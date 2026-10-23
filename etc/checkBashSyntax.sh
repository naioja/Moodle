#!/usr/bin/env bash
set -euo pipefail

for script_path in "$@"; do
    bash -n "$script_path"
done
