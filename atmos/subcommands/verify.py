from atmos import symlinks_to_atmos_root
from atmos import symlinks_to_lib
from atmos import unlinked as unlinked_libs
from itertools import chain
from pathlib import Path


def verify_linked(cache):
    issues = {}

    linked = {
        lib: [
            (Path(src), Path(link))
            for src, link in links
        ]
        for lib, links in cache['linked'].items()
    }

    for lib, links in linked.items():
        missing_srcs = {s for s, _ in links if not s.exists()}
        missing_links = {l for _, l in links if not l.exists()}
        not_links = {l for _, l in links if not l.is_symlink()}
        mismatches = {(s, l) for s, l in links if s.resolve() != l.resolve()}

        if len(missing_srcs) > 0:
            issues.setdefault(lib, {})['missing_srcs'] = missing_srcs

        if len(missing_links) > 0:
            issues.setdefault(lib, {})['missing_links'] = missing_links

        if len(not_links) > 0:
            issues.setdefault(lib, {})['not_links'] = not_links

        if len(mismatches) > 0:
            issues.setdefault(lib, {})['mismatches'] = mismatches

    return issues


def verify_unlinked(cache):
    issues = {}

    unlinked = unlinked_libs(cache)

    for lib in unlinked:
        links_to_unlinked = symlinks_to_lib(lib, cache)

        if len(links_to_unlinked) > 0:
            issues.setdefault(lib, {})['links_to_unlinked'] = links_to_unlinked

    return issues


def verify_all_links(cache):
    issues = {}

    linked = {
        lib: [Path(link) for _, link in links]
        for lib, links in cache['linked'].items()
    }

    all_links = symlinks_to_atmos_root(cache)
    claimed_links = frozenset(chain(*linked.values()))

    invalid_links = all_links - claimed_links
    missing_links = claimed_links - all_links

    if len(invalid_links) > 0:
        issues['invalid_links'] = invalid_links

    if len(missing_links) > 0:
        issues['missing_links'] = missing_links

    return issues


def cmd_verify(args, cache):
    verbose = args.verbose

    linked_issues = verify_linked(cache)
    if len(linked_issues) > 0:
        for lib, issues in linked_issues.items():
            print('Found issues in linked library {}:'.format(lib))
            print(issues)

    unlinked_issues = verify_unlinked(cache)
    if len(unlinked_issues) > 0:
        for lib, issues in unlinked.items():
            print('Found issues in unlinked library {}:'.format(lib))
            print(issues)

    link_issues = verify_all_links(cache)
    print(link_issues)
