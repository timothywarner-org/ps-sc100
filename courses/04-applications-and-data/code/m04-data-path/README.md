# Module 4 lab: audit the customer assistant's data path

This lab builds the storage account behind the Globomantics customer assistant, the account the demo
"Audit the customer assistant's data path" reads, in your own Azure subscription. It turns on
Microsoft Defender for Storage for that one account, then reads back the same settings the demo
reads, so you can make a keep-or-change call on each one.

Globomantics is a fictional company. Every name in this lab is invented for teaching.

## What's in the folder

| File | What it does |
|---|---|
| `Deploy-C4M04DataPath.ps1` | Plans, deploys, reads, or removes the lab |
| `iac\main.bicep` | The storage account, with every setting commented as a keep or a change |

## What the lab builds

Everything lands in one resource group, `rg-globomantics-c4m04`, tagged `course=SC100-C4M04`:

- **One StorageV2 account** named `stglbc4m04` plus a suffix, with a `customer-records` container and
  no data. It refuses Shared Key authorization, requires TLS 1.2, blocks anonymous blob reads, still
  accepts traffic from the public internet, and has no infrastructure encryption.
- **Microsoft Defender for Storage on that account only**, with malware scanning on upload capped at
  10 GB a month and sensitive data threat detection on. It's turned on at the account level, so no
  other storage account in your subscription starts billing.

This is the same account design the Course 3 Module 3 lab built for the assistant, in its own
resource group, so it never touches a Course 3 lab you might still have.

## Before you start

- **PowerShell 7** (`pwsh`) and the **Azure CLI**, signed in with `az login`. If you don't have the
  Bicep CLI yet, run `az bicep install`.
- **Contributor** on a subscription you use for learning, plus permission to change Microsoft
  Defender for Cloud settings, such as Security Admin or Owner.

## Run it

Open PowerShell 7 in this folder and run these in order:

```powershell
az login
az account set --subscription "<your-subscription-name-or-id>"

# Preview the deployment. Changes nothing.
pwsh -NoProfile -File .\Deploy-C4M04DataPath.ps1 -Mode Plan

# Deploy the account and turn on Defender for Storage for it alone. Safe to rerun.
pwsh -NoProfile -File .\Deploy-C4M04DataPath.ps1 -Mode Deploy

# Read the account and its Defender settings.
pwsh -NoProfile -File .\Deploy-C4M04DataPath.ps1 -Mode Show
```

On a first run, Plan only compiles the template, because what-if needs the resource group to exist.
That's expected. Defender for Storage can take up to 24 hours to start protecting a new account, but
its settings read back right away.

Working in more than one subscription? Add `-SubscriptionId <your-subscription-id>` to any mode, and
`-TenantId <your-tenant-id>` to refuse writes outside the tenant you name.

Prefer Azure Cloud Shell's Bash? These are the same two reads Show runs. Neither one prints a key.

```bash
RG=rg-globomantics-c4m04
SA=$(az storage account list -g $RG --query "[0].name" -o tsv)
ACCT_ID=$(az storage account show -n $SA -g $RG --query id -o tsv)

az storage account show -n $SA -g $RG --query "{sharedKey:allowSharedKeyAccess, minTls:minimumTlsVersion, publicBlob:allowBlobPublicAccess, publicNetwork:publicNetworkAccess, infraEncryption:encryption.requireInfrastructureEncryption}" -o yaml

az rest --method get --url "https://management.azure.com${ACCT_ID}/providers/Microsoft.Security/defenderForStorageSettings/current?api-version=2025-07-01-preview" --query "properties.{enabled:isEnabled, malwareScanning:malwareScanning.onUpload.isEnabled, sensitiveData:sensitiveDataDiscovery.isEnabled}" -o yaml
```

## Read the values

Make your own keep-or-change call on each value before you read the answers below.

| Value | What it reads | The call the course makes |
|---|---|---|
| `sharedKey` | false | Keep. The account refuses its own keys, account SAS and service SAS, so only Microsoft Entra ID or a user delegation SAS gets in. A stem that wants Conditional Access on storage is asking for exactly this |
| `minTls` | TLS1_2 | Keep |
| `publicBlob` | false | Keep. It governs anonymous reads only, so it doesn't take the account off the internet |
| `publicNetwork` | Enabled | Change. The account still listens on the internet. Add a private endpoint before the assistant reaches more customers |
| `infraEncryption` | not set | Leave it, unless a regulator names it. You can only turn it on when you create an account, and every authorized caller reads straight through it |
| Defender `enabled` | true | Keep. Activity monitoring watches the identities you allowed, with malware scanning and sensitive data threat detection beside it |

So the path is keyless and monitored, with one network fix to make.

## What it costs

The empty storage account costs pennies. Defender for Storage bills per protected account per month,
prorated by the hour, and malware scanning bills per GB scanned, which an empty account never
triggers. Check the Microsoft Defender for Cloud pricing page for your region, and remove the lab when
you finish. If Show warns that Defender for Storage is on at the subscription level, every storage
account in that subscription was already billed before this lab.

## Clean up

Run the Remove mode. It turns Defender for Storage off for the account, then deletes the resource
group:

```powershell
pwsh -NoProfile -File .\Deploy-C4M04DataPath.ps1 -Mode Remove
```

Or by hand. Deleting the account ends its Defender for Storage billing with it:

```powershell
az group delete --name rg-globomantics-c4m04 --yes
```

Check Cost Management the next day to confirm the charges stopped.
