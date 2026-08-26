{-# LANGUAGE OverloadedStrings, ScopedTypeVariables #-}
-- What SQLite's WASI build actually does: which VFS it picked, whether WAL is
-- available, whether locking excludes a second connection, whether temp files
-- and VACUUM work.  Compare the output natively and in wasm.
module Main (main) where

import Control.Exception
import Control.Monad (forM_)
import Database.SQLite3
import System.Environment
import qualified Data.Text as T

say :: String -> IO ()
say = putStrLn

probe :: String -> IO a -> (a -> String) -> IO ()
probe name act fmt =
  (act >>= \v -> say ("  ok    " ++ name ++ " = " ++ fmt v))
    `catch` \(e :: SomeException) -> say ("  FAIL  " ++ name ++ " :: " ++ takeWhile (/= '\n') (show e))

probe_ :: String -> IO a -> IO ()
probe_ name act = probe name act (const "")

query1 :: Database -> T.Text -> IO [SQLData]
query1 db sql = bracket (prepare db sql) finalize $ \st -> do
  _ <- step st
  columns st

main :: IO ()
main = do
  args <- getArgs
  let path = T.pack (case args of (p:_) -> p; _ -> "test.db")
  say ("db = " ++ T.unpack path)

  db <- open path
  say "\n-- build info --"
  probe "sqlite_version"     (query1 db "SELECT sqlite_version()") show
  probe "compile options"    (bracket (prepare db "PRAGMA compile_options") finalize collect) show
  probe "temp_store"         (query1 db "PRAGMA temp_store") show
  probe "locking_mode"       (query1 db "PRAGMA locking_mode") show

  say "\n-- schema + rollback journal --"
  probe_ "CREATE TABLE"      (exec db "CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v TEXT)")
  probe_ "INSERT x200 in txn" $ do
    exec db "BEGIN"
    forM_ [1..200::Int] $ \i ->
      exec db (T.pack ("INSERT OR REPLACE INTO kv VALUES ('k" ++ show i ++ "','v" ++ show i ++ "')"))
    exec db "COMMIT"
  probe "count"              (query1 db "SELECT count(*) FROM kv") show
  probe "integrity_check"    (query1 db "PRAGMA integrity_check") show

  say "\n-- WAL (needs shared memory / mmap) --"
  probe "PRAGMA journal_mode=WAL" (query1 db "PRAGMA journal_mode=WAL") show
  probe "write in WAL mode"       (exec db "INSERT OR REPLACE INTO kv VALUES ('wal','yes')" >> query1 db "SELECT v FROM kv WHERE k='wal'") show
  probe "back to delete mode"     (query1 db "PRAGMA journal_mode=DELETE") show

  say "\n-- concurrent writers: does file locking actually lock? --"
  db2 <- open path
  probe_ "conn1 BEGIN EXCLUSIVE" (exec db "BEGIN EXCLUSIVE")
  probe_ "conn2 write while conn1 holds EXCLUSIVE (native: SQLITE_BUSY)" $
    exec db2 "INSERT OR REPLACE INTO kv VALUES ('race','conn2')"
  probe_ "conn1 ROLLBACK" (exec db "ROLLBACK")
  close db2

  say "\n-- temp files / VACUUM --"
  probe_ "VACUUM"            (exec db "VACUUM")
  probe_ "large ORDER BY (may spill to temp)" (exec db "CREATE TEMP TABLE t AS SELECT * FROM kv ORDER BY v")

  say "\n-- durability --"
  probe "PRAGMA synchronous" (query1 db "PRAGMA synchronous") show
  close db
  say "done"
  where
    collect st = go []
      where go acc = do
              r <- step st
              case r of
                Row -> do cs <- columns st; go (acc ++ [cs])
                Done -> pure (length (acc :: [[SQLData]]))
