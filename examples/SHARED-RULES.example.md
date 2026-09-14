# Shared rules - the canonical text

Rules that must appear IN FULL in more than one skill, because each skill is
loaded on its own and a pointer is not in context when the rule is needed.

That makes them vendored copies, with the drift problem vendored copies always
have. So: this file is the source of truth, `sync-rules.py` pushes it into
every consumer, and `check-rules.sh` refuses if any copy differs by a byte.

To change a rule: edit it HERE, run `python3 sync-rules.py`, commit both.
Never edit a shared rule inside a consumer skill.

Copy this file to `SHARED-RULES.md` beside `sync-rules.py` and replace the rule
below with your own.

---

<!-- RULE:prove-it-fails consumers: qa build -->
## NOTHING IS DONE UNTIL IT HAS BEEN SHOWN TO FAIL

A test that passes on the broken code proves nothing, and it passes exactly as
green as a real one. Green is not evidence. Green on code you have not first
seen go red is a coin landing heads.

### Why this is the rule and not "be careful"

Every vacuous guard in this repository's history was written by someone who
knew this rule. Two were written the same afternoon it was added to the skill.
One of them greped the source file for a string that its own comment contained.

### How

1. Write the guard.
2. Break the thing it guards - revert the fix, doctor the fixture, delete the
   section it asserts on.
3. Run it. It must go RED, and the message must name what is wrong.
4. Restore. It must go GREEN.
5. Record steps 3 and 4 in the commit message or the guard's docstring.

A guard that has not been through this is not finished, whatever it reports.
<!-- /RULE:prove-it-fails -->
