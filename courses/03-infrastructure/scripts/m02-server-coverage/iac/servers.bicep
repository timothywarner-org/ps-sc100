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
