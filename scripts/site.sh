#!/bin/bash
# The website, as GitHub Pages builds it: the builder's tests, then site/ plus a page for each guide in docs/
# into .build/site. A broken link, a page without a description or a guide left off the site fails it.
#   scripts/site.sh           test and build
#   scripts/site.sh --serve   then serve it at http://localhost:8765 (PORT changes the port)
set -euo pipefail
cd "$(dirname "$0")/.."
port="${PORT:-8765}"

# The builder's tests: one line when they pass, everything when they don't.
if ! tests="$(python3 scripts/site/test_build.py 2>&1)"; then
  echo "$tests" >&2
  exit 1
fi
echo "${tests##*$'\n'}"
# The repository's address, from the origin remote (any GitHub form), so links point at this checkout's repository.
origin="$(git remote get-url origin 2>/dev/null || true)"
path="$(sed -E 's#^(git@github\.com:|ssh://git@github\.com/|https://github\.com/)##; s#\.git$##' <<<"$origin")"
[[ "$path" == */* && "$path" != *:* ]] || path="owner/broski"
python3 scripts/site/build.py --out .build/site --site "http://localhost:$port" --repo "https://github.com/$path"

if [[ "${1:-}" == "--serve" ]]; then
  echo "Serving http://localhost:$port/"
  exec python3 -m http.server "$port" --bind 127.0.0.1 --directory .build/site
fi
