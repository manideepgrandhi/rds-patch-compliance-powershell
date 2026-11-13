#!/usr/bin/env python3
"""Write GitHub release notes for a version tag (stdout, or a file if given)."""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


def changelog_section(changelog: Path, ver: str) -> str:
    section_lines: list[str] = []
    in_sec = False
    for line in changelog.read_text(encoding="utf-8").splitlines():
        m = re.match(r"^##\s+[vV]?(\d+\.\d+\.\d+)\s*$", line.strip())
        if m:
            if m.group(1) == ver:
                in_sec = True
                section_lines.append(line)
                continue
            if in_sec:
                break
        elif in_sec:
            section_lines.append(line)
    return "\n".join(section_lines).strip()


def render(tag: str, repo: str, name: str, changelog: Path) -> str:
    ver = tag.lstrip("vV")
    base = f"https://github.com/{repo}/releases/latest/download"
    changelog_url = f"https://github.com/{repo}/blob/{tag}/CHANGELOG.md"
    linux = (
        f"curl -fsSLO {base}/{name}.zip && curl -fsSLO {base}/{name}.zip.sha256 && "
        f"sha256sum -c {name}.zip.sha256 && unzip -oq {name}.zip && cd {name}"
    )
    win = "\n".join(
        [
            f"$N = '{name}'",
            f"$base = '{base}'",
            'Invoke-WebRequest -Uri "$base/$N.zip" -OutFile "$N.zip"',
            'Invoke-WebRequest -Uri "$base/$N.zip.sha256" -OutFile "$N.zip.sha256"',
            '$expected = (Get-Content -Raw "$N.zip.sha256").Split()[0]',
            '$actual = (Get-FileHash "$N.zip" -Algorithm SHA256).Hash',
            'if ($expected -ine $actual) { throw "SHA256 mismatch" }',
            'Expand-Archive -Path "$N.zip" -DestinationPath . -Force',
            f"pwsh ./$N/Invoke-RdsPatchCompliance.ps1 -Help",
        ]
    )
    notes = (
        f"{name} {tag} (PowerShell 7 port of rds-patch-compliance).\n\n"
        f"### CloudShell / Linux\n\n"
        f"```bash\n{linux}\n```\n\n"
        f"### Windows (PowerShell)\n\n"
        f"```powershell\n{win}\n```\n\n"
        f"Changelog: {changelog_url}\n"
    )
    section = changelog_section(changelog, ver)
    if section:
        notes += f"\n{section}\n"
    return notes


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("tag", help="Version tag, e.g. v1.0.0")
    p.add_argument(
        "--repo",
        default="manideepgrandhi/rds-patch-compliance-powershell",
        help="owner/name used in download and changelog URLs",
    )
    p.add_argument(
        "--name",
        default="rds-patch-compliance-powershell",
        help="Zip / folder name",
    )
    p.add_argument(
        "--changelog",
        type=Path,
        default=Path("CHANGELOG.md"),
        help="Path to CHANGELOG.md",
    )
    p.add_argument(
        "-o",
        "--output",
        type=Path,
        help="Write notes to this file (default: stdout)",
    )
    args = p.parse_args(argv)
    if not args.changelog.is_file():
        print(f"error: missing {args.changelog}", file=sys.stderr)
        return 1
    notes = render(args.tag, args.repo, args.name, args.changelog)
    if args.output:
        args.output.write_text(notes, encoding="utf-8")
    else:
        sys.stdout.write(notes)
        if not notes.endswith("\n"):
            sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
