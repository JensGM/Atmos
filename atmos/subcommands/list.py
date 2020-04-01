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
            print('{} links:'.format(lib))
            for src, dst in links:
                print('\t{} installed to {}'.format(src, dst))

    else:
        raise RuntimeError('Unknown selection {}'.format(args.selection))
