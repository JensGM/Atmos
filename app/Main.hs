module Main where

import Atmos (withCache)
import Atmos.Cli (cacheFile, runArgs, usage, usageError)
import Control.Exception (IOException, displayException, handle)
import Control.Monad (when)
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.FilePath (takeDirectory)
import System.IO (hPutStr, hPutStrLn, stderr)

main :: IO ()
main = handle failed do
    path <- cacheFile
    createDirectoryIfMissing True (takeDirectory path)
    args <- getArgs
    outcome <- withCache path \cache -> runArgs cache args
    case outcome of
        Right () -> return ()
        Left err -> do
            hPutStrLn stderr ("atmos: " ++ displayException err)
            when (usageError err) (hPutStr stderr ('\n' : usage))
            exitFailure

failed :: IOException -> IO ()
failed err = do
    hPutStrLn stderr ("atmos: " ++ displayException err)
    exitFailure
