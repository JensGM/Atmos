from pathlib import Path


class CacheError(Exception): pass
class ConfigError(Exception): pass
class LinkError(Exception): pass
class UnlinkError(Exception): pass


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


def is_symlink_to_file_in_dir(candidate, root):
    if not candidate.is_symlink():
        return False

    resolved = candidate.resolve()

    try:
        # If the candidate path does not start with the value of root, a
        # ValueError is raised
        resolved.relative_to(root)
    except ValueError:
        return False

    return True


found_links = None
def symlinks_to_atmos_root(cache):
    global found_links

    if found_links is not None:
        return found_links

    atmos_root, dest_root = get_dirs(cache)

    found_links = frozenset(
        p for p in dest_root.rglob('*')
        if is_symlink_to_file_in_dir(p, atmos_root)
    )

    return found_links


def symlinks_to_lib(lib, cache):
    atmos_links = symlinks_to_atmos_root(cache)
    atmos_root, _ = get_dirs(cache)

    lib_path = atmos_root / lib

    if not lib_path.is_dir():
        raise ValueError('{} is not a directory'.format(lib))

    links = {
        p for p in symlinks_to_atmos_root(cache)
        if is_symlink_to_file_in_dir(p, lib_path)
    }

    return links
