#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
manifest="$script_directory/toolchain.json"
installation_root="${1:-$HOME/.local/share/moodle-loadtest}"
cache_directory="${JMETER_CACHE:-$script_directory/../.cache/loadtest-artifacts}"
jmeter_version="$(jq -er '.jmeterVersion' "$manifest")"
jmeter_home="$installation_root/apache-jmeter-$jmeter_version"
java_version="$(java -version 2>&1 | sed -n '1s/.*version "\([0-9]*\).*/\1/p')"
minimum_java_version="$(jq -er '.minimumJavaVersion' "$manifest")"
if [[ ! "$java_version" =~ ^[0-9]+$ || "$java_version" -lt "$minimum_java_version" ]]; then
    printf 'Install a maintained JDK %s or newer before installing JMeter.\n' "$minimum_java_version" >&2
    exit 1
fi

mkdir -p "$installation_root" "$cache_directory"
while IFS=$'\t' read -r artifact_file artifact_url algorithm digest destination; do
    artifact_path="$cache_directory/$artifact_file"
    if [[ ! -f "$artifact_path" ]]; then
        curl --fail --silent --show-error --location --proto '=https' \
            "$artifact_url" -o "$artifact_path.download"
        mv "$artifact_path.download" "$artifact_path"
    fi
    case "$algorithm" in
    sha256) printf '%s  %s\n' "$digest" "$artifact_path" | sha256sum --check --status ;;
    sha512) printf '%s  %s\n' "$digest" "$artifact_path" | sha512sum --check --status ;;
    *)
        printf 'Unsupported artifact digest algorithm: %s\n' "$algorithm" >&2
        exit 1
        ;;
    esac
    if [[ "$destination" == archive ]]; then
        if [[ ! -x "$jmeter_home/bin/jmeter" ]]; then
            tar -xzf "$artifact_path" -C "$installation_root"
        fi
    else
        install -m 0644 "$artifact_path" "$jmeter_home/$destination/$artifact_file"
    fi
done < <(jq -er '.artifacts[] | [.file, .url, .algorithm, .digest, .destination] | @tsv' "$manifest")

java -cp "$jmeter_home/lib/ext/jmeter-plugins-manager-2.0.jar" org.jmeterplugins.repository.PluginManagerCMDInstaller
"$jmeter_home/bin/jmeter" --version
mkdir -p "$HOME/bin"
ln -sfn "$(cd -- "$jmeter_home/bin" && pwd)/jmeter" "$HOME/bin/jmeter"
printf 'JMeter is installed at %s\n' "$jmeter_home"
