{-# LANGUAGE OverloadedStrings, ScopedTypeVariables #-}
-- Several instances write the same database at once, each holding an open
-- write transaction for 300ms.  Run five in parallel to see whether the
-- locking regime SQLite picked actually excludes them; kill one mid-run to see
-- what it leaves behind.
--
--   for i in A B C D E; do <runner> lock-race.wasm /tmp/r.db $i & done; wait
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Exception
import Control.Monad (forM_)
import Database.SQLite3
import System.Environment
import qualified Data.Text as T

main :: IO ()
main = do
  [path, wid] <- getArgs
  r <- try $ do
    db <- open (T.pack path)
    exec db "CREATE TABLE IF NOT EXISTS log (id INTEGER PRIMARY KEY AUTOINCREMENT, who TEXT)"
    exec db "BEGIN IMMEDIATE"
    forM_ [1..50::Int] $ \i ->
      exec db (T.pack ("INSERT INTO log (who) VALUES ('" ++ wid ++ "-" ++ show i ++ "')"))
    threadDelay 300000          -- hold the write transaction open for 300ms
    forM_ [51..100::Int] $ \i ->
      exec db (T.pack ("INSERT INTO log (who) VALUES ('" ++ wid ++ "-" ++ show i ++ "')"))
    exec db "COMMIT"
    close db
  case (r :: Either SomeException ()) of
    Left e  -> putStrLn (wid ++ ": ERROR " ++ takeWhile (/= '\n') (show e))
    Right _ -> putStrLn (wid ++ ": committed 100 rows")
