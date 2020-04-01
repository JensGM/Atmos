from atmos import UnlinkError
from atmos import get_dirs
from atmos import symlinks_to_lib
from pathlib import Path
import logging


def cmd_unlink(args, cache):
    atmos_root, dest_root = get_dirs(cache)

    lib = args.library
    full = args.full

    if lib not in cache['linked'] and not full:
        raise UnlinkError('library {} not linked'.format(lib))

    links = frozenset()

    if lib in cache['linked']:
        links |= {target for _, target in cache['linked'][lib]}

    if full:
        links |= symlinks_to_lib(lib, cache)

    for link in links:
        link = Path(link)
        if not link.is_symlink():
            logging.warning('{} is not a symlink'.format(link))
            continue
        if not link.exists():
            logging.warning('{} does not exist'.format(link))
            continue
        if link.is_dir():
            logging.warning('{} is a directory'.format(link))
            continue
        link.unlink()

    if lib in cache['linked']:
        linked_libs = cache['linked']
        del linked_libs[lib]
        cache['linked'] = linked_libs
