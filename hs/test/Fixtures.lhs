Fixtures shared by the test suites

\begin{code}
module Fixtures
    ( test
    , test'
    , mktree
    , capture
    , shouldBe'
    , shouldContain'
    , fails
    , failsWith
    , isLink
    , isDir
    , exists
    , target
    , contents
    , leftovers
    , Entry (..)
    , Env (..)
    ) where

import Atmos
import Control.Exception (displayException, finally)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT)
import GHC.IO.Handle (hDuplicate, hDuplicateTo)
import System.IO (hClose, hFlush, readFile', stdout)
import System.Directory (canonicalizePath, createDirectory,
                         createDirectoryIfMissing, createFileLink,
                         doesDirectoryExist, doesPathExist,
                         getSymbolicLinkTarget, pathIsSymbolicLink)
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory, withSystemTempFile)
import Test.Hspec
\end{code}

A test runs against a cache with both roots configured, or, in the
primed variant, against a bare one.

\begin{code}
test tag desc f = describe tag $ it desc $ withAtmosTestCache f
test' tag desc f = describe tag $ it desc $ withTestCache \cache _ -> f cache
\end{code}

A test body is one action, so library calls are statements and an
unexpected failure fails the test. Assertions come back lifted.

\begin{code}
action `shouldBe'` expected = action >>= liftIO . (`shouldBe` expected)

text `shouldContain'` piece = liftIO (text `shouldContain` piece)

fails action expected = failsWith action (== expected)

failsWith action predicate = do
    outcome <- liftIO (runExceptT action)
    liftIO case outcome of
        Left err | predicate err -> return ()
        Left err -> expectationFailure ("unexpected error " ++ show err)
        Right _ -> expectationFailure "expected a failure"
\end{code}

The filesystem is inspected through the same monad, so a test never
has to lift anything itself.

\begin{code}
isLink path = liftIO (pathIsSymbolicLink path)

isDir path = liftIO (doesDirectoryExist path)

exists path = liftIO (doesPathExist path)

target path = liftIO (getSymbolicLinkTarget path)

contents path = liftIO (readFile path)

leftovers dir = liftIO (symlinksUnder dir)
\end{code}

Each test gets a fresh cache in a temp directory. A failure that
reaches the fixture fails the test.

\begin{code}
withTestCache :: (Cache -> FilePath -> Atmos ()) -> IO ()
withTestCache body = withSystemTempDirectory "atmos" \tmp -> do
    outcome <- withCache (tmp </> "cache.db") \cache -> body cache tmp
    either (fail . displayException) return outcome
\end{code}

Both roots are configured in the cache and handed to the test.

\begin{code}
data Env = Env
    { cache :: Cache
    , root :: FilePath
    , atmosDir :: FilePath
    , destDir :: FilePath
    }

withAtmosTestCache :: (Env -> Atmos ()) -> IO ()
withAtmosTestCache body = withTestCache \cache tmp -> do
    root <- liftIO (canonicalizePath tmp)
    let atmosDir = root </> "atmos"
        destDir = root </> "dest"
    liftIO (createDirectory atmosDir)
    liftIO (createDirectory destDir)
    mktree atmosDir [("file", File "")]
    set cache atmosRoot atmosDir
    set cache destRoot destDir
    body Env {..}
\end{code}

A tree is built from paths, so intermediate directories are implied. A
link is created with its target written verbatim, whether or not it
resolves.

\begin{code}
data Entry = File String | Link FilePath

mktree root entries = liftIO (mapM_ create entries)
  where
    create (path, entry) = do
        let full = root </> path
        createDirectoryIfMissing True (takeDirectory full)
        case entry of
            File content -> writeFile full content
            Link content -> createFileLink content full
\end{code}

Standard output is redirected to a temp file for the duration of the
action, so what a command prints can be read back.

\begin{code}
capture action = ExceptT (withSystemTempFile "capture" \path handle -> do
    saved <- hDuplicate stdout
    hDuplicateTo handle stdout
    hClose handle
    outcome <- runExceptT action `finally` do
        hFlush stdout
        hDuplicateTo saved stdout
        hClose saved
    traverse (const (readFile' path)) outcome)
\end{code}

