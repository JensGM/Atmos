#!/usr/bin/env python3

import setuptools

setuptools.setup(
    name = 'atmos',
    description = 'atmos: package generated with cookiecutter-equinor',

    author = 'Equinor',
    author_email = 'jegm@equinor.com',
    url = 'https://github.com/jensgm/atmos',

    project_urls = {
        'Documentation': 'https://atmos.readthedocs.io/',
        'Issue Tracker': 'https://github.com/jensgm/atmos/issues',
    },
    keywords = [
    ],

    license = 'GNU General Public License v3',

    packages = [
        'atmos',
    ],
    platforms = 'any',

    install_requires = [
    ],

    setup_requires = [
        'setuptools >=28',
        'setuptools_scm',
        'pytest-runner'
    ],

    tests_require = [
        'pytest',
    ],

entry_points = {
        'console_scripts': [
            'atmos = atmos.cli:main',
        ],
    },

    use_scm_version = {
        'write_to': 'atmos/version.py',
    },
)
