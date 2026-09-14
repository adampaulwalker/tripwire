#!/bin/bash
# conformance.sh - does THIS PROJECT carry the mechanisms, or only the advice?
#
# Asserting that a rule's text is still in a document guards the guidance from
# deletion and nothing else. It cannot tell you whether a project built with
# that guidance implemented anything.
#
# So this asks the PROJECT. Each mechanism is claimed by a MARKER at the code -
# `tripwire:<id>` in the file that implements it - because a central registry of
# "yes we did that" goes stale in a week, while a marker sits in the diff where
# a reviewer sees it.
#
# ABSENCE IS A FAILURE, never a skip. A project that never built a coverage map
# must not be able to report that it has one by saying nothing.
#
# A MARKER IS ONLY A CLAIM WHERE IT COULD RUN. A hit in a document, a data file
# or on a TODO line is a plan. Each of those fails with its own reason, because
# a refusal that does not say what it read gets worked around.
#
# Usage:  bash conformance.sh [--quiet] [--mechanisms FILE] [project-dir]
# Exit 0 all mechanisms present, 1 any missing, 2 the gate could not run.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$HERE/$(basename "${BASH_SOURCE[0]}")"
QUIET=0
MECHFILE=""
MECHFILE_EXPLICIT=0
ROOT=""

die() { printf 'conformance: %s\n' "$1" >&2; exit 2; }

# A missing option value must not shift past the end and spin forever. errexit
# is off here deliberately, so `shift 2` failing would loop, not stop.
need() { [ "$2" -ge 2 ] || die "$1 needs a value"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --quiet)      QUIET=1; shift ;;
    --mechanisms) need "$1" $#; MECHFILE="$2"; MECHFILE_EXPLICIT=1; shift 2 ;;
    -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
    --*)          die "unknown option: $1" ;;
    *)            [ -n "$ROOT" ] && die "more than one project directory given"
                  # An empty positional is an unset shell variable, not a
                  # request to scan the current directory. Falling back would
                  # give a confident verdict about a tree nobody named.
                  [ -n "$1" ] || die "the project directory is an empty value. That is usually an unset shell variable; refusing rather than scanning a tree nobody named."
                  ROOT="$1"; shift ;;
  esac
done
ROOT="${ROOT:-$PWD}"

[ -d "$ROOT" ] || die "no such directory: $ROOT"
ROOT="$(cd "$ROOT" && pwd)"

# An explicitly named mechanism file that cannot be read is a configuration
# error, never a reason to quietly fall back to the built-in defaults and report
# a pass against a specification nobody asked for.
if [ "$MECHFILE_EXPLICIT" = 1 ]; then
  [ -f "$MECHFILE" ] || die "--mechanisms file not found: $MECHFILE"
  [ -r "$MECHFILE" ] || die "--mechanisms file not readable: $MECHFILE"
else
  for cand in "$ROOT/.tripwire-mechanisms" "${CLAUDE_HOOKS_MECHANISMS:-}"; do
    [ -n "$cand" ] && [ -f "$cand" ] && { MECHFILE="$cand"; break; }
  done
fi

# One scratch directory for the whole run.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tripwire-conf.XXXXXX")" || die "mktemp failed"
[ -n "$WORK" ] && [ -d "$WORK" ] || die "mktemp produced no directory"
trap 'rm -rf "$WORK"' EXIT

MECHFILE_ABS=""
[ -n "$MECHFILE" ] && MECHFILE_ABS="$(cd "$(dirname "$MECHFILE")" && pwd)/$(basename "$MECHFILE")"

FAIL=0
say()  { [ "$QUIET" = 1 ] || printf '%s\n' "$1"; }
pass() { say "  [PASS] $1"; }
fire() { printf '  [FIRE] %s\n      -> %s\n' "$1" "$2"; FAIL=1; }

# marker id | what it must be | why it exists | how to clear it
DEFAULT_MECHS=(
"coverage-map|a test that enumerates the system's SURFACES from the shipped code and forces each into covered-by-a-named-test or not-covered-with-a-reason|weeks of review rounds each declared complete and found more, because complete meant 'the checks I wrote pass'|write it, mark it 'tripwire:coverage-map', and make an undeclared surface FAIL"
"dark-guards|a meta-test over the guards: every section or heading they name exists, and no guard's assertions are all conditional|23 guards raised before their first assertion for weeks while reporting red; 8 more would have gone green the day their subject vanished|write it, mark it 'tripwire:dark-guards'"
"failure-ceiling|a declared, SMALL number of tolerated failures that the suite is checked against|a quoted '34 pre-existing failures' appeared in every status report and hid a template shipping the literal text None in all six charts|declare it, mark it 'tripwire:failure-ceiling', and make it a number you can explain"
"outcome-guards|a check that no test asserts ONLY by reading source|half the guards written in one day were source greps; one passed while the artifact kept a wrong label baked into the template|write it, mark it 'tripwire:outcome-guards'"
)

MECHS=()
if [ -n "$MECHFILE" ] && [ -f "$MECHFILE" ]; then
  LINENO_M=0
  # `|| [ -n "$line" ]` so a final record with no trailing newline is still
  # read. Without it the last mechanism in a hand-edited file is never checked,
  # and a missing mechanism silently becomes a pass.
  while IFS= read -r line || [ -n "$line" ]; do
    LINENO_M=$((LINENO_M + 1))
    case "$line" in ''|\#*) continue ;; esac
    # id|what|why|how - four fields, none empty. A malformed row must stop the
    # run, not be skipped into a smaller specification.
    n=$(printf '%s' "$line" | awk -F'|' '{print NF}')
    [ "$n" -eq 4 ] || die "$MECHFILE line $LINENO_M: need 4 '|'-separated fields, found $n"
    f1="${line%%|*}"; r1="${line#*|}"
    f2="${r1%%|*}";   r2="${r1#*|}"
    f3="${r2%%|*}";   f4="${r2#*|}"
    for pair in "id:$f1" "what:$f2" "why:$f3" "how:$f4"; do
      [ -n "${pair#*:}" ] || die "$MECHFILE line $LINENO_M: empty ${pair%%:*} field - a specification with a blank field cannot say what it wants or why"
    done
    # The id is interpolated into an extended regular expression below. An id
    # like `a.b` would quietly become a pattern and credit `axb`, so the token
    # grammar is enforced here rather than escaped later.
    printf '%s' "$f1" | grep -qxE '[A-Za-z0-9][A-Za-z0-9_-]*' \
      || die "$MECHFILE line $LINENO_M: '$f1' is not a usable mechanism id. Use letters and digits, then - and _"
    MECHS+=("$line")
  done < "$MECHFILE"
  [ "${#MECHS[@]}" -gt 0 ] || die "$MECHFILE declares no mechanisms - a specification that asks for nothing is not a pass"
fi
[ "${#MECHS[@]}" -eq 0 ] && MECHS=("${DEFAULT_MECHS[@]}")

# Where a marker does NOT count as a claim.
#   documents  - a plan, not a mechanism
#   data       - manifests, lockfiles and configuration describe; they do not run
# Tested against the real filename, case-insensitively, so plan.JSON is not
# quietly promoted to an implementation.
# Declared once and used as the `case` patterns below, so the two lists cannot
# drift apart - the exact defect this skill's parity gate exists to catch.
DOC_EXT='md|markdown|mdx|txt|rst|adoc|org|htm|html|pdf'
DATA_EXT='tsv|csv|json|yaml|yml|toml|lock|ini|cfg|conf|properties|plist'

# A marker on one of these lines announces intent. Matched case-insensitively:
# "todo" and "TODO" are the same promise.
# "one day" was in this list and came straight back out: on the first real
# project it matched the incident prose "half the guards written in one day",
# and reported a mechanism as a plan. A token that appears in the language
# people use to record what something COST cannot also mean it is unbuilt.
TODO_RE='(TODO|FIXME|XXX|HACK|@todo|WIP[: ]|not yet|next quarter|someday|should add|plan to add|once the)'

# A mechanism SPECIFICATION lists every id as data, in `id|what|why|how` rows.
# Scanning a tree that contains one credited the specification as an
# implementation of the thing it specifies. Three or more field separators on
# the marker's own line is that format and nothing else.
SPEC_LINE_PIPES=3

# worktrees hold a second checkout of the same repository. A mechanism found
# there is a copy that is not the one running, which is this skill's own rule
# about naming the copy that runs - and it credited one on the first real tree
# it was pointed at.
EXCLUDES=(--exclude-dir=.git --exclude-dir=node_modules --exclude-dir=.venv
          --exclude-dir=venv --exclude-dir=__pycache__ --exclude-dir=dist
          --exclude-dir=build --exclude-dir=target --exclude-dir=vendor
          --exclude-dir=.next --exclude-dir=.tox --exclude-dir=coverage
          --exclude-dir=worktrees)

say "conformance: does this project carry the mechanisms, or only the advice?"
say "  project:      $ROOT"
say "  mechanisms:   ${MECHFILE:-<built-in defaults>} (${#MECHS[@]})"
say ""

# lower <string> - portable lowercase. bash 3.2 has no ${v,,}.
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Each list is declared once, above, and tested through one function, so the
# two cannot drift apart - the exact defect the parity gate exists to catch.
is_doc()  { printf '%s' "$1" | grep -qxE "$DOC_EXT"; }
is_data() { printf '%s' "$1" | grep -qxE "$DATA_EXT"; }

# grep -I decides from an initial buffer, so a file whose first NUL sits past it
# is returned as a text match and used to satisfy a mechanism. This reads the
# whole file: if deleting NUL bytes changes it, it had some, and it is binary.
#
# An operational failure is NOT binary. Treating an unreadable file as binary
# would skip it silently, which is a partial inspection reported as a verdict -
# so a read error stops the run instead.
is_binary() {
  # Defence in depth: in practice the recursive grep above fails first on an
  # unreadable file and stops the run, so this branch is not reachable from the
  # normal path. It stays because the order of those two reads is not a
  # guarantee, and it is declared as uncovered in SKILL.md rather than claimed.
  [ -r "$1" ] || die "cannot read $1 - the scan would be partial, so no verdict is honest"
  LC_ALL=C tr -d '\000' < "$1" > "$WORK/nonul" 2>/dev/null \
    || die "could not scan $1 for binary content - the scan would be partial"
  # cmp: 0 identical (no NULs, so text), 1 differs (NULs present, so binary),
  # anything else is an operational error. Folding 2 into "binary" would skip
  # the file silently, which is a partial inspection reported as a verdict.
  cmp -s "$WORK/nonul" "$1"
  case "$?" in
    0) return 1 ;;
    1) return 0 ;;
    *) die "could not compare $1 while testing it for binary content - the scan would be partial" ;;
  esac
}

# A marker id must match as a whole token. Without the boundary,
# `tripwire:coverage-map-disabled` satisfied a requirement for `coverage-map`.
id_pattern() { printf 'tripwire:%s([^A-Za-z0-9_-]|$)' "$1"; }

# One census of the tree, reused for every mechanism.
#
# grep's -l output is one filename per LINE, which cannot represent a filename
# containing a newline - and such a file would be split into fragments, one of
# which has no document extension and would be scored as source. grep -Z is not
# a way out: BSD grep ignores it with -l and emits newlines anyway, so a NUL
# reader silently gets nothing and every mechanism reads as absent.
#
# So: enumerate with find -print0, which is portable, and REFUSE outright if any
# filename cannot be represented. Failing closed on the pathological case keeps
# the fast path honest.
FILES="$WORK/files"
find "$ROOT" \
     \( -name .git -o -name node_modules -o -name .venv -o -name venv \
        -o -name __pycache__ -o -name dist -o -name build -o -name target \
        -o -name vendor -o -name .next -o -name .tox -o -name coverage \) -prune \
     -o -type f -print0 > "$FILES" 2>/dev/null
[ "${PIPESTATUS[0]}" -eq 0 ] || die "find failed walking $ROOT - a partial walk cannot support a verdict"

NL=$'\n'
BAD_NAME=""
while IFS= read -r -d '' f; do
  case "$f" in *"$NL"*) BAD_NAME="$f"; break ;; esac
done < "$FILES"
[ -n "$BAD_NAME" ] && die "a filename under $ROOT contains a newline, which no line-oriented scan can represent safely. Rename it, then re-run."

for m in "${MECHS[@]}"; do
  id="${m%%|*}";      rest="${m#*|}"
  what="${rest%%|*}"; rest="${rest#*|}"
  why="${rest%%|*}";  how="${rest#*|}"

  pat="$(id_pattern "$id")"

  # -l  filenames only, so a path containing a colon is unambiguous
  # -I  skip binary files; their match summary carries no line information and
  #     used to be scored as source
  LIST="$WORK/hits"
  grep -rlIE -e "$pat" "${EXCLUDES[@]}" -- "$ROOT" > "$LIST" 2>/dev/null
  rc=$?
  # 0 matches, 1 none, >=2 an operational error. An error mid-scan means the
  # inspection was partial, and no verdict drawn from a partial scan is honest.
  [ "$rc" -ge 2 ] && die "grep failed (status $rc) scanning $ROOT for tripwire:$id - the scan was partial, so no verdict is honest"

  code=""; docs=""; data=""; todo=""; onlyspec=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # Exact-path self-exclusion. Matching on record text discarded any hit whose
    # LINE happened to contain this script's name.
    [ "$f" = "$SELF" ] && continue
    [ -n "$MECHFILE_ABS" ] && [ "$f" = "$MECHFILE_ABS" ] && continue
    # A COPY of this skill inside the tree lists every marker id as data. On the
    # first real project it was pointed at, the skill's own specification was
    # credited as an implementation of the thing it specifies. A directory
    # holding these three files is this skill, not a mechanism.
    d="${f%/*}"
    if [ -f "$d/conformance.sh" ] && [ -f "$d/check-rules.sh" ] && [ -f "$d/registry.py" ]; then
      continue
    fi
    is_binary "$f" && continue

    base="$(lower "${f##*/}")"
    ext="${base##*.}"
    [ "$ext" = "$base" ] && ext=""

    # Lines carrying the marker, minus the ones that only plan it and the ones
    # that merely SPECIFY it.
    real=$(grep -E -e "$pat" -- "$f" 2>/dev/null | grep -viE "$TODO_RE" \
           | awk -F'|' -v n="$SPEC_LINE_PIPES" 'NF <= n' | head -1)
    spec=$(grep -E -e "$pat" -- "$f" 2>/dev/null | grep -viE "$TODO_RE" \
           | awk -F'|' -v n="$SPEC_LINE_PIPES" 'NF > n' | head -1)
    plan=$(grep -E -e "$pat" -- "$f" 2>/dev/null | grep -iE  "$TODO_RE" | head -1)

    rel="${f#"$ROOT"/}"
    if [ -z "$real" ]; then
      if [ -n "$spec" ] && [ -z "$onlyspec" ]; then onlyspec="$rel"
      elif [ -n "$plan" ] && [ -z "$todo" ]; then todo="$rel"
      fi
      continue
    fi
    if is_doc "$ext"; then
      [ -z "$docs" ] && docs="$rel"
    elif is_data "$ext"; then
      [ -z "$data" ] && data="$rel"
    else
      [ -z "$code" ] && code="$rel"
    fi
  done < "$LIST"

  if [ -n "$code" ]; then
    pass "$id claimed by $code"
  elif [ -n "$docs" ]; then
    fire "$id is DOCUMENTED but not implemented" \
         "'tripwire:$id' appears only in a document: $docs. A document cannot execute. It must be $what. $how"
  elif [ -n "$data" ]; then
    fire "$id is DECLARED in data but not implemented" \
         "'tripwire:$id' appears only in a data or configuration file: $data. Describing the mechanism is not building it. It must be $what. $how"
  elif [ -n "$onlyspec" ]; then
    fire "$id is SPECIFIED but not implemented" \
         "'tripwire:$id' appears only in a mechanism specification: $onlyspec. Listing what a mechanism must be is not building it. It must be $what. $how"
  elif [ -n "$todo" ]; then
    fire "$id is a TODO, not a mechanism" \
         "'tripwire:$id' appears only on a TODO/FIXME line: $todo. A marker that plans the work does not claim it. It must be $what. $how"
  else
    fire "no $id" "$how. It must be $what. It exists because: $why"
  fi
done

say ""
if [ "$FAIL" = "0" ]; then
  say "conformance: this project carries all ${#MECHS[@]} mechanisms"
else
  say "conformance: FAILED - the guidance is not implemented here"
fi
exit "$FAIL"
