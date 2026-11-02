# Module 4 lab: scope vendor access with Microsoft Entra Private Access

These scripts rebuild the Globomantics plant and its vendor Private Access setup from the Module 4 demo in **your own** Azure subscription and Microsoft Entra tenant, so you can run the same review I ran and find the same leftover VPN route.

Globomantics is fictional, and so is every name, domain and address in here.

## What you'll build

**In Azure** (`Deploy-C3M04PlantNetwork.ps1`, template in `iac\main.bicep`), all inside the resource group `rg-globomantics-c3m04`:

- The plant network `vnet-glb-plant-a`, with a management subnet and a subnet for each production line.
- `vm-glb-pa-conn01`, a Windows Server VM that hosts the **Microsoft Entra private network connector**. It only dials out, so its NSG, `nsg-glb-plant-mgmt`, has no inbound rules.
- `vm-glb-line-a`, the maintenance app the vendor may reach, and `vm-glb-line-b`, a controller HMI the vendor must never reach. Each serves one HTTPS page.
- `nsg-glb-line-a` and `nsg-glb-line-b`, which still admit the legacy vendor VPN pool `172.16.50.0/24`. That's the finding.
- A private DNS zone, `globomantics.example`, and a nightly 23:00 Central shutdown for every VM.

**In Microsoft Entra** (`Set-C3M04PrivateAccess.ps1`):

- Connector group `cg-glb-c3m04-plant-a`, with the lab's connector registered into it.
- Enterprise app `Globomantics line A maintenance (C3M04)`: Private Access, one segment (`maintenance-line-a.globomantics.example`, TCP 443), assignment required.
- A **disabled** vendor account, `glb-c3m04-vendor@<your default domain>`, assigned to that app.
- Conditional Access policy `GLB C3M04: vendor line A maintenance requires MFA`, enabled and scoped to that one account and that one app.

## Before you start

**Licensing.** Microsoft Entra Private Access needs licensing in your tenant, and I can't see what yours has from here. Check the licensing section of [What is Global Secure Access?](https://learn.microsoft.com/entra/global-secure-access/overview-what-is-global-secure-access#licensing-overview) on Microsoft Learn before you build anything.

**Roles.**

- Azure: **Contributor** (or Owner) on the subscription.
- Microsoft Entra: **Application Administrator**, **User Administrator**, **Conditional Access Administrator** and **Global Secure Access Administrator**. **Global Administrator** covers all of them. If this is the first private network connector your tenant has ever registered, Microsoft's [connector tutorial](https://learn.microsoft.com/entra/global-secure-access/tutorial-private-access-connector-setup) says that first registration needs Global Administrator.
- For the registration sign-in, use a member account in your tenant's own domain, not a personal Microsoft account.

**Tools.**

- PowerShell 7.4 or later
- Azure CLI with Bicep: `az bicep install`
- Microsoft Graph PowerShell: `Install-Module Microsoft.Graph.Authentication -MinimumVersion 2.28.0 -Scope CurrentUser`
- OpenSSH `ssh-keygen`, which already ships with Windows 10 and later, macOS and Linux
- Python 3 with MSAL, for the registration step only: `python -m pip install msal`

**Turn on Private Access forwarding.** In the Microsoft Entra admin center, go to **Global Secure Access > Connect > Traffic forwarding** and enable the Private Access profile. Configure checks it and stops if it's off. It's a tenant-wide switch, so I won't flip it for you.

## Run it

Open PowerShell 7 in this folder, then run these in order. On macOS or Linux, use `./` where you see `.\`.

```powershell
az login
az account set --subscription <your-subscription-id>

pwsh -NoProfile -File .\Deploy-C3M04PlantNetwork.ps1 -Mode Plan
pwsh -NoProfile -File .\Deploy-C3M04PlantNetwork.ps1 -Mode Deploy
pwsh -NoProfile -File .\Set-C3M04PrivateAccess.ps1 -Mode Configure
pwsh -NoProfile -File .\Set-C3M04PrivateAccess.ps1 -Mode Register -AdminUserPrincipalName admin@contoso.onmicrosoft.com
pwsh -NoProfile -File .\Set-C3M04PrivateAccess.ps1 -Mode Status
```

- **Plan** compiles the template and checks your vCPU quota. It changes nothing.
- **Deploy** builds the Azure half and installs the connector software without registering it. It uses `westus2` unless you add `-Location <region>`, and it takes a while.
- **Configure** signs you in to Microsoft Graph and creates the Entra objects. It's safe to rerun.
- **Register** prints a device sign-in code. Sign in as the account you passed to `-AdminUserPrincipalName`, or registration stops. The token goes straight to the connector host and never shows on screen.
- **Status** confirms every object exists and the connector is active.

Every script carries full help, so `Get-Help .\Set-C3M04PrivateAccess.ps1 -Full` tells you what it changes before you run it.

## Run the review

```powershell
pwsh -NoProfile -File .\Show-C3M04PrivateAccess.ps1
```

It's read-only. **WHO MAY CONNECT** and **WHERE THE CONNECTION LANDS** show the Private Access side: one assigned vendor, MFA required, one host on one port. **WHAT ELSE REACHES THE PLANT** is why the review exists: the legacy vendor VPN pool still reaches both lines, including SSH to line B, and that's the route that still needs removal.

If the connector reads inactive, the nightly shutdown has probably stopped its VM. The script warns you and gives you the `az vm start` command.

## What it costs you

The Azure half bills you for three VMs and their disks until you delete it. The template's own estimate is about USD 3 a day while the VMs run, so check the [Azure pricing calculator](https://azure.microsoft.com/pricing/calculator/) for your region. The nightly shutdown stops the VMs, not the disk charges.

## Clean up

Delete the Azure half:

```powershell
az group delete --name rg-globomantics-c3m04 --yes --no-wait
```

Delete the Entra half:

```powershell
pwsh -NoProfile -File .\Set-C3M04PrivateAccess.ps1 -Mode Remove
```

That removes the Conditional Access policy, the enterprise app (its service principal, segment and vendor assignment go with it), the vendor account, the connector record and the connector group. Microsoft Entra keeps deleted apps and users under Deleted items for 30 days. If you turned on Private Access forwarding just for this lab, turn it off again under **Global Secure Access > Connect > Traffic forwarding**.

If you'd rather remove the Entra objects by hand, these are the same calls `-Mode Remove` makes:

```powershell
Connect-MgGraph -Scopes Application.ReadWrite.All, Directory.ReadWrite.All, Policy.Read.All, Policy.ReadWrite.ConditionalAccess, User.ReadWrite.All
$v1 = 'https://graph.microsoft.com/v1.0'
$beta = 'https://graph.microsoft.com/beta'

# Conditional Access policy
$policy = (Invoke-MgGraphRequest -Method GET -Uri "$v1/identity/conditionalAccess/policies").value | Where-Object displayName -eq 'GLB C3M04: vendor line A maintenance requires MFA'
Invoke-MgGraphRequest -Method DELETE -Uri "$v1/identity/conditionalAccess/policies/$($policy.id)"

# Enterprise app: deleting the app registration also deletes its service principal, segment and assignment
$app = (Invoke-MgGraphRequest -Method GET -Uri "$v1/applications?`$filter=displayName eq 'Globomantics line A maintenance (C3M04)'").value | Select-Object -First 1
Invoke-MgGraphRequest -Method DELETE -Uri "$v1/applications/$($app.id)"

# Vendor account
$users = "$v1/users"
$domain = ((Invoke-MgGraphRequest -Method GET -Uri "$v1/organization").value[0].verifiedDomains | Where-Object isDefault).name
Invoke-MgGraphRequest -Method DELETE -Uri "$users/glb-c3m04-vendor@$domain"

# Connector first, then the connector group, which can't be deleted while it has members
$cg = (Invoke-MgGraphRequest -Method GET -Uri "$beta/onPremisesPublishingProfiles/applicationProxy/connectorGroups").value | Where-Object name -eq 'cg-glb-c3m04-plant-a'
(Invoke-MgGraphRequest -Method GET -Uri "$beta/onPremisesPublishingProfiles/applicationProxy/connectorGroups/$($cg.id)/members").value | ForEach-Object { Invoke-MgGraphRequest -Method DELETE -Uri "$beta/onPremisesPublishingProfiles/applicationProxy/connectors/$($_.id)" }
Invoke-MgGraphRequest -Method DELETE -Uri "$beta/onPremisesPublishingProfiles/applicationProxy/connectorGroups/$($cg.id)"
```

## What's in this folder

| File | What it does |
|---|---|
| `Deploy-C3M04PlantNetwork.ps1` | Plans, builds or removes the Azure half |
| `iac\main.bicep` | The Azure template, with every resource explained |
| `Set-C3M04PrivateAccess.ps1` | Configures, registers, reports on or removes the Entra half |
| `Get-C3M04RegistrationToken.py` | The device sign-in helper that Register runs for you |
| `Show-C3M04PrivateAccess.ps1` | The read-only review from the demo |
| `C3M04Common.ps1` | Shared names and readers the review uses |
