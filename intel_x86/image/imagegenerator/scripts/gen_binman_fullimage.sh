#!/bin/bash

set -e

if [ -n "${STAGING_DIR_HOSTPKG}" ]; then
	export PATH=${STAGING_DIR_HOSTPKG}/bin:$PATH
fi

binman --toolpath ./tools -v4 build -I ./build -d build/binman-fullimage.dts -O build
