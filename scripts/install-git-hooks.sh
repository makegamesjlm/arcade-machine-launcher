#!/usr/bin/env bash

set -euo pipefail

repo_root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
chmod +x "$repo_root/.githooks/pre-commit"
git -C "$repo_root" config core.hooksPath .githooks
printf 'Git hooks enabled for %s\n' "$repo_root"
