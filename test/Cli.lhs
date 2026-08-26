Tests for the atmos command line

\begin{code}
module Main (main) where

import Atmos
import Atmos.Cli
import Fixtures
import System.FilePath (takeDirectory, takeFileName, (</>))
import Test.Hspec

main :: IO ()
main = hspec $ do
  testSet
  testLsns
  testListLinked
  testListUnlinked
  testListLinks
  testUnlinkCli
  testUnlinkFullCli
  testNamespacedCli
  testVerifyClean
  testVerifyReportsLinksToUnlinked
  testFailOnMissingNamespaceName
  testFailOnUnknownParam
  testFailOnUnknownSelection
  testFailOnUnknownOption
  testHelpListsTheCommands
  testVersion
  testSubcommandHelp
  testCacheFileLocation
\end{code}

The set command writes its parameter to the cache.

\begin{code}
testSet = test' "set" "stores the given parameter" \cache -> do
    runArgs cache ["set", atmosRoot, "foo"]
    cacheGet cache atmosRoot `shouldBe'` Just "foo"
\end{code}

Namespaces are created by name and listed sorted, one per line.

\begin{code}
testLsns = test' "lsns" "prints the namespaces sorted" \cache -> do
    runArgs cache ["new", "-t", "work"]
    runArgs cache ["new", "-t", "play"]
    capture (runArgs cache ["lsns"]) `shouldBe'` "play\nwork\n"
\end{code}

The list command reports linked libraries by default, and can report
the unlinked ones or every individual link instead.

\begin{code}
testListLinked = test "list" "prints the linked libraries" \Env {..} -> do
    mktree atmosDir [("some_library/somedir/msg.txt", File "hello")]
    link cache "some_library"
    capture (runArgs cache ["list"]) `shouldBe'` "some_library\n"

testListUnlinked = test "list" "prints the unlinked libraries" \Env {..} -> do
    mktree atmosDir
        [ ("some_library/somedir/msg.txt", File "hello")
        , ("another_library/lib/hello_world.py", File "print")
        ]
    link cache "some_library"
    capture (runArgs cache ["list", "unlinked"]) `shouldBe'` "another_library\n"

testListLinks = test "list" "prints where each file is installed" \Env {..} -> do
    mktree atmosDir [("some_library/somedir/msg.txt", File "hello")]
    link cache "some_library"
    let src = atmosDir </> "some_library/somedir/msg.txt"
        dst = destDir </> "somedir/msg.txt"
    capture (runArgs cache ["list", "links"])
        `shouldBe'` ("some_library links:\n\t" ++ src ++ " installed to " ++ dst ++ "\n")

testFailOnUnknownSelection = test' "list" "fails on an unknown selection" \cache ->
    runArgs cache ["list", "bogus"] `fails` Usage "list"

testFailOnUnknownOption = test' "atmos" "fails on an unknown option" \cache -> do
    runArgs cache ["link", "--bogus", "mylib"] `failsWith` badOption

badOption (BadOption _) = True
badOption _ = False

testHelpListsTheCommands = test' "atmos" "prints the commands for --help" \cache -> do
    out <- capture (runArgs cache ["--help"])
    out `shouldContain'` "usage: atmos"
    mapM_ (shouldContain' out) ["new", "lsns", "set", "list", "link", "unlink", "verify"]

testVersion = test' "atmos" "prints the package version" \cache ->
    capture (runArgs cache ["--version"]) `shouldBe'` (atmosVersion ++ "\n")

testSubcommandHelp = test' "atmos" "prints help for a single command" \cache -> do
    out <- capture (runArgs cache ["unlink", "--help"])
    out `shouldContain'` "unlink"
    out `shouldContain'` "--full"
\end{code}

The database gets a directory to itself, so the files sqlite writes
beside it stay out of the home directory.

\begin{code}
testCacheFileLocation = describe "cacheFile" $ it "sits in a directory of its own" $ do
    path <- cacheFile
    takeFileName path `shouldBe` "atmos.db"
    takeFileName (takeDirectory path) `shouldBe` ".atmos.d"
\end{code}

Linking and unlinking go through the same commands, with the full
search behind a flag, and every command but new and lsns accepts a
namespace.

\begin{code}
testUnlinkCli = test "unlink" "removes a library's links" \Env {..} -> do
    mktree atmosDir [("mylib/file.txt", File "hello")]
    runArgs cache ["link", "mylib"]
    linked cache `shouldBe'` ["mylib"]
    runArgs cache ["unlink", "mylib"]
    linked cache `shouldBe'` []
    leftovers destDir `shouldBe'` []

testUnlinkFullCli = test "unlink --full" "removes unrecorded links" \Env {..} -> do
    mktree atmosDir [("mylib/file.txt", File "hello")]
    runArgs cache ["link", "mylib"]
    untrack cache "mylib"
    runArgs cache ["unlink", "mylib", "--full"]
    leftovers destDir `shouldBe'` []

testNamespacedCli = test "link" "links in the given namespace" \Env {..} -> do
    mktree atmosDir [("mylib/file.txt", File "hello")]
    runArgs cache ["new", "-t", "work"]
    runArgs cache ["set", "-t", "work", atmosRoot, atmosDir]
    runArgs cache ["set", "-t", "work", destRoot, destDir]
    runArgs cache ["link", "-t", "work", "mylib"]
    capture (runArgs cache ["list", "-t", "work"]) `shouldBe'` "mylib\n"
    capture (runArgs cache ["list"]) `shouldBe'` ""
\end{code}

Verify says nothing when everything checks out, and names the library
each problem belongs to otherwise.

\begin{code}
testVerifyClean = test "verify" "prints nothing when the links are sound" \Env {..} -> do
    mktree atmosDir [("mylib/file.txt", File "hello")]
    link cache "mylib"
    capture (runArgs cache ["verify"]) `shouldBe'` ""

testVerifyReportsLinksToUnlinked =
    test "verify" "reports links left by an unlinked library" \Env {..} -> do
        mktree atmosDir [("mylib/file.txt", File "hello")]
        link cache "mylib"
        untrack cache "mylib"
        out <- capture (runArgs cache ["verify"])
        out `shouldContain'` "links to unlinked library mylib:"
        out `shouldContain'` "unclaimed link"
\end{code}

The new command has no default namespace to fall back on.

\begin{code}
testFailOnMissingNamespaceName = test' "new" "fails without a namespace name" \cache ->
    runArgs cache ["new"] `fails` Usage "new"
\end{code}

Only the known parameters can be set.

\begin{code}
testFailOnUnknownParam = test' "set" "fails on an unknown parameter" \cache -> do
    runArgs cache ["set", "foo", "bar"] `fails` Usage "set"
    cacheGet cache "foo" `shouldBe'` Nothing
\end{code}
