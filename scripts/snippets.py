#!/usr/bin/env python3
"""Keep the example blocks in the guides byte-identical to the files under examples/.

A page carries `<!-- include: <path>[#region] -->` ... `<!-- /include -->` and
this script owns the fenced block between them. A region is the lines between
`# region: <name>` and `# endregion: <name>` (`//` works too), markers excluded.

--check exits 1 naming every block that differs, every missing file or region,
every include path outside examples/, every code block outside an include
marker, every malformed or nested marker, and every file under examples/ that
no page includes and NOT_SHOWN does not list. --write rewrites the blocks in
place and exits 1 on every problem it cannot repair.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path, PurePosixPath

# --root replaces it, so tests can run the script against a scratch tree.
ROOT = Path(__file__).resolve().parent.parent

# Pages that may carry include markers.
PAGES = ("README.md", "CONTRIBUTING.md", "docs/*.md")

# Files under examples/ that exist for the examples to work but are never shown.
NOT_SHOWN = frozenset(
    {
        "examples/monitoring/full/prometheus/rules/.gitkeep",
        "examples/monitoring/full/grafana/dashboards/.gitkeep",
    }
)

LANGUAGES = {
    ".yaml": "yaml",
    ".yml": "yaml",
    ".json": "json",
    ".sh": "sh",
    ".alloy": "alloy",
    ".conf": "nginx",
    ".txt": "text",
    "Caddyfile": "caddyfile",
}

OPEN = re.compile(r"^<!-- include: (?P<path>[^#\s]+)(?:#(?P<region>[\w-]+))? -->$")
CLOSE = "<!-- /include -->"
MARKER_PREFIX = "<!-- include"
REGION = re.compile(r"^\s*(?:#|//) (?P<kind>region|endregion): (?P<name>[\w-]+)\s*$")
# A CommonMark fence opener: up to three spaces, then three or more backticks or tildes.
FENCE = re.compile(r"^ {0,3}(?P<fence>`{3,}|~{3,})")


def language(path: str) -> str:
    name = Path(path).name
    if name in LANGUAGES:
        return LANGUAGES[name]
    return LANGUAGES.get(Path(path).suffix, "text")


def region_text(text: str, name: str) -> str | None:
    """Return the lines between the region's markers, or None when absent."""
    lines = text.splitlines(keepends=True)
    start = end = None
    for i, line in enumerate(lines):
        m = REGION.match(line)
        if not m or m["name"] != name:
            continue
        if m["kind"] == "region" and start is None:
            start = i + 1
        elif m["kind"] == "endregion" and start is not None:
            end = i
            break
    if start is None or end is None:
        return None
    return "".join(lines[start:end])


def render(path: str, body: str) -> list[str]:
    """The lines a marker owns: blank, fence, body, fence, blank."""
    fence = "```"
    while fence in body:
        fence += "`"
    if not body.endswith("\n"):
        body += "\n"
    return ["", fence + language(path), *body.splitlines(), fence, ""]


def confined(path: str) -> bool:
    """True when path is a relative POSIX path that stays under ROOT/examples."""
    parts = PurePosixPath(path).parts
    if "\\" in path or not parts or parts[0] != "examples" or any(p in (".", "..") for p in parts):
        return False
    return (ROOT / path).resolve().is_relative_to((ROOT / "examples").resolve())


def source(path: str, region: str | None) -> tuple[str | None, str]:
    """Return (body, problem). Body is None when the file or region is missing."""
    if not confined(path):
        return None, f"include path is not a file under examples/: {path}"
    file = ROOT / path
    if not file.is_file():
        return None, f"file not found: {path}"
    text = file.read_text(encoding="utf-8")
    if region is None:
        return text, ""
    body = region_text(text, region)
    if body is None:
        return None, f"region not found: {path}#{region}"
    return body, ""


def fence_end(lines: list[str], start: int, fence: str) -> int:
    """Index of the line after the fence that closes the block opened at lines[start]."""
    closer = re.compile(rf"^ {{0,3}}{re.escape(fence[0])}{{{len(fence)},}}\s*$")
    for j in range(start + 1, len(lines)):
        if closer.match(lines[j]):
            return j + 1
    return len(lines)


def process(page: Path, write: bool, shown: set[str]) -> list[str]:
    """Check or rewrite one page. Return its problems."""
    rel = page.relative_to(ROOT).as_posix()
    lines = page.read_text(encoding="utf-8").splitlines()
    out: list[str] = []
    problems: list[str] = []
    i = 0
    while i < len(lines):
        line = lines[i]
        m = OPEN.match(line)
        if not m:
            if line.startswith(MARKER_PREFIX):
                problems.append(f"{rel}:{i + 1}: malformed include marker")
            elif line.strip() == CLOSE:
                problems.append(f"{rel}:{i + 1}: {CLOSE} with no include marker before it")
            fence = FENCE.match(line)
            if fence:
                # Every code block must come from a file, or the page and the tests can drift.
                problems.append(f"{rel}:{i + 1}: code block outside an include marker, move it to a file under examples/")
                end = fence_end(lines, i, fence["fence"])
                out.extend(lines[i:end])
                i = end
                continue
            out.append(line)
            i += 1
            continue
        out.append(line)
        i += 1
        try:
            close = lines.index(CLOSE, i)
        except ValueError:
            problems.append(f"{rel}:{i}: include marker has no {CLOSE}")
            out.extend(lines[i:])
            break
        current = lines[i:close]
        nested = next((j for j in range(i, close) if lines[j].startswith(MARKER_PREFIX)), None)
        path, region = m["path"], m["region"]
        shown.add(path)
        body, problem = source(path, region)
        if nested is not None:
            problems.append(f"{rel}:{nested + 1}: include marker inside another include block")
            out.extend(current)
        elif body is None:
            problems.append(f"{rel}:{i}: {problem}")
            out.extend(current)
        else:
            wanted = render(path, body)
            if current != wanted and not write:
                target = f"{path}#{region}" if region else path
                problems.append(f"{rel}:{i}: block differs from {target}")
            out.extend(wanted if write else current)
        out.append(CLOSE)
        i = close + 1
    if write:
        page.write_text("\n".join(out) + "\n", encoding="utf-8")
    return problems


def orphans(shown: set[str]) -> list[str]:
    """Files under examples/ that no page shows and NOT_SHOWN does not list."""
    found = []
    for file in sorted((ROOT / "examples").rglob("*")):
        if not file.is_file():
            continue
        rel = file.relative_to(ROOT).as_posix()
        if rel not in shown and rel not in NOT_SHOWN:
            found.append(f"{rel}: no page includes it and it is not in NOT_SHOWN")
    return found


def main() -> int:
    global ROOT
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true", help="report drift, change nothing")
    mode.add_argument("--write", action="store_true", help="rewrite every include block")
    parser.add_argument("--root", type=Path, default=ROOT, help="repository root (default: this script's repository)")
    args = parser.parse_args()
    ROOT = args.root.resolve()

    shown: set[str] = set()
    problems: list[str] = []
    for pattern in PAGES:
        for page in sorted(ROOT.glob(pattern)):
            problems += process(page, args.write, shown)
    if (ROOT / "examples").is_dir():
        problems += orphans(shown)

    for problem in problems:
        print(problem, file=sys.stderr)
    if problems:
        if args.check:
            print("Run python3 scripts/snippets.py --write after editing a file under examples/.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
