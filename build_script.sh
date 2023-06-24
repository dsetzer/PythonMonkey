#! /bin/bash
#
# @file         build.sh
# @author       Giovanni Tedesco <giovanni@distributive.network>
# @date         Aug 2022

cd `dirname "$0"`
topDir=`pwd`

# Get number of CPU cores
CPUS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || getconf NPROCESSORS_ONLN 2>/dev/null || echo 1)

DIR="build"
if [  ! -d "$DIR" ]; then
  ### Take action if $DIR exists ###
  mkdir build
fi

cd build
cmake ..
cmake --build . -j$CPUS

cd "${topDir}"
cp -f build/src/pythonmonkey.so python/pythonmonkey/
echo "# This file was generated via $0 by `id -un` on `date` - do not edit by hand!"
grep '^version' pyproject.toml \
| head -1 \
| sed 's/^version /__version__ /' \
>> python/pythonmonkey/version.py

# npm is used to load JS components, see package.json
cd "${topDir}/python/pythonmonkey/"
npm i 
