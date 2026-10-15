#!/usr/bin/env sh
# Install the MoonBit toolchain and add it to the PATH for the current shell.
#
# Usage:
#   . scripts/install-moonbit.sh   # sourced: also updates PATH
#   sh scripts/install-moonbit.sh  # executed: installs only
set -e

MOON_DIR="${HOME}/.moon"
BIN_DIR="${MOON_DIR}/bin"

install_moonbit() {
  if [ -x "${BIN_DIR}/moon" ]; then
    echo "[install-moonbit] moon already installed at ${BIN_DIR}/moon"
    return 0
  fi

  echo "[install-moonbit] installing MoonBit toolchain..."
  curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash

  if [ ! -x "${BIN_DIR}/moon" ]; then
    echo "[install-moonbit] error: ${BIN_DIR}/moon not found after install" >&2
    return 1
  fi
}

install_moonbit

export PATH="${BIN_DIR}:${PATH}"

case "${PATH}" in
  *"${BIN_DIR}"*) ;;
  *) echo "[install-moonbit] warning: ${BIN_DIR} not on PATH" >&2 ;;
esac

moon version --all
