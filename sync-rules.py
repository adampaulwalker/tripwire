#!/usr/bin/env python3
"""Push canonical shared rules from SHARED-RULES.md into every consumer file.

A rule that must be loaded with more than one skill has to be COPIED into each,
because skills load independently and a cross-reference is not in context at
the moment the rule matters. Copies drift. This is the sync half; --check is
the gate half, and refuses when any copy differs by a byte.

Usage:
  python3 sync-rules.py [--check] [--canon FILE] [--skills DIR]

  --check   verify only; exit 1 on drift, a missing copy, or a dead gate
  --skills  the tree the consumers live in. Resolved FIRST: --skills, else
            $CLAUDE_SKILLS_DIR, else the parent of this script's directory,
            else ~/.claude/skills
  --canon   the canonical rules file: --canon, else $CLAUDE_HOOKS_CANON, else
            <skills>/tripwire/SHARED-RULES.md, else <skills>/SHARED-RULES.md.
            Never the file beside this script when --skills points elsewhere.

Exit codes:
  0  clean
  1  drift, a missing copy, or a structural problem
  2  nothing is configured (no canonical file anywhere)
  3  something WAS configured and is wrong (a path that does not exist, bad
     arguments). Distinct from 2 so a caller cannot waive a typo as absence.

Canonical file format - each rule wrapped in markers naming who must carry it:

    <!-- RULE:my-rule-id consumers: skill-a skill-b -->
    ## THE RULE, IN FULL
    ...body...
    <!-- /RULE:my-rule-id -->

Markers are parsed STRUCTURALLY, by walking every one in the file and pairing
them. A regex that merely finds a complete block cannot see an unmatched opener
sitting in front of it, and replacing a block located that way silently deletes
everything in between.

Everything is validated and planned BEFORE anything is written. A run that would
fail halfway writes nothing at all, because a half-synced tree is worse than an
unsynced one: it looks done.
"""
import argparse
import os
import re
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))

VALID_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]*$")

# One marker line: an opening or closing RULE marker occupying its own line.
# Anchored to line starts so a closing marker can never be mid-paragraph, which
# is what keeps a captured body byte-exact without fabricating a newline.
# Marker lines are PARSED, not pattern-matched.
#
# Three rounds of review killed three different regexes here, each one able to
# reach past the first "-->" and silently delete what lay between two comments.
# A tempered pattern fixed the body and left the id group free to do it; fixing
# the id left a nested "<!--" able to smuggle a second declaration onto an
# accepted line. The shape of the bug never changed: one regex deciding where a
# comment ends.
#
# So the rule is stated directly instead. A marker line, stripped, must open
# with "<!--", close with "-->", and contain NEITHER sequence in between. One
# comment, alone on its line, or it is not a marker.
MARKER_HINT = re.compile(r"<!--[ \t]*/?RULE:")


def parse_marker(line):
    """Return (close, id, rest) for a marker line, or None if it is not one.

    Raises ValueError with a reason when the line is trying to be a marker and
    failing, so a malformed declaration is reported rather than ignored.
    """
    # Only lines TRYING to be a rule declaration are held to the marker rules.
    # Checking comment shape first made an ordinary line of two unrelated HTML
    # comments fail the whole run, which is a compatibility break, not a guard.
    if MARKER_HINT.search(line) is None:
        return None
    t = line.strip()
    if not t.startswith("<!--") or not t.endswith("-->"):
        raise ValueError("a marker must be one complete HTML comment alone on "
                         "its line: <!-- RULE:id consumers: a b --> or "
                         "<!-- /RULE:id -->")
    inner = t[4:-3]
    if "<!--" in inner or "-->" in inner:
        raise ValueError("a marker line may hold only ONE comment; this line "
                         "contains another '<!--' or '-->' inside it")
    inner = inner.strip()
    close = inner.startswith("/")
    if close:
        inner = inner[1:]
    if not inner.startswith("RULE:"):
        raise ValueError("a marker must read RULE:id or /RULE:id immediately "
                         "after the comment opener")
    inner = inner[len("RULE:"):]
    parts = inner.split(None, 1)
    rid = parts[0] if parts else ""
    rest = parts[1] if len(parts) > 1 else ""
    if not VALID_ID.match(rid):
        raise ValueError("%r is not a usable rule id (letters and digits, then "
                         "- and _)" % rid)
    if close and rest:
        raise ValueError("a closing marker carries nothing after the id, found %r" % rest)
    return close, rid, rest

# The installed marker carries NO filename. A canonical file whose name contains
# a bracket used to generate a marker this script's own pattern could not match,
# so the next run duplicated the block instead of updating it.
INSTALLED_NOTE = "(synced - edit the canonical file, not here)"


def read_text(path):
    # newline="" keeps CRLF as CRLF. Without it Python normalises line endings
    # on read and a byte-exact comparison silently is not one.
    with open(path, encoding="utf-8", newline="") as fh:
        return fh.read()


def write_atomic(path, text):
    # A plain open(path, "w") truncates the original before the replacement is
    # safely on disk. An interruption there leaves a consumer holding a few
    # bytes of a marker and nothing else.
    d = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".sync-rules.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
        try:
            os.chmod(tmp, os.stat(path).st_mode & 0o7777)
        except OSError:
            pass
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def scan_blocks(text, where):
    """Walk EVERY marker in `text` and pair them.

    Returns (blocks, problems). A block is a dict with id, start, body_start,
    body_end, end, rest. Every marker must pair; nesting, duplication and
    orphans are all reported rather than skipped, because each of them makes a
    later replacement delete the wrong bytes.
    """
    blocks, problems, stack, seen = [], [], [], {}

    # Offsets are tracked by hand so a block's bytes can be sliced exactly.
    pos, lineno = 0, 0
    while pos <= len(text):
        nl = text.find("\n", pos)
        eol = len(text) if nl == -1 else nl
        line = text[pos:eol]
        lineno += 1
        line_start, next_pos = pos, (len(text) + 1 if nl == -1 else nl + 1)
        pos = next_pos
        try:
            parsed = parse_marker(line)
        except ValueError as e:
            problems.append("%s line %d: %s" % (where, lineno, e))
            continue
        if parsed is None:
            continue
        close, rid, rest = parsed
        # marker end = end of this line, excluding its newline
        m_start, m_end = line_start + (len(line) - len(line.lstrip())), line_start + len(line.rstrip())
        if close:
            if not stack or stack[-1][0] != rid:
                problems.append("%s line %d: closing marker for %r has no "
                                "matching opening marker" % (where, lineno, rid))
                continue
            oid, ostart, obody, oline, orest = stack.pop()
            if rid in seen:
                problems.append("%s line %d: %r is declared %d times. One block "
                                "per id, or a later one silently wins and the "
                                "earlier readers drift."
                                % (where, lineno, rid, seen[rid] + 1))
            seen[rid] = seen.get(rid, 0) + 1
            blocks.append({"id": rid, "start": ostart, "body_start": obody,
                           "body_end": m_start, "end": m_end,
                           "rest": orest, "line": oline})
        else:
            if stack:
                problems.append("%s line %d: %r opens inside %r - blocks cannot "
                                "nest" % (where, lineno, rid, stack[-1][0]))
                continue
            stack.append((rid, m_start, next_pos, lineno, rest))
    for rid, _s, _b, line, _r in stack:
        problems.append("%s line %d: %r is opened and never closed" % (where, line, rid))
    return blocks, problems


def resolve(explicit, env_name, fallbacks, kind, isdir):
    """A path someone GAVE us is authoritative, by flag or by environment. A
    typo in either must fail, never fall through to some other tree and report a
    confident verdict about it. Only the built-in fallbacks may miss and move on.
    Returns (path, error, configured) - `configured` says whether anyone named
    one, so a caller can tell a typo from an absence."""
    ok = os.path.isdir if isdir else os.path.isfile
    if explicit is not None:
        if not ok(explicit):
            return None, "%s not found: %s" % (kind, explicit), True
        return os.path.abspath(explicit), None, True
    from_env = os.environ.get(env_name)
    if from_env:
        if not ok(from_env):
            return None, "%s not found: %s (from %s)" % (kind, from_env, env_name), True
        return os.path.abspath(from_env), None, True
    for cand in fallbacks:
        if cand and ok(cand):
            return os.path.abspath(cand), None, False
    return None, None, False


def parse_canon(canon):
    """Return (rules, problems). Nothing is written until problems is empty."""
    text = read_text(canon)
    name = os.path.basename(canon)
    blocks, problems = scan_blocks(text, name)

    rules = []
    for b in blocks:
        rid = b["id"]
        rest = b["rest"]
        if "consumers:" not in rest:
            problems.append("%s line %d: %r declares no 'consumers:' clause"
                            % (name, b["line"], rid))
            continue
        consumers = rest.split("consumers:", 1)[1].split()
        body = text[b["body_start"]:b["body_end"]]
        if not consumers:
            problems.append("%s line %d: %r names no consumers - canonical text "
                            "nothing carries" % (name, b["line"], rid))
            continue
        if not body.strip():
            problems.append("%s line %d: %r has an empty body" % (name, b["line"], rid))
            continue
        rules.append((rid, consumers, body))
    return rules, problems


def same_file(a, b):
    """Identity, not string equality. macOS is case-insensitive by default, so
    ./CANON.md and ./canon.md are ONE file whose realpaths differ as strings -
    and a consumer named that way walked straight past the self-check and
    overwrote the canonical declaration."""
    try:
        return os.path.samefile(a, b)
    except OSError:
        return os.path.abspath(a) == os.path.abspath(b)


def file_key(path):
    """A stable identity for the planned-edits map, so two spellings of one file
    share a single evolving text instead of overwriting each other."""
    try:
        st = os.stat(path)
        return (st.st_dev, st.st_ino)
    except OSError:
        return os.path.abspath(path)


def consumer_path(skills, name, canon):
    """Resolve a consumer, refusing anything outside the skills tree, and
    refusing the canonical file itself - syncing the canon into the canon
    rewrites its own 'consumers:' clause away."""
    raw = os.path.join(skills, name) if "/" in name else os.path.join(skills, name, "SKILL.md")
    real = os.path.realpath(raw)
    root = os.path.realpath(skills)
    if os.path.commonpath([real, root]) != root:
        return None, ("%s resolves to %s, outside the skills tree %s. A consumer "
                      "name must not escape it." % (name, real, root))
    if os.path.exists(real) and same_file(real, canon):
        return None, ("%s resolves to the canonical file itself. Syncing the canon "
                      "into the canon destroys the declaration it is read from."
                      % name)
    # Writes are atomic via os.replace, which swaps ONE directory entry and
    # breaks the link. A second name for the same inode would silently keep the
    # old bytes while this run reported success.
    try:
        if os.path.exists(real) and os.stat(real).st_nlink > 1:
            return None, ("%s is a hard link with %d names. An atomic replace "
                          "updates one of them and breaks the link, so the others "
                          "would keep the old text while this run reported success. "
                          "Break the link (cp then mv) before syncing."
                          % (name, os.stat(real).st_nlink))
    except OSError:
        pass
    return real, None


def main(argv=None):
    ap = argparse.ArgumentParser(
        add_help=True, description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--canon")
    ap.add_argument("--skills")
    args = ap.parse_args(argv)

    # The skills tree is resolved FIRST, and the canon is looked for inside it.
    #
    # The canonical text belongs to the tree being checked, never to wherever
    # this script is installed. Falling back to the script's own directory
    # applied ONE installation's shared rules to every other tree: a fresh stack
    # always reported a skill it never had as missing, and no waiver could clear
    # it. Found by a model given only this skill and an unfamiliar stack.
    #
    # The first version of that fix derived the canon from --skills and the
    # environment only, before the tree was resolved, so the ordinary no-flags
    # `tripwire sync` stopped finding the installation's own canon. Resolving the
    # tree first keeps both: no flags finds the canon of the tree the skill sits
    # in, and --skills pointed elsewhere never borrows it.
    skills, err, _ = resolve(
        args.skills, "CLAUDE_SKILLS_DIR",
        [os.path.dirname(HERE), os.path.expanduser("~/.claude/skills")],
        "--skills directory", True)
    if err:
        print(err)
        return 3
    if not skills:
        print("no skills directory found.")
        print("FIX: pass --skills DIR, or set CLAUDE_SKILLS_DIR.")
        return 2

    canon, err, configured = resolve(
        args.canon, "CLAUDE_HOOKS_CANON",
        [os.path.join(skills, "tripwire", "SHARED-RULES.md"),
         os.path.join(skills, "SHARED-RULES.md")],
        "--canon file", False)
    if err:
        print(err)
        return 3
    if not canon:
        print("no canonical rules file found in %s." % skills)
        print("FIX: create %s, or pass --canon FILE."
              % os.path.join(skills, "tripwire", "SHARED-RULES.md"))
        return 2

    rules, problems = parse_canon(canon)

    # ---- plan everything, write nothing ---------------------------------
    # `planned` holds one EVOLVING text per consumer path. Building each rule's
    # replacement from the original file and keeping only the last would drop
    # every earlier rule's edit while still exiting 0.
    # Keyed by filesystem identity, so two spellings of one path evolve one text.
    planned, paths, touched, verified = {}, {}, set(), 0

    def load(path, label):
        k = file_key(path)
        paths.setdefault(k, path)
        if k not in planned:
            planned[k] = read_text(path)
        text = planned[k]
        blocks, probs = scan_blocks(text, label)
        return k, text, blocks, probs

    for rid, consumers, body in rules:
        begin = "<!-- RULE:%s %s -->" % (rid, INSTALLED_NOTE)
        end = "<!-- /RULE:%s -->" % rid
        block = begin + "\n" + body + end

        for name in consumers:
            path, err = consumer_path(skills, name, canon)
            if err:
                problems.append(err)
                continue
            if not os.path.exists(path):
                problems.append("%s: %s missing" % (name, os.path.basename(path)))
                continue

            key, cur, blocks, probs = load(path, name)
            if probs:
                # Structural damage anywhere in the file makes every offset in
                # it untrustworthy. Refuse rather than cut.
                problems.extend(probs)
                continue

            mine = [b for b in blocks if b["id"] == rid]
            if len(mine) > 1:
                problems.append("%s: %r is installed %d times. Delete the extra "
                                "block(s); a duplicate can contradict the canonical "
                                "text while --check reads only one."
                                % (name, rid, len(mine)))
                continue

            if mine:
                b = mine[0]
                if cur[b["start"]:b["end"]] == block:
                    verified += 1
                    continue
                if args.check:
                    problems.append("%s: %r has DRIFTED from canonical" % (name, rid))
                    continue
                planned[key] = cur[:b["start"]] + block + cur[b["end"]:]
                touched.add(key)
                continue

            if args.check:
                problems.append("%s: %r is missing" % (name, rid))
                continue

            # Not installed. Append. The old behaviour located the body's first
            # line anywhere in the file and deleted everything to the next "## ",
            # which silently ate unrelated prose.
            head = body.splitlines()[0].strip() if body.strip() else ""
            if head and head in cur:
                problems.append(
                    "%s: %r is not installed, but the file already contains the line "
                    "%r. That is probably an unmarked copy of this rule. Delete it and "
                    "run sync again - this script will not guess which lines it owns."
                    % (name, rid, head))
                continue
            sep = "" if cur.endswith("\n\n") else ("\n" if cur.endswith("\n") else "\n\n")
            planned[key] = cur + sep + block + "\n"
            touched.add(key)

    if problems:
        print("PROBLEMS:")
        for p in dict.fromkeys(problems):
            print("  " + p)
        print("\nNothing was written.")
        print("FIX: python3 %s --canon %s --skills %s"
              % (os.path.abspath(__file__), canon, skills))
        return 1

    # A gate that inspected nothing is not a pass.
    if args.check and verified == 0:
        print("DEAD GATE: no RULE blocks parsed from %s - a check that "
              "inspects nothing is not a pass" % canon)
        return 1

    for k in sorted(touched, key=lambda k: paths[k]):
        write_atomic(paths[k], planned[k])

    n = verified if args.check else len(touched)
    print("shared rules %s: %d consumer cop%s (canon: %s)"
          % ("verified" if args.check else "synced", n,
             "y" if n == 1 else "ies", canon))
    return 0


if __name__ == "__main__":
    sys.exit(main())
