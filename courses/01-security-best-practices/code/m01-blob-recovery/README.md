# Module 1 lab: evidence a ransomware-resilient recovery design

This lab builds, in your own Azure subscription, the Globomantics estate behind the demo **Evidence a
ransomware-resilient recovery design**. Globomantics keeps its customer order documents in blob storage,
and leadership's requirement is that a compromised administrator can't eliminate the retained recovery
points. The lab gives you everything you need to test that requirement against real
settings: the order documents with operational backup switched on, an empty restore-target account,
and a Backup vault holding a vaulted copy outside the source account's blast radius.

Globomantics is a fictional company, and every name and order document in this lab is invented for
teaching.

## What's in the folder

| File | What it does |
|---|---|
| `Deploy-C1M01BlobRecovery.ps1` | Plans, deploys, reads, or removes the lab |
| `iac\main.bicep` | The subscription-scope template: the resource group and, only if you ask for it, Defender CSPM |
| `iac\modules\blob-recovery-estate.bicep` | The estate itself. Every resource is commented with the decision it supports |

The script carries full help. Run `Get-Help .\Deploy-C1M01BlobRecovery.ps1 -Full` to read it.

## What the lab builds

Everything lands in one resource group, `rg-globomantics-c1m01`, tagged `course=SC100-C1M01`:

- **The source.** A storage account named `stgloborders` plus a suffix, holding an `orders` container
  of fictional order documents, with blob soft delete, versioning, change feed and point-in-time restore
  all switched on. That's operational backup, and every piece of it is a property of the account an
  attacker would already control.
- **The restore target.** A second, empty storage account named `stglobrestore` plus a suffix, in the
  same region. Vaulted blob restore refuses the source account, so the target has to exist before the
  incident.
- **The vault.** A Backup vault, `bvault-globomantics`, with a daily vaulted backup policy and a backup
  instance protecting the `orders` container. Its managed identity holds the Storage Account Backup
  Contributor role on both accounts.

Storage account names are globally unique, so yours carry a suffix the template derives from your
resource group. In the video you'll see `stglobomanticsorders` and `rg-globomantics`; the design is
identical.

Vault immutability stays **Disabled** and Multi-User Authorization isn't configured, so you have
something to harden yourself.

## Before you start

- **PowerShell 7** (`pwsh`) and the **Azure CLI**, signed in with `az login`. If you don't have the
  Bicep CLI yet, run `az bicep install`.
- **Owner** on a subscription you use for learning, or **Contributor** plus **User Access
  Administrator**. The template writes role assignments for the vault's managed identity, and
  Contributor alone can't do that.
- **The Microsoft Defender portal**, if you want to classify the order account as a critical asset.
  The critical asset surface is fed by the Defender CSPM plan, which bills across your whole
  subscription, so the lab only turns it on when you pass `-EnableDefenderCspm`.

The script registers the `Microsoft.DataProtection` and `Microsoft.RecoveryServices` resource providers
and adds the Azure CLI `dataprotection` extension if they're missing. The vault's immutability settings
don't appear in the portal at all until `Microsoft.RecoveryServices` is registered.

## Run it

Open PowerShell 7 in this folder and run these in order:

```powershell
az login
az account set --subscription "<your-subscription-name-or-id>"

# Preview the deployment. Changes nothing.
pwsh -NoProfile -File .\Deploy-C1M01BlobRecovery.ps1 -Mode Plan

# Deploy the lab, upload the sample orders, and ask for the first backup. Safe to rerun.
pwsh -NoProfile -File .\Deploy-C1M01BlobRecovery.ps1 -Mode Deploy

# Read back the evidence, once the first backup job has finished.
pwsh -NoProfile -File .\Deploy-C1M01BlobRecovery.ps1 -Mode Show
```

To include Defender CSPM, deploy with `-Mode Deploy -EnableDefenderCspm` instead. If the plan is already
on in your subscription, the script leaves it exactly as you configured it.

The first backup job takes a few minutes. If the on-demand backup is refused because the instance is
still configuring, rerun `-Mode Deploy` a few minutes later, or let the daily 08:00 UTC run take the
first recovery point.

Working in more than one subscription? Add `-SubscriptionId <your-subscription-id>` to any mode, and
`-TenantId <your-tenant-id>` to refuse writes outside the tenant you name.

## What to look for

Work through the design in the same order the demo does: what matters, what's true today, what the
design should be, and what proves it.

**1. Classify the asset.** In the Microsoft Defender portal, go to **Settings > Microsoft XDR > Rules >
Critical asset management**. Create a custom rule that matches your order storage account and rate it
**High**, not Very high. Very high at Globomantics is identity and the plant-floor control systems, and
if everything is critical, nothing is. Microsoft Learn's
[classify critical assets](https://learn.microsoft.com/security-exposure-management/classify-critical-assets)
page walks you through the rule. A brand-new rule shows zero matching assets until the inventory catches
up, which can take about a day after Defender CSPM is turned on.

**2. Find out who can already break it.** Open `..\..\demo-artifacts\m01-scenario-card.html` for the
requirement, then go to the Backup vault's **Access control (IAM) > Role assignments**. Count the
principals at Backup Contributor or above, because that count is the real answer to leadership's
question. `-Mode Show` prints the same count. Remember the quiet half: deleting a recovery point looks
like an attack, but shortening a retention rule just lets recovery points age out with no deletion event
at all.

**3. Read the recovery architecture.** On the source account, open **Data protection**. Then open the
vault's **Backup instances**, select the instance, and choose **Restore**. Walk the wizard to the target
storage account picker and notice that the source account isn't offered. Vaulted restore goes to a
different account, so three things have to be true before the incident: the target exists, it holds no
containers with the same names, and the vault's identity has Storage Account Backup Contributor on it.
**Cancel the wizard.** If you'd rather run a real restore, send it to the restore-target account; Remove
deletes it with everything else.

**4. Harden the recovery path, then let the platform grade it.** On the vault, open **Properties**:

- **Immutable vault**: enable it, and **never select the lock**. *Enabled and locked* is irreversible,
  turns on WORM storage, and stops you deleting the lab until its recovery points expire. Immutability
  applies to the backup data in the vault, not to your production blobs or the operational backup on the
  source account.
- **Soft delete**: read its state and retention off the screen. Soft delete keeps deleted backup data for
  14 to 180 days, including recovery points aged out by a policy change.
- **Multi-User Authorization**: open the pane and close it without saving. It relies on a Resource Guard
  in a different subscription or tenant, which is the whole point of it, so it doesn't fit in a
  single-subscription lab.

Then open **Resiliency** in the Azure portal, go to **Manage > Vaults**, and find the vault's security
level. Resiliency grades each vault from None to Maximum, and only irreversible protection (locked
immutability or always-on soft delete) together with Multi-User Authorization reaches Maximum. The
[security levels page](https://learn.microsoft.com/azure/resiliency/security-levels-concept) lists
exactly what each level needs. Expect this lab to land below Maximum, and that gap is the lesson:
reversible protection is protection a compromised administrator can reverse.

Finish on `..\..\demo-artifacts\m01-decision-artifact.html`, the decision record that pairs every
requirement with the control that answers it.

## What it costs

**This lab creates billable resources:** two Standard_LRS storage accounts, and a Backup vault whose
vaulted blob backup bills per protected instance plus backup storage. The data is a few kilobytes of
fictional order documents, so it stays small, but it isn't zero. Defender CSPM, if you turn it on, bills
per billable resource across your whole subscription until you turn it off. Check the Azure pricing pages
for your region, and remove the lab the same day you build it.

## Clean up

Run the Remove mode:

```powershell
pwsh -NoProfile -File .\Deploy-C1M01BlobRecovery.ps1 -Mode Remove
```

A Backup vault that still holds backup data refuses to delete, so Remove unpicks it first: it turns
immutability off (possible only because you never locked it), turns soft delete off, deletes the backup
instance, then deletes the resource group and waits for it to finish. If this lab turned Defender CSPM
on, Remove sets it back to the Free tier.

**One case Remove can't finish in a day.** If your region applied **always-on** soft delete to the vault,
that setting is permanent. Remove then deletes the storage accounts, tells you so, and leaves the vault
until its soft-deleted data ages out. Run Remove again after the retention period.

If you'd rather do it by hand, run these in order (replace the instance name with the one the list
command prints):

```powershell
az dataprotection backup-vault update --resource-group rg-globomantics-c1m01 --vault-name bvault-globomantics --immutability-state Disabled
az dataprotection backup-vault update --resource-group rg-globomantics-c1m01 --vault-name bvault-globomantics --soft-delete-state Off
az dataprotection backup-instance list --resource-group rg-globomantics-c1m01 --vault-name bvault-globomantics --query "[].name" -o tsv
az dataprotection backup-instance delete --resource-group rg-globomantics-c1m01 --vault-name bvault-globomantics --name <instance-name> --yes
az group delete --name rg-globomantics-c1m01 --yes

# Only if you turned Defender CSPM on for this lab:
az security pricing create --name CloudPosture --tier Free
```

Check Cost Management the next day to confirm the charges stopped.
