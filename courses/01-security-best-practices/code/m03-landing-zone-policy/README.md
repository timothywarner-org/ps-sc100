# Module 3 lab: two landing zones, one template, two answers

This lab builds the Globomantics landing zone hierarchy behind the demo **Two landing zones, one
template, two answers**, in your own tenant, and then proves the point of it. One workload template
deploys while your subscription sits in the Online landing zone. The identical file is denied after the
subscription moves to Corp. Nothing about the workload changes; only its address does, and that's what an
Azure landing zone actually is.

Globomantics is a fictional company, and every name in this lab is invented for teaching.

## What's in the folder

| File | What it does |
|---|---|
| `Deploy-C1M03LandingZones.ps1` | Plans, deploys, reads, or removes the hierarchy and its policy assignments |
| `Invoke-C1M03Workload.ps1` | Deploys the workload template in whichever landing zone your subscription sits in, and moves the subscription between Online and Corp. In the video it's named `Invoke-M03Workload.ps1`; it behaves the same way |
| `iac\main.bicep` | The management-group template: the hierarchy, the subscription's placement, and the three assignments |
| `iac\modules\archetype-storage-policy.bicep` | One archetype's storage rule, deployed once for Corp and once for Online |
| `iac\workload-storage.bicep` | The workload template that runs twice and never changes |
| `iac\policy-params\` | Parameter files for assigning the same policies by hand, if you'd rather see every step |

Both scripts carry full help. Run `Get-Help .\Deploy-C1M03LandingZones.ps1 -Full` to read it.

## What the lab builds

```
Globomantics                  Allowed locations (Deny), inherited by everything below
└── Landing zones
    ├── Corp                  Storage account public access should be disallowed (Deny)
    └── Online                Storage account public access should be disallowed (Audit)
                              └── your subscription
```

The two archetype rules use the **same built-in definition** with two different effects. Corp hosts
internal workloads, so a public blob endpoint there is a design error and the platform prevents it.
Online hosts internet-facing workloads, so a public blob endpoint there is the business, and the platform
records it instead of blocking it. Deny and Audit aren't a maturity ladder. They're matched to exposure.

The org-wide rule sits on the top group, so every landing zone inherits it, including subscriptions that
don't exist yet. Some rules are about who you are, and some are about where you live.

## Before you start

This lab changes your tenant, not just a resource group, so read this part carefully.

- **Use a tenant and subscription you keep for learning.** Deploy moves your subscription under a new
  management group and assigns a Deny policy above it. Never run it against production.
- **Owner on the subscription, assigned directly** rather than inherited from a management group.
  Moving a subscription needs role assignment write on it, and an inherited Owner can only move it to
  groups where you're also Owner.
- **Permission to create management groups.** By default, any signed-in user can create one under the
  Tenant Root Group and becomes its Owner, so nothing here needs the Microsoft Entra "elevate access"
  toggle or any role at the root. If an administrator turned on the setting that requires write
  permission for new management groups, ask them to create `mg-globomantics` and make you its Owner.
- **PowerShell 7** (`pwsh`) and the **Azure CLI**, signed in with `az login`. If you don't have the Bicep
  CLI yet, run `az bicep install`.

**What changes about your subscription.** From about five minutes after Deploy finishes, every create or
update outside the allowed regions (East US 2 and East US by default) is refused. Deploy checks the
regions your existing resources already use and stops if any sits outside the list, because those
resources would otherwise become impossible to update until you remove the lab. If it stops, add the
regions it names with `-AllowedLocations`.

## Run it

Open PowerShell 7 in this folder and run these in order:

```powershell
az login
az account set --subscription "<your-subscription-name-or-id>"

# Preview. Changes nothing.
pwsh -NoProfile -File .\Deploy-C1M03LandingZones.ps1 -Mode Plan

# Build the hierarchy and move your subscription under Online. Safe to rerun.
pwsh -NoProfile -File .\Deploy-C1M03LandingZones.ps1 -Mode Deploy -ConfirmSubscriptionMove

# Wait about five minutes for the new assignments to take effect, then read them back.
pwsh -NoProfile -File .\Deploy-C1M03LandingZones.ps1 -Mode Show

# The first workload run, in Online. Expect DEPLOYED.
pwsh -NoProfile -File .\Invoke-C1M03Workload.ps1 -ShowTemplate

# Move to Corp and run the identical file. Expect PREVENTED.
pwsh -NoProfile -File .\Invoke-C1M03Workload.ps1 -MoveTo corp
```

To run the pair again from the start, use `.\Invoke-C1M03Workload.ps1 -Reset`, which moves the
subscription back to Online and deletes the storage account the first run created.

Working in more than one subscription? Add `-SubscriptionId <your-subscription-id>` to every command, and
`-TenantId <your-tenant-id>` to refuse writes outside the tenant you name.

## What to look for

**The hierarchy.** In the Azure portal, open **Management groups** and expand Globomantics, then Landing
zones. Corp and Online sit side by side, and your subscription sits under Online. An archetype is a
governance profile, not a folder: where a subscription lives decides what it's allowed to do.

**The rules, one landing zone at a time.** Open **Policy > Assignments** and set the **Scope** filter to
Globomantics - Online. The Allowed locations row shows a scope of Globomantics, not Online, because it's
inherited from the top of the hierarchy. The storage row is scoped to Online itself, with effect Audit.
Switch the filter to Globomantics - Corp. The org-wide row doesn't move, and the storage row shows the
same built-in definition with effect Deny.

**The fingerprint.** Both workload runs print the template's SHA-256 hash. Compare them. Same file, same
parameters, same account name, and only the subscription's placement changed between the two runs.

**The denial.** The second run comes back with `RequestDisallowedByPolicy`. The readable part of the
error is the non-compliance message the platform team wrote into the assignment, and it does more than
say no: it says where the workload belongs and who to talk to. The assignment itself arrives as a
resource ID in the error details, which is why a good non-compliance message matters.

**Deny doesn't reach backward.** After the move to Corp, the storage account from the first run is still
there. Moving it under a Deny assignment marks it non-compliant once Azure Policy evaluates it, and it
removes nothing. Deny gates new and updated resources, and remediating what already exists is separate
work.

Finish on `..\..\demo-artifacts\m03-governance-scorecard.html`, which sorts governance gaps by the
scope that owns the fix.

**On your own.** Ask for a resource outside the allowed regions and watch the inherited org-wide rule
refuse it. Use any storage account name that's free:

```powershell
az storage account create --name <globally-unique-name> --resource-group rg-globomantics-storefront --location westeurope --sku Standard_LRS
```

## Assign the policies by hand (optional)

If you'd rather build the rules yourself, the files in `iac\policy-params` hold each assignment's
parameters. Look up the built-in definitions by display name rather than copying IDs:

```powershell
$locations = az policy definition list --query "[?displayName=='Allowed locations'].name" -o tsv
$storage = az policy definition list --query "[?displayName=='Storage account public access should be disallowed'].name" -o tsv
$mgScope = '/providers/Microsoft.Management/managementGroups'

az policy assignment create --name deny-allowed-locations --policy $locations --scope "$mgScope/mg-globomantics" --params '@iac/policy-params/allowed-locations.json'
az policy assignment create --name deny-storage-public --policy $storage --scope "$mgScope/mg-globomantics-corp" --params '@iac/policy-params/storage-public-deny.json'
az policy assignment create --name audit-storage-public --policy $storage --scope "$mgScope/mg-globomantics-online" --params '@iac/policy-params/storage-public-audit.json'
```

The Bicep does the same thing and adds the display names, descriptions and non-compliance messages.

## What it costs

Management groups, policy assignments and compliance scans are free. The only billable resource is the
storage account the first workload run creates, which holds no data and costs very little. Remove deletes
it.

## Clean up

Run the Remove mode. It deletes `rg-globomantics-storefront`, deletes the three assignments, moves your
subscription back to the management group it started in (recorded when you first deployed), and deletes
the four Globomantics groups, children first:

```powershell
pwsh -NoProfile -File .\Deploy-C1M03LandingZones.ps1 -Mode Remove
```

If you'd rather do it by hand, run these in order. Delete the assignments first, so nothing in your
subscription is refused while the hierarchy comes down. If your subscription started directly under the
Tenant Root Group, its name is your tenant ID, which `az account show --query tenantId -o tsv` prints.

```powershell
$mgScope = '/providers/Microsoft.Management/managementGroups'
az group delete --name rg-globomantics-storefront --yes
az policy assignment delete --name deny-allowed-locations --scope "$mgScope/mg-globomantics"
az policy assignment delete --name deny-storage-public --scope "$mgScope/mg-globomantics-corp"
az policy assignment delete --name audit-storage-public --scope "$mgScope/mg-globomantics-online"
az account management-group subscription add --name <original-parent-group> --subscription <your-subscription-id>
az account management-group delete --name mg-globomantics-corp
az account management-group delete --name mg-globomantics-online
az account management-group delete --name mg-globomantics-landingzones
az account management-group delete --name mg-globomantics
```

Removing a subscription from a management group or deleting a group never deletes or disables the
subscription itself.
