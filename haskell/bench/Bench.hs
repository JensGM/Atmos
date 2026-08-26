-- | Storage micro-benchmark.
--
-- Simulates the write pattern atmos actually has: N libraries, each linked
-- once (one manifest write), then listed, then read back, then unlinked.  The
-- point is not raw throughput — it is how each backend's cost scales with the
-- number of already-linked libraries, which is where the single-file store and
-- the file-per-library store differ.
module Main (main) where

import Atmos.Store
import Atmos.Store.Files (filesStore)
import Atmos.Store.SingleFile (singleFileStore)
import Atmos.Types
import Control.Monad (forM_)
import Data.Time.Clock
import System.Directory
import System.Environment
import System.FilePath ((</>))
import Text.Printf (printf)

main :: IO ()
main = do
  args <- getArgs
  let libs = case args of (n : _) -> read n; _ -> 50
      linksPerLib = case args of (_ : n : _) -> read n; _ -> 40
      tmp = case args of (_ : _ : d : _) -> d; _ -> "/tmp/atmos-bench"
  forM_ ["files", "single-file"] $ \name -> do
    let dir = tmp </> name
    removePathForcibly dir
    createDirectoryIfMissing True dir
    let st = case name of
          "files" -> filesStore dir
          _ -> singleFileStore (dir </> "state")
    putStrLn ("== " ++ name ++ " ==")
    time "  write config" $ storeSaveConfig st (configSet "atmos_root" "/a" (configSet "dest_root" "/b" emptyConfig))
    time (printf "  link %d libs x %d links" (libs :: Int) (linksPerLib :: Int)) $
      forM_ [1 .. libs] $ \i ->
        storeWriteLib st Nothing (libName i) (manifest i linksPerLib)
    time "  list linked" $ do
      ls <- storeLinkedLibs st Nothing
      length ls `seq` pure ()
    time "  read every manifest" $
      forM_ [1 .. libs] $ \i -> do
        m <- storeReadLib st Nothing (libName i)
        maybe (pure ()) (\x -> length x `seq` pure ()) m
    time "  unlink every lib" $
      forM_ [1 .. libs] $ \i -> storeDeleteLib st Nothing (libName i)
    sz <- dirSize dir
    printf "  bytes on disk after config-only: %d\n" sz

libName :: Int -> String
libName i = "lib" ++ show i

manifest :: Int -> Int -> Manifest
manifest lib n =
  [ LinkRecord
      ("/home/user/atmos/" ++ libName lib ++ "/lib/file" ++ show j ++ ".so")
      ("/usr/local/lib/file" ++ show lib ++ "_" ++ show j ++ ".so")
  | j <- [1 .. n]
  ]

time :: String -> IO () -> IO ()
time label act = do
  t0 <- getCurrentTime
  act
  t1 <- getCurrentTime
  printf "%s: %.1f ms\n" label (realToFrac (diffUTCTime t1 t0) * 1000 :: Double)

dirSize :: FilePath -> IO Integer
dirSize p = do
  isDir <- doesDirectoryExist p
  if isDir
    then do
      es <- listDirectory p
      sum <$> mapM (dirSize . (p </>)) es
    else do
      exists <- doesFileExist p
      if exists then getFileSize p else pure 0
