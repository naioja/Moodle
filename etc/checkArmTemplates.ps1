[CmdletBinding()]
param(
    [ValidateSet('Inventory', 'Contracts', 'RefreshCatalog', 'FetchSchemas', 'Schemas', 'SelfTest', 'Fixtures', 'Ttk', 'Rules', 'All')]
    [string] $Mode = 'Contracts',
    [string] $RepositoryRoot = (Split-Path $PSScriptRoot -Parent)
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$cacheDirectory = Join-Path $RepositoryRoot '.cache/arm-tools'
$catalogPath = Join-Path $RepositoryRoot 'etc/arm-api-versions.json'
if ($Mode -notin @('Inventory', 'RefreshCatalog') -and !(Test-Path $catalogPath)) { throw 'The pinned ARM API catalog is missing.' }
if ($Mode -eq 'All') {
    $failedLayers = [Collections.Generic.List[string]]::new()
    foreach ($layer in @('Schemas', 'Ttk', 'Rules')) {
        & (Join-Path $PSHOME 'pwsh') -NoLogo -NoProfile -NonInteractive -File $PSCommandPath -Mode $layer -RepositoryRoot $RepositoryRoot
        if ($LASTEXITCODE -ne 0) { $failedLayers.Add($layer) }
    }
    if ($failedLayers.Count) { throw "ARM gates failed: $($failedLayers -join ', ')" }
    return
}
$failures = [Collections.Generic.List[string]]::new()
$templates = @{}

foreach ($relativePath in (& git -C $RepositoryRoot ls-files --cached --others --exclude-standard -- '*.json' | Sort-Object -Unique)) {
    $fullPath = Join-Path $RepositoryRoot $relativePath
    if (!(Test-Path -LiteralPath $fullPath)) { continue }
    $document = Get-Content -LiteralPath $fullPath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    if ($document -is [Collections.IDictionary] -and $document.Contains('$schema') -and $document['$schema'] -match '/deploymentTemplate\.json#?$') {
        $templates[$relativePath] = $document
    }
}
if ($templates.Count -eq 0) { throw 'No ARM deployment templates were discovered.' }

function Get-ArmResource {
    param([Collections.IDictionary] $Template, [string] $File, [string] $ParentType = '')
    if (!$Template.Contains('resources')) { return }
    $resources = $Template.resources
    if ($resources -is [Collections.IDictionary]) { $resources = @($resources.Values) }
    foreach ($resource in $resources) {
        $resourceType = [string]$resource.type
        if ($ParentType -and $resourceType -notmatch '^Microsoft\.') { $resourceType = "$ParentType/$resourceType" }
        [pscustomobject]@{ File = $File; Type = $resourceType; ApiVersion = [string]$resource.apiVersion; Resource = $resource }
        Get-ArmResource -Template $resource -File $File -ParentType $resourceType
        if ($resource.Contains('properties') -and $resource.properties.Contains('template')) {
            Get-ArmResource -Template $resource.properties.template -File $File
        }
    }
}

$inventory = @($templates.GetEnumerator() | ForEach-Object { Get-ArmResource -Template $_.Value -File $_.Key })
if ($inventory.Count -eq 0) { throw 'No ARM resources were discovered.' }

function Read-ArmApiCatalog {
    $result = Get-Content $catalogPath -Raw | ConvertFrom-Json -AsHashtable
    foreach ($sectionName in @('resources', 'exceptions')) {
        $normalized = @{}
        foreach ($item in $result[$sectionName].GetEnumerator()) { $normalized[$item.Key] = $item.Value }
        $result[$sectionName] = $normalized
    }
    if ($result.Contains('templatePins')) {
        foreach ($pin in $result.templatePins.Values) {
            $normalized = @{}
            foreach ($item in $pin.resources.GetEnumerator()) { $normalized[$item.Key] = $item.Value }
            $pin.resources = $normalized
        }
    }
    return $result
}

function Get-ArmApiSelection {
    param($Entry, [Collections.IDictionary] $Catalog)
    if ($Catalog.Contains('templatePins') -and $Catalog.templatePins.Contains($Entry.File) -and $Catalog.templatePins[$Entry.File].resources.ContainsKey($Entry.Type)) {
        return $Catalog.templatePins[$Entry.File].resources[$Entry.Type]
    }
    if ($Catalog.exceptions.ContainsKey($Entry.Type)) { return $Catalog.exceptions[$Entry.Type] }
    return $Catalog.resources[$Entry.Type]
}

function Get-ArmSchemaKey {
    param([string] $Reference)
    if ($Reference -notmatch '/schemas/([^#]+\.json)') { throw "Unsupported schema reference: $Reference" }
    return $Matches[1]
}

function Get-CachedArmSchema {
    param([switch] $Download)
    $catalog = Read-ArmApiCatalog
    $documents = @{}
    $pending = [Collections.Generic.Queue[string]]::new()
    foreach ($source in @($catalog.resources.Values.source) + @($catalog.exceptions.Values.source)) { $pending.Enqueue((Get-ArmSchemaKey $source)) }
    if ($catalog.Contains('templatePins')) {
        foreach ($pin in $catalog.templatePins.Values) {
            foreach ($source in $pin.resources.Values.source) { $pending.Enqueue((Get-ArmSchemaKey $source)) }
        }
    }
    while ($pending.Count) {
        $key = $pending.Dequeue()
        if ($documents.ContainsKey($key)) { continue }
        if ($documents.Count -gt 100) { throw 'Unexpectedly large ARM schema dependency graph.' }
        $path = Join-Path $cacheDirectory "schemas/$key"
        if (!(Test-Path $path)) {
            if (!$Download) { throw "Missing cached schema $key. Run bash etc/installArmTools.sh first." }
            New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force | Out-Null
            Invoke-WebRequest -Uri "https://raw.githubusercontent.com/Azure/azure-resource-manager-schemas/$($catalog.schemaCommit)/schemas/$key" -OutFile $path
        }
        $raw = Get-Content $path -Raw
        $documents[$key] = $raw | ConvertFrom-Json -AsHashtable -Depth 100
        foreach ($match in [regex]::Matches($raw, '"\$ref"\s*:\s*"(https?://[^"#]+\.json)(?:#[^"]*)?"')) {
            $pending.Enqueue((Get-ArmSchemaKey $match.Groups[1].Value))
        }
    }
    return $documents
}

function Convert-ArmSchemaReference {
    param($Node, [string] $SchemaKey)
    if ($Node -is [Collections.IDictionary]) {
        foreach ($key in @($Node.Keys)) {
            if ($key -in @('$schema', '$id', 'id') -and $Node[$key] -is [string]) { $Node.Remove($key); continue }
            if ($key -eq '$ref') {
                $reference = [string]$Node[$key]
                $targetKey = if ($reference.StartsWith('#')) { $SchemaKey } else { Get-ArmSchemaKey $reference }
                $fragment = if ($reference.Contains('#')) { $reference.Substring($reference.IndexOf('#') + 1) } else { '' }
                $escapedKey = $targetKey.Replace('~', '~0').Replace('/', '~1')
                $Node[$key] = "#/definitions/$escapedKey$fragment"
            } else { Convert-ArmSchemaReference -Node $Node[$key] -SchemaKey $SchemaKey }
        }
    } elseif ($Node -is [Collections.IEnumerable] -and $Node -isnot [string]) {
        foreach ($item in $Node) { Convert-ArmSchemaReference -Node $item -SchemaKey $SchemaKey }
    }
}

function Add-ArmExpressionAllowance {
    param($Node)
    if ($Node -is [Collections.IDictionary]) {
        foreach ($value in @($Node.Values)) { Add-ArmExpressionAllowance -Node $value }
        if ($Node.Contains('oneOf') -and $Node.oneOf -is [array]) {
            $Node['anyOf'] = $Node.oneOf
            $Node.Remove('oneOf')
        }
        $isSchema = ($Node.Contains('type') -and $Node.type -is [string]) -or ($Node.Contains('$ref') -and $Node['$ref'] -is [string]) -or ($Node.Contains('anyOf') -and $Node.anyOf -is [array]) -or $Node.Contains('const')
        if ($isSchema) {
            $original = @{}
            foreach ($item in $Node.GetEnumerator()) { $original[$item.Key] = $item.Value }
            $Node.Clear()
            $Node['anyOf'] = @($original, @{ type = 'string'; pattern = '^\[.+\]$' })
        }
    } elseif ($Node -is [Collections.IEnumerable] -and $Node -isnot [string]) {
        foreach ($item in $Node) { Add-ArmExpressionAllowance -Node $item }
    }
}

function New-ArmFixtureParameter {
    param([Collections.IDictionary] $Document)
    $values = @{}
    foreach ($parameter in $Document.parameters.GetEnumerator()) {
        $name = $parameter.Key
        $definition = $parameter.Value
        if ($name -eq '_artifactsLocation') { $values[$name] = @{ value = 'https://example.invalid/current-revision/' }; continue }
        if ($definition.type -eq 'securestring') { $values[$name] = @{ value = 'Fixture-Only-Not-A-Secret-2026!' }; continue }
        if ($definition.Contains('defaultValue')) { continue }
        $value = switch ($definition.type.ToLowerInvariant()) {
            'object' { @{} }
            'secureobject' { @{} }
            'array' { @('10.0.0.10', '10.0.0.11') }
            'int' { 0 }
            'bool' { $true }
            default {
                if ($name -match '(?i)subnetId') { '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/arm-fixture-rg/providers/Microsoft.Network/virtualNetworks/fixture-vnet/subnets/default' }
                elseif ($name -match '(?i)(availSet|availabilitySet)Id') { '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/arm-fixture-rg/providers/Microsoft.Compute/availabilitySets/fixture-as' }
                elseif ($name -match '(?i)(PubIp|ipAddress|nfsClientsIPRange)') { '203.0.113.10' }
                elseif ($name -match '(?i)sshPublicKey') { 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA arm-fixture' }
                elseif ($definition.Contains('allowedValues')) { $definition.allowedValues[0] }
                else { 'armfixture' }
            }
        }
        $values[$name] = @{ value = $value }
    }
    return $values
}

function Write-ArmFixture {
    param([Collections.IDictionary] $Document, [Collections.IDictionary] $Values, [string] $Directory)
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $templatePath = Join-Path $Directory 'template.json'
    $parameterPath = Join-Path $Directory 'template.parameters.json'
    $Document | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $templatePath -Encoding utf8
    $parameterFile = @{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; metadata = @{ template = $templatePath }; parameters = $Values }
    $parameterFile | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $parameterPath -Encoding utf8
    return @{ Template = $templatePath; Parameters = $parameterPath }
}

function New-ArmRuleFixtures {
    $toolManifest = Get-Content (Join-Path $RepositoryRoot 'etc/arm-toolchain.json') -Raw | ConvertFrom-Json -AsHashtable
    $env:PSModulePath = (Join-Path $cacheDirectory 'modules') + [IO.Path]::PathSeparator + $env:PSModulePath
    Import-Module (Join-Path $cacheDirectory "modules/PSRule/$($toolManifest.psRule.version)/PSRule.psd1") -ErrorAction Stop
    Import-Module (Join-Path $cacheDirectory "modules/PSRule.Rules.Azure/$($toolManifest.psRuleAzure.version)/PSRule.Rules.Azure.psd1") -ErrorAction Stop
    $fixtureDirectory = Join-Path $cacheDirectory "fixtures/$([guid]::NewGuid().ToString('N'))"
    $subscription = @{ subscriptionId = '00000000-0000-0000-0000-000000000001'; tenantId = '00000000-0000-0000-0000-000000000002'; displayName = 'Offline ARM fixtures' }
    $resourceGroup = @{ name = 'arm-fixture-rg'; location = 'eastus'; tags = @{} }
    $probe = $templates['azuredeploy.json'] | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100
    $probe.Remove('outputs')
    $probe.resources = @(@{ type = 'Microsoft.Storage/storageAccounts'; apiVersion = $catalog.resources['Microsoft.Storage/storageAccounts'].apiVersion; name = 'armfixtureprobe'; location = 'eastus'; properties = @{ moodleCommon = "[variables('moodleCommon')]" } })
    $probeFiles = Write-ArmFixture -Document $probe -Values (New-ArmFixtureParameter $probe) -Directory (Join-Path $fixtureDirectory 'probe')
    $probeResources = @(Export-AzRuleTemplateData -TemplateFile $probeFiles.Template -ParameterFile $probeFiles.Parameters -Subscription $subscription -ResourceGroup $resourceGroup -PassThru -ErrorAction Stop | Where-Object { $_.type -eq 'Microsoft.Storage/storageAccounts' })
    if ($probeResources.Count -ne 1) { throw 'The root moodleCommon fixture probe did not produce exactly one resource.' }
    $common = $probeResources[0].properties.moodleCommon | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100
    if ($common.Count -eq 0) { throw 'The root moodleCommon fixture probe was empty.' }
    $fixtures = [Collections.Generic.List[object]]::new()
    foreach ($file in ($templates.Keys | Sort-Object)) {
        $document = $templates[$file]
        $values = New-ArmFixtureParameter $document
        if ($document.parameters.Contains('moodleCommon')) {
            $childCommon = $common.Clone()
            if ($file -like '*nfs-ha*') { $childCommon.fileServerType = 'nfs-ha' }
            if ($file -like '*appgw*') { $childCommon.httpsTermination = 'AppGw' }
            if ($file -like '*privateDnsZone*') { $childCommon.vnetDbDeploySwitch = $true }
            $values['moodleCommon'] = @{ value = $childCommon }
        }
        $paths = Write-ArmFixture -Document $document -Values $values -Directory (Join-Path $fixtureDirectory ($file.Replace('/', '_')))
        $expected = @($inventory | Where-Object File -eq $file).Count
        $fixtures.Add([pscustomobject]@{ File = $file; Template = $paths.Template; Parameters = $paths.Parameters; ExpectedDeclarations = $expected })
    }
    return @{ Directory = $fixtureDirectory; Fixtures = $fixtures; Subscription = $subscription; ResourceGroup = $resourceGroup }
}

if ($Mode -eq 'Inventory') {
    $inventory | Select-Object File, Type, ApiVersion | Format-Table -AutoSize
    Write-Output "Templates: $($templates.Count); resource declarations: $($inventory.Count)"
    return
}

if ($Mode -eq 'RefreshCatalog') {
    $toolManifest = Get-Content (Join-Path $RepositoryRoot 'etc/arm-toolchain.json') -Raw | ConvertFrom-Json -AsHashtable
    $schemaCommit = $toolManifest.schemas.commit
    $tree = Get-Content (Join-Path $cacheDirectory 'schema-tree.json') -Raw | ConvertFrom-Json
    if ($tree.truncated) { throw 'The published schema tree is truncated.' }
    $versions = @{}
    foreach ($namespace in @($inventory.Type | ForEach-Object { ($_ -split '/')[0] } | Sort-Object -Unique)) {
        $wantedTypes = @($inventory.Type | Where-Object { $_ -like "$namespace/*" } | Sort-Object -Unique)
        $schemaPaths = @($tree.tree.path | Where-Object { $_ -match "^schemas/(\d{4}-\d{2}-\d{2})/$([regex]::Escape($namespace))(?:\.[^/]+)?\.json$" -and $Matches[1] -le $toolManifest.assessmentDate } | Sort-Object -Descending)
        foreach ($schemaPath in $schemaPaths) {
            $schemaUrl = "https://raw.githubusercontent.com/Azure/azure-resource-manager-schemas/$schemaCommit/$schemaPath"
            $schema = Invoke-RestMethod -Uri $schemaUrl
            if (!$schema.PSObject.Properties['resourceDefinitions']) { continue }
            foreach ($definition in $schema.resourceDefinitions.PSObject.Properties) {
                $properties = $definition.Value.properties
                if (!$properties -or !$properties.PSObject.Properties['type'] -or !$properties.PSObject.Properties['apiVersion']) { continue }
                $resourceType = [string]$properties.type.enum[0]
                if ($resourceType -in $wantedTypes -and !$versions.ContainsKey($resourceType) -and $properties.apiVersion.enum[0] -match '^\d{4}-\d{2}-\d{2}$') {
                    $versions[$resourceType] = [ordered]@{ apiVersion = [string]$properties.apiVersion.enum[0]; source = $schemaUrl }
                }
            }
            if (@($wantedTypes | Where-Object { !$versions.ContainsKey($_) }).Count -eq 0) { break }
        }
    }
    $missingTypes = @($inventory.Type | Sort-Object -Unique | Where-Object { !$versions.ContainsKey($_) })
    if ($missingTypes.Count) { throw "No published stable schema found for: $($missingTypes -join ', ')" }
    $exceptions = if (Test-Path $catalogPath) { (Read-ArmApiCatalog).exceptions } else { @{} }
    $orderedVersions = [ordered]@{}
    foreach ($resourceType in ($versions.Keys | Sort-Object)) { $orderedVersions[$resourceType] = $versions[$resourceType] }
    $operations = if (Test-Path $catalogPath) { (Read-ArmApiCatalog).operations } else { @{} }
    $templatePins = if ((Test-Path $catalogPath) -and (Read-ArmApiCatalog).Contains('templatePins')) { (Read-ArmApiCatalog).templatePins } else { @{} }
    $catalog = [ordered]@{ assessmentDate = $toolManifest.assessmentDate; schemaCommit = $schemaCommit; resources = $orderedVersions; operations = $operations; exceptions = $exceptions; templatePins = $templatePins }
    $catalog | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $catalogPath -Encoding utf8
    Write-Output "Pinned stable APIs for $($versions.Count) resource types in $catalogPath"
    return
}

if ($Mode -eq 'FetchSchemas') {
    $schemas = Get-CachedArmSchema -Download
    Write-Output "Cached $($schemas.Count) pinned schema files for offline resource-shape checks."
    return
}

foreach ($templateEntry in $templates.GetEnumerator()) {
    $document = $templateEntry.Value
    $parameters = if ($document.Contains('parameters')) { $document.parameters } else { @{} }
    foreach ($parameter in $parameters.GetEnumerator()) {
        if ($parameter.Value.Contains('defaultValue') -and $parameter.Value.Contains('allowedValues') -and $parameter.Value.defaultValue -notin $parameter.Value.allowedValues) {
            $failures.Add("$($templateEntry.Key): default for $($parameter.Key) is not allowed")
        }
    }
    $text = $document | ConvertTo-Json -Depth 100
    foreach ($match in [regex]::Matches($text, "(?i)\bparameters\(\s*'([^']+)'\s*\)")) {
        if (!$parameters.Contains($match.Groups[1].Value)) { $failures.Add("$($templateEntry.Key): undeclared parameter $($match.Groups[1].Value)") }
    }
    foreach ($match in [regex]::Matches($text, "(?:(?:scripts|etc)/)?[a-zA-Z_][a-zA-Z0-9_-]+\.sh")) {
        $scriptName = Split-Path $match.Value -Leaf
        $relativeScripts = if ($match.Value.Contains('/')) { @($match.Value) } else { @("scripts/$scriptName", "etc/$scriptName", $scriptName) }
        $existingScripts = @($relativeScripts | Where-Object { Test-Path (Join-Path $RepositoryRoot $_) })
        if ($existingScripts.Count -eq 0) { $failures.Add("$($templateEntry.Key): referenced script $($match.Value) was not found locally") }
    }
}

$linkedOutputs = @{}
$linkedTargetCount = 0
foreach ($entry in $inventory) {
    $resource = $entry.Resource
    if (!$resource.Contains('properties') -or !$resource.properties.Contains('templateLink')) { continue }
    $link = $resource.properties.templateLink
    $linkText = if ($link.Contains('uri')) { [string]$link.uri } elseif ($link.Contains('relativePath')) { [string]$link.relativePath } else { '' }
    foreach ($variable in $templates[$entry.File].variables.GetEnumerator()) {
        if ($variable.Value -is [string] -and $variable.Value -match '\.json') { $linkText = $linkText.Replace("variables('$($variable.Key)')", $variable.Value) }
    }
    $filenames = @([regex]::Matches($linkText, "'([^']+\.json)'") | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -ne '.json' })
    if ($linkText -match "'db-'" -and $templates[$entry.File].parameters.Contains('dbServerType')) {
        $filenames += @($templates[$entry.File].parameters.dbServerType.allowedValues | ForEach-Object { "db-$_.json" })
    }
    if ($linkText -match "'search-'" -and $templates[$entry.File].parameters.Contains('searchType')) {
        $filenames += @($templates[$entry.File].parameters.searchType.allowedValues | Where-Object { $_ -ne 'none' } | ForEach-Object { "search-$_.json" })
    }
    if ($filenames.Count -eq 0) { $failures.Add("$($entry.File): unresolved linked-template target $linkText") }
    foreach ($filename in ($filenames | Sort-Object -Unique)) {
        $parentDirectory = Split-Path $entry.File -Parent
        $relativeCandidate = if ($parentDirectory) { Join-Path $parentDirectory $filename } else { $filename }
        $candidates = @($relativeCandidate, "nested/$filename", $filename)
        $childPath = @($candidates | Where-Object { $templates.ContainsKey($_) } | Select-Object -First 1)
        if ($childPath.Count -eq 0) { $failures.Add("$($entry.File): linked template $filename was not found locally"); continue }
        $linkedTargetCount++
        $linkKey = "$($entry.File)|$($resource.name)"
        if (!$linkedOutputs.ContainsKey($linkKey)) { $linkedOutputs[$linkKey] = @() }
        $linkedOutputs[$linkKey] += $childPath[0]
        $declared = $templates[$childPath[0]].parameters
        $supplied = if ($resource.properties.Contains('parameters')) { $resource.properties.parameters } else { @{} }
        foreach ($parameterName in $supplied.Keys) {
            if (!$declared.Contains($parameterName)) { $failures.Add("$($entry.File) -> $($childPath[0]): unexpected parameter $parameterName") }
        }
        foreach ($parameter in $declared.GetEnumerator()) {
            if (!$parameter.Value.Contains('defaultValue') -and !$supplied.Contains($parameter.Key) -and !$resource.properties.Contains('parametersLink')) {
                $failures.Add("$($entry.File) -> $($childPath[0]): missing required parameter $($parameter.Key)")
            }
        }
    }
}

foreach ($templateEntry in $templates.GetEnumerator()) {
    $text = $templateEntry.Value | ConvertTo-Json -Depth 100
    foreach ($match in [regex]::Matches($text, "(?i)reference\(\s*'([^']+)'\s*\)\.outputs\.([a-zA-Z0-9_]+)")) {
        $linkKey = "$($templateEntry.Key)|$($match.Groups[1].Value)"
        if (!$linkedOutputs.ContainsKey($linkKey)) { continue }
        $children = $linkedOutputs[$linkKey]
        $prefix = $text.Substring(0, $match.Index)
        $guard = [regex]::Match($prefix, "if\(equals\(parameters\('[^']+'\),\s*'([^']+)'\),\s*$")
        if ($guard.Success) {
            $guardedChildren = @($children | Where-Object { $_ -match "[-/]$([regex]::Escape($guard.Groups[1].Value))\.json$" })
            if ($guardedChildren.Count) { $children = $guardedChildren }
        }
        foreach ($child in $children) {
            if (!$templates[$child].Contains('outputs') -or !$templates[$child].outputs.Contains($match.Groups[2].Value)) {
                $failures.Add("$($templateEntry.Key) -> ${child}: missing output $($match.Groups[2].Value)")
            }
        }
    }
}

foreach ($consumer in @('azuredeploy.parameters.json', 'loadtest/azuredeploy.parameters.loadtest.defaults.json', 'managedApplication/parameters-template.json')) {
    $values = Get-Content (Join-Path $RepositoryRoot $consumer) -Raw | ConvertFrom-Json -AsHashtable
    if ($values.Contains('parameters')) { $values = $values.parameters }
    foreach ($parameterName in $values.Keys) {
        if (!$templates['azuredeploy.json'].parameters.Contains($parameterName)) { $failures.Add("${consumer}: unknown root parameter $parameterName") }
    }
}

if (Test-Path $catalogPath) {
    $catalog = Read-ArmApiCatalog
    foreach ($entry in $inventory) {
        if (!$catalog.resources.Contains($entry.Type)) { $failures.Add("$($entry.File): no API catalog entry for $($entry.Type)"); continue }
        $expected = (Get-ArmApiSelection -Entry $entry -Catalog $catalog).apiVersion
        if ($entry.ApiVersion -ne $expected) { $failures.Add("$($entry.File): $($entry.Type) uses $($entry.ApiVersion), expected $expected") }
    }
    foreach ($templateEntry in $templates.GetEnumerator()) {
        $text = $templateEntry.Value | ConvertTo-Json -Depth 100
        foreach ($match in [regex]::Matches($text, '"([^"\r\n]*(?:reference|list[A-Za-z]+)\([^"\r\n]*)"')) {
            foreach ($version in [regex]::Matches($match.Groups[1].Value, "'(\d{4}-\d{2}-\d{2}(?:-preview)?)'")) {
                if (!$catalog.operations.Contains($templateEntry.Key) -or $version.Groups[1].Value -ne $catalog.operations[$templateEntry.Key].apiVersion) {
                    $failures.Add("$($templateEntry.Key): unreviewed operation API $($version.Groups[1].Value)")
                }
            }
        }
    }
}

$failures = @($failures | Sort-Object -Unique)
foreach ($failure in $failures) { Write-Output "FAIL: $failure" }
Write-Output "ARM coverage: $($templates.Count) templates; $($inventory.Count) resource declarations; $linkedTargetCount linked targets; $($failures.Count) contract/API failures"
if ($failures.Count) { throw 'ARM contract or API checks failed.' }

if ($Mode -in @('Schemas', 'All')) {
    $schemas = Get-CachedArmSchema
    $bundle = @{ definitions = @{} }
    $definitionIndex = @{}
    foreach ($schemaKey in $schemas.Keys) {
        if ($schemaKey -match '/Microsoft\.RecoveryServices\.json$') {
            foreach ($policyType in @('ProtectionPolicy', 'RetentionPolicy', 'SchedulePolicy')) {
                if ($schemas[$schemaKey].definitions.Contains($policyType)) {
                    $polymorphicBase = $schemas[$schemaKey].definitions[$policyType].allOf[0]
                    if ($polymorphicBase.Contains('additionalProperties') -and $polymorphicBase.additionalProperties -eq $false) {
                        $polymorphicBase.Remove('additionalProperties')
                        Write-Output "NOTICE: normalized contradictory inherited-property base in $schemaKey/$policyType; derived policy properties remain checked."
                    }
                }
            }
        }
        $definitionIndex[$schemaKey] = @{}
        if ($schemas[$schemaKey].Contains('resourceDefinitions')) {
            foreach ($definition in $schemas[$schemaKey].resourceDefinitions.GetEnumerator()) {
                $canonicalType = [string]$definition.Value.properties.type.enum[0]
                $definitionIndex[$schemaKey][$canonicalType] = @{ Name = $definition.Key; Type = $canonicalType }
            }
        }
        Convert-ArmSchemaReference -Node $schemas[$schemaKey] -SchemaKey $schemaKey
        Add-ArmExpressionAllowance -Node $schemas[$schemaKey]
        $bundle.definitions[$schemaKey] = $schemas[$schemaKey]
    }
    $schemaFailures = [Collections.Generic.List[string]]::new()
    Test-Json -Json '{}' -Schema '{}' | Out-Null
    $evaluationOptions = [Json.Schema.EvaluationOptions]::new()
    $evaluationOptions.OutputFormat = [Json.Schema.OutputFormat]::List
    $compiledSchemas = @{}
    foreach ($entry in $inventory) {
        $selection = Get-ArmApiSelection -Entry $entry -Catalog $catalog
        $schemaKey = Get-ArmSchemaKey $selection.source
        $definition = $definitionIndex[$schemaKey][$entry.Type]
        if (!$definition) { throw "No schema definition for $($entry.Type) in $schemaKey" }
        $escapedKey = $schemaKey.Replace('~', '~0').Replace('/', '~1')
        $rootReference = "#/definitions/$escapedKey/resourceDefinitions/$($definition.Name)"
        if (!$compiledSchemas.ContainsKey($rootReference)) {
            $bundle['$ref'] = $rootReference
            $compiledSchemas[$rootReference] = [Json.Schema.JsonSchema]::FromText(($bundle | ConvertTo-Json -Depth 100 -Compress))
        }
        $resourceCopy = $entry.Resource | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100
        $resourceCopy.type = $definition.Type
        $instance = [System.Text.Json.Nodes.JsonNode]::Parse(($resourceCopy | ConvertTo-Json -Depth 100 -Compress))
        $evaluation = $compiledSchemas[$rootReference].Evaluate($instance, $evaluationOptions)
        if (!$evaluation.IsValid) {
            $details = @($evaluation.Details | Where-Object { !$_.IsValid -and $_.Errors } | Select-Object -First 8 | ForEach-Object {
                "$($_.InstanceLocation): $($_.Errors.Values -join ', ')"
            })
            $schemaFailures.Add("$($entry.File): $($entry.Type): $($details -join '; ')")
        }
    }
    foreach ($failure in $schemaFailures) { Write-Output "FAIL: $failure" }
    Write-Output "ARM resource-shape coverage: $($inventory.Count) declarations; $($schemaFailures.Count) failures. Expressions are not provider validation."
    if ($schemaFailures.Count) { throw 'ARM resource-shape checks failed.' }
}

if ($Mode -in @('Ttk', 'All')) {
    $toolManifest = Get-Content (Join-Path $RepositoryRoot 'etc/arm-toolchain.json') -Raw | ConvertFrom-Json -AsHashtable
    $modulePath = Join-Path $cacheDirectory "arm-ttk-$($toolManifest.armTtk.commit)/arm-ttk/arm-ttk.psd1"
    if (!(Test-Path $modulePath)) { throw 'ARM-TTK is missing. Run bash etc/installArmTools.sh first.' }
    $ttkModule = Import-Module $modulePath -ErrorAction Stop -PassThru
    $ttkModule.SessionState.PSVariable.Set('ErrorActionPreference', 'Continue')
    $stageDirectory = Join-Path $cacheDirectory "staging/$([guid]::NewGuid().ToString('N'))"
    $reportDirectory = Join-Path $cacheDirectory 'reports'
    New-Item -ItemType Directory -Path $stageDirectory, $reportDirectory -Force | Out-Null
    $testResults = [Collections.Generic.List[object]]::new()
    $toolFailures = [Collections.Generic.List[string]]::new()
    try {
        foreach ($relativePath in (& git -C $RepositoryRoot ls-files --cached --others --exclude-standard -- '*.json' '*.sh' '*.md' | Sort-Object -Unique)) {
            $source = Join-Path $RepositoryRoot $relativePath
            if (!(Test-Path -LiteralPath $source)) { continue }
            $destination = Join-Path $stageDirectory $relativePath
            New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
            Copy-Item -LiteralPath $source -Destination $destination
        }
        foreach ($file in ($templates.Keys | Sort-Object)) {
            $templatePath = Join-Path $stageDirectory $file
            $results = @(& {
                Set-StrictMode -Off
                $ErrorActionPreference = 'Continue'
                Test-AzTemplate -TemplatePath $templatePath -File (Split-Path $file -Leaf) -GroupName DeploymentTemplate -ErrorAction Continue
            })
            if ($results.Count -eq 0) { $toolFailures.Add("$file produced no ARM-TTK test results") }
            foreach ($result in $results) {
                $testResults.Add([pscustomobject]@{
                    File = $file
                    Name = [string]$result.Name
                    Errors = @($result.Errors | ForEach-Object { $_.ToString() })
                })
            }
            Write-Output "ARM-TTK tested: $file; $($results.Count) tests"
        }
        $testResults | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $reportDirectory 'arm-ttk.json') -Encoding utf8
    } finally { Remove-Item -LiteralPath $stageDirectory -Recurse -Force }
    $failedTests = @($testResults | Where-Object { $_.Errors.Count -gt 0 })
    $failedTests | Group-Object Name | Sort-Object Name | ForEach-Object { Write-Output "ARM-TTK finding: $($_.Name): $($_.Count)" }
    foreach ($failure in $toolFailures) { Write-Output "FAIL: $failure" }
    Write-Output "ARM-TTK coverage: $($templates.Count) templates; $($testResults.Count) tests; $($failedTests.Count) failed tests; $($toolFailures.Count) coverage failures."
    if ($failedTests.Count -or $toolFailures.Count) { throw 'ARM-TTK failed; inspect the local reports/arm-ttk.json report.' }
}

if ($Mode -eq 'Fixtures') {
    $fixtureSet = New-ArmRuleFixtures
    Write-Output "PSRule fixtures: $($fixtureSet.Fixtures.Count) templates; local artifacts only; dummy values; $($fixtureSet.Directory)"
}

if ($Mode -in @('Rules', 'All')) {
    $fixtureSet = New-ArmRuleFixtures
    $reportDirectory = Join-Path $cacheDirectory 'reports'
    New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null
    $ruleResults = [Collections.Generic.List[object]]::new()
    $coverageResults = [Collections.Generic.List[object]]::new()
    $ruleFailures = [Collections.Generic.List[string]]::new()
    $options = New-PSRuleOption -Configuration @{
        AZURE_PARAMETER_FILE_EXPANSION = $true
        AZURE_SUBSCRIPTION = $fixtureSet.Subscription
        AZURE_RESOURCE_GROUP = $fixtureSet.ResourceGroup
    } -InputIgnoreGitPath $false -InputIgnoreRepositoryCommon $false -ExecutionUnprocessedObject Error -ExecutionRuleInconclusive Error -OutputBanner None
    try {
        foreach ($fixture in $fixtureSet.Fixtures) {
            try {
                $expanded = @(Export-AzRuleTemplateData -TemplateFile $fixture.Template -ParameterFile $fixture.Parameters -Subscription $fixtureSet.Subscription -ResourceGroup $fixtureSet.ResourceGroup -PassThru -ErrorAction Stop)
                $resourceCount = @($expanded | Where-Object { !$_.PSObject.Properties['rootDeployment'] }).Count
                if ($fixture.ExpectedDeclarations -gt 0 -and $resourceCount -eq 0) { throw 'Resource-bearing template expanded to zero resources.' }
                $results = @($expanded | Invoke-PSRule -Module PSRule.Rules.Azure -Option $options -Outcome All -ErrorAction Stop)
                $processed = @($results | Where-Object { $_.Outcome -in @('Pass', 'Fail') }).Count
                if ($processed -eq 0) { throw 'No PSRule rules evaluated the fixture.' }
                foreach ($result in $results) {
                    $ruleResults.Add([pscustomobject]@{
                        File = $fixture.File
                        RuleName = [string]$result.RuleName
                        TargetName = [string]$result.TargetName
                        Outcome = [string]$result.Outcome
                        Reason = @($result.Reason | Where-Object { $null -ne $_ } | ForEach-Object { $_.ToString() })
                    })
                }
                $coverageResults.Add([pscustomobject]@{ File = $fixture.File; Declarations = $fixture.ExpectedDeclarations; ExpandedResources = $resourceCount; EvaluatedRules = $processed })
                Write-Output "PSRule tested: $($fixture.File); $resourceCount expanded resources; $processed evaluated rules"
            } catch {
                $ruleFailures.Add("$($fixture.File): $($_.Exception.Message) [$($_.ScriptStackTrace)]")
            }
        }
        $ruleResults | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $reportDirectory 'psrule.json') -Encoding utf8
        $coverageResults | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $reportDirectory 'psrule-coverage.json') -Encoding utf8
    } finally { Remove-Item -LiteralPath $fixtureSet.Directory -Recurse -Force }
    $failedRules = @($ruleResults | Where-Object Outcome -eq 'Fail')
    $failedRules | Group-Object RuleName | Sort-Object Name | ForEach-Object { Write-Output "PSRule finding: $($_.Name): $($_.Count)" }
    foreach ($failure in $ruleFailures) { Write-Output "FAIL: $failure" }
    Write-Output "PSRule coverage: $($coverageResults.Count)/$($templates.Count) templates; $($failedRules.Count) failed rules; $($ruleFailures.Count) expansion/coverage failures. External templateLink children were tested independently."
    if ($failedRules.Count -or $ruleFailures.Count -or $coverageResults.Count -ne $templates.Count) { throw 'PSRule failed; inspect the local reports/psrule*.json reports.' }
}

if ($Mode -eq 'SelfTest') {
    $testRoot = Join-Path $cacheDirectory "contract-tests/$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $sourceFiles = @(& git -C $RepositoryRoot ls-files --cached --others --exclude-standard -- '*.json' '*.sh' | Sort-Object -Unique | Where-Object { Test-Path (Join-Path $RepositoryRoot $_) })
    $mutations = @(
        @{ Name = 'old resource API'; File = 'nested/controller.json'; Mode = 'Contracts'; Expected = 'expected 2026'; Edit = { param($document) $document.resources[0].apiVersion = '2017-10-01' } },
        @{ Name = 'unexpected child parameter'; File = 'azuredeploy.json'; Mode = 'Contracts'; Expected = 'unexpected parameter'; Edit = { param($document) ($document.resources | Where-Object name -eq 'networkTemplate').properties.parameters['unexpectedFixtureParameter'] = @{ value = 'invalid' } } },
        @{ Name = 'missing linked output'; File = 'nested/network.json'; Mode = 'Contracts'; Expected = 'missing output'; Edit = { param($document) $document.outputs.Clear() } },
        @{ Name = 'retired database route'; File = 'azuredeploy.json'; Mode = 'Contracts'; Expected = 'db-mysql.json was not found'; Edit = { param($document) $document.parameters.dbServerType.allowedValues += 'mysql' } },
        @{ Name = 'stale operation API'; File = 'nested/controller.json'; Mode = 'Contracts'; Expected = 'unreviewed operation API'; Edit = { param($document) $output = @($document.outputs.Values | Where-Object { $_.value -match '2026-03-01' })[0]; $output.value = $output.value.Replace('2026-03-01', '2017-10-01') } },
        @{ Name = 'invalid storage kind'; File = 'nested/storageAccount.json'; Mode = 'Schemas'; Expected = 'resource-shape checks failed'; Edit = { param($document) $document.resources[0].kind = 'InvalidFixtureKind' } },
        @{ Name = 'invalid backup discriminator'; File = 'nested/recoveryservices.json'; Mode = 'Schemas'; Expected = 'resource-shape checks failed'; Edit = { param($document) $document.resources[1].properties.backupManagementType = 'InvalidFixtureBackupType' } }
    )
    $mutationFailures = [Collections.Generic.List[string]]::new()
    try {
        & git -C $testRoot init --quiet
        if ($LASTEXITCODE -ne 0) { throw 'Could not initialize isolated mutation-test repository.' }
        foreach ($file in $sourceFiles) {
            $destination = Join-Path $testRoot $file
            New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $RepositoryRoot $file) -Destination $destination
        }
        $schemaCache = Join-Path $testRoot '.cache/arm-tools'
        New-Item -ItemType Directory -Path $schemaCache -Force | Out-Null
        New-Item -ItemType SymbolicLink -Path (Join-Path $schemaCache 'schemas') -Value (Join-Path $cacheDirectory 'schemas') | Out-Null
        foreach ($mutation in $mutations) {
            $filePath = Join-Path $testRoot $mutation.File
            $document = Get-Content $filePath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
            & $mutation.Edit $document
            $document | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $filePath -Encoding utf8
            $output = @(& (Join-Path $PSHOME 'pwsh') -NoLogo -NoProfile -NonInteractive -File $PSCommandPath -Mode $mutation.Mode -RepositoryRoot $testRoot 2>&1)
            if ($LASTEXITCODE -eq 0 -or ($output -join "`n") -notmatch $mutation.Expected) { $mutationFailures.Add($mutation.Name) }
            else { Write-Output "PASS: rejected $($mutation.Name)" }
            Copy-Item -LiteralPath (Join-Path $RepositoryRoot $mutation.File) -Destination $filePath -Force
        }
    } finally { Remove-Item -LiteralPath $testRoot -Recurse -Force }
    if ($mutationFailures.Count) { throw "ARM mutation tests failed: $($mutationFailures -join ', ')" }
    Write-Output "ARM mutation tests: $($mutations.Count) deliberate defects rejected."
}

if ($Mode -notin @('Contracts', 'Schemas', 'SelfTest', 'Ttk', 'Fixtures', 'Rules')) { throw "The $Mode layer has not been initialized yet." }