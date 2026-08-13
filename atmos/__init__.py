from importlib.metadata import PackageNotFoundError, version

try:
    __version__ = version(__name__)
except PackageNotFoundError:
    pass


from .core import existing
from .core import get_dirs
from .core import linked
from .core import namespace_view
from .core import symlinks_to_atmos_root
from .core import symlinks_to_lib
from .core import unlinked
from .core import validate_cache


from .core import CacheError
from .core import ConfigError
from .core import LinkError
from .core import UnlinkError


from . import subcommands


__all__ = [
    'existing',
    'get_dirs',
    'linked',
    'namespace_view',
    'symlinks_to_atmos_root',
    'symlinks_to_lib',
    'unlinked',
    'validate_cache',

    'CacheError',
    'ConfigError',
    'LinkError',
    'UnlinkError',

    'subcommands',
]
