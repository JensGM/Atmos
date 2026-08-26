-- | A subset of the atmos CLI, enough to exercise every storage operation and
-- every filesystem operation the real tool needs.
--
-- Two knobs exist that the Python CLI does not have, because they are what the
-- wasm evaluation is about:
--
-- > --store=files|single-file      which home-grown backend to use
-- > --link-style=absolute|relative what to write into the symlinks
module Main (main) where

import Atmos.Link
import Atmos.Store
import Atmos.Store.Files (filesStore)
import Atmos.Store.SingleFile (singleFileStore)
import Atmos.Types
import Control.Exception (handle, throwIO)
import Control.Monad (forM_, unless, when)
import Data.List (isPrefixOf, partition)
import Data.Maybe (fromMaybe)
import System.Directory
import System.Environment
import System.Exit
import System.FilePath ((</>))
import System.IO

data Options = Options
  { optStore :: String
  , optStateDir :: FilePath
  , optNamespace :: Namespace
  , optLinkStyle :: LinkStyle
  }

defaultOptions :: FilePath -> Options
defaultOptions home =
  Options
    { optStore = "files"
    , optStateDir = home </> ".atmos"
    , optNamespace = Nothing
    , optLinkStyle = Absolute
    }

main :: IO ()
main = handle onError $ do
  home <- fromMaybe "/" <$> lookupEnv "HOME"
  argv <- getArgs
  let (flags, rest) = partition ("--" `isPrefixOf`) argv
  opts <- foldMandatory (defaultOptions home) flags
  case rest of
    [] -> usage >> exitWith (ExitFailure 1)
    (cmd : args) -> run opts cmd args
  where
    onError e = do
      hPutStrLn stderr ("atmos: " ++ describe (e :: AtmosError))
      exitWith (ExitFailure 1)

describe :: AtmosError -> String
describe (CacheError m) = m
describe (ConfigError m) = m
describe (LinkError m) = m
describe (UnlinkError m) = m
describe (StoreError m) = m

foldMandatory :: Options -> [String] -> IO Options
foldMandatory = go
  where
    go o [] = pure o
    go o (f : fs) = case break (== '=') (drop 2 f) of
      ("store", '=' : v) -> go o {optStore = v} fs
      ("state-dir", '=' : v) -> go o {optStateDir = v} fs
      ("namespace", '=' : v) -> go o {optNamespace = Just v} fs
      ("link-style", '=' : "absolute") -> go o {optLinkStyle = Absolute} fs
      ("link-style", '=' : "relative") -> go o {optLinkStyle = Relative} fs
      _ -> throwIO (ConfigError ("unknown option " ++ f))

mkStore :: Options -> Store
mkStore o = case optStore o of
  "files" -> filesStore (optStateDir o)
  "single-file" -> singleFileStore (optStateDir o </> "state")
  other -> error ("unknown store " ++ other)

usage :: IO ()
usage =
  mapM_
    putStrLn
    [ "usage: atmos [--store=files|single-file] [--state-dir=DIR]"
    , "             [--namespace=NS] [--link-style=absolute|relative] COMMAND"
    , ""
    , "commands:"
    , "  set PARAM VALUE     set atmos_root or dest_root"
    , "  get PARAM           print a setting"
    , "  new NAMESPACE       create a namespace"
    , "  lsns                list namespaces"
    , "  list [linked|unlinked|links]"
    , "  link LIBRARY        symlink a library into dest_root"
    , "  unlink LIBRARY      remove a library's symlinks"
    , "  verify              check recorded links against the filesystem"
    ]

run :: Options -> String -> [String] -> IO ()
run o "set" [param, value] = do
  let st = mkStore o
  unless (param `elem` ["atmos_root", "dest_root"]) $
    throwIO (ConfigError ("unknown parameter " ++ param))
  c <- storeLoadConfig st
  storeSaveConfig st (configSet param value c)
run o "get" [param] = do
  c <- storeLoadConfig (mkStore o)
  putStrLn (fromMaybe "" (configGet param c))
run o "new" [ns] = storeNewNamespace (mkStore o) ns
run o "lsns" [] = storeNamespaces (mkStore o) >>= mapM_ putStrLn
run o "list" args = do
  let st = mkStore o
      selection = case args of (s : _) -> s; [] -> "linked"
  case selection of
    "linked" -> storeLinkedLibs st (optNamespace o) >>= mapM_ putStrLn
    "unlinked" -> do
      (atmosRoot, _) <- dirs st
      present <- existingLibraries atmosRoot
      linked <- storeLinkedLibs st (optNamespace o)
      mapM_ putStrLn [l | l <- present, l `notElem` linked]
    "links" -> do
      libs <- storeLinkedLibs st (optNamespace o)
      forM_ libs $ \lib -> do
        putStrLn (lib ++ " links:")
        recs <- fromMaybe [] <$> storeReadLib st (optNamespace o) lib
        forM_ recs $ \r ->
          putStrLn ("\t" ++ lrSource r ++ " installed to " ++ lrTarget r)
    other -> throwIO (ConfigError ("unknown selection " ++ other))
run o "link" [lib] = do
  let st = mkStore o
  (atmosRoot, destRoot) <- dirs st
  already <- storeReadLib st (optNamespace o) lib
  case already of
    Just _ -> throwIO (LinkError ("library " ++ lib ++ " already linked"))
    Nothing -> pure ()
  let libPath = atmosRoot </> lib
  isDir <- doesDirectoryExist libPath
  unless isDir $ throwIO (LinkError (lib ++ " is not a directory"))
  (recs, warnings) <- linkLibrary (optLinkStyle o) libPath destRoot
  mapM_ (hPutStrLn stderr . ("warning: " ++)) warnings
  storeWriteLib st (optNamespace o) lib recs
  putStrLn (show (length recs) ++ " links created")
run o "unlink" [lib] = do
  let st = mkStore o
  recs <- storeReadLib st (optNamespace o) lib
  case recs of
    Nothing -> throwIO (UnlinkError ("library " ++ lib ++ " not linked"))
    Just rs -> do
      warnings <- unlinkLibrary rs
      mapM_ (hPutStrLn stderr . ("warning: " ++)) warnings
      storeDeleteLib st (optNamespace o) lib
      putStrLn (show (length rs) ++ " links removed")
run o "verify" [] = do
  let st = mkStore o
  libs <- storeLinkedLibs st (optNamespace o)
  bad <- fmap concat . mapM (\lib -> do
    recs <- fromMaybe [] <$> storeReadLib st (optNamespace o) lib
    issues <- verifyManifest recs
    pure [(lib, i) | i <- issues]) $ libs
  forM_ bad $ \(lib, i) -> putStrLn (lib ++ ": " ++ show i)
  when (null bad) $ putStrLn "ok"
run _ cmd _ = throwIO (ConfigError ("unknown command " ++ cmd))

dirs :: Store -> IO (FilePath, FilePath)
dirs st = do
  c <- storeLoadConfig st
  a <- need "atmos_root" c
  d <- need "dest_root" c
  pure (a, d)
  where
    need k c = case configGet k c of
      Nothing -> throwIO (CacheError (k ++ " is not set"))
      Just v -> pure v

existingLibraries :: FilePath -> IO [String]
existingLibraries root = do
  entries <- listDirectory root
  filterDirs entries
  where
    filterDirs = go []
    go acc [] = pure (reverse acc)
    go acc (e : es) = do
      isDir <- doesDirectoryExist (root </> e)
      go (if isDir then e : acc else acc) es
