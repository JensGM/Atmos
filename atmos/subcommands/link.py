from atmos import LinkError
from atmos import get_dirs
import logging
import os


def cmd_link(args, cache):
    atmos_root, dest_root = get_dirs(cache)

    lib = args.library
    if lib in cache['linked']:
        raise LinkError(f'library {lib} already linked')

    lib_path = atmos_root / lib
    if not lib_path.is_dir():
        raise LinkError(f'{lib} is not a directory')

    sources = [
        p.absolute() for p in lib_path.rglob('*')
        if p.is_symlink() or p.is_file()
    ]

    links = []
    for source in sources:
        target = dest_root / source.relative_to(lib_path)

        if target.is_symlink() or target.exists():
            logging.warning(f'{target} already exists')
            continue

        target.parent.mkdir(parents=True, exist_ok=True)
        if source.is_symlink():
            if not source.exists():
                logging.warning(f'{source} does not resolve')
            # os.readlink, not Path.readlink, to transport the link content
            # byte-for-byte without Path normalization
            target.symlink_to(os.readlink(source))
        else:
            target.symlink_to(source)
        record = str(source), str(target)
        links.append(record)

    linked_libs = cache['linked']
    linked_libs[lib] = links
    cache['linked'] = linked_libs
