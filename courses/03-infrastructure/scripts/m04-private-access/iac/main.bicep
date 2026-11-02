// =====================================================================================
// SC-100 Course 3, Module 4 lab, Azure half: "Scope vendor access with Microsoft Entra
// Private Access". Deploy it with ../Deploy-C3M04PlantNetwork.ps1, which generates the
// secure parameters below for you.
//
// THE GLOBOMANTICS PLANT NETWORK IN THE DEMO
//   vnet-glb-plant-a 10.40.0.0/16
//     snet-plant-mgmt  10.40.1.0/24   vm-glb-pa-conn01  Windows Server; hosts the Microsoft Entra
//                                                       private network connector (outbound only)
//     snet-line-a      10.40.10.0/24  vm-glb-line-a     the maintenance application, HTTPS 443
//     snet-line-b      10.40.20.0/24  vm-glb-line-b     an unrelated controller HMI the vendor
//                                                       must NOT reach
//   Private DNS zone globomantics.example: maintenance-line-a and hmi-line-b resolve inside the
//   plant, so the Private Access segment can name the FQDN rather than an IP address.
//
// THE FINDING YOU'RE MEANT TO SPOT: which legacy route still needs removal
//   NSG rules still admit the legacy vendor VPN address pool 172.16.50.0/24 to BOTH lines, on
//   443, and on SSH to line B. That's the whole-subnet reach Private Access was meant to replace.
//   It's deliberate, and harmless here: no VPN gateway exists, so nothing can use it.
//
// THE ENTRA HALF (enterprise app, segment, connector group, vendor assignment, Conditional
// Access) is configured by ../Set-C3M04PrivateAccess.ps1 through Microsoft Graph. Azure
// Resource Manager can't create those objects, which is why the lab has two halves.
//
// COST: this template creates billable resources. Its own estimate is about USD 3/day while the
// VMs run (one B2s Windows, two B1s Linux, three disks); check the Azure pricing calculator for
// your region. Every VM shuts down daily at 23:00 Central, but the disks bill until you delete
// the resource group:
//   az group delete --name rg-globomantics-c3m04 --yes --no-wait
// =====================================================================================

targetScope = 'resourceGroup'

param location string = resourceGroup().location

@secure()
@description('Random per deployment and never stored: the connector host is managed with Run Command only.')
param windowsAdminPassword string

@description('Per-run public key from the deploy script; the private half is deleted after deployment.')
param sshPublicKey string

// Every resource carries these tags, and the deploy script refuses to touch a group without them.
var tags = {
  course: 'SC100-C3M04'
  company: 'Globomantics'
  purpose: 'demo-fixture'
  teardown: 'after-course'
}
var legacyVendorVpnPool = '172.16.50.0/24'
var mgmtPrefix = '10.40.1.0/24'

// ---------------------------------------------------------------- network security groups
resource nsgMgmt 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-glb-plant-mgmt'
  location: location
  tags: tags
  // No inbound rules at all: the connector only ever dials OUT to the service.
  properties: { securityRules: [] }
}

resource nsgLineA 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-glb-line-a'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'connector-to-maintenance-https'
        properties: {
          description: 'Private Access path: the connector reaches the maintenance app'
          priority: 100, direction: 'Inbound', access: 'Allow', protocol: 'Tcp'
          sourceAddressPrefix: mgmtPrefix, sourcePortRange: '*'
          destinationAddressPrefix: '*', destinationPortRange: '443'
        }
      }
      {
        name: 'legacy-vendor-vpn-line-a'
        properties: {
          description: 'LEGACY: site-to-site vendor VPN pool. Remove after the Private Access cutover'
          priority: 200, direction: 'Inbound', access: 'Allow', protocol: 'Tcp'
          sourceAddressPrefix: legacyVendorVpnPool, sourcePortRange: '*'
          destinationAddressPrefix: '*', destinationPortRange: '443'
        }
      }
      {
        name: 'deny-other-vnet'
        properties: {
          priority: 4000, direction: 'Inbound', access: 'Deny', protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork', sourcePortRange: '*'
          destinationAddressPrefix: '*', destinationPortRange: '*'
        }
      }
    ]
  }
}

resource nsgLineB 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-glb-line-b'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'plant-mgmt-to-hmi-https'
        properties: {
          description: 'Plant operations reach the HMI from the management subnet'
          priority: 100, direction: 'Inbound', access: 'Allow', protocol: 'Tcp'
          sourceAddressPrefix: mgmtPrefix, sourcePortRange: '*'
          destinationAddressPrefix: '*', destinationPortRange: '443'
        }
      }
      {
        name: 'legacy-vendor-vpn-line-b'
        properties: {
          description: 'LEGACY: site-to-site vendor VPN pool. Remove after the Private Access cutover'
          priority: 200, direction: 'Inbound', access: 'Allow', protocol: 'Tcp'
          sourceAddressPrefix: legacyVendorVpnPool, sourcePortRange: '*'
          destinationAddressPrefix: '*', destinationPortRanges: [ '22', '443' ]
        }
      }
      {
        name: 'deny-other-vnet'
        properties: {
          priority: 4000, direction: 'Inbound', access: 'Deny', protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork', sourcePortRange: '*'
          destinationAddressPrefix: '*', destinationPortRange: '*'
        }
      }
    ]
  }
}

// ---------------------------------------------------------------- plant network
resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-glb-plant-a'
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [ '10.40.0.0/16' ] }
    subnets: [
      // defaultOutboundAccess keeps the connector's outbound HTTPS and the Linux package
      // installs working without the cost of a NAT gateway.
      { name: 'snet-plant-mgmt', properties: { addressPrefix: mgmtPrefix, networkSecurityGroup: { id: nsgMgmt.id }, defaultOutboundAccess: true } }
      { name: 'snet-line-a', properties: { addressPrefix: '10.40.10.0/24', networkSecurityGroup: { id: nsgLineA.id }, defaultOutboundAccess: true } }
      { name: 'snet-line-b', properties: { addressPrefix: '10.40.20.0/24', networkSecurityGroup: { id: nsgLineB.id }, defaultOutboundAccess: true } }
    ]
  }
}

// ---------------------------------------------------------------- hosts
var lines = [
  { name: 'vm-glb-line-a', subnet: 'snet-line-a', ip: '10.40.10.10', host: 'maintenance-line-a', title: 'Globomantics line A maintenance', note: 'Assigned maintenance application' }
  { name: 'vm-glb-line-b', subnet: 'snet-line-b', ip: '10.40.20.10', host: 'hmi-line-b', title: 'Globomantics line B controller HMI', note: 'Not part of any vendor assignment' }
]

resource lineNics 'Microsoft.Network/networkInterfaces@2024-05-01' = [for l in lines: {
  name: 'nic-${l.name}'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [ {
      name: 'ipconfig1'
      properties: {
        privateIPAllocationMethod: 'Static'
        privateIPAddress: l.ip
        subnet: { id: '${vnet.id}/subnets/${l.subnet}' }
      }
    } ]
  }
}]

// cloud-init: nginx serving one labeled page over HTTPS with a self-signed certificate. The
// certificate is only there so the port is really 443/TLS; nothing trusts it and nothing needs to.
resource lineVms 'Microsoft.Compute/virtualMachines@2024-07-01' = [for (l, i) in lines: {
  name: l.name
  location: location
  tags: union(tags, { role: l.host })
  properties: {
    hardwareProfile: { vmSize: 'Standard_B1s' }
    osProfile: {
      computerName: l.host
      adminUsername: 'glbadmin'
      customData: base64(format('''#cloud-config
package_update: true
packages: [nginx, openssl]
write_files:
  - path: /var/www/html/index.html
    content: |
      <!doctype html><title>{0}</title><h1>{0}</h1><p>{1}</p>
  - path: /etc/nginx/sites-available/default
    # Package installation starts nginx before runcmd creates the TLS certificate.
    # Defer the custom TLS config so its first start uses the package's valid defaults.
    defer: true
    content: |
      server {{
        listen 443 ssl default_server;
        ssl_certificate /etc/ssl/certs/glb.crt;
        ssl_certificate_key /etc/ssl/private/glb.key;
        root /var/www/html;
      }}
runcmd:
  - openssl req -x509 -nodes -newkey rsa:2048 -days 365 -subj "/CN={2}.globomantics.example" -keyout /etc/ssl/private/glb.key -out /etc/ssl/certs/glb.crt
  - systemctl restart nginx
''', l.title, l.note, l.host))
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: { publicKeys: [ { path: '/home/glbadmin/.ssh/authorized_keys', keyData: sshPublicKey } ] }
      }
    }
    storageProfile: {
      imageReference: { publisher: 'Canonical', offer: 'ubuntu-24_04-lts', sku: 'server', version: 'latest' }
      osDisk: { createOption: 'FromImage', managedDisk: { storageAccountType: 'Standard_LRS' }, deleteOption: 'Delete' }
    }
    networkProfile: { networkInterfaces: [ { id: lineNics[i].id, properties: { deleteOption: 'Delete' } } ] }
  }
}]

resource connNic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: 'nic-vm-glb-pa-conn01'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [ {
      name: 'ipconfig1'
      properties: {
        privateIPAllocationMethod: 'Static'
        privateIPAddress: '10.40.1.10'
        subnet: { id: '${vnet.id}/subnets/snet-plant-mgmt' }
      }
    } ]
  }
}

resource connector 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: 'vm-glb-pa-conn01'
  location: location
  tags: union(tags, { role: 'private-network-connector' })
  properties: {
    hardwareProfile: { vmSize: 'Standard_B2s' }
    osProfile: {
      computerName: 'glb-pa-conn01'
      adminUsername: 'glbadmin'
      adminPassword: windowsAdminPassword
    }
    storageProfile: {
      imageReference: { publisher: 'MicrosoftWindowsServer', offer: 'WindowsServer', sku: '2022-datacenter-azure-edition-smalldisk', version: 'latest' }
      osDisk: { createOption: 'FromImage', managedDisk: { storageAccountType: 'StandardSSD_LRS' }, deleteOption: 'Delete' }
    }
    networkProfile: { networkInterfaces: [ { id: connNic.id, properties: { deleteOption: 'Delete' } } ] }
  }
}

// Daily shutdown at 23:00 Central so an idle lab can't run all month. Change timeZoneId if you
// like. The connector shows inactive while its host is stopped, so start the VMs before you run
// the review, for example:
//   az vm start --resource-group rg-globomantics-c3m04 --name vm-glb-pa-conn01
var allVms = [ 'vm-glb-pa-conn01', 'vm-glb-line-a', 'vm-glb-line-b' ]
resource shutdown 'Microsoft.DevTestLab/schedules@2018-09-15' = [for vm in allVms: {
  name: 'shutdown-computevm-${vm}'
  location: location
  tags: tags
  dependsOn: [ connector, lineVms ]
  properties: {
    status: 'Enabled'
    taskType: 'ComputeVmShutdownTask'
    dailyRecurrence: { time: '2300' }
    timeZoneId: 'Central Standard Time'
    targetResourceId: resourceId('Microsoft.Compute/virtualMachines', vm)
    notificationSettings: { status: 'Disabled' }
  }
}]

// ---------------------------------------------------------------- plant DNS
resource zone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'globomantics.example'
  location: 'global'
  tags: tags
}

resource zoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: zone
  name: 'link-vnet-glb-plant-a'
  location: 'global'
  tags: tags
  properties: { registrationEnabled: false, virtualNetwork: { id: vnet.id } }
}

resource records 'Microsoft.Network/privateDnsZones/A@2024-06-01' = [for l in lines: {
  parent: zone
  name: l.host
  properties: { ttl: 300, aRecords: [ { ipv4Address: l.ip } ] }
}]

output connectorVm string = connector.name
output maintenanceFqdn string = 'maintenance-line-a.globomantics.example'
output legacyVendorVpnPool string = legacyVendorVpnPool
