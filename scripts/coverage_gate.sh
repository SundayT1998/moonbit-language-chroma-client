#!/usr/bin/env sh
# Coverage threshold for the chroma-client module.
#
# `moon coverage report -f summary` prints the numbers, but nothing fails when
# they drop: a new function with no test shows up as a slightly worse
# percentage and slips through review. This script turns the target from the
# issue ("core paths >= 80%") into an exit code.
#
# It reads the cobertura report rather than the summary, because the summary
# is human-formatted and the XML is not. Two exclusions, both deliberate and
# both stated in docs/CONTRIBUTING.md:
#
#   * cmd/main — the demo executable, exercised by running it against a live
#     Chroma server, not by the unit suite;
#   * async_http_transport.mbt — the real socket transport, which only runs in
#     the integration job (it needs a server to talk to).
#
# What is left is the "core path": request building, decoding, error mapping,
# retries, URL handling — the code every caller depends on.
#
# Usage: sh scripts/coverage_gate.sh [threshold]
#   threshold   minimum percentage, default 80
#
# Expects the cobertura report scripts/ci.sh writes (override with
# COVERAGE_REPORT).
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "${ROOT_DIR}"

THRESHOLD="${1:-80}"
REPORT="${COVERAGE_REPORT:-cobertura.xml}"

if [ ! -f "${REPORT}" ]; then
  echo "${REPORT} not found; run \`moon test --enable-coverage\` and" >&2
  echo "\`moon coverage report -f cobertura\` first" >&2
  exit 1
fi

# The report is small XML with a fixed shape (one <class> per file, one <line>
# per instrumented line), so a shell loop is enough and keeps the check
# runnable anywhere `moon` is, with no extra interpreter.
total=0
covered=0
included_files=""

current=""
while IFS= read -r line; do
  case "${line}" in
    *'<class '*)
      # e.g. `        <class name="async.mbt" filename="async.mbt" ...>`
      current=$(printf '%s' "${line}" | sed -n 's/.*filename="\([^"]*\)".*/\1/p')
      case "${current}" in
        cmd/main/main.mbt | async_http_transport.mbt) current="" ;;
        "") ;;
        *) included_files="${included_files} ${current}" ;;
      esac
      ;;
    *'<line '*)
      [ -z "${current}" ] && continue
      total=$((total + 1))
      case "${line}" in
        *'hits="0"'*) ;;
        *) covered=$((covered + 1)) ;;
      esac
      ;;
  esac
done < "${REPORT}"

if [ "${total}" -eq 0 ]; then
  echo "coverage gate: no core-path lines found in ${REPORT}" >&2
  exit 2
fi

# Integer-only shell arithmetic: compare covered/total scaled by 1000 so the
# comparison keeps one decimal place without depending on awk or bc.
scaled=$((covered * 1000 / total))
threshold_scaled=$((THRESHOLD * 10))

echo "core-path coverage: $((scaled / 10)).$((scaled % 10))% (${covered}/${total} lines, threshold ${THRESHOLD}%)"
echo "core-path files:${included_files}"

if [ "${scaled}" -lt "${threshold_scaled}" ]; then
  echo "coverage gate: below the ${THRESHOLD}% target" >&2
  exit 1
fi

echo "coverage gate: ok"
