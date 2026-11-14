#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Zenlygram Tasks — the strings gate (wf15 FINAL SPEC §15.1, §15.4).

What it scans
  * every string literal inside each `var|func tasks_*` or `tab_tasks` declaration of the
    `SGTasksL10n*.swift` files. A declaration runs from its `var|func` line to the next `var|func`
    declaration at the same member level (or the closing brace of the type); comments are never
    scanned. The ~120 non-Tasks declarations of SGTasksL10n.swift (`settings_*`, `about_*`,
    `accounts_*`, `tips_*`, `update_*`, `iap_*`, …) belong to other screens and are not gated;
  * the three `Tasks.Cloud.LogoutNotice` values of `SGLocalizable.strings` (en, uz, ru);
  * rule (b) of §15.4 (WP-I0b): the 11 consent-flow summaries of owner item O6b in the same three
    tables, for the cloud words only (bulut, cloud, облак, облач) — their "shu qurilmada" /
    "on this device" say where the app keeps working, not a Tasks scope;
  * rule (a) of §15.4 (WP-I2b, F19): every string literal of every `*.swift` file under
    `Swiftgram/SGTasks/Sources` (comments excluded) that has a dot-separated `cloud` / `icloud`
    component — an SF Symbol name such as "icloud", "icloud.slash", "exclamationmark.icloud",
    "cloud.fill", "arrow.clockwise.icloud" — fails unless it is an identifier that is never shown or
    spoken: an accessibility identifier ("sgtasks.…") or a reverse-DNS name ("uz.zenlygram.…", a
    dispatch queue label). "tasks_cloud" and "zenlygram-tasks-cloud" have no such component and pass.

What fails
  * a banned word in any language (case-insensitive): bulut, cloud, облак, облач, on this device,
    shu qurilmada (covers "shu qurilmadagi/-dan"), qurilma arxivi, device archive,
    на этом устройстве, архив устройства;
  * in a uz value: an ASCII (') or curly (‘ ’) apostrophe between letters, U+02BC (ʼ) after o/g, or
    U+02BB (ʻ) anywhere but after o/g — the one orthography of §15.1 (oʻ gʻ Oʻ Gʻ with U+02BB, the
    tutuq belgisi — Masʼul, Maʼlumot, IDʼsi, baʼzi — with U+02BC);
  * a cloud SF Symbol name anywhere in the module's sources (rule a).
  Keys listed in an allow file (`--allow`, one key per line, `#` comments) are skipped; an absent
  file is an empty list. The default `no-cloud-word.allow` held the retired keys of §15.3 between
  WP-I0 and WP-I10 and was deleted with them, so nothing is skipped now. The symbol rule has no
  allow list.

Subcommands (run as `python3 -I check_strings.py …`; `check-strings.sh` does)
  gate [--sources PATH …] [--strings DIR] [--allow FILE]   the gate (default when no subcommand)
  fixture FILE                                             one Swift file alone, no allow file, no
                                                           .strings (the --self-test of the script):
                                                           the declaration rules and the symbol rule
  fix-apostrophes FILE …                                   the normaliser of §15.1: rewrites the uz
                                                           values of the gated declarations in place
                                                           (apostrophe after o/g → U+02BB, between
                                                           other letters → U+02BC); nothing else
  dump PATH …                                              the second check of §15.4: `ios-ui/run
                                                           <udid> dump Tasks` trees (`*tree.txt`
                                                           files, or directories holding them)
                                                           contain none of the banned words in what
                                                           a person sees or hears — the labels and
                                                           values; an `identifier: 'sgtasks.…'` (the
                                                           kept a11y ids of §15.2, never shown or
                                                           spoken) and a container's `<Module.Class:
                                                           0x…>` description are not scanned
Exit status: 0 clean, 1 at least one failure, 2 usage / unreadable input.
"""
import argparse
import io
import os
import re
import sys

BANNED_WORDS = (
    "bulut",
    "cloud",
    "облак",
    "облач",
    "on this device",
    "shu qurilmada",
    "qurilma arxivi",
    "device archive",
    "на этом устройстве",
    "архив устройства",
)

CLOUD_WORDS = ("bulut", "cloud", "облак", "облач")

LANGUAGES = ("en", "uz", "ru")
LOGOUT_NOTICE_KEY = "Tasks.Cloud.LogoutNotice"
# Rule (b) of §15.4 (WP-I0b): the SGStrings summaries around consent (owner item O6b, §19) name the
# category by what the user sees — "sinxronlangan vazifalar" / "synced tasks" — never the cloud.
# Reverting WP-I0b (counsel wants the v1 term) means reverting that one commit, this list included.
O6B_KEYS = (
    "LinkAccount.Intro",
    "LinkAccount.Intro.Free",
    "Consent.Wall.Summary",
    "Consent.Wall.ModeNote.Optional",
    "Consent.Declined.Text",
    "Consent.Declined.Logout.LastAccount",
    "DataConsent.Status.None",
    "DataConsent.Status.Declined",
    "DataConsent.Withdraw.Confirm.Text",
    "DataConsent.Withdraw.Optional",
    "AccountDelete.Deleted",
)
STRINGS_RELATIVE = "SGLocalizable.strings"

PLAIN_APOSTROPHES = ("'", "‘", "’")
TURNED_COMMA = "ʻ"  # oʻ gʻ
MODIFIER_APOSTROPHE = "ʼ"  # tutuq belgisi
O_G = "oOgG"

# Rule (a) of §15.4 (WP-I2b, F19): a dot-separated `cloud` / `icloud` component names an SF Symbol.
CLOUD_SYMBOL = re.compile(r"(^|\.)i?cloud(\.|$)")
# Identifiers that are never shown or spoken: accessibility ids and reverse-DNS names (queue labels).
CLOUD_SYMBOL_EXEMPT_PREFIXES = ("sgtasks.", "uz.zenlygram.")

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_SOURCES = os.path.normpath(os.path.join(HERE, "..", "Sources"))
DEFAULT_STRINGS = os.path.normpath(os.path.join(HERE, "..", "..", "SGStrings", "Strings"))
DEFAULT_ALLOW = os.path.join(HERE, "no-cloud-word.allow")

# `var|func NAME` with Swift's member modifiers; attributes such as `@available(...)` come first.
DECLARATION_LINE = re.compile(
    r"^\s*(?:(?:@\w+(?:\([^)]*\))?|public|private|internal|fileprivate|open|static|final|override|"
    r"mutating|nonmutating|nonisolated|dynamic|lazy|weak|unowned|optional|required|convenience)\s+)*"
    r"(?:var|func)\s+([A-Za-z_][A-Za-z0-9_]*)"
)
# `en:` / `uz:` / `ru:` argument labels and `default:` inside `switch langCode`.
LANGUAGE_LABEL = re.compile(r"(?<![\w.])(en|uz|ru|default)\s*:")


class Failure(object):
    __slots__ = ("path", "line", "key", "lang", "rule", "snippet")

    def __init__(self, path, line, key, lang, rule, snippet):
        self.path = path
        self.line = line
        self.key = key
        self.lang = lang
        self.rule = rule
        self.snippet = snippet

    def __str__(self):
        where = "%s:%d" % (self.path, self.line)
        lang = " [%s]" % self.lang if self.lang else ""
        return "FAIL %s %s%s %s: %s" % (where, self.key, lang, self.rule, shorten(self.snippet))


def shorten(text, limit=90):
    text = text.replace("\n", "\\n")
    if len(text) <= limit:
        return text
    return text[: limit - 1] + "…"


# --- Swift scanning ----------------------------------------------------------------------------


class SwiftLiteral(object):
    """One string literal: `start`/`end` are the offsets of its contents (between the quotes)."""

    __slots__ = ("start", "end", "line", "lang")

    def __init__(self, start, end, line):
        self.start = start
        self.end = end
        self.line = line
        self.lang = None


class SwiftDeclaration(object):
    __slots__ = ("name", "start", "end", "line", "literals")

    def __init__(self, name, start, line):
        self.name = name
        self.start = start
        self.end = None
        self.line = line
        self.literals = []

    @property
    def gated(self):
        return self.name.startswith("tasks_") or self.name == "tab_tasks"


def blank_code(text):
    """Return (code, literals): `code` is `text` with every comment and every string literal's
    contents replaced by spaces (newlines kept, so offsets and lines are unchanged), `literals`
    the string literals in source order. Interpolations (`\\(…)`) stay part of their literal;
    a literal nested inside an interpolation is part of the outer one."""
    out = list(text)
    literals = []
    n = len(text)
    i = 0
    line = 1

    def blank(a, b):
        for k in range(a, b):
            if out[k] != "\n":
                out[k] = " "

    while i < n:
        ch = text[i]
        if ch == "\n":
            line += 1
            i += 1
            continue
        if ch == "/" and i + 1 < n and text[i + 1] == "/":
            j = text.find("\n", i)
            if j < 0:
                j = n
            blank(i, j)
            i = j
            continue
        if ch == "/" and i + 1 < n and text[i + 1] == "*":
            depth = 1
            j = i + 2
            while j < n and depth > 0:
                if text.startswith("/*", j):
                    depth += 1
                    j += 2
                elif text.startswith("*/", j):
                    depth -= 1
                    j += 2
                else:
                    j += 1
            line += text.count("\n", i, j)
            blank(i, j)
            i = j
            continue
        if ch == '"':
            start_line = line
            if text.startswith('"""', i):
                i += 3
                content_start = i
                i = scan_string_body(text, i, multiline=True)
                content_end = i
                i += 3
            else:
                i += 1
                content_start = i
                i = scan_string_body(text, i, multiline=False)
                content_end = i
                i += 1
            literals.append(SwiftLiteral(content_start, content_end, start_line))
            line += text.count("\n", content_start, content_end)
            blank(content_start, content_end)
            continue
        i += 1
    return "".join(out), literals


def scan_string_body(text, i, multiline):
    """Return the offset of the closing quote(s) of a string whose contents start at `i`."""
    n = len(text)
    while i < n:
        ch = text[i]
        if ch == "\\":
            if i + 1 < n and text[i + 1] == "(":
                i = scan_interpolation(text, i + 2)
                continue
            i += 2
            continue
        if multiline:
            if text.startswith('"""', i):
                return i
        elif ch == '"':
            return i
        i += 1
    return n


def scan_interpolation(text, i):
    """`i` is just after `\\(`; return the offset just after the matching `)`."""
    n = len(text)
    depth = 1
    while i < n and depth > 0:
        ch = text[i]
        if ch == '"':
            if text.startswith('"""', i):
                i = scan_string_body(text, i + 3, multiline=True) + 3
            else:
                i = scan_string_body(text, i + 1, multiline=False) + 1
            continue
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        i += 1
    return i


def scan_declarations(text):
    """Split a Swift file into member declarations (`var|func` lines at brace depth 1), attach
    every string literal to the declaration it sits in and attribute each literal a language."""
    code, literals = blank_code(text)
    declarations = []
    depth = 0
    offset = 0
    current = None
    line_no = 0
    for raw in code.splitlines(True):
        line_no += 1
        if depth == 1:
            match = DECLARATION_LINE.match(raw)
            if match:
                if current is not None:
                    current.end = offset
                current = SwiftDeclaration(match.group(1), offset, line_no)
                declarations.append(current)
        for ch in raw:
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0 and current is not None:
                    current.end = offset + len(raw)
                    current = None
        offset += len(raw)
    if current is not None:
        current.end = len(text)

    index = 0
    for declaration in declarations:
        while index < len(literals) and literals[index].start < declaration.start:
            index += 1
        while index < len(literals) and literals[index].start < declaration.end:
            declaration.literals.append(literals[index])
            index += 1
        attribute_languages(text, code, declaration)
    return declarations


def attribute_languages(text, code, declaration):
    """`en:` / `uz:` / `ru:` labels set the language of the literals that follow them inside a
    declaration; `case "uz":` patterns (switch langCode) and `default:` do the same."""
    lang = None
    previous_end = declaration.start
    for literal in declaration.literals:
        gap = code[previous_end : literal.start]
        found = None
        for match in LANGUAGE_LABEL.finditer(gap):
            found = match.group(1)
        if found is not None:
            lang = "en" if found == "default" else found
        literal.lang = lang
        content = text[literal.start : literal.end]
        if content in LANGUAGES:
            after = code[literal.end + 1 : literal.end + 8].lstrip()
            if after.startswith(":"):
                lang = content
        previous_end = literal.end
    return declaration


# --- Rules -----------------------------------------------------------------------------------------


def banned_word_hits(value):
    low = value.lower()
    return [word for word in BANNED_WORDS if word in low]


def apostrophe_faults(value):
    """The §15.1 orthography of a uz value: returns a list of (rule, index)."""
    faults = []
    for i, ch in enumerate(value):
        prev = value[i - 1] if i > 0 else ""
        nxt = value[i + 1] if i + 1 < len(value) else ""
        if ch in PLAIN_APOSTROPHES:
            if prev.isalpha() and nxt.isalpha():
                faults.append(("apostrophe U+%04X between letters (use U+02BB after o/g, else U+02BC)" % ord(ch), i))
        elif ch == MODIFIER_APOSTROPHE:
            if prev in O_G and prev != "":
                faults.append(("U+02BC after o/g (use U+02BB)", i))
        elif ch == TURNED_COMMA:
            if not (prev in O_G and prev != ""):
                faults.append(("U+02BB not after o/g (use U+02BC)", i))
    return faults


def check_value(path, line, key, lang, value, cloud_words_only=False):
    failures = []
    words = banned_word_hits(value)
    if cloud_words_only:
        words = [w for w in words if w in CLOUD_WORDS]
    for word in words:
        failures.append(Failure(path, line, key, lang, "banned word %r" % word, value))
    if lang == "uz" and not cloud_words_only:
        for rule, index in apostrophe_faults(value):
            snippet = value[max(0, index - 20) : index + 20]
            failures.append(Failure(path, line, key, lang, rule, snippet))
    return failures


def check_swift_file(path, allow, display=None):
    display = display or path
    text = read_text(path)
    failures = []
    gated = 0
    literals = 0
    for declaration in scan_declarations(text):
        if not declaration.gated or declaration.name in allow:
            continue
        gated += 1
        for literal in declaration.literals:
            literals += 1
            value = text[literal.start : literal.end]
            failures.extend(check_value(display, literal.line, declaration.name, literal.lang, value))
    return failures, gated, literals


def cloud_symbol_fault(value):
    """Rule (a): True when the literal names a cloud SF Symbol (and is not an exempt identifier)."""
    if value.startswith(CLOUD_SYMBOL_EXEMPT_PREFIXES):
        return False
    return CLOUD_SYMBOL.search(value) is not None


def check_swift_symbols(path, display=None):
    """Rule (a) over every string literal of one Swift file (comments excluded, declarations or not)."""
    display = display or path
    text = read_text(path)
    _code, literals = blank_code(text)
    failures = []
    for literal in literals:
        value = text[literal.start : literal.end]
        if cloud_symbol_fault(value):
            failures.append(Failure(display, literal.line, "symbol", None, "cloud SF Symbol name (§15.4 rule a)", value))
    return failures, len(literals)


# --- .strings ---------------------------------------------------------------------------------------

STRINGS_LINE = re.compile(r'^"((?:[^"\\]|\\.)+)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;')


def read_strings_table(path):
    """{key: (line, raw value)} of one SGLocalizable.strings (values as written, escapes kept)."""
    table = {}
    for number, raw in enumerate(read_text(path).splitlines(), 1):
        match = STRINGS_LINE.match(raw)
        if match:
            table[match.group(1)] = (number, match.group(2))
    return table


def check_strings_tables(strings_root, keys, cloud_words_only=False):
    failures = []
    checked = 0
    for lang in LANGUAGES:
        path = os.path.join(strings_root, lang + ".lproj", STRINGS_RELATIVE)
        display = relative(path)
        table = read_strings_table(path)
        for key in keys:
            if key not in table:
                failures.append(Failure(display, 0, key, lang, "missing key", ""))
                continue
            line, value = table[key]
            checked += 1
            failures.extend(check_value(display, line, key, lang, value, cloud_words_only))
    return failures, checked


# --- Subcommands ---------------------------------------------------------------------------------


def read_text(path):
    with io.open(path, "r", encoding="utf-8", newline="") as handle:
        return handle.read()


def write_text(path, text):
    with io.open(path, "w", encoding="utf-8", newline="") as handle:
        handle.write(text)


def relative(path):
    """The path as the report prints it: relative inside the working directory, absolute outside."""
    try:
        rel = os.path.relpath(path)
    except ValueError:
        return path
    return path if rel.startswith("..") else rel


def read_allow(path):
    allow = set()
    if path is None or not os.path.exists(path):
        return allow
    for raw in read_text(path).splitlines():
        key = raw.split("#", 1)[0].strip()
        if key:
            allow.add(key)
    return allow


def swift_sources(paths):
    files = []
    for path in paths:
        if os.path.isdir(path):
            for name in sorted(os.listdir(path)):
                if name.startswith("SGTasksL10n") and name.endswith(".swift"):
                    files.append(os.path.join(path, name))
        else:
            files.append(path)
    return files


def all_swift_sources(paths):
    """Every `*.swift` under the given directories (recursively), or the files given; rule (a)."""
    files = []
    for path in paths:
        if os.path.isdir(path):
            for root, _dirs, names in os.walk(path):
                for name in sorted(names):
                    if name.endswith(".swift"):
                        files.append(os.path.join(root, name))
        else:
            files.append(path)
    return files


def run_gate(args):
    sources = swift_sources(args.sources or [DEFAULT_SOURCES])
    if not sources:
        sys.stderr.write("check-strings: no SGTasksL10n*.swift under %s\n" % (args.sources or [DEFAULT_SOURCES]))
        return 2
    allow = read_allow(args.allow)
    failures = []
    gated = literals = 0
    for path in sources:
        file_failures, file_gated, file_literals = check_swift_file(path, allow, relative(path))
        failures.extend(file_failures)
        gated += file_gated
        literals += file_literals
    symbol_sources = all_swift_sources(args.sources or [DEFAULT_SOURCES])
    symbol_literals = 0
    for path in symbol_sources:
        file_failures, file_literals = check_swift_symbols(path, relative(path))
        failures.extend(file_failures)
        symbol_literals += file_literals
    strings_root = args.strings or DEFAULT_STRINGS
    table_failures, checked = check_strings_tables(strings_root, [LOGOUT_NOTICE_KEY])
    failures.extend(table_failures)
    o6b_failures, o6b_checked = check_strings_tables(strings_root, O6B_KEYS, cloud_words_only=True)
    failures.extend(o6b_failures)
    checked += o6b_checked
    for failure in failures:
        print(failure)
    print(
        "check-strings: %d Swift file(s), %d gated declaration(s), %d literal(s), %d .strings value(s), "
        "%d source file(s) with %d literal(s) scanned for cloud symbols, %d allowed key(s), %d failure(s)"
        % (len(sources), gated, literals, checked, len(symbol_sources), symbol_literals, len(allow), len(failures))
    )
    return 1 if failures else 0


def run_fixture(args):
    failures, gated, literals = check_swift_file(args.file, set(), relative(args.file))
    symbol_failures, symbol_literals = check_swift_symbols(args.file, relative(args.file))
    failures.extend(symbol_failures)
    for failure in failures:
        print(failure)
    print("check-strings fixture: %d gated declaration(s), %d literal(s), %d literal(s) scanned for cloud symbols, %d failure(s)" % (gated, literals, symbol_literals, len(failures)))
    return 1 if failures else 0


def normalise_uz(value):
    out = list(value)
    changed = 0
    for i, ch in enumerate(value):
        if ch not in PLAIN_APOSTROPHES:
            continue
        prev = value[i - 1] if i > 0 else ""
        nxt = value[i + 1] if i + 1 < len(value) else ""
        if prev != "" and prev in O_G:
            out[i] = TURNED_COMMA
            changed += 1
        elif prev.isalpha() and nxt.isalpha():
            out[i] = MODIFIER_APOSTROPHE
            changed += 1
    return "".join(out), changed


def run_fix_apostrophes(args):
    total = 0
    for path in args.files:
        text = read_text(path)
        edits = []
        for declaration in scan_declarations(text):
            if not declaration.gated:
                continue
            for literal in declaration.literals:
                if literal.lang != "uz":
                    continue
                value = text[literal.start : literal.end]
                fixed, changed = normalise_uz(value)
                if changed:
                    edits.append((literal.start, literal.end, fixed, declaration.name, changed))
        if not edits:
            print("%s: unchanged" % relative(path))
            continue
        names = {}
        for start, end, fixed, name, changed in reversed(edits):
            text = text[:start] + fixed + text[end:]
            names[name] = names.get(name, 0) + changed
        write_text(path, text)
        total += sum(names.values())
        print("%s: %d apostrophe(s) in %d declaration(s)" % (relative(path), sum(names.values()), len(names)))
        for name in sorted(names):
            print("  %s: %d" % (name, names[name]))
    print("fix-apostrophes: %d apostrophe(s) normalised" % total)
    return 0


def dump_files(paths):
    files = []
    for path in paths:
        if os.path.isdir(path):
            for root, _dirs, names in os.walk(path):
                for name in sorted(names):
                    if name.endswith("tree.txt"):
                        files.append(os.path.join(root, name))
        else:
            files.append(path)
    return files


# What a tree line shows or speaks. XCUITest prints each element as
# `Kind, 0x…, {{x, y}, {w, h}}, identifier: '…', label: '…', value: …`; the accessibility identifier is
# never shown or spoken (§15.4 rule (a) exempts the `sgtasks.…` ids for the same reason, and §15.2 keeps
# `sgtasks.cloud.privacy`), and a container without a label prints its `<Module.Class: 0x…>` description
# (an `ASDisplayNode` such as `SGTasks.TasksCloudBoardNode`), which is a class name, not UI text.
DUMP_IDENTIFIER = re.compile(r"identifier: '[^']*'")
DUMP_DESCRIPTION = re.compile(r"label: '<[^'>]*: 0x[^']*>'")


def dump_visible_text(raw):
    return DUMP_DESCRIPTION.sub("label: ''", DUMP_IDENTIFIER.sub("identifier: ''", raw))


def run_dump(args):
    files = dump_files(args.paths)
    if not files:
        sys.stderr.write("check-strings dump: no *tree.txt under %s\n" % args.paths)
        return 2
    failures = []
    lines = 0
    for path in files:
        for number, raw in enumerate(read_text(path).splitlines(), 1):
            lines += 1
            for word in banned_word_hits(dump_visible_text(raw)):
                failures.append(Failure(relative(path), number, "ui-dump", None, "banned word %r" % word, raw.strip()))
    for failure in failures:
        print(failure)
    print("check-strings dump: %d tree file(s), %d line(s), %d failure(s)" % (len(files), lines, len(failures)))
    return 1 if failures else 0


def main(argv):
    parser = argparse.ArgumentParser(prog="check_strings.py", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    subparsers = parser.add_subparsers(dest="command")
    gate = subparsers.add_parser("gate", help="the gate over the repository files (default)")
    gate.add_argument("--sources", nargs="*", help="SGTasksL10n*.swift files or their directory")
    gate.add_argument("--strings", help="Swiftgram/SGStrings/Strings directory")
    gate.add_argument("--allow", default=DEFAULT_ALLOW, help="allow file (skipped keys); may be absent")
    fixture = subparsers.add_parser("fixture", help="one Swift file alone (the self-test)")
    fixture.add_argument("file")
    fix = subparsers.add_parser("fix-apostrophes", help="normalise the uz apostrophes of the gated declarations in place")
    fix.add_argument("files", nargs="+")
    dump = subparsers.add_parser("dump", help="scan ios-ui dump trees for the banned words")
    dump.add_argument("paths", nargs="+")
    if not argv or argv[0].startswith("-"):
        argv = ["gate"] + list(argv)
    args = parser.parse_args(argv)
    if args.command == "gate":
        return run_gate(args)
    if args.command == "fixture":
        return run_fixture(args)
    if args.command == "fix-apostrophes":
        return run_fix_apostrophes(args)
    if args.command == "dump":
        return run_dump(args)
    parser.print_help()
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (IOError, OSError) as error:
        sys.stderr.write("check-strings: %s\n" % error)
        sys.exit(2)
