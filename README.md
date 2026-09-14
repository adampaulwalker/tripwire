# Tripwire

A Claude Code skill that reviews your skill stack and finds the rules nothing enforces.

Every skill library accumulates rules. Most live in a SKILL.md as a sentence: *never do this*, *always check that*. Some of them get broken anyway, and writing them more emphatically doesn't help. Tripwire reads every skill you have, finds each rule that states an obligation, works out which ones nothing enforces, and ranks them by whether the rule has already been broken. Then it turns the ones worth guarding into checks that fail, registers them so they can't be quietly deleted, and proves each one fires before anyone relies on it.

**It reviews your whole stack the first time you run it.**

```bash
./tripwire scan --skills ~/.claude/skills
```

## What the review finds

Run against one real library of 101 skills, it read 1,864 lines that state an obligation and listed 31. Those 31 each cite a dated incident and still have nothing executing behind them - somebody cared enough to write down what the mistake cost, then left the rule as prose.

The other 1,833 are counted and not listed. A reviewer that printed all of them would be switched off within a day, so the ranking is the feature:

| Tier | What it is | Listed? |
|---|---|---|
| **A** | states an obligation, cites an incident, nothing enforces it | yes, each with a next action |
| **B** | checkable, but no incident recorded | only if you ask, with the reason it's a candidate and not a job |
| **C** | states an obligation and nothing more | counted, never listed |

On that same library one of the rules it surfaced was being broken at the moment it ran: it said code lives in git and never in a synced document folder, and 51MB of git data was sitting in one. That rule and one other became guards. The first fails on any new violation, while the two that already existed stay listed until someone clears them.

## What's in it

| | |
|---|---|
| `tripwire scan` | reviews the skill stack: which rules are still only prose |
| `tripwire check` | is each registered rule still in its skill, does every guard still pass |
| `tripwire conform` | does a project carry the mechanisms, or only the advice |
| `tripwire sync` | one canonical text for a rule several skills need, no drift |
| `tripwire selftest` | breaks every gate on purpose and watches it go red |

`SKILL.md` is the doctrine behind it: ten rules for a guard that catches something, the shapes that work, and how to build one.

Exit codes pass through untouched: 0 clean, 1 a check fired, 2 it could not run. The entry point never interprets a status, because a wrapper that translated one would be a place for a refusal to quietly become a pass.

## Install

```bash
git clone https://github.com/adampaulwalker/tripwire.git
cd tripwire
bash install.sh
```

That runs the selftest first, so a broken checkout can't become an installed skill, then links the folder into `~/.claude/skills/tripwire`. Claude Code picks it up as `/tripwire`.

Then run the review. Copy `rules.example.tsv` to `rules.tsv` and register the rules you decide to guard. Until you do, `tripwire check` refuses with `no rules registry`, which is deliberate - an empty registry is a gate that inspected nothing, not a clean run.

## Every gate here has been shown to fail

A gate that has never blocked anything is decoration, and a test that passes on broken code passes exactly as green as a real one. So `tripwire selftest` breaks each gate and requires it to refuse. It runs 275 assertions, each declaring an exact exit status in advance, and passes on bash 3.2 and bash 5.

Most of those cases exist because this repository kept failing its own test. It once credited a mechanism that was only named in a README. It once reported a missing gate as a clean run, because it called a function it never defined. And once it was pointed at a real library, it credited a copy of itself sitting in a git worktree, a copy that cannot run.

Every one of those is now a selftest case, which is the only form of "fixed" this skill accepts.

## The honest limit

A guard catches the mistake it was built from. It won't make anyone careful, and it won't catch the next novel thing. What it buys is that one class of error stops recurring without anyone having to remember. `SKILL.md` closes with what nothing here verifies, which is what makes the rest trustworthy.

MIT licensed. Use freely.
