from .. import cli
from atmos import get_dirs
from atmos import UnlinkError
from diskcache import Cache
from pathlib import Path
import pytest  # noqa: F401


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
