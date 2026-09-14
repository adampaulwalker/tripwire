#!/bin/bash
# selftest.sh - prove every gate in this repo CAN fail, and fail the RIGHT way.
#
# The whole claim of this skill is that a gate which has never blocked anything
# is decoration. That applies to the gates shipped here more than to anyone
# else's. So each one is broken on purpose, in a throwaway tree, and watched go
# red - then shown to go green on a correct tree, because a gate that fails on
# everything is not a gate either.
#
# Cases assert an EXACT exit status, never merely "nonzero". A typo that makes
# the script exit 127 would otherwise read as a successful refusal:
#   0 = clean   1 = a check fired   2 = the gate could not run
#
# Usage:  bash selftest.sh [-v]
# Exit 0 if every case behaved as declared, 1 otherwise.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

# Inherited configuration would make this suite pass or fail for reasons that
# have nothing to do with the code under test.
unset CLAUDE_HOOKS_CANON CLAUDE_SKILLS_DIR CLAUDE_HOOKS_RULES CLAUDE_HOOKS_MECHANISMS

# A sandbox that silently failed to be created would leave SANDBOX empty and
# every path below would resolve against / instead.
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/tripwire-selftest.XXXXXX")" || {
  echo "selftest: mktemp -d failed - refusing to run against unknown paths" >&2
  exit 1
}
if [ -z "$SANDBOX" ] || [ ! -d "$SANDBOX" ]; then
  echo "selftest: sandbox is not a directory - refusing to run" >&2
  exit 1
fi
trap 'rm -rf "$SANDBOX"' EXIT

# The scripts are COPIED into the sandbox and exercised there. An earlier
# version stashed the repository's real SHARED-RULES.md inside a directory the
# EXIT trap deletes, so an interrupted run destroyed the only canonical copy.
# Nothing here now reads, moves or removes a file the user owns.
TOOL="$SANDBOX/tool"
mkdir -p "$TOOL"
for f in conformance.sh check-rules.sh sync-rules.py scan.py registry.py tripwire \
         mechanisms.example.tsv; do
  cp "$HERE/$f" "$TOOL/$f" || { echo "selftest: cannot copy $f" >&2; exit 1; }
done

TOTAL=0; BAD=0
LAST_OUT=""

# run <expected-exit> <name> -- command...
run() {
  local want="$1" name="$2"; shift 3
  TOTAL=$((TOTAL + 1))
  LAST_OUT="$("$@" 2>&1)"; local rc=$?
  if [ "$rc" = "$want" ]; then
    printf '  [ok]   %s (exit %d)\n' "$name" "$rc"
    [ "$VERBOSE" = 1 ] && printf '%s\n' "$LAST_OUT" | sed 's/^/         | /'
  else
    printf '  [BAD]  %s - wanted exit %s, got %d\n' "$name" "$want" "$rc"
    printf '%s\n' "$LAST_OUT" | sed 's/^/         | /'
    BAD=$((BAD + 1))
  fi
  return 0
}

# says <substring> - the last run must have SAID why, not just exited nonzero.
# A refusal that does not name its reason gets worked around.
says() {
  TOTAL=$((TOTAL + 1))
  if printf '%s' "$LAST_OUT" | grep -qF -- "$1"; then
    printf '  [ok]   ... and says: %s\n' "$1"
  else
    printf '  [BAD]  ... but never said: %s\n' "$1"
    printf '%s\n' "$LAST_OUT" | sed 's/^/         | /'
    BAD=$((BAD + 1))
  fi
}

# assert <description> <test-expression...>
assert() {
  local name="$1"; shift
  TOTAL=$((TOTAL + 1))
  if "$@"; then
    printf '  [ok]   %s\n' "$name"
  else
    printf '  [BAD]  %s\n' "$name"
    BAD=$((BAD + 1))
  fi
}

echo "selftest: can these gates actually fail?"
echo "  sandbox: $SANDBOX"
echo

# ---------------------------------------------------------------- conformance
echo "conformance.sh"

mkdir -p "$SANDBOX/empty/src"
echo "def main(): pass" > "$SANDBOX/empty/src/app.py"
run 1 "absence fails - a project with no markers cannot pass by saying nothing" \
    -- bash "$TOOL/conformance.sh" --quiet "$SANDBOX/empty"

mkdir -p "$SANDBOX/prose/docs"
cat > "$SANDBOX/prose/docs/plan.md" <<'EOF'
Roadmap: add tripwire:coverage-map, tripwire:dark-guards,
tripwire:failure-ceiling and tripwire:outcome-guards.
EOF
run 1 "a document is a plan, not a mechanism" \
    -- bash "$TOOL/conformance.sh" "$SANDBOX/prose"
says "DOCUMENTED but not implemented"

mkdir -p "$SANDBOX/data"
for id in coverage-map dark-guards failure-ceiling outcome-guards; do
  printf '{"note": "tripwire:%s"}\n' "$id" > "$SANDBOX/data/${id}.json"
done
run 1 "a data file describes the mechanism; it does not run it" \
    -- bash "$TOOL/conformance.sh" "$SANDBOX/data"
says "DECLARED in data but not implemented"

mkdir -p "$SANDBOX/todo/src"
for id in coverage-map dark-guards failure-ceiling outcome-guards; do
  printf '# todo: implement tripwire:%s later\ndef f(): pass\n' "$id" \
    > "$SANDBOX/todo/src/${id}.py"
done
run 1 "a lower-case todo line is still a TODO" \
    -- bash "$TOOL/conformance.sh" "$SANDBOX/todo"
says "is a TODO, not a mechanism"

mkdir -p "$SANDBOX/real/tests"
for id in coverage-map dark-guards failure-ceiling outcome-guards; do
  printf '# tripwire:%s\ndef test_%s(): assert True\n' "$id" "${id//-/_}" \
    > "$SANDBOX/real/tests/test_${id}.py"
done
run 0 "a project whose tests carry all four markers passes" \
    -- bash "$TOOL/conformance.sh" --quiet "$SANDBOX/real"

rm "$SANDBOX/real/tests/test_failure-ceiling.py"
run 1 "removing one mechanism turns it red again" \
    -- bash "$TOOL/conformance.sh" --quiet "$SANDBOX/real"

mkdir -p "$SANDBOX/mixed/src" "$SANDBOX/mixed/docs"
for id in coverage-map dark-guards failure-ceiling outcome-guards; do
  printf 'plans tripwire:%s\n' "$id" > "$SANDBOX/mixed/docs/${id}.md"
  printf '# tripwire:%s\ndef t(): assert True\n' "$id" > "$SANDBOX/mixed/src/${id}.py"
done
run 0 "a marker in BOTH a doc and a code file counts as implemented" \
    -- bash "$TOOL/conformance.sh" --quiet "$SANDBOX/mixed"

run 2 "a missing project directory cannot run, and says so" \
    -- bash "$TOOL/conformance.sh" --quiet "$SANDBOX/no-such-dir"

# An empty value is a value somebody GAVE, usually an unset shell variable.
# Found by fault injection: `scan --skills ""` scanned 102 real skills and
# exited 0 while `check` on the same input correctly refused. Four tools, one
# answer.
run 2 "conform refuses an empty project directory rather than using \$PWD" \
    -- bash "$TOOL/conformance.sh" --quiet ""
says "empty value"
run 2 "scan refuses an empty --skills rather than using a default tree" \
    -- python3 "$TOOL/scan.py" --skills ""
says "empty value"
run 2 "check refuses an empty --skills too" \
    -- bash "$TOOL/check-rules.sh" --skills "" --rules "$SANDBOX/one.tsv"

run 2 "an option with no value exits instead of looping forever" \
    -- bash "$TOOL/conformance.sh" --mechanisms
says "needs a value"

run 2 "an explicitly named mechanisms file that is missing fails, never falls back" \
    -- bash "$TOOL/conformance.sh" --mechanisms "$SANDBOX/nope.tsv" "$SANDBOX/real"

# the specification itself names every id, and implements none of them
mkdir -p "$SANDBOX/manifest"
cp "$TOOL/mechanisms.example.tsv" "$SANDBOX/manifest/.tripwire-mechanisms"
run 1 "the mechanism specification cannot credit itself" \
    -- bash "$TOOL/conformance.sh" --quiet "$SANDBOX/manifest"

# a final record with no trailing newline must still be checked
printf 'present|w|y|f\nmissing|w|y|f' > "$SANDBOX/mech-nonl.tsv"
mkdir -p "$SANDBOX/nonl/src"; printf '# tripwire:present\n' > "$SANDBOX/nonl/src/a.py"
run 1 "the last mechanism in a file with no trailing newline is still checked" \
    -- bash "$TOOL/conformance.sh" --quiet --mechanisms "$SANDBOX/mech-nonl.tsv" "$SANDBOX/nonl"
says "no missing"

# a mechanism SPECIFICATION inside the scanned tree lists every id as data.
# Found on the first real project this was pointed at: the skill's own spec was
# credited as an implementation of the thing it specifies.
mkdir -p "$SANDBOX/hasspec/skills/tool"
{ printf '#!/bin/bash\nMECHS=(\n'
  for id in coverage-map dark-guards failure-ceiling outcome-guards; do
    printf '"%s|a test that does the thing|it cost a day once|write it, mark it %s"\n' \
      "$id" "'tripwire:$id'"
  done
  printf ')\n'; } > "$SANDBOX/hasspec/skills/tool/conformance.sh"
run 1 "a mechanism specification in the tree does not credit itself" \
    -- bash "$TOOL/conformance.sh" "$SANDBOX/hasspec"
says "SPECIFIED but not implemented"

# "one day" was a TODO token and matched the incident prose "written in one
# day", reporting a real mechanism as a plan. A word used to record what
# something COST cannot also mean it is unbuilt.
mkdir -p "$SANDBOX/costaday/tests"
for id in coverage-map dark-guards failure-ceiling outcome-guards; do
  printf '# tripwire:%s - half the guards written in one day were source greps\ndef t(): assert True\n' \
    "$id" > "$SANDBOX/costaday/tests/t_${id}.py"
done
run 0 "an incident saying 'in one day' is not a TODO" \
    -- bash "$TOOL/conformance.sh" --quiet "$SANDBOX/costaday"

# a second checkout is a copy that is not the one running
mkdir -p "$SANDBOX/wt/worktrees/branch/tests" "$SANDBOX/wt/src"
printf 'def main(): pass\n' > "$SANDBOX/wt/src/app.py"
for id in coverage-map dark-guards failure-ceiling outcome-guards; do
  printf '# tripwire:%s\ndef t(): assert True\n' "$id" > "$SANDBOX/wt/worktrees/branch/tests/t_${id}.py"
done
run 1 "a mechanism that exists only in a worktree is not the copy that runs" \
    -- bash "$TOOL/conformance.sh" --quiet "$SANDBOX/wt"

# a longer id must not satisfy a shorter requirement
mkdir -p "$SANDBOX/longer/src"
for id in coverage-map dark-guards failure-ceiling outcome-guards; do
  printf '# tripwire:%s-disabled\n' "$id" > "$SANDBOX/longer/src/${id}.py"
done
run 1 "a longer marker id does not satisfy a shorter requirement" \
    -- bash "$TOOL/conformance.sh" --quiet "$SANDBOX/longer"

# an uppercase extension is still a data file
mkdir -p "$SANDBOX/upper"
printf '{"a":"tripwire:coverage-map","b":"tripwire:dark-guards","c":"tripwire:failure-ceiling","d":"tripwire:outcome-guards"}\n' \
  > "$SANDBOX/upper/plan.JSON"
run 1 "an uppercase .JSON is still a data file, not an implementation" \
    -- bash "$TOOL/conformance.sh" "$SANDBOX/upper"
says "DECLARED in data but not implemented"

# a binary file's grep summary carries no line information
mkdir -p "$SANDBOX/binary"
printf 'tripwire:coverage-map\0tripwire:dark-guards\0tripwire:failure-ceiling\0tripwire:outcome-guards\0' \
  > "$SANDBOX/binary/blob.dat"
run 1 "a binary file cannot claim a mechanism" \
    -- bash "$TOOL/conformance.sh" --quiet "$SANDBOX/binary"

# a filename a line-oriented scan cannot represent must stop the run
mkdir -p "$SANDBOX/newline"
printf 'x\n' > "$SANDBOX/newline/$(printf 'a\nb').md"
run 2 "a filename containing a newline stops the run instead of being misread" \
    -- bash "$TOOL/conformance.sh" --quiet "$SANDBOX/newline"

# a mechanism id is interpolated into a regex, so punctuation must be refused
# cmp failing operationally is not evidence of binary content. Injected,
# because nothing in normal use makes cmp exit 2 and an unproven branch is
# decoration.
mkdir -p "$SANDBOX/shim" "$SANDBOX/cmpfail/src"
printf '#!/bin/sh\nexit 2\n' > "$SANDBOX/shim/cmp"
chmod +x "$SANDBOX/shim/cmp"
for id in coverage-map dark-guards failure-ceiling outcome-guards; do
  printf '# tripwire:%s\ndef t(): assert True\n' "$id" > "$SANDBOX/cmpfail/src/${id}.py"
done
run 2 "a comparison that fails operationally stops the run, it is not read as binary" \
    -- env PATH="$SANDBOX/shim:$PATH" bash "$TOOL/conformance.sh" --quiet "$SANDBOX/cmpfail"
says "could not compare"

# an unreadable candidate is an operational failure, never "binary, skip it"
mkdir -p "$SANDBOX/unreadable/src"
for id in coverage-map dark-guards failure-ceiling outcome-guards; do
  printf '# tripwire:%s\ndef t(): assert True\n' "$id" > "$SANDBOX/unreadable/src/${id}.py"
done
chmod 000 "$SANDBOX/unreadable/src/coverage-map.py" 2>/dev/null || true
if [ -r "$SANDBOX/unreadable/src/coverage-map.py" ]; then
  printf '  [SKIP] unreadable-file case - running as a user who can read anything\n'
else
  run 2 "an unreadable file stops the scan rather than being skipped" \
      -- bash "$TOOL/conformance.sh" --quiet "$SANDBOX/unreadable"
fi
chmod 644 "$SANDBOX/unreadable/src/coverage-map.py" 2>/dev/null || true

printf 'a.b|what|why|how\n' > "$SANDBOX/mech-dot.tsv"
mkdir -p "$SANDBOX/dotid/src"; printf '# tripwire:axb\n' > "$SANDBOX/dotid/src/a.py"
run 2 "a mechanism id containing regex punctuation is refused, not used as a pattern" \
    -- bash "$TOOL/conformance.sh" --mechanisms "$SANDBOX/mech-dot.tsv" "$SANDBOX/dotid"
says "not a usable mechanism id"

# grep decides binary from an initial buffer; a distant NUL slipped through
mkdir -p "$SANDBOX/bigbin"
{ printf 'tripwire:coverage-map tripwire:dark-guards tripwire:failure-ceiling tripwire:outcome-guards\n'
  head -c 100000 /dev/zero | tr '\000' 'A'
  printf '\000'; } > "$SANDBOX/bigbin/blob.bin"
run 1 "a binary file whose first NUL is far from the start still cannot claim a mechanism" \
    -- bash "$TOOL/conformance.sh" --quiet "$SANDBOX/bigbin"

printf 'x|||\n' > "$SANDBOX/mech-blank.tsv"
run 2 "a mechanism row with a blank field is refused" \
    -- bash "$TOOL/conformance.sh" --mechanisms "$SANDBOX/mech-blank.tsv" "$SANDBOX/real"
says "empty what field"

printf 'bad-row-with-two|fields\n' > "$SANDBOX/mech-bad.tsv"
run 2 "a malformed mechanism row stops the run rather than shrinking the spec" \
    -- bash "$TOOL/conformance.sh" --mechanisms "$SANDBOX/mech-bad.tsv" "$SANDBOX/real"

echo

# ---------------------------------------------------------------- check-rules
echo "check-rules.sh"

SK="$SANDBOX/skills"
mkdir -p "$SK/alpha" "$SK/beta" "$SK/gamma"
seed_skills() {
  printf -- '---\nname: alpha\n---\n\n## NEVER SHIP ON RED\nbody\n' > "$SK/alpha/SKILL.md"
  printf -- '---\nname: beta\n---\n\n## MEASURE BEFORE ASSUMING\nbody\n'  > "$SK/beta/SKILL.md"
  printf -- '---\nname: gamma\n---\n\nUnregistered on purpose.\n'         > "$SK/gamma/SKILL.md"
}
seed_skills
WAIVERS=$'proofs: none - no guard is expected in this fixture\nshared-rules: none - nothing is shared in this fixture\n'
{ printf 'alpha|NEVER SHIP ON RED|2026-01-02: a red suite was waved through and the bug shipped\n'
  printf 'beta|MEASURE BEFORE ASSUMING|2026-01-09: three named causes were all wrong at the source\n'
  printf '%s' "$WAIVERS"; } > "$SANDBOX/rules.tsv"

run 0 "both rules present, both phases waived in writing" \
    -- bash "$TOOL/check-rules.sh" --rules "$SANDBOX/rules.tsv" --skills "$SK"
says "2 declared skip(s)"

perl -0pi -e 's/## NEVER SHIP ON RED\n//' "$SK/alpha/SKILL.md"
run 1 "deleting a rule from a skill turns it red" \
    -- bash "$TOOL/check-rules.sh" --rules "$SANDBOX/rules.tsv" --skills "$SK"
says "a red suite was waved through"
seed_skills

: > "$SANDBOX/empty-rules.tsv"
run 1 "a registry that parses to zero rules is a dead gate, not a clean run" \
    -- bash "$TOOL/check-rules.sh" --rules "$SANDBOX/empty-rules.tsv" --skills "$SK"
says "inspects nothing is not a pass"

run 2 "an explicitly named skills tree that is missing fails, never falls back" \
    -- bash "$TOOL/check-rules.sh" --rules "$SANDBOX/rules.tsv" --skills "$SANDBOX/nope"

run 2 "an option with no value exits instead of looping forever" \
    -- bash "$TOOL/check-rules.sh" --rules
says "needs a value"

printf 'alpha||incident\n' > "$SANDBOX/bad-empty.tsv"
run 2 "an empty marker is refused - an empty pattern matches every line" \
    -- bash "$TOOL/check-rules.sh" --rules "$SANDBOX/bad-empty.tsv" --skills "$SK"
says "inspected nothing"

printf 'alpha|NEVER SHIP ON RED\n' > "$SANDBOX/bad-short.tsv"
run 2 "a rule with no recorded incident is refused" \
    -- bash "$TOOL/check-rules.sh" --rules "$SANDBOX/bad-short.tsv" --skills "$SK"

{ printf 'alpha|-eNEVER SHIP|incident: a marker beginning with a dash\n'
  printf '%s' "$WAIVERS"; } > "$SANDBOX/dash.tsv"
run 1 "a marker beginning with a dash is a literal string, not a grep option" \
    -- bash "$TOOL/check-rules.sh" --rules "$SANDBOX/dash.tsv" --skills "$SK"
says "LOST: -eNEVER SHIP"

# ---- proofs
{ printf 'alpha|NEVER SHIP ON RED|incident\n'
  printf 'shared-rules: none - waived so missing proofs are the only thing that can fire\n'
  } > "$SANDBOX/noproof.tsv"
run 1 "no executable proof anywhere FAILS - absence is not a skip" \
    -- bash "$TOOL/check-rules.sh" --rules "$SANDBOX/noproof.tsv" --skills "$SK"
says "no executable proofs"

cat > "$SK/alpha/guard_test.sh" <<'EOF'
#!/bin/bash
echo "the wrap guard no longer refuses the body that shipped illegibly"; exit 1
EOF
{ printf 'alpha|NEVER SHIP ON RED|incident\nshared-rules: none - nothing shared here\n'; } > "$SANDBOX/proof.tsv"
run 1 "a discovered guard_test that fails turns the run red" \
    -- bash "$TOOL/check-rules.sh" --rules "$SANDBOX/proof.tsv" --skills "$SK"
says "proof FAILS"

printf '#!/bin/bash\nexit 0\n' > "$SK/alpha/guard_test.sh"
run 0 "and passes once the proof passes" \
    -- bash "$TOOL/check-rules.sh" --rules "$SANDBOX/proof.tsv" --skills "$SK"
says "1 executable proof(s) discovered and run"

# gamma is in NO registry row. A hardcoded list of proofs could not see it,
# which is the failure mode this whole skill is about.
printf '#!/bin/bash\nexit 1\n' > "$SK/gamma/guard_test.sh"
run 1 "a proof in a skill no registry row mentions is still discovered and still fires" \
    -- bash "$TOOL/check-rules.sh" --rules "$SANDBOX/proof.tsv" --skills "$SK"
says "gamma/guard_test.sh"
rm "$SK/gamma/guard_test.sh"

# a guard that reads stdin must not swallow the discovery list behind it
printf '#!/bin/bash\ncat >/dev/null\nexit 0\n' > "$SK/alpha/guard_test.sh"
printf '#!/bin/bash\nexit 1\n' > "$SK/beta/guard_test.sh"
run 1 "a guard that reads stdin cannot swallow the guards discovered after it" \
    -- bash "$TOOL/check-rules.sh" --rules "$SANDBOX/proof.tsv" --skills "$SK"
says "beta/guard_test.sh"
run 1 "both guards ran despite the first consuming stdin" \
    -- bash "$TOOL/check-rules.sh" --rules "$SANDBOX/proof.tsv" --skills "$SK"
says "2 executable proof(s) discovered and run"
rm -f "$SK/beta/guard_test.sh"
printf '#!/bin/bash\nexit 0\n' > "$SK/alpha/guard_test.sh"

# a symlinked skills root is the normal case when skills live in a config repo
ln -s "$SK" "$SANDBOX/linked-skills"
run 0 "a symlinked skills root is still traversed" \
    -- bash "$TOOL/check-rules.sh" --rules "$SANDBOX/proof.tsv" --skills "$SANDBOX/linked-skills"
says "1 executable proof(s) discovered and run"

# a guard nested deeper than the conventional layout must still be found
mkdir -p "$SK/alpha/tests/unit"
printf 'import sys; sys.exit(1)\n' > "$SK/alpha/tests/unit/guard_test.py"
run 1 "a guard nested deep in a skill is still discovered and still fires" \
    -- bash "$TOOL/check-rules.sh" --rules "$SANDBOX/proof.tsv" --skills "$SK"
says "alpha/tests/unit/guard_test.py"
rm -rf "$SK/alpha/tests"

printf 'package main\n' > "$SK/alpha/guard_test.go"
run 1 "an unknown proof type is refused, never executed" \
    -- bash "$TOOL/check-rules.sh" --rules "$SANDBOX/proof.tsv" --skills "$SK"
says "unknown proof type"
rm "$SK/alpha/guard_test.go"

echo

# ------------------------------------------------- check-rules -> sync (wrapper)
# The drift phase is reached through check-rules.sh, not only by calling
# sync-rules.py directly. Without these, replacing the whole phase with an
# unconditional pass would leave every other assertion green.
echo "check-rules.sh -> sync-rules.py"

# The sandboxed copy has no SHARED-RULES.md beside it, so this is the genuine
# unconfigured path with nothing of the user's involved.

# proofs waived in writing, drift NOT waived - so the only thing that can fire
# is the drift phase being unconfigured.
{ printf 'alpha|NEVER SHIP ON RED|incident\n'
  printf 'proofs: none - waived so only the drift phase can fire here\n'; } > "$SANDBOX/wrap.tsv"
run 1 "an unconfigured drift gate FAILS through the wrapper, it does not skip" \
    -- env -u CLAUDE_HOOKS_CANON \
       bash "$TOOL/check-rules.sh" --rules "$SANDBOX/wrap.tsv" --skills "$SK"
says "NOT CONFIGURED"

# a canonical path that IS configured and wrong is a typo, never an absence,
# so the written waiver must not quiet it
{ printf 'alpha|NEVER SHIP ON RED|incident\n'
  printf 'proofs: none - waived\n'
  printf 'shared-rules: none - waived, and this waiver must NOT cover a typo\n'
  } > "$SANDBOX/typo.tsv"
run 1 "a configured-but-missing canonical path is not waivable" \
    -- env CLAUDE_HOOKS_CANON="$SANDBOX/no-such-canon.md" \
       bash "$TOOL/check-rules.sh" --rules "$SANDBOX/typo.tsv" --skills "$SK"
says "configured and wrong"

WCANON="$SANDBOX/wrapper-canon.md"
cat > "$WCANON" <<'EOF'
<!-- RULE:wrapper-check consumers: alpha beta -->
## A WRAPPER RULE

Text both skills must carry byte for byte.
<!-- /RULE:wrapper-check -->
EOF
python3 "$TOOL/sync-rules.py" --canon "$WCANON" --skills "$SK" >/dev/null
{ printf 'alpha|NEVER SHIP ON RED|incident\n'; } > "$SANDBOX/wrap2.tsv"
run 0 "a configured, synced tree passes through the wrapper" \
    -- env CLAUDE_HOOKS_CANON="$WCANON" \
       bash "$TOOL/check-rules.sh" --rules "$SANDBOX/wrap2.tsv" --skills "$SK"
says "shared rules identical"

perl -0pi -e 's/byte for byte/byte for byte (edited locally)/' "$SK/beta/SKILL.md"
run 1 "drift introduced in a consumer is caught THROUGH the wrapper" \
    -- env CLAUDE_HOOKS_CANON="$WCANON" \
       bash "$TOOL/check-rules.sh" --rules "$SANDBOX/wrap2.tsv" --skills "$SK"
says "DRIFTED"

seed_skills
printf '#!/bin/bash\nexit 0\n' > "$SK/alpha/guard_test.sh"

echo

# ---------------------------------------------------------------- sync-rules
echo "sync-rules.py"

C="$SANDBOX/CANON.md"
cat > "$C" <<'EOF'
# canonical

<!-- RULE:shared-one consumers: alpha beta -->
## A SHARED RULE

Its full text, which both skills must carry byte for byte.
<!-- /RULE:shared-one -->
EOF

run 1 "before the first sync, the copies are missing" \
    -- python3 "$TOOL/sync-rules.py" --check --canon "$C" --skills "$SK"
says "is missing"

run 0 "sync installs it into every consumer" \
    -- python3 "$TOOL/sync-rules.py" --canon "$C" --skills "$SK"
run 0 "and --check then verifies it" \
    -- python3 "$TOOL/sync-rules.py" --check --canon "$C" --skills "$SK"
says "2 consumer copies"

perl -0pi -e 's/byte for byte/byte for byte (edited locally)/' "$SK/beta/SKILL.md"
run 1 "editing a shared rule inside a consumer is caught as drift" \
    -- python3 "$TOOL/sync-rules.py" --check --canon "$C" --skills "$SK"
says "DRIFTED"

run 0 "re-syncing repairs the drifted copy" \
    -- python3 "$TOOL/sync-rules.py" --canon "$C" --skills "$SK"
run 0 "and --check is clean again" \
    -- python3 "$TOOL/sync-rules.py" --check --canon "$C" --skills "$SK"

# a renamed canon, and a canon whose name contains a bracket, must both
# recognise their own already-installed blocks rather than duplicating them
mv "$C" "$SANDBOX/RENAMED (v2).md"
run 0 "a renamed canon with a bracket in its name recognises its own copies" \
    -- python3 "$TOOL/sync-rules.py" --canon "$SANDBOX/RENAMED (v2).md" --skills "$SK"
run 0 "and --check still verifies both consumers afterwards" \
    -- python3 "$TOOL/sync-rules.py" --check --canon "$SANDBOX/RENAMED (v2).md" --skills "$SK"
says "2 consumer copies"
for s in alpha beta; do
  assert "$s holds exactly one opening marker for the rule" \
      test "$(grep -c '<!-- RULE:shared-one' "$SK/$s/SKILL.md")" = "1"
  assert "$s holds exactly one closing marker for the rule" \
      test "$(grep -c '<!-- /RULE:shared-one -->' "$SK/$s/SKILL.md")" = "1"
  assert "$s kept its own unrelated content" \
      grep -q 'name: '"$s" "$SK/$s/SKILL.md"
done
mv "$SANDBOX/RENAMED (v2).md" "$C"

# a second, contradicting block must not hide behind the first
cat >> "$SK/alpha/SKILL.md" <<'EOF'

<!-- RULE:shared-one (synced - edit the canonical file, not here) -->
## A SHARED RULE

A stale contradicting copy.
<!-- /RULE:shared-one -->
EOF
run 1 "a duplicated installed block is refused, not silently half-checked" \
    -- python3 "$TOOL/sync-rules.py" --check --canon "$C" --skills "$SK"
says "is declared 2 times"
seed_skills
python3 "$TOOL/sync-rules.py" --canon "$C" --skills "$SK" >/dev/null

# the destructive first-install splice
mkdir -p "$SK/delta"
printf -- '---\nname: delta\n---\nIntro mentions ## A SHARED RULE someday.\nKEEP THIS LINE\n## Other\nmore\n' > "$SK/delta/SKILL.md"
perl -0pi -e 's/consumers: alpha beta/consumers: alpha beta delta/' "$C"
run 1 "an ambiguous first install is refused rather than guessing which lines it owns" \
    -- python3 "$TOOL/sync-rules.py" --canon "$C" --skills "$SK"
says "will not guess which lines it owns"
assert "... and the unrelated line was not deleted" \
    grep -q 'KEEP THIS LINE' "$SK/delta/SKILL.md"
perl -0pi -e 's/consumers: alpha beta delta/consumers: alpha beta/' "$C"
rm -rf "$SK/delta"

# validation happens before any write
cp "$C" "$SANDBOX/DUP.md"
cat >> "$SANDBOX/DUP.md" <<'EOF'

<!-- RULE:shared-one consumers: alpha -->
## A SHARED RULE

DIFFERENT canonical text.
<!-- /RULE:shared-one -->
EOF
run 1 "a duplicate canonical id is refused" \
    -- python3 "$TOOL/sync-rules.py" --check --canon "$SANDBOX/DUP.md" --skills "$SK"
says "is declared 2 times"

cp "$C" "$SANDBOX/MAL.md"
printf '\n<!-- RULE:a.b consumers: alpha -->\nbody\n' >> "$SANDBOX/MAL.md"
run 1 "a declaration the parser cannot read is reported, not ignored" \
    -- python3 "$TOOL/sync-rules.py" --check --canon "$SANDBOX/MAL.md" --skills "$SK"
says "is not a usable rule id"

printf 'outside\n' > "$SANDBOX/outside-SKILL.md"
cp "$SANDBOX/outside-SKILL.md" "$SANDBOX/outside-SKILL.orig"
cp "$C" "$SANDBOX/ESC.md"
perl -0pi -e 's{consumers: alpha beta}{consumers: ../outside-SKILL.md}' "$SANDBOX/ESC.md"
run 1 "a consumer path escaping the skills tree is refused" \
    -- python3 "$TOOL/sync-rules.py" --canon "$SANDBOX/ESC.md" --skills "$SK"
says "outside the skills tree"
assert "... and the file outside the tree is byte-identical to before" \
    cmp -s "$SANDBOX/outside-SKILL.md" "$SANDBOX/outside-SKILL.orig"

run 3 "an explicitly named skills tree that is missing is configured-and-wrong, not absent" \
    -- python3 "$TOOL/sync-rules.py" --check --canon "$C" --skills "$SANDBOX/nonexistent"
says "not found"

# two rules naming the SAME consumer must both survive. Building each
# replacement from the original file and keeping the last dropped the first.
mkdir -p "$SK/epsilon"
printf -- '---\nname: epsilon\n---\nIntro.\n' > "$SK/epsilon/SKILL.md"
cat > "$SANDBOX/TWO.md" <<'EOF'
<!-- RULE:first consumers: epsilon -->
## RULE ONE
text one
<!-- /RULE:first -->

<!-- RULE:second consumers: epsilon -->
## RULE TWO
text two
<!-- /RULE:second -->
EOF
run 0 "two rules naming one consumer both install" \
    -- python3 "$TOOL/sync-rules.py" --canon "$SANDBOX/TWO.md" --skills "$SK"
assert "... the first rule survived" grep -q 'text one' "$SK/epsilon/SKILL.md"
assert "... and so did the second" grep -q 'text two' "$SK/epsilon/SKILL.md"
run 0 "... and --check verifies both" \
    -- python3 "$TOOL/sync-rules.py" --check --canon "$SANDBOX/TWO.md" --skills "$SK"

# a rule id that is a PREFIX of another must not consume it
mkdir -p "$SK/zeta"
{ printf -- '---\nname: zeta\n---\n\n'
  printf '<!-- RULE:ab (synced - edit the canonical file, not here) -->\n## AB\nab body\n<!-- /RULE:ab -->\n\n'
  printf '<!-- RULE:a (synced - edit the canonical file, not here) -->\n## A\nstale a\n<!-- /RULE:a -->\n'
  } > "$SK/zeta/SKILL.md"
printf '<!-- RULE:a consumers: zeta -->\n## A\nfresh a\n<!-- /RULE:a -->\n' > "$SANDBOX/PFX.md"
run 0 "updating rule 'a' does not consume the neighbouring 'ab' block" \
    -- python3 "$TOOL/sync-rules.py" --canon "$SANDBOX/PFX.md" --skills "$SK"
assert "... the 'ab' block survived intact" grep -q 'ab body' "$SK/zeta/SKILL.md"
assert "... and 'a' was updated" grep -q 'fresh a' "$SK/zeta/SKILL.md"

# an unmatched opening marker makes every offset in the file untrustworthy
mkdir -p "$SK/eta"
{ printf -- '---\nname: eta\n---\n<!-- RULE:a broken -->\nKEEP ME\n\n'
  printf '<!-- RULE:a (synced - edit the canonical file, not here) -->\n## A\nold\n<!-- /RULE:a -->\n'
  } > "$SK/eta/SKILL.md"
printf '<!-- RULE:a consumers: eta -->\n## A\nfresh\n<!-- /RULE:a -->\n' > "$SANDBOX/BRK.md"
run 1 "a file with an unmatched opening marker is refused, not cut" \
    -- python3 "$TOOL/sync-rules.py" --canon "$SANDBOX/BRK.md" --skills "$SK"
assert "... and the unrelated line between the markers survived" \
    grep -q 'KEEP ME' "$SK/eta/SKILL.md"

# the canonical file naming itself would rewrite away its own consumers clause
mkdir -p "$SANDBOX/selfsk"
printf '<!-- RULE:a consumers: ./canon.md -->\n## A\nbody\n<!-- /RULE:a -->\n' > "$SANDBOX/selfsk/canon.md"
run 1 "the canonical file cannot be its own consumer" \
    -- python3 "$TOOL/sync-rules.py" --canon "$SANDBOX/selfsk/canon.md" --skills "$SANDBOX/selfsk"
says "canonical file itself"

# CRLF must survive a round trip, or --check is not byte-exact
mkdir -p "$SK/theta"
printf -- '---\nname: theta\n---\n' > "$SK/theta/SKILL.md"
printf '<!-- RULE:crlf consumers: theta -->\r\n## CRLF RULE\r\nbody\r\n<!-- /RULE:crlf -->\r\n' > "$SANDBOX/CRLF.md"
run 0 "a CRLF canonical file installs" \
    -- python3 "$TOOL/sync-rules.py" --canon "$SANDBOX/CRLF.md" --skills "$SK"
run 0 "... and verifies byte-exact afterwards" \
    -- python3 "$TOOL/sync-rules.py" --check --canon "$SANDBOX/CRLF.md" --skills "$SK"
# Self-agreement is not preservation: a reader that normalised CRLF to LF would
# satisfy both runs above while silently losing bytes. Assert the bytes.
printf '## CRLF RULE\r\nbody\r\n' > "$SANDBOX/crlf-expected"
assert "... and the installed body kept its carriage returns" \
    bash -c 'python3 - "$1" "$2" <<'"'"'EOS'"'"'
import sys
body = open(sys.argv[1], "rb").read().split(b"-->", 1)[1].lstrip(b"\r\n")
body = body.split(b"<!-- /RULE:crlf -->")[0]
sys.exit(0 if body == open(sys.argv[2], "rb").read() else 1)
EOS' _ "$SK/theta/SKILL.md" "$SANDBOX/crlf-expected"

run 3 "a configured-but-missing canonical file is configured-and-wrong, not absent" \
    -- python3 "$TOOL/sync-rules.py" --check --canon "$SANDBOX/no-canon-here.md" --skills "$SK"

# a marker line holding a second comment must not swallow what is between them
mkdir -p "$SK/iota"
{ printf -- '---\nname: iota\n---\n\n'
  printf '<!-- RULE:a (old) --> KEEP THIS <!-- unrelated -->\n## A\nold\n<!-- /RULE:a -->\n'
  } > "$SK/iota/SKILL.md"
printf '<!-- RULE:a consumers: iota -->\n## A\nfresh\n<!-- /RULE:a -->\n' > "$SANDBOX/TWOC.md"
run 1 "a marker line carrying a second comment is refused, not treated as one marker" \
    -- python3 "$TOOL/sync-rules.py" --canon "$SANDBOX/TWOC.md" --skills "$SK"
assert "... and the text between the two comments survived" \
    grep -q 'KEEP THIS' "$SK/iota/SKILL.md"

# an unterminated declaration must not hide behind a valid one
cp "$C" "$SANDBOX/UNTERM.md"
printf '\n<!-- RULE:b consumers: beta\n' >> "$SANDBOX/UNTERM.md"
run 1 "an unterminated declaration is reported even when another rule verifies" \
    -- python3 "$TOOL/sync-rules.py" --check --canon "$SANDBOX/UNTERM.md" --skills "$SK"
says "one complete HTML comment alone on its line"

# on a case-insensitive filesystem two spellings are ONE file
mkdir -p "$SANDBOX/casesk"
printf '<!-- RULE:a consumers: ./CANON.md -->\n## A\nbody\n<!-- /RULE:a -->\n' > "$SANDBOX/casesk/canon.md"
cp "$SANDBOX/casesk/canon.md" "$SANDBOX/casesk/canon.orig"
run 1 "a differently-spelled alias of the canonical file is still the canonical file" \
    -- python3 "$TOOL/sync-rules.py" --canon "$SANDBOX/casesk/canon.md" --skills "$SANDBOX/casesk"
assert "... and the canonical file was not rewritten" \
    cmp -s "$SANDBOX/casesk/canon.md" "$SANDBOX/casesk/canon.orig"

# ordinary HTML comments are none of this parser's business
mkdir -p "$SK/nu"
{ printf -- '---\nname: nu\n---\n'
  printf '<!-- ordinary --> <!-- unrelated -->\nprose\n'
  } > "$SK/nu/SKILL.md"
cp "$SK/nu/SKILL.md" "$SANDBOX/nu.orig"
printf '<!-- RULE:plain consumers: nu -->\n## PLAIN\nbody\n<!-- /RULE:plain -->\n' > "$SANDBOX/PLAIN.md"
run 0 "a file with two unrelated comments on one line syncs normally" \
    -- python3 "$TOOL/sync-rules.py" --canon "$SANDBOX/PLAIN.md" --skills "$SK"
assert "... and both unrelated comments survived unchanged" \
    grep -q '<!-- ordinary --> <!-- unrelated -->' "$SK/nu/SKILL.md"
run 0 "... and --check verifies it" \
    -- python3 "$TOOL/sync-rules.py" --check --canon "$SANDBOX/PLAIN.md" --skills "$SK"

# an id ending in hyphens must not let the marker reach a later "-->".
# `<!-- RULE:a--> KEEP THIS <!-- unrelated -->` was parsed as one marker whose
# id was "a--", and the sync deleted KEEP THIS.
mkdir -p "$SK/kappa"
{ printf -- '---\nname: kappa\n---\n\n'
  printf '<!-- RULE:a--> KEEP THIS <!-- unrelated -->\n## A\nold\n<!-- /RULE:a-- -->\n'
  } > "$SK/kappa/SKILL.md"
printf '<!-- RULE:a-- consumers: kappa -->\n## A\nfresh\n<!-- /RULE:a-- -->\n' > "$SANDBOX/HYPH.md"
run 1 "a hyphen-terminated id cannot reach past the first comment terminator" \
    -- python3 "$TOOL/sync-rules.py" --canon "$SANDBOX/HYPH.md" --skills "$SK"
assert "... and the text after that comment survived" \
    grep -q 'KEEP THIS' "$SK/kappa/SKILL.md"

# a second declaration smuggled inside an accepted marker line
cp "$C" "$SANDBOX/NEST.md"
{ printf '\n<!-- RULE:outer <!-- RULE:inner consumers: alpha -->\nbody\n<!-- /RULE:outer -->\n'; } >> "$SANDBOX/NEST.md"
run 1 "a nested declaration inside a marker line is refused" \
    -- python3 "$TOOL/sync-rules.py" --check --canon "$SANDBOX/NEST.md" --skills "$SK"
says "only ONE comment"

# an atomic replace swaps one directory entry, so a hard-linked consumer would
# keep the old bytes while the run reported success
mkdir -p "$SK/lambda" "$SK/mu"
printf -- '---\nname: lambda\n---\nIntro.\n' > "$SK/lambda/SKILL.md"
if ln "$SK/lambda/SKILL.md" "$SK/mu/SKILL.md" 2>/dev/null; then
  printf '<!-- RULE:hl consumers: lambda mu -->\n## HL\nbody\n<!-- /RULE:hl -->\n' > "$SANDBOX/HL.md"
  run 1 "a hard-linked consumer is refused rather than half-updated" \
      -- python3 "$TOOL/sync-rules.py" --canon "$SANDBOX/HL.md" --skills "$SK"
  says "hard link"
  assert "... and neither name was modified" \
      bash -c '! grep -q "RULE:hl" "'"$SK"'/lambda/SKILL.md"'
  # a hard link is also a portable alias for the canon on any filesystem
  mkdir -p "$SANDBOX/hlsk"
  printf '<!-- RULE:a consumers: ./alias.md -->\n## A\nbody\n<!-- /RULE:a -->\n' > "$SANDBOX/hlsk/canon.md"
  cp "$SANDBOX/hlsk/canon.md" "$SANDBOX/hlsk/canon.orig"
  ln "$SANDBOX/hlsk/canon.md" "$SANDBOX/hlsk/alias.md"
  run 1 "a hard-link alias of the canonical file is still the canonical file" \
      -- python3 "$TOOL/sync-rules.py" --canon "$SANDBOX/hlsk/canon.md" --skills "$SANDBOX/hlsk"
  says "canonical file itself"
  assert "... and the canonical file is byte-identical" \
      cmp -s "$SANDBOX/hlsk/canon.md" "$SANDBOX/hlsk/canon.orig"
else
  printf '  [SKIP] hard-link cases - this filesystem does not support hard links\n'
fi
rm -rf "$SK/lambda" "$SK/mu"

printf '# canonical with no rule blocks at all\n' > "$SANDBOX/DEAD.md"
run 1 "a canon with no RULE blocks is a dead gate, not a pass" \
    -- python3 "$TOOL/sync-rules.py" --check --canon "$SANDBOX/DEAD.md" --skills "$SK"
says "DEAD GATE"

echo

# ------------------------------------------------------------------- scan.py
echo "scan.py"

# absent <substring> <name> -- cmd...
# Runs the command, REQUIRES it to succeed, and only then asserts the substring
# is missing. A bare `! cmd | grep -q x` passes when the command crashes and
# prints nothing, which is not evidence of anything.
absent() {
  local want="$1" name="$2"; shift 3
  TOTAL=$((TOTAL + 1))
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '  [BAD]  %s - the command failed (exit %d), so absence proves nothing\n' "$name" "$rc"
    printf '%s\n' "$out" | sed 's/^/         | /'
    BAD=$((BAD + 1))
    return 0
  fi
  if printf '%s' "$out" | grep -qF -- "$want"; then
    printf '  [BAD]  %s - found %s in a successful run\n' "$name" "$want"
    BAD=$((BAD + 1))
  else
    printf '  [ok]   %s\n' "$name"
  fi
}

SC="$SANDBOX/scanskills"
mkdir -p "$SC/alpha" "$SC/beta" "$SC/logs-skill"

# a rule that records what it cost, with nothing executing it: the bullseye
printf -- '---\nname: alpha\n---\n\nNever run the importer twice. On 2026-03-27 a double run duplicated 400 rows and cost a day.\n' \
  > "$SC/alpha/SKILL.md"
# a rule with no incident behind it, but mechanically checkable
printf -- '---\nname: beta\n---\n\nAlways pass `--dry-run` before a real write.\n' \
  > "$SC/beta/SKILL.md"
# an incident LOG. Long enough to clear every substance filter, so this fixture
# actually exercises the corpus-path exclusion rather than being dropped for
# brevity - it did not, the first time, and a mutation survived because of it.
printf -- '---\nname: logs-skill\n---\n\nNothing here instructs.\n' > "$SC/logs-skill/SKILL.md"
printf '# Incidents\n\n## 2026-08-18\nNever ran the reconciliation before the export that day, and it cost a day of rework across the whole batch.\n\n## 2026-08-26\nAlways assumed the cache was warm; that assumption was violated twice more and shipped three times.\n' \
  > "$SC/logs-skill/INCIDENTS.md"

run 0 "the scan completes and reports what it inspected" \
    -- python3 "$TOOL/scan.py" --skills "$SC"
says "inspected:"
says "Never run the importer twice"

absent "--dry-run" "a rule with no incident behind it is not proposed at tier A" \
    -- python3 "$TOOL/scan.py" --skills "$SC"

run 0 "asking for tier B surfaces it, with the reason it is only a candidate" \
    -- python3 "$TOOL/scan.py" --skills "$SC" --tier B
says "no incident is recorded here"

absent "logs-skill/INCIDENTS.md" "an incident log is not mined for rules" \
    -- python3 "$TOOL/scan.py" --skills "$SC" --tier B

# artifacts annotate a finding; they never remove one
printf '#!/bin/bash\nexit 0\n' > "$SC/alpha/guard_test.sh"
run 0 "an existing guard test is reported as an artifact" \
    -- python3 "$TOOL/scan.py" --skills "$SC"
says "guard test (guard_test.sh)"
says "Never run the importer twice"
# and one nested deeper, where check-rules.sh would still run it
mkdir -p "$SC/alpha/tests/unit"
mv "$SC/alpha/guard_test.sh" "$SC/alpha/tests/unit/guard_test.sh"
run 0 "a guard nested inside the skill is found too" \
    -- python3 "$TOOL/scan.py" --skills "$SC"
says "tests/unit/guard_test.sh"
rm -rf "$SC/alpha/tests"

# a rule named in the registry FOR THAT FILE is guarded; an identical copy
# somewhere else is not, and must still be reported
mkdir -p "$SC/copycat"
cp "$SC/alpha/SKILL.md" "$SC/copycat/SKILL.md"
printf 'alpha|Never run the importer twice|2026-03-27 double run, 400 duplicate rows\n' \
  > "$SC/reg.tsv"
run 0 "a rule named in the registry counts as guarded for that file" \
    -- python3 "$TOOL/scan.py" --skills "$SC" --rules "$SC/reg.tsv"
says "already named in the registry: 1"
says "copycat/SKILL.md"
absent "alpha/SKILL.md" "... and the registered copy drops off the list" \
    -- python3 "$TOOL/scan.py" --skills "$SC" --rules "$SC/reg.tsv"

# a malformed registry row is not evidence and must not suppress anything
printf 'alpha|Never run the importer twice\n' > "$SC/bad.tsv"
run 2 "a malformed registry row is refused rather than tolerated" \
    -- python3 "$TOOL/scan.py" --skills "$SC" --rules "$SC/bad.tsv"
says "need target|MARKER|incident"
rm -rf "$SC/copycat"

# one rule carried by two skills is ONE candidate
mkdir -p "$SC/gamma2"
cp "$SC/alpha/SKILL.md" "$SC/gamma2/SKILL.md"
run 0 "one rule carried by two skills is reported once" \
    -- python3 "$TOOL/scan.py" --skills "$SC"
says "same rule also in:"
assert "... and it appears once, not twice" \
    bash -c '[ "$(python3 "'"$TOOL"'/scan.py" --skills "'"$SC"'" | grep -c "Never run the importer twice")" = "1" ]'
rm -rf "$SC/gamma2"

# two DIFFERENT rules sharing a bold label must not merge into one
mkdir -p "$SC/labels"
{ printf -- '---\nname: labels\n---\n\n'
  printf -- '- **File ownership** - never let two agents hold one file. On 2026-03-27 that cost a day.\n'
  printf -- '- **File ownership** - never rename a tracked file in the same commit. On 2026-04-02 it cost an hour.\n'
  } > "$SC/labels/SKILL.md"
run 0 "two different rules under one label stay two findings" \
    -- python3 "$TOOL/scan.py" --skills "$SC"
assert "... both are listed, not merged" \
    bash -c '[ "$(python3 "'"$TOOL"'/scan.py" --skills "'"$SC"'" | grep -c "File ownership")" = "2" ]'
rm -rf "$SC/labels"

# a registry row the checker itself could not open is not evidence of anything
printf 'missing/../alpha/SKILL.md|Never run the importer twice|2026-03-27 incident\n' \
  > "$SC/dotdot.tsv"
run 2 "a registry target containing .. is refused, not resolved" \
    -- python3 "$TOOL/scan.py" --skills "$SC" --rules "$SC/dotdot.tsv"
says "resolves onto a file the registry never named"
printf '%s|Never run the importer twice|2026-03-27 incident\n' "$SC/alpha/SKILL.md" \
  > "$SC/abs.tsv"
run 2 "an absolute registry target is refused, not resolved" \
    -- python3 "$TOOL/scan.py" --skills "$SC" --rules "$SC/abs.tsv"
says "escapes the skills tree"

# a registry row naming a file that does not exist guards nothing, and saying
# nothing about it would hide a problem check-rules.sh will fire on
printf 'ghost|Never run the importer twice|2026-03-27 incident\n' > "$SC/ghost.tsv"
run 0 "a registry target that does not exist is reported, not ignored" \
    -- python3 "$TOOL/scan.py" --skills "$SC" --rules "$SC/ghost.tsv"
says "REGISTRY POINTS AT NOTHING"
says "alpha/SKILL.md"

# the registry row is read exactly as check-rules.sh reads it. Stripping the
# line changed the TARGET, so a row written " alpha|..." suppressed alpha's rule
# here while the checker looked for " alpha/SKILL.md" and found nothing.
printf ' alpha|Never run the importer twice|2026-03-27 incident\n' > "$SC/space.tsv"
run 0 "a target with a leading space suppresses nothing" \
    -- python3 "$TOOL/scan.py" --skills "$SC" --rules "$SC/space.tsv"
says "alpha/SKILL.md"
says "REGISTRY POINTS AT NOTHING"
run 1 "... and the rule is still counted against the budget" \
    -- python3 "$TOOL/scan.py" --skills "$SC" --rules "$SC/space.tsv" --max 0
says "OVER BUDGET"

# whitespace inside a literal is meaningful: these name two different files
mkdir -p "$SC/ws"
{ printf -- '---\nname: ws\n---\n\n'
  printf -- 'Never touch `client data.csv` by hand. On 2026-01-01 that cost a day.\n'
  printf -- 'Never touch `client  data.csv` by hand. On 2026-01-01 that cost a day.\n'
  } > "$SC/ws/SKILL.md"
run 0 "two rules differing only inside a literal stay two findings" \
    -- python3 "$TOOL/scan.py" --skills "$SC"
assert "... both are listed, not collapsed by whitespace" \
    bash -c '[ "$(python3 "'"$TOOL"'/scan.py" --skills "'"$SC"'" | grep -c "Never touch")" = "2" ]'
rm -rf "$SC/ws"

# a directory entry that cannot be resolved would otherwise drop out silently
ln -s "$SANDBOX/nothing-here" "$SC/brokenlink"
run 2 "a skill entry that cannot be resolved fails the scan" \
    -- python3 "$TOOL/scan.py" --skills "$SC" --max 99
says "silently drop out"
rm -f "$SC/brokenlink"

# Installed the normal way - inside the tree it reviews - this skill must not
# review itself. A stranger's first run listed two of its own worked examples as
# unguarded rules in their stack.
SELFINST="$SANDBOX/selfinst/skills"
mkdir -p "$SELFINST/writer"
cp -R "$TOOL" "$SELFINST/tripwire"
printf -- '---\nname: tripwire\n---\n\nNever claim a fix without a test. On 2026-01-01 that was violated and it cost a day.\n' \
  > "$SELFINST/tripwire/SKILL.md"
printf -- '---\nname: writer\n---\n\nNever send an unreviewed draft. On 2026-06-03 one reached a client and was retracted.\n' \
  > "$SELFINST/writer/SKILL.md"
run 0 "installed inside the tree, the review covers the user's skills" \
    -- python3 "$SELFINST/tripwire/scan.py" --skills "$SELFINST"
says "writer/SKILL.md"
absent "tripwire/SKILL.md" "... and does not list its own doctrine as the user's problem" \
    -- python3 "$SELFINST/tripwire/scan.py" --skills "$SELFINST"
# The same tree spelled differently - a symlinked install, and on a
# case-insensitive filesystem a differently capitalised path - is still the tree.
ln -s "$SELFINST" "$SANDBOX/selfinst-link"
absent "tripwire/SKILL.md" "a symlinked path to the tree is recognised, and it still skips itself" \
    -- python3 "$SELFINST/tripwire/scan.py" --skills "$SANDBOX/selfinst-link"
UPPER="$SANDBOX/selfinst/SKILLS"
if [ -d "$UPPER" ] && [ ! "$UPPER" -ef "$SANDBOX/nonexistent-probe" ]; then
  absent "tripwire/SKILL.md" "a differently capitalised path is recognised on a case-insensitive filesystem" \
      -- python3 "$SELFINST/tripwire/scan.py" --skills "$UPPER"
else
  printf '  [SKIP] capitalised alias - this filesystem is case-sensitive\n'
fi
run 0 "asking for it by name still reviews it" \
    -- python3 "$SELFINST/tripwire/scan.py" --skills "$SELFINST" --skill tripwire
says "tripwire/SKILL.md"

# a scan that read nothing is not a result
mkdir -p "$SANDBOX/emptyskills"
run 2 "a tree with no markdown fails rather than reporting a clean scan" \
    -- python3 "$TOOL/scan.py" --skills "$SANDBOX/emptyskills"
says "read nothing is not a result"

run 2 "an explicitly named skills tree that is missing fails" \
    -- python3 "$TOOL/scan.py" --skills "$SANDBOX/no-such-tree"

# a file it cannot open is a hole in the scan, never a clean run
mkdir -p "$SC/locked"
printf -- '---\nname: locked\n---\n\nNever skip the check. On 2026-05-01 it cost a day.\n' > "$SC/locked/SKILL.md"
chmod 000 "$SC/locked/SKILL.md" 2>/dev/null || true
if [ -r "$SC/locked/SKILL.md" ]; then
  printf '  [SKIP] unreadable-file case - running as a user who can read anything\n'
else
  run 2 "an unreadable file fails the scan instead of yielding no findings" \
      -- python3 "$TOOL/scan.py" --skills "$SC" --max 0
fi
chmod 644 "$SC/locked/SKILL.md" 2>/dev/null || true
rm -rf "$SC/locked"

# a declared budget, so this can be wired into a gate without being permanently red
run 1 "more unguarded rules than the declared budget fails" \
    -- python3 "$TOOL/scan.py" --skills "$SC" --max 0
says "OVER BUDGET"
run 0 "and within budget it passes" \
    -- python3 "$TOOL/scan.py" --skills "$SC" --max 5

# --json must stay one parseable object even when the run ends over budget
assert "--json stdout is valid JSON AND the run still exits 1 when over budget" \
    bash -c 'out=$(python3 "'"$TOOL"'/scan.py" --skills "'"$SC"'" --max 0 --json 2>/dev/null); rc=$?; [ "$rc" = "1" ] && printf "%s" "$out" | python3 -c "import json,sys; json.load(sys.stdin)"'

# recording a baseline and checking against one are separate operations, because
# a gate that writes its own passing baseline when the file is missing accepts
# whatever it finds the day somebody deletes it
run 2 "checking against a baseline that does not exist FAILS" \
    -- python3 "$TOOL/scan.py" --skills "$SC" --baseline "$SANDBOX/never-recorded.txt"
says "Record it first"

run 0 "recording a baseline is an explicit, separate action" \
    -- python3 "$TOOL/scan.py" --skills "$SC" --record-baseline "$SANDBOX/base.txt"
# Tied to the number the scan itself reports, so writing 999 fails here rather
# than sailing through the rerun below.
EXPECTED_N=$(python3 "$TOOL/scan.py" --skills "$SC" --json 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["findings"]))')
assert "... and the recorded file holds exactly the count the scan reported" \
    bash -c '[ "$(cat "'"$SANDBOX"'/base.txt")" = "'"$EXPECTED_N"'" ]'
run 0 "... and the scan passes against the file it just wrote" \
    -- python3 "$TOOL/scan.py" --skills "$SC" --baseline "$SANDBOX/base.txt"

printf '0\n' > "$SANDBOX/base.txt"
run 1 "a baseline that has been beaten cannot grow again" \
    -- python3 "$TOOL/scan.py" --skills "$SC" --baseline "$SANDBOX/base.txt"

# recording writes a NEW number; checking enforces an old one. Doing both in one
# run would overwrite the ceiling it was supposed to be checked against.
printf '0\n' > "$SANDBOX/ceiling.txt"
run 2 "--record-baseline cannot be combined with a check" \
    -- python3 "$TOOL/scan.py" --skills "$SC" --record-baseline "$SANDBOX/ceiling.txt" --max 0
assert "... and the existing ceiling was left untouched" \
    bash -c '[ "$(cat "'"$SANDBOX"'/ceiling.txt")" = "0" ]'

printf '\377\376bad\n' > "$SANDBOX/badenc.txt"
run 2 "a baseline that is not valid text stops the run" \
    -- python3 "$TOOL/scan.py" --skills "$SC" --baseline "$SANDBOX/badenc.txt"

printf 'not a number\n' > "$SANDBOX/base.txt"
run 2 "a corrupt baseline stops the run rather than being treated as zero" \
    -- python3 "$TOOL/scan.py" --skills "$SC" --baseline "$SANDBOX/base.txt"

printf '99\n' > "$SANDBOX/base.txt"
run 1 "the stricter of --max and --baseline is still enforced when both are given" \
    -- python3 "$TOOL/scan.py" --skills "$SC" --max 0 --baseline "$SANDBOX/base.txt"

echo

# ------------------------------------------------------------------ one skill
echo "tripwire (the single entry point)"

HS="$SANDBOX/oneskill"
mkdir -p "$HS/a"
printf -- '---\nname: a\n---\n\n## NEVER SHIP ON RED\nNever merge on a red suite. On 2026-03-27 one was waved through and it cost a day.\n' \
  > "$HS/a/SKILL.md"
printf 'a|NEVER SHIP ON RED|2026-03-27 a red suite was waved through\nproofs: none - none here\nshared-rules: none - none here\n' \
  > "$SANDBOX/one.tsv"

# The dispatcher must not interpret a status. A wrapper that translated one is a
# place for a refusal to quietly become a pass.
run 1 "tripwire scan passes an over-budget status through unchanged" \
    -- bash "$TOOL/tripwire" scan --skills "$HS" --max 0
run 0 "tripwire scan passes a clean status through unchanged" \
    -- bash "$TOOL/tripwire" scan --skills "$HS" --max 9
run 2 "tripwire scan passes a could-not-run status through unchanged" \
    -- bash "$TOOL/tripwire" scan --skills "$SANDBOX/no-such-tree"
run 1 "tripwire conform passes a failure through unchanged" \
    -- bash "$TOOL/tripwire" conform --quiet "$HS"
run 0 "tripwire check passes a clean run through unchanged" \
    -- bash "$TOOL/tripwire" check --rules "$SANDBOX/one.tsv" --skills "$HS"
run 3 "tripwire sync passes a configured-and-wrong status through unchanged" \
    -- bash "$TOOL/tripwire" sync --canon "$SANDBOX/no-canon.md" --skills "$HS"
run 0 "hooks help works" -- bash "$TOOL/tripwire" help
run 2 "an unknown subcommand is refused and names the alternatives" \
    -- bash "$TOOL/tripwire" nonsense
says "unknown command"

# a dispatcher that silently did nothing when a tool was missing would be worse
# than no dispatcher
mv "$TOOL/scan.py" "$TOOL/scan.py.hidden"
run 2 "a missing subcommand tool is refused, not skipped" \
    -- bash "$TOOL/tripwire" scan --skills "$HS"
says "is missing"
mv "$TOOL/scan.py.hidden" "$TOOL/scan.py"

# ---- ONE registry parser, not two --------------------------------------
# check-rules.sh and scan.py each used to split rules.tsv themselves, and they
# disagreed: a row with a leading space was guarded according to one and
# unguarded according to the other.
printf ' a|NEVER SHIP ON RED|2026-03-27 incident\nproofs: none - x\nshared-rules: none - x\n' \
  > "$SANDBOX/spaced.tsv"
run 1 "check-rules treats a leading-space target as a target it cannot open" \
    -- bash "$TOOL/check-rules.sh" --rules "$SANDBOX/spaced.tsv" --skills "$HS"
run 0 "and scan reports the very same row as pointing at nothing" \
    -- python3 "$TOOL/scan.py" --skills "$HS" --rules "$SANDBOX/spaced.tsv"
says "REGISTRY POINTS AT NOTHING"

printf 'a||incident\n' > "$SANDBOX/emptymarker.tsv"
run 2 "the shared parser refuses an empty marker" \
    -- python3 "$TOOL/registry.py" validate "$SANDBOX/emptymarker.tsv"
says "inspected nothing"
run 2 "... and check-rules refuses the same row, through the same parser" \
    -- bash "$TOOL/check-rules.sh" --rules "$SANDBOX/emptymarker.tsv" --skills "$HS"
says "inspected nothing"

printf 'proofs: none\n' > "$SANDBOX/barewaiver.tsv"
run 2 "a waiver with no written reason is refused" \
    -- python3 "$TOOL/registry.py" validate "$SANDBOX/barewaiver.tsv"
says "with the hyphen and a reason"

# A NUL in the registry would be a field separator on the wire to the shell,
# so a row could forge a record pointing at any file on disk.
printf 'a|NEVER SHIP ON RED|incident\0%s\0junk\n' "$HS/a/SKILL.md" > "$SANDBOX/nul.tsv"
run 2 "a registry containing a NUL byte is refused" \
    -- python3 "$TOOL/registry.py" validate "$SANDBOX/nul.tsv"
says "NUL byte"
run 2 "... and check-rules refuses it too, through the same parser" \
    -- bash "$TOOL/check-rules.sh" --rules "$SANDBOX/nul.tsv" --skills "$HS"

# "proofs: required" is not a waiver. Accepting any text after the colon turned
# a line ASKING for the phase into one that skipped it.
printf 'a|NEVER SHIP ON RED|incident\nproofs: required\n' > "$SANDBOX/notwaiver.tsv"
run 2 "a line that is not the waiver form is refused, not read as a waiver" \
    -- bash "$TOOL/check-rules.sh" --rules "$SANDBOX/notwaiver.tsv" --skills "$HS"
says "only ever a waiver"

# an absolute target escapes the tree the checker was pointed at
printf '%s|NEVER SHIP ON RED|incident\n' "$HS/a/SKILL.md" > "$SANDBOX/abs2.tsv"
run 2 "an absolute registry target is refused by the checker, not resolved" \
    -- bash "$TOOL/check-rules.sh" --rules "$SANDBOX/abs2.tsv" --skills "$HS"
says "escapes the skills tree"
run 2 "... and scan.py refuses the identical row" \
    -- python3 "$TOOL/scan.py" --skills "$HS" --rules "$SANDBOX/abs2.tsv"
says "escapes the skills tree"

# a parser that emits one good record and then dies must not look successful
cp "$TOOL/registry.py" "$SANDBOX/registry.py.good"
python3 - "$TOOL/registry.py" <<'EOS'
import sys
p = sys.argv[1]; s = open(p).read()
old = "        for target, marker, why, _ln in rows:"
new = "        for _i, (target, marker, why, _ln) in enumerate(rows):\n            if _i == 1: sys.exit(9)"
assert old in s
open(p, "w").write(s.replace(old, new, 1))
EOS
printf 'a|NEVER SHIP ON RED|incident\na|SECOND RULE|incident two\nproofs: none - x\nshared-rules: none - x\n' \
  > "$SANDBOX/tworows.tsv"
run 2 "a registry parser that dies mid-stream fails the gate, it does not shorten it" \
    -- bash "$TOOL/check-rules.sh" --rules "$SANDBOX/tworows.tsv" --skills "$HS"
cp "$SANDBOX/registry.py.good" "$TOOL/registry.py"

# a producer that exits 0 but stops mid-record. The crash case above trips the
# exit-status check first, so without this the framing check is never the thing
# that fires and could be deleted unnoticed.
cp "$TOOL/registry.py" "$SANDBOX/registry.py.good2"
python3 - "$TOOL/registry.py" <<'EOS'
import sys
p = sys.argv[1]; s = open(p).read()
# An anchor with no backslash escapes: inside this heredoc, "\0" would become
# a real NUL in the Python string and never match the two characters on disk.
old = "join([target, marker, why, f])"
new = ("join([target, marker, why, f][:3] if target.endswith('TRUNCATE') "
       "else [target, marker, why, f])")
assert old in s, "injection anchor missing"
open(p, "w").write(s.replace(old, new, 1))
EOS
mkdir -p "$HS/aTRUNCATE"
printf -- '---\nname: aTRUNCATE\n---\n\n## NEVER SHIP ON RED\n' > "$HS/aTRUNCATE/SKILL.md"
printf 'aTRUNCATE|NEVER SHIP ON RED|incident\nproofs: none - x\nshared-rules: none - x\n' \
  > "$SANDBOX/trunc.tsv"
run 2 "a producer that exits 0 but truncates a record fails the gate" \
    -- bash "$TOOL/check-rules.sh" --rules "$SANDBOX/trunc.tsv" --skills "$HS"
says "incomplete record"
cp "$SANDBOX/registry.py.good2" "$TOOL/registry.py"
rm -rf "$HS/aTRUNCATE"

# a COMPLETE record followed by an unterminated tail. The separator count still
# divides by the record width, so counting NULs cannot see this; the bytes have
# to end on a separator.
cp "$TOOL/registry.py" "$SANDBOX/registry.py.good3"
python3 - "$TOOL/registry.py" <<'EOS'
import sys
p = sys.argv[1]; s = open(p).read()
# Anchored after the rows loop so the tail lands after a COMPLETE record.
# Injecting inside the record produced a short record instead, which the
# framing check caught for the wrong reason.
old = "        return 0\n    die(\"unknown command"
new = "        sys.stdout.write(\"tail\")\n        return 0\n    die(\"unknown command"
assert old in s, "injection anchor missing"
open(p, "w").write(s.replace(old, new, 1))
EOS
run 2 "a complete record followed by an unterminated tail fails the gate" \
    -- bash "$TOOL/check-rules.sh" --rules "$SANDBOX/one.tsv" --skills "$HS"
says "ends mid-record"
cp "$SANDBOX/registry.py.good3" "$TOOL/registry.py"

# the framing validator's own refusals, exercised directly
printf 'a\0b\0c\0d\0' > "$SANDBOX/frame-ok"
run 0 "a complete set of records frames cleanly" \
    -- python3 "$TOOL/registry.py" frame "$SANDBOX/frame-ok" 4
printf 'a\0b\0c\0' > "$SANDBOX/frame-short"
run 2 "a short record is refused" \
    -- python3 "$TOOL/registry.py" frame "$SANDBOX/frame-short" 4
printf 'a\0b\0c\0d\0tail' > "$SANDBOX/frame-tail"
run 2 "a trailing unterminated field is refused" \
    -- python3 "$TOOL/registry.py" frame "$SANDBOX/frame-tail" 4

# whitespace before the colon is still a waiver, and still refused when
# malformed - the two checks used to disagree about which lines they covered
printf 'a|NEVER SHIP ON RED|incident\nproofs : none - spaced before the colon\nshared-rules: none - x\n' \
  > "$SANDBOX/spacedcolon.tsv"
run 0 "a waiver with whitespace before the colon is recognised" \
    -- bash "$TOOL/check-rules.sh" --rules "$SANDBOX/spacedcolon.tsv" --skills "$HS"
says "spaced before the colon"
printf 'a|NEVER SHIP ON RED|incident\nproofs : required\n' > "$SANDBOX/spacedbad.tsv"
run 2 "... and a malformed one with the same spacing is refused as a waiver" \
    -- bash "$TOOL/check-rules.sh" --rules "$SANDBOX/spacedbad.tsv" --skills "$HS"
says "only ever a waiver"

# a waiver missing its separator is not a waiver
printf 'a|NEVER SHIP ON RED|incident\nproofs: none required\n' > "$SANDBOX/nohyphen.tsv"
run 2 "a waiver written without the hyphen is refused" \
    -- bash "$TOOL/check-rules.sh" --rules "$SANDBOX/nohyphen.tsv" --skills "$HS"
says "with the hyphen and a reason"

# behavioural proof that BOTH consumers go through the shared parser: one
# malformed row, refused identically by each. A source-text grep cannot show
# this, and a second parser would have to reimplement the same refusal to pass.
printf 'a|NEVER SHIP ON RED\n' > "$SANDBOX/short.tsv"
run 2 "the checker refuses a short row" \
    -- bash "$TOOL/check-rules.sh" --rules "$SANDBOX/short.tsv" --skills "$HS"
says "need target|MARKER|incident"
run 2 "the parser refuses the same short row with the same words" \
    -- python3 "$TOOL/registry.py" validate "$SANDBOX/short.tsv"
says "need target|MARKER|incident"
# The third consumer, held to the same contract. A scanner more tolerant than
# the gate would report a different world than the gate enforces.
run 2 "and scan.py refuses it too, rather than skipping it quietly" \
    -- python3 "$TOOL/scan.py" --skills "$HS" --rules "$SANDBOX/short.tsv"
says "need target|MARKER|incident"

assert "rules.tsv is parsed in exactly one file" \
    bash -c '[ "$(grep -l "split(\"|\")" "'"$TOOL"'"/*.py 2>/dev/null | wc -l | tr -d " ")" = "1" ]'

echo

# ---------------------------------------- one installation, somebody else's tree
# Found by a model given ONLY this skill and an unfamiliar skill stack: every
# tool fell back to the files beside the script, so one installation's shared
# rules and registry were applied to any tree it was pointed at. A fresh stack
# always reported a skill it never had as missing, and no waiver could clear it.
echo "configuration comes from the tree being checked"

BL="$SANDBOX/bleed"
mkdir -p "$BL/stack/solo"
printf -- '---\nname: solo\n---\n\n## ONLY RULE\n' > "$BL/stack/solo/SKILL.md"
# plant an installation's own configuration beside the tool
cat > "$TOOL/SHARED-RULES.md" <<'EOS'
<!-- RULE:installation-only consumers: a-skill-this-stack-never-had -->
## A RULE FROM SOMEBODY ELSE'S LIBRARY

Text.
<!-- /RULE:installation-only -->
EOS
printf 'a-skill-this-stack-never-had|NOT HERE|incident from another library\n' > "$TOOL/rules.tsv"

run 2 "sync does not borrow the installation's canon for a different tree" \
    -- python3 "$TOOL/sync-rules.py" --check --skills "$BL/stack"
says "no canonical rules file found"

printf 'solo|ONLY RULE|2026-01-01 incident\nproofs: none - fixture\nshared-rules: none - fixture\n' \
  > "$BL/stack/rules.tsv"
run 0 "check on a fresh stack is clean, with no rule from another library leaking in" \
    -- bash "$TOOL/check-rules.sh" --skills "$BL/stack"
says "solo carries: ONLY RULE"
absent "a-skill-this-stack-never-had" "... and nothing from the installation's registry appears" \
    -- bash "$TOOL/check-rules.sh" --skills "$BL/stack"

rm "$BL/stack/rules.tsv"
run 1 "a stack with NO registry refuses for the right reason, not by borrowing one" \
    -- bash "$TOOL/check-rules.sh" --skills "$BL/stack"
says "no rules registry"

# The count stays 0 whether or not a foreign registry is read, because its row
# matches nothing here - so that alone could not tell borrowing from not. What
# discriminates is WHICH registry scan reports it read.
run 0 "scan reads no registry for a stack that has none" \
    -- python3 "$TOOL/scan.py" --skills "$BL/stack"
says "registry:    <none>"
absent "a-skill-this-stack-never-had" "... and never reports the installation's rows" \
    -- python3 "$TOOL/scan.py" --skills "$BL/stack"

rm -f "$TOOL/SHARED-RULES.md" "$TOOL/rules.tsv"

# The first fix for the bleed broke the ordinary case: `sync` with NO flags
# stopped finding the installation's OWN canon, because the canon was looked
# for before the tree was resolved. Nothing caught it but a reviewer's question.
# So: a real installation layout, run with no flags and no environment.
INST="$SANDBOX/installation/skills"
mkdir -p "$INST/tripwire" "$INST/consumer"
cp "$TOOL/sync-rules.py" "$INST/tripwire/"
cat > "$INST/tripwire/SHARED-RULES.md" <<'EOS'
<!-- RULE:own-canon consumers: consumer -->
## THE INSTALLATION'S OWN RULE

Its text.
<!-- /RULE:own-canon -->
EOS
printf -- '---\nname: consumer\n---\n' > "$INST/consumer/SKILL.md"
env -u CLAUDE_SKILLS_DIR -u CLAUDE_HOOKS_CANON \
    python3 "$INST/tripwire/sync-rules.py" --skills "$INST" >/dev/null 2>&1
run 0 "sync with no flags finds the canon of the tree the skill sits in" \
    -- env -u CLAUDE_SKILLS_DIR -u CLAUDE_HOOKS_CANON \
       python3 "$INST/tripwire/sync-rules.py" --check
says "1 consumer copy"

echo
if [ "$BAD" = "0" ]; then
  echo "selftest: $TOTAL/$TOTAL assertions behaved as declared - every gate here has been shown to fail."
  exit 0
fi
echo "selftest: $BAD of $TOTAL assertions did NOT behave as declared."
exit 1
