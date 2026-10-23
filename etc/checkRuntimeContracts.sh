#!/usr/bin/env bash
set -euo pipefail

repository_root="${1:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"

assert_json() {
    local template_path="$1"
    local expression="$2"
    if ! jq -e "$expression" "$repository_root/$template_path" > /dev/null; then
        printf 'FAIL: runtime contract in %s\n' "$template_path" >&2
        return 1
    fi
}

assert_json azuredeploy.json '
    .parameters |
    .moodleVersion.defaultValue == "MOODLE_503_STABLE" and
    .moodleVersion.allowedValues == ["MOODLE_503_STABLE"] and
    .phpVersion.defaultValue == "8.3" and
    .ubuntuVersion.defaultValue == "24_04-lts-gen2" and
    .controllerVmSku.defaultValue == "Standard_D4ds_v5" and
    .autoscaleVmSku.defaultValue == "Standard_D2ds_v5" and
    .fileServerVmSku.defaultValue == "Standard_D2ds_v5" and
    .elasticVmSku.defaultValue == "Standard_D2ds_v5" and
    .enableAccelNwForCtlrVmSwitch.defaultValue == true and
    .enableAccelNwForOtherVmsSwitch.defaultValue == true
'

for preset_name in minimal small2mid-noha large-ha maximal; do
    frontend_size="Standard_D2ds_v5"
    if [[ "$preset_name" == large-ha || "$preset_name" == maximal ]]; then
        frontend_size="Standard_D4ds_v5"
    fi
    assert_json "azuredeploy-$preset_name.json" "
        .resources[0].properties.parameters |
        (.autoscaleVmSku.value // \"Standard_D2ds_v5\") == \"$frontend_size\" and
        (.controllerVmSku.value // \"Standard_D4ds_v5\") == \"Standard_D4ds_v5\" and
        (if has(\"enableAccelNwForCtlrVmSwitch\") then .enableAccelNwForCtlrVmSwitch.value else true end) == true and
        (if has(\"enableAccelNwForOtherVmsSwitch\") then .enableAccelNwForOtherVmsSwitch.value else true end) == true
    "
done

assert_json migration/azuredeploy-migration.json '
    .parameters.moodleVersion.defaultValue == "MOODLE_503_STABLE" and
    .parameters.moodleVersion.allowedValues == ["MOODLE_503_STABLE"] and
    .parameters.autoscaleVmSku.defaultValue == "Standard_D2ds_v5" and
    .resources[0].properties.parameters.controllerVmSku.value == "Standard_D4ds_v5" and
    .resources[0].properties.parameters.enableAccelNwForOtherVmsSwitch.value == true
'

assert_json managedApplication/parameters-template.json '
    .autoscaleVmSku.value == "Standard_D2ds_v5"
'

for template_path in nested/nfs-ha.json nested/nfs-ha-vm.json; do
    assert_json "$template_path" '
        .parameters.vmSku.defaultValue == "Standard_D2ds_v5" and
        .parameters.enableAccelNwSwitch.defaultValue == true
    '
done

assert_json azuredeploy.json "
    .parameters.dbServerType.defaultValue == \"mysqlflex\" and
    .parameters.mysqlflexVersion.defaultValue == \"8.4\" and
    .parameters.mysqlflexVersion.allowedValues == [\"8.4\"] and
    .variables.moodleCommon.mysqlflexVersion == \"[parameters('mysqlflexVersion')]\" and
    (.parameters.dbServerType.allowedValues | index(\"mysql\") == null) and
    (.parameters.fileServerType.allowedValues | index(\"gluster\") == null) and
    (.parameters | has(\"tikaService\") | not)
"

assert_json nested/db-mysqlflex.json "
    .resources[0].type == \"Microsoft.DBforMySQL/flexibleServers\" and
    .resources[0].apiVersion == \"2025-06-01-preview\" and
    .resources[0].properties.version == \"[parameters('moodleCommon').mysqlflexVersion]\" and
    .resources[0].properties.createMode == \"Default\" and
    (.resources[0].properties | has(\"storage\") and has(\"backup\") and (has(\"Storage\") | not) and (has(\"Backup\") | not)) and
    (.resources[0].properties.storage | has(\"autoGrow\")) and
    .variables.vnetNetworkData.publicNetworkAccess == \"Disabled\" and
    .variables.publicNetworkData.publicNetworkAccess == \"Enabled\"
"

assert_json migration/azuredeploy-migration.json "
    .parameters.dbServerType.defaultValue == \"mysqlflex\" and
    (.parameters.dbServerType.allowedValues | index(\"mysqlflex\") != null) and
    .parameters.mysqlflexVersion.defaultValue == \"8.4\" and
    .parameters.mysqlflexVersion.allowedValues == [\"8.4\"] and
    (.parameters | has(\"mysqlVersion\") | not) and
    (.parameters.dbServerType.allowedValues | index(\"mysql\") == null) and
    .resources[0].properties.parameters.postgresVersion.value == \"18\" and
    .resources[0].properties.parameters.mysqlflexVersion.value == \"[parameters('mysqlflexVersion')]\"
"

assert_json managedApplication/parameters-template.json '.dbServerType.value == "mysqlflex"'

assert_json azuredeploy.json '
    .parameters.postgresVersion.defaultValue == "18" and
    .parameters.postgresVersion.allowedValues == ["18"] and
    .parameters.postgresStorageSizeGiB.defaultValue >= 32
'
assert_json nested/db-postgres.json '
    .resources[0].type == "Microsoft.DBforPostgreSQL/flexibleServers" and
    .resources[0].apiVersion == "2025-08-01" and
    .resources[0].properties.backup.backupRetentionDays == 35
'
for retired_path in nested/db-mysql.json nested/tika.json nested/tikaconfig.json nested/gluster.json nested/glustervm.json nested/glustervmsetup.json scripts/install_tika.sh scripts/install_gluster.sh; do
    [[ ! -e "$repository_root/$retired_path" ]]
done
storage_type_helper="$(sed -n '/^function check_fileServerType_param$/,/^}/p' "$repository_root/scripts/helper_functions.sh")"
[[ -n "$storage_type_helper" ]]
if printf '%s\n%s\n' "$storage_type_helper" 'check_fileServerType_param gluster' | bash > /dev/null; then
    printf 'FAIL: removed Gluster storage type was accepted\n' >&2
    false
fi

assert_json nested/storageAccount.json "
    .resources[0].kind == \"StorageV2\" and
    .resources[1].kind == \"[if(equals(parameters('moodleCommon').storageAccountType, 'Premium_LRS'), 'FileStorage', 'StorageV2')]\"
"
assert_json nested/webvmss.json '
    all(.resources[] | select(.type == "Microsoft.Storage/storageAccounts"); .kind == "StorageV2")
'

unzip_helper="$(sed -n '/^function get_moodle_unzip_dir_from_moodle_version {/,/^}/p' "$repository_root/scripts/helper_functions.sh")"
[[ -n "$unzip_helper" ]]
unzip_directory="$(printf '%s\n%s\n' "$unzip_helper" 'get_moodle_unzip_dir_from_moodle_version MOODLE_503_STABLE' | bash)"
[[ "$unzip_directory" == moodle-MOODLE_503_STABLE ]]
grep -Fq "\"https://github.com/moodle/moodle/archive/\${moodleVersion}.zip\"" "$repository_root/scripts/install_moodle.sh"
grep -Fq 'Default: MOODLE_503_STABLE' "$repository_root/docs/Parameters.md"

assert_text() {
    local content="$1"
    local expected_text="$2"
    if ! grep -Fq -- "$expected_text" <<< "$content"; then
        printf 'FAIL: missing generated configuration: %s\n' "$expected_text" >&2
        return 1
    fi
}

site_template() {
    local source_path="$1"
    local server_type="$2"
    awk -v server_type="$server_type" '
        index($0, "cat <<EOF") && index($0, "/etc/" server_type "/sites-enabled/") { active = 1; next }
        active && $0 == "EOF" { active = 0; next }
        active { print }
    ' "$source_path"
}

render_site_template() {
    local template_content="$1"
    local document_root="$2"
    printf '%s\n' \
        "set -eu" \
        "htmlRootDir=$document_root" \
        "siteFQDN=runtime-contract.invalid" \
        "PhpVer=8.3" \
        'cat <<RUNTIME_CONFIG' \
        "$template_content" \
        'RUNTIME_CONFIG' | bash
}

web_root_setup="$(awk '
    /^  htmlRootDir="\/moodle\/html\/moodle"/ { active = 1 }
    active && /^  if \[ "\$httpsTermination"/ { exit }
    active { print }
' "$repository_root/scripts/setup_webserver.sh")"
[[ -n "$web_root_setup" ]]

stubbed_commands="$(cat <<'STUBS'
set -euo pipefail
mkdir() { :; }
chown() { :; }
sync() { :; }
setup_html_local_copy_cron_job() { :; }
az() { printf 'fixture-sas'; }
date() { printf '2030-01-01T00:00:00Z'; }
rsync() {
    [[ "$2" == /moodle/html/moodle/ && "$3" == /var/www/html/moodle/ ]]
}
azcopy() {
    [[ "$5" == /var/www/html/moodle ]]
}
STUBS
)"

frontend_nginx="$(site_template "$repository_root/scripts/setup_webserver.sh" nginx)"
frontend_apache="$(site_template "$repository_root/scripts/setup_webserver.sh" apache2)"
controller_nginx="$(site_template "$repository_root/scripts/install_moodle.sh" nginx)"
[[ -n "$frontend_nginx" && -n "$frontend_apache" && -n "$controller_nginx" ]]

for local_copy in false true; do
    expected_root=/moodle/html/moodle/public
    if [[ "$local_copy" == true ]]; then
        expected_root=/var/www/html/moodle/public
    fi
    for storage_backend in azurefiles nfs nfs-ha nfs-byo; do
        actual_root="$(printf '%s\n%s\n%s\n' \
            "$stubbed_commands" "$web_root_setup" "printf '%s' \"\$htmlRootDir\"" |
            env htmlLocalCopySwitch="$local_copy" fileServerType="$storage_backend" \
                storageAccountName=fixtureaccount storageAccountKey=fixture-key bash)"
        [[ "$actual_root" == "$expected_root" ]]
    done

    rendered_nginx="$(render_site_template "$frontend_nginx" "$expected_root")"
    rendered_apache="$(render_site_template "$frontend_apache" "$expected_root")"
    [[ "$(grep -Fc "root $expected_root;" <<< "$rendered_nginx")" -eq 2 ]]
    assert_text "$rendered_nginx" "try_files \$uri \$uri/ /r.php\$is_args\$args;"
    assert_text "$rendered_nginx" "fastcgi_param PATH_INFO \$fastcgi_path_info;"
    assert_text "$rendered_nginx" 'rewrite ^ /r.php last;'
    assert_text "$rendered_apache" "DocumentRoot $expected_root"
    assert_text "$rendered_apache" "<Directory $expected_root>"
    assert_text "$rendered_apache" 'FallbackResource /r.php'
    assert_text "$rendered_apache" 'AcceptPathInfo On'
done

rendered_controller="$(render_site_template "$controller_nginx" /moodle/html/moodle/public)"
[[ "$(grep -Fc 'root /moodle/html/moodle/public;' <<< "$rendered_controller")" -eq 2 ]]
assert_text "$rendered_controller" "try_files \$uri \$uri/ /r.php\$is_args\$args;"
assert_text "$rendered_controller" "fastcgi_param PATH_INFO \$fastcgi_path_info;"

for plugin_path in admin/tool/policy admin/tool/dataprivacy search/engine/elastic local/aws search/engine/azure admin/tool/objectfs local/azure_storage; do
    grep -Fq "/moodle/html/moodle/public/$plugin_path" "$repository_root/scripts/install_moodle.sh"
done
grep -Fq '/moodle/html/moodle/public/search/cli/indexer.php' "$repository_root/scripts/install_moodle.sh"
grep -Fq '/moodle/html/moodle/admin/cli/install.php' "$repository_root/scripts/install_moodle.sh"
grep -Fq '/moodle/html/moodle/admin/cli/cron.php' "$repository_root/scripts/install_moodle.sh"
if grep -Eq 'root /moodle/html/moodle;|/moodle/html/moodle/public/admin/cli/(install|cron)\.php' "$repository_root/scripts/install_moodle.sh"; then
    printf 'FAIL: private web root or relocated top-level CLI entrypoint\n' >&2
    false
fi

printf 'PASS: Gen2 VM, Moodle archive, MySQL 8.4, public web roots, routing and plugin contracts\n'