#!/usr/bin/env python3
"""Localization gate for the SwiftUI/AppKit prototype and its Rust bridges.

The prototype translates strings through three mechanisms:

  (a) LocalizedStringKey + ``Resources/en.lproj/Localizable.strings``. Chinese
      source strings are the keys; SwiftUI looks the English text up from the
      bundle (the views inject ``.environment(\\.locale, ...)`` for English).
  (b) the explicit bilingual helpers ``t("中文", "English")`` and
      ``model.text("中文", "English")``.
  (c) inline ``language == 0 ? "English" : "中文"`` switches and the player's
      ``localized()`` helper (exact en.lproj keys plus a small prefix map).

A user-visible Chinese string that no mechanism can translate is a leak: in
English mode it renders verbatim. This gate finds those leaks structurally:

  R1 strings-key        Chinese literal used as a LocalizedStringKey (including
                        interpolated format keys such as "Root：%@") with no
                        en.lproj entry.
  R2 appkit-sink        Chinese literal assigned straight to an AppKit display
                        sink that bypasses SwiftUI localization:
                        NSSavePanel.nameFieldStringValue, panel.prompt,
                        NSWindow.title, NSImage accessibilityDescription,
                        toolTip, setAccessibilityLabel, .accessibilityLabel,
                        .accessibilityValue.
  R2b appkit-a11y       .accessibilityValue(variable) passing a status string
                        that was only localized for display (no localized()).
  R3 dynamic-sink       Chinese literal assigned to a String variable that the
                        UI renders (Text(variable), @State/@Published state,
                        onStatus(variable), ...).
  R4 exposed-error      Chinese literal that becomes a user-visible error
                        description: NSLocalizedDescriptionKey, a
                        LocalizedError.errorDescription(), or a
                        DeviceCreation validation message that is not mapped by
                        CenterModel.creationError().
  R5 player-status      Chinese literal passed to the player onStatus sink with
                        neither an en.lproj key nor a localized() prefix.
  R6 bridge-diagnostic  Chinese literal in a user-visible diagnostic of the two
                        bridge binaries (player bridge, center bridge).
  R7 bilingual-helper   t()/model.text() call with a Chinese first argument but
                        no English second argument (or Chinese in the English
                        slot).
  R8 inline-ternary     language==0 switch whose English branch still contains
                        Chinese.

Mechanisms (a), (b) and (c) are also *counted* so the log proves what was
checked, and the .strings files get non-blocking hygiene warnings (duplicate
keys, en-only/zh-only keys, dead keys, trailing spaces, format-placeholder
mismatches).

Known gaps are baselined in ``Tests/i18n_allowlist.txt`` (one line per
finding, with the M0 audit group and the M2 fix). Only findings outside that
baseline fail the gate. ``--self-test`` proves the rules catch violations with
in-memory samples before scanning the real tree; it never touches the app.
"""

from __future__ import annotations

import argparse
import re
import sys
from bisect import bisect_left
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path

APP_DIR = Path(__file__).resolve().parents[1]
ROOT = APP_DIR.parents[1]
EN_STRINGS = APP_DIR / "Resources" / "en.lproj" / "Localizable.strings"
ZH_STRINGS = APP_DIR / "Resources" / "zh-Hans.lproj" / "Localizable.strings"
ALLOWLIST_PATH = Path(__file__).resolve().with_name("i18n_allowlist.txt")

# CJK ideographs, CJK punctuation and fullwidth forms: a string that contains
# any of these is treated as Chinese user-facing text.
CJK = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\u3000-\u303f\uff01-\uff60]")

# SwiftUI/AppKit initializers whose first argument is a LocalizedStringKey.
LOCALIZABLE_INITIALIZERS = frozenset(
    {
        "Text",
        "Button",
        "Label",
        "LabeledContent",
        "Section",
        "Picker",
        "TextField",
        "SecureField",
        "Toggle",
        "Stepper",
        "GroupBox",
        "Menu",
        "Link",
        "NavigationLink",
        "help",
        "alert",
        "confirmationDialog",
        "navigationTitle",
        "navigationSubtitle",
    }
)

# Bilingual helpers (mechanism b) and the player's translation helper.
MECHANISM_B_HELPERS = frozenset({"t", "text"})
TRANSLATION_HELPERS = frozenset({"t", "text", "localized"})

# Player status strings that go through the visible bubble (R5).
PLAYER_STATUS_SINK = "onStatus"

# Prefix map inside GameWindow.ContentView.localized(), which translates a few
# messages whose text is assembled at runtime.
LOCALIZED_PREFIXES = ("连接已结束（", "已绑定 ", "无法启动桥接：")

# Player status state-machine sentinels. They are never rendered: ContentView
# filters them out (GameWindow.swift: if status != "准备中" && status != "已连接")
# and they drive comparisons only, so they are not localization gaps.
PLAYER_STATUS_SENTINELS = frozenset({"准备中", "已连接"})

# AppKit display sinks that take a plain String (R2). The pattern is matched
# against the masked source between the line start and the literal's opening
# quote, so earlier string literals on the same line are already blanked.
APPKIT_SINK_PATTERNS = (
    re.compile(r"\bnameFieldStringValue\s*=\s*$"),
    re.compile(r"\.prompt\s*=\s*$"),
    re.compile(r"\.title\s*=\s*$"),
    re.compile(r"\baccessibilityDescription\s*:\s*$"),
    re.compile(r"\.toolTip\s*=\s*$"),
    re.compile(r"\.setAccessibilityLabel\(\s*$"),
    re.compile(r"\.accessibilityLabel\(\s*$"),
    re.compile(r"\.accessibilityValue\(\s*$"),
)

# A method/initializer call: "Text(", "model.text(", "self?.onStatus?(", ...
CALLEE = re.compile(r"([A-Za-z_][A-Za-z0-9_.?]*)\s*$")
BARE_IDENTIFIER = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
ASSIGNMENT = re.compile(r"(?:self\.)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*$")
STATE_DECLARATION = re.compile(
    r"@(?:State|Published)\s+(?:private\s+)?(?:\(set\)\s+)?var\s+"
    r"([A-Za-z_][A-Za-z0-9_]*)\s*(?::\s*[A-Za-z_][A-Za-z0-9_]*\s*)?=\s*$"
)
LANGUAGE_TERNARY = re.compile(r"language\s*==\s*0\s*\?")
FORMAT_SPEC = re.compile(r"%(?:\d+\$)?[-+0-9.#]*[a-zA-Z@]")
FORMAT_SPEC_DETAIL = re.compile(r"%(?:\d+\$)?[-+0-9.#]*([a-zA-Z@])")


# ---------------------------------------------------------------------------
# Source files and the string-literal lexer


@dataclass
class Literal:
    """One string literal (or interpolation-free concatenation of its pieces)."""

    line: int
    text: str  # static pieces joined; interpolation arguments are dropped
    pieces: tuple[str, ...]  # static pieces, interps+1 of them
    interps: int  # number of \( ... ) interpolations
    start: int
    end: int
    depth: int  # 0 = code-level literal, >0 = inside another literal's interpolation


@dataclass
class Call:
    name: str  # last path component, e.g. "Text", "text", "onStatus"
    raw: str  # e.g. "model.text", "self?.onStatus?"
    open: int
    close: int
    args: list[tuple[int, int]]  # (start, end) offsets of each argument


@dataclass
class Source:
    path: Path
    rel: str
    text: str
    masked: str
    literals: list[Literal]
    parens: dict[int, int]  # opening '(' offset -> closing ')' offset
    paren_stack: list[int]  # paren_stack[pos] = innermost open '(' before pos
    calls: list[Call] = field(default_factory=list)


def _scan_text(text: str) -> tuple[list[Literal], list[tuple[int, int]]]:
    """Return the string literals and comment spans in a Swift/Rust source."""
    n = len(text)
    literals: list[Literal] = []
    comments: list[tuple[int, int]] = []

    def scan_string(j: int, depth: int) -> int:
        start = j
        parts = [""]
        interps = 0
        triple = text.startswith('"""', j)
        if triple:
            j += 3
            while j < n:
                if text.startswith('"""', j):
                    literals.append(
                        Literal(0, "".join(parts), tuple(parts), interps, start, j + 3, depth)
                    )
                    return j + 3
                ch = text[j]
                if ch == "\\" and j + 1 < n:
                    if text[j + 1] == "(":
                        interps += 1
                        j = scan_interp(j + 2, depth + 1)
                        parts.append("")
                        continue
                    parts[-1] += text[j : j + 2]
                    j += 2
                    continue
                parts[-1] += ch
                j += 1
            literals.append(Literal(0, "".join(parts), tuple(parts), interps, start, j, depth))
            return j
        j += 1
        while j < n:
            ch = text[j]
            if ch == "\\" and j + 1 < n:
                if text[j + 1] == "(":
                    interps += 1
                    j = scan_interp(j + 2, depth + 1)
                    parts.append("")
                    continue
                parts[-1] += text[j : j + 2]
                j += 2
                continue
            if ch == '"':
                literals.append(
                    Literal(0, "".join(parts), tuple(parts), interps, start, j + 1, depth)
                )
                return j + 1
            parts[-1] += ch
            j += 1
        return j

    def scan_interp(j: int, depth: int) -> int:
        nesting = 1
        while j < n and nesting > 0:
            ch = text[j]
            if ch == '"':
                j = scan_string(j, depth)
                continue
            if ch == "(":
                nesting += 1
            elif ch == ")":
                nesting -= 1
            j += 1
        return j

    i = 0
    while i < n:
        if text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            comments.append((i, j))
            i = j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            comments.append((i, j))
            i = j
        elif text[i] == '"':
            i = scan_string(i, 0)
        else:
            i += 1
    return literals, comments


def build_source(path: Path, rel: str, text: str | None = None) -> Source:
    if text is None:
        text = path.read_text(encoding="utf-8")
    literals, comments = _scan_text(text)
    newlines = [k for k, ch in enumerate(text) if ch == "\n"]
    for lit in literals:
        lit.line = bisect_left(newlines, lit.start) + 1
    chars = list(text)
    for lit in literals:
        for k in range(lit.start, lit.end):
            if chars[k] != "\n":
                chars[k] = " "
    for start, end in comments:
        for k in range(start, end):
            if chars[k] != "\n":
                chars[k] = " "
    masked = "".join(chars)
    parens: dict[int, int] = {}
    stack: list[int] = []
    paren_stack = [-1] * (len(masked) + 1)
    for k, ch in enumerate(masked):
        if ch == "(":
            stack.append(k)
            paren_stack[k + 1] = k
        elif ch == ")" and stack:
            parens[stack.pop()] = k
            paren_stack[k + 1] = stack[-1] if stack else -1
        else:
            paren_stack[k + 1] = stack[-1] if stack else -1
    source = Source(path, rel, text, masked, literals, parens, paren_stack)
    source.calls = _collect_calls(source)
    return source


def _callee_before(source: Source, open_idx: int) -> str:
    window = source.masked[max(0, open_idx - 160) : open_idx]
    match = CALLEE.search(window)
    return match.group(1) if match else ""


def _call_name(raw: str) -> str:
    return raw.split(".")[-1].rstrip("?")


def _split_args(masked: str, open_idx: int, close_idx: int) -> list[tuple[int, int]]:
    spans: list[tuple[int, int]] = []
    depth = 0
    start = open_idx + 1
    for k in range(open_idx + 1, close_idx):
        ch = masked[k]
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        elif ch == "," and depth == 0:
            spans.append((start, k))
            start = k + 1
    spans.append((start, close_idx))
    return spans


def _collect_calls(source: Source) -> list[Call]:
    calls: list[Call] = []
    for open_idx, close_idx in sorted(source.parens.items()):
        raw = _callee_before(source, open_idx)
        if not raw:
            continue
        calls.append(
            Call(
                name=_call_name(raw),
                raw=raw,
                open=open_idx,
                close=close_idx,
                args=_split_args(source.masked, open_idx, close_idx),
            )
        )
    return calls


def _enclosing_call(source: Source, pos: int) -> Call | None:
    """Innermost call whose parentheses contain ``pos`` (within the arguments)."""
    open_idx = source.paren_stack[pos]
    if open_idx < 0:
        return None
    close_idx = source.parens.get(open_idx)
    if close_idx is None or not (open_idx < pos < close_idx):
        return None
    for call in source.calls:
        if call.open == open_idx:
            return call
    # A parenthesis that is not a call (e.g. a tuple or grouping) can still
    # enclose the literal; walk outwards to the nearest real call.
    depth_guard = 0
    while open_idx >= 0 and depth_guard < 40:
        depth_guard += 1
        open_idx = source.paren_stack[open_idx]
        if open_idx < 0:
            return None
        close_idx = source.parens.get(open_idx)
        if close_idx is None or not (open_idx < pos < close_idx):
            return None
        for call in source.calls:
            if call.open == open_idx:
                return call
    return None


def _arg_index(source: Source, call: Call, pos: int) -> int:
    index = 0
    depth = 0
    for ch in source.masked[call.open + 1 : pos]:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        elif ch == "," and depth == 0:
            index += 1
    return index


def _line_prefix(source: Source, lit: Literal) -> str:
    line_start = source.masked.rfind("\n", 0, lit.start) + 1
    return source.masked[line_start : lit.start]


def _top_level_literals(source: Source, start: int, end: int) -> list[Literal]:
    return [lit for lit in source.literals if lit.depth == 0 and start <= lit.start < end]


# ---------------------------------------------------------------------------
# .strings files


@dataclass
class StringsEntry:
    key: str
    value: str
    line: int


def load_strings(path: Path) -> list[StringsEntry]:
    text = path.read_text(encoding="utf-8")
    entries: list[StringsEntry] = []
    pattern = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";', re.MULTILINE)
    for match in pattern.finditer(text):
        line = text.count("\n", 0, match.start()) + 1
        entries.append(StringsEntry(match.group(1), match.group(2), line))
    return entries


# ---------------------------------------------------------------------------
# Findings and the gate


@dataclass(frozen=True)
class Finding:
    path: str
    line: int
    rule: str
    literal: str
    hint: str

    def key(self) -> tuple[str, str, str]:
        return (self.path, self.rule, self.literal)


HINTS = {
    "strings-key": (
        'add an en.lproj entry (or route the text through t()/model.text()); '
        "SwiftUI looks this literal up as a LocalizedStringKey"
    ),
    "appkit-sink": (
        "AppKit takes a plain String here; build it with t()/model.text() "
        "or localized() instead of a literal"
    ),
    "appkit-a11y": (
        "the visible status is localized but this accessibility value is not; "
        "pass localized(status)"
    ),
    "dynamic-sink": (
        "the value is rendered by the UI; assign t()/model.text() output or a "
        "code translated by OperationMessages"
    ),
    "exposed-error": (
        "this error text reaches the UI verbatim; expose a code and translate "
        "it in Swift, or add it to the OperationMessages tables"
    ),
    "player-status": (
        "player status bubbles go through localized(); add an en.lproj entry "
        "or a localized() prefix mapping"
    ),
    "bridge-diagnostic": (
        "this bridge diagnostic reaches the UI verbatim; send a stable code "
        "(or English text) and translate it in Swift"
    ),
    "bilingual-helper": (
        "t()/model.text() must receive both languages; the English counterpart "
        "is missing or still Chinese"
    ),
    "inline-ternary": (
        "the language==0 branch is the English UI; it must not contain Chinese"
    ),
}


class Gate:
    """Runs the Swift and Rust rules over a set of in-memory sources."""

    def __init__(
        self,
        swift_sources: list[Source],
        rust_sources: list[Source],
        en_keys: set[str],
        creation_error_keys: set[str],
    ) -> None:
        self.swift_sources = swift_sources
        self.rust_sources = rust_sources
        self.en_keys = en_keys
        self.creation_error_keys = creation_error_keys
        self.findings: list[Finding] = []
        self.checked = Counter()  # rule -> covered occurrences
        # Every depth-0 Chinese literal in the Swift sources, plus the interpolated
        # LocalizedStringKey format keys: the .strings hygiene check uses this set
        # to report dead keys (reference = "the key text appears in the sources").
        self.referenced_literals: set[str] = {
            lit.text
            for source in swift_sources
            for lit in source.literals
            if lit.depth == 0 and CJK.search(lit.text)
        }
        self.referenced_format_keys: set[str] = set()
        self.exposed_names = self._displayed_names()
        self._run()

    # -- shared helpers ----------------------------------------------------

    def _add(self, source: Source, lit: Literal, rule: str) -> None:
        literal = lit.text
        if rule == "strings-key" and lit.interps:
            # An interpolated LocalizedStringKey is looked up as a format key,
            # e.g. Text("Root：\(mode)") needs the "Root：%@" entry.
            literal = "%@".join(lit.pieces)
        self.findings.append(Finding(source.rel, lit.line, rule, literal, HINTS[rule]))

    def _is_interpolated_key_covered(self, lit: Literal) -> bool:
        # A key may use any printf-style placeholder for the interpolation
        # (SwiftUI emits %@/%lld depending on the interpolated type).
        flexible = re.compile(
            "^"
            + "".join(
                (r"%(?:\d+\$)?[-+0-9.#]*[a-zA-Z@]" if i and i <= lit.interps else re.escape(piece))
                for i, piece in enumerate(lit.pieces)
            )
            + "$"
        )
        return any(flexible.match(key) for key in self.en_keys)

    # -- rule wiring -------------------------------------------------------

    def _displayed_names(self) -> set[str]:
        """String variables the UI renders (bare Text(x), states, onStatus(x))."""
        names: set[str] = set()
        display_calls = {
            "Text",
            "Label",
            "LabeledContent",
            "ProgressView",
            "accessibilityValue",
            "accessibilityLabel",
            "help",
            "toolTip",
            "onStatus",
            "onWarning",
        }
        for source in self.swift_sources:
            for call in source.calls:
                if call.name not in display_calls or not call.args:
                    continue
                start, end = call.args[0]
                if BARE_IDENTIFIER.match(source.masked[start:end].strip()):
                    names.add(source.masked[start:end].strip())
            for match in STATE_DECLARATION.finditer(source.masked):
                names.add(match.group(1))
        return names

    def _run(self) -> None:
        for source in self.swift_sources:
            for lit in source.literals:
                if lit.depth != 0 or not CJK.search(lit.text):
                    continue
                self._classify_swift(source, lit)
        self._check_bilingual_helpers()
        self._check_inline_ternaries()
        for source in self.rust_sources:
            self._classify_rust(source)

    def _classify_swift(self, source: Source, lit: Literal) -> None:
        prefix = _line_prefix(source, lit)
        call = _enclosing_call(source, lit.start)
        call_name = call.name if call else None

        # R2: AppKit string sinks (literal directly after the sink).
        if any(pattern.search(prefix) for pattern in APPKIT_SINK_PATTERNS):
            self._add(source, lit, "appkit-sink")
            return

        # R4: user-visible error descriptions.
        if re.search(r"NSLocalizedDescriptionKey\s*:\s*$", prefix):
            self._add(source, lit, "exposed-error")
            return
        if re.search(r"NSLocalizedDescriptionKey[^;\n]*$", source.masked[max(0, lit.start - 240) : lit.start]):
            # e.g. [NSLocalizedDescriptionKey: value ?? "操作失败"]: the fallback
            # still becomes the user-visible error text.
            self._add(source, lit, "exposed-error")
            return
        if "LocalizedError" in source.text and re.search(r"return\s+$", prefix):
            self._add(source, lit, "exposed-error")
            return
        # A DeviceCreation validation message is shown through
        # CenterModel.creationError(), which maps every known message; a new
        # message that the map does not know would fall through untranslated.
        if call_name == "invalid" and call:
            if lit.text in self.creation_error_keys:
                self.checked["creation-validation"] += 1
            else:
                self._add(source, lit, "exposed-error")
            return

        if call_name in TRANSLATION_HELPERS:
            return  # mechanism (b): t() / model.text() / localized()

        # R5: the player status bubble.
        if call_name == PLAYER_STATUS_SINK:
            if lit.text in PLAYER_STATUS_SENTINELS:
                return
            window = source.masked[max(0, lit.start - 400) : lit.start]
            if LANGUAGE_TERNARY.search(window):
                return
            if lit.text in self.en_keys or lit.text.startswith(LOCALIZED_PREFIXES):
                self.checked["player-status-covered"] += 1
                return
            self._add(source, lit, "player-status")
            return

        # R1: LocalizedStringKey positions.
        if call_name in LOCALIZABLE_INITIALIZERS and call and _arg_index(source, call, lit.start) == 0:
            if lit.interps:
                format_key = "%@".join(lit.pieces)
                self.referenced_format_keys.add(format_key)
                if self._is_interpolated_key_covered(lit):
                    self.checked["mechanism-a"] += 1
                else:
                    self._add(source, lit, "strings-key")
            elif lit.text in self.en_keys:
                self.checked["mechanism-a"] += 1
            else:
                self._add(source, lit, "strings-key")
            return

        # R3: Chinese literal assigned to a String the UI renders.
        declaration = STATE_DECLARATION.search(prefix)
        assignment = ASSIGNMENT.search(prefix)
        if declaration:
            if lit.text in PLAYER_STATUS_SENTINELS:
                return
            self._add(source, lit, "dynamic-sink")
            return
        if assignment and assignment.group(1) in self.exposed_names:
            if lit.text in PLAYER_STATUS_SENTINELS:
                return
            self._add(source, lit, "dynamic-sink")
            return

    def _check_bilingual_helpers(self) -> None:
        for source in self.swift_sources:
            for call in source.calls:
                if call.name not in MECHANISM_B_HELPERS or not call.args:
                    continue
                first_start, first_end = call.args[0]
                first_raw = source.text[first_start:first_end]
                if not CJK.search(first_raw):
                    continue
                self.checked["mechanism-b"] += 1
                self.checked["mechanism-b-" + call.name] += 1
                second_start, second_end = (
                    call.args[1] if len(call.args) > 1 else (-1, -1)
                )
                second_raw = source.text[second_start:second_end] if second_start >= 0 else ""
                if len(call.args) < 2 or not second_raw.strip():
                    lit = _top_level_literals(source, first_start, first_end)
                    if lit:
                        self.findings.append(
                            Finding(source.rel, lit[0].line, "bilingual-helper", lit[0].text,
                                    HINTS["bilingual-helper"])
                        )
                    continue
                second_literals = _top_level_literals(source, second_start, second_end)
                chinese = [lit for lit in second_literals if CJK.search(lit.text)]
                if chinese:
                    self.findings.append(
                        Finding(source.rel, chinese[0].line, "bilingual-helper",
                                chinese[0].text, HINTS["bilingual-helper"])
                    )

    def _check_inline_ternaries(self) -> None:
        for source in self.swift_sources:
            for match in LANGUAGE_TERNARY.finditer(source.masked):
                self.checked["mechanism-c-all"] += 1
                cursor = match.end()
                depth = 0
                nesting = 0
                separator = -1
                end = len(source.masked)
                # A ternary may span lines (the player writes the two
                # branches on separate lines), so stop at a statement boundary
                # or after a bounded window, not at the first newline.
                limit = min(end, match.end() + 1200)
                while cursor < limit:
                    ch = source.masked[cursor]
                    if ch in "([{":
                        depth += 1
                    elif ch in ")]}":
                        depth -= 1
                        if depth < 0:
                            break
                    elif depth == 0:
                        if ch == "?":
                            nesting += 1
                        elif ch == ":":
                            if nesting == 0:
                                separator = cursor
                                break
                            nesting -= 1
                        elif ch == ";":
                            break
                    cursor += 1
                if separator < 0:
                    continue
                first_branch = source.text[match.end() : separator]
                if CJK.search(first_branch):
                    literal = next(
                        (lit.text for lit in source.literals
                         if match.end() <= lit.start < separator and CJK.search(lit.text)),
                        first_branch.strip()[:60],
                    )
                    line = next(
                        (lit.line for lit in source.literals if match.end() <= lit.start < separator),
                        1,
                    )
                    self.findings.append(
                        Finding(source.rel, line, "inline-ternary", literal,
                                HINTS["inline-ternary"])
                    )
                # Classify the 26 switches: locale identifiers, the two
                # internal bilingual helpers, and copy switches (one branch is
                # Chinese, or the non-English branch is a dynamic string).
                tail = source.text[separator + 1 : separator + 200]
                first = first_branch.strip()
                second = tail.strip()
                if first in ('"en"', '"zh-Hans"') or second.startswith('"zh-Hans"'):
                    self.checked["mechanism-c-locale"] += 1
                else:
                    # helper form: language == 0 ? english : chinese / pair.1 : pair.0
                    helper_first = re.match(r"[A-Za-z_][A-Za-z0-9_.]*$", first)
                    helper_second = re.match(r"[A-Za-z_][A-Za-z0-9_.]*", second)
                    if helper_first and helper_second:
                        self.checked["mechanism-c-helper"] += 1
                    else:
                        self.checked["mechanism-c-copy"] += 1

    def _classify_rust(self, source: Source) -> None:
        cfg_test = source.text.find("#[cfg(test)]")
        for lit in source.literals:
            if lit.depth != 0 or not CJK.search(lit.text):
                continue
            if cfg_test >= 0 and lit.start >= cfg_test:
                continue
            self._add(source, lit, "bridge-diagnostic")

    # -- R2b: accessibility values that bypass localized() -----------------

    def check_accessibility_values(self) -> None:
        for source in self.swift_sources:
            for call in source.calls:
                if call.name != "accessibilityValue" or not call.args:
                    continue
                start, end = call.args[0]
                value = source.masked[start:end].strip()
                if BARE_IDENTIFIER.match(value):
                    self.findings.append(
                        Finding(source.rel, source.text.count("\n", 0, call.open) + 1,
                                "appkit-a11y", value, HINTS["appkit-a11y"])
                    )

    # -- aggregate views ---------------------------------------------------

    def grouped(self) -> dict[tuple[str, str, str], list[Finding]]:
        grouped: dict[tuple[str, str, str], list[Finding]] = defaultdict(list)
        for finding in self.findings:
            grouped[finding.key()].append(finding)
        return grouped


def creation_error_keys(device_model: Path) -> set[str]:
    """Keys of CenterModel.creationError()'s translation table."""
    text = device_model.read_text(encoding="utf-8")
    start = text.find("func creationError")
    if start < 0:
        return set()
    block = text[start : start + 3000]
    keys = set(re.findall(r'"((?:[^"\\]|\\.)+)"\s*:\s*"', block))
    return {key for key in keys if CJK.search(key)}


# ---------------------------------------------------------------------------
# Reporting


def _esc(text: str) -> str:
    return text.replace("\n", "\\n")


def format_findings(findings: list[Finding], marker: str) -> list[str]:
    lines = []
    for finding in findings:
        lines.append(
            f"  {marker} {finding.path}:{finding.line}  [{finding.rule}] "
            f'"{_esc(finding.literal)}"'
        )
        lines.append(f"      -> {finding.hint}")
    return lines


@dataclass(frozen=True)
class AllowEntry:
    path: str
    line: int
    rule: str
    literal: str
    reason: str
    occurrences: int = 1

    def key(self) -> tuple[str, str, str]:
        return (self.path, self.rule, self.literal)


def load_allowlist(path: Path) -> tuple[list[AllowEntry], list[str]]:
    entries: list[AllowEntry] = []
    errors: list[str] = []
    if not path.exists():
        return entries, [f"missing allowlist file: {path}"]
    for number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split(" | ")
        if len(parts) < 4:
            errors.append(f"{path.name}:{number}: expected '<path>:<line> | <rule> | <literal> | <reason> | M2: <fix>'")
            continue
        location, rule = parts[0].strip(), parts[1].strip()
        literal = parts[2]  # exact text: some UI literals carry significant spaces
        reason = parts[3].strip()
        fix = parts[4].strip() if len(parts) > 4 else ""
        extra = " | ".join(parts[4:])
        occurrences_match = re.search(r"occurrences=(\d+)", extra)
        occurrences = int(occurrences_match.group(1)) if occurrences_match else 1
        location_match = re.fullmatch(r"(.+):(\d+)", location)
        if not location_match:
            errors.append(f"{path.name}:{number}: bad location {location!r}")
            continue
        entries.append(
            AllowEntry(
                path=location_match.group(1),
                line=int(location_match.group(2)),
                rule=rule,
                literal=literal,
                reason=reason + (f" | {fix}" if fix else ""),
                occurrences=occurrences,
            )
        )
    return entries, errors


def hygiene_warnings(
    language_files: dict[str, list[StringsEntry]], referenced: set[str]
) -> list[str]:
    warnings: list[str] = []
    en_entries = language_files.get("en", [])
    zh_entries = language_files.get("zh", [])
    en_keys = {entry.key for entry in en_entries}
    zh_keys = {entry.key for entry in zh_entries}
    for label, file_entries in (("en.lproj", en_entries), ("zh-Hans.lproj", zh_entries)):
        duplicates = [key for key, count in Counter(e.key for e in file_entries).items() if count > 1]
        if duplicates:
            warnings.append(f"{label}: duplicate keys: {', '.join(sorted(duplicates))}")
        trailing = sorted({entry.key for entry in file_entries if entry.key != entry.key.strip()})
        if trailing:
            warnings.append(f"{label}: keys with leading/trailing spaces: {', '.join(repr(k) for k in trailing[:8])}")
        chinese_values = sorted(
            {entry.key for entry in file_entries if CJK.search(entry.value) and not CJK.search(entry.key)}
        )
        if chinese_values:
            warnings.append(
                f"{label}: English values that still contain Chinese: "
                + ", ".join(repr(k) for k in chinese_values[:8])
            )
    en_only = sorted(en_keys - zh_keys)
    zh_only = sorted(zh_keys - en_keys)
    if en_only:
        warnings.append(f"en.lproj keys missing from zh-Hans.lproj ({len(en_only)}): {', '.join(repr(k) for k in en_only[:8])}" + (" ..." if len(en_only) > 8 else ""))
    if zh_only:
        warnings.append(f"zh-Hans.lproj keys missing from en.lproj ({len(zh_only)}): {', '.join(repr(k) for k in zh_only[:8])}")
    dead = sorted(key for key in en_keys if key not in referenced)
    if dead:
        warnings.append(f"en.lproj keys no source literal references ({len(dead)}): {', '.join(repr(k) for k in dead[:8])}" + (" ..." if len(dead) > 8 else ""))
    # Placeholder mismatch between the two languages.
    en_by_key = {entry.key: entry.value for entry in en_entries}
    zh_by_key = {entry.key: entry.value for entry in zh_entries}
    mismatched = []
    for key in sorted(en_keys & zh_keys):
        en_specs = FORMAT_SPEC_DETAIL.findall(en_by_key[key])
        zh_specs = FORMAT_SPEC_DETAIL.findall(zh_by_key[key])
        if en_specs != zh_specs:
            mismatched.append(key)
    if mismatched:
        warnings.append(
            f"format placeholders differ between en and zh ({len(mismatched)}): "
            + ", ".join(repr(k) for k in mismatched[:8])
        )
    return warnings


BRIDGE_ROLES = {
    "bridge/src/main.rs": "player bridge (jidr-swiftui-bridge)",
    "bridge/src/bin/jidr-center-bridge.rs": "center bridge (jidr-center-bridge)",
    "bridge/src/bin/jidr-offline-copy.rs": "offline copy helper (no user text)",
    "bridge/src/bin/jidr_center/migration_preflight.rs": "center migration preflight (no user text)",
}


def describe_sources(sources: list[Source]) -> list[str]:
    lines = []
    for source in sources:
        cjk = sum(1 for lit in source.literals if lit.depth == 0 and CJK.search(lit.text))
        short = source.rel.split("apps/jidr-swiftui/", 1)[-1]
        role = BRIDGE_ROLES.get(short)
        label = f"  {role} - {short}" if role else f"  {short}"
        lines.append(f"    {label} ({len(source.literals)} literals, {cjk} Chinese)")
    return lines


# ---------------------------------------------------------------------------
# Self-test: prove the rules catch violations without touching the app


def _sample_gate(files: dict[str, str], keys: set[str], rust: dict[str, str] | None = None, creation: set[str] | None = None) -> Gate:
    swift = [build_source(Path(rel), rel, text) for rel, text in files.items()]
    rust_sources = [build_source(Path(rel), rel, text) for rel, text in (rust or {}).items()]
    gate = Gate(swift, rust_sources, keys, creation or set())
    gate.check_accessibility_values()
    return gate


def _finding_keys(gate: Gate) -> set[tuple[str, str, str]]:
    return set(gate.grouped())


def run_self_test() -> None:
    checks = 0

    def expect(name: str, got: set, want: set) -> None:
        nonlocal checks
        checks += 1
        if got != want:
            print(f"SELF-TEST FAILED: {name}")
            print(f"  missing: {sorted(want - got)}")
            print(f"  unexpected: {sorted(got - want)}")
            raise SystemExit(1)

    keys = {"已翻译的按钮", "已翻译的标题", "已翻译的标签", "已翻译的快照", "已翻译的提示"}

    # R1: LocalizedStringKey literal / interpolated format key.
    gate = _sample_gate(
        {
            "Center/R1.swift": """
import SwiftUI
struct R1: View {
    var body: some View {
        VStack {
            Text("已翻译的按钮")
            Text("未翻译的按钮")
            Text("Root：\\(value)")
            Button(t("中文", "English")) { }
            Label(model.text("中文2", "English2"), systemImage: "x")
        }
    }
}
"""
        },
        keys,
    )
    expect(
        "R1 strings-key",
        _finding_keys(gate),
        {
            ("Center/R1.swift", "strings-key", "未翻译的按钮"),
            ("Center/R1.swift", "strings-key", "Root：%@"),
        },
    )

    # R2: AppKit string sinks, including the accessibility value bypass.
    gate = _sample_gate(
        {
            "Sources/R2.swift": """
import AppKit
func save() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "未翻译的截图.png"
    panel.prompt = model.text("选择位置", "Choose location")
    window.title = "未翻译的窗口标题"
    let image = NSImage(systemSymbolName: "x", accessibilityDescription: "未翻译的侧边栏")
    button.toolTip = "未翻译的提示"
    button.setAccessibilityLabel("未翻译的标签")
}
func a11y(status: String) {
    Text(status).accessibilityValue(status)
}
"""
        },
        keys,
    )
    expect(
        "R2 appkit sinks",
        _finding_keys(gate),
        {
            ("Sources/R2.swift", "appkit-sink", "未翻译的截图.png"),
            ("Sources/R2.swift", "appkit-sink", "未翻译的窗口标题"),
            ("Sources/R2.swift", "appkit-sink", "未翻译的侧边栏"),
            ("Sources/R2.swift", "appkit-sink", "未翻译的提示"),
            ("Sources/R2.swift", "appkit-sink", "未翻译的标签"),
            ("Sources/R2.swift", "appkit-a11y", "status"),
        },
    )

    # R3: state variables and rendered dynamic strings.
    gate = _sample_gate(
        {
            "Center/R3.swift": """
import SwiftUI
final class Model: ObservableObject {
    @Published var notice = "未翻译的初始值"
}
struct R3: View {
    @State private var qualityMessage = ""
    @State private var status = "准备中"
    var body: some View {
        VStack {
            Text(qualityMessage)
            Text(message)
            Text(status)
        }
    }
    func save() {
        qualityMessage = "未翻译的提示"
        message = t("中文", "English")
    }
}
"""
        },
        keys,
    )
    got = _finding_keys(gate)
    expect(
        "R3 dynamic-sink",
        got,
        {
            ("Center/R3.swift", "dynamic-sink", "未翻译的初始值"),
            ("Center/R3.swift", "dynamic-sink", "未翻译的提示"),
        },
    )

    # R4: error descriptions and the DeviceCreation validation map.
    gate = _sample_gate(
        {
            "Sources/R4.swift": """
import Foundation
enum Bad: LocalizedError {
    case broken
    var errorDescription: String? {
        switch self { case .broken: return "未翻译的错误。" }
    }
}
func fail() {
    throw NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "未翻译的失败"])
}
"""
        },
        keys,
    )
    expect(
        "R4 exposed-error",
        _finding_keys(gate),
        {
            ("Sources/R4.swift", "exposed-error", "未翻译的错误。"),
            ("Sources/R4.swift", "exposed-error", "未翻译的失败"),
        },
    )
    gate = _sample_gate(
        {
            "Sources/DeviceCreation.swift": """
import Foundation
struct DeviceCreation {
    func parameters() throws {
        throw Validation.invalid("已映射的校验")
        throw Validation.invalid("未映射的校验")
    }
}
"""
        },
        keys,
        creation={"已映射的校验"},
    )
    expect(
        "R4 creation validation map",
        _finding_keys(gate),
        {("Sources/DeviceCreation.swift", "exposed-error", "未映射的校验")},
    )

    # R5: player status sink, including the sentinels and localized() prefixes.
    gate = _sample_gate(
        {
            "Sources/GameWindow.swift": """
func statuses() {
    transport.onStatus?("正在连接测试设备…")
    transport.onStatus?("未翻译的状态")
    transport.onStatus?("已绑定 \\(key)")
    transport.onStatus?("连接已结束（1）")
    transport.onStatus?("准备中")
    self.transport.onStatus?(self.transport.language == 0 ? "English" : "中文")
}
"""
        },
        keys | {"正在连接测试设备…", "已绑定 "},
    )
    expect(
        "R5 player-status",
        _finding_keys(gate),
        {("Sources/GameWindow.swift", "player-status", "未翻译的状态")},
    )

    # R6: bridge diagnostics, ignoring #[cfg(test)] fixtures.
    gate = _sample_gate(
        {"Center/R6.swift": "import SwiftUI\n"},
        keys,
        rust={
            "bridge/src/main.rs": """
fn run() {
    bail!("未翻译的桥接错误");
    eprintln!("JIDR_OPERATION:{}", json!({"message": "未翻译的桥接消息"}));
    bail!("english diagnostic");
}
#[cfg(test)]
mod tests {
    fn fixture() { assert_eq!("测试中文", "测试中文"); }
}
""",
        },
    )
    expect(
        "R6 bridge-diagnostic",
        _finding_keys(gate),
        {
            ("bridge/src/main.rs", "bridge-diagnostic", "未翻译的桥接错误"),
            ("bridge/src/main.rs", "bridge-diagnostic", "未翻译的桥接消息"),
        },
    )

    # R7: bilingual helper arity/language guard.
    gate = _sample_gate(
        {
            "Center/R7.swift": """
func f() {
    let a = t("中文一")
    let b = t("中文二", "English two")
    let c = model.text("中文三", "仍然是中文")
}
"""
        },
        keys,
    )
    expect(
        "R7 bilingual-helper",
        _finding_keys(gate),
        {
            ("Center/R7.swift", "bilingual-helper", "中文一"),
            ("Center/R7.swift", "bilingual-helper", "仍然是中文"),
        },
    )

    # R8: inline language ternary with Chinese in the English branch.
    gate = _sample_gate(
        {
            "Sources/R8.swift": """
func f() {
    let ok = language == 0 ? "English" : "中文"
    let bad = language == 0 ? "中文一" : "中文二"
}
"""
        },
        keys,
    )
    bad = [k for k in _finding_keys(gate) if k[1] == "inline-ternary"]
    expect(
        "R8 inline-ternary",
        set(bad),
        {("Sources/R8.swift", "inline-ternary", "中文一")},
    )

    # Allowlist diff: an allowlisted finding is not new, an unknown one is.
    entries, errors = _allowlist_from_lines(
        [
            "Center/Sample.swift:1 | appkit-sink | 未翻译的截图.png | test entry | M2: test",
        ]
    )
    if errors:
        raise SystemExit("SELF-TEST FAILED: allowlist parser: " + "; ".join(errors))
    findings = [
        Finding("Center/Sample.swift", 1, "appkit-sink", "未翻译的截图.png", ""),
        Finding("Center/Sample.swift", 2, "appkit-sink", "新泄漏.png", ""),
    ]
    grouped = defaultdict(list)
    for finding in findings:
        grouped[finding.key()].append(finding)
    new, grown, stale, reduced = diff_findings(grouped, entries)
    checks += 1
    if [f.key() for f in new] != [("Center/Sample.swift", "appkit-sink", "新泄漏.png")]:
        raise SystemExit("SELF-TEST FAILED: allowlist diff did not isolate the new leak")
    if stale or reduced or grown:
        raise SystemExit("SELF-TEST FAILED: allowlist diff mis-split the matching entry")
    checks += 1
    # A second occurrence of an already baselined literal is a new leak too.
    grown_entries = [
        AllowEntry("Center/Sample.swift", 1, "appkit-sink", "已基线.png", "test", 1)
    ]
    grouped_grown = defaultdict(list)
    for finding in [
        Finding("Center/Sample.swift", 1, "appkit-sink", "已基线.png", ""),
        Finding("Center/Sample.swift", 9, "appkit-sink", "已基线.png", ""),
    ]:
        grouped_grown[finding.key()].append(finding)
    grown_new, grown_extra, _, _ = diff_findings(grouped_grown, grown_entries)
    checks += 1
    if grown_new or [f.line for f in grown_extra] != [9]:
        raise SystemExit("SELF-TEST FAILED: a second occurrence of a baselined literal was not flagged")
    checks += 1

    print(f"localization gate self-test passed ({checks} checks: R1-R8 + allowlist)")


def _allowlist_from_lines(lines: list[str]) -> tuple[list[AllowEntry], list[str]]:
    # Reuse the real parser by writing nothing: parse the given lines the same way.
    entries: list[AllowEntry] = []
    errors: list[str] = []
    for number, line in enumerate(lines, 1):
        parts = line.split(" | ")
        if len(parts) < 4:
            errors.append(f"line {number}: bad format")
            continue
        location, rule = parts[0].strip(), parts[1].strip()
        literal, reason = parts[2], parts[3].strip()
        match = re.fullmatch(r"(.+):(\d+)", location)
        if not match:
            errors.append(f"line {number}: bad location")
            continue
        entries.append(AllowEntry(match.group(1), int(match.group(2)), rule, literal, reason))
    return entries, errors


def diff_findings(
    grouped: dict[tuple[str, str, str], list[Finding]], entries: list[AllowEntry]
) -> tuple[list[Finding], list[Finding], list[AllowEntry], list[AllowEntry]]:
    """Split findings into new/extra-occurrence leaks and stale/reduced rows.

    A baseline row pins (path, rule, literal) and the audited number of
    occurrences. A new occurrence of an already known literal is still a new
    leak, so growing a file does not hide a copy of a baselined string.
    """
    allowed = {entry.key(): entry for entry in entries}
    new: list[Finding] = []
    grown: list[Finding] = []
    for key, findings in grouped.items():
        entry = allowed.get(key)
        if entry is None:
            new.append(findings[0])
        elif len(findings) > entry.occurrences:
            grown.extend(findings[entry.occurrences:])
    stale = [entry for entry in entries if entry.key() not in grouped]
    reduced = [
        entry
        for entry in entries
        if entry.key() in grouped and len(grouped[entry.key()]) < entry.occurrences
    ]
    return new, grown, stale, reduced


# ---------------------------------------------------------------------------
# Main


def collect_sources() -> tuple[list[Source], list[Source], list[str]]:
    swift: list[Source] = []
    rust: list[Source] = []
    missing: list[str] = []
    for sub in ("Center", "Sources", "Player"):
        folder = APP_DIR / sub
        if not folder.is_dir():
            missing.append(str(folder))
            continue
        for path in sorted(folder.glob("*.swift")):
            swift.append(build_source(path, _rel(path)))
    bridge = APP_DIR / "bridge"
    if not bridge.is_dir():
        missing.append(str(bridge))
    else:
        for path in sorted(bridge.rglob("*.rs")):
            rust.append(build_source(path, _rel(path)))
    return swift, rust, missing


def _rel(path: Path) -> str:
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Localization gate for the SwiftUI prototype")
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="run in-memory rule samples first (proves the gate catches violations)",
    )
    parser.add_argument(
        "--explain",
        action="store_true",
        help="list every finding (baselined and new) with locations and hints",
    )
    args = parser.parse_args(argv)

    if args.self_test:
        run_self_test()

    en_entries = load_strings(EN_STRINGS)
    zh_entries = load_strings(ZH_STRINGS)
    en_keys = {entry.key for entry in en_entries}
    creation_keys = creation_error_keys(APP_DIR / "Center" / "DeviceModel.swift")
    swift_sources, rust_sources, missing = collect_sources()

    gate = Gate(swift_sources, rust_sources, en_keys, creation_keys)
    gate.check_accessibility_values()
    grouped = gate.grouped()

    allow_entries, allow_errors = load_allowlist(ALLOWLIST_PATH)
    new, grown, stale, reduced = diff_findings(grouped, allow_entries)
    leaks = new + grown

    print("SwiftUI localization gate")
    print("=========================")
    def count_files(folder: str) -> str:
        n = sum(1 for s in swift_sources if f"/{folder}/" in s.rel)
        return f"{n} file" + ("" if n == 1 else "s")

    print("scanned Swift (non-test):")
    print(f"  Center/*.swift: {count_files('Center')}")
    print(f"  Sources/*.swift: {count_files('Sources')}")
    print(f"  Player/*.swift: {count_files('Player')}")
    for line in describe_sources(swift_sources):
        print(line)
    print("scanned Rust bridges:")
    for line in describe_sources(rust_sources):
        print(line)
    if not rust_sources:
        print("  (none found)")
    print(
        "mechanisms checked: "
        f"(a) .strings keys: {gate.checked['mechanism-a']} localizable literals covered; "
        f"(b) t()/model.text(): {gate.checked['mechanism-b']} bilingual calls "
        f"(t: {gate.checked['mechanism-b-t']}, text: {gate.checked['mechanism-b-text']}); "
        f"(c) inline language switch: {gate.checked['mechanism-c-all']} found "
        f"({gate.checked['mechanism-c-copy']} copy switches, "
        f"{gate.checked['mechanism-c-locale']} locale identifiers, "
        f"{gate.checked['mechanism-c-helper']} internal helpers)"
    )
    print(
        "checks: "
        f"player status strings covered: {gate.checked['player-status-covered']}; "
        f"DeviceCreation validation messages mapped: {gate.checked['creation-validation']}"
    )
    print()
    rule_counts = Counter(finding.rule for finding in gate.findings)
    for rule in (
        "strings-key",
        "appkit-sink",
        "appkit-a11y",
        "dynamic-sink",
        "exposed-error",
        "player-status",
        "bridge-diagnostic",
        "bilingual-helper",
        "inline-ternary",
    ):
        if rule_counts.get(rule):
            print(f"  {rule:<18} {rule_counts[rule]} finding(s)")
    print(f"baseline allowlist: {len(allow_entries)} entries (known M0 gaps, see i18n_allowlist.txt)")
    print(f"findings: {len(grouped)} distinct, {len(gate.findings)} occurrences; "
          f"new leaks: {len(leaks)} ({len(new)} new, {len(grown)} extra occurrences); "
          f"stale allowlist entries: {len(stale)}")
    print()

    if args.explain:
        allowed = {entry.key() for entry in allow_entries}
        for key, findings in sorted(grouped.items()):
            marker = "BASELINE" if key in allowed else "NEW"
            for line in format_findings(findings, marker):
                print(line)
        print()

    warnings: list[str] = []
    entries_by_file = {
        "en": en_entries,
        "zh": zh_entries,
    }
    referenced = gate.referenced_literals | gate.referenced_format_keys
    warnings.extend(hygiene_warnings(entries_by_file, referenced))
    if missing:
        warnings.append("missing source directories: " + ", ".join(missing))
    if allow_errors:
        warnings.extend("allowlist: " + error for error in allow_errors)
    if reduced:
        warnings.append(
            "allowlist rows now have fewer occurrences than pinned (M2 fixed part of a leak): "
            + ", ".join(f"{entry.path}:{entry.line}" for entry in reduced[:8])
        )
    if warnings:
        print("warnings (non-blocking):")
        for warning in warnings:
            print(f"  - {warning}")
        print()

    if leaks:
        print(f"FAIL: {len(leaks)} Chinese UI string occurrence(s) are not localized in English mode")
        for line in format_findings(new, "NEW"):
            print(line)
        for line in format_findings(grown, "NEW (extra occurrence)"):
            print(line)
        print("Add an en.lproj entry / t() counterpart, or baseline the known gap in")
        print("apps/jidr-swiftui/Tests/i18n_allowlist.txt with a reason and M2 fix.")
        return 1

    if allow_errors:
        print("FAIL: localization allowlist is malformed")
        return 1

    print("Result: PASS (no new English-mode localization leaks)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
