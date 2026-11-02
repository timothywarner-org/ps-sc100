// =============================================================================
// SC-100 Course 1, Module 3 lab: Globomantics landing zones (management group scope)
//
// The hierarchy behind the demo "Two landing zones, one template, two answers":
//
//   Globomantics                  <- org-wide rule: Allowed locations (Deny)
//   └── Landing zones
//       ├── Corp                  <- Storage public access (Deny)
//       └── Online                <- Storage public access (Audit)  <- your subscription
//
// Deploy it with Deploy-C1M03LandingZones.ps1, which creates the top group first (a
// management-group deployment can't create its own target), records where your
// subscription sat before the lab, and deploys this file AT the top group. Then
// Invoke-C1M03Workload.ps1 runs one workload template twice: it succeeds while your
// subscription sits in Online, and it's denied after the subscription moves to Corp.
//
// WHY THIS SHAPE, AND WHY ONLY FOUR GROUPS
//   Microsoft's full Azure landing zone architecture also has Platform (Identity,
//   Management, Connectivity), Sandbox and Decommissioned groups. They're real, and
//   none of them carries an assignment this lab reads. Every group here either holds
//   an assignment or is the parent that makes inheritance visible.
//   https://learn.microsoft.com/azure/cloud-adoption-framework/ready/landing-zone/
//
// WHY ONE DEFINITION ASSIGNED TWICE
//   Deny and Audit aren't a maturity ladder where Audit is the timid setting. They
//   match workload exposure. Corp is internal, so a public blob endpoint is a design
//   error and the platform prevents it. Online is internet-facing, so a public blob
//   endpoint is the business, and the platform records it instead.
//
// WHY THE ORG-WIDE LOCATION RULE STAYS
//   It's the layer that makes "layered" visible. Allowed locations sits on the top
//   group and both archetypes inherit it; the storage rules sit on the archetypes and
//   only their own subscriptions get them. Some rules are about who you are, and some
//   are about where you live.
//
// WHY MANAGEMENT GROUP SCOPE AND NOT TENANT SCOPE
//   A tenant-scope template needs rights at the Tenant Root Group, which means the
//   Microsoft Entra "elevate access" toggle: a standing, tenant-wide User Access
//   Administrator grant. By default any signed-in user may create a management group
//   under the root and becomes its Owner, so the script creates the top group and
//   everything below it is declared here with no elevation anywhere.
//
// WHAT THIS FILE REFUSES TO DO
//   No custom definition, no initiative, no remediation task, no landing zone
//   accelerator, no subscription vending. Each would make the lab about the tool
//   instead of the architecture.
// =============================================================================

targetScope = 'managementGroup'

@description('ID of the top Globomantics management group. This template is deployed AT this group, which must already exist.')
@minLength(1)
@maxLength(90)
param platformMgId string = 'mg-globomantics'

@description('Parent of the two archetypes. It exists so the org-wide rule sits two hops above the subscription, which is what makes "inherited" look different from "assigned here" in the portal.')
param landingZonesMgId string = 'mg-globomantics-landingzones'

@description('Corp archetype. Internal workloads, no public exposure.')
param corpMgId string = 'mg-globomantics-corp'

@description('Online archetype. Internet-facing workloads, public exposure expected.')
param onlineMgId string = 'mg-globomantics-online'

@description('Your subscription, which plays the application landing zone. No default on purpose: the deploy script passes the subscription your Azure CLI is signed in to. Pass an empty string to build the hierarchy without moving any subscription.')
param governedSubscriptionId string

@description('Which archetype the subscription starts in. The lab opens in Online, because the first deployment has to SUCCEED before the denied one means anything.')
@allowed([
  'online'
  'corp'
])
param startingArchetype string = 'online'

@description('Regions the org-wide Deny permits. Every region your subscription already uses should be on this list, or those resources become non-compliant and can no longer be updated.')
@minLength(1)
param allowedLocations array = [
  'eastus2'
  'eastus'
]

@description('Where your subscription sat before the lab moved it. The template only records it in the deployment history, so Remove can put the subscription back exactly where it was.')
param originalParentMgId string = ''

// Built-in "Allowed locations" (Audit, Deny or Disabled through its effect parameter).
// It excludes resource groups, which is why the workload's resource group is never
// what this rule refuses.
// https://learn.microsoft.com/azure/governance/policy/samples/built-in-policies#general
var allowedLocationsDefinitionId = '/providers/Microsoft.Authorization/policyDefinitions/e56962a6-4747-49cd-b67b-bf8b01975c4c'

// ===========================================================================
// HIERARCHY
// Management groups are tenant-level resources whatever scope the deployment runs
// at, hence scope: tenant(). The parent link is what makes a group a CHILD rather
// than another sibling under the root.
// ===========================================================================

resource landingZonesMg 'Microsoft.Management/managementGroups@2023-04-01' = {
  scope: tenant()
  name: landingZonesMgId
  properties: {
    displayName: 'Globomantics - Landing zones'
    details: {
      parent: {
        id: tenantResourceId('Microsoft.Management/managementGroups', platformMgId)
      }
    }
  }
}

// THE TWO ARCHETYPES. Everything the lab shows hangs off these being siblings with
// different rules.
resource corpMg 'Microsoft.Management/managementGroups@2023-04-01' = {
  scope: tenant()
  name: corpMgId
  properties: {
    displayName: 'Globomantics - Corp'
    details: {
      parent: {
        id: tenantResourceId('Microsoft.Management/managementGroups', landingZonesMgId)
      }
    }
  }
  dependsOn: [
    landingZonesMg
  ]
}

resource onlineMg 'Microsoft.Management/managementGroups@2023-04-01' = {
  scope: tenant()
  name: onlineMgId
  properties: {
    displayName: 'Globomantics - Online'
    details: {
      parent: {
        id: tenantResourceId('Microsoft.Management/managementGroups', landingZonesMgId)
      }
    }
  }
  dependsOn: [
    landingZonesMg
  ]
}

// The subscription's placement. This ONE line is the security control the lab is
// about, which is why it's separate from every assignment: the rules shouldn't
// depend on which subscriptions happen to sit under them today.
// Bicep's `parent` accepts only a direct resource reference, never an expression, so
// the archetype choice is two mutually exclusive conditional resources. Verbose, but
// it reads better: these are the two states the workload script moves between.
resource placeInOnline 'Microsoft.Management/managementGroups/subscriptions@2023-04-01' = if (!empty(governedSubscriptionId) && startingArchetype == 'online') {
  parent: onlineMg
  name: governedSubscriptionId
}

resource placeInCorp 'Microsoft.Management/managementGroups/subscriptions@2023-04-01' = if (!empty(governedSubscriptionId) && startingArchetype == 'corp') {
  parent: corpMg
  name: governedSubscriptionId
}

// ===========================================================================
// RULES
//
// The descriptions and non-compliance messages below avoid apostrophes on purpose.
// Azure quotes a non-compliance message in single quotes inside the denial error,
// and Invoke-C1M03Workload.ps1 reads the message back out of that quoted span, so
// an apostrophe would cut the message short. The Corp message keeps the wording
// you see in the course video.
// ===========================================================================

// Layer 1, org-wide. No `scope:` property, so it attaches to the deployment target,
// the TOP group. Both archetypes inherit it.
resource denyAllowedLocations 'Microsoft.Authorization/policyAssignments@2025-03-01' = {
  name: 'deny-allowed-locations'
  properties: {
    displayName: 'Globomantics - Allowed locations (Deny)'
    description: 'Globomantics platform guardrail. Resources deploy to approved regions only. Assigned once at the top management group and inherited by every landing zone beneath it, including subscriptions created later.'
    policyDefinitionId: allowedLocationsDefinitionId
    // 'Default' is what the portal labels "Enabled". 'DoNotEnforce' (portal: Disabled)
    // evaluates without blocking anything.
    // https://learn.microsoft.com/azure/governance/policy/concepts/assignment-structure#enforcement-mode
    enforcementMode: 'Default'
    parameters: {
      listOfAllowedLocations: {
        value: allowedLocations
      }
      effect: {
        value: 'Deny'
      }
    }
    nonComplianceMessages: [
      {
        message: 'Globomantics platform policy: this region is outside the approved list. Approved regions: ${join(allowedLocations, ', ')}. This guardrail is inherited from the platform management group, not set on your subscription, so contact the platform team, not your subscription owner.'
      }
    ]
    metadata: {
      course: 'SC-100 Course 1 Module 3'
      layer: 'organization-wide'
    }
  }
}

// Layer 2, archetype-specific. Same definition, two effects, two scopes. This pair
// IS the lab.
module corpStoragePolicy 'modules/archetype-storage-policy.bicep' = {
  name: 'corp-storage-public-deny'
  scope: managementGroup(corpMgId)
  params: {
    assignmentName: 'deny-storage-public'
    assignmentDisplayName: 'Globomantics Corp - Storage public access (Deny)'
    effect: 'Deny'
    assignmentDescription: 'Corp landing zones host internal workloads only. A publicly accessible blob endpoint is a design error here, so the platform prevents it rather than reporting it.'
    nonComplianceMessage: 'Globomantics Corp landing zone policy: storage accounts in Corp cannot allow public blob access. If this workload genuinely needs a public endpoint, it belongs in an Online landing zone - that is a subscription placement conversation with the platform team, not a policy exception.'
  }
  dependsOn: [
    corpMg
  ]
}

module onlineStoragePolicy 'modules/archetype-storage-policy.bicep' = {
  name: 'online-storage-public-audit'
  scope: managementGroup(onlineMgId)
  params: {
    assignmentName: 'audit-storage-public'
    assignmentDisplayName: 'Globomantics Online - Storage public access (Audit)'
    effect: 'Audit'
    assignmentDescription: 'Online landing zones host internet-facing workloads where a public blob endpoint is a legitimate business requirement. The platform records exposure here instead of blocking it, so the inventory stays honest.'
    nonComplianceMessage: 'Globomantics Online landing zone policy: this storage account allows public blob access. That is permitted in an Online landing zone and it is recorded here on purpose, so the platform team can see every public endpoint the organization owns.'
  }
  dependsOn: [
    onlineMg
  ]
}

output landingZonesManagementGroupId string = landingZonesMg.name
output corpManagementGroupId string = corpMg.name
output onlineManagementGroupId string = onlineMg.name
output governedSubscriptionId string = governedSubscriptionId
output startingArchetype string = startingArchetype
output originalParentMgId string = originalParentMgId
output locationsAssignmentId string = denyAllowedLocations.id
output corpAssignmentId string = corpStoragePolicy.outputs.assignmentId
output onlineAssignmentId string = onlineStoragePolicy.outputs.assignmentId
