---
name: tripwire
description: Reviews your skill stack and finds the rules that are still only prose - written down, broken anyway, and enforced by nothing - then turns the ones worth guarding into checks that fail, registers them so they cannot be quietly deleted, and proves each one fires before trusting it. Run it after installing to audit every skill you have. Also use when the same mistake recurs despite being written down, when a gate has never blocked anything, when a check "passed" on work it never inspected, or before trusting any new gate. Triggers on "review my skills", "audit my skill stack", "what rules are unguarded", "build a tripwire", "add a guard", "make this mandatory", "how do we stop this happening again", "prove the gate can fail".
---

# Tripwire

**Tripwire reviews your skill stack.** Point it at the skills you have and it reads
every one, finds each rule that states an obligation, works out which of those
nothing enforces, and ranks what is left by whether the rule has already been
broken. Then it helps you turn the ones worth guarding into checks that fail,
registers them so they cannot be quietly deleted, and proves each check fires
before anyone relies on it.

Start here, the first time:

    ~/.claude/skills/tripwire/tripwire scan --skills ~/.claude/skills


A tripwire is a check that fires on the mistake you have ALREADY made, in the
place you will make it again. Wire it into the commit gate, the test suite, the
finish script - wherever the work cannot get past it.

Not a linter. Not a style rule. A specific, named, provable guard against a
specific, named, dated incident.

> Naming note: Claude Code also has a settings.json feature called hooks, which
> runs a command on a tool event. That is one good place to wire a guard built
> with this skill, and it is not what this skill is about. This skill is about
> deciding what to guard, building a check that can actually fail, and proving
> it does.

## When you need one

The trigger is not "this seems risky". It is:

**The rule was already written down, and it was broken anyway.**

That sentence is the whole test. If a rule lives in a CLAUDE.md, a memory file,
a docstring or a code comment, and somebody violated it despite that, the rule
has failed as a rule. Writing it more emphatically will not help. It needs to
execute.

Real examples, all from one repository on one day:

- "The service loads the copy under `vendor/`, so fix the copy that runs" - a
  memory file, written after it cost a day. Violated twice more within the hour,
  once by the agent that had just read it, once inside the tool built to
  prevent it.
- "Never claim a fix without a test that fails on the pre-fix code" - violated
  by a test that loaded the wrong module and passed green against code it was
  not testing.
- Defect class 11 in a project's own taxonomy, named and explained, with no
  guard built. The exact defect it described shipped eight times.

**Knowing a rule and applying it are different things. Prose does not execute.**

## When you do NOT need one

- The mistake has been made once and the cause is now structurally impossible.
- The check cannot fail (see rule 4, below).
- You are guessing at a future problem. Tripwires are built from incident reports,
  not from imagination. A guard with no incident behind it gets deleted by the
  next person who finds it annoying, and they will be right.

## What makes a GOOD guard

### 1. It names its incident, with a date and a cost

Every check carries the story. Not "check for sentinels" but "on 2026-08-30
five `n/a` cells out of 486 read as absent values and withdrew twenty slides of
one report section". A check whose reason is forgotten is a check that gets
removed.

### 2. It fails by DEFAULT. Absence is not a pass.

The most common way a gate becomes decoration: it only fires when something is
present, so doing nothing looks like doing it right. Invert it. An unrecorded
check is a failure, not a skip. A bare `SKIP` is a silence wearing a label -
require a reason. A `PASS` with no statement of what was inspected is refused,
because a checker with a hardcoded path passes happily on files nobody edited.

### 3. Exemptions live AT THE CODE, never in the checker

A central allowlist goes invisible within a week. A marker comment beside the
line gets read by the next person to touch it:

    # tripwire-allow: sentinel is deliberate. This metric sits under the
    # reconciliation gate below - when the denominator cannot be shown to mean
    # what its label says, the card AND the table must both withdraw.
    return f"${round(x):,}" if x is not None else "n/a"

The scanner honours the marker; the reason is forced into the diff where a
reviewer sees it. This is not a convenience - it immediately surfaced a fourth
site the author had missed, because each exemption had to be argued separately.

### 4. It is PROVEN to fire before it is trusted

**A gate that has never blocked anything is decoration.** So break the code on
purpose and watch it go red. Every gate ships with that demonstration recorded.

The corollary matters more: **a test that passes on the broken code proves
nothing, and passes exactly as green as a real one.** The only way to know is
to revert the fix and check the test fails. Do this every time. It has caught
vacuous tests written minutes earlier by someone who knew the rule.

`selftest.sh` in this repo is that demonstration for every gate shipped here. Two hundred and seventy-five assertions, each declaring an exact exit
status in advance, so a crash cannot read as a successful refusal. Run it
before trusting any of them:

    tripwire selftest

### 5. It reports PASS / FAIL / SKIP-with-reason, never silence

"Not applicable" must never look like "checked and passed".

### 6. It says how to clear it

A refusal that does not name the next action gets worked around.

### 7. A SKIP is not a result. Hunt for silent ones.

A failing check is loud. A SKIPPED one is invisible - it reports neither pass
nor fail and vanishes into a summary line. On 2026-09-01 a fixture path that
resolved above the repository root in a git worktree meant 38 guards over one
ingest layer skipped silently, while the suite read "1283 passed" and looked
healthy. Nobody had run those guards for weeks.

So: count your skips, know the reason for every one, and make a missing
precondition fail LOUDLY rather than skip quietly. One red test beats 38
invisible ones. If a skip is legitimate, it carries a written reason and lives
on a list that may shrink, never grow.

### 8. Read the producer before naming a cause

The most expensive mistake of that session was not a bad fix - it was asserting
a MECHANISM without opening the code that implements it. Three root causes were
named and wrong before being caught:

- "the callout is anchored to the table" - nothing in the pipeline writes a
  transform; the footnote sits at a fixed template position and the TABLE grows
  into it.
- "the delta colour is one constant" - it is a per-section scoping bug, and
  flipping the constant would have broken a section that was correct.
- "those blank rows are an oversight" - they are the deliberate output of a
  mechanism that prevented a twenty-slide loss.

Each was plausible from the symptom and wrong at the source. A cause you have
not read is a guess wearing a diagnosis. Measure before assuming, too: a table
overprinting its own footnote looked template-owned until the geometry showed
`rowHeight` is a MINIMUM and cells were wrapping.

### 9. Never grep raw source in a test

It matches your own comments. A truncation guard once passed because it found
its own note reading "this was `name[:38]`". And a string slice is not a parser
- two guards sliced source on a literal, cut the function in half, and passed
against the pre-fix tree. Parse it, or assert on behaviour.

### 10. A marker in a document is a plan, not a mechanism

Found in this repository's own gate, 2026-09-13. `conformance.sh` searched the
whole project tree for its four markers and passed on any hit. A `docs/plan.md`
reading "add tripwire:coverage-map next quarter" satisfied all four and the
gate reported *carries all 4 mechanisms*, exit 0.

That is this skill's own failure mode, shipped inside the tool built to stop
it: advice reported as a mechanism. The fix is in the gate, not in the rule -
documentation extensions are excluded, and a project whose only hits are in
prose fails with that named as the reason. The selftest case is
`prose fails - markers named only in a document are a plan, not a mechanism`.

The same gate then passed on `# TODO: add tripwire:coverage-map here once the
refactor lands`, which is a code file by every test the fix had just added. A
marker on a TODO line announces intent; it does not claim a mechanism. So TODO,
FIXME, XXX, WIP and "next quarter" now disqualify the line, and the refusal says
which line it read.

Found the same day, same file family: `check-rules.sh` called a `skip()`
function it never defined. The one branch that reached it - the drift gate
missing entirely - printed `command not found` to stderr and left the exit code
clean. A missing gate reported as a clean run. Both bugs are the same bug.

Then the fix produced a third. Moving the scan to NUL-separated filenames is
strictly safer on paper, and `grep -rlIZ` is documented to emit them - but BSD
grep ignores `-Z` when `-l` is set and writes newlines anyway. The NUL reader
found no records, so every mechanism reported absent. Reaching for the safer
primitive without checking what the local one actually does is rule 8 again:
a mechanism you have not read is a guess. The scan is a `find -print0` census
now, and a filename no line-oriented scan can represent stops the run.

## Shapes that work

**Meta-test** - a test over the other tests. "No eval may bare-import a module
that exists in more than one copy." Found six pre-existing violations on its
first run, including the guard for the repository's worst historical defect.

**Census, not instance** - when a defect is found, grep for the CLASS before
fixing the INSTANCE. One bad sentinel was visible on a page; the census found
eight, seven invisible on that quarter's data because they need a zero
denominator to fire. Fixing the visible one would have been a fix that fixed
nothing.

**Definitional invariant** - assert what a LABEL implies about its value.
Nested funnel stages are a subset chain, so `views >= 75%-views >= completions`.
This catches a mis-wired metric using only the numbers already on the page,
with no source lookup and no knowledge of which field is wrong.

**Receipt with named checks** - replace "did somebody look at it?" with a list
of every check owed, each needing a verdict and evidence. Missing check = the
job cannot report success.

**Parity gate** - when a file is vendored to N places, hash them and refuse on
drift. This one catches the author mid-mistake, repeatedly.

**Baseline assertion** - state the known pass/fail count. "No regressions" is
not a claim until there is a number to compare against.

**Discovery, never a list** - find the guards by convention rather than naming
them in an array. A hardcoded list cannot see a guard in a directory nobody
added to the list, so absence is invisible - the failure this whole skill is
about. `check-rules.sh` discovers every `guard_test.sh` / `guard_test.py` under
the skills tree and runs it.

## How to build one

1. **Write the incident down first.** Date, what shipped, what it cost. If you
   cannot, you do not have a guard, you have a preference.
2. **Find the narrowest mechanical signal** that would have caught it. Assert
   on what the code produces, or parse the source - never grep it (rule 9); prefer arithmetic over
   judgment.
3. **Write it to fail closed.**
4. **Break the code and watch it fire.** Record that you did.
5. **Run it on the whole existing tree.** It will find things. That is the
   point, and it is also how you learn whether your signal has false positives
   - fix those in the CHECK, never by narrowing the rule.
6. **Give exemptions a site marker and a reason.**
7. **Wire it where it cannot be forgotten** - the commit gate, the test suite,
   the finish script, a Claude Code `PreToolUse` hook, the pipeline's own
   terminal state.

## Finding the rules worth guarding

Everything above assumes you already know which rule to guard. `scan.py` finds
the candidates: it reads a tree of skills, pulls out every line that states a
binding obligation, works out which ones nothing enforces, and ranks what is
left by how much evidence there is that the rule has ALREADY been broken.

    tripwire scan --skills ~/.claude/skills

**The ranking is the entire feature.** Measured on 2026-09-14 over one real
library of 101 skills and 256 markdown files: 1,864 lines state an obligation. A
reviewer that printed those would be switched off within a day, and switching it
off would be the correct decision - a filter that fires constantly is not a
filter, whatever its hit rate looks like.

| Tier | What it is | Count in that library |
|---|---|---|
| **A** | states an obligation, CITES AN INCIDENT, nothing enforces it | 33, listed as 31 once a rule carried by several skills is merged |
| **B** | states an obligation, mechanically checkable, no incident recorded | 364 |
| **C** | states an obligation and nothing more | 1,458 |

Another 9 were already named in the registry and dropped off the list.

Tier A is the bullseye: somebody cared enough to write down what the mistake
cost, and still left the rule as prose. That is this skill's thesis, found for
you.

Tier B is a candidate, not a job. The rule above still holds - a guard with no
incident behind it gets deleted by the next person who finds it annoying, and
they are right - so tier B is listed only when you ask for it (`--tier B`), with that reason attached rather than a
suggestion to go build something.

Tier C is counted and never listed. The count is printed so you can see the size
of what was filtered instead of wondering whether the scan was any good.

### After the review: guard what deserves it

The review is the first half. The second half is the reason to run it. Work
only on tier A; tier B waits for an incident and tier C is not work.

1. **Take each tier-A finding in turn.** For every one that has a mechanical
   signal - a file that must not exist, a string a skill must carry, a value
   that must match - build the guard: a `guard_test.sh` or `guard_test.py` in
   that skill's directory, following "How to build one" above.
2. **Break it and watch it fire, then restore it and watch it pass.** A guard
   that has not been seen to fail is not finished (rule 4).
3. **Register it** in `rules.tsv`, so deleting the rule's text turns the check
   red.
4. **Give every tier-A finding you do not guard a written verdict** in
   `AUDIT-<date>.md`, next to `rules.tsv`: the finding's file and line, and what
   a guard would need that is not available today. A finding with no verdict
   quietly becomes untrue.

Done means every tier-A finding is either guarded or has a verdict in that
file. If you registered at least one guard, done also means
`~/.claude/skills/tripwire/tripwire check --skills ~/.claude/skills` is clean.
If none was warranted, there is no registry to check, and the audit file is the
whole result.

### What it reads, and how well

Hand-checking all 29 findings from an early run: about a third were strong, a
third worth a glance, and a third junk. The junk fell into named classes -
incident logs mined as if they were rule statements, a line whose only evidence
was a bare date, one shared rule reported once per skill that carried it, and
passive statements of fact ("`--from` is validated against verified aliases")
read as instructions. Each was fixed in the CHECK rather than by narrowing what
counts as a rule: incident logs and article corpora are excluded by path,
a date with almost no prose around it is not an incident, identical rules are
merged into one finding that names every file carrying it, and the passive forms
were dropped from the obligation pattern.

That took it to roughly 17 real candidates in a list of 29 lines. It is a
shortlist for a human, not a verdict, and it is reported that way.

A rule already named in your `rules.tsv` counts as guarded and drops off the
list, so the scan and the registry stay in step: guard something, and the
number goes down.

### Wiring it in

On its own this is a report, and reports get skimmed. `--max N` fails when more
than N unguarded rules are listed, and `--baseline FILE` records the current
number and then refuses to let it grow. That is the failure-ceiling mechanism
from the table below, applied to this skill's own output: a number you can
explain, which may shrink and never grow.

    tripwire scan --skills ~/.claude/skills --baseline .tripwire-baseline

`--json` gives the whole thing, including the per-skill coverage map of which
skills state rules with nothing executing at all.

## One entry point

Five subcommands, one command, in the order the work happens. `tripwire` is the
executable file in this skill's own directory - `~/.claude/skills/tripwire/tripwire`
after a normal install. `install.sh` does not put it on your PATH, so run it by
that path, or from inside the skill's directory as `./tripwire`:

    tripwire              scan, then say what to do next
    tripwire scan         which rules are still only prose?
    tripwire check        is the guidance still in the skills?
    tripwire conform      does a PROJECT carry the mechanisms?
    tripwire sync         one canonical text, N copies, no drift
    tripwire selftest     prove every gate here can fail

Exit codes belong to the subcommand and pass through untouched: 0 clean, 1 a
check fired, 2 it could not run. The dispatcher never interprets a status,
because a wrapper that translated one is exactly where a refusal quietly
becomes a pass.

`rules.tsv` is parsed in one place, `registry.py`. It was parsed in two - once
in `check-rules.sh` and once in `scan.py` - and they disagreed almost at once:
a row written with a leading space was guarded according to one and unguarded
according to the other. That is the vendored-copy defect this skill exists to
name, found inside the skill itself. A selftest case asserts there is exactly
one parser.

## The gates, one by one

### `tripwire conform` - does the PROJECT carry the mechanisms?

Asserting that a rule's text is still in a skill guards the guidance from
deletion and nothing more. It cannot tell you whether a project built with that
guidance implemented anything.

On 2026-09-01 the answer, across four builder skills, was: three had no
contract at all and the fourth had two steps marked `required: false`. Every
rule in every one of them was advice. An agent could run the whole workflow,
skip all of it, and report done.

    tripwire conform [project-dir]

Each mechanism is claimed by a MARKER at the code - `tripwire:<id>` in the file
that implements it - because a central "yes we did that" registry goes stale in
a week while a marker sits in the diff where a reviewer sees it.

| Marker | What it must be | The incident |
|---|---|---|
| `tripwire:coverage-map` | a test enumerating the system's surfaces from the SHIPPED code, each either driven by a named test or declared uncovered with a reason | weeks of rounds each declaring completeness and finding more |
| `tripwire:dark-guards` | a meta-test: every section a guard names exists, and no guard's assertions are all conditional | 23 guards raised before their first assertion for weeks while reporting red |
| `tripwire:failure-ceiling` | a declared, small number of tolerated failures, checked | "34 pre-existing failures" hid a template shipping the literal text `None` |
| `tripwire:outcome-guards` | a check that no test asserts only by reading source | half the guards written in one day were source greps |

Those four are a starter set, not a law. Override them with a
`.tripwire-mechanisms` file in the project, or `--mechanisms FILE`. The format is
one per line: `id|what it must be|why it exists|how to clear it`.

**Absence is a failure, never a skip.** A project that never built a coverage
map must not be able to report that it has one by saying nothing. Nor by
writing the marker in a README - see rule 10.

### `tripwire check` - is the guidance still in the skills?

A rule added to a skill can be quietly deleted, and then it is prose again.
This asserts each rule is STILL THERE, in every skill that needs it.

    tripwire check --skills ~/.claude/skills

It reads `rules.tsv`, one line per rule:

    target|MARKER TEXT THAT MUST BE PRESENT|the dated incident and what it cost

`target` is a skill name, whose `SKILL.md` is checked - or an exact path inside
a skill, for a rule that must live where the skill actually loads it. Checking
only `SKILL.md` would pass on a file nobody edited, which is the hardcoded-path
failure this skill warns about.

It also discovers and runs every `guard_test.sh` / `guard_test.py` under the
skills tree, and checks shared rules for drift.

All three phases fail when there is nothing to do. No registry, no guard, no
canonical shared-rules file - each is a gap, and a gap that reports a clean run
is the decoration this skill exists to prevent. The only way to quiet one is to
write the reason into `rules.tsv`:

    proofs: none - no skill here owns an executable guard yet
    shared-rules: none - no rule is carried by more than one skill yet

Those become counted skips, printed with their reason every run. Rule 7 in
practice: a skip is legitimate only when it carries a written reason and sits
on a list that may shrink, never grow.

### `tripwire sync` - one canonical text, N copies, no drift

A rule needed by several skills has to be COPIED into each of them, because
skills load independently and a cross-reference is not in context at the moment
the rule matters. So shared guidance is a vendored copy, with the drift problem
vendored copies always have - the same one that let a fix land in three copies
of an adapter module while the service loaded the fourth.

Treat it the same way:

- `SHARED-RULES.md` holds the canonical text, each rule wrapped in
  `<!-- RULE:id consumers: a b c -->` markers naming who must carry it.
- `sync-rules.py` pushes it into every consumer.
- `check-rules.sh` refuses on a byte of drift.
- Every consumer carries a "Related skills" table, so somebody editing one can
  see the others exist before they change a shared rule in the wrong place.

Never edit a shared rule inside a consumer skill. Edit the canonical text and
sync, exactly as you would never fix one copy of a vendored module.

See `examples/SHARED-RULES.example.md` for the format with a worked rule in it.

## The honest limit

A guard catches the mistake it was built from. It does not make you careful,
and it will not catch the next novel thing. Its value is that a class of error
stops recurring, permanently, without anyone having to remember. Judgment is
still yours; the guard just stops you spending it on the same mistake twice.

## What nothing here verifies

Named because an honest list is what makes the gates above trustworthy rather
than a shortcut:

- **Whether a guard fires on the RIGHT input.** Breaking the code and watching
  it go red proves the guard can fail. It does not prove the guard fails on the
  incident it was built from rather than on something adjacent.
- **Whether the incident named is the real cause.** A guard can cite a dated
  incident whose root cause was misdiagnosed - three confidently named causes
  in one session were all wrong - and the citation looks identical.
- **Whether exemptions marked at the code are still justified.** A marker with
  a reason is read by the next person; nothing re-reads it when the reason
  stops being true.
- **Whether the rule is in every skill that NEEDS it.** `check-rules.sh`
  asserts the rules it is told about. A skill that should carry a rule and is
  not in `rules.tsv` is invisible to it.
- **One branch of the binary test.** `conformance.sh` refuses a file it cannot
  read, but in practice the recursive scan fails first and stops the run, so
  that branch is never reached from the normal path and no case exercises it.
  It stays as defence in depth, declared rather than claimed.
- **The registry reader's own failure handler.** An error raised while reading
  a registry file that opened successfully is routed to exit 2, and
  that was verified by fault injection during review, but no permanent case in
  the suite holds it there. It is the one handler in this repo protected by a
  reviewer rather than by a test.
- **Whether `scan.py` found every rule worth guarding.** It reads lines, not
  meaning. A rule spread over three sentences, or written without any of the
  words it looks for, is invisible to it. Measured precision on one library is
  reported above; recall is not measured at all, and a clean tier A means only
  that nothing matched.
- **That `check-rules.sh` runs code it discovered.** Every `guard_test.sh` and
  `guard_test.py` under the tree you point it at is executed. It runs only
  those two extensions and refuses anything else, but it is not a sandbox.
  Point it at a tree you trust.
- **Whether a marker sits on a line that does the work.** `conformance.sh`
  rejects a marker found only in documentation and only on a TODO line. It
  cannot tell a real implementation from a code comment that merely mentions
  the id, and it does not read the test it is pointed at. The marker is a
  claim by the author; the gate checks that the claim was made somewhere that
  executes, not that it is true.
