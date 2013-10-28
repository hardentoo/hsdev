{-# LANGUAGE GeneralizedNewtypeDeriving, FlexibleContexts, OverloadedStrings, CPP #-}

module Main (
	main
	) where

import Control.Applicative
import Control.Arrow
import Control.Concurrent
import Control.Exception
import Control.DeepSeq (force, NFData)
import Control.Monad
import Control.Monad.Error
import Control.Monad.Trans.Maybe
import Control.Monad.Reader
import qualified Data.ByteString.Lazy.Char8 as L (unpack, pack)
import Data.Aeson
import Data.Aeson.Encode.Pretty
import Data.Aeson.Types (parseMaybe)
import Data.Either (partitionEithers)
import Data.Maybe
import Data.Monoid
import Data.List
import qualified Data.Text as T (unpack)
import Data.Traversable (traverse)
import qualified Data.Traversable as T (forM)
import Data.Map (Map)
import Data.String (fromString)
import qualified Data.Map as M
import qualified Data.HashMap.Strict as HM
import Network.Socket
import System.Command hiding (brief)
import qualified System.Command as C (brief)
import System.Environment
import System.Exit
import System.Console.GetOpt
import System.Directory (canonicalizePath, getDirectoryContents, doesFileExist, createDirectoryIfMissing, doesDirectoryExist, getCurrentDirectory)
import System.FilePath
import System.IO
import System.Process
import System.Timeout

#ifdef mingw32_HOST_OS
import System.Win32.FileMapping.Memory (withMapFile, readMapFile)
import System.Win32.FileMapping.NamePool
#endif

import Text.Read (readMaybe)

import HsDev.Cache
import HsDev.Commands
import HsDev.Database
import HsDev.Database.Async
import HsDev.Project
import HsDev.Scan
import HsDev.Symbols
import HsDev.Symbols.Util
import HsDev.Symbols.JSON
import HsDev.Tools.GhcMod
import HsDev.Util
import HsDev.Inspect

import qualified Commands as C

main :: IO ()
main = withSocketsDo $ do
	hSetBuffering stdout LineBuffering
	hSetEncoding stdout utf8
	as <- getArgs
	when (null as) $ do
		printMainUsage
		exitSuccess
	let
		asr = if last as == "-?" then "help" : init as else as 
	run mainCommands onDef onError asr
	where
		onError :: [String] -> IO ()
		onError errs = do
			mapM_ putStrLn errs
			exitFailure

		onDef :: IO ()
		onDef = do
			putStrLn "Unknown command"
			exitFailure

mainCommands :: [Command (IO ())]
mainCommands = addHelp "hsdev" id $ srvCmds ++ map (fmap sendCmd . addClientOpts . fmap withOptsArgs) commands where
	srvCmds = [
		cmd_ ["run"] [] "run interactive" $ \_ -> do
			dir <- getCurrentDirectory
			db <- newAsync
			forever $ do
				s <- getLine
				r <- processCmd (CommandOptions db dir) 10000 s putStrLn
				unless r exitSuccess,
		cmd ["server", "start"] [] "start remote server" serverOpts $ \sopts _ -> do
			let
				args = ["server", "run"] ++ maybe [] (\p' -> ["--port", show p']) (getFirst $ serverPort sopts)
			void $ runInteractiveProcess "powershell" ["-Command", "& {start-process hsdev " ++ intercalate ", " args ++ " -WindowStyle Hidden}"] Nothing Nothing
			printOk sopts $ "Server started at port " ++ show (fromJust $ getFirst $ serverPort sopts),
		cmd ["server", "run"] [] "start server" serverOpts $ \sopts _ -> do
			msgs <- newChan
			forkIO $ getChanContents msgs >>= mapM_ (printOk sopts)
			let
				outputStr = writeChan msgs

			db <- newAsync

			waitListen <- newEmptyMVar
			clientChan <- newChan

#ifdef mingw32_HOST_OS
			mmapPool <- createPool "hsdev"
			let
				-- | Send response as is or via memory mapped file
				sendResponseToClient :: Handle -> String -> IO ()
				sendResponseToClient h msg
					| length msg <= 1024 = hPutStrLn h msg
					| otherwise = do
						sync <- newEmptyMVar
						forkIO $ void $ withName mmapPool $ \mmapName -> do
							runErrorT $ flip catchError
								(\e -> liftIO $ do
									hPutStrLn h (L.unpack $ encode $ err e)
									putMVar sync ())
								(withMapFile mmapName msg $ liftIO $ do
									hPutStrLn h $ L.unpack $ encode $ ResultMapFile mmapName
									putMVar sync ()
									-- Give 10 seconds for client to read it
									threadDelay 10000000)
						takeMVar sync
#else
			let
				sendResponseToClient = hPutStrLn
#endif

			forkIO $ do
				accepter <- myThreadId
				s <- socket AF_INET Stream defaultProtocol
				bind s (SockAddrInet (fromIntegral $ fromJust $ getFirst $ serverPort sopts) iNADDR_ANY)
				listen s maxListenQueue
				forever $ handle (ignoreIO outputStr) $ do
					s' <- fmap fst $ accept s
					outputStr $ show s' ++ " connected"
					void $ forkIO $ bracket (socketToHandle s' ReadWriteMode) hClose $ \h -> do
						me <- myThreadId
						done <- newEmptyMVar
						let
							timeoutWait = do
								notDone <- isEmptyMVar done
								when notDone $ do
									void $ forkIO $ do
										threadDelay 1000000
										tryPutMVar done ()
										killThread me
									void $ takeMVar done
						writeChan clientChan (Just timeoutWait)
						req <- hGetLine h
						outputStr $ show s' ++ ": " ++ req
						r <- case fmap extractCurrentDir $ eitherDecode (L.pack req) of
							Left reqErr -> do
								hPutStrLn h $ L.unpack $ encode $ errArgs "Invalid request" [("request", ResultString req), ("error", ResultString reqErr)]
								return False
							Right (clientDir, reqArgs) -> processCmdArgs
								(CommandOptions db clientDir)
								(fromJust $ getFirst $ serverTimeout sopts) reqArgs (sendResponseToClient h)
						unless r $ do
							void $ tryPutMVar waitListen ()
							killThread accepter
						putMVar done ()


			takeMVar waitListen
			outputStr "waiting for clients"
			writeChan clientChan Nothing
			getChanContents clientChan >>= sequence_ . catMaybes . takeWhile isJust
			outputStr "server shutdown",
		cmd ["server", "stop"] [] "stop remote server" serverOpts $ \sopts _ -> do
			pname <- getExecutablePath
			r <- readProcess pname (maybe [] (\p' -> ["--port", show p']) (getFirst $ serverPort sopts) ++ ["exit"]) ""
			let
				stopped = case decode (L.pack r) of
					Just (Object obj) -> fromMaybe False $ flip parseMaybe obj $ \_ -> do
						res <- obj .: "result"
						return (res == ("exit" :: String))
					_ -> False
			printOk sopts $ if stopped then "Server stopped" else "Server returned: " ++ r]
		where
			ignoreIO :: (String -> IO ()) -> IOException -> IO ()
			ignoreIO out = out . show

			printOk :: ServerOpts -> String -> IO ()
			printOk _ = putStrLn

	-- Send command to server
	sendCmd :: IO (ClientOpts, [String]) -> IO ()
	sendCmd get' = do
		curDir <- getCurrentDirectory
		(p, as) <- get'
		stdinData <- if getAny (clientData p)
			then do
				cdata <- liftM (eitherDecode . L.pack) getContents
				case cdata of
					Left cdataErr -> do
						putStrLn $ "Invalid data: " ++ cdataErr
						exitFailure
					Right dataValue -> return $ Just dataValue
			else return Nothing

		s <- socket AF_INET Stream defaultProtocol
		addr' <- inet_addr "127.0.0.1"
		connect s (SockAddrInet (fromIntegral $ fromJust $ getFirst $ clientPort p) addr')
		h <- socketToHandle s ReadWriteMode
		hPutStrLn h $ L.unpack $ encode $ ["--current-directory", curDir] ++ setData stdinData as
		responses <- liftM lines $ hGetContents h
		forM_ responses $
			parseResponse >=>
			(putStrLn . encodeValue (getAny $ clientPretty p))
		where
			setData :: Maybe ResultValue -> [String] -> [String]
			setData Nothing = id
			setData (Just d) = (++ ["--data", L.unpack $ encode d])

			parseResponse r = fmap (either err' id) $ runErrorT $ do
				v <- errT (eitherDecode (L.pack r)) `orFail`
					(\e -> "Can't decode response " ++ r ++ " due to: " ++ e)
				case parseMaybe (withObject "map view of file" (.: "file")) v of
					Nothing -> return v
					Just viewFile -> do
						str <- readMapFile viewFile `orFail`
							(\e -> "Can't read map view of file " ++ viewFile ++ " due to: " ++ e)
						errT (eitherDecode (L.pack str)) `orFail`
							(\e -> "Can't decode map view of file contents " ++ str ++ " due to: " ++ e)
				where
					errT act = ErrorT $ return act
					orFail act msg = act `catchError` (throwError . msg)
					err' msg = object ["error" .= msg]

			encodeValue True = L.unpack . encodePretty
			encodeValue False = L.unpack . encode

	-- Add parsing 'ClieptOpts'
	addClientOpts :: Command (IO [String]) -> Command (IO (ClientOpts, [String]))
	addClientOpts c = c { commandRun = run' } where
		run' args = fmap (fmap (fmap $ (,) p)) $ commandRun c args' where
			(ps, args', _) = getOpt RequireOrder clientOpts args
			p = mconcat ps `mappend` defaultConfig

	extractCurrentDir :: [String] -> (FilePath, [String])
	extractCurrentDir as = (head $ cur ++ ["."], as') where
		(cur, as', _) = getOpt RequireOrder curDirOpts as
		curDirOpts = [Option [] ["current-directory"] (ReqArg id "path") "current directory"]

data ServerOpts = ServerOpts {
	serverPort :: First Int,
	serverTimeout :: First Int }

instance DefaultConfig ServerOpts where
	defaultConfig = ServerOpts (First $ Just 4567) (First $ Just 1000)

serverOpts :: [OptDescr ServerOpts]
serverOpts = [
	Option [] ["port"] (ReqArg (\p -> mempty { serverPort = First (readMaybe p) }) "number") "listen port",
	Option [] ["timeout"] (ReqArg (\t -> mempty { serverTimeout = First (readMaybe t) }) "msec") "query timeout"]

instance Monoid ServerOpts where
	mempty = ServerOpts mempty mempty
	l `mappend` r = ServerOpts
		(serverPort l `mappend` serverPort r)
		(serverTimeout l `mappend` serverTimeout r)

data ClientOpts = ClientOpts {
	clientPort :: First Int,
	clientPretty :: Any,
	clientData :: Any }

instance DefaultConfig ClientOpts where
	defaultConfig = ClientOpts (First $ Just 4567) mempty mempty

clientOpts :: [OptDescr ClientOpts]
clientOpts = [
	Option [] ["port"] (ReqArg (\p -> mempty { clientPort = First (readMaybe p) }) "number") "connection port",
	Option [] ["pretty"] (NoArg (mempty { clientPretty = Any True })) "pretty json output",
	Option [] ["stdin"] (NoArg (mempty { clientData = Any True })) "pass data to stdin"]

instance Monoid ClientOpts where
	mempty = ClientOpts mempty mempty mempty
	l `mappend` r = ClientOpts
		(clientPort l `mappend` clientPort r)
		(clientPretty l `mappend` clientPretty r)
		(clientData l `mappend` clientData r)

data ResultValue =
	ResultDatabase Database |
	ResultDeclaration Declaration |
	ResultModuleDeclaration ModuleDeclaration |
	ResultModuleId ModuleId |
	ResultModule Module |
	ResultInspectedModule InspectedModule |
	ResultProject Project |
	ResultList [ResultValue] |
	ResultMap (Map String ResultValue) |
	ResultString String |
	ResultNone

instance ToJSON ResultValue where
	toJSON (ResultDatabase db) = toJSON db
	toJSON (ResultDeclaration d) = toJSON d
	toJSON (ResultModuleDeclaration md) = toJSON md
	toJSON (ResultModuleId mid) = toJSON mid
	toJSON (ResultModule m) = toJSON m
	toJSON (ResultInspectedModule m) = toJSON m
	toJSON (ResultProject p) = toJSON p
	toJSON (ResultList l) = toJSON l
	toJSON (ResultMap m) = toJSON m
	toJSON (ResultString s) = toJSON s
	toJSON ResultNone = toJSON $ object []

instance FromJSON ResultValue where
	parseJSON v = foldr1 (<|>) [
		do
			(Object m) <- parseJSON v
			if HM.null m then return ResultNone else mzero,
		ResultDatabase <$> parseJSON v,
		ResultDeclaration <$> parseJSON v,
		ResultModuleDeclaration <$> parseJSON v,
		ResultModuleId <$> parseJSON v,
		ResultModule <$> parseJSON v,
		ResultInspectedModule <$> parseJSON v,
		ResultProject <$> parseJSON v,
		ResultList <$> parseJSON v,
		ResultMap <$> parseJSON v,
		ResultString <$> parseJSON v]

data CommandResult =
	ResultOk ResultValue |
	ResultError String (Map String ResultValue) |
	ResultProcess ((String -> IO ()) -> IO ()) |
	ResultMapFile String |
	ResultExit

instance ToJSON CommandResult where
	toJSON (ResultOk v) = toJSON v
	toJSON (ResultError e as) = object [
		"error" .= e,
		"details" .= as]
	toJSON (ResultProcess _) = object [
		"status" .= ("process" :: String)]
	toJSON (ResultMapFile nm) = object [
		"file" .= nm]
	toJSON ResultExit = object [
		"status" .= ("exit" :: String)]

instance Error CommandResult where
	noMsg = ResultError noMsg mempty
	strMsg s = ResultError s mempty

ok :: CommandResult
ok = ResultOk ResultNone

err :: String -> CommandResult
err s = ResultError s M.empty

errArgs :: String -> [(String, ResultValue)] -> CommandResult
errArgs s as = ResultError s (M.fromList as)

data WithOpts a = WithOpts {
	withOptsAct :: a,
	withOptsArgs :: IO [String] }

instance Functor WithOpts where
	fmap f (WithOpts x as) = WithOpts (f x) as

data CommandOptions = CommandOptions {
	commandDatabase :: Async Database,
	commandRoot :: FilePath }

type CommandAction = WithOpts (Int -> CommandOptions -> IO CommandResult)

commands :: [Command CommandAction]
commands = map (fmap (fmap timeout')) cmds where
	timeout' :: (CommandOptions -> IO CommandResult) -> (Int -> CommandOptions -> IO CommandResult)
	timeout' f tm copts = fmap (fromMaybe $ err "timeout") $ timeout (tm * 1000) $ f copts

	cmds = [
		-- Database commands
		cmd' ["add"] [] "add info to database" [dataArg] add',
		cmd' ["scan", "cabal"] [] "scan modules installed in cabal" [
			sandbox, ghcOpts, wait, status] scanCabal',
		cmd' ["scan", "module"] ["module name"] "scan module in cabal" [sandbox, ghcOpts] scanModule',
		cmd' ["scan"] [] "scan sources" [
			projectArg "project path or .cabal",
			fileArg "source file",
			pathArg "directory to scan for files and projects",
			ghcOpts, wait, status] scan',
		cmd' ["rescan"] [] "rescan sources" [
			projectArg "project path or .cabal",
			projectNameArg "project name",
			fileArg "source file",
			pathArg "path to rescan",
			ghcOpts, wait, status] rescan',
		cmd' ["remove"] [] "remove modules info" [
			sandbox,
			projectArg "module project",
			projectNameArg "module project by name",
			fileArg "module source file",
			moduleArg "module name",
			allFlag] remove',
		-- | Context free commands
		cmd' ["list", "modules"] [] "list modules" [
			projectArg "project to list modules from",
			projectNameArg "project name to list modules from",
			sandbox, sourced, standaloned] listModules',
		cmd_' ["list", "projects"] [] "list projects" listProjects',
		cmd' ["symbol"] ["name"] "get symbol info" [
			projectArg "related project",
			projectNameArg "related project name",
			fileArg "source file",
			moduleArg "module name",
			sandbox, sourced, standaloned] symbol',
		cmd' ["module"] [] "get module info" [
			moduleArg "module name",
			projectArg "module project",
			projectNameArg "module project name",
			fileArg "module source file",
			sandbox] modul',
		cmd_' ["project"] ["project name"] "show project info" project',
		-- Context commands
		cmd' ["whois"] ["symbol"] "get info for symbol" ctx whois',
		cmd' ["complete"] ["input"] "show completions for input" ctx complete',
		-- Dump/load commands
		cmd' ["dump", "cabal"] [] "dump cabal modules" [sandbox, cacheDir, cacheFile] dumpCabal',
		cmd' ["dump", "projects"] [] "dump projects" [projectArg "project .cabal", projectNameArg "project name", cacheDir, cacheFile] dumpProjects',
		cmd' ["dump", "files"] [] "dump standalone files" [cacheDir, cacheFile] dumpFiles',
		cmd' ["dump"] [] "dump whole database" [cacheDir, cacheFile] dump',
		cmd' ["load"] [] "load data" [cacheDir, cacheFile, dataArg, wait] load',
		-- Exit
		cmd_' ["exit"] [] "exit" $ \_ _ -> return ResultExit]

	-- Command arguments and flags
	allFlag = option_ ['a'] "all" flag "remove all"
	cacheDir = pathArg "cache path"
	cacheFile = fileArg "cache file"
	ctx = [fileArg "source file", sandbox]
	dataArg = option_ [] "data" (req "contents") "data to pass to command"
	fileArg = option_ ['f'] "file" (req "file")
	ghcOpts = option_ ['g'] "ghc" (req "ghc options") "options to pass to GHC"
	moduleArg = option_ ['m'] "module" (req "module name")
	pathArg = option_ ['p'] "path" (req "path")
	projectArg = option [] "project" ["proj"] (req "project")
	projectNameArg = option [] "project-name" ["proj-name"] (req "name")
	sandbox = option_ [] "sandbox" (noreq "path") "path to cabal sandbox"
	sourced = option_ [] "src" flag "source files"
	standaloned = option_ [] "stand" flag "standalone files"
	status = option_ ['s'] "status" flag "show status of operation, works only with --wait"
	wait = option_ ['w'] "wait" flag "wait for operation to complete"

	-- add data
	add' as _ copts = do
		dbval <- getDb copts
		res <- runErrorT $ do
			jsonData <- maybe (throwError $ err "Specify --data") return $ askOpt "data" as
			decodedData <- either
				(\err -> throwError (errArgs "Unable to decode data" [
					("why", ResultString err),
					("data", ResultString jsonData)]))
				return $
				eitherDecode $ L.pack jsonData
			let
				updateData (ResultDeclaration d) = throwError $ errArgs "Can't insert declaration" [("declaration", ResultDeclaration d)]
				updateData (ResultModuleDeclaration md) = do
					let
						ModuleId mname mloc = declarationModuleId md
						defMod = Module mname Nothing mloc [] mempty mempty
						defInspMod = Inspected InspectionNone mloc (Right defMod)
						dbmod = maybe
							defInspMod
							(\i -> i { inspectionResult = inspectionResult i <|> (Right defMod) }) $
							M.lookup mloc (databaseModules dbval)
						updatedMod = dbmod {
							inspectionResult = fmap (addDeclaration $ moduleDeclaration md) (inspectionResult dbmod) }
					update (dbVar copts) $ return $ fromModule updatedMod
				updateData (ResultModuleId (ModuleId mname mloc)) = when (M.notMember mloc $ databaseModules dbval) $
					update (dbVar copts) $ return $ fromModule $ Inspected InspectionNone mloc (Right $ Module mname Nothing mloc [] mempty mempty)
				updateData (ResultModule m) = update (dbVar copts) $ return $ fromModule $ Inspected InspectionNone (moduleLocation m) (Right m)
				updateData (ResultInspectedModule m) = update (dbVar copts) $ return $ fromModule m
				updateData (ResultProject p) = update (dbVar copts) $ return $ fromProject p
				updateData (ResultList l) = mapM_ updateData l
				updateData (ResultMap m) = mapM_ updateData $ M.elems m
				updateData (ResultString s) = throwError $ err "Can't insert string"
				updateData ResultNone = return ()
			updateData decodedData
		return $ either id (const (ResultOk ResultNone)) res
	-- scan
	scan' as _ copts = updateProcess (dbVar copts) as $
		mapM_ (\(n, f) -> forM_ (askOpts n as) (f (getGhcOpts as))) [
			("project", C.scanProject),
			("file", C.scanFile),
			("path", C.scanDirectory)]
	-- scan cabal
	scanCabal' as _ copts = do
		cabal <- askCabal copts as
		updateProcess (dbVar copts) as $ C.scanCabal (getGhcOpts as) cabal
	-- scan cabal module
	scanModule' as [] copts = return $ err "Module name not specified"
	scanModule' as ms copts = do
		cabal <- askCabal copts as
		updateProcess (dbVar copts) as $
			forM_ ms (C.scanModule (getGhcOpts as) . CabalModule cabal Nothing)
	-- rescan
	rescan' as _ copts = do
		dbval <- getDb copts
		let
			fileMap = M.fromList $ mapMaybe toPair $
				selectModules (byFile . moduleId) dbval

		(errors, filteredMods) <- liftM partitionEithers $ mapM runErrorT $ concat [
			do
				p <- askOpts "project" as
				return $ do
					p' <- getProject copts p
					return $ M.fromList $ mapMaybe toPair $
						selectModules (inProject p' . moduleId) dbval,
			do
				f <- askOpts "file" as
				return $ maybe
					(throwError $ "Unknown file: " ++ f)
					(return . M.singleton f)
					(lookupFile f dbval),
			do
				d <- askOpts "path" as
				return $ return $ M.filterWithKey (\f _ -> isParent d f) fileMap]
		let
			rescanMods = map (getInspected dbval) $
				M.elems $ if null filteredMods then fileMap else M.unions filteredMods

		if not (null errors)
			then return $ err $ intercalate ", " errors
			else updateProcess (dbVar copts) as $ C.runScan_ "rescan" "modules" $ do
				needRescan <- C.liftErrors $ filterM (changedModule dbval (getGhcOpts as) . inspectedId) rescanMods
				C.scanModules (getGhcOpts as) (map (inspectionOpts . inspection &&& inspectedId) needRescan)
	-- remove
	remove' as _ copts = errorT $ do
		dbval <- liftIO $ getDb copts
		cabal <- traverse (asCabal copts) $ askOptDef "sandbox" "" as
		proj <- askProject copts as
		file <- traverse (canonicalizePath' copts) $ askOpt "file" as
		let
			cleanAll = hasOpt "all" as
			filters = catMaybes [
				fmap inProject proj,
				fmap inFile file,
				fmap inModule (askOpt "module" as),
				fmap inCabal cabal]
			toClean = filter (allOf filters . moduleId) (allModules dbval)
			action
				| null filters && cleanAll = liftIO $ do
					modifyAsync (dbVar copts) Clear
					return ResultNone
				| null filters && not cleanAll = throwError "Specify filter or explicitely set flag --all"
				| cleanAll = throwError "--all flag can't be set with filters"
				| otherwise = liftIO $ do
					mapM_ (modifyAsync (dbVar copts) . Remove . fromModule) $ map (getInspected dbval) $ toClean
					return $ ResultList $ map (ResultModuleId . moduleId) toClean
		action
	-- list modules
	listModules' as _ copts = errorT $ do
		dbval <- liftIO $ getDb copts
		proj <- askProject copts as
		cabal <- traverse (asCabal copts) $ askOptDef "sandbox" "" as
		let
			filters = allOf $ catMaybes [
				fmap inProject proj,
				fmap inCabal cabal,
				if hasOpt "src" as then Just byFile else Nothing,
				if hasOpt "stand" as then Just standalone else Nothing]
		return $ ResultList $ map (ResultModuleId . moduleId) $ selectModules (filters . moduleId) dbval
	-- list projects
	listProjects' _ copts = do
		dbval <- getDb copts
		return $ ResultOk $ ResultList $ map ResultProject $ M.elems $ databaseProjects dbval
	-- get symbol info
	symbol' as ns copts = errorT $ do
		dbval <- liftIO $ getDb copts
		proj <- askProject copts as
		file <- traverse (canonicalizePath' copts) $ askOpt "file" as
		cabal <- traverse (asCabal copts) $ askOptDef "sandbox" "" as
		let
			filters = checkModule $ allOf $ catMaybes [
				fmap inProject proj,
				fmap inFile file,
				fmap inModule (askOpt "module" as),
				if hasOpt "src" as then Just byFile else Nothing,
				if hasOpt "stand" as then Just standalone else Nothing]
			toResult = ResultList . map ResultModuleDeclaration . filter filters
		case ns of
			[] -> return $ toResult $ allDeclarations dbval
			[nm] -> liftM toResult (findDeclaration dbval nm) `catchError` (\e ->
				throwError ("Can't find symbol: " ++ e))
			_ -> throwError "Too much arguments"
	-- get module info
	modul' as _ copts = errorT' $ do
		dbval <- liftIO $ getDb copts
		proj <- mapErrorT (fmap $ strMsg +++ id) $ askProject copts as
		cabal <- traverse (asCabal copts) $ askOptDef "sandbox" "" as
		file' <- traverse (canonicalizePath' copts) $ askOpt "file" as
		let
			filters = allOf $ catMaybes [
				fmap inProject proj,
				fmap inCabal cabal,
				fmap inFile file',
				fmap inModule (askOpt "module" as)]
		rs <- mapErrorT (fmap $ strMsg +++ id) $
			filter (filters . moduleId) <$> maybe
				(return $ allModules dbval)
				(findModule dbval)
				(askOpt "module" as)
		case rs of
			[] -> throwError $ err "Module not found"
			[m] -> return $ ResultModule m
			ms' -> throwError $ errArgs "Ambiguous modules" [("modules", ResultList $ map (ResultModuleId . moduleId) ms')]
	-- get project info
	project' [] copts = return $ err "Project name not specified"
	project' pnames copts = do
		dbval <- getDb copts
		case filter ((`elem` pnames) . projectName) $ M.elems $ databaseProjects dbval of
			[] -> return $ errArgs "Projects not found" [
				("projects", ResultList $ map ResultString pnames)]
			ps -> return $ ResultOk $ ResultList $ map ResultProject ps
	-- get detailed info about symbol in source file
	whois' as [nm] copts = errorT $ do
		dbval <- liftIO $ getDb copts
		srcFile <- maybe (throwError $ "No file specified") (canonicalizePath' copts) $ askOpt "file" as
		cabal <- getCabal copts (askOptDef "sandbox" "" as)
		liftM ResultModuleDeclaration $ whois dbval srcFile nm
	whois' as _ copts = return $ err "Invalid arguments"
	-- completion
	complete' as [] copts = complete' as [""] copts
	complete' as [input] copts = errorT $ do
		dbval <- getDb copts
		srcFile <- maybe (throwError $ "No file specified") (canonicalizePath' copts) $ askOpt "file" as
		mthis <- fileModule dbval srcFile
		cabal <- getCabal copts (askOptDef "sandbox" "" as)
		liftM (ResultList . map ResultModuleDeclaration) $ completions dbval mthis input
	complete' as _ copts = return $ err "Invalid arguments"
	-- dump cabal modules
	dumpCabal' as _ copts = do
		dbval <- getDb copts
		cabal <- getCabal copts $ askOptDef "sandbox" "" as
		let
			dat = cabalDB cabal dbval
		liftM (ResultOk . fromMaybe (ResultDatabase dat)) $ runMaybeT $ msum [
			maybeOpt "path" as $ \p -> fork (dump (p </> cabalCache cabal) dat),
			maybeOpt "file" as $ \f -> fork (dump f dat)]
	-- dump projects
	dumpProjects' as [] copts = errorT $ do
		dbval <- liftIO $ getDb copts
		ps' <- traverse (getProject copts) $ askOpts "project" as
		let
			ps = if null ps' then M.elems (databaseProjects dbval) else ps'
			dats = map (id &&& flip projectDB dbval) ps
		liftM (fromMaybe (ResultList $ map (ResultDatabase . snd) dats)) $
			runMaybeT $ msum [
				maybeOpt "path" as $ \p ->
					fork (forM_ dats $ \(proj, dat) -> (dump (p </> projectCache proj) dat)),
				maybeOpt "file" as $ \f ->
					fork (dump f (mconcat $ map snd dats))]
	dumpProjects' as _ copts = return $ err "Invalid arguments"
	-- dump files
	dumpFiles' as [] copts = do
		dbval <- getDb copts
		let
			dat = standaloneDB dbval
		liftM (ResultOk . fromMaybe (ResultDatabase dat)) $ runMaybeT $ msum [
			maybeOpt "path" as $ \p -> fork (dump (p </> standaloneCache) dat),
			maybeOpt "file" as $ \f -> fork (dump f dat)]
	dumpFiles' as _ copts = return $ err "Invalid arguments"
	-- dump database
	dump' as _ copts = do
		dbval <- getDb copts
		liftM (fromMaybe (ResultOk $ ResultDatabase dbval)) $ runMaybeT $ msum [
			do
				p <- MaybeT $ return $ askOpt "path" as
				fork $ do
					createDirectoryIfMissing True (p </> "cabal")
					createDirectoryIfMissing True (p </> "projects")
					forM_ (nub $ mapMaybe modCabal $ allModules dbval) $ \c ->
						dump
							(p </> "cabal" </> cabalCache c)
							(cabalDB c dbval)
					forM_ (M.keys $ databaseProjects dbval) $ \pr ->
						dump
							(p </> "projects" </> projectCache (project pr))
							(projectDB (project pr) dbval)
					dump (p </> standaloneCache) (standaloneDB dbval)
				return ok,
			do
				f <- MaybeT $ return $ askOpt "file" as
				fork $ dump f dbval
				return ok]
	-- load database
	load' as _ copts = do
		res <- liftM (fromMaybe (err "Specify one of: --path, --file or --data")) $ runMaybeT $ msum [
			do
				p <- MaybeT $ return $ askOpt "path" as
				forkOrWait as $ do
					cts <- liftM concat $ mapM
						(liftM
							(filter ((== ".json") . takeExtension)) .
							getDirectoryContents')
						[p, p </> "cabal", p </> "projects"]
					forM_ cts $ \c -> do
						e <- doesFileExist c
						when e $ cacheLoad (dbVar copts) (load c)
				return ok,
			do
				f <- MaybeT $ return $ askOpt "file" as
				e <- liftIO $ doesFileExist f
				forkOrWait as $ when e $ cacheLoad (dbVar copts) (load f)
				return ok,
			do
				dat <- MaybeT $ return $ askOpt "data" as
				forkOrWait as $ cacheLoad (dbVar copts) (return $ eitherDecode (L.pack dat))
				return ok]
		waitDb as (dbVar copts)
		return res

	-- Helper functions
	cmd' :: [String] -> [String] -> String -> [OptDescr Opts] -> (Opts -> [String] -> a) -> Command (WithOpts a)
	cmd' name posArgs descr as act = cmd name posArgs descr as act' where
		act' os args = WithOpts (act os args) $
			return $ name ++ args ++ optsToArgs os

	cmd_' :: [String] -> [String] -> String -> ([String] -> a) -> Command (WithOpts a)
	cmd_' name posArgs descr act = cmd_ name posArgs descr act' where
		act' args = WithOpts (act args) $
			return $ name ++ args ++ optsToArgs defaultConfig

	getGhcOpts = askOpts "ghc"

	isParent :: FilePath -> FilePath -> Bool
	isParent dir file = norm dir `isPrefixOf` norm file where
		norm = splitDirectories . normalise

	toPair :: Module -> Maybe (FilePath, Module)
	toPair m = case moduleLocation m of
		FileModule f _ -> Just (f, m)
		_ -> Nothing

	modCabal :: Module -> Maybe Cabal
	modCabal m = case moduleLocation m of
		CabalModule c _ _ -> Just c
		_ -> Nothing

	getDirectoryContents' :: FilePath -> IO [FilePath]
	getDirectoryContents' p = do
		b <- doesDirectoryExist p
		if b then liftM (map (p </>) . filter (`notElem` [".", ".."])) (getDirectoryContents p) else return []

	waitDb as db = when (hasOpt "wait" as) $ do
		putStrLn "wait for db"
		waitDbVar <- newEmptyMVar
		modifyAsync db (Action $ \d -> putStrLn "db done!" >> putMVar waitDbVar () >> return d)
		takeMVar waitDbVar

	forkOrWait as act
		| hasOpt "wait" as = liftIO act
		| otherwise = liftIO $ void $ forkIO act

	cacheLoad db act = do
		db' <- act
		case db' of
			Left e -> putStrLn e
			Right database -> update db (return database)

	getCabal :: (Applicative m, MonadIO m) => CommandOptions -> Maybe String -> m Cabal
	getCabal copts = liftM (maybe Cabal Sandbox) . traverse (canonicalizePath' copts)

	asCabal :: MonadIO m => CommandOptions -> FilePath -> m Cabal
	asCabal _ "" = return Cabal
	asCabal copts p = liftM Sandbox $ (canonicalizePath' copts) p

	askCabal :: MonadIO m => CommandOptions -> Opts -> m Cabal
	askCabal copts = maybe (return Cabal) (asCabal copts) . askOptDef "sandbox" ""

	getProject :: CommandOptions -> String -> ErrorT String IO Project
	getProject copts proj = do
		db' <- getDb copts
		proj' <- liftM addCabal $ canonicalizePath' copts proj
		let
			result =
				M.lookup proj' (databaseProjects db') <|>
				find ((== proj) . projectName) (M.elems $ databaseProjects db')
		maybe (throwError $ "Project " ++ proj ++ " not found") return result
		where
			addCabal p
				| takeExtension p == ".cabal" = p
				| otherwise = p </> (takeBaseName p <.> "cabal")

	askProject :: CommandOptions -> Opts -> ErrorT String IO (Maybe Project)
	askProject copts = traverse (getProject copts) . askOpt "project"

	getDb :: (MonadIO m) => CommandOptions -> m Database
	getDb = liftIO . readAsync . commandDatabase

	dbVar :: CommandOptions -> Async Database
	dbVar = commandDatabase

	canonicalizePath' :: MonadIO m => CommandOptions -> FilePath -> m FilePath
	canonicalizePath' copts f = liftIO $ canonicalizePath (normalise f') where
		f'
			| isRelative f = commandRoot copts </> f
			| otherwise = f

	startProcess :: Opts -> ((String -> IO ()) -> IO ()) -> IO CommandResult
	startProcess as f
		| hasOpt "wait" as = return $ ResultProcess (f . onMsg)
		| otherwise = forkIO (f $ const $ return ()) >> return ok
		where
			onMsg showMsg = if hasOpt "status" as then showMsg else (const $ return ())

	errorT :: ErrorT String IO ResultValue -> IO CommandResult
	errorT = liftM (either err ResultOk) . runErrorT

	errorT' :: ErrorT CommandResult IO ResultValue -> IO CommandResult
	errorT' = liftM (either id ResultOk) . runErrorT

	updateProcess :: Async Database -> Opts -> C.UpdateDB IO () -> IO CommandResult
	updateProcess db as act = startProcess as $ \onStatus -> C.updateDB (C.Settings db onStatus (getGhcOpts as)) act

	fork :: MonadIO m => IO () -> m ()
	fork = voidm . liftIO . forkIO

	voidm :: Monad m => m a -> m ()
	voidm act = act >> return ()

	maybeOpt :: Monad m => String -> Opts -> (String -> MaybeT m a) -> MaybeT m ResultValue
	maybeOpt n as act = do
		p <- MaybeT $ return $ askOpt n as
		act p
		return ResultNone

printMainUsage :: IO ()
printMainUsage = do
	mapM_ (putStrLn . ('\t':) . ("hsdev " ++) . C.brief) mainCommands
	putStrLn "\thsdev [--port=number] [--pretty] [--stdin] interactive command... -- send command to server, use flag stdin to pass data argument through stdin"

printUsage :: IO ()
printUsage = mapM_ (putStrLn . ('\t':) . ("hsdev " ++) . C.brief) commands

processCmd :: CommandOptions -> Int -> String -> (String -> IO ()) -> IO Bool
processCmd copts tm cmdLine printResult = processCmdArgs copts tm (split cmdLine) printResult

processCmdArgs :: CommandOptions -> Int -> [String] -> (String -> IO ()) -> IO Bool
processCmdArgs copts tm cmdArgs printResult = run (map (fmap withOptsAct) commands) (asCmd unknownCommand) (asCmd . commandError) cmdArgs tm copts >>= processResult where
	asCmd :: CommandResult -> (Int -> CommandOptions -> IO CommandResult)
	asCmd r _ _ = return r

	unknownCommand :: CommandResult
	unknownCommand = err "Unknown command"
	commandError :: [String] -> CommandResult
	commandError errs = errArgs "Command syntax error" [("what", ResultList $ map ResultString errs)]

	processResult :: CommandResult -> IO Bool
	processResult (ResultProcess act) = do
		act (printResult . showStatus)
		processResult ok
		`catch`
		processFailed
		where
			processFailed :: SomeException -> IO Bool
			processFailed e = do
				processResult $ errArgs "process throws exception" [("exception", ResultString $ show e)]
				return True

			showStatus s = L.unpack $ encode $ object ["status" .= s]

	processResult ResultExit = do
		printResult $ L.unpack $ encode ResultExit
		return False
	processResult v = do
		printResult $ L.unpack $ encode v
		return True
