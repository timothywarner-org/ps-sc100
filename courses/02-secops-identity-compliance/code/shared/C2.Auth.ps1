#Requires -Version 7.2
<#
.SYNOPSIS
Shared Azure helpers for the SC-100 Course 2 labs. Dot-source it; don't run it.

.DESCRIPTION
Every Course 2 script that touches Azure dot-sources this file, so the same three rules hold in
all five labs.

1. YOUR SIGN-IN DECIDES WHERE THE LAB LANDS. Resolve-C2AzureContext takes the subscription and
   tenant from, in order: the -SubscriptionId and -TenantId parameters you pass, then the
   AZURE_SUBSCRIPTION_ID and AZURE_TENANT_ID environment variables, then your current Azure CLI
   context (az account show). Nothing in this course names a subscription or tenant of its own.

2. A WORKING READ PROVES NOTHING ABOUT A WRITE. Azure enforces mandatory multifactor
   authentication (MFA) at the Azure Resource Manager (ARM) layer for create, update and delete
   calls. A session that signed in without completing MFA can list everything you own and still
   have its first write refused with AADSTS50076. az account show reads a cached local profile, so
   it can't tell you which kind of session you hold. The honest check is to decode the ARM access
   token and look for mfa in its amr (authentication methods) claim. Assert-C2ArmWriteReady does
   exactly that, before any script writes.

3. A FAILED CALL MUST NEVER LOOK LIKE AN EMPTY RESULT. Invoke-C2Az and Invoke-C2Arm throw on any
   failure, so "the call failed" can't masquerade as "nothing exists".

.EXAMPLE
. (Join-Path $PSScriptRoot '..' 'shared' 'C2.Auth.ps1')
$ctx = Resolve-C2AzureContext -SubscriptionId $SubscriptionId -TenantId $TenantId
Assert-C2ArmWriteReady -Context $ctx

.NOTES
Mandatory MFA for Azure:
  https://learn.microsoft.com/entra/identity/authentication/concept-mandatory-multifactor-authentication
Claims-challenge recovery for the Azure CLI:
  https://learn.microsoft.com/cli/azure/use-azure-cli-successfully-troubleshooting#troubleshooting-multifactor-authentication-mfa
#>

# Version 1.0 catches a misspelled variable. Later versions also throw on a missing property, and
# Azure and Graph responses legitimately omit empty properties, so a stricter mode turns an absent
# optional field into a crash.
Set-StrictMode -Version 1.0

$script:C2GuidPattern = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
$script:C2TokenCache = @{}

function Assert-C2AzureCli {
    <#
    .SYNOPSIS
    Stops early, with the install pointer, when the Azure CLI or Bicep is missing.
    .PARAMETER Bicep
    Also require the Bicep CLI that the Azure CLI manages.
    #>
    [CmdletBinding()]
    param([switch]$Bicep)

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'The Azure CLI (az) isn''t on your PATH. Install it from https://learn.microsoft.com/cli/azure/install-azure-cli, run az login, then rerun this script.'
    }
    if ($Bicep) {
        # A native command's stderr mustn't become a terminating error here; the exit code decides.
        $ErrorActionPreference = 'Continue'
        $null = & az bicep version --only-show-errors 2>&1
        if ($LASTEXITCODE -ne 0) { throw 'Bicep isn''t installed for the Azure CLI. Run az bicep install, then rerun this script.' }
    }
}

function Write-C2MfaRemedy {
    <#
    .SYNOPSIS
    Explains why Azure refuses writes from a token without the mfa claim, and the two fixes that work.
    .PARAMETER TenantId
    Your tenant, so the printed commands are ready to paste.
    .PARAMETER Amr
    The amr values the current token carries, if known.
    #>
    [CmdletBinding()]
    param([string]$TenantId = '<your-tenant-id>', [string[]]$Amr = @())

    $amrText = if ($Amr.Count) { $Amr -join ',' } else { 'unknown' }
    Write-Host ''
    Write-Host "[WARN] Your Azure session can read but can't write (token amr: $amrText, no mfa)."
    Write-Host '       Azure enforces mandatory MFA on create, update and delete calls at the Azure Resource'
    Write-Host '       Manager layer. Reads succeed without it, so the first write is where you find out.'
    Write-Host ''
    Write-Host '       Fix it one of two ways:'
    Write-Host ''
    Write-Host '       1. Sign in again from this shell and complete MFA when you are prompted:'
    Write-Host '              az logout'
    Write-Host "              az login --tenant $TenantId"
    Write-Host '          If that sign-in never asks for MFA, Azure answers the refused write with a claims'
    Write-Host '          challenge. Pass that challenge back exactly as Microsoft documents:'
    Write-Host "              az login --tenant $TenantId --scope https://management.core.windows.net//.default --claims-challenge `"<challenge>`""
    Write-Host ''
    Write-Host '       2. Use Azure Cloud Shell. Sign in at https://portal.azure.com and complete MFA there. If'
    Write-Host '          the portal sign-in didn''t prompt for MFA, make one small change in the portal, such as'
    Write-Host '          adding a tag to a resource group you own, and complete the prompt that follows. Then'
    Write-Host '          open Cloud Shell, choose PowerShell, bring this folder over and run the same command.'
    Write-Host '          Cloud Shell inherits your portal session.'
    Write-Host ''
    Write-Host "       Don't turn MFA off to get past this. The requirement is the lesson."
    Write-Host ''
}

function Invoke-C2Az {
    <#
    .SYNOPSIS
    Runs one Azure CLI command, returns parsed JSON, and throws on any failure.
    .PARAMETER Arguments
    The az arguments, without the leading az.
    .PARAMETER SubscriptionId
    Pins the call to this subscription, so a change to your CLI default mid-run can't redirect it.
    .PARAMETER Text
    Return raw text instead of parsed JSON, for commands such as az bicep build.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$SubscriptionId,
        [switch]$Text
    )

    # The exit code decides success, so native stderr mustn't throw before we read it.
    $ErrorActionPreference = 'Continue'
    $all = [System.Collections.Generic.List[string]]::new()
    $all.AddRange([string[]]$Arguments)
    if ($SubscriptionId) { $all.Add('--subscription'); $all.Add($SubscriptionId) }
    # Explicit JSON on purpose: a CLI configured for table output would hand ConvertFrom-Json an
    # ASCII table, and that failure reads like "not signed in" when you are.
    if (-not $Text) { $all.Add('--output'); $all.Add('json') }
    $all.Add('--only-show-errors')

    $result = & az @all 2>&1
    $exit = $LASTEXITCODE
    $stdout = @($result | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
    $stderr = (@($result | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) | ForEach-Object { $_.ToString() }) -join ' '

    if ($exit -ne 0) {
        if ($stderr -match 'AADSTS50076|AADSTS50079|claims.challenge|RequestDisallowedBy|multi-?factor|MFA') {
            Write-C2MfaRemedy
        }
        $verb = ($Arguments | Select-Object -First 3) -join ' '
        throw "Azure CLI call failed (exit $exit): az $verb. $stderr"
    }
    if ($Text) { return ($stdout -join "`n") }
    $json = ($stdout -join "`n").Trim()
    if ($json) { return ($json | ConvertFrom-Json) }
}

function Resolve-C2AzureContext {
    <#
    .SYNOPSIS
    Works out which subscription and tenant this run targets, from your own sign-in.
    .DESCRIPTION
    Resolution order: the parameter you pass, then AZURE_SUBSCRIPTION_ID and AZURE_TENANT_ID, then
    your current Azure CLI context. TenantId is a guard rather than a target: when you supply it, the
    run stops if the subscription belongs to any other tenant.
    .PARAMETER SubscriptionId
    Optional. The subscription to work in.
    .PARAMETER TenantId
    Optional. The tenant you expect that subscription to belong to.
    .OUTPUTS
    An object with SubscriptionId, SubscriptionName, TenantId, Account and AccountType.
    #>
    [CmdletBinding()]
    param([string]$SubscriptionId, [string]$TenantId)

    Assert-C2AzureCli
    $subSource = 'parameter'
    if (-not $SubscriptionId -and $env:AZURE_SUBSCRIPTION_ID) { $SubscriptionId = $env:AZURE_SUBSCRIPTION_ID; $subSource = 'AZURE_SUBSCRIPTION_ID' }
    elseif (-not $SubscriptionId) { $subSource = 'your current Azure CLI context' }
    if (-not $TenantId -and $env:AZURE_TENANT_ID) { $TenantId = $env:AZURE_TENANT_ID }

    foreach ($pair in @(@('SubscriptionId', $SubscriptionId), @('TenantId', $TenantId))) {
        if ($pair[1] -and $pair[1] -notmatch $script:C2GuidPattern) { throw "$($pair[0]) '$($pair[1])' isn't a GUID." }
    }

    try { $account = Invoke-C2Az -Arguments @('account', 'show') -SubscriptionId $SubscriptionId }
    catch {
        throw "Can't read the subscription from $subSource. Run az login (and az account set --subscription <your-subscription-id> if you have more than one), then rerun. Detail: $($_.Exception.Message)"
    }
    if (-not $account) { throw 'The Azure CLI returned no account. Run az login, then rerun.' }
    if ($TenantId -and $account.tenantId -ne $TenantId) {
        throw "Subscription '$($account.name)' belongs to tenant $($account.tenantId), not $TenantId. Refusing to continue."
    }
    if ($account.state -ne 'Enabled') { throw "Subscription '$($account.name)' is $($account.state). Use an enabled subscription." }

    [pscustomobject]@{
        SubscriptionId   = [string]$account.id
        SubscriptionName = [string]$account.name
        TenantId         = [string]$account.tenantId
        Account          = [string]$account.user.name
        AccountType      = [string]$account.user.type
        Source           = $subSource
    }
}

function Write-C2AzureContext {
    <#
    .SYNOPSIS
    Prints the context a run will use, so you can stop before anything lands in the wrong place.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Context, [string]$Mode)
    Write-Host "[CONTEXT] $($Context.Account) | $($Context.SubscriptionName) ($($Context.SubscriptionId)) | tenant $($Context.TenantId) | from $($Context.Source)$(if ($Mode) { " | $Mode" })"
}

function ConvertFrom-C2Base64Url {
    <#
    .SYNOPSIS
    Base64url (RFC 4648 section 5) to text.
    .DESCRIPTION
    JWT segments use - and _ in place of + and / and drop the = padding, so
    [Convert]::FromBase64String rejects them as they are. Restoring both is the whole job.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Text)

    $s = $Text.Replace('-', '+').Replace('_', '/')
    switch ($s.Length % 4) {
        2 { $s += '==' }
        3 { $s += '=' }
        1 { throw 'Malformed base64url segment: its length leaves one character over.' }
    }
    [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($s))
}

function ConvertFrom-C2JwtPayload {
    <#
    .SYNOPSIS
    Decodes a JWT's payload, the second of its three segments.
    .DESCRIPTION
    This INSPECTS the token; it doesn't validate it. Validation is the resource's job, and ARM does
    it. All a script needs is to read the claims the issuer already put there.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Token)

    $parts = $Token.Split('.')
    if ($parts.Count -lt 2) { throw 'The access token isn''t a JWT.' }
    ConvertFrom-C2Base64Url -Text $parts[1] | ConvertFrom-Json
}

function Get-C2AccessToken {
    <#
    .SYNOPSIS
    Gets an access token for one resource from your Azure CLI sign-in and keeps it in memory only.
    .PARAMETER Resource
    The resource the token is for. Defaults to Azure Resource Manager.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Context, [string]$Resource = 'https://management.azure.com/')

    $cached = $script:C2TokenCache[$Resource]
    # Thirty minutes keeps well inside a token's lifetime without asking the CLI on every call.
    if (-not $cached -or ((Get-Date) - $cached.At).TotalMinutes -gt 30) {
        $t = Invoke-C2Az -Arguments @('account', 'get-access-token', '--resource', $Resource) -SubscriptionId $Context.SubscriptionId
        $cached = @{ Token = [string]$t.accessToken; At = Get-Date }
        $script:C2TokenCache[$Resource] = $cached
    }
    $cached.Token
}

function Assert-C2ArmWriteReady {
    <#
    .SYNOPSIS
    Stops before the first write when your Azure token lacks the mfa claim that ARM writes need.
    .PARAMETER Context
    The object Resolve-C2AzureContext returned.
    .PARAMETER Skip
    Skip the check. Use it only if your organization satisfies MFA in a way that doesn't appear in
    the token's amr claim. A refused write then fails with AADSTS50076 instead of stopping here.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Context, [switch]$Skip)

    if ($Skip) { Write-Host '[WARN] Skipping the mfa claim check because you asked to.'; return }
    if ($Context.AccountType -ne 'user') {
        # Mandatory MFA covers user sign-ins. Workload identities such as service principals are out of scope.
        Write-Host "[OK] Signed in as a $($Context.AccountType). Mandatory MFA applies to user sign-ins, so there's no mfa claim to check."
        return
    }
    $claims = ConvertFrom-C2JwtPayload -Token (Get-C2AccessToken -Context $Context)
    $amr = @()
    if ($claims.PSObject.Properties.Name -contains 'amr') { $amr = @($claims.amr) }
    $aud = if ($claims.PSObject.Properties.Name -contains 'aud') { [string]$claims.aud } else { '' }
    # Both spellings are valid ARM audiences, depending on how the token was requested. A token for
    # some other audience could carry mfa and still be the wrong token, so check both claims.
    if ($aud -notmatch 'management\.azure\.com|management\.core\.windows\.net') {
        throw "The token the Azure CLI returned is for '$aud', not Azure Resource Manager. Run az login again."
    }
    if ($amr -contains 'mfa') {
        Write-Host "[OK] Your Azure token carries the mfa claim (amr: $($amr -join ',')), so Azure will accept writes."
        return
    }
    Write-C2MfaRemedy -TenantId $Context.TenantId -Amr $amr
    throw 'Stopped before any write: your Azure token has no mfa claim, so Azure would refuse the first create with AADSTS50076.'
}

function Invoke-C2Arm {
    <#
    .SYNOPSIS
    Sends one Azure Resource Manager REST call and returns the parsed response.
    .DESCRIPTION
    REST calls go through Invoke-WebRequest rather than az rest. On Windows, az is a .cmd file, so
    cmd.exe re-parses its arguments and an & or a $filter inside a URL breaks the call. Invoke-WebRequest
    takes the URL as one string and never reaches cmd.exe.
    .PARAMETER Path
    The ARM path, starting with /subscriptions or /providers.
    .PARAMETER ApiVersion
    The api-version for that resource type.
    .PARAMETER Method
    GET (the default) or POST. Some read operations, such as listing a Sentinel incident's alerts, are POSTs.
    .PARAMETER Body
    An object to send as JSON with a POST.
    .PARAMETER AllowNotFound
    Return $null on 404 instead of throwing.
    .PARAMETER All
    Follow nextLink and return every item from a collection.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Context,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ApiVersion,
        [ValidateSet('GET', 'POST')][string]$Method = 'GET',
        [object]$Body,
        [switch]$AllowNotFound,
        [switch]$All
    )

    # ${Path} needs braces: PowerShell allows ? inside a variable name, so "$Path?api" reads 'Path?'.
    $uri = "https://management.azure.com${Path}$(if ($Path.Contains('?')) { '&' } else { '?' })api-version=$ApiVersion"
    $seen = @{}
    $items = [System.Collections.Generic.List[object]]::new()
    do {
        $parsed = [uri]$uri
        # A continuation link is followed with your token attached, so it must stay on ARM.
        if ($parsed.Scheme -ne 'https' -or $parsed.Host -ne 'management.azure.com') { throw "Refusing to send a token to $($parsed.Host)." }
        if ($seen.ContainsKey($uri)) { throw 'ARM repeated a continuation link.' }
        $seen[$uri] = $true
        $request = @{
            Uri                = $uri
            Method             = $Method
            Headers            = @{ Authorization = "Bearer $(Get-C2AccessToken -Context $Context)" }
            SkipHttpErrorCheck = $true
            TimeoutSec         = 60
        }
        if ($null -ne $Body) { $request.Body = ($Body | ConvertTo-Json -Depth 20 -Compress); $request.ContentType = 'application/json' }
        $resp = Invoke-WebRequest @request
        if ($resp.StatusCode -eq 404 -and $AllowNotFound) { return $null }
        if ($resp.StatusCode -ge 400) { throw "ARM $Method $Path returned $($resp.StatusCode): $($resp.Content)" }
        $data = if ($resp.Content) { $resp.Content | ConvertFrom-Json } else { $null }
        if (-not $All) { return $data }
        if ($data -and $data.PSObject.Properties.Name -contains 'value') { foreach ($v in @($data.value)) { $items.Add($v) } }
        $uri = if ($data -and $data.PSObject.Properties.Name -contains 'nextLink') { [string]$data.nextLink } else { $null }
    } while ($uri)
    # Emit the items one by one; callers wrap the call in @() so an empty collection stays an array.
    $items.ToArray()
}

function Get-C2DeterministicSuffix {
    <#
    .SYNOPSIS
    Returns a short, repeatable suffix for a globally unique resource name.
    .DESCRIPTION
    The same subscription and seed always produce the same suffix, so a rerun converges on the same
    resource instead of creating a second one, and two learners never collide on one global name.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SubscriptionId, [Parameter(Mandatory)][string]$Seed, [ValidateRange(4, 16)][int]$Length = 8)

    $bytes = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes("$SubscriptionId/$Seed".ToLowerInvariant()))
    ([System.Convert]::ToHexString($bytes)).Substring(0, $Length).ToLowerInvariant()
}
