#! /usr/bin/env python

from setuptools import setup, Extension
from distutils.command.build import build

import os
import subprocess
import sys

try:
    import numpy
    try:
        numpy_include = numpy.get_include()
    except AttributeError:
        numpy_include = numpy.get_numpy_include()
except ImportError:
    numpy_include = ''
    assert 'NUMPY_INCLUDE' in os.environ

numpy_include = os.getenv('NUMPY_INCLUDE', numpy_include)

project_name = 'deepspeech'
if '--project_name' in sys.argv:
  project_name_idx = sys.argv.index('--project_name')
  project_name = sys.argv[project_name_idx + 1]
  sys.argv.remove('--project_name')
  sys.argv.pop(project_name_idx)

class BuildExtFirst(build):
    sub_commands = [('build_ext', build.has_ext_modules),
                    ('build_py', build.has_pure_modules),
                    ('build_clib', build.has_c_libraries),
                    ('build_scripts', build.has_scripts)]

model = Extension('deepspeech._model',
        ['python/model.i'],
        include_dirs = [numpy_include],
        library_dirs = list(map(lambda x: x.strip(), os.getenv('MODEL_LDFLAGS', '').split('-L')[1:])),
        libraries = list(map(lambda x: x.strip(), os.getenv('MODEL_LIBS', '').split('-l')[1:])))

utils = Extension('deepspeech._utils',
        ['python/utils.i'],
        include_dirs = [numpy_include],
        library_dirs = list(map(lambda x: x.strip(), os.getenv('UTILS_LDFLAGS', '').split('-L')[1:])),
        libraries = ['deepspeech_utils'])

setup(name = project_name,
      description = 'A library for running inference on a DeepSpeech model',
      author = 'Mozilla',
      version = '0.1.0',
      package_dir = {'deepspeech': 'python'},
      packages = ['deepspeech'],
      cmdclass = {'build': BuildExtFirst},
      license = 'MPL-2.0',
      url = 'https://github.com/mozilla/DeepSpeech',
      ext_modules = [model, utils],
      entry_points={'console_scripts':['deepspeech = deepspeech.client:main']},
      install_requires = ['numpy', 'scipy'],
      include_package_data = True,
      classifiers = [
        'Development Status :: 3 - Alpha',
        'Environment :: Console',
        'Intended Audience :: Developers',
        'Intended Audience :: Science/Research',
        'License :: OSI Approved :: Mozilla Public License 2.0 (MPL 2.0)',
        'Programming Language :: Python :: 2.7',
        'Programming Language :: Python :: 3.4',
        'Programming Language :: Python :: 3.5',
        'Programming Language :: Python :: 3.6',
        'Topic :: Multimedia :: Sound/Audio :: Speech',
        'Topic :: Scientific/Engineering :: Human Machine Interfaces',
        'Topic :: Scientific/Engineering',
        'Topic :: Utilities',
      ])
