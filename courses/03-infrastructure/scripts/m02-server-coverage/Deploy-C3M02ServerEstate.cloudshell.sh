#!/usr/bin/env bash
# =============================================================================
# Deploy-C3M02ServerEstate.cloudshell.sh: run as a FILE in Azure Cloud Shell (Bash).
#
# GENERATED FILE. The source is the iac folder next to this script
# (main.bicep, servers.bicep, archost.bicep, arc-host-cloud-init.yaml). The
# templates are embedded below so ONE upload carries everything. You don't
# need to rebuild it. If you change a template, rebuild from the folder that
# holds this script with:  python iac/build_cloudshell.py
#
# Builds the lab for the SC-100 Course 3 Module 2 demo, "Read server coverage
# and plan fit in Defender for Cloud": a small Globomantics server estate whose
# machines differ in exactly the two ways the module teaches, plan and
# connection path.
#
#   rg-globomantics-c3m02 (what the demo reads)
#     vm-glb-erp01   Windows Server 2025, Azure VM   Plan 2, inherited
#     vm-glb-web01   Ubuntu, Azure VM, storefront    Plan 1, set on the VM
#     vm-glb-test01  Ubuntu, Azure VM, test          Plan 1, set on the VM
#     glb-dc-file01  Azure Arc-enabled server        Plan 2, inherited
#   rg-globomantics-c3m02-host (plumbing the demo never shows)
#     vm-glb-arc-host01  the Azure VM that plays glb-dc-file01 (evaluation only)
#
# RUN IT AS A FILE, NEVER BY PASTING ITS LINES. It uses 'set -e' and 'exit',
# which close an interactive shell and take the output with them. In Cloud
# Shell: Manage files > Upload this file, then
#   bash Deploy-C3M02ServerEstate.cloudshell.sh                  # what-if only
#   MODE=deploy bash Deploy-C3M02ServerEstate.cloudshell.sh      # build it
#   MODE=teardown bash Deploy-C3M02ServerEstate.cloudshell.sh    # remove it
# It runs unchanged in any bash with the Azure CLI, openssl and GNU date (WSL,
# Git Bash).
#
# OPTIONS, set as environment variables in front of the command:
#   MODE             whatif (the default), deploy, or teardown
#   SUBSCRIPTION_ID  work in this subscription. It becomes the Azure CLI's
#                    default. Unset, the CLI's current subscription is used.
#   LOCATION         Azure region, default westus2. Needs 5 free B-series vCPUs.
#   SHUTDOWN_TZ      Windows time zone ID for the nightly 11 PM VM shutdown,
#                    default 'Central Standard Time'.
#   Example:
#   MODE=deploy LOCATION=eastus2 SHUTDOWN_TZ='Eastern Standard Time' bash Deploy-C3M02ServerEstate.cloudshell.sh
#
# MODES. The default does nothing but show the plan:
#   (unset)          what-if only. Creates NOTHING. Run it first, always.
#   MODE=deploy      creates the lab, or re-asserts it if it already exists.
#   MODE=teardown    removes the onboarding app registration, then both groups.
#
# PREREQUISITES
#   * The Azure CLI, signed in (Cloud Shell already is). Built and checked with
#     Azure CLI 2.85; run az upgrade if yours is older.
#   * Owner on the subscription, or Contributor plus User Access Administrator,
#     because deploy creates a role assignment.
#   * Permission to create app registrations in Microsoft Entra ID.
#   * Microsoft Defender for Servers Plan 2 on at subscription scope. Two lab
#     servers inherit it and two override it with Plan 1, and that difference
#     is the demo. Deploy checks and stops rather than change a subscription-
#     wide plan on your behalf. Plan 2 at subscription scope covers every server
#     in the subscription, not just this lab's. To turn it on:
#       az security pricing create --name VirtualMachines --tier standard --subplan P2
#
# WHAT DEPLOY WRITES OUTSIDE AZURE RESOURCE GROUPS, so nothing surprises you:
#   * One Microsoft Entra app and service principal, sp-globomantics-c3m02-arc,
#     holding ONLY "Azure Connected Machine Onboarding" on rg-globomantics-c3m02,
#     with a secret that expires ONE DAY after it's minted. It's how the host
#     connects itself to Arc (Course 3 Module 1 teaches this exact method).
#     Teardown deletes it. It's safe to delete early once glb-dc-file01 shows
#     Connected: the agent authenticates with its own identity after onboarding.
#   * The Microsoft.HybridCompute, Microsoft.GuestConfiguration and
#     Microsoft.HybridConnectivity resource providers, registered if they
#     aren't already. That's a subscription setting, not a resource.
#
# SECRETS: the Windows admin password and the service principal secret are
# generated here, handed to the deployment as parameters, and never printed or
# written to a file. Linux sign-in is key-only, and the private key is shredded
# straight away: nothing in this module needs a shell on any machine.
#
# TIMING: the deploy takes 10 to 15 minutes, and the host connects itself to
# Arc a few minutes after it boots. Defender for Endpoint onboarding and the
# Defender for Cloud inventory run on their own cycles, so give the portal
# views up to 24 hours. The plan table works as soon as all four servers exist.
# Upload Show-C3M02ServerPlans.ps1 too, then run:
#   pwsh -NoProfile -File ./Show-C3M02ServerPlans.ps1
#
# COST WARNING: this creates billable resources. Four small VMs while they run,
# their disks, and Defender for Servers on three Azure VMs and one Arc machine.
# Deallocating stops compute, not disks or the Arc machine's plan. Check current
# rates on Microsoft's Azure and Defender for Cloud pricing pages, and run
# MODE=teardown as soon as you're done.
#
# CLEANUP BY HAND, if you'd rather not use MODE=teardown:
#   az ad app delete --id "$(az ad app list --display-name sp-globomantics-c3m02-arc --query '[0].appId' -o tsv)"
#   az group delete --name rg-globomantics-c3m02 --yes --no-wait
#   az group delete --name rg-globomantics-c3m02-host --yes --no-wait
# If you turned on Defender for Servers Plan 2 only for this lab, turn it off:
#   az security pricing create --name VirtualMachines --tier free
# =============================================================================
set -euo pipefail
umask 077

MODE="${MODE:-whatif}"
LOC="${LOCATION:-westus2}"
SHUTDOWN_TZ="${SHUTDOWN_TZ:-Central Standard Time}"
RG='rg-globomantics-c3m02'
HOST_RG='rg-globomantics-c3m02-host'
SP_NAME='sp-globomantics-c3m02-arc'
ONBOARD_ROLE='b64e21ea-ac4e-4cdf-9dc9-5b892992bee7'   # Azure Connected Machine Onboarding: built-in role, same ID in every tenant
VCPUS_NEEDED=5                                         # B2s (2) + three B1ms (1 each)
# A private scratch folder outside your home directory: nothing here needs to outlive the run.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/c3m02.XXXXXX")"
trap 'find "$WORK" -type f -exec shred -u {} + 2>/dev/null; rm -rf "$WORK"' EXIT

case "$MODE" in
  whatif|deploy|teardown) ;;
  *) echo "[FAIL] MODE must be whatif, deploy, or teardown (got '$MODE')."; exit 2 ;;
esac

# Work in YOUR subscription: the one you name, or the CLI's current one. Nothing in this lab
# is tied to a particular tenant or subscription.
if [ -n "${SUBSCRIPTION_ID:-}" ]; then
  az account set --subscription "$SUBSCRIPTION_ID"
fi
SUB="$(az account show --query id -o tsv)"
if [ -z "$SUB" ]; then
  echo "[FAIL] no Azure CLI sign-in. Run az login, then rerun."; exit 1
fi
echo "[INFO] mode=$MODE  identity=$(az account show --query user.name -o tsv)  subscription=$(az account show --query name -o tsv)  location=$LOC"

# --- TEARDOWN ----------------------------------------------------------------
# Order: the app registration first (it's the only thing outside the groups),
# then the groups, refusing any group whose ownership tag isn't this lab's.
if [ "$MODE" = "teardown" ]; then
  APP_ID="$(az ad app list --display-name "$SP_NAME" --query "[0].appId" -o tsv)"
  if [ -n "$APP_ID" ]; then
    az ad app delete --id "$APP_ID"
    echo "[OK] $SP_NAME deleted"
  else
    echo "[OK] $SP_NAME already absent"
  fi
  for g in "$RG" "$HOST_RG"; do
    if [ "$(az group exists -n "$g")" != "true" ]; then echo "[OK] $g already absent"; continue; fi
    if [ "$(az group show -n "$g" --query tags.course -o tsv)" != "SC100-C3M02" ]; then
      echo "[FAIL] $g ownership tag does not match this lab. Refusing to delete it."; exit 1
    fi
    az group delete -n "$g" --yes
    echo "[OK] $g deleted"
  done
  echo "[NEXT] If you turned on Defender for Servers Plan 2 only for this lab: az security pricing create --name VirtualMachines --tier free"
  exit 0
fi

# --- CHECKS: everything the deploy would otherwise discover by failing --------
USED="$(az vm list-usage -l "$LOC" --query "[?name.value=='cores'].currentValue | [0]" -o tsv)"
LIMIT="$(az vm list-usage -l "$LOC" --query "[?name.value=='cores'].limit | [0]" -o tsv)"
if [ $((LIMIT - USED)) -lt "$VCPUS_NEEDED" ]; then
  echo "[FAIL] $LOC has $USED of $LIMIT regional vCPUs in use; the lab needs $VCPUS_NEEDED. Set LOCATION to another region."; exit 1
fi
echo "[OK] quota: $LOC cores $USED/$LIMIT, lab needs $VCPUS_NEEDED"
# Family quota too: every VM here is B-series, and the family limit can bite before the regional one.
BUSED="$(az vm list-usage -l "$LOC" --query "[?name.value=='standardBSFamily'].currentValue | [0]" -o tsv)"
BLIMIT="$(az vm list-usage -l "$LOC" --query "[?name.value=='standardBSFamily'].limit | [0]" -o tsv)"
if [ $((BLIMIT - BUSED)) -lt "$VCPUS_NEEDED" ]; then
  echo "[FAIL] $LOC B-series family has $BUSED of $BLIMIT vCPUs in use; the lab needs $VCPUS_NEEDED."; exit 1
fi
echo "[OK] quota: $LOC B-series family $BUSED/$BLIMIT"

# The lab's whole point is that two VMs OVERRIDE the subscription's plan. If the
# subscription isn't on Plan 2, the inherited rows read wrong. Turning on a
# subscription-wide plan is your decision, so what-if only warns and deploy stops.
PLAN="$(az rest --method get --url "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.Security/pricings/VirtualMachines?api-version=2024-01-01" --query "join('/', [properties.pricingTier, properties.subPlan])" -o tsv)"
if [ "$PLAN" != "Standard/P2" ]; then
  if [ "$MODE" = "deploy" ]; then
    echo "[FAIL] Defender for Servers at subscription scope is '$PLAN', expected Standard/P2. This script won't change it on your behalf. It covers every server in the subscription; to turn it on:"
    echo "       az security pricing create --name VirtualMachines --tier standard --subplan P2"
    exit 1
  fi
  echo "[WARN] Defender for Servers at subscription scope is '$PLAN'. MODE=deploy needs Standard/P2."
else
  echo "[OK] Defender for Servers subscription plan: $PLAN"
fi

# Azure Arc needs these resource providers registered before glb-dc-file01 can appear.
for ns in Microsoft.HybridCompute Microsoft.GuestConfiguration Microsoft.HybridConnectivity; do
  state="$(az provider show -n "$ns" --query registrationState -o tsv)"
  if [ "$state" != "Registered" ]; then
    if [ "$MODE" = "deploy" ]; then
      az provider register -n "$ns" --wait
      echo "[OK] registered $ns"
    else
      echo "[WARN] $ns is $state; MODE=deploy registers it"
    fi
  else
    echo "[OK] provider $ns registered"
  fi
done

# --- TEMPLATES: written fresh every run, so this file IS the source it deploys -
mkdir -p "$WORK"
cat > "$WORK/main.bicep" <<'C3M02_TEMPLATE_EOF'
// =============================================================================================
// SC-100 Course 3, Module 2 lab: the Globomantics server estate.
//
// WHAT IT BUILDS (subscription scope, West US 2 by default)
//   rg-globomantics-c3m02        the estate the demo reads, and the only group it filters to
//     vm-glb-erp01               Windows Server 2025 Azure VM   Defender for Servers inherited (P2)
//     vm-glb-web01               Ubuntu Azure VM, storefront    resource-level Plan 1
//     vm-glb-test01              Ubuntu Azure VM, test          resource-level Plan 1
//     glb-dc-file01              Azure Arc-enabled server       inherited (P2), created by the agent
//   rg-globomantics-c3m02-host   plumbing the demo never shows
//     vm-glb-arc-host01          the Azure VM that plays the datacenter server; Defender Free
//
// WHY THIS SHAPE (the decision the demo supports: which plan, and which onboarding path)
//   * Plans must DIFFER across servers, or there's no plan decision to make. Two servers on
//     Plan 1 with different tags give you a real choice: the storefront web tier that handles
//     customer orders, or an isolated test box.
//   * The Arc machine must be a real Microsoft.HybridCompute/machines resource, because the
//     inventory's resource type is the evidence for "how it connects". A lab has no real
//     datacenter, so an Azure VM plays one, using Microsoft's evaluation-only procedure
//     ("Evaluate Azure Arc-enabled servers on an Azure virtual machine"). Read
//     arc-host-cloud-init.yaml for how the host prepares itself and connects.
//   * The host VM sits in its OWN resource group with Defender set to Free on the VM resource:
//     Free keeps Defender from pushing an extension onto a machine that must have none, and the
//     separate group keeps an extra Azure VM out of the demo's filtered inventory.
//   * No public IPs, no inbound rules. Nothing in this module needs a shell on any machine.
//   * Trusted launch (Secure Boot plus vTPM) on every VM, because the module's own server
//     requirements specify it for Azure VMs; the lab shouldn't contradict the slide.
//
// EVIDENCE BOUNDARY
//   Tags such as dataClass and environment are DESIGN INPUTS written here, not findings. The
//   demo reads them as "what Globomantics says this server does", never as observed exposure.
//
// PREREQUISITE THIS TEMPLATE DOESN'T CREATE
//   Defender for Servers Plan 2 at subscription scope. vm-glb-erp01 and glb-dc-file01 inherit
//   it. The deploy scripts check for it and stop, rather than change a subscription-wide plan
//   on your behalf.
// =============================================================================================
targetScope = 'subscription'

@description('Region for every resource. Pick any region where you have at least 5 free B-series vCPUs.')
param location string = 'westus2'

@description('Local administrator password for vm-glb-erp01. The deploy scripts generate it at run time and never print it.')
@secure()
param adminPassword string

@description('Public half of a throwaway SSH key. The deploy scripts delete the private half straight away.')
param sshPublicKey string

@description('Application (client) ID of the onboarding service principal that connects glb-dc-file01 to Arc.')
param arcSpAppId string

@description('Its secret. Expires one day after creation, and the host scrubs it after connecting.')
@secure()
param arcSpSecret string

@description('Directory (tenant) ID the Arc machine registers in. Defaults to the tenant you deploy from.')
param tenantId string = tenant().tenantId

@description('Windows time zone ID for the nightly 11 PM shutdown of every lab VM, for example Pacific Standard Time or W. Europe Standard Time.')
param shutdownTimeZone string = 'Central Standard Time'

var estateRg = 'rg-globomantics-c3m02'
var hostRg = 'rg-globomantics-c3m02-host'
var baseTags = {
  course: 'SC100-C3M02'
  company: 'Globomantics'
  purpose: 'demo-fixture'
  teardown: 'after-course'
}

resource estate 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: estateRg
  location: location
  tags: baseTags
}

resource hostGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: hostRg
  location: location
  tags: union(baseTags, { role: 'arc-evaluation-host' })
}

module servers 'servers.bicep' = {
  name: 'c3m02-servers'
  scope: estate
  params: {
    location: location
    baseTags: baseTags
    adminPassword: adminPassword
    sshPublicKey: sshPublicKey
    shutdownTimeZone: shutdownTimeZone
  }
}

module arcHost 'archost.bicep' = {
  name: 'c3m02-archost'
  scope: hostGroup
  params: {
    location: location
    baseTags: baseTags
    arcSpAppId: arcSpAppId
    arcSpSecret: arcSpSecret
    tenantId: tenantId
    subscriptionId: subscription().subscriptionId
    arcResourceGroup: estateRg
    sshPublicKey: sshPublicKey
    shutdownTimeZone: shutdownTimeZone
  }
}

output estateResourceGroup string = estate.name
output hostResourceGroup string = hostGroup.name
output azureServers array = servers.outputs.serverNames
output arcMachineName string = arcHost.outputs.arcMachineName
C3M02_TEMPLATE_EOF

cat > "$WORK/servers.bicep" <<'C3M02_TEMPLATE_EOF'
// =============================================================================================
// The Azure half of the Globomantics server estate for C3 M2. Deployed into rg-globomantics-c3m02
// by main.bicep. Read main.bicep's header first; this file only builds what it describes.
// =============================================================================================
param location string
param baseTags object

@secure()
param adminPassword string

@description('Public half of a throwaway key the deploy script generates and then destroys. Linux sign-in is key-only, and nobody keeps the private key, because nothing in this module needs a shell.')
param sshPublicKey string

@description('Windows time zone ID for the nightly 11 PM shutdown, passed down from main.bicep.')
param shutdownTimeZone string

var adminUser = 'glbadmin'

// Each server: what it is, what OS, and which Defender for Servers plan it carries.
//   plan 'inherit' -> no resource-level pricing, so it takes the subscription's Plan 2
//   plan 'P1'      -> resource-level Standard/P1, the documented way to run Plan 1 on one machine
//                     while the subscription runs Plan 2
var servers = [
  {
    name: 'vm-glb-erp01'
    os: 'windows'
    size: 'Standard_B2s'
    plan: 'inherit'
    tags: { role: 'erp', dataClass: 'financial', environment: 'production' }
  }
  {
    name: 'vm-glb-web01'
    os: 'linux'
    size: 'Standard_B1ms'
    plan: 'P1'
    tags: { role: 'storefront-web', dataClass: 'customer-orders', environment: 'production' }
  }
  {
    name: 'vm-glb-test01'
    os: 'linux'
    size: 'Standard_B1ms'
    plan: 'P1'
    tags: { role: 'integration-test', dataClass: 'synthetic', environment: 'test' }
  }
]

var images = {
  windows: {
    publisher: 'MicrosoftWindowsServer'
    offer: 'WindowsServer'
    sku: '2025-datacenter-g2'
    version: 'latest'
  }
  linux: {
    publisher: 'Canonical'
    offer: '0001-com-ubuntu-server-jammy'
    sku: '22_04-lts-gen2'
    version: 'latest'
  }
}

// No inbound rules at all: the platform defaults deny internet inbound, and nothing here needs
// a management port. The demo is read entirely from the Defender for Cloud control plane.
resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-glb-c3m02-servers'
  location: location
  tags: baseTags
  properties: {
    securityRules: []
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-glb-c3m02'
  location: location
  tags: baseTags
  properties: {
    addressSpace: { addressPrefixes: [ '10.62.0.0/24' ] }
    subnets: [
      {
        name: 'snet-servers'
        properties: {
          addressPrefix: '10.62.0.0/26'
          networkSecurityGroup: { id: nsg.id }
          // Explicit, because new subnets default to private. The Defender for Endpoint agent
          // and the Defender extensions need outbound HTTPS, and a NAT gateway for a four-VM
          // lab is cost with no teaching value.
          defaultOutboundAccess: true
        }
      }
    ]
  }
}

resource nics 'Microsoft.Network/networkInterfaces@2024-05-01' = [for s in servers: {
  name: 'nic-${s.name}'
  location: location
  tags: union(baseTags, s.tags)
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: { id: vnet.properties.subnets[0].id }
        }
      }
    ]
  }
}]

resource vms 'Microsoft.Compute/virtualMachines@2024-07-01' = [for (s, i) in servers: {
  name: s.name
  location: location
  tags: union(baseTags, s.tags)
  properties: {
    hardwareProfile: { vmSize: s.size }
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: { secureBootEnabled: true, vTpmEnabled: true }
    }
    storageProfile: {
      imageReference: images[s.os]
      osDisk: {
        name: 'osdisk-${s.name}'
        createOption: 'FromImage'
        deleteOption: 'Delete'
        managedDisk: { storageAccountType: 'StandardSSD_LRS' }
      }
    }
    osProfile: s.os == 'windows' ? {
      computerName: take(replace(s.name, 'vm-', ''), 15)
      adminUsername: adminUser
      adminPassword: adminPassword
      windowsConfiguration: { provisionVMAgent: true, enableAutomaticUpdates: true }
    } : {
      computerName: replace(s.name, 'vm-', '')
      adminUsername: adminUser
      linuxConfiguration: {
        disablePasswordAuthentication: true
        provisionVMAgent: true
        ssh: { publicKeys: [ { path: '/home/${adminUser}/.ssh/authorized_keys', keyData: sshPublicKey } ] }
      }
    }
    networkProfile: {
      networkInterfaces: [ { id: nics[i].id, properties: { deleteOption: 'Delete' } } ]
    }
    diagnosticsProfile: { bootDiagnostics: { enabled: true } }
  }
}]

// Resource-level Plan 1. Scoped to the VM itself, so it overrides the subscription's Plan 2 for
// that one machine and nothing else. This is the difference the demo's plan table reads.
resource planP1 'Microsoft.Security/pricings@2024-01-01' = [for (s, i) in servers: if (s.plan == 'P1') {
  name: 'virtualMachines'
  scope: vms[i]
  properties: {
    pricingTier: 'Standard'
    subPlan: 'P1'
  }
}]

// Shut every server down at 11 PM in the time zone you picked, so a lab you forget about doesn't
// run all night, and a daytime session is never cut off partway through.
resource shutdown 'Microsoft.DevTestLab/schedules@2018-09-15' = [for (s, i) in servers: {
  name: 'shutdown-computevm-${s.name}'
  location: location
  tags: baseTags
  properties: {
    status: 'Enabled'
    taskType: 'ComputeVmShutdownTask'
    dailyRecurrence: { time: '2300' }
    timeZoneId: shutdownTimeZone
    targetResourceId: vms[i].id
    notificationSettings: { status: 'Disabled' }
  }
}]

output serverNames array = [for s in servers: s.name]
C3M02_TEMPLATE_EOF

cat > "$WORK/archost.bicep" <<'C3M02_TEMPLATE_EOF'
// =============================================================================================
// The Azure VM that plays a Globomantics datacenter server for C3 M2, and connects itself to
// Azure Arc as glb-dc-file01 in rg-globomantics-c3m02. Deployed into rg-globomantics-c3m02-host.
//
// Microsoft supports this ONLY for evaluation ("Evaluate Azure Arc-enabled servers on an Azure
// virtual machine"), and the procedure has hard requirements that this file honors:
//   * no VM extensions on the host, so Defender for Servers is set to Free on THIS VM resource,
//     which stops Defender from pushing the Defender for Endpoint extension onto it;
//   * the Azure guest agent stopped and masked, and the instance metadata endpoints blocked,
//     which cloud-init does before it installs the Connected Machine agent.
// The Arc resource it creates is what the demo reads; this VM is plumbing the demo never shows.
// =============================================================================================
param location string
param baseTags object
param arcSpAppId string

@secure()
param arcSpSecret string

param tenantId string
param subscriptionId string
param arcResourceGroup string
param sshPublicKey string

@description('Windows time zone ID for the nightly 11 PM shutdown, passed down from main.bicep.')
param shutdownTimeZone string

var hostName = 'vm-glb-arc-host01'
var arcMachineName = 'glb-dc-file01'

// cloud-init is authored as a plain file so it can be read and linted on its own; the values
// that differ per deployment are substituted here. The secret therefore lands in customData,
// which Azure doesn't return from any API, and cloud-init scrubs every on-disk copy after the
// agent connects (see the file's own header).
var cloudInit = reduce(
  items({
    '__ARC_SP_APP_ID__': arcSpAppId
    '__ARC_SP_SECRET__': arcSpSecret
    '__TENANT_ID__': tenantId
    '__SUBSCRIPTION_ID__': subscriptionId
    '__ARC_RESOURCE_GROUP__': arcResourceGroup
    '__ARC_MACHINE_NAME__': arcMachineName
    '__LOCATION__': location
  }),
  loadTextContent('arc-host-cloud-init.yaml'),
  (text, kv) => replace(text, kv.key, kv.value))

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-glb-c3m02-host'
  location: location
  tags: baseTags
  properties: {
    securityRules: []
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-glb-c3m02-host'
  location: location
  tags: baseTags
  properties: {
    addressSpace: { addressPrefixes: [ '10.62.1.0/24' ] }
    subnets: [
      {
        name: 'snet-host'
        properties: {
          addressPrefix: '10.62.1.0/26'
          networkSecurityGroup: { id: nsg.id }
          // The agent installer and the Arc endpoints are reached over outbound HTTPS.
          defaultOutboundAccess: true
        }
      }
    ]
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: 'nic-${hostName}'
  location: location
  tags: baseTags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: { id: vnet.properties.subnets[0].id }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: hostName
  location: location
  tags: union(baseTags, { role: 'arc-evaluation-host', plays: arcMachineName })
  properties: {
    hardwareProfile: { vmSize: 'Standard_B1ms' }
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: { secureBootEnabled: true, vTpmEnabled: true }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        name: 'osdisk-${hostName}'
        createOption: 'FromImage'
        deleteOption: 'Delete'
        managedDisk: { storageAccountType: 'StandardSSD_LRS' }
      }
    }
    osProfile: {
      computerName: 'glb-dc-file01'
      adminUsername: 'glbadmin'
      customData: base64(cloudInit)
      linuxConfiguration: {
        disablePasswordAuthentication: true
        provisionVMAgent: true
        ssh: { publicKeys: [ { path: '/home/glbadmin/.ssh/authorized_keys', keyData: sshPublicKey } ] }
      }
    }
    networkProfile: {
      networkInterfaces: [ { id: nic.id, properties: { deleteOption: 'Delete' } } ]
    }
    // Every cloud-init step reports to the serial console, which boot diagnostics captures,
    // because once the guest agent is masked, Run Command can't reach this VM.
    diagnosticsProfile: { bootDiagnostics: { enabled: true } }
  }
}

// Defender for Servers OFF for this VM resource only. The Arc machine it becomes is billed and
// protected on its own resource; this keeps the host from carrying a second, extension-pushing
// plan that would break the evaluation procedure.
resource hostFree 'Microsoft.Security/pricings@2024-01-01' = {
  name: 'VirtualMachines'
  scope: vm
  properties: {
    pricingTier: 'Free'
  }
}

// Same nightly 11 PM shutdown as the Azure servers, so Arc is available whenever they are.
resource shutdown 'Microsoft.DevTestLab/schedules@2018-09-15' = {
  name: 'shutdown-computevm-${vm.name}'
  location: location
  tags: baseTags
  properties: {
    status: 'Enabled'
    taskType: 'ComputeVmShutdownTask'
    dailyRecurrence: { time: '2300' }
    timeZoneId: shutdownTimeZone
    targetResourceId: vm.id
    notificationSettings: { status: 'Disabled' }
  }
}

output arcMachineName string = arcMachineName
output hostVmName string = vm.name
C3M02_TEMPLATE_EOF

cat > "$WORK/arc-host-cloud-init.yaml" <<'C3M02_TEMPLATE_EOF'
#cloud-config
# vm-glb-arc-host01 -> Azure Arc machine glb-dc-file01, for SC-100 Course 3 Module 2.
#
# WHAT THIS DOES. It follows Microsoft's evaluation-only procedure "Evaluate Azure Arc-enabled
# servers on an Azure virtual machine": stop and mask the Azure guest agent, block the instance
# metadata endpoints, install the Connected Machine agent, then connect. Two choices are this
# lab's own, and here's why:
#   * CONNECTS ITSELF. The lab has no Bastion and no public IP, so nobody signs in to finish an
#     interactive connect. The agent connects with a service principal that holds only
#     "Azure Connected Machine Onboarding" on one resource group, with a secret that expires a
#     day after it's minted. That's also the onboarding method Course 3 Module 1 recommends, so
#     the lab practices what the course teaches.
#   * SCRUBS THE SECRET. Every on-disk copy of this file, which carries the secret, is shredded
#     after the connect attempt, success or failure.
# Every console line starts with GLOBOMANTICS-ARC, so you can filter the boot log for it.
#
# The __PLACEHOLDERS__ are replaced by archost.bicep at deployment time. Nothing here is
# secret until then.
#
# Once the guest agent is masked, Run Command and extensions stop working on this VM, so every
# result goes to the serial console. Read it through boot diagnostics:
#   az vm boot-diagnostics get-boot-log -g rg-globomantics-c3m02-host -n vm-glb-arc-host01

write_files:
  - path: /etc/environment
    append: true
    content: |
      MSFT_ARC_TEST=true
  # The agent's daemons need the variable too, and systemctl set-environment doesn't survive a
  # reboot. A manager drop-in does, so the lab can be deallocated between sessions.
  - path: /etc/systemd/system.conf.d/10-msft-arc-test.conf
    content: |
      [Manager]
      DefaultEnvironment=MSFT_ARC_TEST=true
  - path: /usr/local/sbin/glb-arc-prep
    permissions: '0700'
    content: |
      #!/bin/bash
      # One-time preparation and connection. Never 'set -x': the secret must not reach a log.
      out=/dev/ttyS0
      report() { echo "GLOBOMANTICS-ARC $*" > "$out" 2>/dev/null; echo "GLOBOMANTICS-ARC $*"; }
      report "prep begin $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      export MSFT_ARC_TEST=true
      systemctl set-environment MSFT_ARC_TEST=true
      systemctl daemon-reexec
      systemctl stop walinuxagent
      systemctl disable walinuxagent
      systemctl mask walinuxagent
      report "guest-agent=$(systemctl is-active walinuxagent 2>/dev/null) enabled=$(systemctl is-enabled walinuxagent 2>/dev/null)"
      ufw --force enable
      ufw default allow incoming
      ufw deny out from any to 169.254.169.254
      ufw deny out from any to 169.254.169.253
      if curl -s -m 5 -H Metadata:true "http://169.254.169.254/metadata/instance?api-version=2021-02-01" > /dev/null; then
        report "imds=reachable (NOT blocked)"
      else
        report "imds=blocked"
      fi
      curl -fsSL -o /tmp/install_linux_azcmagent.sh https://gbl.his.arc.azure.com/azcmagent-linux
      if bash /tmp/install_linux_azcmagent.sh > /var/log/glb-azcmagent-install.log 2>&1; then
        report "agent-install=ok version=$(azcmagent version 2>/dev/null | head -n 1)"
      else
        report "agent-install=FAILED (see /var/log/glb-azcmagent-install.log)"
      fi
      azcmagent check --location __LOCATION__ 2>&1 | sed 's/^/GLOBOMANTICS-ARC check /' > "$out" 2>/dev/null
      # Connect. The role assignment behind the service principal can take a few minutes to
      # propagate, so retry rather than fail on the first 403.
      connected=no
      for attempt in 1 2 3 4 5; do
        if azcmagent connect \
             --service-principal-id "__ARC_SP_APP_ID__" \
             --service-principal-secret "__ARC_SP_SECRET__" \
             --tenant-id "__TENANT_ID__" \
             --subscription-id "__SUBSCRIPTION_ID__" \
             --resource-group "__ARC_RESOURCE_GROUP__" \
             --location "__LOCATION__" \
             --resource-name "__ARC_MACHINE_NAME__" \
             --tags "course=SC100-C3M02,company=Globomantics,purpose=demo-fixture,role=file-server,dataClass=internal-files,environment=production,site=datacenter" \
             > /var/log/glb-azcmagent-connect.log 2>&1; then
          connected=yes; break
        fi
        report "connect attempt $attempt failed; retrying in 60s"
        sleep 60
      done
      report "connect=$connected"
      # Scrub every copy of the user data that carried the secret, whatever the outcome.
      for f in /var/lib/cloud/instance/user-data.txt /var/lib/cloud/instance/user-data.txt.i \
               /var/lib/cloud/instances/*/user-data.txt /var/lib/cloud/instances/*/user-data.txt.i \
               /var/lib/cloud/instances/*/obj.pkl /var/lib/waagent/CustomData /var/lib/waagent/ovf-env.xml; do
        [ -e "$f" ] && shred -u "$f" 2>/dev/null
      done
      sed -i 's/--service-principal-secret "[^"]*"/--service-principal-secret "SCRUBBED"/' /usr/local/sbin/glb-arc-prep
      report "secret-scrub=done"
      # Later boots can't reach instance metadata, so stop cloud-init from waiting on it.
      touch /etc/cloud/cloud-init.disabled
      report "prep end $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  - path: /usr/local/sbin/glb-arc-status
    permissions: '0755'
    content: |
      #!/bin/bash
      # Every boot: the Arc agent's view of itself, to the serial console.
      out=/dev/ttyS0
      {
        echo "GLOBOMANTICS-ARC status begin $(hostname) $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        azcmagent show 2>&1 | grep -E 'Resource Name|Resource Group|Agent Status|Agent Version|Cloud Provider|Last Heartbeat' | sed 's/^/GLOBOMANTICS-ARC status /'
        echo "GLOBOMANTICS-ARC status guest-agent=$(systemctl is-active walinuxagent 2>/dev/null)"
        echo "GLOBOMANTICS-ARC status end"
      } > "$out" 2>/dev/null || true
  - path: /etc/systemd/system/glb-arc-status.service
    content: |
      [Unit]
      Description=Print the Azure Arc agent status to the serial console
      After=network-online.target himdsd.service
      Wants=network-online.target

      [Service]
      Type=oneshot
      ExecStartPre=/bin/sleep 60
      ExecStart=/usr/local/sbin/glb-arc-status

      [Install]
      WantedBy=multi-user.target

runcmd:
  - /usr/local/sbin/glb-arc-prep
  - systemctl daemon-reload
  - systemctl enable glb-arc-status.service
C3M02_TEMPLATE_EOF

# Throwaway SSH key: the API needs a public key; nobody keeps the private one.
ssh-keygen -t ed25519 -N '' -C 'c3m02-lab-throwaway' -f "$WORK/throwaway" -q
PUBKEY="$(cat "$WORK/throwaway.pub")"
shred -u "$WORK/throwaway"

NAME="c3m02-estate-$(date +%Y%m%d%H%M%S)"
if [ "$MODE" = "whatif" ]; then
  # What-if creates nothing, but the template still wants every parameter. These
  # values are random throwaways, so no real or literal secret is ever involved.
  WHATIF_PW="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 24)aA1."
  WHATIF_SECRET="$(openssl rand -hex 16)"
  echo "[PLAN] what-if only. Nothing is created in this mode."
  az deployment sub what-if --location "$LOC" --name "$NAME" --template-file "$WORK/main.bicep" \
    --parameters adminPassword="$WHATIF_PW" sshPublicKey="$PUBKEY" \
                 arcSpAppId='00000000-0000-0000-0000-000000000000' arcSpSecret="$WHATIF_SECRET" \
                 location="$LOC" shutdownTimeZone="$SHUTDOWN_TZ"
  unset WHATIF_PW WHATIF_SECRET
  echo "[NEXT] To build it: MODE=deploy bash $(basename "$0")"
  exit 0
fi

# --- DEPLOY --------------------------------------------------------------------
# The groups first, because the onboarding role is scoped to one of them.
for g in "$RG" "$HOST_RG"; do
  if [ "$(az group exists -n "$g")" = "true" ] && [ "$(az group show -n "$g" --query tags.course -o tsv)" != "SC100-C3M02" ]; then
    echo "[FAIL] $g already exists and isn't tagged course=SC100-C3M02. Refusing to touch it."; exit 1
  fi
  az group create -n "$g" -l "$LOC" --tags course=SC100-C3M02 company=Globomantics purpose=demo-fixture teardown=after-course -o none
done
RG_ID="$(az group show -n "$RG" --query id -o tsv)"

# Onboarding service principal: create once, then mint a ONE-DAY secret every run.
APP_ID="$(az ad app list --display-name "$SP_NAME" --query "[0].appId" -o tsv)"
if [ -z "$APP_ID" ]; then
  APP_ID="$(az ad app create --display-name "$SP_NAME" --query appId -o tsv)"
  az ad sp create --id "$APP_ID" -o none
  echo "[OK] created $SP_NAME ($APP_ID)"
fi
SP_OID="$(az ad sp show --id "$APP_ID" --query id -o tsv)"
if [ "$(az role assignment list --assignee "$SP_OID" --scope "$RG_ID" --role "$ONBOARD_ROLE" --query 'length(@)' -o tsv)" = "0" ]; then
  az role assignment create --assignee-object-id "$SP_OID" --assignee-principal-type ServicePrincipal \
    --role "$ONBOARD_ROLE" --scope "$RG_ID" -o none
  echo "[OK] Azure Connected Machine Onboarding granted on $RG only"
fi
END="$(date -u -d '+1 day' +%Y-%m-%dT%H:%M:%SZ)"
SP_SECRET="$(az ad app credential reset --id "$APP_ID" --end-date "$END" --query password -o tsv --only-show-errors)"
ADMIN_PW="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 24)aA1."   # upper, lower, digit, symbol

# Secrets go to the deployment as parameters, never into a file, so nothing secret lands on
# disk. Your own shell's process list can see them while az runs, which is one reason the
# onboarding secret is scoped to one role on one resource group and expires in a day.
echo "[DEPLOY] creating or re-asserting the lab (10 to 15 minutes) ..."
az deployment sub create --location "$LOC" --name "$NAME" --template-file "$WORK/main.bicep" \
  --parameters adminPassword="$ADMIN_PW" sshPublicKey="$PUBKEY" arcSpAppId="$APP_ID" \
               arcSpSecret="$SP_SECRET" location="$LOC" shutdownTimeZone="$SHUTDOWN_TZ" -o none
unset ADMIN_PW SP_SECRET
az deployment sub show --name "$NAME" --query "properties.outputs" -o jsonc

# Read back through a different path than the one that wrote it.
echo "[VERIFY] Azure VMs and power state:"
az vm list -g "$RG" -d --query "[].{name:name, power:powerState, os:storageProfile.osDisk.osType}" -o table
echo "[VERIFY] resource-level plans (Plan 1 expected on web01 and test01):"
for vm in vm-glb-erp01 vm-glb-web01 vm-glb-test01; do
  id="$(az vm show -g "$RG" -n "$vm" --query id -o tsv)"
  az rest --method get --url "https://management.azure.com$id/providers/Microsoft.Security/pricings/virtualMachines?api-version=2024-01-01" \
    --query "{vm:'$vm', tier:properties.pricingTier, subPlan:properties.subPlan, inherited:properties.inherited}" -o tsv
done
echo "[VERIFY] Arc machine (the host connects itself a few minutes after it boots):"
# Ask for the machine by exact name: the generic resource-list endpoint has returned an empty
# list even while an exact read showed the connected machine.
az resource show -g "$RG" -n glb-dc-file01 --resource-type Microsoft.HybridCompute/machines --api-version 2024-07-10 \
  --query "{name:name, status:properties.status}" -o table 2>/dev/null \
  || echo "[INFO] glb-dc-file01 isn't registered yet. Check again in five minutes."
echo "[VERIFY] host's own report, from the serial console:"
az vm boot-diagnostics get-boot-log -g "$HOST_RG" -n vm-glb-arc-host01 2>/dev/null | grep 'GLOBOMANTICS-ARC' | tail -n 12 || true
echo "[WAIT] Defender for Endpoint onboarding and the Defender for Cloud inventory run on their own cycles; give the portal views up to 24 hours."
echo "[NEXT] Read the plans: pwsh -NoProfile -File ./Show-C3M02ServerPlans.ps1"
echo "[NEXT] When you're done: MODE=teardown bash $(basename "$0")"
