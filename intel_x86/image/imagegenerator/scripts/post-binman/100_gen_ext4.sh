#!/bin/bash
# SPDX-License-Identifier: BSD-2-Clause-Patent
#
# SPDX-FileCopyrightText: Copyright (c) 2025 SoftAtHome
#
# Script to perform the signature process of an image
#
# This script should be run from the root directory where imagegenerator files
# are installed.

set -e

mkdir -p build/input_dir

if [ -f build/kernel.itb ]; then
	echo "copy kernel.itb"
	cp -f build/kernel.itb build/input_dir/
fi

if [ -f build/rootfs.itb ]; then
	echo "copy rootfs.itb"
	cp -f build/rootfs.itb build/input_dir/
fi

# Estimate the required size of the ext4 filesystem to store the images with a margin of 30%
block_size=4096

size_bytes=$(du -sb build/input_dir | cut -f1)
size_bytes=$((size_bytes + size_bytes * 30 / 100))
blocks=$(( (size_bytes + block_size - 1) / block_size ))

# Format the file as ext4
echo "Create an create an ext4 file system of $blocks blocks"
mkfs.ext4 -F -b $block_size -d build/input_dir build/ext4.img $blocks

rm -r build/input_dir
