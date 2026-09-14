#!/bin/bash
# install.sh - link this skill into Claude Code and prove the gates still fire.
#
# Usage:  bash install.sh [--skills DIR] [--copy]
#
#   --skills DIR  where your skills live (default: $CLAUDE_SKILLS_DIR, else
#                 ~/.claude/skills)
#   --copy        copy instead of symlinking. Default is a symlink, so a
#                 `git pull` here updates the installed skill.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
MODE="link"

die() { printf 'install: %s\n' "$1" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --skills) [ $# -ge 2 ] || die "--skills needs a value"; SKILLS="$2"; shift 2 ;;
    --copy)   MODE="copy"; shift ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# Never trust a gate you have not watched fail. This runs before anything is
# installed, so a broken checkout cannot become an installed skill.
echo "==> proving the gates can fail"
bash "$HERE/selftest.sh" | tail -1

mkdir -p "$SKILLS"
SKILLS="$(cd "$SKILLS" && pwd)"
DEST="$SKILLS/tripwire"

if [ -e "$DEST" ] || [ -L "$DEST" ]; then
  die "$DEST already exists. Remove or rename it first, then run this again."
fi

if [ "$MODE" = "link" ]; then
  ln -s "$HERE" "$DEST"
  echo "==> linked $DEST -> $HERE"
else
  cp -R "$HERE" "$DEST"
  rm -rf "$DEST/.git" "$DEST/.claude"
  echo "==> copied to $DEST"
fi

# Every path below names the INSTALLED copy, and passes --skills explicitly.
# Configuring the source checkout instead would leave the installed skill
# unconfigured under --copy, and letting check-rules.sh pick its own default
# would point it at this checkout's PARENT directory - which, for a clone
# sitting in a folder of other repositories, means discovering and running
# guard files in projects that have nothing to do with this.
cat <<NEXT

Start here - it reads every skill you have and tells you which rules
nothing enforces:

  "$DEST/tripwire" scan --skills "$SKILLS"

Then, and it is not optional:

  1. cp "$DEST/rules.example.tsv" "$DEST/rules.tsv"
     Replace every line with a rule of yours that has actually been broken.
     The scan above is where to find them.

  2. "$DEST/tripwire" check --skills "$SKILLS"

Until step 1, check-rules.sh fails with 'no rules registry'. That is
deliberate: an empty registry is a dead gate, not a clean run. It will also
refuse until you either write an executable guard or record, in rules.tsv, why
there is none:

  proofs: none - <reason>
  shared-rules: none - <reason>

Always pass --skills explicitly. Without it the script guesses, and a guess is
how a gate ends up inspecting a tree nobody meant it to.
NEXT
