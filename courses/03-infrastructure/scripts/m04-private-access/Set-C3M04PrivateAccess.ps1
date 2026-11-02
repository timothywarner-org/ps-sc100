<#
.SYNOPSIS
Configures, registers, reports or removes the Microsoft Entra half of the Globomantics Private
Access lab.

.DESCRIPTION
Supports the SC-100 Course 3, Module 4 demo, "Scope vendor access with Microsoft Entra Private
Access". The objects the demo inspects live in Microsoft Entra, not in Azure Resource Manager:

    Connector group    cg-glb-c3m04-plant-a
    Enterprise app     Globomantics line A maintenance (C3M04), Private Access, assignment required
    App segment        maintenance-line-a.globomantics.example, TCP 443
    Vendor identity    glb-c3m04-vendor@<your default domain>, a DISABLED lab account, assigned
    Conditional Access GLB C3M04: vendor line A maintenance requires MFA, enabled, vendor + app only

Every object carries a C3M04 marker in its name (and the app and user carry it in a tag or the
department field), so Remove deletes exactly these objects and nothing a colleague made.

WHAT IT CHANGES IN MICROSOFT ENTRA
    Configure creates or converges the objects above. Register adds one connector
    (glb-pa-conn01) to your tenant and moves it into the connector group. Remove deletes all of
    them. No mode ever changes the Private Access traffic forwarding profile; Configure only
    checks that it's on.

WHAT IT CHANGES IN AZURE
    Register only: it creates a temporary Run Command resource, glb-register-connector, on
    vm-glb-pa-conn01, uses it to register the connector, and deletes it again. Status, Configure
    and Remove leave Azure alone.

WHY THE VENDOR ACCOUNT IS DISABLED
    The demo reviews configuration; it never signs in as the vendor. An enabled account with a
    password is a live credential in your tenant. To test the behavior end to end (sign in as the
    vendor through the Global Secure Access client, reach line A, fail to reach line B), enable
    the account, license it and register it for MFA yourself, then disable it again afterward.

WHY THE CONNECTOR NEEDS YOUR SIGN-IN
    Microsoft's connector registration accepts only a user token from its own public client. No
    service principal or managed identity can register a connector. -Mode Register runs ONE
    device sign-in, then hands the token to the connector host through a Run Command protected
    parameter and deletes the Run Command resource afterward. The token is never printed, and it
    only touches disk inside an owner-only temporary folder that the script deletes.

GRAPH SESSION
    Every mode connects Microsoft Graph PowerShell to your tenant. The first run opens the normal
    Microsoft sign-in and requests consent for the scopes listed in Connect-CourseGraph; later
    runs reuse the session.

.PARAMETER Mode
Status     read-only report of every object above (default).
Configure  creates or converges the Entra objects. Idempotent.
Register   one device sign-in, then registers the connector and moves it into the group.
Remove     deletes the C3M04 Entra objects. The Azure half has its own Remove.

.PARAMETER AdminUserPrincipalName
Required with -Mode Register; ignored by the other modes. The administrator account you'll sign
in with at the device sign-in, for example admin@contoso.onmicrosoft.com. Use a member account in
your tenant's own domain, not a personal Microsoft account, with Application Administrator. If
this is the first connector your tenant has ever registered, Microsoft's connector tutorial says
that first registration needs Global Administrator. Registration stops if the token was issued to
any other account.

.PARAMETER SubscriptionId
Optional. The subscription that holds the lab's connector host (Register only). Defaults to your
current Azure CLI subscription (az account show).

.PARAMETER TenantId
Optional. The Microsoft Entra tenant to configure. Defaults to the tenant of your Azure CLI
sign-in. Pass it to run Status, Configure or Remove without the Azure CLI.

.EXAMPLE
pwsh -NoProfile -File ./Set-C3M04PrivateAccess.ps1 -Mode Configure

.EXAMPLE
pwsh -NoProfile -File ./Set-C3M04PrivateAccess.ps1 -Mode Register -AdminUserPrincipalName admin@contoso.onmicrosoft.com

Prints a Microsoft device sign-in URL and a short-lived code. Sign in as the account you named.

.EXAMPLE
pwsh -NoProfile -File ./Set-C3M04PrivateAccess.ps1 -Mode Status

.EXAMPLE
pwsh -NoProfile -File ./Set-C3M04PrivateAccess.ps1 -Mode Remove

.NOTES
PREREQUISITES
    PowerShell 7.4 or later.
    Microsoft.Graph.Authentication 2.28.0 or later:
        Install-Module Microsoft.Graph.Authentication -MinimumVersion 2.28.0 -Scope CurrentUser
    Azure CLI, signed in with az login (Register always; the other modes only to find your tenant
    when you don't pass -TenantId).
    Register only: Python 3 with MSAL for Python (python -m pip install msal), and the Azure half
    deployed with Deploy-C3M04PlantNetwork.ps1 -Mode Deploy.
    Microsoft Entra roles: Application Administrator (enterprise app, segment, connector group,
    connector registration), User Administrator (vendor account), Conditional Access
    Administrator (policy), and Global Secure Access Administrator to turn on the Private Access
    traffic forwarding profile before Configure. Global Administrator covers all of them.
    Azure role (Register only): Contributor on rg-globomantics-c3m04, for the VM read and the
    Run Command.
    Microsoft Entra Private Access needs licensing in your tenant. Check the licensing section of
    "What is Global Secure Access?" on Microsoft Learn:
    https://learn.microsoft.com/entra/global-secure-access/overview-what-is-global-secure-access
    Turn on the Private Access traffic forwarding profile first: Microsoft Entra admin center >
    Global Secure Access > Connect > Traffic forwarding.

COST
    This script adds no billable Azure resources of its own; the Register Run Command resource is
    deleted when it finishes. The lab it configures runs on billable Azure VMs created by
    Deploy-C3M04PlantNetwork.ps1, which keep billing until you delete the resource group.

CLEANUP
    Microsoft Entra:
        pwsh -NoProfile -File ./Set-C3M04PrivateAccess.ps1 -Mode Remove
    That deletes the Conditional Access policy "GLB C3M04: vendor line A maintenance requires
    MFA"; the enterprise application "Globomantics line A maintenance (C3M04)", which takes its
    service principal, segment and vendor assignment with it; the vendor account
    glb-c3m04-vendor@<your default domain>; the connector glb-pa-conn01; and the connector group
    cg-glb-c3m04-plant-a. Microsoft Entra keeps deleted apps and users in Deleted items for 30
    days. README.md lists the manual Graph command for each object.
    Azure:
        az group delete --name rg-globomantics-c3m04 --yes --no-wait
    If you turned on the Private Access traffic forwarding profile just for this lab, turn it off
    again under Global Secure Access > Connect > Traffic forwarding.
#>
#Requires -Version 7.4
[CmdletBinding()]
param(
    [ValidateSet('Status', 'Configure', 'Register', 'Remove')]
    [string]$Mode = 'Status',

    [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')]
    [string]$AdminUserPrincipalName,

    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$TenantId
)

$ErrorActionPreference = 'Stop'
# Fail before any sign-in: Register can't check who signed in without knowing who should have.
if ($Mode -eq 'Register' -and -not $AdminUserPrincipalName) {
    throw '-Mode Register needs -AdminUserPrincipalName, the administrator you will sign in as (for example admin@contoso.onmicrosoft.com).'
}

$group = 'rg-globomantics-c3m04'
$connectorVm = 'vm-glb-pa-conn01'
$connectorMachine = 'glb-pa-conn01'
$marker = 'SC100-C3M04'
$names = @{
    ConnectorGroup = 'cg-glb-c3m04-plant-a'
    App            = 'Globomantics line A maintenance (C3M04)'
    Policy         = 'GLB C3M04: vendor line A maintenance requires MFA'
    UserPrefix     = 'glb-c3m04-vendor'
}
$segment = @{ destinationHost = 'maintenance-line-a.globomantics.example'; destinationType = 'fqdn'; ports = @('443-443'); protocol = 'tcp' }
# Microsoft Entra app gallery "Custom" (non-gallery) application template, the documented starting
# point for a Private Access app in Microsoft's Graph tutorial. It's a public Microsoft ID.
$customTemplate = '8adf8e6e-67b2-4cf2-a259-e3dc5476c621'
$beta = 'https://graph.microsoft.com/beta'
$v1 = 'https://graph.microsoft.com/v1.0'
$usersUri = "$v1/users"

# Tenant and subscription come from YOUR context: the parameters if you pass them, otherwise
# az account show. Register always needs Azure; the other modes only need it to find the tenant.
$sub = $null
$tenant = $TenantId
if ($Mode -eq 'Register' -or -not $TenantId) {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'The Azure CLI (az) is not on your PATH. Install it and run az login, or pass -TenantId for a Graph-only mode.' }
    $showArgs = @('account', 'show', '--only-show-errors', '-o', 'json')
    if ($SubscriptionId) { $showArgs += @('--subscription', $SubscriptionId) }
    $accountJson = & az @showArgs
    if ($LASTEXITCODE -ne 0 -or -not $accountJson) { throw 'No usable Azure CLI sign-in. Run az login (and az account set --subscription <your subscription ID>), then rerun.' }
    $account = ($accountJson -join "`n") | ConvertFrom-Json
    $sub = $account.id
    if (-not $tenant) { $tenant = $account.tenantId }
}

function Connect-CourseGraph {
    Import-Module Microsoft.Graph.Authentication -MinimumVersion 2.28.0 -ErrorAction Stop
    $scopes = 'Application.ReadWrite.All', 'Directory.ReadWrite.All', 'NetworkAccess.ReadWrite.All',
              'Policy.Read.All', 'Policy.ReadWrite.ConditionalAccess', 'User.ReadWrite.All'
    # Reuse a session that's already on your tenant with every scope; otherwise sign in normally.
    $ctx = Get-MgContext
    $missing = if ($ctx) { @($scopes | Where-Object { $_ -notin $ctx.Scopes }) } else { $scopes }
    if (-not $ctx -or $ctx.TenantId -ne $tenant -or $missing) {
        Connect-MgGraph -TenantId $tenant -Scopes $scopes -NoWelcome -ErrorAction Stop
        $ctx = Get-MgContext
    }
    # Objects created in another directory would never meet the connector you register here.
    if (-not $ctx -or $ctx.TenantId -ne $tenant) { throw "Microsoft Graph is signed in to a different tenant than $tenant. Run Disconnect-MgGraph, then rerun and sign in with an account from that tenant." }
    Write-Host "[CONTEXT] Graph as $($ctx.Account) | $Mode"
}
function G([string]$Uri) { Invoke-MgGraphRequest -Method GET -Uri $Uri -ErrorAction Stop }
function Send([string]$Method, [string]$Uri, $Body) {
    $json = if ($null -ne $Body) { $Body | ConvertTo-Json -Depth 10 -Compress } else { $null }
    if ($json) { Invoke-MgGraphRequest -Method $Method -Uri $Uri -Body $json -ContentType 'application/json' -ErrorAction Stop }
    else { Invoke-MgGraphRequest -Method $Method -Uri $Uri -ErrorAction Stop }
}
function Find-State {
    # One read of everything this lab owns, so Status, Configure and Remove agree on identity.
    $s = [ordered]@{}
    $s.Domain = ((G "$v1/organization").value[0].verifiedDomains | Where-Object isDefault).name
    $s.Upn = "$($names.UserPrefix)@$($s.Domain)"
    $s.Group = @((G "$beta/onPremisesPublishingProfiles/applicationProxy/connectorGroups").value | Where-Object name -eq $names.ConnectorGroup) | Select-Object -First 1
    $s.App = @((G "$v1/applications?`$filter=displayName eq '$($names.App)'&`$select=id,appId,displayName,tags").value) | Select-Object -First 1
    $s.Sp = if ($s.App) { @((G "$v1/servicePrincipals?`$filter=appId eq '$($s.App.appId)'&`$select=id,appId,appRoles,appRoleAssignmentRequired").value) | Select-Object -First 1 }
    $s.User = @((G "$usersUri`?`$filter=userPrincipalName eq '$($s.Upn)'&`$select=id,displayName,accountEnabled,department").value) | Select-Object -First 1
    $s.Policy = @((G "$v1/identity/conditionalAccess/policies").value | Where-Object displayName -eq $names.Policy) | Select-Object -First 1
    $s.Connectors = @((G "$beta/onPremisesPublishingProfiles/applicationProxy/connectors").value | Where-Object { $_.machineName -like "$connectorMachine*" })
    return $s
}
function Initialize-PrivateFolder {
    # Owner-only folder for the short-lived token. On Windows, break ACL inheritance and grant only
    # you; on macOS and Linux, mode 700.
    $path = Join-Path ([IO.Path]::GetTempPath()) ('sc100-c3m04-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($path)
    if ($IsWindows) {
        $acl = Get-Acl -LiteralPath $path
        $acl.SetAccessRuleProtection($true, $false)
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.WindowsIdentity]::GetCurrent().User, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
        Set-Acl -LiteralPath $path -AclObject $acl
    } else {
        & chmod 700 $path
        if ($LASTEXITCODE -ne 0) { throw "Couldn't restrict $path to your account." }
    }
    $path
}
function Find-MsalPython {
    # The token helper needs Python 3 with MSAL. On Windows, python3 is often a Microsoft Store
    # placeholder, so python and the py launcher come first there.
    $candidates = if ($IsWindows) { 'python', 'py', 'python3' } else { 'python3', 'python' }
    foreach ($candidate in $candidates) {
        $cmd = Get-Command $candidate -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $cmd) { continue }
        & $cmd.Source -c 'import msal' 2>$null
        if ($LASTEXITCODE -eq 0) { return $cmd.Source }
    }
    throw 'Register needs Python 3 with MSAL for Python. Install Python 3, run: python -m pip install msal, then rerun. Nothing was changed.'
}

# ============================================================================== Register
if ($Mode -eq 'Register') {
    # Verify the exact host before obtaining a short-lived token. Don't queue guest work behind an
    # extension update, and don't target a similarly named VM that this lab doesn't own.
    $hostRaw = & az vm get-instance-view -g $group -n $connectorVm --subscription $sub --only-show-errors -o json
    if ($LASTEXITCODE) { throw "Connector host $connectorVm is unreadable in $group; registration stopped. Run Deploy-C3M04PlantNetwork.ps1 -Mode Deploy first." }
    $hostState = ($hostRaw -join "`n") | ConvertFrom-Json
    if ($hostState.tags.course -ne $marker -or $hostState.provisioningState -ne 'Succeeded' -or
        $hostState.instanceView.statuses.code -notcontains 'PowerState/running' -or
        $hostState.instanceView.vmAgent.statuses.code -notcontains 'ProvisioningState/succeeded') {
        throw "The lab connector host must be course-tagged, running and agent-ready before registration. If it's stopped: az vm start --resource-group $group --name $connectorVm"
    }
    foreach ($extension in $hostState.instanceView.extensions) {
        if ($extension.statuses.code -notcontains 'ProvisioningState/succeeded') { throw "Wait for connector-host extension $($extension.name) to finish before registration." }
    }
    # A separate Python process runs MSAL, so it never collides with the Graph SDK's own MSAL copy.
    $python = Find-MsalPython
    $secretDir = Initialize-PrivateFolder
    $tokenFile = Join-Path $secretDir 'token.txt'
    $bodyFile = Join-Path $secretDir 'registration.json'
    $runUri = "https://management.azure.com/subscriptions/$sub/resourceGroups/$group/providers/Microsoft.Compute/virtualMachines/$connectorVm/runCommands/glb-register-connector?api-version=2024-07-01"
    $token = $null
    $submitted = $false
    $cleanupFailed = $false
    try {
        & $python (Join-Path $PSScriptRoot 'Get-C3M04RegistrationToken.py') --tenant $tenant --expected-upn $AdminUserPrincipalName --output $tokenFile
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tokenFile) -or (Get-Item -LiteralPath $tokenFile).Length -lt 100) {
            throw 'No registration token was issued; nothing was changed.'
        }
        $token = Get-Content -LiteralPath $tokenFile -Raw
        # This script runs ON the connector host. RegisterConnector.ps1 and its arguments are the
        # ones in Microsoft Learn's unattended connector installation article.
        $register = @'
param([string]$Token, [string]$TenantId)
$ErrorActionPreference = 'Stop'
$base = 'C:\Program Files\Microsoft Entra private network connector'
# Some connector builds declare -Token as String, while the Learn example passes SecureString.
# Binding a SecureString to a String sends the type name, not the token, so inspect the installed
# script instead of guessing its signature.
$registrationScript = Join-Path $base 'RegisterConnector.ps1'
$tokenType = (Get-Command $registrationScript -ErrorAction Stop).Parameters['Token'].ParameterType
if ([string]::IsNullOrWhiteSpace($Token) -or $Token.Length -lt 100) { throw 'Protected registration token is missing.' }
if ($tokenType -eq [string]) { $tokenArgument = $Token.Trim() }
elseif ($tokenType -eq [securestring]) { $tokenArgument = ConvertTo-SecureString -String $Token.Trim() -AsPlainText -Force }
else { throw 'Unsupported connector Token parameter type; inspect the installed script.' }
& $registrationScript -modulePath "$base\Modules\" -moduleName 'MicrosoftEntraPrivateNetworkConnectorPSModule' -Authenticationmode Token -Token $tokenArgument -TenantId $TenantId -Feature ApplicationProxy
Start-Sleep -Seconds 20
(Get-Service | Where-Object { $_.DisplayName -like 'Microsoft Entra private network connector*' } | ForEach-Object { "$($_.DisplayName)=$($_.Status)" }) -join '; '
'@
        # Keep the token out of process arguments as well as console output. The protected ARM
        # parameter body lives only in the owner-only folder and is deleted in finally.
        @{ location = $hostState.location
           properties = @{ source = @{ script = $register }; parameters = @(@{ name = 'TenantId'; value = $tenant })
                           protectedParameters = @(@{ name = 'Token'; value = $token }); timeoutInSeconds = 600; asyncExecution = $false } } |
            ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $bodyFile
        $submitted = $true
        & az rest --method put --url $runUri --body "@$bodyFile" --subscription $sub --only-show-errors -o none
        if ($LASTEXITCODE -ne 0) { throw 'Run Command failed to start on the connector host.' }
        $deadline = [DateTimeOffset]::UtcNow.AddMinutes(11)
        do {
            Start-Sleep -Seconds 10
            # $expand rides in --url-parameters rather than in the URL: on Windows, az is a .cmd
            # file, and cmd.exe would split the URL at the ampersand.
            $raw = & az rest --method get --url $runUri --url-parameters '$expand=instanceView' --subscription $sub --only-show-errors -o json
            if ($LASTEXITCODE) { throw 'Registration execution state is unreadable.' }
            $execution = (($raw -join "`n") | ConvertFrom-Json).properties.instanceView
        } while ($execution.executionState -notin @('Succeeded', 'Failed', 'Canceled') -and [DateTimeOffset]::UtcNow -lt $deadline)
        # Redact before showing anything: a provider error can echo parameters back.
        $safeOutput = ([string]$execution.output).Replace($token, '[REDACTED]') -replace 'eyJ[A-Za-z0-9_.-]{80,}', '[REDACTED]'
        $safeError = ([string]$execution.error).Replace($token, '[REDACTED]') -replace 'eyJ[A-Za-z0-9_.-]{80,}', '[REDACTED]'
        if ($execution.executionState -ne 'Succeeded' -or $execution.exitCode -ne 0) {
            throw "Connector registration did not succeed: $($execution.executionState), exit $($execution.exitCode). $($safeError.Trim())"
        }
        Write-Host "[PASS] Connector registration command completed: $($safeOutput.Trim())"
    } finally {
        if ($submitted) {
            & az rest --method delete --url $runUri --subscription $sub --only-show-errors -o none
            if ($LASTEXITCODE) { $cleanupFailed = $true; Write-Warning 'Removing the glb-register-connector Run Command failed.' }
        }
        $token = $null
        foreach ($f in $tokenFile, $bodyFile) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } }
        Remove-Item -LiteralPath $secretDir -Force
    }
    # The Run Command resource held the token as a protected parameter, so it must not linger.
    if ($cleanupFailed) { throw "Delete the leftover Run Command, then rerun: az vm run-command delete --resource-group $group --vm-name $connectorVm --name glb-register-connector --yes" }

    # Move the new connector out of Default and into the lab's connector group.
    Connect-CourseGraph
    $s = Find-State
    # Prefer an active record: a rerun can leave an older, inactive connector with the same name.
    $conn = $s.Connectors | Sort-Object { $_.status -ne 'active' } | Select-Object -First 1
    if (-not $conn) { throw 'The connector did not appear in Microsoft Entra. Rerun -Mode Status in a minute.' }
    if (-not $s.Group) { throw 'Run -Mode Configure first; the connector group is missing.' }
    $members = @((G "$beta/onPremisesPublishingProfiles/applicationProxy/connectorGroups/$($s.Group.id)/members").value.id)
    if ($conn.id -notin $members) {
        Send POST "$beta/onPremisesPublishingProfiles/applicationProxy/connectorGroups/$($s.Group.id)/members/`$ref" @{ '@odata.id' = "$beta/onPremisesPublishingProfiles/applicationProxy/connectors/$($conn.id)" }
    }
    # A successful membership write isn't proof of an active connection. Read back both facts.
    $deadline = [DateTimeOffset]::UtcNow.AddMinutes(3)
    do {
        $registered = @((G "$beta/onPremisesPublishingProfiles/applicationProxy/connectorGroups/$($s.Group.id)/members").value | Where-Object id -eq $conn.id)
        if ($registered.Count -eq 1 -and $registered[0].status -eq 'active') { break }
        Start-Sleep -Seconds 10
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    if ($registered.Count -ne 1 -or $registered[0].status -ne 'active') { throw 'The connector is not yet active in the lab group. Give the service a few minutes, then run -Mode Status.' }
    Write-Host "[PASS] Connector $($registered[0].machineName) is active in $($names.ConnectorGroup)"
    Write-Host '[NEXT] pwsh -NoProfile -File ./Show-C3M04PrivateAccess.ps1'
    return
}

Connect-CourseGraph
$s = Find-State

# ============================================================================== Status
if ($Mode -eq 'Status') {
    Write-Host ('Connector group     : ' + $(if ($s.Group) { $s.Group.name } else { 'ABSENT' }))
    Write-Host ('Connectors          : ' + $(if ($s.Connectors) { ($s.Connectors | ForEach-Object { "$($_.machineName) $($_.status)" }) -join ', ' } else { 'none registered from ' + $connectorMachine }))
    Write-Host ('Enterprise app      : ' + $(if ($s.App) { $s.App.displayName } else { 'ABSENT' }))
    Write-Host ('Vendor account      : ' + $(if ($s.User) { "$($s.Upn), enabled=$($s.User.accountEnabled)" } else { 'ABSENT' }))
    Write-Host ('Conditional Access  : ' + $(if ($s.Policy) { "$($s.Policy.displayName), state=$($s.Policy.state)" } else { 'ABSENT' }))
    return
}

# ============================================================================== Remove
if ($Mode -eq 'Remove') {
    # Order matters: a connector group can't be deleted while an app or a connector still uses it.
    if ($s.Policy) { Send DELETE "$v1/identity/conditionalAccess/policies/$($s.Policy.id)" $null; Write-Host '[PASS] Conditional Access policy removed' }
    if ($s.App -and $s.App.tags -contains $marker) { Send DELETE "$v1/applications/$($s.App.id)" $null; Write-Host '[PASS] Enterprise app removed, with its segment and vendor assignment' }
    if ($s.User -and $s.User.department -eq $marker) { Send DELETE "$usersUri/$($s.User.id)" $null; Write-Host '[PASS] Vendor account removed' }
    if ($s.Group) {
        foreach ($c in $s.Connectors) { Send DELETE "$beta/onPremisesPublishingProfiles/applicationProxy/connectors/$($c.id)" $null }
        Send DELETE "$beta/onPremisesPublishingProfiles/applicationProxy/connectorGroups/$($s.Group.id)" $null
        Write-Host '[PASS] Connector and connector group removed'
    }
    Write-Host '[NOTE] Microsoft Entra keeps deleted apps and users in Deleted items for 30 days. For the Azure half: az group delete --name rg-globomantics-c3m04 --yes --no-wait'
    return
}

# ============================================================================== Configure
# Private Access must be the enabled profile for the app to carry traffic. Read it; never flip a
# tenant-wide forwarding profile on someone's behalf.
$privateProfile = @((G "$beta/networkAccess/forwardingProfiles?`$select=id,name,state,trafficForwardingType").value | Where-Object trafficForwardingType -eq 'private')
if (-not $privateProfile -or $privateProfile[0].state -ne 'enabled') {
    throw 'The Private Access traffic forwarding profile is not enabled in this tenant. Turn it on in the Microsoft Entra admin center under Global Secure Access > Connect > Traffic forwarding (Global Secure Access Administrator), then rerun. This script will not change it for you.'
}
Write-Host '[PASS] Private Access traffic forwarding profile is enabled'

if (-not $s.Group) {
    $s.Group = Send POST "$beta/onPremisesPublishingProfiles/applicationProxy/connectorGroups" @{ name = $names.ConnectorGroup }
    Write-Host "[PASS] Created connector group $($names.ConnectorGroup)"
} else { Write-Host "[PASS] Connector group $($names.ConnectorGroup) exists" }

if (-not $s.App) {
    $created = Send POST "$v1/applicationTemplates/$customTemplate/instantiate" @{ displayName = $names.App }
    $s.App = $created.application; $s.Sp = $created.servicePrincipal
    # A new app and its principal take a few seconds to replicate before PATCH succeeds.
    Start-Sleep -Seconds 20
    Write-Host "[PASS] Created enterprise app $($names.App)"
}
Send PATCH "$v1/applications/$($s.App.id)" @{ tags = @($marker, 'PrivateAccessNonWebApplication') } | Out-Null
Send PATCH "$beta/applications/$($s.App.id)" @{ onPremisesPublishing = @{ applicationType = 'nonwebapp'; isAccessibleViaZTNAClient = $true } } | Out-Null
Send PUT "$beta/applications/$($s.App.id)/connectorGroup/`$ref" @{ '@odata.id' = "$beta/onPremisesPublishingProfiles/applicationproxy/connectorGroups/$($s.Group.id)" } | Out-Null
Send PATCH "$v1/servicePrincipals/$($s.Sp.id)" @{ appRoleAssignmentRequired = $true } | Out-Null
Write-Host '[PASS] App is a Private Access enterprise app on the lab connector group; assignment required'

$segUri = "$beta/applications/$($s.App.id)/onPremisesPublishing/segmentsConfiguration/microsoft.graph.ipSegmentConfiguration/applicationSegments"
$segments = @((G $segUri).value)
if (-not ($segments | Where-Object { $_.destinationHost -eq $segment.destinationHost })) {
    Send POST $segUri $segment | Out-Null
    Write-Host "[PASS] Added segment $($segment.destinationHost) TCP 443"
}
foreach ($extra in $segments | Where-Object { $_.destinationHost -ne $segment.destinationHost }) {
    # The demo's claim is ONE host and ONE port; anything else is drift from an earlier edit.
    Send DELETE "$segUri/$($extra.id)" $null
    Write-Host "[PASS] Removed stray segment $($extra.destinationHost)"
}

if (-not $s.User) {
    # Random, never shown, never stored: the account is created disabled and nobody signs in as it.
    $pw = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(24)) + 'aA1.'
    $s.User = Send POST $usersUri @{
        accountEnabled = $false; displayName = 'Line A maintenance vendor (demo)'; mailNickname = $names.UserPrefix
        userPrincipalName = $s.Upn; department = $marker; companyName = 'Globomantics maintenance vendor'; usageLocation = 'US'
        passwordProfile = @{ forceChangePasswordNextSignIn = $true; password = $pw }
    }
    Remove-Variable pw
    Write-Host "[PASS] Created disabled vendor account $($s.Upn)"
}

# Assign the vendor. A custom app exposes a "User" role; fall back to default access if it doesn't.
$sp = G "$v1/servicePrincipals/$($s.Sp.id)?`$select=id,appRoles"
$role = @($sp.appRoles | Where-Object { $_.value -eq 'User' -or $_.displayName -eq 'User' }) | Select-Object -First 1
$roleId = if ($role) { $role.id } else { '00000000-0000-0000-0000-000000000000' }
$assigned = @((G "$v1/servicePrincipals/$($s.Sp.id)/appRoleAssignedTo").value)
if (-not ($assigned | Where-Object principalId -eq $s.User.id)) {
    Send POST "$v1/servicePrincipals/$($s.Sp.id)/appRoleAssignedTo" @{ principalId = $s.User.id; resourceId = $s.Sp.id; appRoleId = $roleId } | Out-Null
    Write-Host '[PASS] Vendor assigned to the app'
}

# Scoped to one disabled lab account and one lab app, so enabling it can't affect anyone else.
$policyBody = @{
    displayName = $names.Policy; state = 'enabled'
    conditions = @{
        clientAppTypes = @('all')
        users = @{ includeUsers = @($s.User.id) }
        applications = @{ includeApplications = @($s.App.appId) }
    }
    grantControls = @{ operator = 'OR'; builtInControls = @('mfa') }
}
if (-not $s.Policy) { Send POST "$v1/identity/conditionalAccess/policies" $policyBody | Out-Null; Write-Host '[PASS] Conditional Access policy created, enabled, vendor and app only' }
else { Send PATCH "$v1/identity/conditionalAccess/policies/$($s.Policy.id)" $policyBody | Out-Null; Write-Host '[PASS] Conditional Access policy converged' }

Write-Host '[NEXT] -Mode Register -AdminUserPrincipalName <your admin account> once (one device sign-in) to bring the connector online, then Show-C3M04PrivateAccess.ps1.'
