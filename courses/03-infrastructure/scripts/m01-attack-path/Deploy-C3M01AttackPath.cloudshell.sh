#!/usr/bin/env bash
# =============================================================================
# Deploy-C3M01AttackPath.cloudshell.sh
#
# SYNOPSIS
#   Preview, deploy, or tear down the SC-100 Course 3, Module 1 attack path lab
#   in YOUR Azure subscription, from Azure Cloud Shell (Bash).
#
# DESCRIPTION
#   Supports the demo "Follow an attack path to a critical asset". It builds two
#   internet-exposed web VMs that share ONE user-assigned managed identity, and
#   that identity can read the Globomantics order data. Two entry points
#   converging on one identity is what gives Microsoft Defender for Cloud a
#   choke point to find.
#
#     Internet --80--> vm-c3m01-web01 --\
#                                        +--> id-globomantics-c3m01-orders --read--> your order storage account
#     Internet --80--> vm-c3m01-web02 --/            (the choke point)                (the critical asset)
#
#   What it changes: creates resource group rg-globomantics-c3m01 and everything
#   in it, and adds ONE role assignment (Storage Blob Data Reader) on the target
#   storage account you name. It doesn't create that storage account; README.md
#   has the commands that do.
#
#   This file is also the single source of the Bicep templates.
#   Deploy-C3M01AttackPath.ps1 extracts them from here, so edit them here only.
#
#   Upload it to Cloud Shell and run the saved file with bash, as the examples
#   below do. Running it in a child process matters: its strict settings and
#   exit commands must not end the interactive Cloud Shell session.
#
# SETTINGS (environment variables, set on each run)
#   MODE           whatif (the default), deploy, or teardown.
#                    whatif    shows the plan and creates nothing.
#                    deploy    creates or re-asserts the lab. Safe to rerun.
#                    teardown  removes the role assignment, then the resource group.
#   TARGET_ST      REQUIRED. The storage account that plays the critical asset.
#                  Storage account names are globally unique, so yours can't be
#                  stglobomanticsorders; something like stglobomanticsorders123.
#   TARGET_RG      Resource group that holds TARGET_ST. Default: rg-globomantics.
#   SUBSCRIPTION   Subscription name or ID. Default: your current az account.
#   LOCATION       Azure region for the lab. Default: westus2.
#   IMAGE_VERSION  Ubuntu 22.04 LTS gen2 image version. Default: 22.04.202206220.
#
# EXAMPLES
#   MODE=whatif   TARGET_ST=stglobomanticsorders123 bash Deploy-C3M01AttackPath.cloudshell.sh
#   MODE=deploy   TARGET_ST=stglobomanticsorders123 bash Deploy-C3M01AttackPath.cloudshell.sh
#   MODE=teardown TARGET_ST=stglobomanticsorders123 bash Deploy-C3M01AttackPath.cloudshell.sh
#
# NOTES
#   PREREQUISITES
#   * Azure Cloud Shell (Bash), or any bash with the Azure CLI, ssh-keygen and
#     curl. The CLI has to deploy Bicep files directly: 2.20.0 or later, and
#     the current release is the safest choice.
#   * Owner on the subscription, or Contributor plus User Access Administrator,
#     because the deployment writes a role assignment.
#   * Microsoft Defender for Cloud on the subscription, with agentless scanning
#     and attack path generation available. Check Microsoft Learn for the plan
#     that provides them and what it costs.
#   * 2 free vCPUs of regional quota in LOCATION. Deallocated VMs still count
#     against quota, and the checks below read it on every run.
#   * The target storage account must already exist (see README.md).
#
#   READ BEFORE MODE=deploy. THIS LAB IS DELIBERATELY WEAK.
#   * The VMs run a pinned 2022 Ubuntu image with automatic patching turned off,
#     because an attack path needs high-severity vulnerabilities to start from.
#   * Port 80 is open to the whole internet, because Defender for Cloud builds
#     paths only from exposure it can validate from outside.
#   * The shared identity can READ every blob in the target storage account.
#   What limits the damage: SSH is closed and password sign-in is off, the only
#   listener is a static page served by Python's built-in web server, and the
#   identity can read one storage account and write nothing. POINT IT ONLY AT A
#   STORAGE ACCOUNT THAT HOLDS FICTIONAL DATA, and tear the lab down as soon as
#   you've finished the demo.
#
#   TIMING: the deploy takes minutes; the wait is the lab. Agentless scanning
#   and attack path generation run on Defender for Cloud's own cycle, so give it
#   at least 24 hours, better 48, before you look for the path. Then check
#   progress with C3M01VulnerabilityEvidence.ps1 and C3M01-ExposureGraphCheck.kql.
#
#   If Azure Resource Manager prompts for MFA, complete the prompt. Don't
#   weaken authentication to get around it.
#
#   COST: THIS CREATES BILLABLE RESOURCES. Two Standard_B1s VMs bill while they
#   run, plus their managed disks, two Standard public IP addresses, and any
#   Defender for Cloud plan charges. The lab sets no auto-shutdown schedule, and
#   deallocating doesn't mean zero cost. Teardown removes the lab resources;
#   your target storage account and any subscription-level Defender plans stay.
#
#   CLEANUP
#     MODE=teardown TARGET_ST=<your account> bash Deploy-C3M01AttackPath.cloudshell.sh
#   If you created rg-globomantics only for this lab, delete it afterward:
#     az group delete --name rg-globomantics --yes --no-wait
# =============================================================================
set -euo pipefail

MODE="${MODE:-whatif}"
TARGET_ST="${TARGET_ST:-}"
TARGET_RG="${TARGET_RG:-rg-globomantics}"
SUBSCRIPTION="${SUBSCRIPTION:-}"
LOC="${LOCATION:-westus2}"
IMAGE_VERSION="${IMAGE_VERSION:-22.04.202206220}"   # pinned on purpose: an old image carries the CVEs
RG='rg-globomantics-c3m01'
UAI_NAME='id-globomantics-c3m01-orders'
READER_ROLE='2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'  # Storage Blob Data Reader; built-in role IDs are the same in every tenant
WORK="$HOME/c3m01"

case "$MODE" in
  whatif|deploy|teardown) ;;
  *) echo "[FAIL] MODE must be whatif, deploy, or teardown (got '$MODE')."; exit 2 ;;
esac

# Every mode needs the target account, so fail before touching Azure.
if [ -z "$TARGET_ST" ]; then
  echo "[FAIL] Set TARGET_ST to your order storage account name, for example:"
  echo "       MODE=$MODE TARGET_ST=stglobomanticsorders123 bash Deploy-C3M01AttackPath.cloudshell.sh"
  exit 2
fi

# Use the subscription you name, or the one your CLI session already points at.
if [ -n "$SUBSCRIPTION" ]; then
  az account set --subscription "$SUBSCRIPTION"
fi
# Print where this will land before anything changes, so a wrong context is obvious.
echo "[INFO] mode=$MODE  identity=$(az account show --query user.name -o tsv)  subscription=$(az account show --query name -o tsv)  tenant=$(az account show --query tenantId -o tsv)  region=$LOC"

# --- TEARDOWN ----------------------------------------------------------------
# Order matters: delete the role assignment FIRST. Deleting the identity first
# leaves an orphaned assignment on the storage account that shows up later as
# "Identity not found" and has to be cleaned by hand.
if [ "$MODE" = "teardown" ]; then
  ST_ID="$(az storage account show -n "$TARGET_ST" -g "$TARGET_RG" --query id -o tsv)"
  if [ "$(az group exists -n "$RG")" != "true" ]; then
    echo "[INFO] $RG absent. If you deleted it by hand, check $TARGET_ST > Access control (IAM) for an orphaned Storage Blob Data Reader grant; a missing group alone doesn't prove full cleanup."
    exit 0
  fi
  # The course tag is the ownership check: never delete a group this lab didn't create.
  if [ "$(az group show -n "$RG" --query tags.course -o tsv)" != "SC100-C3M01" ]; then
    echo '[FAIL] group ownership tag does not match the M1 lab. Refusing cleanup.'; exit 1
  fi
  PRINCIPAL_ID="$(az identity show -n "$UAI_NAME" -g "$RG" --query principalId -o tsv)"
  if [ -n "$PRINCIPAL_ID" ]; then
    az role assignment delete --assignee-object-id "$PRINCIPAL_ID" --role "$READER_ROLE" --scope "$ST_ID"
    # Read the grant back through a list call rather than trusting the delete's silence.
    LEFT="$(az role assignment list --assignee-object-id "$PRINCIPAL_ID" --scope "$ST_ID" --fill-principal-name false --fill-role-definition-name false --query "length([?ends_with(roleDefinitionId, '$READER_ROLE')])" -o tsv)"
    if [ "$LEFT" != '0' ]; then echo '[FAIL] M1 blob grant remains. Keeping the identity so you can remove the grant.'; exit 1; fi
    echo '[OK] M1 blob grant read back absent'
  fi
  if [ "$(az group exists -n "$RG")" = "true" ]; then
    az group delete -n "$RG" --yes
    echo "[OK] $RG deleted"
  else
    echo "[OK] $RG already absent"
  fi
  echo "[INFO] $TARGET_ST and any Defender for Cloud plans are untouched. README.md covers removing them."
  exit 0
fi

# --- CHECKS: everything the deploy would otherwise discover by failing --------
USED="$(az vm list-usage -l "$LOC" --query "[?name.value=='cores'].currentValue | [0]" -o tsv)"
LIMIT="$(az vm list-usage -l "$LOC" --query "[?name.value=='cores'].limit | [0]" -o tsv)"
if [ $((LIMIT - USED)) -lt 2 ]; then
  echo "[FAIL] $LOC has $USED of $LIMIT regional vCPUs in use; the lab needs 2. Free some up or set LOCATION to another region."; exit 1
fi
echo "[OK] quota: $LOC cores $USED/$LIMIT"

az vm image show -l "$LOC" --urn "Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:$IMAGE_VERSION" -o none \
  || { echo "[FAIL] image version $IMAGE_VERSION is gone from $LOC. List what's left with:"
       echo "       az vm image list -l $LOC -p Canonical -f 0001-com-ubuntu-server-jammy -s 22_04-lts-gen2 --all --query \"[].version\" -o tsv"
       echo "       then rerun with IMAGE_VERSION set to the oldest version listed."; exit 1; }
echo "[OK] image: Ubuntu 22.04 gen2 $IMAGE_VERSION is available in $LOC"

az storage account show -n "$TARGET_ST" -g "$TARGET_RG" -o none \
  || { echo "[FAIL] target $TARGET_ST not found in $TARGET_RG. Create it first; README.md has the commands."; exit 1; }
echo "[OK] target: $TARGET_ST exists"

# SSH key: required by the API even though port 22 stays closed. The private
# half never leaves Cloud Shell and nothing in the demo uses it.
mkdir -p "$WORK" "$HOME/.ssh"
[ -f "$HOME/.ssh/c3m01_fixture" ] || ssh-keygen -t ed25519 -N '' -C 'c3m01-fixture' -f "$HOME/.ssh/c3m01_fixture" -q
PUBKEY="$(cat "$HOME/.ssh/c3m01_fixture.pub")"

# --- BICEP: three files, written fresh every run from this single source ---
cat > "$WORK/main.bicep" <<'BICEP_EOF'
// SC-100 Course 3 / Module 1 - attack path lab. SUBSCRIPTION scope, because it
// creates the resource group and writes a role assignment in a second one.
targetScope = 'subscription'

param location string = 'westus2'
param fixtureRg string = 'rg-globomantics-c3m01'
param targetRg string = 'rg-globomantics'
// No default: storage account names are globally unique, so every subscription's differs.
param targetStorage string
param identityName string = 'id-globomantics-c3m01-orders'
param imageVersion string
@secure()
param adminPublicKey string

// Every lab object carries this tag. Teardown matches on the tag, never on a
// name pattern, so it refuses to delete a resource group this lab didn't create.
var tags = {
  course: 'SC100-C3M01'
  purpose: 'Deliberately exposed attack path lab for the C3 M1 demo. Delete after the lab.'
  lifecycle: 'delete-after-lab'
}

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: fixtureRg
  location: location
  tags: tags
}

module fixture 'fixture.bicep' = {
  scope: rg
  name: 'c3m01-fixture'
  params: {
    location: location
    tags: tags
    identityName: identityName
    imageVersion: imageVersion
    adminPublicKey: adminPublicKey
  }
}

// The lateral move itself: the shared identity may read the order data.
module blobReader 'blob-reader.bicep' = {
  scope: resourceGroup(targetRg)
  name: 'c3m01-blob-reader'
  params: {
    storageName: targetStorage
    principalId: fixture.outputs.identityPrincipalId
  }
}

output identityPrincipalId string = fixture.outputs.identityPrincipalId
output publicIps array = fixture.outputs.publicIps
BICEP_EOF

cat > "$WORK/fixture.bicep" <<'BICEP_EOF'
// Two web VMs, one shared identity. Resource-group scope.
param location string
param tags object
param identityName string
param imageVersion string
@secure()
param adminPublicKey string

var webNames = [
  'vm-c3m01-web01'
  'vm-c3m01-web02'
]

// Python's standard library serves one static page on port 80. No package install
// runs, so nothing refreshes the pinned image's packages, and the old image keeps
// the vulnerabilities agentless scanning needs to find. bootcmd switches off the
// Ubuntu timers that would otherwise patch the VM overnight.
var cloudInit = '''#cloud-config
bootcmd:
  - [ sh, -c, "systemctl disable --now unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer || true" ]
write_files:
  - path: /srv/c3m01/index.html
    content: |
      <html><body><h1>Globomantics order status</h1><p>Training fixture. No real data.</p></body></html>
  - path: /etc/systemd/system/c3m01-web.service
    content: |
      [Unit]
      Description=C3M01 static page on port 80
      After=network-online.target
      [Service]
      ExecStart=/usr/bin/python3 -m http.server 80 --directory /srv/c3m01
      Restart=always
      [Install]
      WantedBy=multi-user.target
runcmd:
  - [ systemctl, daemon-reload ]
  - [ systemctl, enable, --now, c3m01-web.service ]
'''

resource uai 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
  tags: tags
}

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-c3m01-web'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        // The ONLY inbound rule. SSH stays closed; the entry point is the web listener.
        name: 'allow-http-from-internet'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '80'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-c3m01'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.31.0.0/24'
      ]
    }
    subnets: [
      {
        name: 'snet-web'
        properties: {
          addressPrefix: '10.31.0.0/26'
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
    ]
  }
}

resource pip 'Microsoft.Network/publicIPAddresses@2024-05-01' = [for n in webNames: {
  name: 'pip-${n}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}]

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = [for (n, i) in webNames: {
  name: 'nic-${n}'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, 'snet-web')
          }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: pip[i].id
          }
        }
      }
    ]
  }
}]

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = [for (n, i) in webNames: {
  name: n
  location: location
  tags: tags
  identity: {
    // BOTH VMs carry the SAME identity. This one line is the choke point.
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uai.id}': {}
    }
  }
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_B1s'
    }
    osProfile: {
      computerName: n
      adminUsername: 'globoadmin'
      customData: base64(cloudInit)
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/globoadmin/.ssh/authorized_keys'
              keyData: adminPublicKey
            }
          ]
        }
        patchSettings: {
          // ImageDefault: Azure applies no automatic guest patching. Deliberate.
          patchMode: 'ImageDefault'
          assessmentMode: 'ImageDefault'
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: imageVersion
      }
      osDisk: {
        createOption: 'FromImage'
        deleteOption: 'Delete'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic[i].id
          properties: {
            deleteOption: 'Delete'
          }
        }
      ]
    }
  }
}]

output identityPrincipalId string = uai.properties.principalId
output publicIps array = [for (n, i) in webNames: pip[i].properties.ipAddress]
BICEP_EOF

cat > "$WORK/blob-reader.bicep" <<'BICEP_EOF'
// Storage Blob Data Reader for the shared identity, scoped to the target account.
param storageName string
param principalId string

// Storage Blob Data Reader. Built-in role definition IDs are the same in every tenant.
var readerRoleId = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'

resource st 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageName
}

resource ra 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  // Deterministic name, so a rerun re-asserts this assignment instead of adding a second one.
  name: guid(st.id, principalId, readerRoleId)
  scope: st
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
BICEP_EOF

NAME="c3m01-fixture-$(date +%Y%m%d%H%M%S)"
# location is passed to the template as well as to the deployment, so a LOCATION
# override moves the resources and not just the deployment record.
PARAMS=(location="$LOC" targetRg="$TARGET_RG" targetStorage="$TARGET_ST" imageVersion="$IMAGE_VERSION" adminPublicKey="$PUBKEY")
if [ "$MODE" = "whatif" ]; then
  echo "[PLAN] what-if only. Nothing is created in this mode."
  az deployment sub what-if --location "$LOC" --name "$NAME" --template-file "$WORK/main.bicep" \
    --parameters "${PARAMS[@]}"
  echo "[NEXT] To build it: MODE=deploy TARGET_ST=$TARGET_ST bash Deploy-C3M01AttackPath.cloudshell.sh"
  exit 0
fi

echo "[DEPLOY] creating or re-asserting the lab ..."
az deployment sub create --location "$LOC" --name "$NAME" --template-file "$WORK/main.bicep" \
  --parameters "${PARAMS[@]}" -o none
az deployment sub show --name "$NAME" --query "properties.outputs" -o jsonc

# Read back through a different path than the one that wrote it.
echo "[VERIFY] VMs and power state:"
az vm list -g "$RG" -d --query "[].{name:name, power:powerState, ip:publicIps}" -o table
echo "[VERIFY] listener answers from outside the VM:"
for ip in $(az vm list -g "$RG" -d --query "[].publicIps" -o tsv); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://$ip/" || true)"
  echo "  http://$ip/ -> $code (cloud-init can take a few minutes; 200 is the goal)"
done
echo "[WAIT] Give Defender for Cloud at least 24 hours, better 48, to scan before you look for the attack path."
echo "[NEXT] Check progress: pwsh ./C3M01VulnerabilityEvidence.ps1, then the queries in C3M01-ExposureGraphCheck.kql."
echo "[NEXT] Defender portal: Settings > Microsoft Defender XDR > Rules > Critical asset management. Confirm a rule classifies $TARGET_ST as a critical asset. If one already does, don't add a duplicate."
echo "[COST] The VMs bill until you tear the lab down: MODE=teardown TARGET_ST=$TARGET_ST bash Deploy-C3M01AttackPath.cloudshell.sh"
