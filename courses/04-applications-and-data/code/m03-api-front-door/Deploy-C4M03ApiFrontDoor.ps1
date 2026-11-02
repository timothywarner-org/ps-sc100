#Requires -Version 7.0

<#
.SYNOPSIS
Plans, deploys, reads, tests, or removes the Globomantics API front door lab for SC-100 Course 4, Module 3.

.DESCRIPTION
Builds the design behind the demo "Read the API front door" in your own Azure subscription: the
Connected Equipment API behind Azure Front Door Premium and its web application firewall (WAF), with
Azure API Management validating the partner's token and the Front Door ID, and a pipeline identity
that federates with GitHub instead of storing a secret. iac\main.bicep is the only template source and
documents every resource. iac\cancel-order-policy.xml is the gateway policy you read in the portal.

WHAT EACH MODE CHANGES
    Plan    Changes nothing. Compiles the template and runs what-if against the resource group.
    Deploy  Creates the resource group rg-globomantics-c4m03 (tagged course=SC100-C4M03) if it's
            missing, then deploys the template into it. Safe to rerun: it converges.
    Show    Changes nothing. Reads each layer back from Azure and prints the settings that carry a
            design decision: WAF mode, rule sets, custom rules and exclusions; the gateway policy;
            and the pipeline identity's federated credential and role assignments.
    Test    Changes nothing in Azure. Sends three requests and explains each answer:
              ordinary   through Front Door, no token   expect 401 from validate-jwt
              injection  through Front Door, SQLi text  expect 403 from the WAF, at the edge
              direct     straight to the gateway        expect 403 from check-header
            Then it looks for the injection request's entry in the WAF log, to prove the block was
            recorded as well as enforced.
    Remove  Deletes the resource group, then purges the soft-deleted API Management instance so its
            name is free for the next Deploy.

SAFETY RAILS, each one a mistake this script refuses to make
    * Wrong subscription or tenant    -> pass -SubscriptionId or -TenantId and it stops before any
                                         write when your Azure CLI context doesn't match.
    * Someone else's resource group   -> refuses unless the group carries the course tag.
    * Soft-deleted name clash         -> Deploy stops early if a deleted API Management instance still
                                         holds the lab's name, and prints the purge command.
    * Deleting the wrong group        -> Remove re-reads the tag immediately before deleting.

.PARAMETER Mode
Plan (the default), Deploy, Show, Test, or Remove.

.PARAMETER PublisherEmail
Required for Plan and Deploy. The publisher contact address API Management requires. Use an address
you own.

.PARAMETER SubscriptionId
Optional. The subscription to work in. Leave it out and the script uses your current Azure CLI
subscription (az account show). Supply it and every call is pinned to it.

.PARAMETER TenantId
Optional. The Microsoft Entra tenant you expect to be working in. Supply it and the script refuses to
continue when the subscription belongs to a different tenant.

.PARAMETER Location
Region for a new resource group. Defaults to eastus2. When the group already exists, the script uses
the group's region instead.

.PARAMETER EdgeWaitMinutes
How long Test keeps retrying while a new Front Door endpoint propagates. Default 25.

.PARAMETER LogWaitMinutes
How long Test waits for the injection request's WAF log entry to reach the workspace. Default 15.

.EXAMPLE
pwsh -NoProfile -File .\Deploy-C4M03ApiFrontDoor.ps1 -Mode Plan -PublisherEmail '<your-email-address>'
Compiles the template and shows what a deployment would change. Changes nothing.

.EXAMPLE
pwsh -NoProfile -File .\Deploy-C4M03ApiFrontDoor.ps1 -Mode Deploy -PublisherEmail '<your-email-address>'
Deploys the lab into your current Azure CLI subscription. API Management Developer takes 30 to 45
minutes the first time.

.EXAMPLE
pwsh -NoProfile -File .\Deploy-C4M03ApiFrontDoor.ps1 -Mode Show
Reads the edge, the gateway and the pipeline identity back from Azure.

.EXAMPLE
pwsh -NoProfile -File .\Deploy-C4M03ApiFrontDoor.ps1 -Mode Test
Proves which layer stops which request, and that the WAF logged its block.

.EXAMPLE
pwsh -NoProfile -File .\Deploy-C4M03ApiFrontDoor.ps1 -Mode Remove
Deletes the lab and purges the soft-deleted API Management instance. Run this when you're done.

.NOTES
PREREQUISITES
    * PowerShell 7 and the Azure CLI, signed in with az login. Install the Bicep CLI with
      az bicep install if you don't already have it.
    * Contributor on the subscription. The template creates no role assignments.

COST
    This lab creates billable Azure resources, and it bills by the hour whether or not you use it.
    Front Door Premium carries a base fee, and API Management Developer bills by the hour too. In
    East US 2 at October 2026 retail prices the pair came to about 0.52 USD an hour. Check the Azure
    pricing pages for your region, and remove the lab the same day you build it.

CLEANUP
    pwsh -NoProfile -File .\Deploy-C4M03ApiFrontDoor.ps1 -Mode Remove

    Or by hand. API Management is soft-deleted, so purge it once the group delete finishes, or its
    name stays reserved for 48 hours:
    az group delete --name rg-globomantics-c4m03 --yes
    az apim deletedservice list -o table
    az apim deletedservice purge --service-name <apim-name> --location <region>
#>
[CmdletBinding()]
param(
    [ValidateSet('Plan', 'Deploy', 'Show', 'Test', 'Remove')]
    [string]$Mode = 'Plan',

    [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')]
    [string]$PublisherEmail,

    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$TenantId,

    [ValidatePattern('^[a-z0-9]{3,40}$')]
    [string]$Location = 'eastus2',

    [ValidateRange(0, 60)][int]$EdgeWaitMinutes = 25,
    [ValidateRange(0, 60)][int]$LogWaitMinutes = 15
)

$ErrorActionPreference = 'Stop'
$group = 'rg-globomantics-c4m03'
$tag = 'SC100-C4M03'
$apimPrefix = 'apim-glb-c4m03-'
$names = @{ Profile = 'afd-glb-c4m03'; Endpoint = 'connected-equipment'; Waf = 'glbConnectedEquipmentWaf'
            Api = 'connected-equipment-api'; Operation = 'cancel-order'; Identity = 'id-glb-ce-pipeline'; Workspace = 'law-glb-c4m03' }
$apiVersion = @{ Apim = '2024-05-01'; Cdn = '2025-06-01'; Waf = '2025-03-01'; Msi = '2024-11-30'; Law = '2025-07-01' }
$wafLogCategory = 'FrontDoorWebApplicationFirewallLog'
# The template ships beside this script, so the lab works from wherever you unzip it.
$template = Join-Path $PSScriptRoot 'iac' 'main.bicep'

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'The Azure CLI (az) is not on your PATH. Install it, run az login, then rerun this script.'
}
if (-not (Test-Path -LiteralPath $template) -or -not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'iac' 'cancel-order-policy.xml'))) {
    throw "The iac folder must sit next to this script and hold main.bicep and cancel-order-policy.xml."
}
if ($Mode -in 'Plan', 'Deploy' -and -not $PublisherEmail) {
    # what-if evaluates the template's parameters too, so Plan needs the same value Deploy will use.
    throw "$Mode needs -PublisherEmail. API Management requires a publisher contact address at creation."
}

# One wrapper for every Azure CLI call. It pins the subscription once one is known, asks for JSON, and
# throws on a non-zero exit, so a failed call can never hand back an empty result that looks like
# "nothing exists".
function Invoke-CourseAz {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $scoped = if ($SubscriptionId) { $Arguments + @('--subscription', $SubscriptionId) } else { $Arguments }
    $raw = & az @scoped --only-show-errors -o json
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI call failed: az $($Arguments[0..1] -join ' ')" }
    if ($raw) { ($raw -join "`n") | ConvertFrom-Json }
}

# Reads from Azure Resource Manager go through Invoke-WebRequest, not az rest. On Windows, az is a
# .cmd file, so cmd.exe re-parses its arguments and an & or a $filter inside a URL breaks the call.
# Invoke-WebRequest takes the URL as one string and never reaches cmd.exe.
$script:Tokens = @{}
function Get-BearerHeader {
    param([Parameter(Mandatory)][string]$Resource)
    $cached = $script:Tokens[$Resource]
    if (-not $cached -or ((Get-Date) - $cached.At).TotalMinutes -gt 30) {
        $t = Invoke-CourseAz @('account', 'get-access-token', '--resource', $Resource)
        $cached = @{ Token = $t.accessToken; At = Get-Date }
        $script:Tokens[$Resource] = $cached
    }
    return @{ Authorization = "Bearer $($cached.Token)" }
}

function Invoke-Arm {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$ApiVersion, [string]$Query, [switch]$AllowNotFound)
    # ${Path} needs braces: PowerShell allows ? inside a variable name, so "$Path?api" would read 'Path?'.
    $uri = "https://management.azure.com${Path}?api-version=$ApiVersion"
    if ($Query) { $uri += "&$Query" }
    $resp = Invoke-WebRequest -Uri $uri -Headers (Get-BearerHeader 'https://management.azure.com/') -SkipHttpErrorCheck -TimeoutSec 60
    if ($resp.StatusCode -eq 404 -and $AllowNotFound) { return $null }
    if ($resp.StatusCode -ge 400) { throw "ARM GET $Path returned $($resp.StatusCode): $($resp.Content)" }
    if ($resp.Content) { return $resp.Content | ConvertFrom-Json }
}

# Compile first and offline: a template error should stop the run before anything touches Azure.
$null = & az bicep build --file $template --stdout --only-show-errors
if ($LASTEXITCODE -ne 0) { throw "The template didn't compile: $template" }

$account = Invoke-CourseAz @('account', 'show')
if ($TenantId -and $account.tenantId -ne $TenantId) {
    throw "Subscription '$($account.name)' belongs to tenant $($account.tenantId), not $TenantId. Refusing to continue."
}
# Pin every later call to the subscription just checked, even if the CLI default changes mid-run.
$SubscriptionId = $account.id
$rgPath = "/subscriptions/$SubscriptionId/resourceGroups/$group"
Write-Host "[CONTEXT] $($account.user.name) | $($account.name) | $Mode"

$exists = Invoke-CourseAz @('group', 'exists', '-n', $group)
if ($exists) {
    $current = Invoke-CourseAz @('group', 'show', '-n', $group)
    if ($current.tags.course -ne $tag) { throw "Ownership mismatch: $group exists but isn't tagged course=$tag. Refusing to touch it." }
    $Location = $current.location
}
if ($Mode -in 'Show', 'Test' -and -not $exists) { throw "$group doesn't exist yet. Run -Mode Deploy first." }

function Get-LabApim {
    $list = Invoke-Arm -Path "$rgPath/providers/Microsoft.ApiManagement/service" -ApiVersion $apiVersion.Apim -AllowNotFound
    return @($list.value | Where-Object { $_ -and $_.name -like "$apimPrefix*" }) | Select-Object -First 1
}

switch ($Mode) {
    'Remove' {
        if (-not $exists) { Write-Host "[PASS] $group is already absent"; return }
        # Capture the API Management name BEFORE the group goes, so it can be purged after.
        $apim = Get-LabApim
        $recheck = Invoke-CourseAz @('group', 'show', '-n', $group)
        if ($recheck.tags.course -ne $tag) { throw 'Tag changed between checks; refusing to delete.' }
        # No --no-wait: the purge below only works once the delete has finished. Expect several minutes.
        Write-Host "[REMOVE] Deleting $group and waiting for it to finish..."
        $null = Invoke-CourseAz @('group', 'delete', '-n', $group, '--yes')
        if ($apim) {
            $null = Invoke-CourseAz @('apim', 'deletedservice', 'purge', '--service-name', $apim.name, '--location', $Location)
            Write-Host "[PASS] Purged soft-deleted API Management instance $($apim.name)"
        }
        # The workspace goes into soft delete for 14 days and isn't billed there, so it needs no purge.
        Write-Host "[PASS] $group removed. Check Cost Management tomorrow to confirm the charges stopped."
        return
    }
    { $_ -in 'Plan', 'Deploy' } {
        if ($Mode -eq 'Deploy') {
            # A deleted API Management instance holds its name for 48 hours, so a Deploy right after a
            # Remove would fail 40 minutes in. Catch it now.
            $deleted = @((Invoke-CourseAz @('apim', 'deletedservice', 'list')) | Where-Object { $_ -and $_.name -like "$apimPrefix*" })
            if ($deleted.Count -and -not (Get-LabApim)) {
                throw "A soft-deleted API Management instance still holds $($deleted[0].name). Purge it first: az apim deletedservice purge --service-name $($deleted[0].name) --location $($deleted[0].location)"
            }
            if (-not $exists) {
                $null = Invoke-CourseAz @('group', 'create', '-n', $group, '-l', $Location, '--tags', "course=$tag", 'company=Globomantics', 'purpose=course-lab', 'teardown=after-course')
                Write-Host "[PASS] Created $group in $Location"
            }
        } elseif (-not $exists) {
            # what-if needs an existing group. Report that instead of creating one in a no-change mode.
            Write-Host "[PLAN] $group doesn't exist yet. Deploy creates it with the course tag; the template compiled cleanly."
            return
        }
        $action = if ($Mode -eq 'Plan') { 'what-if' } else { 'create' }
        # Your own tenant ID goes in as a secure parameter, so ARM keeps it out of the deployment history.
        $arguments = @('deployment', 'group', $action, '-g', $group, '--name', 'c4m03-api-front-door', '--template-file', $template,
                       '--parameters', "tokenTenantId=$($account.tenantId)", "publisherEmail=$PublisherEmail")
        if ($Mode -eq 'Plan') { $arguments += '--no-pretty-print' }
        if ($Mode -eq 'Deploy') { Write-Host '[DEPLOY] Starting. API Management Developer takes 30 to 45 minutes the first time.' }
        $result = Invoke-CourseAz $arguments
        if ($Mode -eq 'Deploy') {
            $o = $result.properties.outputs
            Write-Host "[RESULT] $($result.properties.provisioningState): $($o.apimName.value), endpoint $($o.endpointHost.value)"
            Write-Host '[NEXT] Run -Mode Show to read each layer. A new Front Door endpoint can take 20 minutes or more to answer, so give it time before -Mode Test.'
            Write-Host '[COST] The lab bills by the hour from now on. Run -Mode Remove the same day.'
        } else {
            $changes = @($result.changes)
            Write-Host "[PLAN] what-if: $(@($changes | Group-Object changeType | ForEach-Object { "$($_.Name) $($_.Count)" }) -join ', ')"
            foreach ($c in $changes) { Write-Host ('  {0,-10}{1}' -f $c.changeType, ($c.resourceId -split '/providers/', 2)[-1]) }
        }
        return
    }
}

# ------------------------------------------------------------------ Show and Test read the live lab
$apim = Get-LabApim
$profilePath = "$rgPath/providers/Microsoft.Cdn/profiles/$($names.Profile)"
$frontDoor = Invoke-Arm -Path $profilePath -ApiVersion $apiVersion.Cdn -AllowNotFound
$endpoint = Invoke-Arm -Path "$profilePath/afdEndpoints/$($names.Endpoint)" -ApiVersion $apiVersion.Cdn -AllowNotFound
if (-not $apim -or -not $frontDoor -or -not $endpoint) { throw 'The lab is incomplete. Run -Mode Deploy again; it converges.' }
$gatewayHost = ([string]$apim.properties.gatewayUrl) -replace '^https://', ''

if ($Mode -eq 'Show') {
    $waf = Invoke-Arm -Path "$rgPath/providers/Microsoft.Network/FrontDoorWebApplicationFirewallPolicies/$($names.Waf)" -ApiVersion $apiVersion.Waf
    $w = $waf.properties
    Write-Host ''
    Write-Host 'THE EDGE: Front Door Premium and its WAF policy'
    Write-Host "  Mode                $($w.policySettings.mode)   (Prevention blocks; Detection only logs)"
    foreach ($set in @($w.managedRules.managedRuleSets)) {
        $ex = @($set.exclusions | Where-Object { $_ }).Count
        Write-Host ("  Managed rule set    {0} {1}, {2} exclusion(s)" -f $set.ruleSetType, $set.ruleSetVersion, $ex)
    }
    foreach ($r in @($w.customRules.rules)) {
        Write-Host ("  Custom rule         {0}, priority {1}, {2}, {3} a minute, action {4}" -f $r.name, $r.priority, $r.ruleType, $r.rateLimitThreshold, $r.action)
    }
    # "The latest Default Rule Set" moves, so compare against Microsoft's live list.
    $sets = Invoke-Arm -Path "/subscriptions/$SubscriptionId/providers/Microsoft.Network/FrontDoorWebApplicationFirewallManagedRuleSets" -ApiVersion $apiVersion.Waf
    $latest = @($sets.value | Where-Object { $_.properties.ruleSetType -eq 'Microsoft_DefaultRuleSet' } | ForEach-Object { $_.properties.ruleSetVersion } |
                Where-Object { $_ -match '^\d+(\.\d+)+$' }) | Sort-Object { [version]$_ } | Select-Object -Last 1
    Write-Host "  Newest Default Rule Set Microsoft offers right now: $latest"
    Write-Host "  Front Door ID       $($frontDoor.properties.frontDoorId)   (compare with the glb-afd-id named value below)"

    $policy = Invoke-Arm -Path "$($apim.id)/apis/$($names.Api)/operations/$($names.Operation)/policies/policy" -ApiVersion $apiVersion.Apim -Query 'format=rawxml'
    $nv = Invoke-Arm -Path "$($apim.id)/namedValues/glb-afd-id" -ApiVersion $apiVersion.Apim -AllowNotFound
    $tenantNv = Invoke-Arm -Path "$($apim.id)/namedValues/glb-tenant-id" -ApiVersion $apiVersion.Apim -AllowNotFound
    Write-Host ''
    Write-Host "THE GATEWAY: API Management $($apim.name), Connected Equipment API, Cancel order"
    Write-Host "  glb-afd-id          $($nv.properties.value)"
    Write-Host "  glb-tenant-id       secret = $($tenantNv.properties.secret)   (masked in the portal)"
    Write-Host '  Inbound policy, in the order the gateway runs it:'
    ([string]$policy.properties.value -split "`r?`n") | Where-Object { $_.Trim() } | ForEach-Object { Write-Host "    $_" }

    $idPath = "$rgPath/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$($names.Identity)"
    $identity = Invoke-Arm -Path $idPath -ApiVersion $apiVersion.Msi
    $creds = @((Invoke-Arm -Path "$idPath/federatedIdentityCredentials" -ApiVersion $apiVersion.Msi).value | Where-Object { $_ })
    # A principalId filter returns assignments at, above and below the subscription scope.
    $filter = '$filter=' + [uri]::EscapeDataString("principalId eq '$($identity.properties.principalId)'")
    $roles = @((Invoke-Arm -Path "/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/roleAssignments" -ApiVersion '2022-04-01' -Query $filter).value | Where-Object { $_ })
    Write-Host ''
    Write-Host "THE PIPELINE: managed identity $($names.Identity)"
    foreach ($c in $creds) {
        Write-Host "  Federated credential $($c.name)"
        Write-Host "    Issuer            $($c.properties.issuer)"
        Write-Host "    Subject           $($c.properties.subject)"
        Write-Host "    Audience          $(@($c.properties.audiences) -join ', ')"
    }
    Write-Host "  Role assignments    $($roles.Count)   (what the pipeline may touch is a separate decision)"
    Write-Host ''
    Write-Host 'Ask yourself why the subject names one environment instead of the whole repository.'
    return
}

# ------------------------------------------------------------------ Test
function Invoke-EdgeProbe {
    <# Three requests, each status code meaning one thing:
         ordinary   401 = the WAF let it through, the Front Door ID check passed, and validate-jwt asked for a token
         injection  403 = blocked at the edge. If the WAF missed it, the gateway would answer 401 instead.
         direct     403 = check-header refused a request that skipped Front Door (no X-Azure-FDID)
       x-azure-ref is Front Door's per-request reference, and the WAF log records the same value, which is
       how the log lookup proves the blocked request was also recorded. #>
    $path = '/connected-equipment/orders/1042/cancel'
    $sqli = "?orderRef=1%27%20OR%20%271%27%3D%271"      # 1' OR '1'='1, the textbook tautology
    $probes = @(
        [pscustomobject]@{ Name = 'ordinary';  Uri = "https://$($endpoint.properties.hostName)$path";      Expect = 401 }
        [pscustomobject]@{ Name = 'injection'; Uri = "https://$($endpoint.properties.hostName)$path$sqli"; Expect = 403 }
        [pscustomobject]@{ Name = 'direct';    Uri = "https://$gatewayHost$path";                          Expect = 403 }
    )
    foreach ($pr in $probes) {
        $code = 0; $ref = ''
        try {
            $r = Invoke-WebRequest -Uri $pr.Uri -Method Post -Body '{"reason":"customer request"}' -ContentType 'application/json' -SkipHttpErrorCheck -TimeoutSec 30
            $code = [int]$r.StatusCode
            # Match the header name case-blind: proxies are free to change header casing.
            $key = $r.Headers.Keys | Where-Object { $_ -ieq 'x-azure-ref' } | Select-Object -First 1
            if ($key) { $ref = [string]($r.Headers[$key] | Select-Object -First 1) }
        } catch { $code = 0 }
        [pscustomobject]@{ Name = $pr.Name; Expect = $pr.Expect; Status = $code; Pass = ($code -eq $pr.Expect); AzureRef = $ref }
    }
}

$deadline = (Get-Date).AddMinutes($EdgeWaitMinutes)
do {
    $results = @(Invoke-EdgeProbe)
    $ordinary = $results | Where-Object Name -eq 'ordinary'
    $injection = $results | Where-Object Name -eq 'injection'
    # A new endpoint answers 404 until it has propagated, and an injection that reaches the gateway
    # (401) means the security policy isn't enforcing yet. Both settle on their own, so wait.
    $propagating = $ordinary.Status -in 0, 404 -or $injection.Status -eq 401
    if (-not $propagating -or (Get-Date) -ge $deadline) { break }
    Write-Host '[WAIT] Front Door is still propagating. Retrying in 60 seconds.'
    Start-Sleep -Seconds 60
} while ($true)

foreach ($r in $results) {
    Write-Host ('[{0}] {1,-9} expected {2}, got {3}' -f $(if ($r.Pass) { 'PASS' } else { 'FAIL' }), $r.Name, $r.Expect, $r.Status)
}
if (@($results | Where-Object { -not $_.Pass }).Count) {
    Write-Host '[RESULT] Not every layer answered as designed. If the ordinary request got 403, the WAF blocked legitimate traffic: switch the policy to Detection, find the rule in the WAF log, and add the narrowest exclusion you can justify.'
    exit 1
}
Write-Host '[RESULT] The ordinary request reached the gateway, the injection was blocked at the edge, and the direct call was refused.'

# Blocked AND logged: look for the injection request's WAF log entry by its x-azure-ref.
$workspace = Invoke-Arm -Path "$rgPath/providers/Microsoft.OperationalInsights/workspaces/$($names.Workspace)" -ApiVersion $apiVersion.Law
$query = @{ query = "AzureDiagnostics | where Category == '$wafLogCategory' | take 500"; timespan = 'PT2H' } | ConvertTo-Json
$logDeadline = (Get-Date).AddMinutes($LogWaitMinutes)
$found = $null
do {
    $resp = Invoke-WebRequest -Uri "https://api.loganalytics.azure.com/v1/workspaces/$($workspace.properties.customerId)/query" -Method Post `
                              -Headers (Get-BearerHeader 'https://api.loganalytics.io') -ContentType 'application/json' -Body $query -SkipHttpErrorCheck -TimeoutSec 60
    # Before the first WAF row arrives, the AzureDiagnostics table may not exist at all.
    if ($resp.StatusCode -lt 400) {
        $table = @(($resp.Content | ConvertFrom-Json).tables) | Select-Object -First 1
        foreach ($row in @($table.rows)) {
            # Match on every column so a column-name difference can't hide a real entry.
            if ($injection.AzureRef -and @($row | Where-Object { [string]$_ -eq $injection.AzureRef }).Count) { $found = $row; break }
        }
    }
    if ($found -or (Get-Date) -ge $logDeadline) { break }
    Write-Host '[WAIT] The WAF log entry hasn''t reached the workspace yet. Front Door logs take a few minutes. Retrying in 60 seconds.'
    Start-Sleep -Seconds 60
} while ($true)

if ($found) {
    Write-Host "[PASS] Logged: the WAF log in $($names.Workspace) holds the injection request (x-azure-ref $($injection.AzureRef))."
    Write-Host "       Query it yourself in the workspace: AzureDiagnostics | where Category == '$wafLogCategory' | where action_s == 'Block'"
} else {
    Write-Host "[WAIT] No log entry yet. Rerun -Mode Test in a few minutes, or run the query above in $($names.Workspace)."
}
