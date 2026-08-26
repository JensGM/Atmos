module Atmos.Cli where

import Atmos
import Control.Monad (forM_)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (throwE)
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Version (showVersion)
import Paths_atmos (version)
import System.Console.GetOpt
import System.Directory (getHomeDirectory)
import System.FilePath ((</>))

atmosVersion :: String
atmosVersion = showVersion version

usageError :: AtmosError -> Bool
usageError (Usage _) = True
usageError (BadOption _) = True
usageError _ = False

data Flag = Namespace String | Full | Verbose | Help | Version
    deriving Eq

flags :: [OptDescr Flag]
flags =
    [ Option "t" [] (ReqArg Namespace "NS") "act in namespace NS"
    , Option "" ["full"] (NoArg Full) "also search dest_root for links to the library"
    , Option "" ["verbose"] (NoArg Verbose) "report every check"
    , Option "h" ["help"] (NoArg Help) "show this help"
    , Option "" ["version"] (NoArg Version) "show the version"
    ]

usage :: String
usage = usageInfo (unlines header) flags
  where
    header =
        [ "usage: atmos [-t NS] COMMAND [ARGS]"
        , ""
        , "commands:"
        , "  new -t NS          create a namespace"
        , "  lsns               list the namespaces"
        , "  set PARAM VALUE    set atmos_root or dest_root"
        , "  list [SELECTION]   list linked, unlinked or links"
        , "  link LIBRARY       link a library into dest_root"
        , "  unlink LIBRARY     remove a library's links"
        , "  verify             check the links against the cache"
        , ""
        , "options:"
        ]

cacheFile = do
    home <- getHomeDirectory
    return (home </> ".atmos.d" </> "atmos.db")

runArgs :: Cache -> [String] -> Atmos ()
runArgs cache args = case getOpt Permute flags args of
    (_, _, errs) | not (null errs) -> throwE (BadOption (concat errs))
    (opts, _, _) | Version `elem` opts -> liftIO (putStrLn atmosVersion)
    (opts, ps, _) | Help `elem` opts -> liftIO (putStr (helpFor ps))
    (opts, ps, _) -> dispatch cache opts ps

helpFor :: [String] -> String
helpFor (cmd : _) | Just text <- lookup cmd commandHelp = unlines text
helpFor _ = usage

commandHelp :: [(String, [String])]
commandHelp =
    [ ("new", ["usage: atmos new -t NS", "", "create a namespace"])
    , ("lsns", ["usage: atmos lsns", "", "list the namespaces"])
    , ("set", ["usage: atmos [-t NS] set PARAM VALUE", "", "set atmos_root or dest_root"])
    , ("list", ["usage: atmos [-t NS] list [linked|unlinked|links]", "", "list linked libraries by default"])
    , ("link", ["usage: atmos [-t NS] link LIBRARY", "", "link a library's files into dest_root"])
    , ("unlink", ["usage: atmos [-t NS] unlink LIBRARY [--full]", "", "remove a library's links; --full also searches dest_root for them"])
    , ("verify", ["usage: atmos [-t NS] verify", "", "check the recorded links against the filesystem"])
    ]

namespaceOf :: [Flag] -> Maybe String
namespaceOf opts = listToMaybe [name | Namespace name <- opts]

dispatch :: Cache -> [Flag] -> [String] -> Atmos ()
dispatch cache opts ["new"] = case namespaceOf opts of
    Just name -> newNamespace cache name
    Nothing -> throwE (Usage "new")
dispatch cache _ ["lsns"] = liftIO . mapM_ putStrLn =<< namespaces cache
dispatch cache opts ps = do
    view <- namespaceView cache (fromMaybe defaultNS (namespaceOf opts))
    command view opts ps

command :: Cache -> [Flag] -> [String] -> Atmos ()
command cache _ ["set", param, value]
    | param `elem` [atmosRoot, destRoot] = set cache param value
command cache _ ["list"] = listing cache "linked"
command cache _ ["list", selection] = listing cache selection
command cache _ ["link", lib] = link cache lib
command cache opts ["unlink", lib]
    | Full `elem` opts = unlinkFull cache lib
    | otherwise = unlink cache lib
command cache _ ["verify"] = verifying cache
command _ _ (cmd : _) = throwE (Usage cmd)
command _ _ [] = throwE (Usage "atmos")

listing :: Cache -> String -> Atmos ()
listing cache "linked" = getDirs cache >> (liftIO . mapM_ putStrLn =<< linked cache)
listing cache "unlinked" = getDirs cache >> (liftIO . mapM_ putStrLn =<< unlinked cache)
listing cache "links" = getDirs cache >> (mapM_ (report cache) =<< linked cache)
listing _ _ = throwE (Usage "list")

verifying :: Cache -> Atmos ()
verifying cache = do
    _ <- getDirs cache
    verifyLinked cache >>= liftIO . mapM_ (group "issues in linked library ")
    verifyUnlinked cache >>= liftIO . mapM_ (group "links to unlinked library ")
    verifyAllLinks cache >>= liftIO . mapM_ putStrLn

group :: String -> (String, [String]) -> IO ()
group heading (lib, entries) = do
    putStrLn (heading ++ lib ++ ":")
    mapM_ (putStrLn . ("\t" ++)) entries

report :: Cache -> String -> Atmos ()
report cache lib = do
    liftIO (putStrLn (lib ++ " links:"))
    records <- links cache lib
    forM_ records \(src, dst) ->
        liftIO (putStrLn ("\t" ++ src ++ " installed to " ++ dst))
