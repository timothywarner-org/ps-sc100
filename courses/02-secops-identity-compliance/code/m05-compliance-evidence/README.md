# Module 5 lab: walk one obligation to its evidence

This lab rebuilds the Module 5 demo for Globomantics. You take one fictional obligation, find the
historical evidence it needs in Microsoft Purview Audit, measure where that evidence runs out, and
then read a regulatory standard on the Microsoft Defender for Cloud regulatory compliance dashboard
and decide what a passing control actually proves.

Globomantics is a fictional company. The obligation and the control record below are invented for
teaching.

> **The first half reads your Microsoft 365 tenant's audit log, and the optional retention policy
> changes it. The second half assigns a policy initiative to an Azure subscription.** Use a test
> tenant and a subscription you use for learning.

## The obligation

> For the restricted Materials formulation library, Globomantics shall retain records sufficient to
> evaluate whether access was limited to authorized personnel from September 1, 2025, through
> August 31, 2026, UTC.

The control record that answers it is **GLO-DATA-012**. Legal approves the interpretation and scope.
The Materials data owner approves access. The identity owner keeps effective-dated grants, removals
and approvals. The service owner validates enforcement, collection and retention. The compliance
owner evaluates the evidence and records exceptions and gaps.

Notice what the obligation asks for: records sufficient to **evaluate** access, over a **dated
window**. An audit event on its own doesn't meet it. You need the event and the authorization that
was in force at the time, for the whole window.

## What's in the folder

| File | What it does |
|---|---|
| `Get-C2M05AuditBoundary.ps1` | Measures the oldest audit record you can still retrieve, and the gap against the window. Read-only |
| `Deploy-C2M05Compliance.ps1` | Plans, assigns, reads back, or removes the NIST SP 800-53 R5.1.1 standard |
| `iac\main.bicep` | The subscription-scope policy assignment |

`Deploy-C2M05Compliance.ps1` dot-sources `..\shared\C2.Auth.ps1`, so keep the `code` folder together.

## What the lab builds

- **Nothing, for the audit measurement.** `Get-C2M05AuditBoundary.ps1` only searches and reads.
- **One optional audit retention policy** in your tenant, if you create it with the commands below.
- **One policy assignment** in Azure, `glb-sc100-nist-r511`, at subscription scope, which assigns
  the **NIST SP 800-53 R5.1.1** built-in initiative. That's what makes the standard assessable on the
  regulatory compliance dashboard. Its definitions are almost entirely Audit and Manual effects, so
  it observes and reports and denies nothing. The script finds the initiative by its display name
  rather than a hardcoded ID.

**Why R5.1.1 and not Rev. 5.** Both initiatives exist in Azure Policy, and either one assigns
cleanly. Defender for Cloud's
[available-standards table](https://learn.microsoft.com/azure/defender-for-cloud/concept-regulatory-compliance-standards)
lists NIST SP 800 53 R5.1.1 for Azure, so that's the one that renders for an Azure subscription.

## Before you start

**Licensing.** Audit (Standard) is enough to search the audit log. The optional retention policy
needs Audit (Premium), and retaining a user's records beyond 180 days needs that user to hold an E5
license or a qualifying add-on, as
[Manage audit log retention policies](https://learn.microsoft.com/purview/audit-log-retention-policies)
explains.

**Roles.**

- Audit search: the **View-Only Audit Logs** or **Audit Logs** role in Exchange Online, which the
  Compliance Management and Organization Management role groups include.
- Retention policy: the **Organization Configuration** role in the Microsoft Purview portal.
- Azure: Resource Policy Contributor, Security Admin or Owner on the subscription.

**Tools.**

- PowerShell 7.2 or later
- The Exchange Online module: `Install-Module ExchangeOnlineManagement -Scope CurrentUser`
- The Azure CLI with Bicep: `az bicep install`

**Time.** The dashboard takes hours to render a newly assigned standard, so assign it the day before
you want to read it.

If the assignment script stops because your Azure token has no `mfa` claim, read
[the course README](../../README.md#before-any-lab-sign-in-so-azure-accepts-writes).

## Run it

### Part 1: find the evidence and where it ends

**Measure the boundary first.**

```powershell
# Against the fictional Globomantics window.
pwsh -NoProfile -File .\Get-C2M05AuditBoundary.ps1

# Against your own window, and list the retention policies that shape it.
pwsh -NoProfile -File .\Get-C2M05AuditBoundary.ps1 -WindowStart 2026-01-01 -WindowEnd 2026-06-30 -CheckRetentionPolicies
```

It does the retention arithmetic before it signs in, probes the audit log backwards in 30-day blocks,
then walks the oldest block one day at a time and reports the oldest record's own timestamp. A search
that fails is reported as UNKNOWN, never as empty, because "there's nothing before that date" isn't
established while any search in the range failed. The gap is measured from today, so it grows by a
day every day.

**Then search the portal.** In the [Microsoft Purview portal](https://purview.microsoft.com), open
**Audit**. Pick a SharePoint library in your test tenant that has seen recent activity, to stand in for
the Materials library, and search it for **Accessed file** and **Downloaded file**, with the library
in the **File, folder, or site** box. Never run an unfiltered search for this: it puts every activity
in the tenant on screen.

- An audit search runs as a job. It queues, runs, and its results appear when you open the
  completed row in the search history. Run it before you need it.
- Run one job over the front of the window and one over the part your boundary measurement says is
  retrievable. If the portal refuses a long date range, that split is how you get around it anyway.
  The empty job and the populated job together **show** the gap instead of asserting it.
- If the library comes back thin, add **Modified file**, **Uploaded file** and **Viewed file**. A
  modification isn't an access, so read which activity each record is.

**Optionally, create the retention policy**, to see that a twelve-month setting isn't twelve months
of history. In Security & Compliance PowerShell:

```powershell
Connect-IPPSSession
New-UnifiedAuditLogRetentionPolicy -Name 'GLB-SC100-SharePoint-12mo' -Description 'Globomantics Materials obligation lab' -RecordTypes SharePointFileOperation -RetentionDuration TwelveMonths -Priority 100
Get-UnifiedAuditLogRetentionPolicy | Format-List Priority, Name, RecordTypes, RetentionDuration
```

Then search again. The search reaches no further than it did, because a retention policy governs the
records collected from now on and changes nothing already committed. Priority 100 keeps the lab policy
from outranking any policy your tenant already relies on, since a lower number wins.

### Part 2: read the standard

```powershell
az login
az account set --subscription "<your-subscription-name-or-id>"

# Resolve the initiative, compile the template and preview the change. Changes nothing.
pwsh -NoProfile -File .\Deploy-C2M05Compliance.ps1 -Mode Plan

# Assign the standard, then ask Azure Policy to start an evaluation scan. Safe to rerun.
pwsh -NoProfile -File .\Deploy-C2M05Compliance.ps1 -Mode Deploy

# Tomorrow: has the dashboard rendered it, is it still on its way, or will it never appear?
pwsh -NoProfile -File .\Deploy-C2M05Compliance.ps1 -Mode Show
```

A standard that's still on its way and a standard that will never render look the same in the portal:
a missing row. Show tells them apart by reading the dashboard's data, the number of policy states
Azure Policy has evaluated, and the assignment's age together. Microsoft documents that a standard
with no relevant resources in the subscription isn't shown at all, even when it's assigned.

If the display name ever stops matching, Plan and Deploy stop and list the NIST initiatives that do
exist. Pass the right one with `-InitiativeDisplayName`, and never paste an ID from memory. The script
takes `-SubscriptionId` and `-TenantId`, and reads `AZURE_SUBSCRIPTION_ID` and `AZURE_TENANT_ID`.

## What to look for

**In Purview,** line up one access event's principal, resource and timestamp against the
authorization in force at that moment. Then put the boundary measurement next to the window. The
front of the window has no records behind it, and nothing you configure today brings them back. That
gap is the finding, and documenting it as an exception against GLO-DATA-012 is the honest move.

**In Defender for Cloud,** open **Regulatory compliance**, select the NIST SP 800 53 R5.1.1 tab, and
expand one control. Each status carries a word and an icon, so read the word. Then ask the question
SC-100 cares about: does a passing automated assessment prove the obligation is met, or only that one
technical condition holds today? The dashboard maps controls to assessments. It doesn't know who
approved access to the Materials library, or when.

## What it costs

The policy assignment is free. Its Audit definitions assess resources you already have. Audit search
and the retention policy carry no separate charge beyond the licensing they need.

## Clean up

```powershell
pwsh -NoProfile -File .\Deploy-C2M05Compliance.ps1 -Mode Remove
```

Remove deletes `glb-sc100-nist-r511` after checking its display name carries the lab prefix, and the
standard leaves the dashboard on its next refresh. By hand:

```powershell
az policy assignment delete --name glb-sc100-nist-r511 --scope /subscriptions/<your-subscription-id>
```

If you created the retention policy, remove it in Security & Compliance PowerShell. Microsoft notes
that removal can take up to 30 minutes to reach your organization.

```powershell
Connect-IPPSSession
Remove-UnifiedAuditLogRetentionPolicy -Identity 'GLB-SC100-SharePoint-12mo'
```
