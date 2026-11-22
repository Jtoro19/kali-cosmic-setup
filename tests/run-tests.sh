#!/usr/bin/env bash
# tests/run-tests.sh: run every tests/test-*.sh; exit non-zero if any fails.
# None of them needs sudo or touches the system.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failed=()
shopt -s nullglob
for t in "$DIR"/test-*.sh; do
  printf '== %s\n' "$(basename -- "$t")"
  if ! "$t"; then
    failed+=("$(basename -- "$t")")
  fi
done

if ((${#failed[@]} > 0)); then
  printf '\nFAILED: %s\n' "${failed[*]}"
  exit 1
fi
printf '\nall tests passed\n'
