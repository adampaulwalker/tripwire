#!/bin/bash
# check-rules.sh - the guard that guards the guidance.
#
# Every rule in your registry was added after something went wrong. A rule that
# can be quietly deleted is back to being prose, and prose does not execute.
# This asserts the guidance is STILL THERE, in every file that needs it, and
# that each executable proof still passes.
#
# Three phases, and NONE of them may vanish quietly:
#   1. registry - every (target, marker) pair in rules.tsv is still present
#   2. proofs   - every guard_test.* under the skills tree still exits 0
#   3. drift    - shared rules are byte-identical across their consumers
#
# A phase with nothing to do is a FAILURE unless the registry says otherwise in
# writing. `proofs: none - <reason>` and `shared-rules: none - <reason>` are the
# two declarations that turn a missing phase into a recorded, reasoned skip.
# Absence on its own never passes.
#
# Usage:  bash check-rules.sh [--rules FILE] [--skills DIR]
# Exit 0 clean, 1 a check fired, 2 the gate could not run.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULES_FILE=""
RULES_EXPLICIT=0
SKILLS=""
SKILLS_EXPLICIT=0

die()  { printf 'check-rules: %s\n' "$1" >&2; exit 2; }
need() { [ "$2" -ge 2 ] || die "$1 needs a value"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --rules)   need "$1" $#; RULES_FILE="$2"; RULES_EXPLICIT=1;  shift 2 ;;
    --skills)  need "$1" $#; SKILLS="$2";     SKILLS_EXPLICIT=1; shift 2 ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    --*)       die "unknown option: $1" ;;
    *)         [ -n "$SKILLS" ] && die "more than one skills directory given"
               SKILLS="$1"; SKILLS_EXPLICIT=1; shift ;;
  esac
done

# An explicitly named path that does not exist is a typo, never a reason to
# silently inspect some other tree and report a pass about it.
if [ "$SKILLS_EXPLICIT" = 1 ]; then
  [ -d "$SKILLS" ] || die "--skills directory not found: $SKILLS"
else
  for cand in "${CLAUDE_SKILLS_DIR:-}" "$(dirname "$HERE")" "$HOME/.claude/skills"; do
    [ -n "$cand" ] && [ -d "$cand" ] && { SKILLS="$cand"; break; }
  done
  [ -n "$SKILLS" ] || die "no skills directory found. FIX: pass --skills DIR, or set CLAUDE_SKILLS_DIR."
fi
SKILLS="$(cd "$SKILLS" && pwd -P)"

if [ "$RULES_EXPLICIT" = 1 ]; then
  [ -r "$RULES_FILE" ] || die "--rules file not found or not readable: $RULES_FILE"
else
  # The registry belongs to the tree being checked. "$HERE/rules.tsv" used to
  # be the last fallback, which applied one installation's registry to every
  # other tree and made a missing registry fire for the wrong reason.
  for cand in "${CLAUDE_HOOKS_RULES:-}" "$SKILLS/tripwire/rules.tsv" "$SKILLS/rules.tsv"; do
    [ -n "$cand" ] && [ -f "$cand" ] && { RULES_FILE="$cand"; break; }
  done
fi

# Read the registry ONCE into a private copy. Reading the path twice - once for
# the waiver lines, once for the rules - silently yields an empty second pass
# when the registry is a pipe or a process substitution, and "0 rules" is a very
# confident-looking way to have inspected nothing.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tripwire-check.XXXXXX")" || die "mktemp failed"
[ -n "$WORK" ] && [ -d "$WORK" ] || die "mktemp produced no directory"
trap 'rm -rf "$WORK"' EXIT
REG="$WORK/rules.tsv"
if [ -n "$RULES_FILE" ]; then
  cat -- "$RULES_FILE" > "$REG" || die "could not read registry: $RULES_FILE"
fi

FAIL=0
SKIPS=0
pass() { printf '  [PASS] %s\n' "$1"; }
fire() { printf '  [FIRE] %s\n      -> %s\n' "$1" "$2"; FAIL=1; }
skip() { printf '  [SKIP] %s\n      -> %s\n' "$1" "$2"; SKIPS=$((SKIPS + 1)); }

printf 'check-rules: is the guidance still in the skills?\n'
printf '  skills:   %s\n' "$SKILLS"
printf '  registry: %s\n' "${RULES_FILE:-<none>}"
printf '\n'

# Declared exemptions, read from the registry before anything else runs.
PROOFS_WAIVER=""
SHARED_WAIVER=""
if [ -n "$RULES_FILE" ]; then
  # Parsed by registry.py, never re-split here. Two parsers for one format
  # disagreed about whether a row with a leading space was guarded, which is
  # the vendored-copy defect this skill exists to name.
  [ -f "$HERE/registry.py" ] || die "registry.py is missing - the registry parser is gone"

  # Produced into a FILE, and the producer's status checked, before a single
  # record is read. `while read < <(python3 ...)` discards the child's exit
  # status: a parser that emitted one good record and then crashed left the
  # loop looking successful and the remaining rules silently gone.
  reg_run() {
    local out="$1" want="$2" cmd="$3"; shift 3
    if ! python3 "$HERE/registry.py" "$cmd" "$REG" "$@" > "$out" 2>"$WORK/regerr"; then
      die "$(sed 's/^registry: //' "$WORK/regerr" | head -2 | tr '\n' ' ')"
    fi
    # Framing is validated by the parser itself, not by counting NULs here.
    # A shell count could not see a COMPLETE record followed by an unterminated
    # tail - the separator count still divides - and the counting pipeline's own
    # failure would read as a count of zero, which divides by anything.
    if ! python3 "$HERE/registry.py" frame "$out" "$want" 2>"$WORK/frameerr"; then
      die "$(sed 's/^registry: //' "$WORK/frameerr" | head -2 | tr '\n' ' ')"
    fi
  }

  reg_run "$WORK/waivers" 2 waivers
  while IFS= read -r -d '' kind && IFS= read -r -d '' reason; do
    case "$kind" in
      proofs)       PROOFS_WAIVER="$reason" ;;
      shared-rules) SHARED_WAIVER="$reason" ;;
    esac
  done < "$WORK/waivers"
fi

# ---- 1. registry ---------------------------------------------------------
if [ -z "$RULES_FILE" ]; then
  fire "no rules registry" \
       "create rules.tsv next to this script (copy rules.example.tsv), or pass --rules FILE. An empty registry is a dead gate, not a clean run."
else
  # A malformed row stops the run before anything is counted as checked.
  if ! rowerr=$(python3 "$HERE/registry.py" validate "$REG" 2>&1); then
    die "$(printf '%s' "$rowerr" | sed 's/^registry: //')"
  fi
  reg_run "$WORK/rows" 4 rows --skills "$SKILLS"

  CHECKED=0
  while IFS= read -r -d '' target && IFS= read -r -d '' marker \
     && IFS= read -r -d '' why && IFS= read -r -d '' f; do
    CHECKED=$((CHECKED + 1))
    if [ ! -f "$f" ]; then
      fire "$target" "${f#"$SKILLS"/} is missing"
      continue
    fi
    # -e and -- so a marker beginning with "-" is a literal string, not an
    # option. Without them, a marker of "-eHooks" made grep search for "Hooks"
    # and report a PASS on a rule that was never in the file.
    if grep -qF -e "$marker" -- "$f"; then
      pass "$target carries: $marker"
    else
      fire "$target LOST: $marker" "$why"
    fi
  done < "$WORK/rows"

  if [ "$CHECKED" = "0" ]; then
    fire "registry parsed to 0 rules" \
         "$RULES_FILE has no usable lines. Format: target|MARKER TEXT|what it cost. A check that inspects nothing is not a pass."
  fi
fi

# ---- 2. executable proofs ------------------------------------------------
# Discovered, never listed. A hardcoded list cannot see a proof in a directory
# nobody added to the list, so absence would be invisible - the failure this
# whole skill is about.
#
# -L because a skills directory is very often a symlink into a config
# repository; without it, discovery silently found nothing at all.
# -print0 because a newline in a filename would otherwise split one path into
# two commands.
printf '\n'
PROOF_LIST="$WORK/proofs"

# The whole tree, to whatever depth. A bound would silently omit a guard at
# <skills>/<skill>/tests/unit/guard_test.py while the summary claimed every
# guard had run - absence made invisible, which is the failure this skill is
# about. The blast radius is held instead by the runner whitelist below: only
# .sh and .py are ever executed, and anything else fires rather than running.
find -L "$SKILLS" -type f \( -name 'guard_test.*' -o -name 'tripwire_test.*' \) \
     -not -path '*/.git/*' -not -path '*/node_modules/*' -print0 2>/dev/null \
  | sort -z > "$PROOF_LIST"
PIPE=("${PIPESTATUS[@]}")

# EVERY stage, not just find. A failed sort, or a redirection that could not be
# created, yields an empty or truncated list - and an empty list is waivable,
# so a broken pipeline could be reported as a declared skip.
DISCOVERY_ERR=""
[ "${PIPE[0]}" -ne 0 ] && DISCOVERY_ERR="find exited ${PIPE[0]}"
[ "${PIPE[1]:-0}" -ne 0 ] && DISCOVERY_ERR="${DISCOVERY_ERR:+$DISCOVERY_ERR; }sort exited ${PIPE[1]}"
[ -f "$PROOF_LIST" ] || DISCOVERY_ERR="${DISCOVERY_ERR:+$DISCOVERY_ERR; }the discovery list was never created"

if [ -n "$DISCOVERY_ERR" ]; then
  fire "proof discovery FAILED ($DISCOVERY_ERR)" \
       "the walk over $SKILLS did not complete, so any proof verdict would be drawn from a partial tree. No waiver applies to a broken scan. Fix the permissions or the path, then re-run."
else
  PROOFS=0
  while IFS= read -r -d '' p; do
    PROOFS=$((PROOFS + 1))
    rel="${p#"$SKILLS"/}"
    # Only interpreters this script chose. Executing whatever a discovery walk
    # happened to match is not a gate, it is a foot-gun.
    case "$p" in
      *.py) runner=(python3 "$p") ;;
      *.sh) runner=(bash "$p") ;;
      *)    fire "unknown proof type: $rel" \
                 "check-rules runs .sh and .py guards only, and will not execute anything else it finds. Rename it, or wrap it in a guard_test.sh that calls it."
            continue ;;
    esac
    # stdin from /dev/null: a guard that reads stdin would otherwise swallow
    # the rest of the discovery list and the guards after it would never run,
    # while the summary reported a clean pass.
    if out=$("${runner[@]}" </dev/null 2>&1); then
      pass "proof passes: $rel"
    else
      fire "proof FAILS: $rel" "$(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
    fi
  done < "$PROOF_LIST"

  if [ "$PROOFS" = "0" ]; then
    if [ -n "$PROOFS_WAIVER" ]; then
      skip "executable proofs" "declared in the registry: $PROOFS_WAIVER"
    else
      fire "no executable proofs" \
           "no guard_test.sh / guard_test.py under $SKILLS. A rule with no executable proof is advice. FIX: write one, or record why there is none by adding this line to $RULES_FILE:  proofs: none - <reason>"
    fi
  else
    pass "$PROOFS executable proof(s) discovered and run"
  fi
fi

# ---- 3. shared-rule drift ------------------------------------------------
# A rule needed by several skills is a vendored copy, with the drift problem
# vendored copies always have. SHARED-RULES.md is canonical; sync-rules.py
# pushes it; this refuses if any consumer differs by a byte.
printf '\n'
if [ ! -f "$HERE/sync-rules.py" ]; then
  fire "sync-rules.py is missing" \
       "the drift gate cannot run, so shared rules are unguarded. Restore it from the repo."
else
  out=$(python3 "$HERE/sync-rules.py" --check --skills "$SKILLS" 2>&1); rc=$?
  case "$rc" in
    0) pass "shared rules identical across every consumer skill" ;;
    3) # Somebody DID configure a canonical file and the path is wrong. A typo
       # is not an absence, so no waiver may quiet it.
       fire "the shared-rules canonical path is configured and wrong" \
            "$(printf '%s' "$out" | head -1) A declared skip covers a phase with nothing to do, never a broken configuration." ;;
    2) if [ -n "$SHARED_WAIVER" ]; then
         skip "shared-rule drift" "declared in the registry: $SHARED_WAIVER"
       else
         fire "shared-rule drift gate is NOT CONFIGURED" \
              "$(printf '%s' "$out" | head -1) FIX: create SHARED-RULES.md beside sync-rules.py, or record why there is none by adding this line to ${RULES_FILE:-rules.tsv}:  shared-rules: none - <reason>"
       fi ;;
    *) fire "a shared rule has DRIFTED between skills" \
            "$(printf '%s' "$out" | sed -n '2p' | sed 's/^ *//')  FIX: python3 sync-rules.py" ;;
  esac
fi

# A SKIP is not a result. Counting them here is the difference between a gap you
# know about and a gap that vanished into a summary line.
printf '\n'
if [ "$FAIL" = "0" ]; then
  if [ "$SKIPS" = "0" ]; then
    echo "check-rules: clean - 0 skipped"
  else
    echo "check-rules: clean - but $SKIPS declared skip(s), each with a written reason above. A skip is a gap, not a pass."
  fi
else
  echo "check-rules: FIRED ($SKIPS skipped)"
fi
exit "$FAIL"
