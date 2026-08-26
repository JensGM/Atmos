-- | The whole of atmos' persistent state, as types.
--
-- This is deliberately small: it is the entire justification for whatever
-- storage engine we pick, and it fits on one screen.
module Atmos.Types
  ( Namespace
  , defaultNamespace
  , Config (..)
  , emptyConfig
  , configGet
  , configSet
  , LinkRecord (..)
  , Manifest
  , AtmosError (..)
  ) where

import Control.Exception (Exception)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M

-- | @Nothing@ is the unnamespaced ("default") view.
type Namespace = Maybe String

-- | On-disk name for the unnamespaced view.  @atmos new@ rejects the name
-- @default@, so this can never collide with a user namespace.
defaultNamespace :: String
defaultNamespace = "default"

-- | Global settings: @atmos_root@ and @dest_root@ today, open-ended by design.
newtype Config = Config (Map String String)
  deriving (Eq, Show)

emptyConfig :: Config
emptyConfig = Config M.empty

configGet :: String -> Config -> Maybe String
configGet k (Config m) = M.lookup k m

configSet :: String -> String -> Config -> Config
configSet k v (Config m) = Config (M.insert k v m)

-- | One symlink atmos created: where it came from and where it was installed.
data LinkRecord = LinkRecord
  { lrSource :: FilePath
  -- ^ path under @atmos_root@
  , lrTarget :: FilePath
  -- ^ path under @dest_root@
  }
  deriving (Eq, Ord, Show)

-- | Everything we know about one linked library.  A manifest is the unit of
-- atomicity for the file-per-library store: @link@ and @unlink@ each touch
-- exactly one.
type Manifest = [LinkRecord]

data AtmosError
  = CacheError String
  | ConfigError String
  | LinkError String
  | UnlinkError String
  | StoreError String
  deriving (Show)

instance Exception AtmosError
