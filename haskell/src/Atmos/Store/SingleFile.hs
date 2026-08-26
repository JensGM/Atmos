-- | Single-file store — the other obvious home-grown option, kept so the
-- trade-off can be measured rather than argued about.
--
-- The whole state is one line-oriented file, rewritten atomically on every
-- mutation:
--
-- > config\tatmos_root\t/home/user/atmos
-- > namespace\tstaging
-- > link\tdefault\tmylib\t/home/user/atmos/mylib/lib/libfoo.so\t/usr/local/lib/libfoo.so
--
-- Strengths: one @rename@ is the entire commit protocol, and the file is
-- trivially copyable and versionable.  Weakness: every mutation rewrites every
-- record, and two concurrent @atmos link@ runs on /different/ libraries will
-- clobber each other unless a lock is added — which is precisely the cost the
-- file-per-library store avoids.
module Atmos.Store.SingleFile (singleFileStore) where

import Atmos.Codec
import Atmos.Store
import Atmos.Types
import Control.Exception (SomeException, throwIO, try)
import Control.Monad (unless)
import Data.List (sort)
import qualified Data.Map.Strict as M
import Data.Maybe (mapMaybe)
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory)

data State = State
  { stConfig :: Config
  , stNamespaces :: [String]
  , stLinks :: [(String, String, LinkRecord)]
  -- ^ (namespace-on-disk-name, library, record)
  }

singleFileStore :: FilePath -> Store
singleFileStore path =
  Store
    { storeName = "single-file"
    , storeLoadConfig = stConfig <$> load path
    , storeSaveConfig = \c -> modify path (\s -> s {stConfig = c})
    , storeNamespaces = sort . stNamespaces <$> load path
    , storeNewNamespace = \n -> do
        unless (validNamespace n) $
          throwIO (ConfigError ("invalid namespace name " ++ n))
        modifyChecked path $ \s ->
          if n `elem` stNamespaces s
            then Left (ConfigError ("namespace " ++ n ++ " already exists"))
            else Right s {stNamespaces = n : stNamespaces s}
    , storeLinkedLibs = \ns -> do
        s <- load path
        pure (dedup (sort [lib | (n, lib, _) <- stLinks s, n == nsKey ns]))
    , storeReadLib = \ns lib -> do
        s <- load path
        let recs = [r | (n, l, r) <- stLinks s, n == nsKey ns, l == lib]
        pure (if null recs then Nothing else Just recs)
    , storeWriteLib = \ns lib recs ->
        modify path $ \s ->
          s
            { stLinks =
                [t | t@(n, l, _) <- stLinks s, not (n == nsKey ns && l == lib)]
                  ++ [(nsKey ns, lib, r) | r <- recs]
            }
    , storeDeleteLib = \ns lib ->
        modify path $ \s ->
          s {stLinks = [t | t@(n, l, _) <- stLinks s, not (n == nsKey ns && l == lib)]}
    }

nsKey :: Namespace -> String
nsKey = maybe defaultNamespace id

validNamespace :: String -> Bool
validNamespace n = not (null n) && ':' `notElem` n && n /= defaultNamespace

load :: FilePath -> IO State
load path = do
  r <- try (readFile' path)
  case (r :: Either SomeException String) of
    Left _ -> pure (State emptyConfig [] [])
    Right s -> pure (unreverse (foldl' step (State emptyConfig [] []) (mapMaybe parse (lines s))))
  where
    parse l = case decodeRecord l of
      [] -> Nothing
      fs -> Just fs
    -- accumulate reversed; appending to the end of the list on every record
    -- would make loading quadratic in the number of links
    step st ("config" : k : v : _) = st {stConfig = configSet k v (stConfig st)}
    step st ["namespace", n] = st {stNamespaces = n : stNamespaces st}
    step st ["link", ns, lib, src, tgt] =
      st {stLinks = (ns, lib, LinkRecord src tgt) : stLinks st}
    step st _ = st
    unreverse st = st {stLinks = reverse (stLinks st)}

save :: FilePath -> State -> IO ()
save path st = do
  createDirectoryIfMissing True (takeDirectory path)
  atomicWriteFile path . unlines $
    [encodeRecord ["config", k, v] | (k, v) <- M.toAscList (unConfig (stConfig st))]
      ++ [encodeRecord ["namespace", n] | n <- sort (stNamespaces st)]
      ++ [ encodeRecord ["link", ns, lib, lrSource r, lrTarget r]
         | (ns, lib, r) <- stLinks st
         ]
  where
    unConfig (Config m) = m

modify :: FilePath -> (State -> State) -> IO ()
modify path f = load path >>= save path . f

modifyChecked :: FilePath -> (State -> Either AtmosError State) -> IO ()
modifyChecked path f = do
  s <- load path
  case f s of
    Left e -> throwIO e
    Right s' -> save path s'

readFile' :: FilePath -> IO String
readFile' p = do
  s <- readFile p
  length s `seq` pure s

dedup :: Eq a => [a] -> [a]
dedup (x : y : rest) | x == y = dedup (y : rest)
dedup (x : rest) = x : dedup rest
dedup [] = []
