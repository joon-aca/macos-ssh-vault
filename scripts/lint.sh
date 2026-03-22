#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)"

shellcheck \
  "${REPO_ROOT}/bin/ssh-vault" \
  "${REPO_ROOT}/bootstrap" \
  "${REPO_ROOT}/libexec/ssh-vault/common.sh" \
  "${REPO_ROOT}/scripts/lint.sh" \
  "${REPO_ROOT}/scripts/check-repo-safety.sh"

"${REPO_ROOT}/scripts/check-repo-safety.sh"

printf 'all checks passed\n'
