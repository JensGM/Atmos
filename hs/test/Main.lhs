Tests for atmos

\begin{code}
module Main (main) where

import Atmos
import Fixtures
import System.FilePath ((</>))
import Test.Hspec

main :: IO ()
main = hspec $ do
  testSet
  testGetDirs
  testLink
  testUnlinked
  testUnlink
  testUnlinkFull
  testUnlinkFullKeepsEscapingLinks
  testLinkTransportsRelativeSymlink
  testLinkTransportsAbsoluteSymlink
  testLinkTransportsBrokenSymlink
  testLinkTransportsDirectorySymlink
  testUnlinkSymlinks
  testUnlinkFullSymlinks
  testVerifyCleanAfterLink
  testVerifyUnlinked
  testSetNamespaced
  testLinkNamespaced
  testFailOnUnknownNamespace
  testFailOnDuplicateNamespace
  testFailOnInvalidNamespaceName
  testLsns
  testLegacyCacheIsDefaultNamespace
\end{code}

Tests typically run against a temp cache

Config parameters are set by name and land in the cache under that
name.

\begin{code}
testSet = test' "set" "stores atmos_root and dest_root" \cache -> do
    cacheGet cache atmosRoot `shouldBe'` Nothing
    cacheGet cache destRoot `shouldBe'` Nothing
    Atmos.set cache atmosRoot "foo"
    Atmos.set cache destRoot "bar"
    cacheGet cache atmosRoot `shouldBe'` Just "foo"
    cacheGet cache destRoot `shouldBe'` Just "bar"
\end{code}

Both roots are resolved and must exist.

\begin{code}
testGetDirs = test "getDirs" "returns a resolved atmos_root and dest_root" \Env {..} -> do
    getDirs cache `shouldBe'` (atmosDir, destDir)
    isDir atmosDir `shouldBe'` True
    isDir destDir `shouldBe'` True
\end{code}

Linking records the library in the cache and symlinks its files into
dest_root. Unlinking removes that library's links and leaves the
others alone.

\begin{code}
testLink = test "link" "links a library into dest_root" \Env {..} -> do
    mktree atmosDir [("some_library/somedir/msg.txt", File "hello")]
    linked cache `shouldBe'` []
    link cache "some_library"
    linked cache `shouldBe'` ["some_library"]
    let msg = destDir </> "somedir/msg.txt"
    isLink msg `shouldBe'` True
    contents msg `shouldBe'` "hello"

testUnlinked = test "unlinked" "lists the libraries that are not linked" \Env {..} -> do
    mktree atmosDir
        [ ("some_library/somedir/msg.txt", File "hello")
        , ("another_library/lib/hello_world.py", File "print")
        ]
    unlinked cache `shouldBe'` ["another_library", "some_library"]
    link cache "some_library"
    unlinked cache `shouldBe'` ["another_library"]

testUnlink = test "unlink" "removes only the given library's links" \Env {..} -> do
    mktree atmosDir
        [ ("some_library/somedir/msg.txt", File "hello")
        , ("another_library/lib/hello_world.py", File "print")
        ]
    link cache "some_library"
    link cache "another_library"
    unlink cache "some_library"
    linked cache `shouldBe'` ["another_library"]
    exists (destDir </> "somedir/msg.txt") `shouldBe'` False
    isLink (destDir </> "lib/hello_world.py") `shouldBe'` True
\end{code}

The full variant searches dest_root for links into the library, so it
also works when the cache no longer lists it.

\begin{code}
testUnlinkFull = test "unlink --full" "removes links for a library missing from the cache" \Env {..} -> do
    mktree atmosDir
        [ ("some_library/somedir/msg.txt", File "hello")
        , ("another_library/lib/hello_world.py", File "print")
        ]
    link cache "some_library"
    link cache "another_library"
    untrack cache "some_library"
    unlink cache "some_library" `fails` NotLinked "some_library"
    linked cache `shouldBe'` ["another_library"]
    isLink (destDir </> "somedir/msg.txt") `shouldBe'` True
    isLink (destDir </> "lib/hello_world.py") `shouldBe'` True
    unlinkFull cache "some_library"
    linked cache `shouldBe'` ["another_library"]
    exists (destDir </> "somedir/msg.txt") `shouldBe'` False
    isLink (destDir </> "lib/hello_world.py") `shouldBe'` True
\end{code}

A link whose target starts inside the library but climbs back out of it
does not belong to that library.

\begin{code}
testUnlinkFullKeepsEscapingLinks =
    test "unlink --full" "keeps links that escape the library" \Env {..} -> do
        mktree atmosDir
            [ ("some_library/somedir/msg.txt", File "hello")
            , ("another_library/lib/hello_world.py", File "print")
            ]
        link cache "some_library"
        let escaping = destDir </> "escaping.txt"
        mktree destDir
            [ ("escaping.txt"
              , Link (atmosDir </> "some_library/../another_library/lib/hello_world.py")
              )
            ]
        unlinkFull cache "some_library"
        isLink escaping `shouldBe'` True
\end{code}

A symlink inside a library is recreated verbatim in dest_root instead
of being followed, so its target text survives whether it is relative,
absolute, broken, or points at a directory.

\begin{code}
testLinkTransportsRelativeSymlink = test "link" "transports a relative symlink" \Env {..} -> do
    mktree atmosDir
        [ ("symlib/regular.txt", File "real")
        , ("symlib/sub/link_inside.txt", Link "../regular.txt")
        ]
    link cache "symlib"
    let inside = destDir </> "sub/link_inside.txt"
    isLink inside `shouldBe'` True
    target inside `shouldBe'` "../regular.txt"
    contents inside `shouldBe'` "real"

testLinkTransportsAbsoluteSymlink = test "link" "transports an absolute symlink" \Env {..} -> do
    let outer = root </> "outside/outer.txt"
    mktree root [("outside/outer.txt", File "outer")]
    mktree atmosDir [("symlib/link_outside.txt", Link outer)]
    link cache "symlib"
    let outside = destDir </> "link_outside.txt"
    isLink outside `shouldBe'` True
    target outside `shouldBe'` outer
    contents outside `shouldBe'` "outer"

testLinkTransportsBrokenSymlink = test "link" "transports a broken symlink" \Env {..} -> do
    mktree atmosDir [("symlib/broken.txt", Link "nonexistent")]
    link cache "symlib"
    let broken = destDir </> "broken.txt"
    isLink broken `shouldBe'` True
    exists broken `shouldBe'` False
    target broken `shouldBe'` "nonexistent"

testLinkTransportsDirectorySymlink = test "link" "transports a directory symlink" \Env {..} -> do
    mktree atmosDir
        [ ("symlib/sub/inner.txt", File "inner")
        , ("symlib/dirlink", Link "sub")
        ]
    link cache "symlib"
    let dirlink = destDir </> "dirlink"
    isLink dirlink `shouldBe'` True
    target dirlink `shouldBe'` "sub"
    contents (dirlink </> "inner.txt") `shouldBe'` "inner"
    isLink (destDir </> "sub/inner.txt") `shouldBe'` True
    fmap length (links cache "symlib") `shouldBe'` 2
\end{code}

Transported symlinks are removed again by unlink, both from the cache
and by a full search, leaving no symlinks behind in dest_root.

\begin{code}
symlib outer =
    [ ("symlib/regular.txt", File "real")
    , ("symlib/dirlink", Link "sub")
    , ("symlib/sub/link_inside.txt", Link "../regular.txt")
    , ("symlib/sub/link_outside.txt", Link outer)
    , ("symlib/sub/broken.txt", Link "nonexistent")
    ]

testUnlinkSymlinks = test "unlink" "removes transported symlinks" \Env {..} -> do
    mktree root [("outside/outer.txt", File "outer")]
    mktree atmosDir (symlib (root </> "outside/outer.txt"))
    link cache "symlib"
    unlink cache "symlib"
    linked cache `shouldBe'` []
    leftovers destDir `shouldBe'` []

testUnlinkFullSymlinks = test "unlink --full" "removes transported symlinks" \Env {..} -> do
    mktree root [("outside/outer.txt", File "outer")]
    mktree atmosDir (symlib (root </> "outside/outer.txt"))
    link cache "symlib"
    untrack cache "symlib"
    unlinkFull cache "symlib"
    leftovers destDir `shouldBe'` []

testVerifyCleanAfterLink = test "verify" "reports nothing after linking" \Env {..} -> do
    mktree root [("outside/outer.txt", File "outer")]
    mktree atmosDir (symlib (root </> "outside/outer.txt"))
    link cache "symlib"
    verifyLinked cache `shouldBe'` []
    verifyAllLinks cache `shouldBe'` []

testVerifyUnlinked = test "verify" "reports links to an unlinked library" \Env {..} -> do
    mktree atmosDir [("some_library/somedir/msg.txt", File "hello")]
    link cache "some_library"
    verifyUnlinked cache `shouldBe'` []
    untrack cache "some_library"
    verifyUnlinked cache
        `shouldBe'` [("some_library", [destDir </> "somedir/msg.txt"])]
\end{code}

A namespace prefixes every cache key it is used with. Namespaces are
created before use, their names are validated, and unknown names are
rejected. A cache written before namespaces existed reads as the
default namespace.

\begin{code}
testSetNamespaced = test' "set" "stores a parameter under its namespace" \cache -> do
    newNamespace cache "work"
    work <- namespaceView cache "work"
    set work atmosRoot "foo"
    cacheGet work atmosRoot `shouldBe'` Just "foo"
    cacheGet cache atmosRoot `shouldBe'` Nothing

testLinkNamespaced = test "link" "links in a namespace" \Env {..} -> do
    mktree atmosDir [("mylib/file.txt", File "hello")]
    newNamespace cache "work"
    work <- namespaceView cache "work"
    set work atmosRoot atmosDir
    set work destRoot destDir
    link work "mylib"
    linked work `shouldBe'` ["mylib"]
    linked cache `shouldBe'` []
    isLink (destDir </> "file.txt") `shouldBe'` True

testFailOnUnknownNamespace = test' "namespaceView" "fails on an unknown namespace" \cache -> do
    newNamespace cache "work"
    _ <- namespaceView cache "work"
    _ <- namespaceView cache defaultNS
    namespaceView cache "typo" `fails` UnknownNamespace "typo"

testFailOnDuplicateNamespace = test' "new" "fails on a duplicate namespace" \cache -> do
    newNamespace cache "work"
    newNamespace cache "work" `fails` DuplicateNamespace "work"

testFailOnInvalidNamespaceName = test' "new" "fails on an invalid namespace name" \cache -> do
    newNamespace cache "with:colon" `fails` InvalidNamespaceName "with:colon"
    newNamespace cache "default" `fails` InvalidNamespaceName "default"

testLsns = test' "namespaces" "lists the namespaces sorted" \cache -> do
    newNamespace cache "work"
    newNamespace cache "play"
    namespaces cache `shouldBe'` ["play", "work"]

testLegacyCacheIsDefaultNamespace = test "link" "treats a cache without namespaces as the default one" \Env {..} -> do
    mktree atmosDir [("mylib/file.txt", File "hello")]
    def <- namespaceView cache defaultNS
    link def "mylib"
    linked cache `shouldBe'` ["mylib"]
    isLink (destDir </> "file.txt") `shouldBe'` True
\end{code}
