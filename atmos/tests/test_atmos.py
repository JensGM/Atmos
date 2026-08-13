from .. import cli
from atmos import ConfigError
from atmos import core
from atmos import get_dirs
from atmos import namespace_view
from atmos import UnlinkError
from atmos.subcommands.verify import verify_all_links
from atmos.subcommands.verify import verify_linked
from diskcache import Cache
from pathlib import Path
import os
import pytest  # noqa: F401


@pytest.fixture(autouse=True)
def reset_found_links():
    # symlinks_to_atmos_root memoizes its dest scan in a module global, which
    # would leak stale results between tests
    core.found_links = None


def mktree(root, entries):
    for name, value in entries.items():
        path = Path(root, name)
        if isinstance(value, dict):
            path.mkdir()
            mktree(path, value)
        elif isinstance(value, Path):
            path.symlink_to(value)
        else:
            path.write_text(value)


@pytest.fixture()
def atmos_tmp(tmp_path_factory):
    cache_path = str(tmp_path_factory.mktemp('atmos_cache'))
    dest_root = str(tmp_path_factory.mktemp('atmos_dest'))

    with Cache(cache_path) as cache:
        ar = str(Path('atmos/tests/test_data/atmos_root').resolve())
        cache['atmos_root'] = ar
        cache['dest_root'] = dest_root
        cache['linked'] = {}

    return {
        'cache_path': cache_path,
        'dest_root': dest_root,
    }


def test_set(atmos_tmp):
    set_atmos_root_args = cli.parser.parse_args(['set', 'atmos_root', 'foo'])
    set_dest_root_args = cli.parser.parse_args(['set', 'dest_root', 'bar'])
    with Cache(atmos_tmp['cache_path']) as cache:
        set_atmos_root_args.func(set_atmos_root_args, cache)
        set_dest_root_args.func(set_dest_root_args, cache)
        assert cache['atmos_root'] =='foo'
        assert cache['dest_root'] =='bar'


def test_get_dirs(atmos_tmp):
    with Cache(atmos_tmp['cache_path']) as cache:
        atmos_root, dest_root = get_dirs(cache)

    ar = Path('atmos/tests/test_data/atmos_root').resolve()
    assert atmos_root == ar
    assert Path(dest_root).is_dir()


def test_link(atmos_tmp):
    args = cli.parser.parse_args(['link', 'some_library'])
    with Cache(atmos_tmp['cache_path']) as cache:
        assert 'some_library' not in cache['linked']
        args.func(args, cache)
        assert 'some_library' in cache['linked']

    linked_file = Path(atmos_tmp['dest_root']) / 'somedir/msg.txt'
    assert linked_file.is_symlink()

    with open(linked_file) as f:
        msg = f.read().strip()
    assert msg == 'hello'


def test_unlink(atmos_tmp):
    some_library_args = cli.parser.parse_args(['link', 'some_library'])
    another_library_args = cli.parser.parse_args(['link', 'another_library'])
    with Cache(atmos_tmp['cache_path']) as cache:
        some_library_args.func(some_library_args, cache)
        another_library_args.func(another_library_args, cache)

    file_a = Path(atmos_tmp['dest_root']) / 'somedir/msg.txt'
    file_b = Path(atmos_tmp['dest_root']) / 'lib/hello_world.py'

    args = cli.parser.parse_args(['unlink', 'some_library'])
    with Cache(atmos_tmp['cache_path']) as cache:
        args.func(args, cache)
        assert 'some_library' not in cache['linked']
        assert 'another_library' in cache['linked']

    assert not file_a.exists()
    assert file_b.is_symlink()


def test_unlink_full(atmos_tmp):
    some_library_args = cli.parser.parse_args(['link', 'some_library'])
    another_library_args = cli.parser.parse_args(['link', 'another_library'])
    with Cache(atmos_tmp['cache_path']) as cache:
        some_library_args.func(some_library_args, cache)
        another_library_args.func(another_library_args, cache)

    file_a = Path(atmos_tmp['dest_root']) / 'somedir/msg.txt'
    file_b = Path(atmos_tmp['dest_root']) / 'lib/hello_world.py'

    # Delete the entry from the cache, making the cache invalid
    with Cache(atmos_tmp['cache_path']) as cache:
        linked = cache['linked']
        del linked['some_library']
        cache['linked'] = linked

    # Fails without full parameter
    args = cli.parser.parse_args(['unlink', 'some_library'])
    with Cache(atmos_tmp['cache_path']) as cache:
        with pytest.raises(UnlinkError):
            args.func(args, cache)
        assert 'another_library' in cache['linked']

    # All linked files should still exist
    assert file_a.is_symlink()
    assert file_b.is_symlink()

    # Fails without full parameter
    args = cli.parser.parse_args(['unlink', 'some_library', '--full'])
    with Cache(atmos_tmp['cache_path']) as cache:
        args.func(args, cache)
        assert 'another_library' in cache['linked']

    # file_a should be removed because it is from some_library, even if
    # some_library was not present in the cache.
    assert not file_a.exists()
    assert file_b.is_symlink()


def test_link_transports_relative_symlink(tmp_path):
    mktree(tmp_path, {
        'atmos': {
            'symlib': {
                'regular.txt': 'real',
                'sub': {
                    'link_inside.txt': Path('../regular.txt'),
                },
            },
        },
        'dest': {},
    })

    args = cli.parser.parse_args(['link', 'symlib'])
    with Cache(str(tmp_path / 'cache')) as cache:
        cache['atmos_root'] = str(tmp_path / 'atmos')
        cache['dest_root'] = str(tmp_path / 'dest')
        cache['linked'] = {}
        args.func(args, cache)

    link = tmp_path / 'dest/sub/link_inside.txt'
    assert link.is_symlink()
    assert os.readlink(link) == '../regular.txt'
    assert link.read_text() == 'real'


def test_link_transports_absolute_symlink(tmp_path):
    mktree(tmp_path, {
        'outside': {'outer.txt': 'outer'},
        'atmos': {
            'symlib': {
                'link_outside.txt': tmp_path / 'outside/outer.txt',
            },
        },
        'dest': {},
    })

    args = cli.parser.parse_args(['link', 'symlib'])
    with Cache(str(tmp_path / 'cache')) as cache:
        cache['atmos_root'] = str(tmp_path / 'atmos')
        cache['dest_root'] = str(tmp_path / 'dest')
        cache['linked'] = {}
        args.func(args, cache)

    link = tmp_path / 'dest/link_outside.txt'
    assert link.is_symlink()
    assert os.readlink(link) == str(tmp_path / 'outside/outer.txt')
    assert link.read_text() == 'outer'


def test_link_transports_broken_symlink(tmp_path):
    mktree(tmp_path, {
        'atmos': {
            'symlib': {
                'broken.txt': Path('nonexistent'),
            },
        },
        'dest': {},
    })

    args = cli.parser.parse_args(['link', 'symlib'])
    with Cache(str(tmp_path / 'cache')) as cache:
        cache['atmos_root'] = str(tmp_path / 'atmos')
        cache['dest_root'] = str(tmp_path / 'dest')
        cache['linked'] = {}
        args.func(args, cache)

    link = tmp_path / 'dest/broken.txt'
    assert link.is_symlink()
    assert not link.exists()
    assert os.readlink(link) == 'nonexistent'


def test_link_transports_directory_symlink(tmp_path):
    mktree(tmp_path, {
        'atmos': {
            'symlib': {
                'sub': {
                    'inner.txt': 'inner',
                },
                'dirlink': Path('sub'),
            },
        },
        'dest': {},
    })

    args = cli.parser.parse_args(['link', 'symlib'])
    with Cache(str(tmp_path / 'cache')) as cache:
        cache['atmos_root'] = str(tmp_path / 'atmos')
        cache['dest_root'] = str(tmp_path / 'dest')
        cache['linked'] = {}
        args.func(args, cache)
        records = cache['linked']['symlib']

    dirlink = tmp_path / 'dest/dirlink'
    assert dirlink.is_symlink()
    assert os.readlink(dirlink) == 'sub'
    assert (dirlink / 'inner.txt').read_text() == 'inner'

    # inner.txt is linked through its real path only, not duplicated through
    # the directory symlink
    assert (tmp_path / 'dest/sub/inner.txt').is_symlink()
    assert len(records) == 2


def test_unlink_symlinks(tmp_path):
    mktree(tmp_path, {
        'outside': {'outer.txt': 'outer'},
        'atmos': {
            'symlib': {
                'regular.txt': 'real',
                'dirlink': Path('sub'),
                'sub': {
                    'link_inside.txt': Path('../regular.txt'),
                    'link_outside.txt': tmp_path / 'outside/outer.txt',
                    'broken.txt': Path('nonexistent'),
                },
            },
        },
        'dest': {},
    })

    link_args = cli.parser.parse_args(['link', 'symlib'])
    with Cache(str(tmp_path / 'cache')) as cache:
        cache['atmos_root'] = str(tmp_path / 'atmos')
        cache['dest_root'] = str(tmp_path / 'dest')
        cache['linked'] = {}
        link_args.func(link_args, cache)

    unlink_args = cli.parser.parse_args(['unlink', 'symlib'])
    with Cache(str(tmp_path / 'cache')) as cache:
        unlink_args.func(unlink_args, cache)
        assert 'symlib' not in cache['linked']

    leftovers = [p for p in (tmp_path / 'dest').rglob('*') if p.is_symlink()]
    assert leftovers == []


def test_unlink_full_symlinks(tmp_path):
    mktree(tmp_path, {
        'outside': {'outer.txt': 'outer'},
        'atmos': {
            'symlib': {
                'regular.txt': 'real',
                'dirlink': Path('sub'),
                'sub': {
                    'link_inside.txt': Path('../regular.txt'),
                    'link_outside.txt': tmp_path / 'outside/outer.txt',
                    'broken.txt': Path('nonexistent'),
                },
            },
        },
        'dest': {},
    })

    link_args = cli.parser.parse_args(['link', 'symlib'])
    with Cache(str(tmp_path / 'cache')) as cache:
        cache['atmos_root'] = str(tmp_path / 'atmos')
        cache['dest_root'] = str(tmp_path / 'dest')
        cache['linked'] = {}
        link_args.func(link_args, cache)

    # Delete the entry from the cache, making the cache invalid
    with Cache(str(tmp_path / 'cache')) as cache:
        linked = cache['linked']
        del linked['symlib']
        cache['linked'] = linked

    unlink_args = cli.parser.parse_args(['unlink', 'symlib', '--full'])
    with Cache(str(tmp_path / 'cache')) as cache:
        unlink_args.func(unlink_args, cache)

    leftovers = [p for p in (tmp_path / 'dest').rglob('*') if p.is_symlink()]
    assert leftovers == []


def test_verify_clean_after_link(tmp_path):
    mktree(tmp_path, {
        'outside': {'outer.txt': 'outer'},
        'atmos': {
            'symlib': {
                'regular.txt': 'real',
                'dirlink': Path('sub'),
                'sub': {
                    'link_inside.txt': Path('../regular.txt'),
                    'link_outside.txt': tmp_path / 'outside/outer.txt',
                    'broken.txt': Path('nonexistent'),
                },
            },
        },
        'dest': {},
    })

    link_args = cli.parser.parse_args(['link', 'symlib'])
    with Cache(str(tmp_path / 'cache')) as cache:
        cache['atmos_root'] = str(tmp_path / 'atmos')
        cache['dest_root'] = str(tmp_path / 'dest')
        cache['linked'] = {}
        link_args.func(link_args, cache)

    with Cache(str(tmp_path / 'cache')) as cache:
        assert verify_linked(cache) == {}
        assert verify_all_links(cache) == {}


def test_set_namespaced(tmp_path):
    new_args = cli.parser.parse_args(['new', '-t', 'work'])
    set_args = cli.parser.parse_args(['set', '-t', 'work', 'atmos_root', 'foo'])
    with Cache(str(tmp_path / 'cache')) as cache:
        new_args.func(new_args, cache)
        set_args.func(set_args, namespace_view(cache, set_args.namespace))
        assert cache['work:atmos_root'] == 'foo'
        assert 'atmos_root' not in cache


def test_link_namespaced(tmp_path):
    mktree(tmp_path, {
        'atmos': {
            'mylib': {'file.txt': 'hello'},
        },
        'dest': {},
    })

    new_args = cli.parser.parse_args(['new', '-t', 'work'])
    root_args = cli.parser.parse_args(
        ['set', '-t', 'work', 'atmos_root', str(tmp_path / 'atmos')])
    dest_args = cli.parser.parse_args(
        ['set', '-t', 'work', 'dest_root', str(tmp_path / 'dest')])
    link_args = cli.parser.parse_args(['link', '-t', 'work', 'mylib'])

    with Cache(str(tmp_path / 'cache')) as cache:
        new_args.func(new_args, cache)
        root_args.func(root_args, namespace_view(cache, 'work'))
        dest_args.func(dest_args, namespace_view(cache, 'work'))
        link_args.func(link_args, namespace_view(cache, 'work'))
        assert 'mylib' in cache['work:linked']
        assert 'linked' not in cache
    assert (tmp_path / 'dest/file.txt').is_symlink()


def test_fail_on_unknown_namespace(tmp_path):
    new_args = cli.parser.parse_args(['new', '-t', 'work'])
    with Cache(str(tmp_path / 'cache')) as cache:
        new_args.func(new_args, cache)
        namespace_view(cache, 'work')
        namespace_view(cache, None)
        with pytest.raises(ConfigError):
            namespace_view(cache, 'typo')


def test_fail_on_duplicate_namespace(tmp_path):
    new_args = cli.parser.parse_args(['new', '-t', 'work'])
    with Cache(str(tmp_path / 'cache')) as cache:
        new_args.func(new_args, cache)
        with pytest.raises(ConfigError):
            new_args.func(new_args, cache)


def test_fail_on_invalid_namespace_name(tmp_path):
    with Cache(str(tmp_path / 'cache')) as cache:
        for name in ['with:colon', 'default']:
            args = cli.parser.parse_args(['new', '-t', name])
            with pytest.raises(ConfigError):
                args.func(args, cache)


def test_fail_on_missing_namespace_name():
    with pytest.raises(SystemExit):
        cli.parser.parse_args(['new'])


def test_legacy_cache_is_default_namespace(tmp_path):
    mktree(tmp_path, {
        'atmos': {'mylib': {'file.txt': 'hello'}},
        'dest': {},
    })

    link_args = cli.parser.parse_args(['link', 'mylib'])
    assert link_args.namespace is None
    with Cache(str(tmp_path / 'cache')) as cache:
        cache['atmos_root'] = str(tmp_path / 'atmos')
        cache['dest_root'] = str(tmp_path / 'dest')
        cache['linked'] = {}
        link_args.func(link_args, namespace_view(cache, None))
        assert 'mylib' in cache['linked']
    assert (tmp_path / 'dest/file.txt').is_symlink()
