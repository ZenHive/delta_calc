#!/usr/bin/env python3
"""Render repository-pinned instruction imports; never consult host defaults."""

import argparse
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
INCLUDES = ROOT / "agent-instructions" / "includes"
IMPORT = re.compile(r"^@([^\s]+)\s*$")
HEADER = "<!-- Auto-generated from CLAUDE.md by scripts/sync-agents-md.py — do not edit manually -->\n\n"


def render(path, replacements, stack=()):
    """Expand root-relative imports, refusing missing or external sources."""
    path = path.resolve()
    if not path.is_relative_to(ROOT):
        raise ValueError(f"Import outside repository: {path}")
    if path in stack or len(stack) >= 5:
        raise ValueError(f"Cyclic import or depth exceeded: {path}")
    content = replacements[path] if path in replacements else path.read_text(encoding="utf-8")
    output = []
    for line in content.splitlines():
        match = IMPORT.fullmatch(line)
        if match:
            name = match[1]
            output.append(f"<!-- @-import: {name} -->\n")
            output.append(render(ROOT / name, replacements, (*stack, path)))
            output.append("\n")
        else:
            output.append(line + "\n")
    return "".join(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--check", action="store_true", help="fail if AGENTS.md is stale or missing")
    modes.add_argument("--dry-run", action="store_true", help="print without writing")
    modes.add_argument(
        "--refresh-includes", type=Path, metavar="SOURCE",
        help="intentionally replace pinned includes from SOURCE and regenerate",
    )
    args = parser.parse_args()
    try:
        replacements = {}
        if args.refresh_includes is not None:
            source = args.refresh_includes.resolve(strict=True)
            # Read every candidate and validate the expansion before changing any file.
            replacements = {
                path.resolve(): (source / path.name).read_text(encoding="utf-8")
                for path in sorted(INCLUDES.glob("*.md"))
            }
            if not replacements:
                raise ValueError("No pinned includes to refresh")
        output = HEADER + render(ROOT / "CLAUDE.md", replacements)
        target = ROOT / "AGENTS.md"
        if args.check:
            if not target.exists() or target.read_bytes() != output.encode():
                print("STALE: AGENTS.md — run python3 scripts/sync-agents-md.py", file=sys.stderr)
                return 1
            print("OK: AGENTS.md is up to date")
        elif args.dry_run:
            sys.stdout.write(output)
        else:
            for path, content in replacements.items():
                path.write_text(content, encoding="utf-8")
            target.write_text(output, encoding="utf-8")
            print("Wrote AGENTS.md")
    except (OSError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
