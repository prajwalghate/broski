#!/bin/bash
# Sets up the repository's GitHub side, once: GitHub Pages built by GitHub Actions, and the About box
# (description, website, topics) that GitHub's search and search engines read. It shows what it will change
# and asks first. Needs the GitHub CLI, signed in with admin access to the repository (gh auth login).
#   scripts/github-setup.sh         show the changes, ask, then make them
#   scripts/github-setup.sh --yes   make them without asking
set -euo pipefail
cd "$(dirname "$0")/.."

# Keep these in step with the README's first paragraph and the site's description.
DESCRIPTION="Open-source AI companion for your projects, on Mac and iPhone. Talk or type: it remembers, thinks with you, and saves notes as plain files. Works with Claude, OpenAI, Gemini or local models."
TOPICS=(macos ios swift swiftui menu-bar-app ai-assistant voice-assistant llm local-first privacy
        mcp mcp-server model-context-protocol ollama openai anthropic gemini note-taking productivity whisper)

command -v gh >/dev/null || { echo "Install the GitHub CLI first: https://cli.github.com" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Sign in to GitHub first: gh auth login" >&2; exit 1; }

repo="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
owner="$(tr '[:upper:]' '[:lower:]' <<<"${repo%%/*}")"
name="${repo#*/}"
# With Pages off, the API answers 404 and gh prints the error's body, so a failed call counts as nothing.
pages="$(gh api "repos/$repo/pages" --jq .build_type 2>/dev/null)" || pages=""
# The site's address: GitHub's own when Pages is on (it knows about a custom domain), else the github.io one.
site="$(gh api "repos/$repo/pages" --jq .html_url 2>/dev/null)" || site=""
if [[ -z "$site" ]]; then
  if [[ "$name" == "$owner.github.io" ]]; then site="https://$owner.github.io/"; else site="https://$owner.github.io/$name/"; fi
fi

echo "Repository: $repo"
echo "  GitHub Pages: ${pages:-off} -> built by GitHub Actions"
echo "  Description:  $DESCRIPTION"
echo "  Website:      $site"
echo "  Topics:       ${TOPICS[*]} (these replace the current topics)"
if [[ "${1:-}" != "--yes" ]]; then
  read -r -p "Make these changes? [y/N] " answer
  [[ "$answer" == [yY]* ]] || { echo "Nothing changed."; exit 0; }
fi

if [[ -z "$pages" ]]; then
  gh api -X POST "repos/$repo/pages" -f build_type=workflow >/dev/null
elif [[ "$pages" != "workflow" ]]; then
  gh api -X PUT "repos/$repo/pages" -f build_type=workflow >/dev/null
fi
gh repo edit "$repo" --description "$DESCRIPTION" --homepage "$site"
topic_args=()
for topic in "${TOPICS[@]}"; do topic_args+=(-f "names[]=$topic"); done
gh api -X PUT "repos/$repo/topics" "${topic_args[@]}" >/dev/null
if ! gh workflow run pages.yml --repo "$repo"; then
  echo "Couldn't start the Pages workflow (is .github/workflows/pages.yml on the default branch?)." >&2
  echo "Push it, or start it from the Actions tab: Pages › Run workflow." >&2
fi

cat <<EOF

Done. The site is building now (the Actions tab shows it) and will be at $site
Two things only the website can do:
  - Settings › General › Social preview: upload site/assets/social-preview.png, the card shown when the repository is shared.
  - Your profile: pin this repository, so it's the first thing people see.
EOF
