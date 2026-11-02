#Requires -Version 7.2

<#
.SYNOPSIS
Plans, deploys, reads back, or removes the Globomantics agent identity and its Conditional Access
estate for SC-100 Course 2, Module 2.

.DESCRIPTION
Builds the Microsoft Entra objects behind the Module 2 demo, "Govern an agent identity with
Conditional Access":

    * Three report-only human policies, GLB-SC100-CA-01 to CA-03: require MFA for all users, block
      legacy authentication, and require a compliant device for Global Administrators.
    * An agent identity blueprint, its blueprint principal, and one agent identity derived from it,
      with you as sponsor and owner.
    * GLB-SC100-AGENT-01, a report-only policy that blocks high-risk agents built from that blueprint.
      It targets the blueprint PRINCIPAL, so it covers every agent the blueprint produces, not one.

THIS CHANGES A MICROSOFT ENTRA TENANT. Run it only in a test tenant you control, never in production.

It creates no credentials, grants no API permissions, and signs nobody in. Report-only policies are
evaluated and logged but never enforced, so none of them can lock anyone out, and the script never
switches a policy on. What the lab proves is inspectable configuration: who the agent is, who owns
it, and which policy governs it. It doesn't prove that the agent reached a resource or that a block
was enforced.

WHAT EACH MODE CHANGES
    Plan    Changes nothing and signs in to nothing. Prints the request bodies it would send.
    Deploy  Creates whatever is missing. An existing lab object must match what the script would
            create; if it has drifted, the script stops and tells you which part, and never
            overwrites your change. Safe to rerun.
    Show    Changes nothing. Reads the policies and the agent objects back.
    Remove  Deletes GLB-SC100-AGENT-01, then CA-01 to CA-03 while they're still report-only, then the
            agent identity and the blueprint, which removes the blueprint principal with it. It
            leaves CA-04 and the other Module 3 objects for that lab's Remove.

DELEGATED SCOPES, requested per mode and nothing more
    Deploy  User.Read, Application.Read.All, AgentIdentityBlueprint.Create,
            AgentIdentityBlueprintPrincipal.Create, AgentIdentity.Create.All, Policy.Read.All,
            Policy.ReadWrite.ConditionalAccess
    Show    User.Read, Application.Read.All, Policy.Read.All
    Remove  User.Read, Application.Read.All, Policy.Read.All, Policy.ReadWrite.ConditionalAccess,
            AgentIdentity.DeleteRestore.All, AgentIdentityBlueprint.DeleteRestore.All

.PARAMETER Mode
Plan (the default), Deploy, Show, or Remove.

.PARAMETER TenantId
Optional. The tenant to sign in to. Defaults to AZURE_TENANT_ID when that's set, then to your home
tenant. The script prints the tenant name before it changes anything.

.EXAMPLE
pwsh -NoProfile -File .\Set-C2M02AgentAccess.ps1 -Mode Plan
Prints the policy and agent request bodies. No sign-in, no changes.

.EXAMPLE
pwsh -NoProfile -File .\Set-C2M02AgentAccess.ps1 -Mode Deploy
Signs in to Microsoft Graph and creates the lab objects in your test tenant.

.EXAMPLE
pwsh -NoProfile -File .\Set-C2M02AgentAccess.ps1 -Mode Remove
Deletes only the objects this script created.

.NOTES
ROLES
    Conditional Access Administrator for the policies. Agent ID Administrator for the blueprint and
    the agent. The account that creates a blueprint becomes its owner, and an owner can manage the
    blueprint's agents without the Agent ID Administrator role.

LICENSING
    Conditional Access needs Microsoft Entra ID P1. Conditional Access for agents needs Microsoft 365
    E7, or Microsoft Agent 365 paired with at least Microsoft Entra ID P1 or Microsoft 365 E3. Without
    that entitlement the tenant refuses the agent policy with error 1267, and the script tells you so
    and keeps the identity objects it created. The agent risk condition is in preview.

API BOUNDARY
    The blueprint, its principal and the agent use Microsoft Graph v1.0. The agent policy uses the
    Graph beta endpoint, because includeAgentIdServicePrincipals and agentIdRiskLevels exist only there.

Agent identity blueprints:      https://learn.microsoft.com/entra/agent-id/create-blueprint
Target agent identities in CA:  https://learn.microsoft.com/entra/identity/conditional-access/howto-target-agent-identities
Delete an agent identity:       https://learn.microsoft.com/graph/api/agentidentity-delete
#>
[CmdletBinding()]
param(
    [ValidateSet('Plan', 'Deploy', 'Show', 'Remove')]
    [string]$Mode = 'Plan',

    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$TenantId
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' 'shared' 'C2.Graph.ps1')

$blueprintName = 'GLB-SC100-M2 Supply-chain blueprint'
$agentName = 'GLB-SC100-M2 Parts reorder agent'
$blueprintMarker = "$script:C2Marker Module 2 supply-chain agent blueprint."
$scopes = @{
    Deploy = @('Application.Read.All', 'AgentIdentityBlueprint.Create', 'AgentIdentityBlueprintPrincipal.Create', 'AgentIdentity.Create.All', 'Policy.Read.All', 'Policy.ReadWrite.ConditionalAccess')
    Show   = @('Application.Read.All', 'Policy.Read.All')
    Remove = @('Application.Read.All', 'Policy.Read.All', 'Policy.ReadWrite.ConditionalAccess', 'AgentIdentity.DeleteRestore.All', 'AgentIdentityBlueprint.DeleteRestore.All')
}

function Get-LabAgentObjects {
    <# Finds this lab's blueprint, its principal and its agent, and refuses look-alikes. #>
    $blueprint = Find-C2NamedObject @(Get-C2GraphCollection 'v1.0/applications/microsoft.graph.agentIdentityBlueprint') $blueprintName
    if ($blueprint -and "$($blueprint.description)" -notlike "$script:C2Marker*") {
        throw "A blueprint named '$blueprintName' exists but doesn't carry the lab marker. Inspect object $($blueprint.id) before rerunning."
    }
    $principal = $null
    if ($blueprint) {
        $found = @(Get-C2GraphCollection 'v1.0/servicePrincipals/microsoft.graph.agentIdentityBlueprintPrincipal' | Where-Object { $_.appId -eq $blueprint.appId })
        if ($found.Count -gt 1) { throw 'The blueprint has more than one principal. Resolve it by object ID.' }
        $principal = $found | Select-Object -First 1
    }
    $agent = Find-C2NamedObject @(Get-C2GraphCollection 'v1.0/servicePrincipals/microsoft.graph.agentIdentity') $agentName
    if ($agent -and (-not $blueprint -or $agent.agentIdentityBlueprintId -ne $blueprint.appId)) {
        throw "An agent named '$agentName' exists but belongs to a different blueprint. Inspect object $($agent.id) before rerunning."
    }
    [pscustomobject]@{ Blueprint = $blueprint; Principal = $principal; Agent = $agent }
}

function Write-AgentPolicyPortalSteps {
    <# The portal route for tenants that refuse the Graph create of an agent policy. #>
    param([string]$PrincipalId)
    Write-Host ''
    Write-Host '[BLOCKED 1267] Your tenant refused to create a Conditional Access policy that targets agents.'
    Write-Host '              The blueprint, its principal and the agent were created and are listed below.'
    Write-Host ''
    Write-Host '  Error 1267 means the tenant isn''t entitled to agent policies: that takes Microsoft 365 E7, or'
    Write-Host '  Microsoft Agent 365 with Microsoft Entra ID P1 or Microsoft 365 E3. If you are licensed, create the'
    Write-Host '  policy by hand in the Microsoft Entra admin center, under Entra ID > Conditional Access > Policies > New policy:'
    Write-Host ''
    Write-Host "    Name              $($script:C2PolicyNames.AGENT01)"
    Write-Host '    Assignments       open the section for users, agents (Preview) or workload identities, not the plain Users one'
    Write-Host '                      What does this policy apply to?  Agents'
    Write-Host '                      Include                          Select agent identities'
    Write-Host '                      In the enhanced object picker, open the Agent blueprint principals tab and select:'
    Write-Host "                          $PrincipalId"
    Write-Host '    Target resources  All resources'
    Write-Host '    Conditions        Agent risk (Preview): High'
    Write-Host '    Grant             Block access'
    Write-Host '    Enable policy     Report-only'
    Write-Host ''
    Write-Host '  Selecting from the Agent identities tab targets one agent instead of the whole blueprint family,'
    Write-Host "  which isn't the design. A blueprint principal is neither a user nor a group, so the users and groups"
    Write-Host '  picker will never find it. If the Assignments section offers no agent option at all, agent targeting'
    Write-Host "  isn't available in your tenant and the entitlement gap is real."
    Write-Host ''
    Write-Host '  Then run -Mode Show. It checks a hand-made policy for the four things that matter.'
    Write-Host ''
}

switch ($Mode) {
    'Plan' {
        Write-Host '[PLAN] No sign-in and no changes. These are the request bodies Deploy sends.'
        Write-Host '[PLAN] Human estate: three report-only policies.'
        Get-C2CaPolicies | ConvertTo-Json -Depth 20
        Write-Host "[PLAN] Blueprint '$blueprintName', its principal, and agent '$agentName', sponsored and owned by you."
        Write-Host '[PLAN] Agent policy. The placeholder ID stands in for the blueprint principal object ID Deploy resolves.'
        Get-C2AgentPolicy -BlueprintPrincipalId '00000000-0000-0000-0000-000000000001' | ConvertTo-Json -Depth 20
        return
    }

    'Deploy' {
        $null = Connect-C2Graph -Scopes $scopes.Deploy -TenantId $TenantId
        $me = Invoke-C2Graph -Uri 'v1.0/me?$select=id,displayName'

        # 1. The human estate. Read back each policy, because Entra can acknowledge a create before
        #    a read can see it, and a policy that drifted is reported rather than overwritten.
        $existing = @(Get-C2GraphCollection 'v1.0/identity/conditionalAccess/policies')
        foreach ($body in @(Get-C2CaPolicies)) {
            $policy = Find-C2NamedObject $existing $body.displayName
            if ($policy) { Assert-C2Policy $policy $body; Write-Host "[EXISTS] $($body.displayName)" }
            else {
                $policy = Invoke-C2Graph -Method POST -Uri 'v1.0/identity/conditionalAccess/policies' -Body $body
                Write-Host "[CREATED] $($body.displayName)"
            }
            if (-not $policy.id) { throw 'Graph returned no policy ID; inspect the tenant before retrying.' }
            Assert-C2Policy (Invoke-C2GraphReadback -Uri "v1.0/identity/conditionalAccess/policies/$($policy.id)") $body
            Write-Host "[OK] $($body.displayName) is report-only and matches the design"
        }

        # 2. The blueprint, its principal and the agent. Each step looks before it creates, so a run
        #    that stopped halfway recovers on the next one instead of making a duplicate.
        $objects = Get-LabAgentObjects
        $blueprint = $objects.Blueprint
        if (-not $blueprint) {
            $blueprint = Invoke-C2Graph -Method POST -Uri 'v1.0/applications/microsoft.graph.agentIdentityBlueprint' -Body @{
                displayName          = $blueprintName
                description          = $blueprintMarker
                'sponsors@odata.bind' = @("https://graph.microsoft.com/$script:C2UsersPath/$($me.id)")
                'owners@odata.bind'   = @("https://graph.microsoft.com/$script:C2UsersPath/$($me.id)")
            }
            Write-Host "[CREATED] blueprint $blueprintName"
        } else { Write-Host "[EXISTS] blueprint $blueprintName" }
        if (-not $blueprint.id -or -not $blueprint.appId) { throw 'The blueprint response is missing an ID; inspect the tenant before retrying.' }

        $principal = $objects.Principal
        if (-not $principal) {
            $principal = Invoke-C2Graph -Method POST -Uri 'v1.0/servicePrincipals/microsoft.graph.agentIdentityBlueprintPrincipal' -Body @{ appId = $blueprint.appId }
            Write-Host '[CREATED] blueprint principal'
        } else { Write-Host '[EXISTS] blueprint principal' }
        if (-not $principal.id) { throw 'The blueprint principal response is missing its object ID.' }

        $agent = $objects.Agent
        if (-not $agent) {
            $agent = Invoke-C2Graph -Method POST -Uri 'v1.0/servicePrincipals/microsoft.graph.agentIdentity' -Body @{
                displayName              = $agentName
                agentIdentityBlueprintId = $blueprint.appId
                'sponsors@odata.bind'    = @("https://graph.microsoft.com/$script:C2UsersPath/$($me.id)")
            }
            Write-Host "[CREATED] agent $agentName"
        } else { Write-Host "[EXISTS] agent $agentName" }
        if (-not $agent.id) { throw 'The agent response is missing its object ID.' }

        # 3. The agent policy, on the beta endpoint. A licensing refusal mustn't throw away the
        #    identity objects that already deployed, so it's caught and turned into the portal route.
        $body = Get-C2AgentPolicy -BlueprintPrincipalId $principal.id
        $policy = Find-C2NamedObject @(Get-C2GraphCollection 'beta/identity/conditionalAccess/policies') $body.displayName
        $blocked = $false
        if (-not $policy) {
            try {
                $policy = Invoke-C2Graph -Method POST -Uri 'beta/identity/conditionalAccess/policies' -Body $body
                Write-Host "[CREATED] $($body.displayName)"
            }
            catch {
                if (-not (Test-C2AgentLicenseBlock $_)) { throw }
                $blocked = $true
                Write-AgentPolicyPortalSteps -PrincipalId $principal.id
            }
        } else { Write-Host "[EXISTS] $($body.displayName)" }
        if (-not $blocked) {
            if (-not $policy.id) { throw 'The agent policy response is missing its ID.' }
            Assert-C2AgentPolicyShape (Invoke-C2GraphReadback -Uri "beta/identity/conditionalAccess/policies/$($policy.id)") $principal.id
            Write-Host "[OK] $($body.displayName) targets the blueprint principal, blocks high agent risk, report-only"
        }

        $agentReadback = Invoke-C2GraphReadback -Uri "v1.0/servicePrincipals/$($agent.id)/microsoft.graph.agentIdentity"
        if ($agentReadback.agentIdentityBlueprintId -ne $blueprint.appId) { throw 'The agent read back without its blueprint relationship.' }

        Write-Host ''
        Write-Host '[DONE] Keep these IDs. They are distinct objects, and the difference is the lesson:'
        Write-Host "       blueprint object ID      $($blueprint.id)"
        Write-Host "       blueprint app ID         $($blueprint.appId)   (the agent's parent points here)"
        Write-Host "       blueprint principal ID   $($principal.id)   (the agent policy targets this)"
        Write-Host "       agent object ID          $($agent.id)"
        Write-Host "       agent policy             $(if ($blocked) { 'not created; see the portal steps above' } else { $policy.id })"
        Write-Host '[NEXT] Run -Mode Show, then open the objects in the Microsoft Entra admin center.'
        return
    }

    'Show' {
        $null = Connect-C2Graph -Scopes $scopes.Show -TenantId $TenantId
        $policies = @(Get-C2GraphCollection 'beta/identity/conditionalAccess/policies' | Where-Object { $_.displayName -like "$script:C2Prefix*" })
        Write-Host ''
        Write-Host 'THE POLICIES: every lab policy, and its state'
        foreach ($name in $script:C2PolicyNames.Values) {
            $p = Find-C2NamedObject $policies $name
            if ($p) { Write-Host ("  [OK]   {0,-58} {1}" -f $name, $p.state) } else { Write-Host ("  [--]   {0,-58} not present" -f $name) }
        }
        Write-Host '  enabledForReportingButNotEnforced is report-only: evaluated and logged, never enforced.'

        $objects = Get-LabAgentObjects
        Write-Host ''
        Write-Host 'THE AGENT: three objects, three IDs'
        if (-not $objects.Blueprint) { Write-Host '  [--] No lab blueprint. Run -Mode Deploy.'; return }
        Write-Host "  [OK] blueprint            $($objects.Blueprint.displayName)  app ID $($objects.Blueprint.appId)"
        if ($objects.Principal) { Write-Host "  [OK] blueprint principal  object ID $($objects.Principal.id)" } else { Write-Host '  [WARN] blueprint principal missing. Run -Mode Deploy to recover it.' }
        if ($objects.Agent) { Write-Host "  [OK] agent                $($objects.Agent.displayName)  object ID $($objects.Agent.id)" } else { Write-Host '  [WARN] agent missing. Run -Mode Deploy to recover it.' }

        $agentPolicy = Find-C2NamedObject $policies $script:C2PolicyNames.AGENT01
        if ($agentPolicy -and $objects.Principal) {
            try {
                Assert-C2AgentPolicyShape $agentPolicy $objects.Principal.id
                Write-Host '  [OK] The agent policy targets the blueprint principal, so it covers every agent built from it.'
            }
            catch { Write-Host "  [WARN] $($_.Exception.Message)" }
        }
        Write-Host ''
        Write-Host 'Ask yourself: none of the human policies above can reach this agent. Why not, and what does'
        Write-Host 'that tell you about designing Conditional Access for an estate that now includes agents?'
        return
    }

    'Remove' {
        $null = Connect-C2Graph -Scopes $scopes.Remove -TenantId $TenantId
        $policies = @(Get-C2GraphCollection 'beta/identity/conditionalAccess/policies')
        foreach ($key in @('AGENT01', 'CA01', 'CA02', 'CA03')) { Remove-C2LabPolicy -Policies $policies -Name $script:C2PolicyNames[$key] }
        if (Find-C2NamedObject $policies $script:C2PolicyNames.CA04) {
            Write-Host "[INFO] $($script:C2PolicyNames.CA04) belongs to the Module 3 lab. Its Remove mode deletes it."
        }

        $objects = Get-LabAgentObjects
        # The agent first: it depends on the blueprint, and deleting the blueprint is what removes
        # the blueprint principal.
        if ($objects.Agent) { Remove-C2GraphObject -Uri "v1.0/servicePrincipals/$($objects.Agent.id)/microsoft.graph.agentIdentity" -Label "agent $agentName" }
        else { Write-Host "[OK] agent $agentName is already gone" }
        if ($objects.Blueprint) {
            Remove-C2GraphObject -Uri "v1.0/applications/$($objects.Blueprint.id)/microsoft.graph.agentIdentityBlueprint" -Label "blueprint $blueprintName"
            $left = @(Get-C2GraphCollection 'v1.0/servicePrincipals/microsoft.graph.agentIdentityBlueprintPrincipal' | Where-Object { $_.appId -eq $objects.Blueprint.appId })
            if ($left.Count) { Write-Host '[WARN] The blueprint principal is still listed. Deletion can take a few minutes to cascade; run -Mode Show later to confirm.' }
            else { Write-Host '[OK] The blueprint principal went with the blueprint.' }
        }
        else { Write-Host "[OK] blueprint $blueprintName is already gone" }
        Write-Host '[DONE] Deleted agent identities and blueprints stay restorable for 30 days, then Entra removes them for good.'
        return
    }
}
