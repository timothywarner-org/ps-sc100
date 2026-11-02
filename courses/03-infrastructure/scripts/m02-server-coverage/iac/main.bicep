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
