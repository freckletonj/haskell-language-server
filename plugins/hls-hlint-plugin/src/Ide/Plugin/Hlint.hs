{-# LANGUAGE CPP                   #-}
{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE OverloadedLabels      #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE PackageImports        #-}
{-# LANGUAGE PatternSynonyms       #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TupleSections         #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE ViewPatterns          #-}
{-# OPTIONS_GHC -Wno-orphans   #-}
{-# LANGUAGE MultiWayIf            #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE RecordWildCards       #-}

#ifdef HLINT_ON_GHC_LIB
#define MIN_GHC_API_VERSION(x,y,z) MIN_VERSION_ghc_lib(x,y,z)
#else
#define MIN_GHC_API_VERSION(x,y,z) MIN_VERSION_ghc(x,y,z)
#endif

module Ide.Plugin.Hlint
  (
    descriptor
  ) where
import           Control.Arrow                                      ((&&&))
import           Control.Concurrent.STM
import           Control.DeepSeq
import           Control.Exception
import           Control.Lens                                       ((^.))
import           Control.Monad
import           Control.Monad.IO.Class
import           Control.Monad.Trans.Except
import           Data.Aeson.Types                                   (FromJSON (..),
                                                                     ToJSON (..),
                                                                     Value (..))
import           Data.Default
import qualified Data.HashMap.Strict                                as Map
import           Data.Hashable
import           Data.Maybe
import qualified Data.Text                                          as T
import qualified Data.Text.IO                                       as T
import           Data.Typeable
import           Development.IDE                                    hiding
                                                                    (Error)
import           Development.IDE.Core.Rules                         (defineNoFile,
                                                                     getParsedModuleWithComments,
                                                                     usePropertyAction)
import           Development.IDE.Core.Shake                         (getDiagnostics)
import           Refact.Apply

#ifdef HLINT_ON_GHC_LIB
import           Data.List                                          (nub)
import           Development.IDE.GHC.Compat.Core                    (BufSpan,
                                                                     DynFlags,
                                                                     extensionFlags,
                                                                     ms_hspp_opts,
                                                                     topDir)
import qualified Development.IDE.GHC.Compat.Util                    as EnumSet
import           "ghc-lib" GHC                                      hiding
                                                                    (DynFlags (..),
                                                                     RealSrcSpan,
                                                                     ms_hspp_opts)
import qualified "ghc-lib" GHC
import           "ghc-lib-parser" GHC.LanguageExtensions            (Extension)
import           Language.Haskell.GhclibParserEx.GHC.Driver.Session as GhclibParserEx (readExtension)
import           System.FilePath                                    (takeFileName)
import           System.IO                                          (IOMode (WriteMode),
                                                                     hClose,
                                                                     hPutStr,
                                                                     hSetEncoding,
                                                                     hSetNewlineMode,
                                                                     noNewlineTranslation,
                                                                     utf8,
                                                                     withFile)
import           System.IO.Temp
#else
import           Development.IDE.GHC.Compat.Core                    hiding
                                                                    (setEnv)
import           Language.Haskell.GHC.ExactPrint.Delta              (deltaOptions)
import           Language.Haskell.GHC.ExactPrint.Parsers            (postParseTransform)
import           Language.Haskell.GHC.ExactPrint.Types              (Rigidity (..))
import           Language.Haskell.GhclibParserEx.Fixity             as GhclibParserEx (applyFixities)
#endif

import           Ide.Logger
import           Ide.Plugin.Config                                  hiding
                                                                    (Config)
import           Ide.Plugin.Properties
import           Ide.PluginUtils
import           Ide.Types
import           Language.Haskell.HLint                             as Hlint hiding
                                                                             (Error)
import           Language.LSP.Server                                (ProgressCancellable (Cancellable),
                                                                     sendRequest,
                                                                     withIndefiniteProgress)
import           Language.LSP.Types                                 hiding
                                                                    (SemanticTokenAbsolute (length, line),
                                                                     SemanticTokenRelative (length),
                                                                     SemanticTokensEdit (_start))
import qualified Language.LSP.Types                                 as LSP
import qualified Language.LSP.Types.Lens                            as LSP

import           GHC.Generics                                       (Associativity (LeftAssociative, NotAssociative, RightAssociative),
                                                                     Generic)
import           Text.Regex.TDFA.Text                               ()

import           Development.IDE.GHC.Compat.Core                    (WarningFlag (Opt_WarnUnrecognisedPragmas),
                                                                     wopt)
import           Development.IDE.Spans.Pragmas                      (LineSplitTextEdits (LineSplitTextEdits),
                                                                     NextPragmaInfo (NextPragmaInfo),
                                                                     getNextPragmaInfo,
                                                                     lineSplitDeleteTextEdit,
                                                                     lineSplitInsertTextEdit,
                                                                     lineSplitTextEdits,
                                                                     nextPragmaLine)
import           System.Environment                                 (setEnv,
                                                                     unsetEnv)
-- ---------------------------------------------------------------------

#ifdef HLINT_ON_GHC_LIB
-- Reimplementing this, since the one in Development.IDE.GHC.Compat isn't for ghc-lib
pattern RealSrcSpan :: GHC.RealSrcSpan -> Maybe BufSpan -> GHC.SrcSpan
#if MIN_VERSION_ghc(9,0,0)
pattern RealSrcSpan x y = GHC.RealSrcSpan x y
#else
pattern RealSrcSpan x y <- ((,Nothing) -> (GHC.RealSrcSpan x, y))
#endif
{-# COMPLETE RealSrcSpan, UnhelpfulSpan #-}
#endif

descriptor :: PluginId -> PluginDescriptor IdeState
descriptor plId = (defaultPluginDescriptor plId)
  { pluginRules = rules plId
  , pluginCommands =
      [ PluginCommand "applyOne" "Apply a single hint" applyOneCmd
      , PluginCommand "applyAll" "Apply all hints to the file" applyAllCmd
      ]
  , pluginHandlers = mkPluginHandler STextDocumentCodeAction codeActionProvider
  , pluginConfigDescriptor = defaultConfigDescriptor
      { configHasDiagnostics = True
      , configCustomConfig = mkCustomConfig properties
      }
  }

-- This rule only exists for generating file diagnostics
-- so the RuleResult is empty
data GetHlintDiagnostics = GetHlintDiagnostics
    deriving (Eq, Show, Typeable, Generic)
instance Hashable GetHlintDiagnostics
instance NFData   GetHlintDiagnostics

type instance RuleResult GetHlintDiagnostics = ()

-- | Hlint rules to generate file diagnostics based on hlint hints
-- | This rule is recomputed when:
-- | - A file has been edited via
-- |    - `getIdeas` -> `getParsedModule` in any case
-- |    - `getIdeas` -> `getFileContents` if the hls ghc does not match the hlint default ghc
-- | - The client settings have changed, to honour the `hlintOn` setting, via `getClientConfigAction`
-- | - The hlint specific settings have changed, via `getHlintSettingsRule`
rules :: PluginId -> Rules ()
rules plugin = do
  define $ \GetHlintDiagnostics file -> do
    config <- getClientConfigAction def
    let pluginConfig = configForPlugin config plugin
    let hlintOn' = hlintOn config && plcGlobalOn pluginConfig && plcDiagnosticsOn pluginConfig
    ideas <- if hlintOn' then getIdeas file else return (Right [])
    return (diagnostics file ideas, Just ())

  defineNoFile $ \GetHlintSettings -> do
    (Config flags) <- getHlintConfig plugin
    liftIO $ argsSettings flags

  action $ do
    files <- getFilesOfInterestUntracked
    void $ uses GetHlintDiagnostics $ Map.keys files

  where

      diagnostics :: NormalizedFilePath -> Either ParseError [Idea] -> [FileDiagnostic]
      diagnostics file (Right ideas) =
        [(file, ShowDiag, ideaToDiagnostic i) | i <- ideas, ideaSeverity i /= Ignore]
      diagnostics file (Left parseErr) =
        [(file, ShowDiag, parseErrorToDiagnostic parseErr)]

      ideaToDiagnostic :: Idea -> Diagnostic
      ideaToDiagnostic idea =
        LSP.Diagnostic {
            _range    = srcSpanToRange $ ideaSpan idea
          , _severity = Just LSP.DsInfo
          -- we are encoding the fact that idea has refactorings in diagnostic code
          , _code     = Just (InR $ T.pack $ codePre ++ ideaHint idea)
          , _source   = Just "hlint"
          , _message  = idea2Message idea
          , _relatedInformation = Nothing
          , _tags     = Nothing
        }
        where codePre = if null $ ideaRefactoring idea then "" else "refact:"

      idea2Message :: Idea -> T.Text
      idea2Message idea = T.unlines $ [T.pack $ ideaHint idea, "Found:", "  " <> T.pack (ideaFrom idea)]
                                     <> toIdea <> map (T.pack . show) (ideaNote idea)
        where
          toIdea :: [T.Text]
          toIdea = case ideaTo idea of
            Nothing -> []
            Just i  -> [T.pack "Why not:", T.pack $ "  " ++ i]


      parseErrorToDiagnostic :: ParseError -> Diagnostic
      parseErrorToDiagnostic (Hlint.ParseError l msg contents) =
        LSP.Diagnostic {
            _range    = srcSpanToRange l
          , _severity = Just LSP.DsInfo
          , _code     = Just (InR "parser")
          , _source   = Just "hlint"
          , _message  = T.unlines [T.pack msg,T.pack contents]
          , _relatedInformation = Nothing
          , _tags     = Nothing
        }

      -- This one is defined in Development.IDE.GHC.Error but here
      -- the types could come from ghc-lib or ghc
      srcSpanToRange :: SrcSpan -> LSP.Range
      srcSpanToRange (RealSrcSpan span _) = Range {
          _start = LSP.Position {
                _line = srcSpanStartLine span - 1
              , _character  = srcSpanStartCol span - 1}
        , _end   = LSP.Position {
                _line = srcSpanEndLine span - 1
             , _character = srcSpanEndCol span - 1}
        }
      srcSpanToRange (UnhelpfulSpan _) = noRange

getIdeas :: NormalizedFilePath -> Action (Either ParseError [Idea])
getIdeas nfp = do
  debugm $ "hlint:getIdeas:file:" ++ show nfp
  (flags, classify, hint) <- useNoFile_ GetHlintSettings

  let applyHints' (Just (Right modEx)) = Right $ applyHints classify hint [modEx]
      applyHints' (Just (Left err)) = Left err
      applyHints' Nothing = Right []

  fmap applyHints' (moduleEx flags)

  where moduleEx :: ParseFlags -> Action (Maybe (Either ParseError ModuleEx))
#ifndef HLINT_ON_GHC_LIB
        moduleEx _flags = do
          mbpm <- getParsedModuleWithComments nfp
          return $ createModule <$> mbpm
          where
            createModule pm = Right (createModuleEx anns (applyParseFlagsFixities modu))
                  where anns = pm_annotations pm
                        modu = pm_parsed_source pm

            applyParseFlagsFixities :: ParsedSource -> ParsedSource
            applyParseFlagsFixities modul = GhclibParserEx.applyFixities (parseFlagsToFixities _flags) modul

            parseFlagsToFixities :: ParseFlags -> [(String, Fixity)]
            parseFlagsToFixities = map toFixity . Hlint.fixities

            toFixity :: FixityInfo -> (String, Fixity)
            toFixity (name, dir, i) = (name, Fixity NoSourceText i $ f dir)
                where
                    f LeftAssociative  = InfixL
                    f RightAssociative = InfixR
                    f NotAssociative   = InfixN
#else
        moduleEx flags = do
          mbpm <- getParsedModuleWithComments nfp
          -- If ghc was not able to parse the module, we disable hlint diagnostics
          if isNothing mbpm
              then return Nothing
              else do
                     flags' <- setExtensions flags
                     (_, contents) <- getFileContents nfp
                     let fp = fromNormalizedFilePath nfp
                     let contents' = T.unpack <$> contents
                     Just <$> liftIO (parseModuleEx flags' fp contents')

        setExtensions flags = do
          hlintExts <- getExtensions flags nfp
          debugm $ "hlint:getIdeas:setExtensions:" ++ show hlintExts
          return $ flags { enabledExtensions = hlintExts }

getExtensions :: ParseFlags -> NormalizedFilePath -> Action [Extension]
getExtensions pflags nfp = do
    dflags <- getFlags
    let hscExts = EnumSet.toList (extensionFlags dflags)
    let hscExts' = mapMaybe (GhclibParserEx.readExtension . show) hscExts
    let hlintExts = nub $ enabledExtensions pflags ++ hscExts'
    return hlintExts
  where getFlags :: Action DynFlags
        getFlags = do
          modsum <- use_ GetModSummary nfp
          return $ ms_hspp_opts $ msrModSummary modsum
#endif

-- ---------------------------------------------------------------------

data GetHlintSettings = GetHlintSettings
    deriving (Eq, Show, Typeable, Generic)
instance Hashable GetHlintSettings
instance NFData   GetHlintSettings
instance NFData Hint where rnf = rwhnf
instance NFData Classify where rnf = rwhnf
instance NFData ParseFlags where rnf = rwhnf
instance Show Hint where show = const "<hint>"
instance Show ParseFlags where show = const "<parseFlags>"

type instance RuleResult GetHlintSettings = (ParseFlags, [Classify], Hint)

-- ---------------------------------------------------------------------

newtype Config = Config [String]

properties :: Properties '[ 'PropertyKey "flags" ('TArray String)]
properties = emptyProperties
  & defineArrayProperty #flags
    "Flags used by hlint" []

-- | Get the plugin config
getHlintConfig :: PluginId -> Action Config
getHlintConfig pId =
  Config
    <$> usePropertyAction #flags pId properties

runHlintAction
 :: (Eq k, Hashable k, Show k, Show (RuleResult k), Typeable k, Typeable (RuleResult k), NFData k, NFData (RuleResult k))
 => IdeState
 -> NormalizedFilePath -> String -> k -> IO (Maybe (RuleResult k))
runHlintAction ideState normalizedFilePath desc rule = runAction desc ideState $ use rule normalizedFilePath

runGetFileContentsAction :: IdeState -> NormalizedFilePath -> IO (Maybe (FileVersion, Maybe T.Text))
runGetFileContentsAction ideState normalizedFilePath = runHlintAction ideState normalizedFilePath "Hlint.GetFileContents" GetFileContents

runGetModSummaryAction :: IdeState -> NormalizedFilePath -> IO (Maybe ModSummaryResult)
runGetModSummaryAction ideState normalizedFilePath = runHlintAction ideState normalizedFilePath "Hlint.GetModSummary" GetModSummary

-- ---------------------------------------------------------------------
codeActionProvider :: PluginMethodHandler IdeState TextDocumentCodeAction
codeActionProvider ideState pluginId (CodeActionParams _ _ documentId _ context)
  | let TextDocumentIdentifier uri = documentId
  , Just docNormalizedFilePath <- uriToNormalizedFilePath (toNormalizedUri uri)
  = liftIO $ fmap (Right . LSP.List . map LSP.InR) $ do
      allDiagnostics <- atomically $ getDiagnostics ideState
      let numHintsInDoc = length
            [diagnostic | (diagnosticNormalizedFilePath, _, diagnostic) <- allDiagnostics
                        , validCommand diagnostic
                        , diagnosticNormalizedFilePath == docNormalizedFilePath
            ]
      let numHintsInContext = length
            [diagnostic | diagnostic <- diags
                        , validCommand diagnostic
            ]
      file <- runGetFileContentsAction ideState docNormalizedFilePath
      singleHintCodeActions <-
        if | Just (_, source) <- file -> do
               modSummaryResult <- runGetModSummaryAction ideState docNormalizedFilePath
               pure if | Just modSummaryResult <- modSummaryResult
                       , Just source <- source
                       , let dynFlags = ms_hspp_opts $ msrModSummary modSummaryResult ->
                           diags >>= diagnosticToCodeActions dynFlags source pluginId documentId
                       | otherwise -> []
           | otherwise -> pure []
      if numHintsInDoc > 1 && numHintsInContext > 0 then do
        pure $ singleHintCodeActions ++ [applyAllAction]
      else
        pure singleHintCodeActions
  | otherwise
  = pure $ Right $ LSP.List []

  where
    applyAllAction =
      let args = Just [toJSON (documentId ^. LSP.uri)]
          cmd = mkLspCommand pluginId "applyAll" "Apply all hints" args
        in LSP.CodeAction "Apply all hints" (Just LSP.CodeActionQuickFix) Nothing Nothing Nothing Nothing (Just cmd) Nothing

    -- |Some hints do not have an associated refactoring
    validCommand (LSP.Diagnostic _ _ (Just (InR code)) (Just "hlint") _ _ _) =
        "refact:" `T.isPrefixOf` code
    validCommand _ =
        False

    LSP.List diags = context ^. LSP.diagnostics

-- | Convert a hlint diagonistic into an apply and an ignore code action
-- if applicable
diagnosticToCodeActions :: DynFlags -> T.Text -> PluginId -> TextDocumentIdentifier -> LSP.Diagnostic -> [LSP.CodeAction]
diagnosticToCodeActions dynFlags fileContents pluginId documentId diagnostic
  | LSP.Diagnostic{ _source = Just "hlint", _code = Just (InR code), _range = LSP.Range start _ } <- diagnostic
  , let TextDocumentIdentifier uri = documentId
  , let isHintApplicable = "refact:" `T.isPrefixOf` code
  , let hint = T.replace "refact:" "" code
  , let suppressHintTitle = "Ignore hint \"" <> hint <> "\" in this module"
  , let suppressHintTextEdits = mkSuppressHintTextEdits dynFlags fileContents hint
  , let suppressHintWorkspaceEdit =
          LSP.WorkspaceEdit
            (Just (Map.singleton uri (List suppressHintTextEdits)))
            Nothing
            Nothing
  = catMaybes
      [ if | isHintApplicable
           , let applyHintTitle = "Apply hint \"" <> hint <> "\""
                 applyHintArguments = [toJSON (AOP (documentId ^. LSP.uri) start hint)]
                 applyHintCommand = mkLspCommand pluginId "applyOne" applyHintTitle (Just applyHintArguments) ->
               Just (mkCodeAction applyHintTitle diagnostic Nothing (Just applyHintCommand))
           | otherwise -> Nothing
      , Just (mkCodeAction suppressHintTitle diagnostic (Just suppressHintWorkspaceEdit) Nothing)
      ]
  | otherwise = []

mkCodeAction :: T.Text -> LSP.Diagnostic -> Maybe LSP.WorkspaceEdit -> Maybe LSP.Command -> LSP.CodeAction
mkCodeAction title diagnostic workspaceEdit command =
  LSP.CodeAction
    { _title = title
    , _kind = Just LSP.CodeActionQuickFix
    , _diagnostics = Just (LSP.List [diagnostic])
    , _isPreferred = Nothing
    , _disabled = Nothing
    , _edit = workspaceEdit
    , _command = command
    , _xdata = Nothing
    }

mkSuppressHintTextEdits :: DynFlags -> T.Text -> T.Text -> [LSP.TextEdit]
mkSuppressHintTextEdits dynFlags fileContents hint =
  let
    NextPragmaInfo{ nextPragmaLine, lineSplitTextEdits } = getNextPragmaInfo dynFlags (Just fileContents)
    nextPragmaLinePosition = Position nextPragmaLine 0
    nextPragmaRange = Range nextPragmaLinePosition nextPragmaLinePosition
    wnoUnrecognisedPragmasText =
      if wopt Opt_WarnUnrecognisedPragmas dynFlags
      then Just "{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}\n"
      else Nothing
    hlintIgnoreText = Just ("{-# HLINT ignore \"" <> hint <> "\" #-}\n")
    -- we combine the texts into a single text because lsp-test currently
    -- applies text edits backwards and I want the options pragma to
    -- appear above the hlint pragma in the tests
    combinedText = mconcat $ catMaybes [wnoUnrecognisedPragmasText, hlintIgnoreText]
    combinedTextEdit = LSP.TextEdit nextPragmaRange combinedText
    lineSplitTextEditList = maybe [] (\LineSplitTextEdits{..} -> [lineSplitInsertTextEdit, lineSplitDeleteTextEdit]) lineSplitTextEdits
  in
    combinedTextEdit : lineSplitTextEditList
-- ---------------------------------------------------------------------

applyAllCmd :: CommandFunction IdeState Uri
applyAllCmd ide uri = do
  let file = maybe (error $ show uri ++ " is not a file.")
                    toNormalizedFilePath'
                   (uriToFilePath' uri)
  withIndefiniteProgress "Applying all hints" Cancellable $ do
    logm $ "hlint:applyAllCmd:file=" ++ show file
    res <- liftIO $ applyHint ide file Nothing
    logm $ "hlint:applyAllCmd:res=" ++ show res
    case res of
      Left err -> pure $ Left (responseError (T.pack $ "hlint:applyAll: " ++ show err))
      Right fs -> do
        _ <- sendRequest SWorkspaceApplyEdit (ApplyWorkspaceEditParams Nothing fs) (\_ -> pure ())
        pure $ Right Null

-- ---------------------------------------------------------------------

data ApplyOneParams = AOP
  { file      :: Uri
  , start_pos :: Position
  -- | There can be more than one hint suggested at the same position, so HintTitle is used to distinguish between them.
  , hintTitle :: HintTitle
  } deriving (Eq,Show,Generic,FromJSON,ToJSON)

type HintTitle = T.Text

data OneHint = OneHint
  { oneHintPos   :: Position
  , oneHintTitle :: HintTitle
  } deriving (Eq, Show)

applyOneCmd :: CommandFunction IdeState ApplyOneParams
applyOneCmd ide (AOP uri pos title) = do
  let oneHint = OneHint pos title
  let file = maybe (error $ show uri ++ " is not a file.") toNormalizedFilePath'
                   (uriToFilePath' uri)
  let progTitle = "Applying hint: " <> title
  withIndefiniteProgress progTitle Cancellable $ do
    logm $ "hlint:applyOneCmd:file=" ++ show file
    res <- liftIO $ applyHint ide file (Just oneHint)
    logm $ "hlint:applyOneCmd:res=" ++ show res
    case res of
      Left err -> pure $ Left (responseError (T.pack $ "hlint:applyOne: " ++ show err))
      Right fs -> do
        _ <- sendRequest SWorkspaceApplyEdit (ApplyWorkspaceEditParams Nothing fs) (\_ -> pure ())
        pure $ Right Null

applyHint :: IdeState -> NormalizedFilePath -> Maybe OneHint -> IO (Either String WorkspaceEdit)
applyHint ide nfp mhint =
  runExceptT $ do
    let runAction' :: Action a -> IO a
        runAction' = runAction "applyHint" ide
    let errorHandlers = [ Handler $ \e -> return (Left (show (e :: IOException)))
                        , Handler $ \e -> return (Left (show (e :: ErrorCall)))
                        ]
    ideas <- bimapExceptT showParseError id $ ExceptT $ runAction' $ getIdeas nfp
    let ideas' = maybe ideas (`filterIdeas` ideas) mhint
    let commands = map ideaRefactoring ideas'
    liftIO $ logm $ "applyHint:apply=" ++ show commands
    let fp = fromNormalizedFilePath nfp
    (_, mbOldContent) <- liftIO $ runAction' $ getFileContents nfp
    oldContent <- maybe (liftIO $ T.readFile fp) return mbOldContent
    modsum <- liftIO $ runAction' $ use_ GetModSummary nfp
    let dflags = ms_hspp_opts $ msrModSummary modsum
    -- Setting a environment variable with the libdir used by ghc-exactprint.
    -- It is a workaround for an error caused by the use of a hadcoded at compile time libdir
    -- in ghc-exactprint that makes dependent executables non portables.
    -- See https://github.com/alanz/ghc-exactprint/issues/96.
    -- WARNING: this code is not thread safe, so if you try to apply several async refactorings
    -- it could fail. That case is not very likely so we assume the risk.
    let withRuntimeLibdir :: IO a -> IO a
        withRuntimeLibdir = bracket_ (setEnv key $ topDir dflags) (unsetEnv key)
            where key = "GHC_EXACTPRINT_GHC_LIBDIR"
    -- set Nothing as "position" for "applyRefactorings" because
    -- applyRefactorings expects the provided position to be _within_ the scope
    -- of each refactoring it will apply.
    -- But "Idea"s returned by HLint point to starting position of the expressions
    -- that contain refactorings, so they are often outside the refactorings' boundaries.
    let position = Nothing
#ifdef HLINT_ON_GHC_LIB
    let writeFileUTF8NoNewLineTranslation file txt =
            withFile file WriteMode $ \h -> do
                hSetEncoding h utf8
                hSetNewlineMode h noNewlineTranslation
                hPutStr h (T.unpack txt)
    res <-
        liftIO $ withSystemTempFile (takeFileName fp) $ \temp h -> do
            hClose h
            writeFileUTF8NoNewLineTranslation temp oldContent
            (pflags, _, _) <- runAction' $ useNoFile_ GetHlintSettings
            exts <- runAction' $ getExtensions pflags nfp
            -- We have to reparse extensions to remove the invalid ones
            let (enabled, disabled, _invalid) = parseExtensions $ map show exts
            let refactExts = map show $ enabled ++ disabled
            (Right <$> withRuntimeLibdir (applyRefactorings position commands temp refactExts))
                `catches` errorHandlers
#else
    mbParsedModule <- liftIO $ runAction' $ getParsedModuleWithComments nfp
    res <-
        case mbParsedModule of
            Nothing -> throwE "Apply hint: error parsing the module"
            Just pm -> do
                let anns = pm_annotations pm
                let modu = pm_parsed_source pm
                -- apply-refact uses RigidLayout
                let rigidLayout = deltaOptions RigidLayout
                (anns', modu') <-
                    ExceptT $ return $ postParseTransform (Right (anns, [], dflags, modu)) rigidLayout
                liftIO $ (Right <$> withRuntimeLibdir (applyRefactorings' position commands anns' modu'))
                            `catches` errorHandlers
#endif
    case res of
      Right appliedFile -> do
        let uri = fromNormalizedUri (filePathToUri' nfp)
        let wsEdit = diffText' True (uri, oldContent) (T.pack appliedFile) IncludeDeletions
        liftIO $ logm $ "hlint:applyHint:diff=" ++ show wsEdit
        ExceptT $ return (Right wsEdit)
      Left err ->
        throwE err
    where
          -- | If we are only interested in applying a particular hint then
          -- let's filter out all the irrelevant ideas
          filterIdeas :: OneHint -> [Idea] -> [Idea]
          filterIdeas (OneHint (Position l c) title) ideas =
            let title' = T.unpack title
                ideaPos = (srcSpanStartLine &&& srcSpanStartCol) . toRealSrcSpan . ideaSpan
            in filter (\i -> ideaHint i == title' && ideaPos i == (l+1, c+1)) ideas

          toRealSrcSpan (RealSrcSpan real _) = real
          toRealSrcSpan (UnhelpfulSpan x) = error $ "No real source span: " ++ show x

          showParseError :: Hlint.ParseError -> String
          showParseError (Hlint.ParseError location message content) =
            unlines [show location, message, content]

-- | Map over both failure and success.
bimapExceptT :: Functor m => (e -> f) -> (a -> b) -> ExceptT e m a -> ExceptT f m b
bimapExceptT f g (ExceptT m) = ExceptT (fmap h m) where
  h (Left e)  = Left (f e)
  h (Right a) = Right (g a)
{-# INLINE bimapExceptT #-}
