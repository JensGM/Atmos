{-# LANGUAGE ScopedTypeVariables #-}
-- Second-round probe: relative targets that escape a preopen, and links that
-- were created on the host (absolute) but must be inspected from inside wasm.
module Main (main) where

import Control.Exception
import System.Directory
import System.Environment
import System.FilePath ((</>))
import qualified System.Posix.Files as P

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
  let root    = case args of (r:_)   -> r; _ -> "/tmp/probe-root"
      outside = case args of (_:o:_) -> o; _ -> "/tmp/probe-outside"

  putStrLn "-- relative target that escapes upward (dest_root -> atmos_root) --"
  -- e.g. /tmp/probe-root/esc.link -> ../probe-outside/target.txt
  check "createSymbolicLink ../probe-outside/target.txt" $
    P.createSymbolicLink "../probe-outside/target.txt" (root </> "esc.link")
  checkShow "readSymbolicLink escaping" $ P.readSymbolicLink (root </> "esc.link")
  checkShow "lstat escaping" $ P.isSymbolicLink <$> P.getSymbolicLinkStatus (root </> "esc.link")
  checkShow "follow escaping (readFile)" $ readFile (root </> "esc.link")

  putStrLn "\n-- links created by the host with an ABSOLUTE target --"
  checkShow "lstat host-abs.link" $ P.isSymbolicLink <$> P.getSymbolicLinkStatus (root </> "host-abs.link")
  checkShow "readSymbolicLink host-abs.link" $ P.readSymbolicLink (root </> "host-abs.link")
  checkShow "follow host-abs.link (readFile)" $ readFile (root </> "host-abs.link")
  checkShow "doesFileExist host-abs.link" $ doesFileExist (root </> "host-abs.link")
  check "removeLink host-abs.link" $ P.removeLink (root </> "host-abs.link")

  putStrLn "\n-- host link with absolute target INSIDE the preopen --"
  checkShow "lstat host-abs-in.link" $ P.isSymbolicLink <$> P.getSymbolicLinkStatus (root </> "host-abs-in.link")
  checkShow "readSymbolicLink host-abs-in.link" $ P.readSymbolicLink (root </> "host-abs-in.link")
  checkShow "follow host-abs-in.link" $ readFile (root </> "host-abs-in.link")

  putStrLn "\n-- rename across directories --"
  check "write + rename into subdir" $ do
    writeFile (root </> "mv.tmp") "x\n"
    P.rename (root </> "mv.tmp") (root </> "lib" </> "mv.done")
  checkShow "rename to outside preopen" $ do
    writeFile (root </> "mv2.tmp") "y\n"
    P.rename (root </> "mv2.tmp") (outside </> "mv2.done")
    pure ()
