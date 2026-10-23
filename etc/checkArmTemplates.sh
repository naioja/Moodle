#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
powershell="$repository_root/.cache/arm-tools/powershell/pwsh"
if [[ ! -x "$powershell" ]]; then
    printf 'Native ARM tools are missing. Run bash etc/installArmTools.sh first.\n' >&2
    exit 1
fi

export POWERSHELL_TELEMETRY_OPTOUT=1
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export XDG_CACHE_HOME="$repository_root/.cache/arm-tools/cache"
export XDG_CONFIG_HOME="$repository_root/.cache/arm-tools/config"
"$powershell" -NoLogo -NoProfile -NonInteractive \
    -File "$repository_root/etc/checkArmTemplates.ps1" -Mode "${1:-Schemas}" -RepositoryRoot "$repository_root"
