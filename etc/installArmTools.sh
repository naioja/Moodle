#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="$repository_root/etc/arm-toolchain.json"
tool_directory="$repository_root/.cache/arm-tools"
mkdir -p "$tool_directory"

if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 ]]; then
    printf 'The pinned bootstrap currently supports Linux x86_64 only.\n' >&2
    exit 1
fi

powershell_archive="$tool_directory/powershell.tar.gz"
powershell_checksum="$(jq -er '.powershell.sha256' "$manifest")"
if [[ ! -f "$powershell_archive" ]]; then
    curl --fail --silent --show-error --location --proto '=https' \
        "$(jq -er '.powershell.url' "$manifest")" -o "$powershell_archive"
fi
printf '%s  %s\n' "$powershell_checksum" "$powershell_archive" | sha256sum --check --status
if [[ ! -x "$tool_directory/powershell/pwsh" ]]; then
    mkdir -p "$tool_directory/powershell"
    tar -xzf "$powershell_archive" -C "$tool_directory/powershell"
    chmod +x "$tool_directory/powershell/pwsh"
fi

ttk_commit="$(jq -er '.armTtk.commit' "$manifest")"
ttk_directory="$tool_directory/arm-ttk-$ttk_commit"
if [[ ! -f "$tool_directory/arm-ttk.tar.gz" ]]; then
    curl --fail --silent --show-error --location --proto '=https' \
        "$(jq -er '.armTtk.url' "$manifest")" -o "$tool_directory/arm-ttk.tar.gz"
fi
printf '%s  %s\n' "$(jq -er '.armTtk.sha256' "$manifest")" "$tool_directory/arm-ttk.tar.gz" | sha256sum --check --status
if [[ ! -f "$ttk_directory/arm-ttk/arm-ttk.psd1" ]]; then
    tar -xzf "$tool_directory/arm-ttk.tar.gz" -C "$tool_directory"
fi

export POWERSHELL_TELEMETRY_OPTOUT=1
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export XDG_CACHE_HOME="$tool_directory/cache"
export XDG_CONFIG_HOME="$tool_directory/config"
export ARM_MODULE_CACHE="$tool_directory/modules"
ARM_PSRULE_VERSION="$(jq -er '.psRuleAzure.version' "$manifest")"
ARM_PSRULE_CORE_VERSION="$(jq -er '.psRule.version' "$manifest")"
export ARM_PSRULE_VERSION ARM_PSRULE_CORE_VERSION
export PSModulePath="$ARM_MODULE_CACHE${PSModulePath:+:$PSModulePath}"
mkdir -p "$ARM_MODULE_CACHE" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME"

"$tool_directory/powershell/pwsh" -NoLogo -NoProfile -NonInteractive -Command "
\$ErrorActionPreference = 'Stop'
\$corePath = Join-Path \$env:ARM_MODULE_CACHE \"PSRule/\$env:ARM_PSRULE_CORE_VERSION/PSRule.psd1\"
if (!(Test-Path \$corePath)) {
    Save-PSResource -Name 'PSRule' -Version \$env:ARM_PSRULE_CORE_VERSION -Repository PSGallery -Path \$env:ARM_MODULE_CACHE -TrustRepository -SkipDependencyCheck
}
\$modulePath = Join-Path \$env:ARM_MODULE_CACHE \"PSRule.Rules.Azure/\$env:ARM_PSRULE_VERSION/PSRule.Rules.Azure.psd1\"
if (!(Test-Path \$modulePath)) {
    Save-PSResource -Name 'PSRule.Rules.Azure' -Version \$env:ARM_PSRULE_VERSION -Repository PSGallery -Path \$env:ARM_MODULE_CACHE -TrustRepository -SkipDependencyCheck
}
Import-Module \$corePath -ErrorAction Stop
Import-Module \$modulePath -ErrorAction Stop
Get-Module PSRule.Rules.Azure, PSRule | Select-Object Name, Version
"

"$tool_directory/powershell/pwsh" -NoLogo -NoProfile -NonInteractive \
    -File "$repository_root/etc/checkArmTemplates.ps1" -Mode FetchSchemas

printf 'Native ARM tools are ready in %s\n' "$tool_directory"
