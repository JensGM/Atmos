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
import argparse
import sys


from atmos.subcommands import cmd_set
from atmos.subcommands import cmd_list
from atmos.subcommands import cmd_link
from atmos.subcommands import cmd_unlink
from atmos.subcommands import cmd_verify


parser = argparse.ArgumentParser(description=None)
subparsers = parser.add_subparsers()

#
# Set command
#
parser_set = subparsers.add_parser('set')
parser_set.add_argument('param',
                        choices=['atmos_root', 'dest_root'])
parser_set.add_argument('value')
parser_set.set_defaults(func=cmd_set)


#
# List command
#
parser_list = subparsers.add_parser('list')
parser_list.add_argument('selection',
                         default='linked',
                         const='linked',
                         nargs='?',
                         choices=['linked', 'unlinked', 'links'])
parser_list.set_defaults(func=cmd_list)


#
# Link command
#
parser_link = subparsers.add_parser('link')
parser_link.add_argument('library', help='library name')
parser_link.set_defaults(func=cmd_link)


#
# Unlink command
#
parser_unlink = subparsers.add_parser('unlink')
parser_unlink.add_argument('library', help='library name')
parser_unlink.add_argument(
    '--full',
    action='store_true',
    help=(
        'Search destination directory for files linking to the library. Any '
        'links to the library root will be removed, regardless if the library '
        'is linked or not.'
    ),
)
parser_unlink.set_defaults(func=cmd_unlink)


#
# Verify command
#
parser_verify = subparsers.add_parser('verify')
parser_verify.add_argument('--verbose', action='store_true')
parser_verify.set_defaults(func=cmd_verify)


def main(args=None):
    args = parser.parse_args(args=args)

    if 'func' not in args:
        parser.print_help()
        sys.exit(1)

    with Cache('~/.atmos.cache') as cache:
        args.func(args, cache)
