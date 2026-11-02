# Module 1 lab: follow an attack path to a critical asset

This folder builds, in your own Azure subscription, the Globomantics attack path I walk through in the **Follow an attack path to a critical asset** demo. You get two internet-facing web VMs that share one managed identity, and that identity can read a Globomantics order storage account. The shared identity is the **choke point** Microsoft Defender for Cloud finds, and the storage account is the **critical asset** at the end of the path.

**This lab is deliberately weak, and it bills while it runs.** Point it only at a storage account that holds fictional data, and tear it down as soon as you're done.

## What's in the folder

| File | What it does |
|---|---|
| `Deploy-C3M01AttackPath.ps1` | Previews, deploys, or tears down the lab from PowerShell 7 on Windows, macOS, or Linux. |
| `Deploy-C3M01AttackPath.cloudshell.sh` | Does the same from Azure Cloud Shell (Bash). It also holds the Bicep templates, so keep it in the same folder as the PowerShell script. |
| `C3M01VulnerabilityEvidence.ps1` | Reports which lab VMs Defender for Cloud has flagged with vulnerability findings. Read-only. |
| `C3M01-ExposureGraphCheck.kql` | Advanced hunting queries that show the lab's nodes and links in the exposure graph. Read-only. |

Every script carries full help. In PowerShell, run `Get-Help .\Deploy-C3M01AttackPath.ps1 -Full`; for the Bash script, read the comment block at the top.

## Before you start

- An Azure subscription where you're **Owner**, or **Contributor** plus **User Access Administrator**. The deployment writes a role assignment, and Contributor alone can't do that.
- **Microsoft Defender for Cloud** on that subscription, with agentless scanning and attack path generation available. Check Microsoft Learn for the plan that provides them, and what it costs, before you turn anything on.
- Access to **Advanced hunting** in the Microsoft Defender portal for the KQL queries.
- The **Azure CLI**, signed in with `az login` (Cloud Shell is already signed in). It has to deploy Bicep files directly, which means 2.20.0 or later. I'd just run the current release.
- **PowerShell 7** for the `.ps1` files, and `ssh-keygen`. Azure won't create a Linux VM without an SSH public key, even though this lab keeps port 22 closed.
- 2 free vCPUs of regional quota in West US 2, or in whichever region you pick. Deallocated VMs still count against quota.

## Step 1: create the order storage account (once)

The lab grants read access to an existing storage account that plays the critical asset. In the course it's `stglobomanticsorders`, but storage account names are globally unique, so you'll need your own: 3 to 24 lowercase letters and digits, such as `stglobomanticsorders123`. If you already built one in an earlier Globomantics lab and it holds only fictional data, use it and skip this step.

These commands work the same in PowerShell and in Bash:

```
az group create --name rg-globomantics --location westus2 --tags course=SC100-C3M01
az storage account create --name stglobomanticsorders123 --resource-group rg-globomantics --location westus2 --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 --allow-blob-public-access false --tags course=SC100-C3M01
```

Swap your own name in for `stglobomanticsorders123` here and in every command below.

## Step 2: preview, then deploy

I run the what-if preview first every single time. It creates nothing, and it shows you exactly what's about to land in your subscription.

**PowerShell 7**, from this folder:

```powershell
.\Deploy-C3M01AttackPath.ps1 -TargetStorageAccount stglobomanticsorders123
.\Deploy-C3M01AttackPath.ps1 -Mode Deploy -TargetStorageAccount stglobomanticsorders123 -FictionalDataConfirmed
```

The `-FictionalDataConfirmed` switch is your promise that the account holds nothing real. The script won't deploy without it, because two internet-facing VMs end up with read access to every blob in that account.

**Azure Cloud Shell (Bash).** Upload `Deploy-C3M01AttackPath.cloudshell.sh` to your Cloud Shell home folder, plus `C3M01VulnerabilityEvidence.ps1` if you want to run it there too, then:

```bash
MODE=whatif TARGET_ST=stglobomanticsorders123 bash Deploy-C3M01AttackPath.cloudshell.sh
MODE=deploy TARGET_ST=stglobomanticsorders123 bash Deploy-C3M01AttackPath.cloudshell.sh
```

Both paths deploy to West US 2 by default. To use another region, add `-Location <region>` in PowerShell or `LOCATION=<region>` in Bash. Both scripts are safe to rerun; a second deploy re-asserts the same resources rather than adding new ones.

## Step 3: mark the storage account as a critical asset

In the Microsoft Defender portal, open **Settings > Microsoft Defender XDR > Rules > Critical asset management** and confirm that a rule classifies your storage account as a critical asset. If one already does, don't add a duplicate. If none does, Microsoft Learn's critical asset management page walks you through adding one.

## Step 4: wait, then check

The deploy takes minutes, and the wait is the real lab. Agentless scanning and attack path generation run on Defender for Cloud's own cycle, so give it at least 24 hours, better 48. Then:

1. Run `.\C3M01VulnerabilityEvidence.ps1` (or `pwsh ./C3M01VulnerabilityEvidence.ps1` in Cloud Shell) to see whether the VMs carry vulnerability findings. The first run may prompt you to install the Resource Graph extension; `az extension add --name resource-graph` does it.
2. Open `C3M01-ExposureGraphCheck.kql`, change `targetStorage` to your account name, and paste each query into **Advanced hunting**.
3. In the Defender portal, go to **Exposure management > Attack surface > Attack paths**, and look at **Choke points** too.

An empty attack path list can mean Defender hasn't finished or that a filter is hiding the path, so don't read it as a broken lab on day one. The KQL file explains how to read each result.

## What it costs you

**This lab creates billable resources:** two Standard_B1s VMs that bill while they run, their managed disks, two Standard public IP addresses, and whatever your Defender for Cloud plans charge. There's no auto-shutdown schedule on these VMs, so they bill around the clock until you tear them down, and deallocating them doesn't take you to zero. Check the Azure pricing calculator for your region before you deploy.

## Clean up

Tear the lab down the moment you're done with it. The teardown removes the role assignment before it deletes the resource group, because deleting the identity first leaves an orphaned "Identity not found" grant on your storage account.

**PowerShell 7:**

```powershell
.\Deploy-C3M01AttackPath.ps1 -Mode Teardown -TargetStorageAccount stglobomanticsorders123
```

**Azure Cloud Shell (Bash):**

```bash
MODE=teardown TARGET_ST=stglobomanticsorders123 bash Deploy-C3M01AttackPath.cloudshell.sh
```

If you'd rather do it by hand, run these in order (PowerShell syntax):

```powershell
$principalId = az identity show --resource-group rg-globomantics-c3m01 --name id-globomantics-c3m01-orders --query principalId -o tsv
$storageId = az storage account show --resource-group rg-globomantics --name stglobomanticsorders123 --query id -o tsv
az role assignment delete --assignee-object-id $principalId --role "Storage Blob Data Reader" --scope $storageId
az group delete --name rg-globomantics-c3m01 --yes --no-wait
```

If you created `rg-globomantics` only for this lab, delete it too:

```
az group delete --name rg-globomantics --yes --no-wait
```

Any Defender for Cloud plan you turned on for this lab stays on, and keeps billing, until you turn it off.

## About Globomantics

Globomantics is a fictional company, and every scenario detail in the course is invented for teaching. The lab's resources carry the tag `course=SC100-C3M01`, so you can always tell what it created.
