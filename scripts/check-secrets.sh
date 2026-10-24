#!/bin/bash
# Stops secrets and private words before they're committed.
#   scripts/check-secrets.sh            scan every file git tracks
#   scripts/check-secrets.sh --staged   scan what's staged (the pre-commit hook runs this)
# Your own private words (names, client projects, IDs) go in .secretscan-local, one per line; that file is never
# committed. A line that must keep a match (a test fixture) ends with the marker "secretscan:allow".
set -euo pipefail
cd "$(dirname "$0")/.."

patterns=(
  'sk-ant-[A-Za-z0-9_-]{20,}'          # Anthropic API keys
  'sk-(proj-)?[A-Za-z0-9]{32,}'        # OpenAI API keys
  'gh[pousr]_[A-Za-z0-9]{36,}'         # GitHub tokens
  'AKIA[0-9A-Z]{16}'                   # AWS access keys
  'AIza[0-9A-Za-z_-]{35}'              # Google API keys
  'xox[baprs]-[A-Za-z0-9-]{10,}'       # Slack tokens
  'BEGIN [A-Z ]*PRIVATE KEY'           # private keys
  'google-oauth2_[0-9]+'               # account ids trackers must redact
)

if [[ "${1:-}" == "--staged" ]]; then
  files=$(git diff --cached --name-only --diff-filter=ACMR)
else
  files=$(git ls-files)
fi

words=()
if [[ -f .secretscan-local ]]; then
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    words+=("$line")
  done < .secretscan-local
fi

found=0
while IFS= read -r file; do
  [[ -z "$file" || ! -f "$file" || "$file" == "scripts/check-secrets.sh" ]] && continue
  for pattern in "${patterns[@]}"; do
    if hits=$(grep -nIE -- "$pattern" "$file" | grep -v "secretscan:allow"); then
      echo "$file: looks like a secret ($pattern)"; echo "$hits" | sed 's/^/    /' | cut -c1-160; found=1
    fi
  done
  for word in "${words[@]+"${words[@]}"}"; do
    if hits=$(grep -nIiF -- "$word" "$file" | grep -v "secretscan:allow"); then
      echo "$file: contains a private word from .secretscan-local"; echo "$hits" | sed 's/^/    /' | cut -c1-160; found=1
    fi
  done
done <<< "$files"

if [[ $found -ne 0 ]]; then
  echo
  echo "Secret scan failed. Remove the values above (or mark a test fixture line with secretscan:allow)."
  exit 1
fi
echo "Secret scan: clean"
