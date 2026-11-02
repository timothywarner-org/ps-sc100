# Module 2 lab: server coverage and plan fit

This folder builds the Globomantics server estate I use in the Module 2 demo, **Read server coverage and plan fit in Defender for Cloud**, and gives you the same plan table you see on screen. You deploy it in your own subscription, read the plans, and tear it down when you're finished.

## What it builds

You get four servers that differ in exactly the two ways the module teaches: how each one connects, and which **Microsoft Defender for Servers** plan it carries.

| Server | Connects as | Plan | Data class | Environment |
|---|---|---|---|---|
| `vm-glb-erp01` | Azure VM, Windows Server 2025 | Plan 2, inherited from the subscription | financial | production |
| `vm-glb-web01` | Azure VM, Ubuntu | Plan 1, set on the VM | customer-orders | production |
| `vm-glb-test01` | Azure VM, Ubuntu | Plan 1, set on the VM | synthetic | test |
| `glb-dc-file01` | Azure Arc machine | Plan 2, inherited from the subscription | internal-files | production |

They all live in `rg-globomantics-c3m02`. A fifth VM, `vm-glb-arc-host01`, sits in `rg-globomantics-c3m02-host` and plays the datacenter file server. It connects itself to **Azure Arc** as `glb-dc-file01` using Microsoft's evaluation-only procedure, "Evaluate Azure Arc-enabled servers on an Azure virtual machine", so don't copy that pattern for real servers.

**Data class** and **Environment** are tags I wrote into the templates to describe the Globomantics workloads. They're business context, not something Defender discovered.

| File | What it does |
|---|---|
| `Deploy-C3M02ServerEstate.ps1` | Plans, deploys, or deallocates the lab from PowerShell 7 on your machine |
| `Deploy-C3M02ServerEstate.cloudshell.sh` | Builds the same lab from Azure Cloud Shell (Bash), with every template built in |
| `Show-C3M02ServerPlans.ps1` | Prints the read-only plan table from the demo |
| `iac\main.bicep`, `iac\servers.bicep`, `iac\archost.bicep` | The templates |
| `iac\arc-host-cloud-init.yaml` | How the host VM prepares itself and connects to Azure Arc |
| `iac\Deploy-C3M02ServerEstate.cloudshell.sh.in`, `iac\build_cloudshell.py` | Rebuild the Cloud Shell script after you change a template. You don't need them to run the lab |

## Before you start

- **Owner** on an Azure subscription, or Contributor plus User Access Administrator. Deploy creates a role assignment.
- Permission to create app registrations in **Microsoft Entra ID**.
- **Defender for Servers Plan 2** turned on at subscription scope. Two servers inherit it and two override it with Plan 1, and that difference is the demo. The scripts check for it and won't flip a subscription-wide plan for you. Plan 2 at subscription scope covers every server in that subscription, so I'd use a subscription that doesn't hold anything else. To turn it on:

  ```
  az security pricing create --name VirtualMachines --tier standard --subplan P2
  ```

- At least 5 free B-series vCPUs in the region you pick. The default is West US 2, and the scripts check quota before they deploy.
- For the PowerShell path: PowerShell 7.4 or later, `ssh-keygen` (the OpenSSH client), and the Azure CLI. I built and checked this with Azure CLI 2.85, so run `az upgrade` if yours is older.
- For the plan table: the Azure CLI resource-graph extension.

  ```
  az extension add --name resource-graph
  ```

## Run it from PowerShell

Sign in, confirm you're in the subscription you mean, then plan before you build.

```powershell
az login
az account show --query "{name:name, id:id}" -o table
pwsh -NoProfile -File .\Deploy-C3M02ServerEstate.ps1
pwsh -NoProfile -File .\Deploy-C3M02ServerEstate.ps1 -Mode Deploy
```

The first run is a what-if, so it creates nothing. Deploy takes 10 to 15 minutes, then waits up to ten more for `glb-dc-file01` to connect to Azure Arc. Add `-Location eastus2` to build in another region, and `-ShutdownTimeZone 'Pacific Standard Time'` to move the nightly 11 PM shutdown into your own time zone.

If Windows won't run a script you downloaded, unblock the folder once from inside it:

```powershell
Get-ChildItem -Recurse | Unblock-File
```

## Run it from Azure Cloud Shell

Open Cloud Shell in Bash, choose **Manage files** > **Upload**, and upload `Deploy-C3M02ServerEstate.cloudshell.sh`. Then run:

```bash
bash Deploy-C3M02ServerEstate.cloudshell.sh
MODE=deploy bash Deploy-C3M02ServerEstate.cloudshell.sh
```

Run it as a file, and don't paste its lines into the shell. It uses `set -e` and `exit`, which would close your session. To change the defaults, set `LOCATION`, `SHUTDOWN_TZ` or `SUBSCRIPTION_ID` in front of the command:

```bash
MODE=deploy LOCATION=eastus2 SHUTDOWN_TZ='Eastern Standard Time' bash Deploy-C3M02ServerEstate.cloudshell.sh
```

## Read the plans

```powershell
pwsh -NoProfile -File .\Show-C3M02ServerPlans.ps1
```

You get one row per server with the same columns as the demo: **Server**, **Connects as**, **Plan**, **Plan set**, **Data class** and **Environment**. It's read-only and uses your current Azure CLI subscription; add `-SubscriptionId` to read another one. If `glb-dc-file01` is missing, the script warns you and prints the rest. That usually means the host is still booting, so wait five minutes and run it again.

Cloud Shell has PowerShell too. Upload `Show-C3M02ServerPlans.ps1` and run `pwsh -NoProfile -File ./Show-C3M02ServerPlans.ps1` there.

The table reads Defender for Cloud's pricing API directly, so it works as soon as the servers exist. The portal is slower: Defender for Endpoint onboarding and the Defender for Cloud inventory run on their own cycles, so give those views up to 24 hours.

## What it costs you

This lab creates billable resources: four small Azure VMs while they run, their disks, and Defender for Servers on three Azure VMs and one Arc machine. I don't quote prices because they change, so check Microsoft's Azure and Defender for Cloud pricing pages before you deploy.

Every VM shuts itself down at 11 PM in the time zone you chose. To stop them between sessions:

```powershell
pwsh -NoProfile -File .\Deploy-C3M02ServerEstate.ps1 -Mode Stop
```

Deallocating stops compute charges, not disk charges or the Arc machine's plan. Tear the lab down the day you finish.

## Clean up

The app registration `sp-globomantics-c3m02-arc` is the only thing the lab creates outside its two resource groups, so delete it along with both groups.

From PowerShell:

```powershell
az ad app delete --id (az ad app list --display-name sp-globomantics-c3m02-arc --query "[0].appId" -o tsv)
az group delete --name rg-globomantics-c3m02 --yes --no-wait
az group delete --name rg-globomantics-c3m02-host --yes --no-wait
```

From Cloud Shell, run `MODE=teardown bash Deploy-C3M02ServerEstate.cloudshell.sh`, or do it by hand:

```bash
az ad app delete --id "$(az ad app list --display-name sp-globomantics-c3m02-arc --query '[0].appId' -o tsv)"
az group delete --name rg-globomantics-c3m02 --yes --no-wait
az group delete --name rg-globomantics-c3m02-host --yes --no-wait
```

If you turned on Defender for Servers Plan 2 only for this lab, turn it back off:

```
az security pricing create --name VirtualMachines --tier free
```

Deploy also registers the Microsoft.HybridCompute, Microsoft.GuestConfiguration and Microsoft.HybridConnectivity resource providers if they weren't already. That's a subscription setting rather than a resource, so there's nothing to delete.

## About Globomantics

Globomantics is a fictional company, and every scenario detail in this lab is invented for teaching. Nothing here describes a real organization.
