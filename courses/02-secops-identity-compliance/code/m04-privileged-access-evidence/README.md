# Module 4 lab: read the grant, then find the evidence

This lab rebuilds the Module 4 demo for Globomantics. The first half puts standing privilege next to
eligible privilege in Microsoft Entra Privileged Identity Management (PIM). The second half asks the
same question one plane over, about Azure resource roles, where Microsoft Defender for Cloud does the
looking and hands you a finding. Both halves make one point: a grant is visible configuration, and
whether anyone used it is separate evidence on a different surface.

Globomantics is a fictional company. Every name in this lab is invented for teaching.

> **The first half changes a Microsoft Entra tenant, and the second half turns on a paid Defender for
> Cloud plan for a whole subscription.** Run the tenant half only in a test tenant you control, never
> in production, and the Azure half in a subscription you use for learning.

## What's in the folder

| File | What it does |
|---|---|
| `Set-C2M04PrivilegedAccess.ps1` | Plans, deploys, reads back, or removes the three accounts and their role assignments |
| `Deploy-C2M04Cspm.ps1` | Plans, turns on, reads back, or turns off Defender CSPM with permissions management |
| `iac\main.bicep` | The subscription-scope template for the Defender CSPM plan |

The scripts dot-source files in `..\shared`, so keep the `code` folder together.

## What the lab builds

**In your Microsoft Entra tenant** (`Set-C2M04PrivilegedAccess.ps1`), with deliberately
low-privilege roles. The point is the shape of each grant, not its power, and the script never
touches Global Administrator.

| Account | Grant |
|---|---|
| `GLB-SC100-Helpdesk Analyst` | **Eligible** for Helpdesk Administrator, expiring after 90 days |
| `GLB-SC100-Plant Operator` | **Eligible** for Helpdesk Administrator, expiring after 90 days |
| `GLB-SC100-Legacy Admin` | **Standing** (permanently active) Directory Readers |

An eligible assignment has to be activated, it expires, and using it leaves activation evidence. A
standing assignment is simply on. The script looks both roles up by display name rather than by a
hardcoded ID, so it can't point at the wrong role. The three accounts never sign in: each gets a
random password that's never printed or stored, no license, no group and no mailbox.

**In Azure** (`Deploy-C2M04Cspm.ps1`): the **Defender CSPM** plan at Standard for your subscription,
with the **permissions management** extension on. That extension is the cloud infrastructure
entitlement management (CIEM) capability in Defender for Cloud. The template's API still calls it
`EntraPermissionsManagement`, after a standalone product that is now **retired**, and Defender for
Cloud is where the capability lives today.

If Defender CSPM is already Standard on your subscription, the script changes nothing, because
rewriting a plan you configured yourself could switch off extensions you rely on. It tells you where
to turn the extension on by hand instead.

## Before you start

**Licensing.** PIM requires **Microsoft Entra ID P2**. Defender CSPM is a paid plan billed per
billable resource in the subscription.

**Roles.**

- Microsoft Entra: Privileged Role Administrator to manage the assignments and User Administrator
  to create the accounts, or Global Administrator in a test tenant.
- Azure: Owner, Contributor or Security Admin on the subscription to change a Defender plan.

**Tools.**

- PowerShell 7.2 or later
- The Azure CLI with Bicep: `az bicep install`
- Microsoft Graph PowerShell: `Install-Module Microsoft.Graph.Authentication -Scope CurrentUser`

**Time.** Defender for Cloud assesses on its own cycle of roughly 12 to 24 hours, so turn the plan
on the day before you want to read findings.

If the CSPM script stops because your Azure token has no `mfa` claim, read
[the course README](../../README.md#before-any-lab-sign-in-so-azure-accepts-writes).

## Run it

Open PowerShell 7 in this folder and run these in order:

```powershell
# The tenant half.
pwsh -NoProfile -File .\Set-C2M04PrivilegedAccess.ps1 -Mode Plan
pwsh -NoProfile -File .\Set-C2M04PrivilegedAccess.ps1 -Mode Deploy
pwsh -NoProfile -File .\Set-C2M04PrivilegedAccess.ps1 -Mode Show

# The Azure half. Show is worth running again tomorrow, after an assessment cycle.
az login
az account set --subscription "<your-subscription-name-or-id>"
pwsh -NoProfile -File .\Deploy-C2M04Cspm.ps1 -Mode Plan
pwsh -NoProfile -File .\Deploy-C2M04Cspm.ps1 -Mode Deploy
pwsh -NoProfile -File .\Deploy-C2M04Cspm.ps1 -Mode Show
```

The PIM script prints the tenant name and default domain right after you sign in. **Read it, and stop
if it isn't your test tenant.** Add `-TenantId <your-test-tenant-id>` to pin it. Deploy and Remove
request `User.Read`, `User.ReadWrite.All` and `RoleManagement.ReadWrite.Directory`. Show requests
only `User.Read`, `User.Read.All` and `RoleManagement.Read.Directory`.

The CSPM script takes `-SubscriptionId` and `-TenantId` too, and reads `AZURE_SUBSCRIPTION_ID` and
`AZURE_TENANT_ID` if you've set them.

## What to look for

**Standing next to eligible.** Open the Microsoft Entra admin center and go to **ID Governance >
Privileged Identity Management > Microsoft Entra roles > Assignments**. Filter by role first:
Helpdesk Administrator on the **Eligible assignments** tab, then Directory Readers on the **Active
assignments** tab. An unfiltered view in a real tenant mixes the lab rows with every other
assignment, including permanently eligible ones with no end date.

- The eligible rows carry an end date. The standing row doesn't.
- Now go looking for the history behind each row in the PIM audit history and the Microsoft Entra
  audit logs. What can you prove about whether any of these grants was ever used, and how far back
  can you prove it?

**The finding one plane over.** `Deploy-C2M04Cspm.ps1 -Mode Show` lists every identity and access
assessment on your subscription, findings first. The demo opens **Privileged roles should not have
permanent access at the subscription and resource group level**. Whether that exact recommendation
appears depends on what Defender for Cloud finds in your subscription, so open whichever finding you
have under **Defender for Cloud > Recommendations**, and read it before you touch anything:

- What scope is it about?
- What severity did Defender for Cloud give it?
- What does it recommend, and what would you verify before you removed a grant?

An empty list isn't evidence of a clean estate. A subscription the plan never assessed looks exactly
the same, which is why coverage per subscription, per AWS account and per GCP project is an
enablement decision with a bill attached.

## What it costs

The tenant objects cost nothing beyond the licensing PIM already needs. Defender CSPM is billed per
billable resource for as long as it's on. Check the
[Defender for Cloud pricing page](https://azure.microsoft.com/pricing/details/defender-for-cloud/),
and turn the plan back off when you're done if you turned it on for this lab.

## Clean up

```powershell
pwsh -NoProfile -File .\Deploy-C2M04Cspm.ps1 -Mode Remove
pwsh -NoProfile -File .\Set-C2M04PrivilegedAccess.ps1 -Mode Remove
```

**The CSPM Remove turns Defender CSPM back to Free for the whole subscription, and it asks you to
confirm first.** Run it only if you turned the plan on for this lab. Add `-Confirm:$false` to skip
the prompt once you're sure. By hand, the same change is:

```powershell
az security pricing create --name CloudPosture --tier free
```

The PIM Remove removes each eligible assignment through PIM with an `adminRemove` request, deletes
the standing assignment, then deletes the three accounts. Each account must carry the lab marker or
it's left alone. A deleted user stays restorable for 30 days and keeps its sign-in name reserved
meanwhile, so restore it under **Entra ID > Users > Deleted users** if you want to rebuild the same
day.
