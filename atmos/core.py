from pathlib import Path
import os


class CacheError(Exception): pass
class ConfigError(Exception): pass
class LinkError(Exception): pass
class UnlinkError(Exception): pass


class NamespaceView:
    def __init__(self, cache, namespace):
        self.cache = cache
        self.namespace = namespace

    def key(self, name):
        if self.namespace is None:
            return name
        return f'{self.namespace}:{name}'

    def __contains__(self, name):
        return self.key(name) in self.cache

    def __getitem__(self, name):
        return self.cache[self.key(name)]

    def __setitem__(self, name, value):
        self.cache[self.key(name)] = value

    def __eq__(self, other):
        if not isinstance(other, NamespaceView):
            return False
        return (self.cache, self.namespace) == (other.cache, other.namespace)

    def __hash__(self):
        return hash((self.cache, self.namespace))

    def __repr__(self):
        return f'NamespaceView({self.cache!r}, {self.namespace!r})'


def namespace_view(cache, namespace):
    if namespace is not None and namespace not in cache.get('namespaces', ()):
        raise ConfigError(f'namespace {namespace} does not exist')
    return NamespaceView(cache, namespace)


def validate_cache(cache):
    if 'atmos_root' not in cache:
        raise CacheError('atmos_root not found in ~/.atmos.cache')
    if 'dest_root' not in cache:
        raise CacheError('dest_root not found in ~/.atmos.cache')

    if 'linked' not in cache:
        cache['linked'] = {}


def get_dirs(cache):
    validate_cache(cache)

    atmos_root = Path(cache['atmos_root']).resolve(strict=True)
    dest_root = Path(cache['dest_root']).resolve(strict=True)

    if not atmos_root.is_dir():
        raise ConfigError('atmos_root is not a directory')
    if not dest_root.is_dir():
        raise ConfigError('dest_root is not a directory')

    return atmos_root, dest_root


def linked(cache):
    return frozenset(cache['linked'].keys())


def existing(atmos_root):
    return frozenset(f.name for f in atmos_root.iterdir() if f.is_dir())


def unlinked(cache):
    atmos_root, _ = get_dirs(cache)
    return existing(atmos_root) - linked(cache)


def is_symlink_into_dir(candidate, root):
    if not candidate.is_symlink():
        return False

    content = Path(os.readlink(candidate))
    if not content.is_absolute():
        return False

    return Path(os.path.normpath(content)).is_relative_to(root)


def is_transported_link(candidate, dest_root, lib_path):
    if not candidate.is_symlink():
        return False

    mirror = lib_path / candidate.relative_to(dest_root)
    return mirror.is_symlink() and os.readlink(mirror) == os.readlink(candidate)


found_links = None
def symlinks_to_atmos_root(cache):
    global found_links

    if found_links is not None:
        return found_links

    atmos_root, dest_root = get_dirs(cache)
    lib_paths = [atmos_root / lib for lib in existing(atmos_root)]

    found_links = frozenset(
        p for p in dest_root.rglob('*')
        if is_symlink_into_dir(p, atmos_root)
        or any(is_transported_link(p, dest_root, lp) for lp in lib_paths)
    )

    return found_links


def symlinks_to_lib(lib, cache):
    atmos_links = symlinks_to_atmos_root(cache)
    atmos_root, dest_root = get_dirs(cache)

    lib_path = atmos_root / lib

    if not lib_path.is_dir():
        raise ValueError(f'{lib} is not a directory')

    links = {
        p for p in atmos_links
        if is_symlink_into_dir(p, lib_path)
        or is_transported_link(p, dest_root, lib_path)
    }

    return links
