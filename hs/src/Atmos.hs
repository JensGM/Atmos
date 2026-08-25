module Atmos
    ( Cache
    , Atmos
    , Result
    , AtmosError (..)
    , atmosRoot
    , destRoot
    , defaultNS
    , withCache
    , set
    , cacheGet
    , getDirs
    , newNamespace
    , namespaces
    , namespaceView
    , existing
    , linked
    , unlinked
    , links
    , link
    , unlink
    , unlinkFull
    , untrack
    , verifyLinked
    , verifyUnlinked
    , verifyAllLinks
    , symlinksUnder
    , symlinksToLib
    , symlinksToAtmos
    ) where

import Control.Exception (Exception (..), onException, try)
import Control.Monad (filterM, forM_, join, unless, when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Data.List (nub, sort, (\\))
import Data.Maybe (listToMaybe)
import Database.SQLite.Simple
import Database.SQLite.Simple.QQ (sql)
import System.Directory (canonicalizePath, createDirectoryIfMissing,
                         createFileLink, doesDirectoryExist, doesPathExist,
                         getSymbolicLinkTarget, listDirectory,
                         pathIsSymbolicLink, removeFile)
import System.FilePath (isAbsolute, isDrive, joinPath, makeRelative,
                        splitDirectories, takeDirectory, (</>))
import System.IO (hPutStrLn, stderr)
import System.IO.Error (catchIOError)

atmosRoot = "atmos_root"
destRoot = "dest_root"
defaultNS = "default"

data AtmosError
    = CacheError String
    | UnknownNamespace String
    | DuplicateNamespace String
    | InvalidNamespaceName String
    | NotLinked String
    | AlreadyLinked String
    | NotADirectory String
    | DatabaseError String
    | Usage String
    | BadOption String
    deriving (Eq, Show)

instance Exception AtmosError where
    displayException err = case err of
        CacheError key -> key ++ " not set"
        UnknownNamespace ns -> "namespace " ++ ns ++ " does not exist"
        DuplicateNamespace ns -> "namespace " ++ ns ++ " already exists"
        InvalidNamespaceName ns -> "invalid namespace name " ++ ns
        NotLinked lib -> "library " ++ lib ++ " is not linked"
        AlreadyLinked lib -> "library " ++ lib ++ " is already linked"
        NotADirectory lib -> lib ++ " is not a directory"
        DatabaseError message -> "database error: " ++ message
        Usage command -> "bad usage of " ++ command
        BadOption message -> message

type Result = Either AtmosError

type Atmos = ExceptT AtmosError IO

data Cache = Cache Connection String

db :: IO a -> Atmos a
db action = ExceptT (fmap convert (try action))
  where
    convert (Right value) = Right value
    convert (Left err) = Left (DatabaseError (show (err :: SQLError)))

transaction :: Connection -> Atmos a -> Atmos a
transaction conn body = do
    db (execute_ conn "BEGIN")
    outcome <- db (runExceptT body `onException` execute_ conn "ROLLBACK")
    case outcome of
        Right value -> db (execute_ conn "COMMIT") >> return value
        Left err -> db (execute_ conn "ROLLBACK") >> throwE err

withCache :: FilePath -> (Cache -> Atmos a) -> IO (Result a)
withCache path body = fmap join (runExceptT (db session))
  where
    session = withConnection path \conn ->
        runExceptT (ensureSchema conn >> body (Cache conn defaultNS))

ensureSchema :: Connection -> Atmos ()
ensureSchema conn = mapM_ (db . execute_ conn)
    [ [sql| CREATE TABLE IF NOT EXISTS config (namespace TEXT, key TEXT, value TEXT, PRIMARY KEY (namespace, key)) |]
    , [sql| CREATE TABLE IF NOT EXISTS namespaces (name TEXT PRIMARY KEY) |]
    , [sql| CREATE TABLE IF NOT EXISTS libraries (namespace TEXT, library TEXT, PRIMARY KEY (namespace, library)) |]
    , [sql| CREATE TABLE IF NOT EXISTS links (namespace TEXT, library TEXT, src TEXT, dst TEXT) |]
    ]

set :: Cache -> String -> String -> Atmos ()
set (Cache conn ns) key value = db (execute conn q (ns, key, value)) where
    q = [sql| INSERT OR REPLACE INTO config (namespace, key, value) VALUES (?, ?, ?) |]

cacheGet :: Cache -> String -> Atmos (Maybe String)
cacheGet (Cache conn ns) key = do
    rows <- db (query conn q (ns, key))
    return (fromOnly <$> listToMaybe rows)
  where
    q = [sql| SELECT value FROM config WHERE namespace = ? AND key = ? |]

filesUnder :: FilePath -> IO [FilePath]
filesUnder dir = listDirectory dir >>= fmap concat . mapM (walk . (dir </>))

walk :: FilePath -> IO [FilePath]
walk path = do
    isLink <- pathIsSymbolicLink path
    isDir <- doesDirectoryExist path
    if isDir && not isLink then filesUnder path else return [path]

occupied :: FilePath -> IO Bool
occupied path = do
    exists <- doesPathExist path
    isLink <- pathIsSymbolicLink path `catchIOError` const (return False)
    return (exists || isLink)

warn :: String -> IO ()
warn message = hPutStrLn stderr ("warning: " ++ message)

available :: FilePath -> IO Bool
available target = do
    taken <- occupied target
    when taken (warn (target ++ " already exists"))
    return (not taken)

createLink :: FilePath -> FilePath -> IO ()
createLink source target = do
    createDirectoryIfMissing True (takeDirectory target)
    isLink <- pathIsSymbolicLink source
    resolves <- doesPathExist source
    unless resolves (warn (source ++ " does not resolve"))
    content <- if isLink then getSymbolicLinkTarget source else return source
    createFileLink content target

track :: Cache -> String -> [(FilePath, FilePath)] -> Atmos ()
track (Cache conn ns) lib records = transaction conn do
    db (execute conn addLibrary (ns, lib))
    forM_ records \(src, dst) -> db (execute conn addLink (ns, lib, src, dst))
  where
    addLibrary = [sql| INSERT INTO libraries (namespace, library) VALUES (?, ?) |]
    addLink = [sql| INSERT INTO links (namespace, library, src, dst) VALUES (?, ?, ?, ?) |]

link :: Cache -> String -> Atmos ()
link cache lib = do
    (atmos, dest) <- getDirs cache
    known <- linked cache
    when (lib `elem` known) (throwE (AlreadyLinked lib))
    let libPath = atmos </> lib
    isDir <- liftIO (doesDirectoryExist libPath)
    unless isDir (throwE (NotADirectory lib))
    sources <- liftIO (filesUnder libPath)
    let target source = dest </> makeRelative libPath source
    records <- liftIO (filterM (available . snd) [(s, target s) | s <- sources])
    liftIO (mapM_ (uncurry createLink) records)
    track cache lib records

removeLink :: FilePath -> IO ()
removeLink path = do
    isLink <- isSymlink path
    if isLink then removeFile path else warn (path ++ " is not a symlink")

untrack :: Cache -> String -> Atmos ()
untrack (Cache conn ns) lib = transaction conn do
    db (execute conn dropLinks (ns, lib))
    db (execute conn dropLibrary (ns, lib))
  where
    dropLinks = [sql| DELETE FROM links WHERE namespace = ? AND library = ? |]
    dropLibrary = [sql| DELETE FROM libraries WHERE namespace = ? AND library = ? |]

unlink :: Cache -> String -> Atmos ()
unlink cache lib = do
    known <- linked cache
    unless (lib `elem` known) (throwE (NotLinked lib))
    recorded <- links cache lib
    liftIO (mapM_ (removeLink . snd) recorded)
    untrack cache lib

symlinksUnder :: FilePath -> IO [FilePath]
symlinksUnder dir = filterM isSymlink =<< filesUnder dir

isSymlink :: FilePath -> IO Bool
isSymlink path = pathIsSymbolicLink path `catchIOError` const (return False)

symlinksToLib :: Cache -> String -> Atmos [FilePath]
symlinksToLib cache lib = do
    (atmos, dest) <- getDirs cache
    candidates <- liftIO (symlinksUnder dest)
    liftIO (filterM (pointsInto (atmos </> lib) dest) candidates)

normpath :: FilePath -> FilePath
normpath = joinPath . reverse . foldl step [] . splitDirectories
  where
    step acc ".." = case acc of
        (top : rest)
            | isDrive top -> acc
            | top /= ".." -> rest
        _ -> ".." : acc
    step acc "." = acc
    step acc part = part : acc

contains :: FilePath -> FilePath -> Bool
contains root path = makeRelative root path /= path

pointsInto :: FilePath -> FilePath -> FilePath -> IO Bool
pointsInto libPath dest candidate = do
    content <- getSymbolicLinkTarget candidate
    if isAbsolute content && contains libPath (normpath content)
        then return True
        else transported libPath dest candidate content

transported :: FilePath -> FilePath -> FilePath -> FilePath -> IO Bool
transported libPath dest candidate content = do
    let mirror = libPath </> makeRelative dest candidate
    isLink <- isSymlink mirror
    if isLink then (== content) <$> getSymbolicLinkTarget mirror else return False

unlinkFull :: Cache -> String -> Atmos ()
unlinkFull cache lib = do
    recorded <- map snd <$> links cache lib
    scanned <- symlinksToLib cache lib
    liftIO (mapM_ removeLink (nub (recorded ++ scanned)))
    untrack cache lib

linked :: Cache -> Atmos [String]
linked (Cache conn ns) = map fromOnly <$> db (query conn q (Only ns)) where
    q = [sql| SELECT library FROM libraries WHERE namespace = ? ORDER BY library |]

unlinked :: Cache -> Atmos [String]
unlinked cache = do
    (atmos, _) <- getDirs cache
    libs <- liftIO (existing atmos)
    known <- linked cache
    return (sort (libs \\ known))

links :: Cache -> String -> Atmos [(FilePath, FilePath)]
links (Cache conn ns) lib = db (query conn q (ns, lib)) where
    q = [sql| SELECT src, dst FROM links WHERE namespace = ? AND library = ? |]

verifyLinked :: Cache -> Atmos [(String, [String])]
verifyLinked cache = do
    known <- linked cache
    found <- mapM libIssues known
    return (filter (not . null . snd) found)
  where
    libIssues lib = (,) lib . concat <$> (liftIO . mapM recordIssues =<< links cache lib)

recordIssues :: (FilePath, FilePath) -> IO [String]
recordIssues (src, dst) = do
    srcThere <- occupied src
    dstThere <- occupied dst
    dstLink <- isSymlink dst
    mism <- mismatch src dst
    return $ concat
        [ ["missing source " ++ src | not srcThere]
        , ["missing link " ++ dst | not dstThere]
        , [dst ++ " is not a symlink" | not dstLink]
        , ["mismatched link " ++ dst | mism]
        ]

mismatch :: FilePath -> FilePath -> IO Bool
mismatch src dst = do
    dstLink <- isSymlink dst
    srcLink <- isSymlink src
    if not dstLink
        then return False
        else if srcLink
            then (/=) <$> getSymbolicLinkTarget dst <*> getSymbolicLinkTarget src
            else (/=) <$> canonicalizePath dst <*> canonicalizePath src

verifyUnlinked :: Cache -> Atmos [(String, [FilePath])]
verifyUnlinked cache = do
    libs <- unlinked cache
    (atmos, dest) <- getDirs cache
    candidates <- liftIO (symlinksUnder dest)
    found <- liftIO (mapM (\lib -> (,) lib <$> stale atmos dest candidates lib) libs)
    return (filter (not . null . snd) found)
  where
    stale atmos dest candidates lib =
        filterM (pointsInto (atmos </> lib) dest) candidates

existing :: FilePath -> IO [String]
existing atmos = filterM (doesDirectoryExist . (atmos </>)) =<< listDirectory atmos

symlinksToAtmos :: Cache -> Atmos [FilePath]
symlinksToAtmos cache = do
    (atmos, dest) <- getDirs cache
    libs <- liftIO (existing atmos)
    candidates <- liftIO (symlinksUnder dest)
    liftIO (filterM (intoAtmos atmos dest libs) candidates)

intoAtmos :: FilePath -> FilePath -> [String] -> FilePath -> IO Bool
intoAtmos atmos dest libs candidate = do
    content <- getSymbolicLinkTarget candidate
    if isAbsolute content && contains atmos (normpath content)
        then return True
        else or <$> mapM (\lib -> transported (atmos </> lib) dest candidate content) libs

verifyAllLinks :: Cache -> Atmos [String]
verifyAllLinks cache = do
    known <- linked cache
    claimed <- concat <$> mapM (fmap (map snd) . links cache) known
    found <- symlinksToAtmos cache
    return $ map ("unclaimed link " ++) (found \\ claimed)
        ++ map ("missing link " ++) (claimed \\ found)

newNamespace :: Cache -> String -> Atmos ()
newNamespace cache@(Cache conn _) name = do
    when (':' `elem` name || name == defaultNS) (throwE (InvalidNamespaceName name))
    known <- namespaces cache
    when (name `elem` known) (throwE (DuplicateNamespace name))
    db (execute conn [sql| INSERT INTO namespaces (name) VALUES (?) |] (Only name))

namespaces :: Cache -> Atmos [String]
namespaces (Cache conn _) =
    map fromOnly <$> db (query_ conn [sql| SELECT name FROM namespaces ORDER BY name |])

namespaceView :: Cache -> String -> Atmos Cache
namespaceView cache@(Cache conn _) name = do
    known <- namespaces cache
    unless (name == defaultNS || name `elem` known) (throwE (UnknownNamespace name))
    return (Cache conn name)

getDirs :: Cache -> Atmos (FilePath, FilePath)
getDirs cache = (,) <$> root atmosRoot <*> root destRoot
  where
    root key = cacheGet cache key >>= maybe (missing key) (liftIO . canonicalizePath)
    missing key = throwE (CacheError key)
