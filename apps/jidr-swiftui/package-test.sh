#!/bin/bash
# One packaging implementation: the production bundle with isolated rehearsal checks.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
exec cargo xtask release --rehearsal "$@"
