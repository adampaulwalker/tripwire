#!/usr/bin/env python3
"""registry.py - the ONE parser for rules.tsv.

There were two: one in check-rules.sh and one in scan.py. They disagreed almost
immediately - the shell read a row literally while the Python stripped it, so a
row written " alpha|..." was guarded according to one and unguarded according to
the other. That is the vendored-copy problem this skill exists to name, found
inside the skill itself.

So there is one implementation and both callers use it. The shell reads it over
NUL-delimited records rather than re-splitting the file.

Format, one rule per line:

    target|MARKER TEXT THAT MUST BE PRESENT|the dated incident and what it cost

  target  a skill name, whose SKILL.md is checked - or an exact path inside a
          skill, for a rule that must live where the skill actually loads it
  MARKER  a literal substring; leading dashes are fine, it is never an option
  why     the incident. Printed when the check fires, and a row without one is
          refused: a check whose reason is forgotten is a check that gets removed

Two declarations turn a phase with nothing to do into a recorded skip:

    proofs: none - <reason>
    shared-rules: none - <reason>

Usage:
  registry.py rows FILE [--skills DIR]   NUL-delimited: target, marker, why, path
  registry.py waivers FILE               NUL-delimited: kind, reason
  registry.py validate FILE              exit 0 clean, 2 with a reason on stderr

Exit codes: 0 ok, 2 the file is unusable or a row is malformed.
"""
import os
import re
import sys

WAIVERS = ("proofs:", "shared-rules:")

# The ONE form a waiver may take. Accepting anything looser has gone wrong
# twice: "proofs: required" was read as a waiver whose reason was the word
# "required", and then "proofs: none required" slipped through a prefix test
# with the separator missing. A waiver turns a missing check into a pass, so
# its syntax is exact.
WAIVER_RE = re.compile(r"^[ \t]*(proofs|shared-rules)[ \t]*:[ \t]*none[ \t]*-[ \t]*(\S.*?)[ \t]*$")

# What merely LOOKS like a waiver. Tested after WAIVER_RE, so a line this
# matches and that does not is refused by name rather than falling through to
# be reported as a malformed rule row, which named the wrong problem.
WAIVER_PREFIX = re.compile(r"^[ \t]*(proofs|shared-rules)[ \t]*:")


def die(msg):
    print("registry: %s" % msg, file=sys.stderr)
    sys.exit(2)


def read_lines(path):
    """Open, read and close inside one handler. An error raised while ITERATING
    used to escape as a traceback and exit 1, which is the code for a failed
    check, not for being unable to run."""
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return list(enumerate(fh, 1))
    except (OSError, UnicodeError) as e:
        die("cannot read %s (%s)" % (path, e))


def reject_nul(path, lineno, line):
    """NUL is the field separator on the wire to the shell. A registry carrying
    one could forge a complete record: `a|M|incident<NUL>/some/other/file<NUL>`
    arrived at check-rules.sh as a row pointing anywhere on disk. It is refused
    before anything interprets it, in every mode."""
    if "\0" in line:
        die("%s line %d: contains a NUL byte. Records are NUL-delimited on the "
            "way to the shell, so a NUL in the file could forge a row pointing "
            "at any file on disk." % (path, lineno))


def check_framing(path, width):
    """The producer's output must be COMPLETE, not merely a multiple.

    Counting NUL separators modulo the record width says nothing about a
    complete record followed by an unterminated tail: the separator count still
    divides, and the shell read loop drops the tail in silence. So the bytes
    must also END on a separator.
    """
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError as e:
        die("cannot read the produced records at %s (%s)" % (path, e))
    if not data:
        return 0
    if not data.endswith(b"\0"):
        die("the registry parser's output ends mid-record. Its last field was "
            "never terminated, so a rule would be dropped in silence.")
    n = data.count(b"\0")
    if n % width:
        die("the registry parser produced an incomplete record (%d fields, "
            "expected a multiple of %d). Its output was truncated, so any "
            "verdict drawn from it would be partial." % (n, width))
    return n // width


def parse(path, strict=True):
    """Return (rows, waivers).

    A row is (target, marker, why, lineno). Fields are taken LITERALLY: only the
    line terminator is removed. Stripping whitespace changed the target before it
    was used, and then this parser and its callers disagreed about what file a
    rule even lived in.
    """
    rows, waivers = [], {}
    for lineno, line in read_lines(path):
        reject_nul(path, lineno, line)
        line = line.rstrip("\r\n")
        if not line or line.startswith("#"):
            continue
        m = WAIVER_RE.match(line)
        if m:
            waivers[m.group(1)] = m.group(2)
            continue
        pre = WAIVER_PREFIX.match(line)
        if pre:
            kind = pre.group(1)
            die("%s line %d: '%s:' is only ever a waiver, written exactly as "
                "'%s: none - <reason>' with the hyphen and a reason. Found %r."
                % (path, lineno, kind, kind, line.strip()[:50]))

        parts = line.split("|")
        # Validated before it counts as anything. An empty marker makes a
        # substring search match every line, which is a confident-looking way to
        # have inspected nothing.
        if len(parts) < 3:
            if not strict:
                continue
            die("%s line %d: need target|MARKER|incident, found %d field(s)"
                % (path, lineno, len(parts)))
        target, marker, why = parts[0], parts[1], "|".join(parts[2:])
        # Applied HERE so every consumer gets the same answer. It lived in
        # scan.py alone, so check-rules.sh would happily PASS against an
        # absolute path outside the tree it was pointed at.
        if not usable_target(target):
            die("%s line %d: target %r is not usable. An absolute path escapes "
                "the skills tree entirely, and a '..' segment resolves onto a "
                "file the registry never named." % (path, lineno, target[:60]))
        for name, val in (("target", target), ("marker", marker), ("incident", why)):
            if not val.strip():
                if not strict:
                    break
                die("%s line %d: empty %s field%s"
                    % (path, lineno, name,
                       " - an empty pattern matches every line, which is a pass "
                       "that inspected nothing" if name == "marker" else
                       ". A check whose reason is forgotten is a check that gets "
                       "removed." if name == "incident" else ""))
        else:
            rows.append((target, marker, why, lineno))
    return rows, waivers


def target_file(skills, target):
    """Where a target resolves. A target containing "/" names an exact file
    inside the skill, because a rule sometimes has to live where the skill
    actually loads it; checking only SKILL.md would pass on a file nobody
    edited."""
    if "/" in target:
        return os.path.join(skills, target)
    return os.path.join(skills, target, "SKILL.md")


def usable_target(target):
    """A target the checker itself could not open is not evidence of anything.
    An absolute path is already broken for the shell caller, which prepends the
    tree; a ".." segment normalises onto a file the registry never named."""
    return not target.startswith("/") and ".." not in target.split("/")


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    cmd, path = argv[0], argv[1]
    skills = ""
    if "--skills" in argv:
        skills = argv[argv.index("--skills") + 1]

    if cmd == "validate":
        parse(path)
        return 0
    if cmd == "frame":
        # path here is the PRODUCED file, not the registry.
        if len(argv) < 3:
            die("frame needs a file and a record width")
        try:
            width = int(argv[2])
        except ValueError:
            die("frame width must be a number")
        if width < 1:
            die("frame width must be positive")
        check_framing(path, width)
        return 0
    if cmd == "waivers":
        _, waivers = parse(path)
        for kind, reason in waivers.items():
            sys.stdout.write(kind + "\0" + reason + "\0")
        return 0
    if cmd == "rows":
        rows, _ = parse(path)
        for target, marker, why, _ln in rows:
            f = target_file(skills, target) if skills else ""
            sys.stdout.write("\0".join([target, marker, why, f]) + "\0")
        return 0
    die("unknown command: %s" % cmd)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
