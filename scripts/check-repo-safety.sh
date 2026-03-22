#!/usr/bin/env bash
set -euo pipefail

# Fail if any tracked file matches patterns that should never be committed.

bad_patterns=(
  '*.sparsebundle'
  '*.sparseimage'
  '*.pem'
  '*.key'
  '*.p12'
  '*.pfx'
  '*.age'
  '*.gpg'
  '.ssh/*'
  'ssh/*'
  'keys/*'
)

rc=0
for pattern in "${bad_patterns[@]}"; do
  matches="$(git ls-files -- "$pattern" 2>/dev/null || true)"
  if [ -n "$matches" ]; then
    printf 'FAIL: tracked files match forbidden pattern "%s":\n%s\n' "$pattern" "$matches" >&2
    rc=1
  fi
done

if [ "$rc" -eq 0 ]; then
  printf 'repo safety check passed\n'
fi
exit "$rc"
