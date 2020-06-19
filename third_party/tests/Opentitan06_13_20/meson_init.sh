#!/bin/bash
# Copyright lowRISC contributors.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

set -o errexit
set -o pipefail
set -o nounset

# meson_init.sh configures OpenTitan's Meson build system. Rather than calling
# Meson directly, this script should be used instead, since it handles things
# that Meson does not out of the box, such as:
# - The RISC-V toolchain.
# - Idempotence.
# - Building for multiple device platforms.
#
# This script's semantics for creating build directories are as follows:
# - By default, this script will create any missing build directories and
#   configure them. It is idempotent: if there is no work to be done, nothing
#   will change and this script will exit successfully.
# - Passing -r will reconfigure existing build directories. This should be used
#   when editing meson.build files.
# - Passing -f will erase existing build directories. This should be used when
#   existing configuration is completely broken, or a clean build is desired
#   (neither of these should be necessary).
# - Passing -A will explicitly disable idempotence, and cause the script to exit
#   if a build directory already exists. This should be used only in CI, where
#   such error-checking is desireable.
#
# Note that only the first option above is actually guaranteed to be idempotent.

. util/build_consts.sh

echo "Detected \$REPO_TOP at $REPO_TOP."
echo "Object directory set at $OBJ_DIR."
echo "Binary directory set at $BIN_DIR."
echo "OpenTitan version: $OT_VERSION"
echo

function usage() {
  cat << USAGE
Configure Meson build targets.

Usage: $0 [-r|-f|-A|-K|-T|-t]

  -f: Force a reconfiguration by removing existing build dirs.
  -r: Reconfigure build dirs, if they exist.
  -A: Assert that no build dirs exist when running this command.
  -K: Keep include search paths as generated by Meson.
  -t FILE: Configure Meson with toolchain configuration FILE
  -T PATH: Build tock from PATH rather than the remote repository.

USAGE
}

readonly DEFAULT_RISCV_TOOLS=/tools/riscv
TOOLCHAIN_PATH="${TOOLCHAIN_PATH:-$DEFAULT_RISCV_TOOLS}"

FLAGS_assert=false
FLAGS_force=false
FLAGS_reconfigure=""
FLAGS_keep_includes=false
FLAGS_specified_toolchain_file=false
ARG_toolchain_file="${TOOLCHAIN_PATH}/meson-riscv32-unknown-elf-gcc.txt"
ARG_tock_dir=""
while getopts 'r?:f?:K?:A?:T:t:' flag; do
  case "${flag}" in
    f) FLAGS_force=true;;
    r) FLAGS_reconfigure="--reconfigure";;
    A) FLAGS_assert=true;;
    K) FLAGS_keep_includes=true;;
    t) FLAGS_specified_toolchain_file=true
       ARG_toolchain_file="${OPTARG}";;
    T) ARG_tock_dir="${OPTARG}";;
    ?) usage && exit 1;;
    :) usage
       error "${OPTARG} requires a path argument"
       ;;
    *) usage
       error "Unexpected option ${flag}"
       ;;
  esac
done

if [[ ! -n "$(command -v meson)" ]]; then
  echo "Unable to find meson. Please install meson before running this command." >&2
  exit 1
fi

if [[ ! -n "$(command -v ninja)" ]]; then
  echo "Unable to find ninja. Please install ninja before running this command." >&2
  exit 1
fi

if [[ "${FLAGS_force}" == true ]]; then
  rm -rf "$OBJ_DIR"
  rm -rf "$BIN_DIR"
fi

if [[ "${FLAGS_assert}" == true ]]; then
  if [[ -e "$OBJ_DIR" ]]; then
    echo "Object directory at $OBJ_DIR already exists. Aborting." >&2
    exit 1
  fi
  if [[ -e "$BIN_DIR" ]]; then
    echo "Binary directory at $BIN_DIR already exists. Aborting." >&2
    exit 1
  fi
fi

TOCK_LOCAL=false
if [[ ! -z "${ARG_tock_dir}" ]]; then
  TOCK_LOCAL=true

  if [[ ! -d "${ARG_tock_dir}" ]]; then
    echo "Referenced Tock directory ${ARG_tock_dir} doesn't exist. Aborting." >&2
    exit 1
  fi

  if [[ ! -f "${TOCK_SYMLINK}" || -L "${TOCK_SYMLINK}" ]]; then
    echo "Creating symlink to Tock project at ${ARG_tock_dir}."
    ln -sf "${ARG_tock_dir}" "${TOCK_SYMLINK}"
  elif [[ -d "${TOCK_SYMLINK}" ]]; then
    echo "Tock directory $TOCK_SYMLINK exists in place. Leaving as is."
  else
    echo "Placing Tock at ${TOCK_SYMLINK} would clobber something. Aborting." >&2
    exit 1
  fi
fi

if [[ -f "${ARG_toolchain_file}" ]]; then
  echo "Using meson toolchain file at $ARG_toolchain_file." >&2
else
  if [[ "${FLAGS_specified_toolchain_file}" == true ]]; then
    echo "Unable to find meson toolchain file at $ARG_toolchain_file. Aborting." >&2
    exit 1
  else
    cross_file=$(mktemp /tmp/toolchain.XXXXXX.txt)
    cp toolchain.txt "$cross_file"
    perl -pi -e "s#$DEFAULT_RISCV_TOOLS#$TOOLCHAIN_PATH#g" "$cross_file"
    echo "Set up toolchain file at $cross_file." >&2
    ARG_toolchain_file="${cross_file}"
  fi
fi

# purge_includes $build_dir deletes any -I command line arguments that are not
# - Absolute paths.
# - Ephemeral build directories.
#
# This function is necessary because Meson does not give adequate
# control over what directories are passed in as -I search directories
# to the C compiler. While Meson does provide |implicit_include_directories|,
# support for this option is poor: empirically, Meson ignores this option for
# some targerts. Doing it as a post-processing step ensures that Meson does
# not allow improper #includes to compile successfully.
function purge_includes() {
  if [[ "${FLAGS_keep_includes}" == "true" ]]; then
    return
  fi
  echo "Purging superfluous -I arguments from $1."
  local ninja_file="$1/build.ninja"
  perl -pi -e 's#-I[^/][^@ ]+ # #g' -- "$ninja_file"
}

reconf="${FLAGS_reconfigure}"

if [[ ! -d "$OBJ_DIR" ]]; then
  echo "Output directory does not exist at $OBJ_DIR; creating." >&2
  mkdir -p "$OBJ_DIR"
  reconf=""
elif [[ -z "$reconf" ]]; then
  echo "Output directory already exists at $OBJ_DIR; skipping." >&2
  continue
fi

mkdir -p "$DEV_BIN_DIR"
set -x
meson $reconf \
  -Dot_version="$OT_VERSION" \
  -Ddev_bin_dir="$DEV_BIN_DIR" \
  -Dhost_bin_dir="$HOST_BIN_DIR" \
  -Dtock_local="$TOCK_LOCAL" \
  --cross-file="$ARG_toolchain_file" \
  "$OBJ_DIR"
{ set +x; } 2>/dev/null
purge_includes "$OBJ_DIR"