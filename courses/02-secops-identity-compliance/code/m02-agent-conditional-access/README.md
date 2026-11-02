# Module 2 lab: govern an agent identity with Conditional Access

This lab builds the Globomantics identity estate from the Module 2 demo in your own Microsoft Entra
test tenant: a supply-chain agent with an identity you can govern, the Conditional Access policy
that governs it, and the human policies that can't reach it.

Globomantics is a fictional company. Every name in this lab is invented for teaching.

> **This lab changes a Microsoft Entra tenant.** Run it only in a test tenant you control, never in
> production. Every policy it creates is report-only, so none of them can lock anyone out, and the
> script never switches one on.

## What's in the folder

| File | What it does |
|---|---|
| `Set-C2M02AgentAccess.ps1` | Plans, deploys, reads back, or removes the lab's tenant objects |

The script dot-sources `..\shared\C2.Graph.ps1`, which holds the policy definitions, so keep the
`code` folder together.

## What the lab builds

Everything lands in your Microsoft Entra tenant. Nothing is created in Azure. Every object's name
starts with `GLB-SC100`, which is how the Remove mode finds only what this lab created.

**The human estate**, all report-only:

- `GLB-SC100-CA-01 Require MFA for all users`
- `GLB-SC100-CA-02 Block legacy authentication`
- `GLB-SC100-CA-03 Require compliant device for admins`, which targets the Global Administrator role

**The agent**, with you as sponsor and owner:

- `GLB-SC100-M2 Supply-chain blueprint`, an agent identity blueprint
- its blueprint principal
- `GLB-SC100-M2 Parts reorder agent`, an agent identity created from that blueprint

**The agent policy**, report-only:

- `GLB-SC100-AGENT-01 Block high-risk supply-chain agents`. It targets the blueprint **principal**,
  so it covers every agent the blueprint produces, not one agent. The condition is high agent risk
  and the control is Block.

The video shows the same objects with a `GLOB-` prefix.

**What the lab proves, and what it doesn't.** It proves inspectable configuration: who the agent is,
who sponsors it, and which policy governs it. It creates no credentials, grants the agent no API
permissions and signs nobody in, so it doesn't prove that the agent reached a resource, that a risk
was detected, or that a block was enforced.

## Before you start

**Licensing.** Conditional Access needs Microsoft Entra ID P1. Conditional Access for agents needs
Microsoft 365 E7, or Microsoft Agent 365 paired with at least Microsoft Entra ID P1 or Microsoft 365
E3, as
[Target agent identities in Conditional Access](https://learn.microsoft.com/entra/identity/conditional-access/howto-target-agent-identities)
explains. Microsoft Entra Agent ID itself is available to all Microsoft Entra customers, and the
security features that extend to agents are what need the Agent 365 entitlement. The agent risk
condition is in **preview**. Check the
[Microsoft Entra Agent ID documentation](https://learn.microsoft.com/entra/agent-id/) for the current
availability of each feature in your tenant before you design around it.

**Roles.** Conditional Access Administrator for the policies and Agent ID Administrator for the
blueprint and the agent, or Global Administrator in a test tenant. The account that creates a
blueprint becomes its owner, and an owner can manage the blueprint's agents without the Agent ID
Administrator role.

**Tools.** PowerShell 7.2 or later and the Microsoft Graph PowerShell authentication module:

```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
```

**Security defaults.** If your test tenant still has security defaults turned on, Microsoft Entra
may not let you create Conditional Access policies alongside them. Use a test tenant that's set up
for Conditional Access rather than turning off a tenant safeguard just for a lab.

## Run it

Open PowerShell 7 in this folder and run these in order:

```powershell
# Print the request bodies. No sign-in, no changes.
pwsh -NoProfile -File .\Set-C2M02AgentAccess.ps1 -Mode Plan

# Sign in to Microsoft Graph and create the lab objects. Safe to rerun.
pwsh -NoProfile -File .\Set-C2M02AgentAccess.ps1 -Mode Deploy

# Read the policies and the agent objects back.
pwsh -NoProfile -File .\Set-C2M02AgentAccess.ps1 -Mode Show
```

Deploy prints the tenant name and default domain right after you sign in. **Read it, and stop if it
isn't your test tenant.** To pin the tenant, add `-TenantId <your-test-tenant-id>`, or set
`AZURE_TENANT_ID`.

The script asks for delegated permissions per mode and nothing more. Deploy requests `User.Read`,
`Application.Read.All`, `AgentIdentityBlueprint.Create`, `AgentIdentityBlueprintPrincipal.Create`,
`AgentIdentity.Create.All`, `Policy.Read.All` and `Policy.ReadWrite.ConditionalAccess`. The first
run asks you to consent to them.

**If an existing lab policy has drifted**, Deploy stops and tells you which part differs. It never
overwrites your change, because a silent overwrite would hide exactly the drift an architect needs
to see.

**If the agent policy fails with error 1267**, your tenant isn't entitled to agent policies. The
script keeps the blueprint, principal and agent it already created and prints the steps to build
the policy by hand in the Microsoft Entra admin center. The step that trips people up is the picker:
open the **Agent blueprint principals** tab in the enhanced object picker. Picking from the agent
identities list targets one agent, not the family, and the users and groups picker can't find a
blueprint principal at all. Run `-Mode Show` afterward and it checks a hand-made policy for the
four things that matter: target, condition, control and state.

## What to look for

Deploy ends by printing four IDs, and the difference between them is the lesson:

| ID | What it identifies |
|---|---|
| Blueprint object ID | The blueprint as a directory object |
| Blueprint app ID | The blueprint as an application. The agent's parent points here |
| Blueprint principal ID | The blueprint's identity in your tenant. The agent policy targets this |
| Agent object ID | The one agent created from the blueprint |

Then open the objects in the Microsoft Entra admin center:

1. **Open the agent.** Search the admin center for `GLB-SC100-M2 Parts reorder agent`, then find
   its blueprint, its sponsor and its owner.
   An agent you can't trace to an accountable human is an agent you can't govern.
2. **Open GLB-SC100-AGENT-01** under **Entra ID > Conditional Access > Policies**. The assignment is
   the blueprint principal, the condition is agent risk (preview), and the only grant control a
   policy for agents allows is Block.
3. **Read the human estate.** Every one of CA-01 to CA-03 targets users or a role. Ask yourself
   which of them would evaluate when the agent signs in on its own, and why the answer is none.

That last question is the design point. An estate built for people doesn't automatically cover the
agents now acting inside it, so the architect recommends policy that targets agents directly, and
licenses for it.

## Clean up

```powershell
pwsh -NoProfile -File .\Set-C2M02AgentAccess.ps1 -Mode Remove
```

Remove deletes `GLB-SC100-AGENT-01`, then CA-01 to CA-03, then the agent and the blueprint, which
takes the blueprint principal with it. It requests `Policy.ReadWrite.ConditionalAccess`,
`AgentIdentity.DeleteRestore.All` and `AgentIdentityBlueprint.DeleteRestore.All` to do that.

It deletes a policy only while it's still report-only. A lab policy you switched on is left in
place with a warning, because it's no longer the lab's object to delete. CA-04 and the other
Module 3 objects stay for that lab's own Remove mode.

Deleted agent identities and blueprints stay restorable for 30 days, then Microsoft Entra removes
them for good. If you'd rather clean up by hand, these are the calls Remove makes, in order:

```powershell
Connect-MgGraph -Scopes Policy.Read.All, Policy.ReadWrite.ConditionalAccess, Application.Read.All, AgentIdentity.DeleteRestore.All, AgentIdentityBlueprint.DeleteRestore.All
# Each lab policy, by its ID from the Conditional Access policy list:
Invoke-MgGraphRequest -Method DELETE -Uri 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies/<policy-id>'
# The agent, then the blueprint:
Invoke-MgGraphRequest -Method DELETE -Uri 'https://graph.microsoft.com/v1.0/servicePrincipals/<agent-object-id>/microsoft.graph.agentIdentity'
Invoke-MgGraphRequest -Method DELETE -Uri 'https://graph.microsoft.com/v1.0/applications/<blueprint-object-id>/microsoft.graph.agentIdentityBlueprint'
```
