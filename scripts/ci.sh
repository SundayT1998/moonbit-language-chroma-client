#!/usr/bin/env sh
# Shared CI entry point for the chroma-client module.
#
# GitHub Actions (.github/workflows/ci.yml) and CNB (.cnb.yml) both call this
# script so that the checks stay identical on every platform. Running it needs
# nothing but a POSIX shell and curl: it installs the MoonBit toolchain itself
# when `moon` is not already on PATH.
#
# Usage: sh scripts/ci.sh [step ...]
#   steps: install update fmt check info test coverage build
#   (default: every step, in order)
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "${ROOT_DIR}"

TARGET="native"

ALL_STEPS="update fmt check info test coverage build"
if [ "$#" -gt 0 ]; then
  STEPS="$*"
else
  STEPS="${ALL_STEPS}"
fi

log() {
  echo ""
  echo "==> $1"
}

has_step() {
  for step in ${STEPS}; do
    [ "${step}" = "$1" ] && return 0
  done
  return 1
}

install_toolchain() {
  if command -v moon >/dev/null 2>&1; then
    log "MoonBit toolchain"
    moon version --all
    return 0
  fi
  log "installing MoonBit toolchain"
  curl -fsSL https://cli.moonbitlang.com/install/unix.sh | sh
  PATH="${HOME}/.moon/bin:${PATH}"
  export PATH
  moon version --all
}

if has_step update; then
  install_toolchain
  log "moon update"
  moon update
fi

if has_step fmt; then
  log "moon fmt --check"
  moon fmt --check
fi

if has_step check; then
  log "moon check --target ${TARGET} --deny-warn"
  moon check --target "${TARGET}" --deny-warn
fi

if has_step info; then
  log "moon info"
  moon info
  # `moon info` regenerates the .mbti interfaces; a non-empty diff means the
  # committed ones are stale. Only tracked files are compared, so build output
  # (e.g. cobertura.xml) or a local _build/ never fails the run.
  log "git status --porcelain"
  test -z "$(git status --porcelain --untracked-files=no)"
fi

if has_step test; then
  log "moon test --target ${TARGET} --deny-warn --enable-coverage"
  moon test --target "${TARGET}" --deny-warn --enable-coverage
fi

if has_step coverage; then
  log "moon coverage report -f summary"
  moon coverage report -f summary
  log "moon coverage analyze"
  moon coverage analyze
  log "moon coverage report -f cobertura"
  moon coverage report -f cobertura
fi

if has_step build; then
  log "moon build --target ${TARGET}"
  moon build --target "${TARGET}"
  log "moon build --target ${TARGET} --release"
  moon build --target "${TARGET}" --release
fi

# Keep the worktree clean for whoever runs this script locally.
rm -f cobertura.xml

log "CI passed"
