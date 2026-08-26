-- | File-per-library store — the recommended backend.
--
-- Layout under the state directory (default @~\/.atmos@):
--
-- > config                              key = value, one per line
-- > ns/default/linked/<lib>.links       one <source>\t<target> record per line
-- > ns/<name>/                          created by `atmos new -t <name>`
-- > ns/<name>/linked/<lib>.links
--
-- Why this shape:
--
--   * @link@ and @unlink@ each rewrite exactly one file, so the unit of
--     atomicity matches the unit of work.  Linking two different libraries
--     concurrently needs no lock at all — they touch disjoint files.
--   * A namespace is a directory.  Creating one is @mkdir@; listing them is
--     @readdir@.  There is no schema to migrate when the next feature lands.
--   * A half-finished @link@ leaves a @.tmp@ file that nothing reads, never a
--     wedged lock — contrast the stale @db.lock@ directory SQLite's WASI
--     build leaves behind when a process is killed mid-transaction.
--   * @git diff@, @grep@ and @rm@ are valid recovery tools.
module Atmos.Store.Files (filesStore) where

import Atmos.Codec
import Atmos.Store
import Atmos.Types
import Control.Exception (SomeException, throwIO, try)
import Control.Monad (filterM, unless)
import Data.List (isSuffixOf, sort)
import qualified Data.Map.Strict as M
import Data.Maybe (mapMaybe)
import System.Directory
import System.FilePath (takeFileName, (</>))

filesStore :: FilePath -> Store
filesStore dir =
  Store
    { storeName = "files"
    , storeLoadConfig = loadConfig dir
    , storeSaveConfig = saveConfig dir
    , storeNamespaces = namespaces dir
    , storeNewNamespace = newNamespace dir
    , storeLinkedLibs = linkedLibs dir
    , storeReadLib = readLib dir
    , storeWriteLib = writeLib dir
    , storeDeleteLib = deleteLib dir
    }

configPath :: FilePath -> FilePath
configPath dir = dir </> "config"

nsDir :: FilePath -> Namespace -> FilePath
nsDir dir ns = dir </> "ns" </> percentEncode (maybe defaultNamespace id ns)

linkedDir :: FilePath -> Namespace -> FilePath
linkedDir dir ns = nsDir dir ns </> "linked"

libPath :: FilePath -> Namespace -> String -> FilePath
libPath dir ns lib = linkedDir dir ns </> (percentEncode lib ++ ".links")

--------------------------------------------------------------------------------
-- config

loadConfig :: FilePath -> IO Config
loadConfig dir = do
  r <- try (readFile' (configPath dir))
  case (r :: Either SomeException String) of
    Left _ -> pure emptyConfig
    Right s -> pure (Config (M.fromList (mapMaybe parseLine (lines s))))
  where
    parseLine l = case decodeRecord l of
      [k, v] -> Just (k, v)
      _ -> Nothing

saveConfig :: FilePath -> Config -> IO ()
saveConfig dir (Config m) = do
  createDirectoryIfMissing True dir
  atomicWriteFile (configPath dir) $
    unlines [encodeRecord [k, v] | (k, v) <- M.toAscList m]

--------------------------------------------------------------------------------
-- namespaces

namespaces :: FilePath -> IO [String]
namespaces dir = do
  let root = dir </> "ns"
  exists <- doesDirectoryExist root
  if not exists
    then pure []
    else do
      es <- listDirectory root
      dirs <- filterM (doesDirectoryExist . (root </>)) es
      pure (sort [n | e <- dirs, let n = percentDecode e, n /= defaultNamespace])

newNamespace :: FilePath -> String -> IO ()
newNamespace dir name = do
  unless (validNamespace name) $
    throwIO (ConfigError ("invalid namespace name " ++ name))
  let d = nsDir dir (Just name)
  exists <- doesDirectoryExist d
  if exists
    then throwIO (ConfigError ("namespace " ++ name ++ " already exists"))
    else createDirectoryIfMissing True (d </> "linked")

validNamespace :: String -> Bool
validNamespace n = not (null n) && ':' `notElem` n && n /= defaultNamespace

--------------------------------------------------------------------------------
-- manifests

linkedLibs :: FilePath -> Namespace -> IO [String]
linkedLibs dir ns = do
  let d = linkedDir dir ns
  exists <- doesDirectoryExist d
  if not exists
    then pure []
    else do
      es <- listDirectory d
      pure $
        sort
          [ percentDecode (dropSuffix ".links" (takeFileName e))
          | e <- es
          , ".links" `isSuffixOf` e
          ]

readLib :: FilePath -> Namespace -> String -> IO (Maybe Manifest)
readLib dir ns lib = do
  r <- try (readFile' (libPath dir ns lib))
  case (r :: Either SomeException String) of
    Left _ -> pure Nothing
    Right s -> pure (Just (mapMaybe parse (lines s)))
  where
    parse l = case decodeRecord l of
      [src, tgt] -> Just (LinkRecord src tgt)
      _ -> Nothing

writeLib :: FilePath -> Namespace -> String -> Manifest -> IO ()
writeLib dir ns lib recs = do
  createDirectoryIfMissing True (linkedDir dir ns)
  atomicWriteFile (libPath dir ns lib) $
    unlines [encodeRecord [lrSource r, lrTarget r] | r <- recs]

deleteLib :: FilePath -> Namespace -> String -> IO ()
deleteLib dir ns lib = do
  let p = libPath dir ns lib
  exists <- doesFileExist p
  if exists
    then removeFile p >> syncDirectory (linkedDir dir ns)
    else pure ()

--------------------------------------------------------------------------------

-- | Strict read: we must not hold a lazy handle open across the rename in
-- 'atomicWriteFile'.
readFile' :: FilePath -> IO String
readFile' p = do
  s <- readFile p
  length s `seq` pure s

dropSuffix :: String -> String -> String
dropSuffix suf s
  | suf `isSuffixOf` s = take (length s - length suf) s
  | otherwise = s
