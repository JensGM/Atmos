# atmos #

Merge install prefixes though removable symlinks.

## Getting started ##

Installations should be done into separate directories in a root directory. In
the example below, we install `some_library` to `~/atmos/some_library` and make
symlinks to it in `/usr/local/`.

```bash
atmos set atmos_root ~/atmos
atmos set dest_root /usr/local

mkdir some_library/build
cd some_library/build
cmake .. install --prefix ~/atmos/some_library
make && make install

sudo atmos link some_library
```

To undo the symlinks, you can run the following

```bash
sudo atmos unlink some_library
```
