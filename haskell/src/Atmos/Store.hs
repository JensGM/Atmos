-- | The storage interface atmos actually needs.
--
-- Eight operations, no queries, no joins, no transactions spanning more than
-- one library.  Every backend in @Atmos.Store.*@ implements this record; the
-- CLI never learns which one it got.
module Atmos.Store
  ( Store (..)
  , atomicWriteFile
  , syncDirectory
  ) where

import Atmos.Types
import Control.Exception (SomeException, try)
import System.FilePath (takeDirectory, (<.>))
import System.IO (IOMode (WriteMode), hSetEncoding, openFile, utf8)
import qualified System.IO as IO
import qualified System.Posix.Files as P
import qualified System.Posix.IO as P
import qualified System.Posix.Unistd as U

data Store = Store
  { storeName :: String
  , storeLoadConfig :: IO Config
  , storeSaveConfig :: Config -> IO ()
  , storeNamespaces :: IO [String]
  -- ^ user-created namespaces, not including the default view
  , storeNewNamespace :: String -> IO ()
  , storeLinkedLibs :: Namespace -> IO [String]
  , storeReadLib :: Namespace -> String -> IO (Maybe Manifest)
  , storeWriteLib :: Namespace -> String -> Manifest -> IO ()
  , storeDeleteLib :: Namespace -> String -> IO ()
  }

-- | Write @path@ so that a reader ever only sees the old or the new contents.
--
-- Temp file in the same directory, fsync, rename, fsync the directory.  The
-- final step is best-effort: wasmtime's WASI implementation rejects
-- @fd_sync@ on a directory handle (EBADF), while node's accepts it.  A failure
-- there costs durability across a machine crash, not consistency, so we carry
-- on rather than refuse to work on that runtime.
atomicWriteFile :: FilePath -> String -> IO ()
atomicWriteFile path contents = do
  let tmp = path <.> "tmp"
  h <- openFile tmp WriteMode
  hSetEncoding h utf8
  IO.hPutStr h contents
  IO.hFlush h
  fd <- P.handleToFd h -- closes the Handle, hands us the fd
  U.fileSynchronise fd
  P.closeFd fd
  P.rename tmp path
  syncDirectory (takeDirectory path)

-- | Best-effort directory fsync; see 'atomicWriteFile'.
syncDirectory :: FilePath -> IO ()
syncDirectory dir = do
  r <-
    try $ do
      fd <- P.openFd dir P.ReadOnly P.defaultFileFlags {P.directory = True}
      U.fileSynchronise fd
      P.closeFd fd
  case (r :: Either SomeException ()) of
    Right () -> pure ()
    Left _ -> pure ()
