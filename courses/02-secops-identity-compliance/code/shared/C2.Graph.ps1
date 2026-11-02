#Requires -Version 7.2
<#
.SYNOPSIS
Shared Microsoft Graph helpers and the Globomantics Conditional Access definitions for the SC-100
Course 2 labs. Dot-source it; don't run it.

.DESCRIPTION
The Module 2, 3 and 4 labs change a Microsoft Entra tenant. Run them only in a test tenant you
control, never in production.

Every object these labs create has a display name that starts with GLB-SC100-, and the ones that
carry a description or notes field are also stamped with the ownership marker below. Each lab's
Remove mode deletes only objects that match both its exact names and that marker, so a teardown
can't take out an object somebody else created with a similar name.

Every Conditional Access policy here is report-only. Report-only policies are evaluated and logged
but never enforced, so none of them can lock anyone out. The labs never switch a policy on.

.EXAMPLE
. (Join-Path $PSScriptRoot '..' 'shared' 'C2.Graph.ps1')
$tenant = Connect-C2Graph -Scopes 'User.Read', 'Policy.Read.All'

.NOTES
Requires the Microsoft Graph PowerShell authentication module:
  Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
Conditional Access policy API:
  https://learn.microsoft.com/graph/api/resources/conditionalaccesspolicy
Report-only mode:
  https://learn.microsoft.com/entra/identity/conditional-access/concept-conditional-access-report-only
#>

# Version 1.0 catches a misspelled variable. Later versions also throw on a missing property, and
# Graph omits empty properties from its responses, so a stricter mode turns an absent optional
# field into a crash.
Set-StrictMode -Version 1.0

$script:C2Prefix = 'GLB-SC100-'
$script:C2Marker = 'GLB-SC100 course lab object.'
# The Graph users collection, relative to graph.microsoft.com. Scripts append /<object-id> to it.
$script:C2UsersPath = 'v1.0/users'

$script:C2PolicyNames = [ordered]@{
    CA01    = 'GLB-SC100-CA-01 Require MFA for all users'
    CA02    = 'GLB-SC100-CA-02 Block legacy authentication'
    CA03    = 'GLB-SC100-CA-03 Require compliant device for admins'
    CA04    = 'GLB-SC100-CA-04 Require MFA for all users - strict'
    AGENT01 = 'GLB-SC100-AGENT-01 Block high-risk supply-chain agents'
}

function Connect-C2Graph {
    <#
    .SYNOPSIS
    Signs in to Microsoft Graph with exactly the delegated scopes a lab needs, and shows you which
    tenant you landed in before anything changes.
    .DESCRIPTION
    Tenant resolution: the -TenantId you pass, then AZURE_TENANT_ID, then your home tenant. The token
    lives in this PowerShell process only (ContextScope Process), so nothing is cached on disk.
    .PARAMETER Scopes
    The delegated permissions to request. User.Read is always added so the tenant name can be shown.
    .PARAMETER TenantId
    Optional. The tenant to sign in to.
    .OUTPUTS
    An object with TenantId, TenantName, DefaultDomain and Account.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Scopes, [string]$TenantId)

    if (-not $TenantId -and $env:AZURE_TENANT_ID) { $TenantId = $env:AZURE_TENANT_ID }
    if ($TenantId -and $TenantId -notmatch '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') { throw "TenantId '$TenantId' isn't a GUID." }
    if (-not (Get-Module -ListAvailable Microsoft.Graph.Authentication)) {
        throw 'The Microsoft Graph PowerShell module is missing. Run: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
    }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

    $wanted = @(@('User.Read') + $Scopes | Select-Object -Unique)
    $connect = @{ Scopes = $wanted; ContextScope = 'Process'; NoWelcome = $true; ErrorAction = 'Stop' }
    if ($TenantId) { $connect.TenantId = $TenantId }
    # Discard anything the sign-in writes to the pipeline, so callers get exactly one tenant object back.
    $null = Connect-MgGraph @connect
    $context = Get-MgContext
    if (-not $context) { throw 'Microsoft Graph sign-in didn''t complete.' }
    if ($context.AuthType -ne 'Delegated') { throw 'These labs use delegated sign-in as you, not an app-only session.' }
    if ($TenantId -and $context.TenantId -ne $TenantId) { throw "Signed in to tenant $($context.TenantId), not $TenantId. Refusing to continue." }

    # Consent decides which scopes a token carries, not the request. Fail on anything missing, and
    # mention extra breadth that an earlier admin consent granted, because you should know you have it.
    $missing = @($wanted | Where-Object { $_ -notin $context.Scopes })
    if ($missing.Count) { throw "The session is missing required scope(s): $($missing -join ', '). Consent to them, then rerun." }
    $broad = @($context.Scopes | Where-Object { $_ -in @('Directory.ReadWrite.All', 'Directory.AccessAsUser.All') })
    if ($broad.Count) { Write-Host "[INFO] Your session also carries broader consented scope(s) this lab doesn't need: $($broad -join ', ')." }

    $org = @((Invoke-C2Graph -Uri 'v1.0/organization?$select=id,displayName,verifiedDomains').value)[0]
    $domain = @($org.verifiedDomains | Where-Object { $_.isDefault })[0].name
    Write-Host "[CONTEXT] $($context.Account) | tenant '$($org.displayName)' ($($context.TenantId)) | default domain $domain"
    Write-Host '          Confirm this is a test tenant you control before you continue.'
    [pscustomobject]@{ TenantId = $context.TenantId; TenantName = $org.displayName; DefaultDomain = $domain; Account = $context.Account }
}

function Invoke-C2Graph {
    <#
    .SYNOPSIS
    Sends one Microsoft Graph request and returns the response as a hashtable.
    .DESCRIPTION
    POSTs are never retried: an uncertain response may already have created the object, and a retry
    would create a second one.
    #>
    [CmdletBinding()]
    param([ValidateSet('GET', 'POST', 'PATCH', 'DELETE')][string]$Method = 'GET', [Parameter(Mandatory)][string]$Uri, [object]$Body)

    if ($Uri -notmatch '^https://') { $Uri = "https://graph.microsoft.com/$Uri" }
    $parsed = [uri]$Uri
    # Continuation links carry your token, so refuse anything that isn't Microsoft Graph.
    if ($parsed.Scheme -ne 'https' -or $parsed.Host -ne 'graph.microsoft.com' -or -not $parsed.IsDefaultPort) { throw 'Refusing a request outside graph.microsoft.com.' }
    $request = @{ Method = $Method; Uri = $Uri; OutputType = 'HashTable'; ErrorAction = 'Stop' }
    if ($null -ne $Body) { $request.Body = ($Body | ConvertTo-Json -Depth 30 -Compress); $request.ContentType = 'application/json' }
    Invoke-MgGraphRequest @request
}

function Get-C2GraphCollection {
    <#
    .SYNOPSIS
    Reads every page of a Graph collection.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Uri)

    $seen = @{}
    do {
        if ($seen.ContainsKey($Uri)) { throw 'Graph repeated a continuation link.' }
        $seen[$Uri] = $true
        $page = Invoke-C2Graph -Uri $Uri
        if (-not $page.ContainsKey('value')) { throw 'Expected a Graph collection response.' }
        foreach ($item in $page.value) { $item }
        $Uri = $page['@odata.nextLink']
    } while ($Uri)
}

function Invoke-C2GraphReadback {
    <#
    .SYNOPSIS
    Reads an object back after creating it, retrying while directory replication catches up.
    .DESCRIPTION
    Microsoft Entra can return 404 for an object it has just committed, because the read lands on a
    replica that hasn't caught up. This retries ANY failure, without matching on the error text,
    because Invoke-MgGraphRequest reports the status in different places depending on which layer
    failed. That's safe only because a GET is idempotent: a retry can't create or change anything.
    The attempt count is bounded and the last error still throws.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Uri, [int]$Attempts = 6, [int]$DelaySeconds = 5)

    for ($i = 1; $i -le $Attempts; $i++) {
        try { return Invoke-C2Graph -Uri $Uri }
        catch {
            if ($i -eq $Attempts) { throw }
            Write-Host "[WAIT] Read-back attempt $i of $Attempts didn't succeed yet; retrying in $DelaySeconds seconds."
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

function Remove-C2GraphObject {
    <#
    .SYNOPSIS
    Deletes one Graph object and treats "already gone" as success, so a rerun of Remove is safe.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Uri, [Parameter(Mandatory)][string]$Label)

    try {
        $null = Invoke-C2Graph -Method DELETE -Uri $Uri
        Write-Host "[REMOVED] $Label"
    }
    catch {
        $text = "$($_.Exception.Message) $($_.ErrorDetails.Message)"
        if ($text -match '404|NotFound|does not exist') { Write-Host "[OK] $Label is already gone"; return }
        throw
    }
}

function Find-C2NamedObject {
    <#
    .SYNOPSIS
    Returns the one object with this display name, nothing if there's none, and throws on duplicates.
    .DESCRIPTION
    A duplicate display name means a name can't safely identify the object, so the lab stops and
    asks you to resolve it by object ID rather than guessing which one is ours.
    #>
    [CmdletBinding()]
    param([object[]]$Objects, [Parameter(Mandatory)][string]$Name)

    $found = @($Objects | Where-Object { $_ -and $_.displayName -eq $Name })
    if ($found.Count -gt 1) { throw "More than one object is named '$Name'. Resolve it by object ID, then rerun." }
    if ($found.Count -eq 1) { return $found[0] }
}

function Test-C2AgentLicenseBlock {
    <#
    .SYNOPSIS
    Recognizes the Microsoft Entra error that means the tenant isn't licensed for agent policies.
    .DESCRIPTION
    Error 1267 means the tenant can't create Conditional Access policies that target agents. A script
    can't fix an entitlement, so the caller reports the portal route instead of a stack trace.
    #>
    [CmdletBinding()]
    param($ErrorRecord)

    $probe = @($ErrorRecord.Exception.Message, $ErrorRecord.ErrorDetails.Message, $ErrorRecord.Exception.InnerException.Message) -join ' '
    return ($probe -match '1267' -or $probe -match 'requires a Microsoft Agent 365')
}

function ConvertTo-C2Canonical {
    <#
    .SYNOPSIS
    Renders a policy fragment as sorted, compact text so two policies can be compared fairly.
    .DESCRIPTION
    Graph fills in null and empty defaults that a request body never sends, and appends @odata
    annotations to property names. Both are dropped so a match means the same conditions and controls.
    #>
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return 'null' }
    if ($Value -is [System.Collections.IDictionary]) {
        $pairs = foreach ($key in ($Value.Keys | Sort-Object)) {
            # Graph appends the annotation to the PROPERTY name, for example
            # 'authenticationStrength@odata.context', so an anchored match would miss it.
            if ($key -like '*@odata.*') { continue }
            $part = ConvertTo-C2Canonical $Value[$key]
            if ($part -notin @('null', '[]', '{}', '""')) { '"' + $key + '":' + $part }
        }
        return '{' + ($pairs -join ',') + '}'
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $parts = @($Value | ForEach-Object { ConvertTo-C2Canonical $_ } | Sort-Object)
        return '[' + ($parts -join ',') + ']'
    }
    ConvertTo-Json -InputObject $Value -Compress
}

function Assert-C2Policy {
    <#
    .SYNOPSIS
    Confirms an existing policy matches what the lab would create, and refuses to overwrite drift.
    .DESCRIPTION
    If you or someone else edited a lab policy, the lab stops and tells you which part differs. It
    never overwrites your change, because a silent overwrite would hide exactly the drift an
    architect needs to see.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Actual, [Parameter(Mandatory)][System.Collections.IDictionary]$Expected)

    foreach ($field in @('displayName', 'state', 'conditions', 'grantControls', 'sessionControls')) {
        $left = ConvertTo-C2Canonical $Actual[$field]
        $right = ConvertTo-C2Canonical $Expected[$field]
        if ($left -in @('{}', '[]')) { $left = 'null' }
        if ($right -in @('{}', '[]')) { $right = 'null' }
        if ($left -ne $right) { throw "Policy '$($Expected.displayName)' differs in $field. Inspect the change; the lab won't overwrite it." }
    }
    if ($Actual.state -ne 'enabledForReportingButNotEnforced') { throw "Policy '$($Expected.displayName)' must be report-only." }
}

function Get-C2CaPolicies {
    <#
    .SYNOPSIS
    Returns the Globomantics human Conditional Access estate as Graph request bodies.
    .DESCRIPTION
    CA-01 to CA-03 are the Module 2 estate: three different shapes, so the estate reads as a real
    Zero Trust posture rather than three variations on MFA.
      CA-01  all users, all resources, require MFA
      CA-02  all users, legacy authentication clients, block
      CA-03  the Global Administrator role, require a compliant device
    CA-04 is Module 3's subject. It repeats CA-01 but excludes three groups, which is the planted
    defect the What If evaluation exposes. Pass exactly three group IDs to include it.
    .PARAMETER ExcludedGroupIds
    None for the Module 2 estate, or exactly three to add CA-04.
    #>
    [CmdletBinding()]
    param([string[]]$ExcludedGroupIds = @())

    if ($ExcludedGroupIds.Count -notin @(0, 3)) { throw 'Supply no exclusion groups (Module 2 estate) or exactly three (adds CA-04 for Module 3).' }
    # The Global Administrator role TEMPLATE ID, which Microsoft publishes and which is the same in
    # every tenant. Conditional Access targets roles by template ID, not by a tenant's role object.
    # https://learn.microsoft.com/entra/identity/role-based-access-control/permissions-reference#global-administrator
    $globalAdminTemplate = '62e90394-69f5-4237-9190-012177145e10'
    $definitions = [System.Collections.Generic.List[hashtable]]::new()
    $definitions.Add(@{ displayName = $script:C2PolicyNames.CA01; conditions = @{ users = @{ includeUsers = @('All') }; applications = @{ includeApplications = @('All') } }; grantControls = @{ operator = 'OR'; builtInControls = @('mfa') } })
    $definitions.Add(@{ displayName = $script:C2PolicyNames.CA02; conditions = @{ users = @{ includeUsers = @('All') }; applications = @{ includeApplications = @('All') }; clientAppTypes = @('exchangeActiveSync', 'other') }; grantControls = @{ operator = 'OR'; builtInControls = @('block') } })
    $definitions.Add(@{ displayName = $script:C2PolicyNames.CA03; conditions = @{ users = @{ includeRoles = @($globalAdminTemplate) }; applications = @{ includeApplications = @('All') } }; grantControls = @{ operator = 'OR'; builtInControls = @('compliantDevice') } })
    if ($ExcludedGroupIds.Count -eq 3) {
        # CA-01 still covers these people. The exclusions alone don't prove an MFA bypass, and the
        # What If evaluation in Module 3 is how you prove what the estate actually decides.
        $definitions.Add(@{ displayName = $script:C2PolicyNames.CA04; conditions = @{ users = @{ includeUsers = @('All'); excludeGroups = @($ExcludedGroupIds) }; applications = @{ includeApplications = @('All') } }; grantControls = @{ operator = 'OR'; builtInControls = @('mfa') } })
    }
    foreach ($policy in $definitions) {
        $policy.state = 'enabledForReportingButNotEnforced'
        if (-not $policy.conditions.ContainsKey('clientAppTypes')) { $policy.conditions.clientAppTypes = @('all') }
        $policy.conditions.signInRiskLevels = @()
        $policy.conditions.userRiskLevels = @()
        $policy
    }
}

function Get-C2AgentPolicy {
    <#
    .SYNOPSIS
    Returns the report-only agent policy that blocks high-risk agents built from one blueprint.
    .DESCRIPTION
    It targets the blueprint PRINCIPAL, not one agent, so every agent derived from the blueprint is
    covered. agentIdRiskLevels is a flags string, not the human signInRiskLevels array. These agent
    properties exist only on the Microsoft Graph beta endpoint.
    .PARAMETER BlueprintPrincipalId
    The blueprint principal's object ID.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BlueprintPrincipalId)

    @{
        displayName   = $script:C2PolicyNames.AGENT01
        state         = 'enabledForReportingButNotEnforced'
        conditions    = @{
            clientApplications = @{ includeAgentIdServicePrincipals = @($BlueprintPrincipalId) }
            applications       = @{ includeApplications = @('All') }
            clientAppTypes     = @('all')
            signInRiskLevels   = @()
            userRiskLevels     = @()
            agentIdRiskLevels  = 'high'
        }
        grantControls = @{ operator = 'OR'; builtInControls = @('block') }
    }
}

function Assert-C2AgentPolicyShape {
    <#
    .SYNOPSIS
    Checks the agent policy for the four things that matter, without demanding a byte-exact match.
    .DESCRIPTION
    You may have created this policy by hand in the Microsoft Entra admin center, because some tenants
    refuse the Graph create. A portal-authored policy carries defaults the request body never sends,
    so a byte-exact comparison would report drift that isn't drift. This checks the claims the demo
    makes instead: it targets the blueprint principal, the condition is high agent risk, the control
    is Block, and the state is report-only.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Actual, [Parameter(Mandatory)][string]$BlueprintPrincipalId)

    $targets = @($Actual.conditions.clientApplications.includeAgentIdServicePrincipals)
    if ($targets -notcontains $BlueprintPrincipalId) { throw "The agent policy doesn't target blueprint principal $BlueprintPrincipalId. Targeting one agent doesn't cover the blueprint's family." }
    if ("$($Actual.conditions.agentIdRiskLevels)" -notmatch 'high') { throw "The agent policy's condition isn't high agent risk." }
    if (@($Actual.grantControls.builtInControls) -notcontains 'block') { throw "The agent policy's control isn't Block." }
    if ($Actual.state -ne 'enabledForReportingButNotEnforced') { throw 'The agent policy must be report-only.' }
}

function Remove-C2LabPolicy {
    <#
    .SYNOPSIS
    Deletes one lab Conditional Access policy by its exact name, but only while it's still report-only.
    .DESCRIPTION
    Conditional Access policies have no description field to carry an ownership marker, so the exact
    lab name plus the report-only state stand in for one. A policy that has been switched on is no
    longer the lab's object to delete; the script leaves it and tells you.
    #>
    [CmdletBinding()]
    param([object[]]$Policies, [Parameter(Mandatory)][string]$Name)

    $policy = Find-C2NamedObject $Policies $Name
    if (-not $policy) { Write-Host "[OK] $Name is already gone"; return }
    if ($policy.state -ne 'enabledForReportingButNotEnforced') {
        Write-Host "[WARN] $Name is $($policy.state), not report-only, so it was changed after the lab created it. Left in place; review and delete it by hand."
        return
    }
    Remove-C2GraphObject -Uri "v1.0/identity/conditionalAccess/policies/$($policy.id)" -Label "policy $Name"
}

function New-C2LabPassword {
    <#
    .SYNOPSIS
    Returns a random password for a lab account that nobody ever signs in as.
    .DESCRIPTION
    Lab accounts exist to be the object of a policy evaluation or a role assignment. Their password is
    generated here and never printed, stored or returned to you, because nothing needs it and a lab
    credential in a transcript is still a credential.
    #>
    [CmdletBinding()]
    param()

    $bytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    # Base64 alone can miss a character class, so the suffix guarantees complexity without
    # weakening the 256 random bits in front of it.
    $value = [Convert]::ToBase64String($bytes) + 'aA1!'
    [System.Array]::Clear($bytes, 0, $bytes.Length)
    $value
}
