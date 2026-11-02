# Module 1 lab: investigate one incident across three signals

This lab rebuilds the Globomantics investigation from the Module 1 demo in your own Azure
subscription. You get one Microsoft Sentinel incident built from three fictional observations, you
investigate it in the Microsoft Defender portal, and then you use three mapping-only rules to
challenge a coverage claim on the MITRE ATT&CK page.

Globomantics is a fictional company. Every name, account, host and address in this lab is invented
for teaching.

## What's in the folder

| File | What it does |
|---|---|
| `Deploy-C2M01Investigation.ps1` | Plans, deploys, reads back, or removes the lab |
| `iac\main.bicep` | The template. Every resource is commented with the reason it exists |
| `iac\investigation.kql` | The query behind the synthetic investigation rule |

The script dot-sources `..\shared\C2.Auth.ps1`, so keep the `code` folder together.

## What the lab builds

Everything lands in Azure, in one resource group, `rg-globomantics-c2m01`, tagged
`course=SC100-C2M01`. Nothing changes in your Microsoft Entra tenant.

- **The workspace.** A Log Analytics workspace, `law-glb-c2m01`, with 30-day retention, onboarded
  to Microsoft Sentinel.
- **The investigation.** A scheduled analytics rule, `GLOB SYNTHETIC Identity endpoint ERP
  investigation`, that runs every five minutes over three fictional observations: an unfamiliar
  sign-in for `planner-04`, an unexpected process on `eng-ws-17`, and ERP activity for the same
  account. It raises one high-severity alert and one incident, with Account, Host and URL entities,
  and it stores the observations inside the alert so you can still read them after the query goes
  quiet.
- **The coverage trap.** Three `GLOB MAP ONLY` rules carrying real MITRE ATT&CK techniques, T1110,
  T1021 and T1567, over a query that can never return a row.

**Every event in this lab is synthetic, and the rules say so in their descriptions.** It proves that
an analyst can follow one account, one device and one application from a single incident. It
doesn't prove that three Microsoft products independently detected an attack, and it doesn't prove
native Microsoft Defender XDR correlation.

## Before you start

- **PowerShell 7.2 or later** and the **Azure CLI** with Bicep (`az bicep install`), signed in with
  `az login`. Azure Cloud Shell has all of these.
- **Contributor** on a subscription you use for learning.
- **A test tenant for the Defender portal step.** Connecting a workspace to the Defender portal
  makes it the tenant's primary workspace when there isn't one, and changing a primary workspace
  moves the Defender XDR connector. If your tenant already has a primary workspace, don't change it
  for this lab. Connecting a primary workspace takes at least the Security Administrator role in
  Microsoft Entra, plus Owner on the subscription or User Access Administrator with Microsoft
  Sentinel Contributor, as
  [Connect Microsoft Sentinel to the Microsoft Defender portal](https://learn.microsoft.com/azure/sentinel/microsoft-sentinel-onboard)
  explains.

If the script stops because your Azure token has no `mfa` claim, read
[the course README](../../README.md#before-any-lab-sign-in-so-azure-accepts-writes). It takes a minute
to fix.

## Run it

Open PowerShell 7 in this folder and run these in order:

```powershell
az login
az account set --subscription "<your-subscription-name-or-id>"

# Compile the template and preview the change. Changes nothing.
pwsh -NoProfile -File .\Deploy-C2M01Investigation.ps1 -Mode Plan

# Deploy the lab, seeded at the current time. Safe to rerun.
pwsh -NoProfile -File .\Deploy-C2M01Investigation.ps1 -Mode Deploy
```

Then connect the workspace in the Defender portal. Sign in at
[security.microsoft.com](https://security.microsoft.com), go to **System > Settings > Microsoft
Sentinel > Workspaces**, choose **Connect a workspace**, and pick `law-glb-c2m01`. The template
can't do this step for you.

Give the rule about 15 minutes, then read the evidence back:

```powershell
pwsh -NoProfile -File .\Deploy-C2M01Investigation.ps1 -Mode Show
```

**Why the timing matters.** The query keeps rows only for 30 minutes after the seed time Deploy
prints. The rule fires once inside that window, and its one-hour suppression stops repeats. After
the window closes, the rule keeps running and returns nothing, and an incident that never appeared
looks exactly like a quiet rule. Show tells the two apart: it says WAIT while the window is open and
FAIL once it has closed with no incident. To replay the exercise, run Deploy again, which seeds at
the new current time.

Working in more than one subscription? Add `-SubscriptionId <your-subscription-id>` to any mode, and
`-TenantId <your-tenant-id>` to refuse writes outside the tenant you name. The script also reads
`AZURE_SUBSCRIPTION_ID` and `AZURE_TENANT_ID` if you've set them.

## What to look for

Work through the investigation in the Defender portal, under **Investigation & response >
Incidents & alerts > Incidents**.

1. **Open the incident.** Its title carries the word SYNTHETIC. The incident page has a row of tabs
   and an incident graph with three nodes: `planner-04`, `eng-ws-17` and `erp.globomantics.example`.
   A graph means you're on the incident page.
2. **Open its alert.** The **What happened** text says the data is synthetic, and **Related events**
   lists the three observations, one minute apart. A Related events list means you're on the alert
   page. These are three rows inside one Sentinel alert, not three alerts from three products.
3. **Back on the incident, count the assets.** The graph draws three things. Check how many of them
   the **Assets** tab counts. Your response playbooks act on assets, so context you can see isn't
   automatically something you can contain.
4. **Follow the workstation.** There's no endpoint history behind `eng-ws-17` in this lab, so the
   trail stops. That doesn't mean the device is clean. It means this evidence can't answer the
   question, which is a different finding.
5. **Challenge the coverage claim.** Open **Microsoft Sentinel > Threat management > MITRE ATT&CK**,
   find T1110, and open `GLOB MAP ONLY Password spray` read-only. The technique shows an active rule,
   and the rule's query returns nothing. If the page carries a Preview label in your tenant, treat it
   as a preview feature. Leave the simulated coverage view off while you read active rules.

The question to answer for yourself, because it's the one SC-100 asks: active tells you a rule is
enabled, and mapped tells you which technique it claims. What would make a cell *tested*, and what
would you need attached to it before you'd call it covered in a design review?

## What it costs

The workspace is pay-as-you-go and Microsoft Sentinel bills on the data you ingest. This lab ingests
almost nothing: the only rows it writes are the alert and incident records Sentinel creates. Check
the [Microsoft Sentinel pricing page](https://www.microsoft.com/en-us/security/pricing/microsoft-sentinel/)
for your region, and remove the lab the same day.

## Clean up

First, if you connected the workspace, disconnect it in the Defender portal: **System > Settings >
Microsoft Sentinel > Workspaces**, select `law-glb-c2m01`, and choose **Disconnect workspace**. Then
remove the Azure half:

```powershell
pwsh -NoProfile -File .\Deploy-C2M01Investigation.ps1 -Mode Remove
```

Remove re-reads the resource group's course tag immediately before it deletes the group, and it
waits for the delete to finish. If you'd rather do it by hand:

```powershell
az group delete --name rg-globomantics-c2m01 --yes
```

Check Cost Management the next day to confirm the charges stopped.
