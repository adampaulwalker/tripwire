#!/usr/bin/env python3
"""scan.py - find rules that are still only prose, and rank them by evidence.

The rest of this skill assumes you already know which rule to guard. This finds
the candidates: it reads a tree of skills, extracts every line that states a
binding obligation, works out which ones nothing enforces, and ranks what is
left by how much evidence there is that the rule has ALREADY been broken.

Why the ranking is the whole feature. Measured over one real library of 102
skills: 4,164 lines state an obligation, 925 of those are mechanically
checkable, and 30 both cite a dated incident and are checkable. A scanner that
reported the first number would be switched off within a day, and it would be
right to switch it off - a filter that fires constantly is not a filter.

    Tier A  states an obligation, CITES AN INCIDENT, nothing enforces it
            The bullseye. Somebody cared enough to write down what it cost and
            still left it as prose.
    Tier B  states an obligation, mechanically checkable, nothing enforces it
            A candidate, not a job. This skill's own rule is that a guard with
            no incident behind it gets deleted by whoever finds it annoying.
            Find the incident first, or leave it alone.
    Tier C  states an obligation and nothing more
            Counted, never listed. The count is printed so you can see what was
            filtered rather than wondering.

Usage:
  python3 scan.py [--skills DIR] [--rules FILE] [--tier A|B] [--json]
                  [--max N] [--baseline FILE] [--skill NAME]

Exit codes:
  0  scan completed (and, with --max/--baseline, stayed within budget)
  1  more unguarded rules than the declared budget allows
  2  the scan could not run, or inspected nothing
"""
import argparse
import json
import os
import re
import registry
import stat as statmod
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

# A line that binds. Grounded in a real corpus rather than invented: the
# imperative forms these actually take are "never X", "always X", "must X",
# "do not X", "no X without Y", "before X, Y", plus ALL-CAPS rule headings.
# Note "refuses" and "is required" are absent. Hand-checking 48 findings over a
# real library showed the passive voice is almost always a statement of fact
# ("--from is validated against verified aliases"), not an instruction to the
# reader, and every one of those was a false positive.
OBLIGATION = re.compile(
    r"\b(never|always|must not|must|do not|don't|shall not|refuse to|"
    r"only ever|before you|no \w+ without|it is not optional|stop and)\b", re.I)

# Files that RECORD things rather than instruct. An incident log is wall-to-wall
# dates and past-tense rule statements, so it matches every signal this scanner
# has and means none of them. Excluding them took tier A from 48 findings at
# roughly one in three useful to a list worth reading.
CORPUS_PATH = re.compile(
    r"(^|/)(INCIDENTS?\.md|CHANGELOG\.md|archive/|fixtures?/|exemplars?/|"
    r"[\w-]*articles?/|samples?/|examples?/)", re.I)

# Evidence the rule has already been broken: a date, or the language people use
# when writing down what it cost.
INCIDENT = re.compile(
    r"(\b20\d\d-\d\d-\d\d\b|cost (a day|a week|weeks|hours|two \w+)|"
    r"shipped \w+ times?|reached a client|went out|was violated|violated|"
    r"broke anyway|happened again|twice more|\b(eight|nine|ten|\d+) times\b|"
    r"after it cost|we lost|had to be rotated|incident)", re.I)

# Something a check could actually look at.
MECHANICAL = re.compile(
    r"(`[^`]+`|\b[\w./-]+\.(py|sh|md|json|ya?ml|tsv|csv|txt)\b|"
    r"\bexit \d+\b|\b\d+ ?(files?|rows?|cells?|slides?|columns?|chars?|words?|"
    r"lines?|commits?)\b|\$[A-Z_]{3,})")

# Lines that look like rules but are quoting the tool, not stating one.
NOISE = re.compile(r"^\s*(\||>|#{1,6}\s*$|```|<!--)")

RULE_HEADING = re.compile(r"^#{2,4}\s+([A-Z][A-Z0-9 ,'\-]{10,})\s*$")
BOLD_LEAD = re.compile(r"^\s*[-*]?\s*\*\*([^*]{10,120})\*\*")


def die(msg):
    print("scan: %s" % msg, file=sys.stderr)
    sys.exit(2)


def note(msg):
    """Supplementary output. Always stderr, so --json stdout stays one parseable
    object even when the run ends over budget."""
    print("  " + msg, file=sys.stderr)


def artifacts_for(skills, skill, registry_targets):
    """Enforcement ARTIFACTS present in this skill.

    Deliberately not called "enforcement": finding a file named guard_test.sh
    says something exists, never that it guards the rule in front of you. It
    annotates a finding; it does not remove one.
    """
    d = os.path.join(skills, skill)
    found = []
    if skill in registry_targets:
        found.append("registry")
    # Walked, not listed, and to the same depth check-rules.sh runs them, or a
    # guard at <skill>/tests/unit/guard_test.py reads as no guard at all.
    for root, dirs, names in os.walk(d, onerror=walk_failed):
        dirs[:] = [x for x in dirs if x not in (".git", "node_modules")]
        for n in names:
            full = os.path.join(root, n)
            if not os.path.isfile(full):
                continue
            rel = os.path.relpath(full, d)
            if n.startswith(("guard_test.", "tripwire_test.")):
                found.append("guard test (%s)" % rel)
            elif n == "skill_contract.yaml":
                found.append("contract")
            elif (root == d and n.endswith(".sh")
                  and re.match(r"(check|gate|verify|guard|validate)", n)):
                found.append("checker (%s)" % n)
    return found


def walk_failed(err):
    die("cannot read %s (%s) - a scan that skipped part of the tree cannot "
        "report a clean result" % (getattr(err, "filename", "?"), err))


def read_registry(path, skills):
    """Targets named in a rules.tsv, the markers each TARGET FILE carries, and
    the targets that resolve to nothing.

    Parsing is registry.py's job and only registry.py's. This used to re-split
    the file itself, and the two parsers disagreed about whether a row with a
    leading space was guarded - the vendored-copy defect, inside the tool built
    to name it.
    """
    targets, by_file, missing = set(), {}, []
    if not path or not os.path.isfile(path):
        return targets, by_file, missing
    # strict, like every other caller. A scanner that tolerated a row the
    # checker refuses would report a different world than the gate enforces.
    rows, _waivers = registry.parse(path)
    for target, marker, _why, _lineno in rows:
        if not registry.usable_target(target):
            continue
        targets.add(target.split("/")[0])
        f = registry.target_file(skills, target)
        if not os.path.isfile(f):
            # Not silently dropped. check-rules.sh FIRES on a target it cannot
            # open, so a registry row pointing at nothing is a real problem, and
            # a scanner that ignored it would be hiding one.
            missing.append(target)
            continue
        by_file.setdefault(os.path.abspath(f), []).append(marker)
    return targets, by_file, missing


def candidate_lines(path):
    """Yield (lineno, text) for lines that could be stating a rule."""
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError as e:
        # Never swallowed. A file this could not open is a hole in the scan,
        # and a hole reported as "no findings" is the exact failure this whole
        # skill exists to stop.
        die("cannot read %s (%s) - the scan would be partial" % (path, e))
    in_fence = False
    for i, raw in enumerate(lines, 1):
        if raw.lstrip().startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        s = raw.strip()
        if len(s) < 20 or len(s) > 400 or NOISE.match(raw):
            continue
        yield i, s


def rule_text(s):
    """The part of the line that reads as the rule, for display."""
    m = RULE_HEADING.match(s) or BOLD_LEAD.match(s)
    if m:
        return m.group(1).strip()
    return s


def scan(skills, registry_path, only_skill=None):
    registry_targets, registry_by_file, registry_missing = read_registry(
        registry_path, skills)
    findings, counts = [], {"A": 0, "B": 0, "C": 0, "guarded": 0}
    files_read = lines_read = 0
    # os.path.isdir() returns False when stat FAILS, so a skill behind a broken
    # or unreadable symlink used to disappear from the scan entirely and the run
    # still reported clean. A directory entry that cannot be resolved is a hole.
    try:
        entries = sorted(os.listdir(skills))
    except OSError as e:
        die("cannot list %s (%s)" % (skills, e))
    skill_names = []
    for d in entries:
        if d.startswith("."):
            continue
        full = os.path.join(skills, d)
        # os.path.isdir() and os.path.islink() catch OSError INSIDE themselves
        # and answer False, so an entry whose metadata cannot be read looks
        # exactly like an ordinary file and drops out of the scan. One explicit
        # stat, inside the try, is the only way the failure reaches this code.
        try:
            st = os.stat(full)
        except OSError as e:
            die("cannot inspect %s (%s) - a skill this scan could not open "
                "would silently drop out of the result" % (full, e))
        if statmod.S_ISDIR(st.st_mode):
            skill_names.append(d)
    coverage = []

    # This skill reviews the user's stack, not itself. Installed inside the tree
    # it scans - the normal install - its own SKILL.md is full of worked example
    # incidents, and a stranger's very first review listed two of them as
    # unguarded rules in THEIR stack. Skipped by identity, so a symlinked install
    # is recognised too; an explicit --skill tripwire still reviews it.
    # File identity, not path strings: realpath keeps capitalisation, so on a
    # case-insensitive filesystem --skills SKILLS and --skills skills named the
    # same tree and gave 33 findings against 31.
    own = HERE

    for skill in skill_names:
        if only_skill and skill != only_skill:
            continue
        if not only_skill:
            try:
                if os.path.samefile(os.path.join(skills, skill), own):
                    continue
            except OSError as e:
                die("cannot compare %s with this skill's own directory (%s)" % (skill, e))
        artifacts = artifacts_for(skills, skill, registry_targets)
        d = os.path.join(skills, skill)
        md = []
        for root, dirs, names in os.walk(d, onerror=walk_failed):
            dirs[:] = [x for x in dirs if x not in (".git", "node_modules")]
            for n in names:
                if not n.endswith(".md"):
                    continue
                full = os.path.join(root, n)
                if CORPUS_PATH.search(os.path.relpath(full, skills)):
                    continue
                md.append(full)
        rules_here = 0
        for path in sorted(md):
            file_markers = registry_by_file.get(os.path.abspath(path), [])
            saw_a_line = False
            for lineno, s in candidate_lines(path):
                saw_a_line = True
                lines_read += 1
                if not OBLIGATION.search(s):
                    continue
                rules_here += 1
                text = rule_text(s)
                # Named in the registry FOR THIS FILE? Then it is guarded.
                if any(mk in s for mk in file_markers):
                    counts["guarded"] += 1
                    continue
                inc = bool(INCIDENT.search(s))
                mech = bool(MECHANICAL.search(s))
                # A line whose only evidence is a date, with almost no prose
                # around it, is a log entry rather than a rule.
                if inc and len(re.sub(r"[^A-Za-z ]", "", s).strip()) < 35:
                    inc = False
                if inc:
                    tier = "A"
                elif mech:
                    tier = "B"
                else:
                    tier = "C"
                counts[tier] += 1
                if tier in ("A", "B"):
                    findings.append({
                        "tier": tier, "skill": skill,
                        "file": os.path.relpath(path, skills),
                        "line": lineno, "rule": text, "full": s,
                        "artifacts": artifacts,
                        "cites_incident": inc, "mechanical": mech,
                    })
            # Counted after the file was successfully opened and read, so an
            # unreadable file can never inflate "files inspected".
            files_read += 1
            if not saw_a_line:
                pass
        coverage.append({"skill": skill, "rules": rules_here,
                         "artifacts": artifacts})

    if files_read == 0:
        die("no .md files under %s - a scan that read nothing is not a result" % skills)
    return findings, counts, coverage, files_read, lines_read, registry_missing


def next_action(f):
    if f["tier"] == "A":
        return ("this rule records what it cost and nothing executes it. Write the "
                "guard, break the code to watch it fire, then add it to rules.tsv "
                "as:  %s|<a literal string from the rule>|<the incident>" % f["skill"])
    return ("checkable, but no incident is recorded here. Find the time this was "
            "actually broken before building anything - a guard with no incident "
            "behind it gets deleted by whoever finds it annoying, and they are right.")


def main(argv=None):
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--skills")
    ap.add_argument("--rules")
    ap.add_argument("--skill", help="scan only this one skill")
    ap.add_argument("--tier", choices=["A", "B"], default="A",
                    help="lowest tier to list (default A, the bullseyes)")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--max", type=int, metavar="N",
                    help="fail if more than N unguarded rules are listed")
    ap.add_argument("--baseline", metavar="FILE",
                    help="a recorded count to ratchet down from; fail if the "
                         "number grows, and fail if the file is missing")
    ap.add_argument("--record-baseline", metavar="FILE",
                    help="write the current count to FILE and exit. Separate "
                         "from --baseline on purpose: a gate that creates its "
                         "own passing baseline when the file is missing accepts "
                         "whatever it finds the day somebody deletes it")
    args = ap.parse_args(argv)

    # An empty --skills is a value someone GAVE, usually an unset shell
    # variable. Falling through to a default scans a tree nobody asked for and
    # reports a confident verdict about it. Found by fault injection: `--skills
    # ""` scanned 102 skills and exited 0 while `check` correctly refused.
    if args.skills is not None and not args.skills.strip():
        die("--skills was given an empty value. That is usually an unset shell "
            "variable; refusing rather than scanning a tree nobody named.")
    skills = args.skills or os.environ.get("CLAUDE_SKILLS_DIR") \
        or os.path.dirname(HERE)
    if not os.path.isdir(skills):
        die("skills directory not found: %s" % skills)
    skills = os.path.abspath(skills)

    registry = args.rules
    if registry is None:
        # From the tree being scanned, never from wherever this is installed.
        for c in (os.environ.get("CLAUDE_HOOKS_RULES"),
                  os.path.join(skills, "tripwire", "rules.tsv"),
                  os.path.join(skills, "rules.tsv")):
            if c and os.path.isfile(c):
                registry = c
                break
    elif not os.path.isfile(registry):
        die("--rules file not found: %s" % registry)

    findings, counts, coverage, files_read, lines_read, registry_missing = scan(
        skills, registry, args.skill)

    listed = [f for f in findings
              if f["tier"] == "A" or (args.tier == "B" and f["tier"] == "B")]

    # One rule carried by several skills is ONE candidate. A shared rule synced
    # into five skills was reported five times, which reads as five problems and
    # is one.
    # Identity is the WHOLE obligation line, whitespace-normalised and nothing
    # else. Lower-casing, stripping punctuation and truncating to 90 characters
    # merged two different rules that happened to share a bold label, and the
    # second one vanished from the count a budget is checked against.
    merged, seen = [], {}
    for f in listed:
        # The exact line. Collapsing internal whitespace merged two rules
        # naming `client data.csv` and `client  data.csv`, which are different
        # files, and the second disappeared from the count a budget checks.
        key = f.get("full", f["rule"]).strip()
        if key in seen:
            first = seen[key]
            first["also_in"].append("%s:%d" % (f["file"], f["line"]))
            # keep the strongest evidence, never the first seen
            if f["tier"] < first["tier"]:
                first["tier"] = f["tier"]
                first["cites_incident"] = f["cites_incident"]
            continue
        f["also_in"] = []
        seen[key] = f
        merged.append(f)
    listed = merged
    listed.sort(key=lambda f: (f["tier"], bool(f["artifacts"]), f["skill"], f["line"]))

    if args.json:
        print(json.dumps({"inspected": {"skills": len(coverage),
                                        "files": files_read,
                                        "candidate_lines": lines_read},
                          "counts": counts,
                          "registry_targets_missing": registry_missing,
                          "findings": listed,
                          "coverage": coverage}, indent=2))
    else:
        print("scan: which rules are still only prose?")
        print("  skills tree: %s" % skills)
        print("  registry:    %s" % (registry or "<none>"))
        # Saying what was inspected, because a checker with a hardcoded path
        # passes happily on files nobody edited.
        print("  inspected:   %d skills, %d markdown files, %d candidate lines"
              % (len(coverage), files_read, lines_read))
        print()
        if registry_missing:
            print("  REGISTRY POINTS AT NOTHING: %d target(s) named in %s do not"
                  % (len(registry_missing), os.path.basename(registry or "")))
            print("  exist, so those rows guard nothing and check-rules.sh will"
                  " fire on them:")
            for t in registry_missing[:6]:
                print("    %s" % t)
            print()
        print("  obligations found:        %d" % (counts["A"] + counts["B"]
                                                  + counts["C"] + counts["guarded"]))
        print("    already named in the registry: %d" % counts["guarded"])
        print("    tier A - cites an incident, unguarded: %d" % counts["A"])
        print("    tier B - checkable, no incident:       %d" % counts["B"])
        print("    tier C - neither, not proposed:        %d" % counts["C"])
        print()
        if not listed:
            print("  nothing at tier %s. That is a real result, not an empty scan:"
                  % args.tier)
            print("  %d obligations were read and every one is either guarded or"
                  % (counts["A"] + counts["B"] + counts["C"] + counts["guarded"]))
            print("  below the bar for proposing a guard.")
        for f in listed:
            print("  [%s] %s:%d" % (f["tier"], f["file"], f["line"]))
            print("      %s" % f["rule"][:150])
            print("      enforcement artifacts in this skill: %s"
                  % (", ".join(f["artifacts"]) if f["artifacts"]
                     else "NONE"))
            if f.get("also_in"):
                print("      same rule also in: %s" % ", ".join(f["also_in"][:4]))
            print("      -> %s" % next_action(f))
            print()

        naked = [c for c in coverage if c["rules"] and not c["artifacts"]]
        if naked:
            print("  skills stating rules with no enforcement of any kind (%d):"
                  % len(naked))
            for c in sorted(naked, key=lambda c: -c["rules"])[:10]:
                print("    %-30s %d obligations, no enforcement artifact"
                      % (c["skill"], c["rules"]))
            if len(naked) > 10:
                print("    ... and %d more (--json for all)" % (len(naked) - 10))
            print()

    # A budget, declared and checked. Without one this is a report nobody acts
    # on; with a permanent red it is a check nobody believes.
    if args.record_baseline and (args.max is not None or args.baseline):
        die("--record-baseline writes a new number; it cannot be combined with "
            "--max or --baseline, which check against one. Record first, then "
            "check in a separate run.")
    if args.record_baseline:
        try:
            with open(args.record_baseline, "w") as fh:
                fh.write("%d\n" % len(listed))
        except OSError as e:
            die("cannot write baseline %s (%s)" % (args.record_baseline, e))
        note("baseline recorded in %s: %d. It may shrink, never grow."
             % (args.record_baseline, len(listed)))
        return 0

    # Both limits are checked when both are given. Letting one silently replace
    # the other means the stricter number you asked for is not the one enforced.
    budgets = []
    if args.max is not None:
        budgets.append(("--max", args.max))
    if args.baseline:
        if not os.path.isfile(args.baseline):
            die("baseline %s does not exist. Record it first:\n"
                "  python3 %s --skills %s --record-baseline %s"
                % (args.baseline, os.path.basename(__file__), skills, args.baseline))
        try:
            with open(args.baseline, encoding="utf-8") as fh:
                raw = fh.read().strip()
        except (OSError, UnicodeError) as e:
            die("cannot read baseline %s (%s)" % (args.baseline, e))
        try:
            n = int(raw)
        except ValueError:
            die("baseline %s does not contain a number (found %r)"
                % (args.baseline, raw[:40]))
        if n < 0:
            die("baseline %s is negative (%d)" % (args.baseline, n))
        budgets.append((args.baseline, n))

    over = [(name, b) for name, b in budgets if len(listed) > b]
    if over:
        for name, b in over:
            note("OVER BUDGET: %d unguarded rules at tier %s, %s allows %d."
                 % (len(listed), args.tier, name, b))
        note("FIX: guard one and lower the number, or raise it deliberately "
             "and say why.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
