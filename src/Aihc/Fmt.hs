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
    TraceEntry (..),
    defaultConfig,
    formatParseErrors,
    parseModule,
    parseModuleWithTrace,
    tokenKindWithoutSpacing,
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
import Data.ByteString qualified as BS
import Data.IntMap.Strict (IntMap)
import Data.IntMap.Strict qualified as IntMap
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Prettyprinter (LayoutOptions (..), PageWidth (..), Pretty (pretty), layoutPretty)
import Prettyprinter.Render.Text (renderStrict)

data FormatOptions = FormatOptions
  { formatExtensions :: [ExtensionSetting],
    -- | The maximum line length that the pretty-printer tries to keep. A
    -- line can be longer when it has no break point.
    formatLineWidth :: !Int
  }
  deriving (Eq, Show)

defaultFormatOptions :: FormatOptions
defaultFormatOptions = FormatOptions {formatExtensions = [], formatLineWidth = 120}

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
  (original, sourceTrace) <- parseInputWithTrace OriginalParseFailure sourceName opts input
  rendered <- mergePrettyLayout opts sourceName input sourceTrace original
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
  let (errs, modu) = parseModule (parserConfig sourceName opts input) input
   in if null errs
        then Right modu
        else Left (mkErr sourceName (T.pack (formatParseErrors sourceName (Just input) errs)))

parseInputWithTrace :: (FilePath -> Text -> FormatError) -> FilePath -> FormatOptions -> Text -> Either FormatError (Module, [TraceEntry])
parseInputWithTrace mkErr sourceName opts input =
  let (errs, modu, trace) = parseModuleWithTrace (parserConfig sourceName opts input) input
   in if null errs
        then Right (modu, trace)
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

-- | Write the source tokens with the whitespace of the pretty-printer output.
--
-- The parser trace pairs the tokens. Without the discarded entries, the trace
-- of the source and the trace of the pretty-printer output have the same
-- token kinds. Thus entry @n@ of one trace pairs with entry @n@ of the other.
mergePrettyLayout :: FormatOptions -> FilePath -> Text -> [TraceEntry] -> Module -> Either FormatError Text
mergePrettyLayout opts sourceName input sourceTrace modu = do
  prettyTrace <-
    case parseModuleWithTrace (parserConfig sourceName opts prettyInput) prettyInput of
      ([], _, trace) -> Right trace
      (errs, _, _) -> Left (FormattedParseFailure sourceName (T.pack (formatParseErrors sourceName (Just prettyInput) errs)))
  pairs <- pairTraces sourceName sourceTrace prettyTrace
  let implicitBlockOpenings =
        [ lexTokenSpan prettyTok
        | (sourceTok, prettyTok) <- pairs,
          not (isRealToken sourceTok),
          not (isRealToken prettyTok),
          lexTokenKind prettyTok == TkSpecialLBrace
        ]
      prettyTokens = prettyTokenInfo prettyInput prettyTrace implicitBlockOpenings
      paired =
        IntMap.fromList
          [ (fst (tokenOffsets sourceTok), info)
          | (sourceTok, prettyTok) <- pairs,
            isRealToken sourceTok,
            isRealToken prettyTok,
            Just info <- [IntMap.lookup (fst (tokenOffsets prettyTok)) prettyTokens]
          ]
      roles = map (sourceRole paired) (physicalSourceTokens (lexModuleTokensWithSourceNameAndExtensions sourceName exts input))
  Right (renderFromSourceTokens input roles)
  where
    exts = formatBaseExtensions opts input
    prettyInput = renderPretty (formatLineWidth opts) modu

-- | Pair the trace entries that the AST keeps, by position.
pairTraces :: FilePath -> [TraceEntry] -> [TraceEntry] -> Either FormatError [(LexToken, LexToken)]
pairTraces sourceName sourceTrace prettyTrace
  | length sourceKept == length prettyKept && and (zipWith sameKind sourceKept prettyKept) =
      Right (zip sourceKept prettyKept)
  | otherwise = Left (TokenStreamMismatch sourceName)
  where
    kept = map traceToken . filter (not . traceDiscarded)
    sourceKept = kept sourceTrace
    prettyKept = kept prettyTrace
    sameKind a b = tokenKindWithoutSpacing (lexTokenKind a) == tokenKindWithoutSpacing (lexTokenKind b)

renderPretty :: (Pretty a) => Int -> a -> Text
renderPretty width = renderStrict . layoutPretty (LayoutOptions (AvailablePerLine width 1.0)) . pretty

physicalSourceTokens :: [LexToken] -> [LexToken]
physicalSourceTokens tokens =
  [ tok
  | tok@LexToken {lexTokenOrigin = FromSource, lexTokenKind = kind} <- tokens,
    kind /= TkEOF
  ]

isRealToken :: LexToken -> Bool
isRealToken tok = lexTokenOrigin tok == FromSource

-- | A real token of the pretty-printer output.
data PrettyToken = PrettyToken
  { prettyStart :: !Int,
    -- | The start of the real token before this token, if there is one.
    prettyPreviousStart :: !(Maybe Int),
    -- | The whitespace between the previous real token and this token.
    prettyGap :: !Text,
    prettyColumn :: !Int,
    -- | A layout block opens on the same line, at this token or after it.
    prettyBlockOpensLater :: !Bool
  }

-- | Collect the real tokens of the pretty-printer output. The spans are the
-- virtual open braces of the blocks that use implicit layout in the source
-- too. A block with explicit braces in the source does not use layout.
prettyTokenInfo :: Text -> [TraceEntry] -> [SourceSpan] -> IntMap PrettyToken
prettyTokenInfo prettyInput prettyTrace implicitBlockOpenings =
  IntMap.fromList
    [ (start, PrettyToken start previous gap column (blockOpensFrom line column))
    | (tok, gap, previous) <- withGaps prettyInput realTokens,
      let start = fst (tokenOffsets tok)
          line = sourceSpanStartLine (lexTokenSpan tok)
          column = sourceSpanStartCol (lexTokenSpan tok)
    ]
  where
    realTokens = [tok | tok <- map traceToken prettyTrace, isRealToken tok, lexTokenKind tok /= TkEOF]
    blockOpenings =
      IntMap.fromListWith
        (<>)
        [ (sourceSpanStartLine span', [sourceSpanStartCol span'])
        | span' <- implicitBlockOpenings
        ]
    blockOpensFrom line column =
      any (>= column) (IntMap.findWithDefault [] line blockOpenings)

-- | Give each token the whitespace before it in the text and the start of the
-- token before it.
withGaps :: Text -> [LexToken] -> [(LexToken, Text, Maybe Int)]
withGaps input =
  go Nothing 0
  where
    bytes = TE.encodeUtf8 input

    go _previous _offset [] = []
    go previous offset (tok : rest) =
      let (start, end) = tokenOffsets tok
          gap = TE.decodeUtf8 (BS.take (start - offset) (BS.drop offset bytes))
       in (tok, gap, previous) : go (Just start) end rest

-- | What a source token is in the output.
data SourceRole
  = -- | A real token with a real partner in the pretty-printer output.
    Paired !LexToken !PrettyToken
  | -- | A real token without a real partner. The AST does not keep it, or it
    -- is an explicit brace or semicolon where the pretty-printer output has
    -- a virtual one.
    Unpaired !LexToken
  | -- | A comment or a pragma. The parser does not take these tokens, so
    -- they are not in the trace.
    Hidden !LexToken

roleToken :: SourceRole -> LexToken
roleToken role =
  case role of
    Paired tok _ -> tok
    Unpaired tok -> tok
    Hidden tok -> tok

sourceRole :: IntMap PrettyToken -> LexToken -> SourceRole
sourceRole paired tok
  | isHiddenToken tok = Hidden tok
  | Just info <- IntMap.lookup (fst (tokenOffsets tok)) paired = Paired tok info
  | otherwise = Unpaired tok

isHiddenToken :: LexToken -> Bool
isHiddenToken tok =
  case lexTokenKind tok of
    TkLineComment -> True
    TkBlockComment -> True
    TkPragma _ -> True
    _ -> False

renderFromSourceTokens :: Text -> [SourceRole] -> Text
renderFromSourceTokens input roles =
  TE.decodeUtf8 (go Nothing Nothing 0 (zip roles (scanr nextColumn Nothing roles)))
  where
    bytes = TE.encodeUtf8 input
    total = BS.length bytes

    nextColumn role later =
      case role of
        Paired _ info -> Just (prettyColumn info)
        _ -> later

    go _anchor _previous offset [] = sliceBytes offset total
    go anchor previous offset ((role, column) : rest) =
      let (start, end) = tokenOffsets (roleToken role)
          gap = TE.decodeUtf8 (sliceBytes offset start)
          anchor' =
            case role of
              Paired _ info -> Just info
              Unpaired _ -> anchor
              Hidden _ -> Nothing
       in TE.encodeUtf8 (renderGap anchor previous role column gap)
            <> sliceBytes start end
            <> go anchor' (Just role) end rest

    sliceBytes start end = BS.take (end - start) (BS.drop start bytes)

-- | Make the gap before a token.
--
-- Each token that starts a line goes to its column in the pretty-printer
-- output, or, for a comment, to the column of the next paired token. Thus the
-- start of each line is the same as in the pretty-printer output. Only the
-- rest of a line can move to the left or to the right. That is safe unless a
-- layout block opens on the rest of the line, so then the token starts a new
-- line.
--
-- The anchor is the last paired token before this token, when only unpaired
-- tokens come between them.
renderGap :: Maybe PrettyToken -> Maybe SourceRole -> SourceRole -> Maybe Int -> Text -> Text
renderGap _anchor Nothing _role _column originalGap = originalGap
renderGap anchor (Just previous) role nextColumn originalGap =
  case role of
    Paired _ info
      | Just anchorInfo <- anchor,
        prettyPreviousStart info == Just (prettyStart anchorInfo) ->
          case previous of
            Paired {} -> prettyGap info
            _
              | not (hasLineBreak (prettyGap info)) && prettyBlockOpensLater info ->
                  "\n" <> indentTo (prettyColumn info)
              | otherwise -> prettyGap info
      | hasLineBreak originalGap -> lineBreaks originalGap <> indentTo (prettyColumn info)
      | hasLineBreak (prettyGap info) -> prettyGap info
      | prettyBlockOpensLater info -> "\n" <> indentTo (prettyColumn info)
      | otherwise -> originalGap
    Hidden _
      | hasLineBreak originalGap,
        Just column <- nextColumn ->
          lineBreaks originalGap <> indentTo column
      | otherwise -> originalGap
    Unpaired tok
      | isLineCommentRole previous,
        Just column <- nextColumn ->
          lineBreaks originalGap <> indentTo column
      | hasLineBreak originalGap ->
          -- Put the token at the end of the line before it. There it does
          -- not change the layout.
          if lexTokenKind tok `elem` [TkSpecialComma, TkSpecialSemicolon] then T.empty else " "
      | otherwise -> originalGap
  where
    isLineCommentRole (Hidden tok) = lexTokenKind tok == TkLineComment
    isLineCommentRole _ = False

hasLineBreak :: Text -> Bool
hasLineBreak = T.any (== '\n')

-- | The text up to and with the last line break.
lineBreaks :: Text -> Text
lineBreaks = fst . T.breakOnEnd "\n"

indentTo :: Int -> Text
indentTo column = T.replicate (column - 1) " "

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
