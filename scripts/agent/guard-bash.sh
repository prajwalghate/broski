#!/bin/bash
# PreToolUse hook for Bash (.claude/settings.json): stops the commands that do damage on this project before they
# run. "deny" stops the command and tells the agent why; "ask" puts the decision to the person at the keyboard.
# Tested by scripts/agent/test-hooks.sh. Reads the hook's JSON on stdin.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

cmd="$(jq -r '.tool_input.command // ""' 2>/dev/null)"
[[ -z "$cmd" ]] && exit 0
# What runs, without heredoc bodies and commit messages: text that only mentions ".env" or "--force" isn't a command.
scan="$(perl -0pe 's/<<-?\s*([\x27"]?)(\w+)\1.*?\n\2(?=\n|$)//gs; s/(?:-m|--message)\s+(?:"(?:[^"\\]|\\.)*"|\x27[^\x27]*\x27)//g' <<<"$cmd")"

decide() {
  jq -nc --arg d "$1" --arg r "$2" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: $d, permissionDecisionReason: $r}}'
  exit 0
}
deny() { decide deny "$1"; }
ask() { decide ask "$1"; }
has() { grep -qE -- "$1" <<<"$scan"; }

S='[[:space:]]'
END='([[:space:];&|)]|$)'
REAL_DATA='(com~apple~CloudDocs/Broski|~/Broski|\$HOME/Broski|/Users/[^/[:space:]]+/Broski)([/[:space:]"'"'"']|$)'
APP_DATA='Application(\\ | )Support/Broski'
WRITERS="(^|[;&|(\`]|$S)(rm|mv|cp|ditto|rsync|truncate|tee|chmod|chown|ln|unlink|shred)$S"

# Secrets and private data: never read, whatever the tool.
if has "$APP_DATA/secrets\.json"; then
  deny "That file holds the API keys. Agents never read it; ask the person to check a key in Settings."
fi
if has "(^|$S)security$S+(find-generic-password|find-internet-password|dump-keychain)"; then
  deny "Keychain items are secrets. Agents never read them."
fi
read -ra words <<<"$(tr '\n' ' ' <<<"$scan")"
for word in "${words[@]}"; do
  word="${word//[\"\'()]/}"
  word="${word%%[;&|]*}"
  [[ -z "$word" || "$word" == -* || "$word" == *[*?]* ]] && continue
  base="${word##*/}"
  if [[ "$base" =~ ^\.env(\..+)?$ && ! "$base" =~ ^\.env\.(example|sample|template)$ ]] \
    || [[ "$base" =~ \.(db|sqlite|sqlite3)$ ]] || [[ "$base" == "Local.env" ]]; then
    deny "$word is a secret or database file. Broski's rules: never read .env*, *.db or iOS/Local.env."
  fi
done

if has "(^|[;&|[:space:]])sudo$S"; then
  deny "No sudo here: nothing in Broski's work needs it, and system settings are the person's to change."
fi

# One build at a time on an 8 GB Mac.
if has "$BUILD_RE" && builds="$(running_builds)"; then
  deny "Another build is running ($builds). This Mac has 8 GB, so one build at a time: wait for it to finish (or stop it), then run this."
fi

# Git: history on GitHub and the hooks that guard commits stay as they are.
if has "git$S+push($S.*)?$S(-f|--force|--force-with-lease[^[:space:]]*|--force-if-includes|--mirror|--delete|-d)$END" \
  || has "git$S+push($S.*)?$S\+[^[:space:]]+" || has "git$S+push($S+[^[:space:]]+)?$S+:[^[:space:]]+"; then
  deny "No force-pushes or remote branch deletes: they rewrite or remove what's on GitHub. Push a new commit instead."
fi
if has "git$S+(commit|push|merge|rebase|am|cherry-pick)($S.*)?$S--no-verify$END" || has "git$S+commit($S.*)?$S-n$END"; then
  deny "No --no-verify: the hooks are the secret scan and the check that the code passed its tests. Fix what they report."
fi
if has "git$S+(-c$S*core\.hooksPath|config($S.*)?core\.hooksPath)" && ! has "git$S+config$S+core\.hooksPath$S+\.githooks$END"; then
  deny "The git hooks stay pointed at .githooks (scripts/install-hooks.sh). Don't turn them off."
fi
if has "git$S+reset($S.*)?$S--hard" || has "git$S+clean($S.*)?$S-[a-zA-Z]*f" || has "git$S+checkout($S.*)?$S--$S" \
  || has "git$S+checkout$S+\.$END" || has "git$S+stash$S+(drop|clear)" || has "git$S+branch($S.*)?$S-D$END" \
  || has "git$S+(rebase|filter-branch|filter-repo)$END" || has "git$S+rebase$S"; then
  ask "This throws away work or rewrites history (uncommitted changes, stashes, branches or commits). Approve only if you meant to lose it."
fi
if has "git$S+restore$END" && ! has "git$S+restore$S.*--staged"; then
  ask "git restore throws away uncommitted changes in those files. Approve only if you meant to lose them."
fi
if has "git$S+commit($S.*)?$S--amend$END" && [[ -n "$(cd "$BROSKI_ROOT" && git branch -r --contains HEAD 2>/dev/null)" ]]; then
  ask "The last commit is already on GitHub; amending it means a force-push. Make a new commit instead, unless you're sure."
fi

# The installed app and the person's real data.
if has "(^|[;&|(\`]|$S)(rm|mv)$S.*/Applications/Broski\.app" || has "(ditto|cp|rsync)$S.*$S\"?/Applications/Broski\.app\"?/?$END"; then
  deny "Install with scripts/install-mac.sh: it checks the new build reads your data, keeps the current version to roll back to, and makes sure the new one starts."
fi
if has "(^|[;&|(\`]|$S)(pkill|killall)$S.*Broski$END"; then
  ask "This quits the Broski the person is using right now."
fi
if has "$REAL_DATA" || has "$APP_DATA"; then
  if has "$WRITERS" || has "sed$S+(-[a-zA-Z]*$S+)*-i" || has "find$S.*-delete" || has ">>?$S*\"?[^[:space:]]*(CloudDocs/Broski|/Broski/|Support/Broski)"; then
    ask "This changes the person's real Broski folder (their notes, conversations, vault, keys). Tests use a temporary folder; approve only if this is meant."
  fi
fi
if has "defaults$S+(write|delete)$S+dev\.broski\.app"; then
  ask "This changes the settings of the Broski the person is using."
fi
exit 0
