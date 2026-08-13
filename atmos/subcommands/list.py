from atmos import get_dirs
from atmos import linked
from atmos import unlinked


def cmd_list(args, cache):
    atmos_root, dest_root = get_dirs(cache)

    if args.selection == 'linked':
        print('\n'.join(linked(cache)))

    elif args.selection == 'unlinked':
        print('\n'.join(unlinked(cache)))

    elif args.selection == 'links':
        lns = cache['linked']
        for lib, links in lns.items():
            print(f'{lib} links:')
            for src, dst in links:
                print(f'\t{src} installed to {dst}')

    else:
        raise RuntimeError(f'Unknown selection {args.selection}')
