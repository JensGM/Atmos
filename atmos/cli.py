"""
Module that contains the command line app.

Why does this file exist, and why not put this in __main__?

  You might be tempted to import things from __main__ later, but that will
  cause problems: the code will get executed twice:

  - When you run `python -m atmos` python will execute
    ``__main__.py`` as a script. That means there won't be any
    ``atmos.__main__`` in ``sys.modules``.
  - When you import __main__ it will get executed again (as a module) because
    there's no ``atmos.__main__`` in ``sys.modules``.

  Also see (1) from http://click.pocoo.org/5/setuptools/#setuptools-integration
"""
from diskcache import Cache
from pathlib import Path
import argparse
import logging
import sys


def set_func(args, cache):
    cache[args.param] = args.value


def get_dirs(cache):
    validate_cache(cache)

    atmos_root = Path(cache['atmos_root']).resolve()
    dest_root = Path(cache['dest_root']).resolve()

    if not atmos_root.is_dir():
        raise ValueError('atmos_root is not a directory')
    if not dest_root.is_dir():
        raise ValueError('dest_root is not a directory')

    return atmos_root, dest_root



def list_func(args, cache):
    atmos_root, dest_root = get_dirs(cache)

    if args.selection == 'linked':
        print('\n'.join(linked(cache)))

    elif args.selection == 'unlinked':
        print('\n'.join(unlinked(atmos_root, cache)))

    elif args.selection == 'links':
        lns = cache['linked']
        for lib, links in lns.items():
            print('{} links:'.format(lib))
            for src, dst in links:
                print('\t{} installed to {}'.format(src, dst))

    else:
        raise RuntimeError('Unknown selection {}'.format(args.selection))


def link_func(args, cache):
    atmos_root, dest_root = get_dirs(cache)

    lib = args.library
    if lib in cache['linked']:
        raise ValueError('library {} already linked'.format(lib))

    lib_path = atmos_root / lib
    if not lib_path.is_dir():
        raise ValueError('{} not found'.format(lib))

    files = [p.absolute() for p in lib_path.rglob('*') if p.is_file()]

    links = []
    for source in files:
        target = dest_root / source.relative_to(lib_path)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.symlink_to(source)
        record = str(source), str(target)
        links.append(record)

    linked_libs = cache['linked']
    linked_libs[lib] = links
    cache['linked'] = linked_libs


def unlink_func(args, cache):
    atmos_root, dest_root = get_dirs(cache)

    lib = args.library
    if lib not in cache['linked']:
        raise ValueError('library {} not linked'.format(lib))

    links = cache['linked'][lib]
    for _, target in links:
        target = Path(target)
        if not target.is_symlink():
            logging.warning('{} is not a symlink'.format(target))
            continue
        if not target.exists():
            logging.warning('{} does not exist'.format(target))
            continue
        if target.is_dir():
            logging.warning('{} is a directory'.format(target))
            continue
        target.unlink()

    linked_libs = cache['linked']
    del linked_libs[lib]
    cache['linked'] = linked_libs


parser = argparse.ArgumentParser(description=None)
subparsers = parser.add_subparsers()


parser_set = subparsers.add_parser('set')
parser_set.add_argument('param',
                        choices=['atmos_root', 'dest_root'])
parser_set.add_argument('value')
parser_set.set_defaults(func=set_func)


parser_list = subparsers.add_parser('list')
parser_list.add_argument('selection',
                         default='linked',
                         const='linked',
                         nargs='?',
                         choices=['linked', 'unlinked', 'links'])
parser_list.set_defaults(func=list_func)


parser_link = subparsers.add_parser('link')
parser_link.add_argument('library', help='library name')
parser_link.set_defaults(func=link_func)


parser_unlink = subparsers.add_parser('unlink')
parser_unlink.add_argument('library', help='library name')
parser_unlink.set_defaults(func=unlink_func)


def validate_cache(cache):
    if 'atmos_root' not in cache:
        raise ValueError('atmos_root not found in ~/.atmos.cache')
    if 'dest_root' not in cache:
        raise ValueError('dest_root not found in ~/.atmos.cache')

    if 'linked' not in cache:
        cache['linked'] = {}


def linked(cache):
    return set(cache['linked'].keys())


def existing(atmos_root):
    return set(f.name for f in atmos_root.iterdir() if f.is_dir())


def unlinked(atmos_root, cache):
    return existing(atmos_root) - linked(cache)


def main(args=None):
    args = parser.parse_args(args=args)

    if 'func' not in args:
        parser.print_help()
        sys.exit(1)

    with Cache('~/.atmos.cache') as cache:
        args.func(args, cache)
