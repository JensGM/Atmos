{-# LANGUAGE ScopedTypeVariables #-}
-- Probe WASI filesystem capabilities that atmos depends on.
module Main (main) where

import Control.Exception
import System.Directory
import System.Environment
import System.FilePath ((</>))
import qualified System.Posix.Files as P
import qualified System.Posix.IO as P
import qualified System.Posix.Directory as P
import qualified System.Posix.Unistd as U

check :: String -> IO a -> IO ()
check name act =
  (act >> putStrLn ("  ok    " ++ name))
    `catch` \(e :: SomeException) -> putStrLn ("  FAIL  " ++ name ++ " :: " ++ oneline e)

checkShow :: Show a => String -> IO a -> IO ()
checkShow name act =
  (act >>= \v -> putStrLn ("  ok    " ++ name ++ " = " ++ show v))
    `catch` \(e :: SomeException) -> putStrLn ("  FAIL  " ++ name ++ " :: " ++ oneline e)

oneline :: SomeException -> String
oneline = takeWhile (/= '\n') . show

main :: IO ()
main = do
  args <- getArgs
  let root = case args of (r:_) -> r; _ -> "/tmp/atmos-probe"
      outside = case args of (_:o:_) -> o; _ -> "/tmp/atmos-outside"
  putStrLn ("root    = " ++ root)
  putStrLn ("outside = " ++ outside)

  putStrLn "\n-- basic --"
  check "createDirectoryIfMissing (nested)" $ createDirectoryIfMissing True (root </> "lib" </> "sub")
  check "writeFile" $ writeFile (root </> "lib" </> "sub" </> "f.txt") "hello\n"
  checkShow "readFile" $ readFile (root </> "lib" </> "sub" </> "f.txt")
  checkShow "getCurrentDirectory" getCurrentDirectory
  checkShow "listDirectory root" $ listDirectory root
  checkShow "getFileSize" $ getFileSize (root </> "lib" </> "sub" </> "f.txt")
  checkShow "getModificationTime" $ getModificationTime (root </> "lib" </> "sub" </> "f.txt")

  putStrLn "\n-- symlinks (relative target) --"
  check "createSymbolicLink rel" $ P.createSymbolicLink "sub/f.txt" (root </> "lib" </> "rel.link")
  checkShow "readSymbolicLink rel" $ P.readSymbolicLink (root </> "lib" </> "rel.link")
  checkShow "isSymbolicLink (lstat)" $ P.isSymbolicLink <$> P.getSymbolicLinkStatus (root </> "lib" </> "rel.link")
  checkShow "follow rel symlink (readFile)" $ readFile (root </> "lib" </> "rel.link")

  putStrLn "\n-- symlinks (absolute target, inside sandbox root) --"
  check "createSymbolicLink abs-inside" $
    P.createSymbolicLink (root </> "lib" </> "sub" </> "f.txt") (root </> "abs-inside.link")
  checkShow "readSymbolicLink abs-inside" $ P.readSymbolicLink (root </> "abs-inside.link")
  checkShow "follow abs-inside" $ readFile (root </> "abs-inside.link")

  putStrLn "\n-- symlinks (absolute target, different preopen / outside) --"
  check "mkdir outside" $ createDirectoryIfMissing True outside
  check "write outside file" $ writeFile (outside </> "target.txt") "outside\n"
  check "createSymbolicLink abs-outside" $
    P.createSymbolicLink (outside </> "target.txt") (root </> "abs-outside.link")
  checkShow "readSymbolicLink abs-outside" $ P.readSymbolicLink (root </> "abs-outside.link")
  checkShow "lstat abs-outside" $ P.isSymbolicLink <$> P.getSymbolicLinkStatus (root </> "abs-outside.link")
  checkShow "follow abs-outside (readFile)" $ readFile (root </> "abs-outside.link")
  checkShow "stat abs-outside (follows)" $ P.isRegularFile <$> P.getFileStatus (root </> "abs-outside.link")

  putStrLn "\n-- dangling symlink --"
  check "createSymbolicLink dangling" $ P.createSymbolicLink "does-not-exist" (root </> "dangling.link")
  checkShow "lstat dangling" $ P.isSymbolicLink <$> P.getSymbolicLinkStatus (root </> "dangling.link")
  checkShow "doesFileExist dangling (should be False)" $ doesFileExist (root </> "dangling.link")
  check "removeLink dangling" $ P.removeLink (root </> "dangling.link")

  putStrLn "\n-- atomic replace & durability --"
  check "write tmp + rename over" $ do
    writeFile (root </> "state.tmp") "v2\n"
    P.rename (root </> "state.tmp") (root </> "state")
  checkShow "read after rename" $ readFile (root </> "state")
  check "fsync file" $ do
    fd <- P.openFd (root </> "state") P.ReadOnly P.defaultFileFlags
    U.fileSynchronise fd
    P.closeFd fd
  check "fsync directory" $ do
    fd <- P.openFd root P.ReadOnly P.defaultFileFlags{P.directory=True}
    U.fileSynchronise fd
    P.closeFd fd
  check "O_EXCL create (lock file)" $ do
    fd <- P.openFd (root </> "lock") P.WriteOnly
            P.defaultFileFlags{P.exclusive=True, P.creat=Just 0o600}
    P.closeFd fd
  checkShow "O_EXCL create again (should FAIL = lock works)" $ do
    fd <- P.openFd (root </> "lock") P.WriteOnly
            P.defaultFileFlags{P.exclusive=True, P.creat=Just 0o600}
    P.closeFd fd
    pure ()

  putStrLn "\n-- process / environment --"
  checkShow "getEnvironment size" $ length <$> getEnvironment
  checkShow "lookupEnv HOME" $ lookupEnv "HOME"
  checkShow "canonicalizePath root" $ canonicalizePath root

  putStrLn "\n-- recursive walk (what `atmos link` does) --"
  checkShow "walk" $ walk root
  where
    walk :: FilePath -> IO Int
    walk p = do
      es <- listDirectory p
      cnts <- mapM (\e -> do
        let q = p </> e
        st <- P.getSymbolicLinkStatus q
        if P.isDirectory st then walk q else pure (1::Int)) es
      pure (1 + sum cnts)
