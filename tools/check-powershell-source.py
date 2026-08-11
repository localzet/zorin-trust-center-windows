#!/usr/bin/env python3
"""Статическая проверка PowerShell-исходников для Windows PowerShell 5.1.

Это не замена штатному Parser::ParseFile на Windows. Проверка нужна в Linux
build-среде, чтобы до упаковки ловить уже встречавшиеся регрессии форматирования.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


LEADING_PIPE = re.compile(r"^\s*\|")
SEPARATED_ARRAY_TOKEN = re.compile(r"@\s+[({]")


def iter_scripts(root: Path):
    if root.is_file() and root.suffix.lower() == ".ps1":
        yield root
        return

    yield from root.rglob("*.ps1")


def check_file(path: Path) -> list[str]:
    errors: list[str] = []
    text = path.read_text(encoding="utf-8-sig")

    for line_number, line in enumerate(text.splitlines(), 1):
        if LEADING_PIPE.match(line):
            errors.append(
                f"{path}:{line_number}: pipeline operator starts a new line; "
                "Windows PowerShell 5.1 rejects this form"
            )

        if SEPARATED_ARRAY_TOKEN.search(line):
            errors.append(
                f"{path}:{line_number}: '@' token is separated from '{{' or '('"
            )

        if line.rstrip().endswith("`") and not line.endswith("`"):
            errors.append(
                f"{path}:{line_number}: whitespace follows a PowerShell continuation backtick"
            )

    return errors


def main(argv: list[str]) -> int:
    roots = [Path(value).resolve() for value in argv[1:]] or [Path.cwd()]
    errors: list[str] = []

    for root in roots:
        for script in sorted(iter_scripts(root)):
            errors.extend(check_file(script))

    if errors:
        print("PowerShell source compatibility check failed:", file=sys.stderr)
        for error in errors:
            print(f"  {error}", file=sys.stderr)
        return 1

    print("PowerShell source compatibility check passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
