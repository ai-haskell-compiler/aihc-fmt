{-# LANGUAGE OverloadedStrings #-}

module Aihc.Fmt
  ( FormatOptions (..),
    defaultFormatOptions,
    FormatError (..),
    formatErrorMessage,
    formatText,
  )
where

import Aihc.Parser
  ( ParserConfig (..),
    defaultConfig,
    formatParseErrors,
    parseModule,
  )
import Aihc.Parser.Parens (addModuleParens)
import Aihc.Parser.Pretty ()
import Aihc.Parser.Syntax
import Aihc.Parser.Token
  ( LexToken (..),
    LexTokenKind (..),
    TokenOrigin (..),
    lexModuleTokensWithSourceNameAndExtensions,
    readModuleHeaderPragmas,
  )
import Control.Applicative ((<|>))
import Data.ByteString qualified as BS
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Prettyprinter (Pretty (pretty), defaultLayoutOptions, layoutPretty)
import Prettyprinter.Render.Text (renderStrict)

newtype FormatOptions = FormatOptions
  { formatExtensions :: [ExtensionSetting]
  }
  deriving (Eq, Show)

defaultFormatOptions :: FormatOptions
defaultFormatOptions = FormatOptions {formatExtensions = []}

data FormatError
  = OriginalParseFailure !FilePath !Text
  | FormattedParseFailure !FilePath !Text
  | SemanticMismatch !FilePath !String
  | TokenStreamMismatch !FilePath
  | IdempotenceFailure !FilePath !Text !Text
  deriving (Eq, Show)

formatText :: FormatOptions -> FilePath -> Text -> Either FormatError Text
formatText opts sourceName input = do
  formatted <- formatTextOnce opts sourceName input
  formattedAgain <- formatTextOnce opts sourceName formatted
  if formattedAgain == formatted
    then Right formatted
    else Left (IdempotenceFailure sourceName formatted formattedAgain)

formatTextOnce :: FormatOptions -> FilePath -> Text -> Either FormatError Text
formatTextOnce opts sourceName input = do
  original <- parseInput OriginalParseFailure sourceName opts input
  rendered <- mergePrettyLayout opts sourceName input original
  let originalTokens = tokenFingerprint opts sourceName input
      renderedTokens = tokenFingerprint opts sourceName rendered
  if originalTokens == renderedTokens
    then pure ()
    else Left (TokenStreamMismatch sourceName)
  reparsed <- parseInput FormattedParseFailure sourceName opts rendered
  if normalizeModule original == normalizeModule reparsed
    then Right rendered
    else
      Left
        ( SemanticMismatch
            sourceName
            "formatted module reparsed to a different AST"
        )

parseInput :: (FilePath -> Text -> FormatError) -> FilePath -> FormatOptions -> Text -> Either FormatError Module
parseInput mkErr sourceName opts input =
  let cfg = parserConfig sourceName opts input
      (errs, modu) = parseModule cfg input
   in if null errs
        then Right modu
        else Left (mkErr sourceName (T.pack (formatParseErrors sourceName (Just input) errs)))

parserConfig :: FilePath -> FormatOptions -> Text -> ParserConfig
parserConfig sourceName opts input =
  defaultConfig
    { parserSourceName = sourceName,
      parserExtensions = formatBaseExtensions opts input
    }

formatBaseExtensions :: FormatOptions -> Text -> [Extension]
formatBaseExtensions opts input =
  effectiveExtensions edition (formatExtensions opts <> headerExtensionSettings headerPragmas)
  where
    headerPragmas = readModuleHeaderPragmas input
    defaultEdition = fromMaybe Haskell2010Edition (editionFromExtensionSettings (formatExtensions opts))
    edition = fromMaybe defaultEdition (headerLanguageEdition headerPragmas)

normalizeModule :: Module -> Module
normalizeModule = stripAnnotations . addModuleParens

data TokenFingerprint = TokenFingerprint
  { tokenKind :: !LexTokenKind,
    tokenText :: !Text,
    tokenOrigin :: !TokenOrigin
  }
  deriving (Eq, Show)

-- | The tokens in the text. The virtual layout tokens are not part of the
-- fingerprint. The formatter changes whitespace, and the whitespace controls
-- where the lexer puts these tokens. The AST check finds a layout change that
-- changes the program.
tokenFingerprint :: FormatOptions -> FilePath -> Text -> [TokenFingerprint]
tokenFingerprint opts sourceName input =
  [ TokenFingerprint
      { tokenKind = lexTokenKind tok,
        tokenText = lexTokenText tok,
        tokenOrigin = lexTokenOrigin tok
      }
  | tok <- lexModuleTokensWithSourceNameAndExtensions sourceName (formatBaseExtensions opts input) input,
    isRealToken tok
  ]

mergePrettyLayout :: FormatOptions -> FilePath -> Text -> Module -> Either FormatError Text
mergePrettyLayout opts sourceName input modu = do
  aligned <- alignTokenStreams sourceName sourceTokensAll prettyTokensAll
  physical <- alignPhysicalSourceTokens sourceName prettyGaps aligned sourcePhysicalTokens
  Right (renderFromSourceTokens input physical)
  where
    exts = formatBaseExtensions opts input
    prettyInput = renderPretty modu
    sourceTokensAll = lexModuleTokensWithSourceNameAndExtensions sourceName exts input
    prettyTokensAll = lexModuleTokensWithSourceNameAndExtensions sourceName exts prettyInput
    sourcePhysicalTokens = physicalSourceTokens sourceTokensAll
    prettyGaps = tokenGaps prettyInput (physicalSourceTokens prettyTokensAll)

renderPretty :: (Pretty a) => a -> Text
renderPretty = renderStrict . layoutPretty defaultLayoutOptions . pretty

physicalSourceTokens :: [LexToken] -> [LexToken]
physicalSourceTokens tokens =
  [ tok
  | tok@LexToken {lexTokenOrigin = FromSource, lexTokenKind = kind} <- tokens,
    kind /= TkEOF
  ]

data PhysicalToken = PhysicalToken
  { physicalToken :: !LexToken,
    physicalPrettyGap :: !(Maybe Text),
    -- | The column of the token in the pretty-printer output. Comments have
    -- no column, because the pretty-printer output has no comments.
    physicalPrettyColumn :: !(Maybe Int)
  }
  deriving (Eq, Show)

-- | Pair each real source token with its token in the pretty-printer output.
-- The virtual layout tokens of the source are not paired, because the
-- whitespace controls where the lexer puts them. An explicit brace or
-- semicolon in the source can pair with a virtual token of the pretty-printer
-- output. The other virtual tokens of the pretty-printer output are skipped.
-- A source token that the AST does not keep has no pair.
alignTokenStreams :: FilePath -> [LexToken] -> [LexToken] -> Either FormatError [(LexToken, Maybe LexToken)]
alignTokenStreams sourceName source pretty' =
  go (filter isRealToken (semanticTokens source)) (semanticTokens pretty')
  where
    go [] ps
      | not (any isRealToken ps) = Right []
    go (s : ss) (p : ps)
      | tokenSemanticsMatch s p = ((s, Just p) :) <$> go ss ps
    go ss (p : ps)
      | not (isRealToken p) = go ss ps
    go (s : ss) ps
      | isDroppedSourceToken s ss = ((s, Nothing) :) <$> go ss ps
    go _ _ = Left (TokenStreamMismatch sourceName)

isRealToken :: LexToken -> Bool
isRealToken tok = lexTokenOrigin tok == FromSource

-- | A source token that the parser accepts but does not keep in the AST. The
-- pretty-printer cannot print it, so the formatter copies it from the source.
-- The only such token now is a trailing comma before a closing parenthesis,
-- as in @module M (a, b,) where@.
isDroppedSourceToken :: LexToken -> [LexToken] -> Bool
isDroppedSourceToken tok rest =
  case (lexTokenKind tok, rest) of
    (TkSpecialComma, next : _) -> lexTokenKind next == TkSpecialRParen
    _ -> False

semanticTokens :: [LexToken] -> [LexToken]
semanticTokens =
  filter
    ( \tok ->
        lexTokenKind tok /= TkEOF
          && not (isCommentToken tok)
    )

tokenSemanticsMatch :: LexToken -> LexToken -> Bool
tokenSemanticsMatch source prettyTok =
  lexTokenKind source == lexTokenKind prettyTok

alignPhysicalSourceTokens :: FilePath -> [(LexToken, Text)] -> [(LexToken, Maybe LexToken)] -> [LexToken] -> Either FormatError [PhysicalToken]
alignPhysicalSourceTokens sourceName prettyGaps =
  go
  where
    go _ [] = Right []
    go pairs (tok : toks)
      | isCommentToken tok =
          (PhysicalToken tok Nothing Nothing :) <$> go pairs toks
      | otherwise =
          case break ((== tok) . fst) pairs of
            (_, []) -> Left (TokenStreamMismatch sourceName)
            (_, (_, Nothing) : restPairs) ->
              (PhysicalToken tok (Just T.empty) Nothing :) <$> go restPairs toks
            (_, (_, Just prettyTok) : restPairs) ->
              (PhysicalToken tok (prettyGapBefore prettyGaps prettyTok) (Just (sourceSpanStartCol (lexTokenSpan prettyTok))) :) <$> go restPairs toks

prettyGapBefore :: [(LexToken, Text)] -> LexToken -> Maybe Text
prettyGapBefore prettyGaps tok
  | lexTokenOrigin tok /= FromSource = Nothing
  | otherwise = lookup tok prettyGaps

tokenGaps :: Text -> [LexToken] -> [(LexToken, Text)]
tokenGaps input =
  go 0
  where
    bytes = TE.encodeUtf8 input

    go _offset [] = []
    go offset (tok : rest) =
      let (start, end) = tokenOffsets tok
          gap = TE.decodeUtf8 (BS.take (start - offset) (BS.drop offset bytes))
       in (tok, gap) : go end rest

renderFromSourceTokens :: Text -> [PhysicalToken] -> Text
renderFromSourceTokens input tokens =
  TE.decodeUtf8 (go Nothing 0 (withCodeColumns tokens))
  where
    bytes = TE.encodeUtf8 input
    total = BS.length bytes

    go _previous offset [] = sliceBytes offset total
    go previous offset ((PhysicalToken tok prettyGap _, column) : rest) =
      let (start, end) = tokenOffsets tok
          gap = TE.decodeUtf8 (sliceBytes offset start)
       in TE.encodeUtf8 (renderGap previous tok prettyGap column gap)
            <> sliceBytes start end
            <> go (Just tok) end rest

    sliceBytes start end = BS.take (end - start) (BS.drop start bytes)

-- | Give each token the pretty-printer column of the next code token. For a
-- code token, this is its own column. For a comment, it is the column of the
-- code token after the comment.
withCodeColumns :: [PhysicalToken] -> [(PhysicalToken, Maybe Int)]
withCodeColumns tokens =
  zip tokens (scanr nextColumn Nothing tokens)
  where
    nextColumn tok later = physicalPrettyColumn tok <|> later

-- | Make the gap before a token. Between two code tokens, use the gap from
-- the pretty-printer. Next to a comment, keep the original line breaks. A
-- token that starts a line after a comment goes to the column of the next
-- code token in the pretty-printer output. Thus a comment does not change
-- the layout.
renderGap :: Maybe LexToken -> LexToken -> Maybe Text -> Maybe Int -> Text -> Text
renderGap Nothing _current _prettyGap _column originalGap = originalGap
renderGap (Just previous) current prettyGap column originalGap
  | isCommentToken previous || isCommentToken current =
      case (T.breakOnEnd "\n" originalGap, column) of
        ((lineBreaks, _), Just col)
          | not (T.null lineBreaks) -> lineBreaks <> T.replicate (col - 1) " "
        _
          | isCommentToken previous,
            Just gap <- prettyGap,
            T.any (== '\n') gap ->
              gap
          | otherwise -> originalGap
  | otherwise = fromMaybe originalGap prettyGap

isCommentToken :: LexToken -> Bool
isCommentToken tok =
  case lexTokenKind tok of
    TkLineComment -> True
    TkBlockComment -> True
    _ -> False

tokenOffsets :: LexToken -> (Int, Int)
tokenOffsets tok =
  (sourceSpanStartOffset (lexTokenSpan tok), sourceSpanEndOffset (lexTokenSpan tok))

formatErrorMessage :: FormatError -> Text
formatErrorMessage err =
  case err of
    OriginalParseFailure sourceName msg ->
      T.pack sourceName <> ": failed to parse input\n" <> msg
    FormattedParseFailure sourceName msg ->
      T.pack sourceName <> ": formatted output did not parse\n" <> msg
    SemanticMismatch sourceName msg ->
      T.pack sourceName <> ": semantic sanity check failed: " <> T.pack msg
    TokenStreamMismatch sourceName ->
      T.pack sourceName <> ": token stream sanity check failed"
    IdempotenceFailure sourceName _ _ ->
      T.pack sourceName <> ": idempotence sanity check failed"
