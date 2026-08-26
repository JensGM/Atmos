-- | The part of atmos that touches the filesystem: walking a library, making
-- the symlinks, taking them away again, and checking them.
--
-- 'LinkStyle' is the one piece of new design here.  Python atmos always writes
-- an absolute target ("/usr/local/lib/libfoo.so -> /home/you/atmos/mylib/lib/libfoo.so").
-- WASI refuses to create a symlink whose target is absolute — @path_symlink@
-- returns EPERM on both wasmtime and node — so a wasm build can only produce
-- links at all if it writes relative targets.  The two styles are otherwise
-- equivalent for the host: the link resolves to the same file either way.
module Atmos.Link
  ( LinkStyle (..)
  , collectSources
  , linkLibrary
  , unlinkLibrary
  , linkTargetFor
  , relativeTo
  , Issue (..)
  , verifyManifest
  ) where

import Atmos.Types
import Control.Exception (SomeException, try)
import Control.Monad (forM)
import Data.List (sort)
import System.Directory
import System.FilePath
import qualified System.Posix.Files as P

-- | What to write into the symlink for a plain file.
data LinkStyle
  = -- | @\/usr\/local\/lib\/libfoo.so -> \/home\/you\/atmos\/mylib\/lib\/libfoo.so@
    Absolute
  | -- | @\/usr\/local\/lib\/libfoo.so -> ..\/..\/home\/you\/atmos\/mylib\/lib\/libfoo.so@
    Relative
  deriving (Eq, Show)

-- | Every file and every symlink under @root@, depth first, as absolute paths.
-- Directories are traversed but not returned: atmos recreates the directory
-- structure in the destination and links the leaves.
collectSources :: FilePath -> IO [FilePath]
collectSources root = go root
  where
    go dir = do
      entries <- sort <$> listDirectory dir
      fmap concat . forM entries $ \e -> do
        let p = dir </> e
        st <- P.getSymbolicLinkStatus p
        if P.isSymbolicLink st
          then pure [p] -- transported as-is, never followed
          else
            if P.isDirectory st
              then go p
              else pure [p]

-- | The string that goes into the new symlink.
--
-- A symlink in the library is transported verbatim, so a relative target keeps
-- resolving in the destination — that is the behaviour the README documents.
-- Anything else gets a target in the requested style.
linkTargetFor :: LinkStyle -> FilePath -> FilePath -> IO FilePath
linkTargetFor style source target = do
  st <- P.getSymbolicLinkStatus source
  if P.isSymbolicLink st
    then P.readSymbolicLink source
    else pure $ case style of
      Absolute -> source
      Relative -> relativeTo (takeDirectory target) source

-- | Collapse @.@ and @..@ lexically, without touching the filesystem.
--
-- 'canonicalizePath' is not an option: it resolves symlinks, which is the very
-- thing we are checking, and under a restricted WASI preopen it fails outright
-- on anything that leaves the sandbox.
collapse :: FilePath -> FilePath
collapse p = joinPath (reverse (foldl step [] (splitDirectories p)))
  where
    step acc "." = acc
    -- "/" is what splitDirectories yields for the root of an absolute path;
    -- ".." above the root is a no-op, as it is in the kernel.
    step (a : as) ".." | a /= ".." && a /= "/" = as
    step acc@("/" : _) ".." = acc
    step acc seg = seg : acc

-- | Path to @to@ as seen from directory @from@.  Both must be absolute.
relativeTo :: FilePath -> FilePath -> FilePath
relativeTo from to =
  case dropCommon (splitDirectories from) (splitDirectories to) of
    ([], []) -> "."
    (up, down) -> joinPath (replicate (length up) ".." ++ down)
  where
    dropCommon (a : as) (b : bs) | a == b = dropCommon as bs
    dropCommon as bs = (as, bs)

-- | Link one library into the destination.  Returns the manifest to record and
-- any warnings worth printing, mirroring the Python implementation: a target
-- that already exists is skipped rather than replaced.
linkLibrary ::
  LinkStyle ->
  -- | library root under atmos_root
  FilePath ->
  -- | dest_root
  FilePath ->
  IO (Manifest, [String])
linkLibrary style libPath destRoot = do
  sources <- collectSources libPath
  results <- forM sources $ \source -> do
    let target = destRoot </> makeRelative libPath source
    existing <- linkOrFileExists target
    if existing
      then pure (Nothing, [target ++ " already exists"])
      else do
        createDirectoryIfMissing True (takeDirectory target)
        content <- linkTargetFor style source target
        dangling <- do
          st <- try (P.getFileStatus source)
          pure $ case (st :: Either SomeException P.FileStatus) of
            Left _ -> True
            Right _ -> False
        r <- try (P.createSymbolicLink content target)
        case (r :: Either SomeException ()) of
          Left e ->
            pure
              ( Nothing
              , [ "could not link "
                    ++ target
                    ++ " -> "
                    ++ content
                    ++ ": "
                    ++ takeWhile (/= '\n') (show e)
                ]
              )
          Right () ->
            pure
              ( Just (LinkRecord source target)
              , [source ++ " does not resolve" | dangling]
              )
  pure ([r | (Just r, _) <- results], concatMap snd results)

-- | Remove the recorded links.  A recorded path that is no longer a symlink is
-- reported and left alone — atmos never deletes a real file.
unlinkLibrary :: Manifest -> IO [String]
unlinkLibrary recs = fmap concat . forM recs $ \r -> do
  let t = lrTarget r
  st <- try (P.getSymbolicLinkStatus t)
  case (st :: Either SomeException P.FileStatus) of
    Left _ -> pure [t ++ " is missing"]
    Right s
      | P.isSymbolicLink s -> P.removeLink t >> pure []
      | otherwise -> pure [t ++ " is not a symlink"]

data Issue
  = MissingSource FilePath
  | MissingLink FilePath
  | NotALink FilePath
  | Mismatch FilePath FilePath
  deriving (Eq, Show)

-- | Check a manifest against the filesystem.
verifyManifest :: Manifest -> IO [Issue]
verifyManifest recs = fmap concat . forM recs $ \(LinkRecord src tgt) -> do
  srcSt <- lstat src
  tgtSt <- lstat tgt
  case (srcSt, tgtSt) of
    (Nothing, Nothing) -> pure [MissingSource src, MissingLink tgt]
    (Nothing, Just _) -> pure [MissingSource src]
    (Just _, Nothing) -> pure [MissingLink tgt]
    (Just s, Just t)
      | not (P.isSymbolicLink t) -> pure [NotALink tgt]
      | otherwise -> do
          mismatch <- isMismatch src s tgt
          pure [Mismatch src tgt | mismatch]
  where
    lstat p = do
      r <- try (P.getSymbolicLinkStatus p)
      pure $ case (r :: Either SomeException P.FileStatus) of
        Left _ -> Nothing
        Right s -> Just s

-- | A recorded link is wrong if it no longer points where the source says it
-- should.  Transported links are compared by content, plain links by the file
-- they resolve to.
isMismatch :: FilePath -> P.FileStatus -> FilePath -> IO Bool
isMismatch src srcSt tgt
  | P.isSymbolicLink srcSt = do
      a <- readLinkSafe src
      b <- readLinkSafe tgt
      pure (a /= b)
  | otherwise = do
      content <- readLinkSafe tgt
      case content of
        Nothing -> pure True
        Just c -> do
          let resolved
                | isAbsolute c = c
                | otherwise = takeDirectory tgt </> c
          pure (collapse resolved /= collapse src)
  where
    readLinkSafe p = do
      r <- try (P.readSymbolicLink p)
      pure $ case (r :: Either SomeException FilePath) of
        Left _ -> Nothing
        Right s -> Just s

-- | @True@ if the path exists as a file, a directory, or a (possibly dangling)
-- symlink.  'doesFileExist' follows links and so reports @False@ for a dangling
-- one, which would make atmos overwrite it.
linkOrFileExists :: FilePath -> IO Bool
linkOrFileExists p = do
  r <- try (P.getSymbolicLinkStatus p)
  pure $ case (r :: Either SomeException P.FileStatus) of
    Left _ -> False
    Right _ -> True
