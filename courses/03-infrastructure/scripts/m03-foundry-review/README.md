# Module 3 lab: evaluate a Foundry project against the AI controls

This lab builds the Globomantics Foundry project I review in the demo "Evaluate a Foundry project against the AI controls", in your own Azure subscription, along with the read-only script that prints the review. Deploy it, run the review, and find the permission that shouldn't be there.

Globomantics is a fictional company. Every name in this lab is invented for teaching.

## What's in the folder

| File | What it does |
|---|---|
| `Deploy-C3M03FoundryReview.ps1` | Plans, deploys, or removes the lab. |
| `Show-C3M03FoundryReview.ps1` | Reads the lab and prints the review. Changes nothing. |
| `iac\main.bicep` | The template. Every resource is commented with the decision it supports. |

## What the lab builds

Everything lands in one resource group, `rg-globomantics-c3m03`, tagged `course=SC100-C3M03`:

- **A Foundry resource** with local keys disabled, so Microsoft Entra ID is the only way in, and public network access left on, so you can weigh "who may call" against "from where".
- **A project**, `glb-customer-experience`, that both workloads share.
- **A gpt-5-mini model deployment**, `glb-assistant`, with a custom content filter that blocks the harm categories at Medium and turns on Prompt Shields for jailbreak and indirect attacks.
- **A storage account** with two containers, `customer-records` and `draft-orders`.
- **Two user-assigned workload identities**, the customer assistant and the ERP draft-order agent. Both hold the Foundry User role on the project.

## The gap you're looking for

The customer assistant can write draft orders, and it shouldn't. I planted that on purpose. Its identity holds **Storage Blob Data Contributor** on the whole storage account, while the ERP draft-order agent, which actually owns draft orders, is scoped to the `draft-orders` container only. The content filter can't help here, because Prompt Shields governs what the assistant says, not what it may read or write.

Don't fix it in the template. Find it in the review first.

## Before you start

- **PowerShell 7** (`pwsh`) and the **Azure CLI**, signed in with `az login`. If you don't have the Bicep CLI yet, run `az bicep install`.
- **Owner** on the subscription, or **Contributor** plus **User Access Administrator**. The template creates role assignments, and Contributor alone can't do that.
- **At least 10 units of gpt-5-mini GlobalStandard quota** in your region. The deploy script checks before it builds anything. It defaults to `eastus2`; add `-Location <region>` to use another one. Model availability varies by region and changes over time, so if the check fails, look up current availability on Microsoft Learn.

## Run it

Open PowerShell 7 in this folder and run these in order:

```powershell
az login
az account set --subscription "<your subscription name or ID>"

# Preview the deployment. Changes nothing.
pwsh -NoProfile -File .\Deploy-C3M03FoundryReview.ps1 -Mode Plan

# Deploy the lab. It's safe to rerun: it converges instead of duplicating.
pwsh -NoProfile -File .\Deploy-C3M03FoundryReview.ps1 -Mode Deploy

# Run the review.
pwsh -NoProfile -File .\Show-C3M03FoundryReview.ps1
```

On a first run, Plan only compiles the template, because what-if needs the resource group to exist. That's expected.

Working in more than one subscription? Add `-SubscriptionId <id>` to either script. Add `-TenantId <id>` to the deploy script too, and it'll refuse to write anywhere outside the tenant you name.

## Reading the review

Go straight to **WORKLOAD PERMISSIONS**, because that's where the finding is. Look at which scope each identity's Storage Blob Data Contributor assignment covers, and ask yourself whether the customer assistant needs to write anything at all.

The other sections matter too. **RESOURCE** tells you who may call the Foundry resource and from where, and those are separate decisions. **MODEL DEPLOYMENT** tells you what the content filter blocks.

## Try the fix

The fix I recommend is **Storage Blob Data Reader** on `customer-records` for the assistant, with the account-wide Contributor assignment removed. Apply it, then rerun the review:

```powershell
$rg = 'rg-globomantics-c3m03'
$assistant = az identity show -g $rg -n id-glb-customer-assistant --query principalId -o tsv
$storage = az storage account list -g $rg --query "[0].id" -o tsv

az role assignment create --assignee-object-id $assistant --assignee-principal-type ServicePrincipal --role "Storage Blob Data Reader" --scope "$storage/blobServices/default/containers/customer-records"
az role assignment delete --assignee $assistant --role "Storage Blob Data Contributor" --scope $storage

pwsh -NoProfile -File .\Show-C3M03FoundryReview.ps1
```

Want the gap back so you can start over? Run the Deploy mode again. The template recreates the account-wide assignment.

## What it costs

This lab creates billable Azure resources, so remove it when you're done. There's no standing compute: the Foundry resource and the model deployment bill per token, and the review doesn't send any. The storage account holds no data. Check the Azure pricing pages for your region if you plan to leave it running.

## Clean up

Run the Remove mode. It deletes the resource group, waits for the delete to finish, and then purges the soft-deleted Foundry resource so its name is free next time:

```powershell
pwsh -NoProfile -File .\Deploy-C3M03FoundryReview.ps1 -Mode Remove
```

If you'd rather do it by hand, delete the group, wait for the delete to finish, then purge the Foundry resource. Its name starts with `glb-c3m03-foundry-`:

```powershell
az group delete --name rg-globomantics-c3m03 --yes --no-wait

# Once the group is gone:
az cognitiveservices account list-deleted -o table
az cognitiveservices account purge --resource-group rg-globomantics-c3m03 --name <foundry-name> --location <region>
```
