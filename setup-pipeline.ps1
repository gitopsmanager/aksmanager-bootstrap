# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
<#
.SYNOPSIS
    One-shot setup for the AKS Manager bootstrap: phase 1, Let's Encrypt.

.DESCRIPTION
    Run once per client, from the root of your PRIVATE copy of
    aksmanager-bootstrap, signed in with `az login --tenant <tenant>` as an
    account that is Owner on the shared services subscription.

    Phase 1 stands up what the certificate pipeline needs and issues the first
    certificates. In order:

      1. Preflight: tools, tenant, subscription, your rights, hosted-zones.json.
      2. Resource providers registered (idempotent).
      3. The shared services resource group.
      4. Terraform state: storage account aksmanagertf<12 hex of subscription>,
         container tfstate, Entra ID access only (shared keys off).
      5. The Key Vault -- created if missing (RBAC, soft delete, purge
         protection); an existing one is used as is.
      6. The container registry, when CONTAINER_REGISTRY_NAME is set -- created
         if missing.
      7. The certificate job's managed identity, id-aksmanager-letsencrypt, and
         its roles: Key Vault Secrets Officer on the vault, Storage Blob Data
         Contributor on the state container, and the customer's DNS-01 role on
         every public zone in hosted-zones.json. You get Secrets Officer and
         blob access too, for this first run.
      8. The vault guard: a zone whose <prefix>-dns-zone-certs is a manually
         saved certificate (not managed_by=Terraform), live or soft-deleted, is
         left out of this run and reported. Manual certificates are never
         overwritten.
      9. pinned.auto.tfvars.json written to your private repo, using the
         bootstrap GitHub App's credentials read from the Key Vault
         (global-bootstrap-github-app). Settings -> Terraform -> Reload reads it.
     10. terraform init + apply of terraform/lets-encrypt under your az login.
         The plan is shown and needs your "yes".

    It never creates DNS zones or delegation: those are yours, listed in
    hosted-zones.json. The scheduled certificate job (Container Apps) and the
    agent bootstrap are later phases.

    Idempotent -- safe to re-run.

.NOTES
    PREREQUISITES
      - PowerShell 7.1 or later (pwsh). RSA.ImportFromPem, used to sign the
        GitHub App JWT, needs .NET 5.
      - az CLI, signed in: az login --tenant <AZURE_TENANT_ID>
      - terraform >= 1.5.0
      - python3 (validates hosted-zones.json)
      - hosted-zones.json in the repo root (copy example-hosted-zones.json)
      - The DNS-01 role from example-cert-manager-role.json created in your
        tenant (or set CERT_DNS_ROLE to "DNS Zone Contributor").

.EXAMPLE
    Paste the PowerShell block from Settings -> Terraform (Azure), then:

    .\setup-pipeline.ps1

    A private registry (no public endpoint) needs Premium; the default is Basic:

    .\setup-pipeline.ps1 -ContainerRegistrySku Premium

    Optional overrides:
      $env:CERT_DNS_ROLE = "DNS Zone Contributor"     # default "AKS Manager ACME DNS-01"
      $env:AKSMANAGER_ALLOW_EMPTY_STATE = "true"      # see the empty-state guard
#>

param(
    # Used only when the registry is CREATED here. An existing registry keeps
    # its tier; change it with az acr update --sku if needed.
    [ValidateSet("Basic", "Standard", "Premium")]
    [string] $ContainerRegistrySku = "Basic"
)

$ErrorActionPreference = "Stop"

if ($PSVersionTable.PSVersion -lt [Version]"7.1") {
    Write-Error "PowerShell 7.1 or later is required (pwsh). This is $($PSVersionTable.PSVersion)."
    exit 1
}

# ── Inputs (the Settings -> Terraform block) ──────────────────────────────────
$TenantId          = $env:AZURE_TENANT_ID
$SubscriptionId    = $env:SHARED_SERVICES_SUBSCRIPTION_ID
$Location          = $env:AZURE_LOCATION
$SharedRg          = $env:SHARED_SERVICES_RESOURCE_GROUP
$KeyVaultName      = $env:KEY_VAULT_NAME
$KeyVaultRg        = $env:KEY_VAULT_RESOURCE_GROUP
$AcrName           = $env:CONTAINER_REGISTRY_NAME
$AcrRg             = $env:CONTAINER_REGISTRY_RESOURCE_GROUP
$AgentVmName       = $env:AGENT_VM_NAME
$AgentVnetId       = $env:AGENT_VNET_ID
$AgentSubnetName   = $env:AGENT_SUBNET_NAME
$CostTagName       = $env:RESOURCE_TAG_NAME
$CostTagValue      = $env:RESOURCE_TAG_VALUE
$CertDnsRole       = if ($env:CERT_DNS_ROLE) { $env:CERT_DNS_ROLE } else { "AKS Manager ACME DNS-01" }

foreach ($pair in @(
    @{ Name = "AZURE_TENANT_ID";                 Value = $TenantId }
    @{ Name = "SHARED_SERVICES_SUBSCRIPTION_ID"; Value = $SubscriptionId }
    @{ Name = "AZURE_LOCATION";                  Value = $Location }
    @{ Name = "SHARED_SERVICES_RESOURCE_GROUP";  Value = $SharedRg }
    @{ Name = "KEY_VAULT_NAME";                  Value = $KeyVaultName }
    @{ Name = "KEY_VAULT_RESOURCE_GROUP";        Value = $KeyVaultRg }
)) {
    if ([string]::IsNullOrWhiteSpace($pair.Value)) {
        Write-Error "`$env:$($pair.Name) is required -- paste the block from Settings -> Terraform (Azure)."
        exit 1
    }
}

$Guid = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
if ($TenantId -notmatch $Guid)       { Write-Error "AZURE_TENANT_ID must be a GUID."; exit 1 }
if ($SubscriptionId -notmatch $Guid) { Write-Error "SHARED_SERVICES_SUBSCRIPTION_ID must be a GUID."; exit 1 }
if ([string]::IsNullOrWhiteSpace($CostTagName) -ne [string]::IsNullOrWhiteSpace($CostTagValue)) {
    Write-Error "RESOURCE_TAG_NAME and RESOURCE_TAG_VALUE go together: set both or neither."
    exit 1
}
if ($AcrName -and -not $AcrRg) { $AcrRg = $SharedRg }

$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $RepoRoot

# Derived, like AWS's eksmanager-tfstate-<account>: every run and every
# operator lands on the same state. Storage account names are 3-24 lowercase
# letters and digits and globally unique, so the full subscription ID does not
# fit; 12 hex digits of it make a clash with someone else's account unlikely.
$StateAccount   = "aksmanagertf" + ($SubscriptionId -replace '-', '').Substring(0, 12).ToLower()
$StateContainer = "tfstate"
$StateKey       = "lets-encrypt.tfstate"
$CertIdentity   = "id-aksmanager-letsencrypt"
$AppSecretName  = "global-bootstrap-github-app"

# What this script creates is tagged like everything else GitOps Manager makes.
# managed_by names the bootstrap, not the agent: the agent treats these as
# another tool's resources and never deletes or reconfigures them.
$Tags = [ordered]@{ AKSManager = "Managed"; deployed_by = "GitOpsManager"; managed_by = "AKSManagerBootstrap" }
if ($CostTagName) { $Tags[$CostTagName] = $CostTagValue }
$TagArgs = @($Tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" })

# ── Helpers ───────────────────────────────────────────────────────────────────

# az with JSON output parsed. Returns @{ Ok; Data; Err }. Never throws, so the
# caller decides what a failure means (NotFound is often the expected answer).
function Invoke-Az {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]] $AzArgs)
    $errFile = [System.IO.Path]::GetTempFileName()
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = & az @AzArgs --only-show-errors -o json 2>$errFile
        $rc = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    $err = (Get-Content $errFile -Raw -ErrorAction SilentlyContinue)
    Remove-Item $errFile -Force -ErrorAction SilentlyContinue
    $data = $null
    if ($rc -eq 0 -and $out) {
        try { $data = ($out -join "`n") | ConvertFrom-Json } catch { $data = $out }
    }
    return @{ Ok = ($rc -eq 0); Data = $data; Err = ("$err").Trim() }
}

function Assert-Az {
    param([string] $What, [hashtable] $Result)
    if (-not $Result.Ok) {
        Write-Error "$What failed:`n$($Result.Err)"
        exit 1
    }
    return $Result.Data
}

function Test-NotFound([string] $Err) {
    return ($Err -match 'NotFound|ResourceNotFound|could not be found|was not found|does not exist|SecretNotFound|ResourceGroupNotFound')
}

function Get-ManagedBy($TagObject) {
    if (-not $TagObject) { return "" }
    foreach ($p in $TagObject.PSObject.Properties) {
        $k = ($p.Name -replace '[^A-Za-z0-9]', '').ToLower()
        if ($k -eq 'managedby') { return [string]$p.Value }
    }
    return ""
}

# Merge our tags onto an existing resource only when nobody owns it yet --
# the same rule as the app's retag. Never replaces tags.
function Add-TagsIfUnowned([string] $ResourceId, $ExistingTags) {
    if (Get-ManagedBy $ExistingTags) { return }
    $r = Invoke-Az tag update --resource-id $ResourceId --operation merge --tags @TagArgs
    if (-not $r.Ok) { Write-Warning "Could not tag $ResourceId -- $($r.Err)" }
}

# Role assignment, created only if missing. By object ID, never by name, so it
# needs no Graph lookup.
function Grant-Role([string] $PrincipalId, [string] $PrincipalType, [string] $Role, [string] $Scope, [string] $Label) {
    $existing = Invoke-Az role assignment list --assignee-object-id $PrincipalId --role $Role --scope $Scope
    if ($existing.Ok -and @($existing.Data).Count -gt 0) {
        Write-Host "  = $Label already has '$Role'"
        return
    }
    $r = Invoke-Az role assignment create --assignee-object-id $PrincipalId --assignee-principal-type $PrincipalType `
        --role $Role --scope $Scope --description "GitOps Manager bootstrap"
    if (-not $r.Ok) {
        Write-Error "Could not grant '$Role' to $Label on $Scope`n$($r.Err)"
        exit 1
    }
    Write-Host "  + $Label granted '$Role'"
}

# Data-plane calls right after a role assignment can be refused for a few
# minutes while it propagates. Retries only on authorization errors.
function Invoke-AzRetryAuth {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]] $AzArgs)
    for ($i = 1; $i -le 12; $i++) {
        $r = Invoke-Az @AzArgs
        if ($r.Ok -or $r.Err -notmatch 'Forbidden|AuthorizationFailed|does not have (secrets|authorization)|403') { return $r }
        Write-Host "    (waiting for a new role assignment to take effect, $i/12)"
        Start-Sleep -Seconds 15
    }
    return $r
}

function Get-TokenOid {
    $t = Invoke-Az account get-access-token --query accessToken
    if (-not $t.Ok) { return "" }
    $payload = ([string]$t.Data).Split('.')[1].Replace('-', '+').Replace('_', '/')
    switch ($payload.Length % 4) { 2 { $payload += '==' } 3 { $payload += '=' } }
    return (([System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))) | ConvertFrom-Json).oid
}

Write-Host "================================================================"
Write-Host "AKS Manager bootstrap -- phase 1 (Let's Encrypt)"
Write-Host "================================================================"

# ── 1. Preflight ─────────────────────────────────────────────────────────────
foreach ($tool in @("az", "terraform")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Error "$tool is required and is not on PATH."
        exit 1
    }
}
$Python = @("python3", "python") | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
if (-not $Python) { Write-Error "python3 is required (it validates hosted-zones.json)."; exit 1 }
if (-not (Test-Path "hosted-zones.json")) {
    Write-Error "hosted-zones.json not found in $RepoRoot. Copy example-hosted-zones.json, fill it in and commit it."
    exit 1
}

$account = Assert-Az "Reading the az login" (Invoke-Az account show)
if ($account.tenantId -ne $TenantId) {
    Write-Error "az is signed in to tenant $($account.tenantId), not $TenantId. Run: az login --tenant $TenantId"
    exit 1
}
Assert-Az "Selecting subscription $SubscriptionId" (Invoke-Az account set --subscription $SubscriptionId) | Out-Null
Write-Host "Signed in as $($account.user.name) ($($account.user.type)); subscription $SubscriptionId"

$OperatorOid  = Get-TokenOid
$OperatorType = if ($account.user.type -eq "servicePrincipal") { "ServicePrincipal" } else { "User" }
if (-not $OperatorOid) { Write-Error "Could not read your object ID from the az token."; exit 1 }

# Direct assignments only; Owner through a group does not show here, so this
# warns rather than stops -- the first role grant below fails clearly anyway.
$myRoles = Invoke-Az role assignment list --assignee-object-id $OperatorOid --scope "/subscriptions/$SubscriptionId" `
    --include-inherited --query "[].roleDefinitionName"
if ($myRoles.Ok -and -not (@($myRoles.Data) | Where-Object { $_ -in @("Owner", "User Access Administrator", "Role Based Access Control Administrator") })) {
    Write-Warning "No direct Owner / User Access Administrator on the subscription found for you. If it comes through a group, ignore this; otherwise the role grants below will fail."
}

# The zone file, validated by the same script the scheduled job will use.
& $Python scripts/hosted_zones_tfvars.py
if ($LASTEXITCODE -ne 0) { Write-Error "hosted-zones.json did not validate (see above)."; exit 1 }
$TfvarsPath = "terraform/lets-encrypt/hosted-zones.auto.tfvars.json"
$zonesDoc = Get-Content $TfvarsPath -Raw | ConvertFrom-Json

# ── 2. Resource providers ────────────────────────────────────────────────────
Write-Host ""
Write-Host "Resource providers"
foreach ($ns in @("Microsoft.KeyVault", "Microsoft.Storage", "Microsoft.ManagedIdentity", "Microsoft.Network") + $(if ($AcrName) { @("Microsoft.ContainerRegistry") } else { @() })) {
    $state = Invoke-Az provider show --namespace $ns --query registrationState
    if ($state.Ok -and $state.Data -eq "Registered") { Write-Host "  = $ns"; continue }
    Assert-Az "Registering $ns" (Invoke-Az provider register --namespace $ns --wait) | Out-Null
    Write-Host "  + $ns registered"
}

# ── 3. Resource groups ───────────────────────────────────────────────────────
Write-Host ""
Write-Host "Resource groups"
foreach ($rg in @($SharedRg, $KeyVaultRg) + $(if ($AcrName) { @($AcrRg) } else { @() }) | Select-Object -Unique) {
    $g = Invoke-Az group show --name $rg
    if ($g.Ok) {
        Write-Host "  = $rg"
        Add-TagsIfUnowned $g.Data.id $g.Data.tags
        continue
    }
    if (-not (Test-NotFound $g.Err)) { Write-Error "Could not read resource group $rg`n$($g.Err)"; exit 1 }
    # Created untagged, then merge-tagged -- `group create --tags` on an
    # existing group would replace its tags.
    $c = Assert-Az "Creating resource group $rg" (Invoke-Az group create --name $rg --location $Location)
    Add-TagsIfUnowned $c.id $null
    Write-Host "  + $rg created in $Location"
}

# ── 4. Terraform state ───────────────────────────────────────────────────────
Write-Host ""
Write-Host "Terraform state: $StateAccount / $StateContainer"
$sa = Invoke-Az storage account show --name $StateAccount --resource-group $SharedRg
$StatePreexisted = $sa.Ok
if (-not $sa.Ok) {
    if (-not (Test-NotFound $sa.Err)) { Write-Error "Could not read storage account $StateAccount`n$($sa.Err)"; exit 1 }
    $avail = Assert-Az "Checking the name $StateAccount" (Invoke-Az storage account check-name --name $StateAccount)
    if (-not $avail.nameAvailable) {
        Write-Error "The storage account name $StateAccount is taken elsewhere in Azure ($($avail.reason)). Storage account names are global; this one is derived from the subscription ID, so this is a rare clash -- tell GitOps Manager support."
        exit 1
    }
    # The state holds the ACME account key and every certificate's private key:
    # Entra ID access only, never an account key.
    $sa = Invoke-Az storage account create --name $StateAccount --resource-group $SharedRg --location $Location `
        --sku Standard_LRS --kind StorageV2 --allow-shared-key-access false --allow-blob-public-access false `
        --min-tls-version TLS1_2 --tags @TagArgs
    Assert-Az "Creating storage account $StateAccount" $sa | Out-Null
    Write-Host "  + storage account created"
} else {
    Write-Host "  = storage account exists"
}
$StateAccountId = (Assert-Az "Reading $StateAccount" (Invoke-Az storage account show --name $StateAccount --resource-group $SharedRg)).id
$ContainerScope = "$StateAccountId/blobServices/default/containers/$StateContainer"

# Blob data access before the container: creating it uses --auth-mode login.
Grant-Role $OperatorOid $OperatorType "Storage Blob Data Contributor" $StateAccountId "you"
$exists = Invoke-AzRetryAuth storage container exists --name $StateContainer --account-name $StateAccount --auth-mode login
if (-not ($exists.Ok -and $exists.Data.exists)) {
    Assert-Az "Creating container $StateContainer" (Invoke-AzRetryAuth storage container create --name $StateContainer `
        --account-name $StateAccount --auth-mode login) | Out-Null
    Write-Host "  + container $StateContainer created"
} else {
    Write-Host "  = container $StateContainer exists"
}

# ── 5. Key Vault ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "Key Vault: $KeyVaultName"
$kv = Invoke-Az keyvault show --name $KeyVaultName --resource-group $KeyVaultRg
if ($kv.Ok) {
    if (-not $kv.Data.properties.enableRbacAuthorization) {
        Write-Error @"
Key Vault $KeyVaultName uses access policies, not Azure RBAC.

This script will not switch it: changing the permission model cuts off everyone
who relies on the access policies, the agent included. Switch it deliberately
(Access configuration -> Azure role-based access control) after granting the
equivalent roles, or use a different vault.
"@
        exit 1
    }
    if ($kv.Data.properties.networkAcls -and $kv.Data.properties.networkAcls.defaultAction -eq "Deny") {
        Write-Warning "Key Vault $KeyVaultName restricts network access. The scheduled certificate job runs from public Container Apps addresses and will need to be allowed in."
    }
    Write-Host "  = exists (RBAC)"
    Add-TagsIfUnowned $kv.Data.id $kv.Data.tags
} else {
    if (-not (Test-NotFound $kv.Err)) { Write-Error "Could not read Key Vault $KeyVaultName`n$($kv.Err)"; exit 1 }
    $deleted = Invoke-Az keyvault list-deleted --resource-type vault --query "[?name=='$KeyVaultName']"
    if ($deleted.Ok -and @($deleted.Data).Count -gt 0) {
        Write-Error @"
A deleted Key Vault named $KeyVaultName is still held by soft delete, so the name
cannot be used. Either recover it:

    az keyvault recover --name $KeyVaultName

or choose a different KEY_VAULT_NAME. It is not purged automatically.
"@
        exit 1
    }
    $kv = Invoke-Az keyvault create --name $KeyVaultName --resource-group $KeyVaultRg --location $Location `
        --enable-rbac-authorization true --enable-purge-protection true --retention-days 90 --tags @TagArgs
    Assert-Az "Creating Key Vault $KeyVaultName" $kv | Out-Null
    Write-Host "  + created (RBAC, purge protection, 90-day soft delete)"
    $kv = Invoke-Az keyvault show --name $KeyVaultName --resource-group $KeyVaultRg
}
$KeyVaultId = $kv.Data.id
Grant-Role $OperatorOid $OperatorType "Key Vault Secrets Officer" $KeyVaultId "you"

# ── 6. Container registry (optional in phase 1) ──────────────────────────────
if ($AcrName) {
    Write-Host ""
    Write-Host "Container registry: $AcrName"
    $acr = Invoke-Az acr show --name $AcrName --resource-group $AcrRg
    if ($acr.Ok) {
        Write-Host "  = exists ($($acr.Data.sku.name))"
        if ($PSBoundParameters.ContainsKey("ContainerRegistrySku") -and $acr.Data.sku.name -ne $ContainerRegistrySku) {
            Write-Warning "$AcrName is $($acr.Data.sku.name); -ContainerRegistrySku $ContainerRegistrySku applies only to a new registry, so it was left as is. To change it: az acr update -n $AcrName --sku $ContainerRegistrySku"
        }
        Add-TagsIfUnowned $acr.Data.id $acr.Data.tags
    } else {
        if (-not (Test-NotFound $acr.Err)) { Write-Error "Could not read registry $AcrName`n$($acr.Err)"; exit 1 }
        $avail = Assert-Az "Checking the name $AcrName" (Invoke-Az acr check-name --name $AcrName)
        if (-not $avail.nameAvailable) { Write-Error "Registry name $AcrName is taken elsewhere in Azure: $($avail.message)"; exit 1 }
        Assert-Az "Creating registry $AcrName" (Invoke-Az acr create --name $AcrName --resource-group $AcrRg `
            --location $Location --sku $ContainerRegistrySku --admin-enabled false --tags @TagArgs) | Out-Null
        Write-Host "  + created ($ContainerRegistrySku, admin user disabled)"
    }
}

# ── 7. Certificate job identity and its roles ────────────────────────────────
Write-Host ""
Write-Host "Certificate identity: $CertIdentity"
$id = Invoke-Az identity show --name $CertIdentity --resource-group $SharedRg
if (-not $id.Ok) {
    if (-not (Test-NotFound $id.Err)) { Write-Error "Could not read identity $CertIdentity`n$($id.Err)"; exit 1 }
    $id = Invoke-Az identity create --name $CertIdentity --resource-group $SharedRg --location $Location --tags @TagArgs
    Assert-Az "Creating identity $CertIdentity" $id | Out-Null
    Write-Host "  + created"
} else {
    Write-Host "  = exists"
}
$CertPrincipalId = $id.Data.principalId
Grant-Role $CertPrincipalId "ServicePrincipal" "Key Vault Secrets Officer" $KeyVaultId $CertIdentity
Grant-Role $CertPrincipalId "ServicePrincipal" "Storage Blob Data Contributor" $ContainerScope $CertIdentity

# The DNS-01 role is the customer's (example-cert-manager-role.json). Checked
# once up front so a missing definition is one clear message, not one per zone.
$roleDef = Invoke-Az role definition list --name $CertDnsRole --scope "/subscriptions/$SubscriptionId"
if (-not ($roleDef.Ok -and @($roleDef.Data).Count -gt 0)) {
    Write-Error @"
The role '$CertDnsRole' does not exist (or is not assignable in $SubscriptionId).

Create it from example-cert-manager-role.json (see the comment in that file), or
use the built-in role instead, at the cost of allowing every record type:

    `$env:CERT_DNS_ROLE = "DNS Zone Contributor"
"@
    exit 1
}
foreach ($z in $zonesDoc.hosted_zones.PSObject.Properties.Value) {
    $zoneId = "/subscriptions/$($z.subscription_id)/resourceGroups/$($z.resource_group)/providers/Microsoft.Network/dnszones/$($z.public_dns_zone)"
    $zone = Invoke-Az network dns zone show --ids $zoneId
    if (-not $zone.Ok) {
        Write-Error "Public zone $($z.public_dns_zone) not found at $zoneId -- hosted-zones.json must list zones that exist.`n$($zone.Err)"
        exit 1
    }
    Grant-Role $CertPrincipalId "ServicePrincipal" $CertDnsRole $zoneId "$CertIdentity on $($z.public_dns_zone)"
}

# ── 8. Vault guard ───────────────────────────────────────────────────────────
# Manual wins where they overlap. A <prefix>-dns-zone-certs that the pipeline
# did not write is a certificate somebody saved by hand; Terraform would fail
# "already exists" on it, or -- if it is soft-deleted -- recover it and write
# over it. Such zones are left out of this run, and the rest go ahead.
Write-Host ""
Write-Host "Vault guard"
$blocked = @()
$kept = [ordered]@{}
foreach ($p in $zonesDoc.hosted_zones.PSObject.Properties) {
    $z = $p.Value
    $secret = ($z.dns_zone_prefix -replace '_', '-') + "-dns-zone-certs"
    $live = Invoke-AzRetryAuth keyvault secret show --vault-name $KeyVaultName --name $secret --query "{tags:tags}"
    if ($live.Ok) {
        $owner = Get-ManagedBy $live.Data.tags
        if ($owner -ne "Terraform") {
            $blocked += "$($z.public_dns_zone): $secret is a manually saved certificate (managed_by='$owner'). Give this zone a different dns-zone-prefix in hosted-zones.json."
            continue
        }
    } elseif (Test-NotFound $live.Err) {
        $gone = Invoke-AzRetryAuth keyvault secret show-deleted --vault-name $KeyVaultName --name $secret --query "{tags:tags}"
        if ($gone.Ok -and (Get-ManagedBy $gone.Data.tags) -ne "Terraform") {
            $blocked += "$($z.public_dns_zone): $secret was deleted but not purged, and is not the pipeline's. Purge it (az keyvault secret purge --vault-name $KeyVaultName --name $secret) or choose a different prefix."
            continue
        }
    } else {
        Write-Error "Could not read $secret in $KeyVaultName`n$($live.Err)"
        exit 1
    }
    $kept[$p.Name] = $z
    Write-Host "  ok $($z.dns_zone_prefix) -> $secret"
}
foreach ($b in $blocked) { Write-Warning "SKIPPED $b" }
if ($kept.Count -eq 0) {
    Write-Error "Every zone was skipped by the vault guard -- nothing to issue."
    exit 1
}
if ($blocked.Count -gt 0) {
    $zonesDoc.hosted_zones = [pscustomobject]$kept
    ($zonesDoc | ConvertTo-Json -Depth 5) | Set-Content $TfvarsPath -Encoding utf8
}

# ── 9. pinned.auto.tfvars.json in the private repo ───────────────────────────
# The GitHub App's credentials live only in the Key Vault (written there by the
# bootstrap App install). Read with your az login, used for one token, dropped.
Write-Host ""
Write-Host "GitHub: pinned.auto.tfvars.json"
$app = Invoke-AzRetryAuth keyvault secret show --vault-name $KeyVaultName --name $AppSecretName --query value
if (-not $app.Ok) {
    Write-Error "Could not read $AppSecretName from $KeyVaultName -- install the AKS Manager bootstrap GitHub App from Settings first.`n$($app.Err)"
    exit 1
}
$appCreds  = ([string]$app.Data) | ConvertFrom-Json
$GithubOrg = $appCreds.githubOrg
$GithubInstallId = $appCreds.installId
$GithubRepoName = "aksmanager-bootstrap"
if (-not ($appCreds.appId -and $appCreds.privateKey -and $GithubInstallId -and $GithubOrg)) {
    Write-Error "$AppSecretName in $KeyVaultName is incomplete (needs appId, installId, privateKey, githubOrg). Reinstall the bootstrap GitHub App from Settings."
    exit 1
}

function ConvertTo-Base64Url([byte[]] $Bytes) {
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}
$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$jwtUnsigned = (ConvertTo-Base64Url ([System.Text.Encoding]::UTF8.GetBytes('{"alg":"RS256","typ":"JWT"}'))) + "." +
               (ConvertTo-Base64Url ([System.Text.Encoding]::UTF8.GetBytes("{`"iat`":$($now - 60),`"exp`":$($now + 540),`"iss`":`"$($appCreds.appId)`"}")))
$rsa = [System.Security.Cryptography.RSA]::Create()
$rsa.ImportFromPem([System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($appCreds.privateKey)))
$sig = $rsa.SignData([System.Text.Encoding]::UTF8.GetBytes($jwtUnsigned),
    [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
$appJwt = "$jwtUnsigned.$(ConvertTo-Base64Url $sig)"
$rsa.Dispose()
Remove-Variable appCreds, app -ErrorAction SilentlyContinue

$installToken = (Invoke-RestMethod -Method Post `
    -Uri "https://api.github.com/app/installations/$GithubInstallId/access_tokens" `
    -Headers @{ Authorization = "Bearer $appJwt"; Accept = "application/vnd.github+json" }).token
Remove-Variable appJwt -ErrorAction SilentlyContinue
if (-not $installToken) { Write-Error "Could not get a GitHub App installation token."; exit 1 }

$pinned = [ordered]@{
    tenant_id                         = $TenantId
    shared_services_subscription_id   = $SubscriptionId
    location                          = $Location
    shared_services_resource_group    = $SharedRg
    key_vault_name                    = $KeyVaultName
    key_vault_resource_group          = $KeyVaultRg
    container_registry_name           = $AcrName
    container_registry_resource_group = $(if ($AcrName) { $AcrRg } else { "" })
    agent_vm_name                     = $AgentVmName
    agent_vnet_id                     = $AgentVnetId
    agent_subnet_name                 = $AgentSubnetName
    resource_tag_name                 = $CostTagName
    resource_tag_value                = $CostTagValue
    state_storage_account             = $StateAccount
    cert_identity_client_id           = $id.Data.clientId
}
$pinnedJson = $pinned | ConvertTo-Json
$headers = @{ Authorization = "Bearer $installToken"; Accept = "application/vnd.github+json" }
$fileUri = "https://api.github.com/repos/$GithubOrg/$GithubRepoName/contents/pinned.auto.tfvars.json"
$sha = $null
try { $sha = (Invoke-RestMethod -Method Get -Uri $fileUri -Headers $headers).sha }
catch { if ($_.Exception.Response.StatusCode.value__ -ne 404) { Write-Error "Could not read pinned.auto.tfvars.json from $GithubOrg/$GithubRepoName -- $_"; exit 1 } }
$body = [ordered]@{
    message = "Update pinned.auto.tfvars.json via setup-pipeline.ps1"
    content = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($pinnedJson))
}
if ($sha) { $body.sha = $sha }
try {
    Invoke-RestMethod -Method Put -Uri $fileUri -Headers $headers -Body ($body | ConvertTo-Json) -ContentType "application/json" | Out-Null
    Write-Host "  $(if ($sha) { 'updated' } else { 'created' }) in $GithubOrg/$GithubRepoName (git pull to see it locally)"
} catch {
    Write-Error "Could not write pinned.auto.tfvars.json to $GithubOrg/$GithubRepoName -- $_"
    exit 1
}
Remove-Variable installToken -ErrorAction SilentlyContinue

# ── 10. terraform/lets-encrypt ───────────────────────────────────────────────
Write-Host ""
Write-Host "terraform/lets-encrypt"
Push-Location "terraform/lets-encrypt"
try {
    terraform init -input=false -reconfigure `
        "-backend-config=storage_account_name=$StateAccount" `
        "-backend-config=container_name=$StateContainer" `
        "-backend-config=key=$StateKey" `
        "-backend-config=resource_group_name=$SharedRg" `
        "-backend-config=subscription_id=$SubscriptionId" `
        "-backend-config=tenant_id=$TenantId"
    if ($LASTEXITCODE -ne 0) { Write-Error "terraform init failed."; exit 1 }

    # Empty-state guard, as on AWS. If the state account predates this run and
    # the state is empty while pipeline-written certificates exist, the state
    # was lost: applying would try to recreate every secret.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $stateList = @(terraform state list 2>$null)
    $ErrorActionPreference = $prevEap
    $managed = @($stateList | Where-Object { $_ -and $_ -notmatch '^data\.' }).Count
    if ($StatePreexisted -and $managed -eq 0 -and $env:AKSMANAGER_ALLOW_EMPTY_STATE -ne "true") {
        $ours = Invoke-AzRetryAuth keyvault secret list --vault-name $KeyVaultName --query "[?tags.managed_by=='Terraform'].name"
        if ($ours.Ok -and @($ours.Data).Count -gt 0) {
            Write-Error @"
The Terraform state for lets-encrypt is empty, but $KeyVaultName already holds
certificates the pipeline wrote ($(@($ours.Data) -join ', ')). The state has been
lost, not never created; applying would try to recreate them.

Check the blob's versions before anything else:

    az storage blob list --account-name $StateAccount --container-name $StateContainer --auth-mode login --include v -o table

If this really is a fresh start, re-run with `$env:AKSMANAGER_ALLOW_EMPTY_STATE = "true".
"@
            exit 1
        }
    }

    terraform apply `
        "-var=shared_services_subscription_id=$SubscriptionId" `
        "-var=key_vault_id=$KeyVaultId" `
        "-var=azure_auth_method=cli"
    if ($LASTEXITCODE -ne 0) { Write-Error "terraform apply did not complete."; exit 1 }
} finally {
    Pop-Location
}

Write-Host ""
Write-Host "================================================================"
Write-Host "Phase 1 done."
Write-Host "  State:      $StateAccount/$StateContainer/$StateKey"
Write-Host "  Key Vault:  $KeyVaultName"
Write-Host "  Identity:   $CertIdentity ($($id.Data.clientId))"
if ($blocked.Count -gt 0) {
    Write-Host ""
    Write-Host "Skipped by the vault guard:"
    foreach ($b in $blocked) { Write-Host "  - $b" }
}
Write-Host ""
Write-Host "Check a certificate:"
Write-Host "  az keyvault secret show --vault-name $KeyVaultName -n <prefix>-dns-zone-certs --query `"{expires:attributes.expires, tags:tags}`""
Write-Host "================================================================"
