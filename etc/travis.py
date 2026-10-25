#!/usr/bin/env python3

import subprocess
import sys
from pathlib import Path


def main():
    repository_root = Path(__file__).resolve().parent.parent
    checks = [
        ["npm", "test"],
        [sys.executable, "-m", "pre_commit", "run", "--all-files"],
        [
            sys.executable,
            "-m",
            "pre_commit",
            "run",
            "--hook-stage",
            "pre-push",
            "--all-files",
        ],
        ["bash", "etc/checkArmTemplates.sh", "SelfTest"],
    ]
    failed = False
    for command in checks:
        try:
            result = subprocess.run(command, cwd=repository_root, check=False)
        except OSError as error:
            print(f"Could not run offline validation: {error}", file=sys.stderr)
            return 1
        if result.returncode != 0:
            failed = True
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(main())
