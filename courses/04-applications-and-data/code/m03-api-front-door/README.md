# Module 3 lab: read the API front door

This lab builds the Globomantics Connected Equipment API's front door, the design behind the demo
"Read the API front door", in your own Azure subscription. Deploy it, read each layer back, then send
three requests and watch which layer stops which one.

Globomantics is a fictional company. Every name in this lab is invented for teaching.

## What's in the folder

| File | What it does |
|---|---|
| `Deploy-C4M03ApiFrontDoor.ps1` | Plans, deploys, reads, tests, or removes the lab |
| `iac\main.bicep` | The template. Every resource is commented with the decision it supports |
| `iac\cancel-order-policy.xml` | The gateway policy on the Cancel order operation |

## What the lab builds

Everything lands in one resource group, `rg-globomantics-c4m03`, tagged `course=SC100-C4M03`:

- **The edge.** Azure Front Door Premium with a web application firewall policy in Prevention mode,
  the Default Rule Set, the Bot Manager rule set, one rate-limit rule, and no exclusions.
- **The gateway.** Azure API Management (Developer tier) with the Connected Equipment API's Cancel
  order operation. Its inbound policy checks the `X-Azure-FDID` header so only your Front Door gets
  through, validates the partner's Microsoft Entra token, and limits each token subject to 60 calls a
  minute. A mock answers, so there's no backend to pay for.
- **The pipeline.** A user-assigned managed identity with one federated credential that trusts
  GitHub Actions for one repository and one environment, and no role assignments.
- **The evidence.** A Log Analytics workspace that receives the firewall log, because Front Door
  doesn't collect it by default.

## Before you start

- **PowerShell 7** (`pwsh`) and the **Azure CLI**, signed in with `az login`. If you don't have the
  Bicep CLI yet, run `az bicep install`.
- **Contributor** on a subscription you use for learning. The template creates no role assignments.
- **An email address you own.** API Management requires a publisher contact address.

## Run it

Open PowerShell 7 in this folder and run these in order. Replace `<your-email-address>` with your
own address.

```powershell
az login
az account set --subscription "<your-subscription-name-or-id>"

# Preview the deployment. Changes nothing.
pwsh -NoProfile -File .\Deploy-C4M03ApiFrontDoor.ps1 -Mode Plan -PublisherEmail '<your-email-address>'

# Deploy the lab. API Management takes 30 to 45 minutes the first time. Safe to rerun.
pwsh -NoProfile -File .\Deploy-C4M03ApiFrontDoor.ps1 -Mode Deploy -PublisherEmail '<your-email-address>'

# Read each layer back.
pwsh -NoProfile -File .\Deploy-C4M03ApiFrontDoor.ps1 -Mode Show

# Send the three requests and look for the firewall log entry.
pwsh -NoProfile -File .\Deploy-C4M03ApiFrontDoor.ps1 -Mode Test
```

On a first run, Plan only compiles the template, because what-if needs the resource group to exist.
That's expected. A new Front Door endpoint can take 20 minutes or more to answer, so Test waits and
retries while it propagates.

Working in more than one subscription? Add `-SubscriptionId <your-subscription-id>` to any mode, and
`-TenantId <your-tenant-id>` to refuse writes outside the tenant you name.

## What to look for

**Show** prints the three layers:

- **The edge.** The mode should read Prevention, the Default Rule Set and Bot Manager should each show
  zero exclusions, and the newest Default Rule Set Microsoft offers prints beside yours, so you can
  see when an upgrade is due.
- **The gateway.** Read the inbound policy top to bottom. `check-header` runs first and refuses
  anything that skipped Front Door, `validate-jwt` checks the token's issuer, audience, expiry and the
  `Orders.Cancel` role, and `rate-limit-by-key` counts calls per token subject. The tenant named value
  is secret, so the portal shows it masked.
- **The pipeline.** The federated credential's subject names one repository and one environment.
  Ask yourself why it names the production environment instead of the whole repository.

**Test** sends three requests, and each status code means one thing:

| Request | Expected | What it proves |
|---|---|---|
| ordinary, through Front Door, no token | 401 | The firewall let it through, the Front Door check passed, and `validate-jwt` asked for a token |
| injection, through Front Door, with a SQL injection string | 403 | The firewall blocked it at the edge. If the firewall had missed it, the gateway would answer 401 |
| direct, straight to the gateway | 403 | `check-header` refused a request that skipped Front Door |

Then Test looks for the injection request in the firewall log, matched by its `x-azure-ref` value,
which proves the block was recorded as well as enforced. To query it yourself, open the
`law-glb-c4m03` workspace and run:

```kusto
AzureDiagnostics
| where Category == 'FrontDoorWebApplicationFirewallLog'
| where action_s == 'Block'
```

If the ordinary request ever gets a 403 from the firewall, legitimate traffic is being blocked. Switch
the policy to Detection, find the rule in the log, and add the narrowest exclusion you can justify.

## Known issue

**A real Microsoft Entra token can't pass the gateway policy as shipped.** The `validate-jwt` policy
requires the v2.0 issuer, but the `glb-api-audience` named value holds the App ID URI
`api://glb-connected-equipment-api`, and a v2.0 token's audience is always the API's client ID, as the
[access token claims reference](https://learn.microsoft.com/en-us/entra/identity-platform/access-token-claims-reference#payload-claims)
explains. A v1.0 token can't pass either, because its issuer doesn't end in /v2.0. The three Test
requests aren't affected, because none of them sends a token. To fix it without changing the policy,
set the API's app registration to issue v2.0 access tokens, which
[the token formats section](https://learn.microsoft.com/en-us/entra/identity-platform/access-tokens#token-formats)
covers, then put that app's client ID in the
[named value](https://learn.microsoft.com/en-us/azure/api-management/api-management-howto-properties).
Orders.Cancel is an app role, so it arrives in the token's `roles` claim, not `scp`, and `roles` is the
claim the policy already checks. A rerun of Deploy puts the App ID URI back, so set the named value
again after one.

```powershell
az ad app update --id <api-app-client-id> --requested-access-token-version 2
az apim nv update --resource-group rg-globomantics-c4m03 --service-name <apim-name> --named-value-id glb-api-audience --value <api-app-client-id>
```

## What it costs

**This lab bills by the hour from the moment it deploys, whether or not you use it.** Front Door
Premium carries a base fee, and API Management Developer bills by the hour too. In East US 2 at
October 2026 retail prices, the pair came to about 0.52 USD an hour. The workspace adds almost
nothing, because a lab writes kilobytes of log. Check the Azure pricing pages for your region, and
remove the lab the same day you build it.

## Clean up

Run the Remove mode. It deletes the resource group, waits for the delete to finish, and then purges
the soft-deleted API Management instance so its name is free next time:

```powershell
pwsh -NoProfile -File .\Deploy-C4M03ApiFrontDoor.ps1 -Mode Remove
```

If you'd rather do it by hand, delete the group, wait for the delete to finish, then purge API
Management. Its name starts with `apim-glb-c4m03-`:

```powershell
az group delete --name rg-globomantics-c4m03 --yes

# Once the group is gone:
az apim deletedservice list -o table
az apim deletedservice purge --service-name <apim-name> --location <region>
```

Check Cost Management the next day to confirm the charges stopped.
