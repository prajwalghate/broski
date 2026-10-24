#!/bin/bash
# Points git at the repo's hooks (.githooks): a secret scan before every commit.
set -euo pipefail
cd "$(dirname "$0")/.."
git config core.hooksPath .githooks
chmod +x .githooks/* scripts/*.sh
echo "Hooks installed: the secret scan runs before every commit."
[[ -f .secretscan-local ]] || echo "Tip: list your own private words (names, client projects, IDs) in .secretscan-local; it's never committed."
