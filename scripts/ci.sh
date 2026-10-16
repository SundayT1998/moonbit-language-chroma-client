#!/usr/bin/env sh
# Shared CI entry point for the chroma-client module.
#
# GitHub Actions (.github/workflows/ci.yml) and CNB (.cnb.yml) both call this
# script so the checks stay identical on every platform. It assumes `moon` is
# already on PATH: GitHub installs it in the workflow, CNB bakes it into
# .cnb/Dockerfile.
#
# The tests that need a real Chroma server live in a separate script
# (scripts/integration.sh), because they need Docker and a published image.
# `moon test` below still covers them: they skip when CHROMA_ENDPOINT is
# unset, which is the case here.
#
# Usage: sh scripts/ci.sh [step ...]
#   steps: update fmt check info test coverage build
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

if has_step update; then
  log "moon version"
  moon version --all
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
