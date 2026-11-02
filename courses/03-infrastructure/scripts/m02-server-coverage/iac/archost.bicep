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
