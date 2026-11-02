# Module 3 lab: prove what the estate actually decides

This lab rebuilds both halves of the Module 3 demo for the Globomantics ERP gateway. The first half
asks who can reach the gateway, and answers with a Conditional Access What If evaluation instead of
a policy blade. The second half asks what credentials the gateway presents and who renews them, and
answers with a Key Vault you triage yourself. It's one workload asked two lifecycle questions:
`GLB-SC100-ERP-Gateway` in Conditional Access and `cert-erp-gateway` in the vault are the same system.

Globomantics is a fictional company. Every name in this lab is invented for teaching.

> **The first half changes a Microsoft Entra tenant, and the second half deploys billable Azure
> resources.** Run the tenant half only in a test tenant you control, never in production, and the
> Azure half in a subscription you use for learning. Remove both the same day.

## What's in the folder

| File | What it does |
|---|---|
| `Set-C2M03WhatIfFixture.ps1` | Plans, deploys, or removes the tenant objects the evaluation needs |
| `Invoke-C2M03WhatIf.ps1` | Runs the What If evaluation and checks the result. Read-only |
| `Deploy-C2M03KeyVault.ps1` | Plans, deploys, reads back, or removes the vault and its four objects |
| `iac\main.bicep` | The vault template, with every setting explained |

The scripts dot-source files in `..\shared`, so keep the `code` folder together.

## What the lab builds

**In your Microsoft Entra tenant** (`Set-C2M03WhatIfFixture.ps1`). Every name starts with
`GLB-SC100`, and every object that has a description or notes field carries a lab marker, which is
how Remove finds only what this lab created.

- Three security groups: `GLB-SC100-Contractors`, `GLB-SC100-ServiceDesk` and
  `GLB-SC100-Plant-Operators`.
- `GLB-SC100-CA-04 Require MFA for all users - strict`, report-only, excluding those groups. That
  exclusion list is the planted defect.
- `GLB-SC100-Contractor-01`, a cloud user **inside** `GLB-SC100-Contractors`. An exclusion group
  with no members excludes nobody, so without this user the evaluation would contradict the lesson.
  The account never signs in: its random password is never printed or stored, and it gets no license.
- `GLB-SC100-ERP-Gateway`, an app registration and its service principal, with no credentials and no
  API permissions. What If matches on an application ID, and an app without a service principal
  never appears in its target picker.

**In Azure** (`Deploy-C2M03KeyVault.ps1`), in the resource group `rg-globomantics-c2m03`, tagged
`course=SC100-C2M03`:

- A Key Vault in Azure RBAC mode, named `kv-glb-c2m03-` plus a suffix derived from your
  subscription, so the name is unique to you and identical on every rerun.
- A Key Vault Administrator role assignment at vault scope, for you only.
- Four data-plane objects, each carrying different lifecycle evidence:

| Object | What it is | Why it's there |
|---|---|---|
| `cert-erp-gateway` | Certificate, one-month validity, renews itself at 50 percent of its life | Always close to expiry, so there's always something to triage |
| `cert-plant-portal` | Certificate, twelve-month validity, renews at 80 percent | The healthy control |
| `legacy-tls-cert` | A **secret** holding certificate-shaped placeholder text, no expiry, no owner | It looks managed and isn't. That absence is the finding, so don't "fix" it |
| `key-data-signing` | RSA 2048 key with no rotation policy | No rotation, on purpose |

`cert-erp-gateway` renews on a percentage of its lifetime rather than a number of days before expiry.
A short certificate on a days-before trigger counts down toward zero and eventually expires, which
would quietly turn "find the credential that's about to fail" into "here's one that already
failed". A percentage trigger keeps its expiry in a band of roughly 15 to 30 days.

The vault's public network access is left **Enabled** on purpose. Network access is a design
decision Globomantics hasn't made yet, and the demo points at that setting as the open question.

## Before you start

**This lab builds on Module 2.** The evaluation needs `GLB-SC100-CA-01`, the all-users MFA policy,
so run [the Module 2 lab](../m02-agent-conditional-access/README.md)'s Deploy first. The fixture
script stops and tells you if CA-01 is missing.

**Licensing.** Microsoft Entra ID P1 for Conditional Access.

**Roles.**

- Microsoft Entra: Conditional Access Administrator, Groups Administrator, Application
  Administrator and User Administrator, or Global Administrator in a test tenant. Activate them
  before you run Deploy.
- Azure: Owner, or User Access Administrator plus Contributor, on the subscription. The vault
  template creates one role assignment, and that takes the right to assign roles.

**Tools.**

- PowerShell 7.2 or later
- The Azure CLI with Bicep: `az bicep install`
- Microsoft Graph PowerShell: `Install-Module Microsoft.Graph.Authentication -Scope CurrentUser`

If the vault script stops because your Azure token has no `mfa` claim, read
[the course README](../../README.md#before-any-lab-sign-in-so-azure-accepts-writes).

## Run it

Open PowerShell 7 in this folder and run these in order:

```powershell
# The tenant half: create the objects, then evaluate.
pwsh -NoProfile -File .\Set-C2M03WhatIfFixture.ps1 -Mode Plan
pwsh -NoProfile -File .\Set-C2M03WhatIfFixture.ps1 -Mode Deploy
pwsh -NoProfile -File .\Invoke-C2M03WhatIf.ps1

# The Azure half: build the vault, then triage it.
az login
az account set --subscription "<your-subscription-name-or-id>"
pwsh -NoProfile -File .\Deploy-C2M03KeyVault.ps1 -Mode Plan
pwsh -NoProfile -File .\Deploy-C2M03KeyVault.ps1 -Mode Deploy
pwsh -NoProfile -File .\Deploy-C2M03KeyVault.ps1 -Mode Show
```

The Graph scripts print the tenant name and default domain right after you sign in. **Read it, and
stop if it isn't your test tenant.** Add `-TenantId <your-test-tenant-id>` to pin it. The vault script
takes `-SubscriptionId` and `-TenantId` the same way, and reads `AZURE_SUBSCRIPTION_ID` and
`AZURE_TENANT_ID` if you've set them.

Delegated permissions, per script:

| Script | Requests |
|---|---|
| `Set-C2M03WhatIfFixture.ps1` | `User.Read`, `Policy.Read.All`, `Policy.ReadWrite.ConditionalAccess`, `Group.ReadWrite.All`, `Application.ReadWrite.All`, `User.ReadWrite.All` |
| `Invoke-C2M03WhatIf.ps1` | `User.Read`, `Policy.Read.ConditionalAccess`, `User.ReadBasic.All`, `GroupMember.Read.All`, `Application.Read.All` |

The vault's role assignment can take a few minutes to reach the data plane, so Deploy waits and
retries before it creates the four objects. That wait is normal.

## What to look for

**The evaluation.** `Invoke-C2M03WhatIf.ps1` calls the same API the portal's What If tool uses and
prints every policy's verdict and reason. You're looking for this pair:

| Policy | Verdict | Reason | What it proves |
|---|---|---|---|
| `GLB-SC100-CA-01` | applies | | The all-users MFA policy still covers the contractor |
| `GLB-SC100-CA-04` | doesn't apply | users | The exclusion reaches the contractor |

Read the two together. The exclusion is real, and it's still not an MFA bypass, because another
policy applies. Reading CA-04 alone could never tell you that.

Then run the same scenario by hand in the Microsoft Entra admin center, under **Entra ID >
Conditional Access > Policies > What If**: the contractor as the user, `GLB-SC100-ERP-Gateway` as the
target resource, browser, Windows, a compliant device, United States. Then clear **Country** and
**Device platform** and evaluate again. Read every reason. A policy that doesn't apply because the
user is excluded is a finding. A policy that doesn't apply because you under-described the sign-in
is your mistake, and it makes the estate look safer than it is. The script fails on purpose if a lab
policy comes back with not enough information, so it can't mistake one for the other.

**The vault.** `Deploy-C2M03KeyVault.ps1 -Mode Show` prints each object's lifecycle evidence, never a
secret's value. Triage it:

- Which credential fails first, and who renews it?
- Which object only looks managed? Secrets can carry an expiry date, but this one has none. Key
  Vault also renews certificate objects only, never certificate material stored as a secret, so
  nothing warns anyone and nothing renews it.
- What does the key's missing rotation policy cost you, and who should own the decision to add one?
- A renewed certificate helps only the services that pick up the new version. Who checks that?

## What it costs

The tenant objects cost nothing. Standard-tier vault operations and certificate renewals are billed
per operation, and the lab makes very few, but `cert-erp-gateway` renews itself about every 15 days
for as long as it exists. Check the [Key Vault pricing page](https://azure.microsoft.com/pricing/details/key-vault/)
and remove the lab when you're done.

## Clean up

```powershell
pwsh -NoProfile -File .\Deploy-C2M03KeyVault.ps1 -Mode Remove
pwsh -NoProfile -File .\Set-C2M03WhatIfFixture.ps1 -Mode Remove
```

The vault's Remove deletes the resource group after re-reading its course tag, waits for the delete,
then purges the soft-deleted vault so its name is free next time. It only ever purges this lab's
exact vault name. If a later Deploy finds that name still held by a soft-deleted vault, it stops and
prints the purge command rather than purging anything on its own.

The fixture's Remove deletes CA-04 while it's still report-only, then the contractor, the ERP
gateway app registration (its service principal goes with it) and the three groups. Each object must
carry the lab marker or it's left alone. If CA-04 survives because you switched it on, the groups
stay too, so CA-04 never ends up pointing at nothing. CA-01 to CA-03 belong to the Module 2 lab and
stay until that lab's Remove.

A deleted user or app registration stays restorable for 30 days, and the deleted user keeps its
sign-in name reserved meanwhile. If you want to rebuild the same day, restore the user under
**Entra ID > Users > Deleted users** instead of rerunning Deploy.

To remove the Azure half by hand:

```powershell
az group delete --name rg-globomantics-c2m03 --yes
az keyvault list-deleted --resource-type vault -o table
az keyvault purge --name <kv-glb-c2m03-name> --location <region>
```
