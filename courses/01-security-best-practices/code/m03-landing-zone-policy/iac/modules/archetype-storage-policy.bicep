// =============================================================================
// SC-100 Course 1, Module 3 lab: one archetype's storage exposure guardrail
//
// Deployed once per LANDING ZONE ARCHETYPE by main.bicep, so the SAME built-in
// definition is assigned twice, with two different effects, at two different
// scopes, in one deployment. That's the single fact the lab is built to show.
//
//   Corp   archetype -> effect Deny   -> internal workloads. A public blob endpoint
//                                        is a design error, so the platform
//                                        prevents it.
//   Online archetype -> effect Audit  -> internet-facing workloads. A public blob
//                                        endpoint is the business, so the platform
//                                        records it instead.
//
// WHY THIS IS A MODULE AND NOT TWO INLINE RESOURCES
//   The assignments attach to the Corp and Online groups, neither of which is the
//   deployment's target scope (that's the top Globomantics group, their
//   grandparent). Bicep reaches another management group with a module and
//   `scope: managementGroup(<id>)`. Inline resources would attach to the target
//   scope instead, which would silently give BOTH archetypes the same rule and
//   erase the entire point.
// =============================================================================

targetScope = 'managementGroup'

@description('Resource name of the assignment. Fixed, so the scripts can find it by name.')
@minLength(1)
@maxLength(64)
param assignmentName string

@description('What the portal Assignments blade shows.')
param assignmentDisplayName string

@description('Effect for this archetype. Deny for Corp, Audit for Online. This single parameter IS the archetype difference.')
@allowed([
  'Audit'
  'Deny'
  'Disabled'
])
param effect string

@description('Assignment description.')
param assignmentDescription string

@description('The message a developer sees when this assignment blocks them, or when a resource reports non-compliant.')
param nonComplianceMessage string

// Built-in "Storage account public access should be disallowed". Audit, Deny or
// Disabled through its effect parameter, default Audit.
// https://learn.microsoft.com/azure/governance/policy/samples/built-in-policies#storage
var storagePublicAccessDefinitionId = '/providers/Microsoft.Authorization/policyDefinitions/4fa4b6c0-31ca-4c0d-b10d-24b96f62a751'

resource archetypeAssignment 'Microsoft.Authorization/policyAssignments@2025-03-01' = {
  name: assignmentName
  properties: {
    displayName: assignmentDisplayName
    description: assignmentDescription
    policyDefinitionId: storagePublicAccessDefinitionId
    // 'Default' is what the portal labels "Enabled". Both archetypes run enforced,
    // because an Audit assignment in DoNotEnforce mode still evaluates but a Deny
    // assignment in that mode blocks nothing, and the Corp half of the lab would
    // quietly stop working.
    enforcementMode: 'Default'
    parameters: {
      effect: {
        value: effect
      }
    }
    nonComplianceMessages: [
      {
        message: nonComplianceMessage
      }
    ]
    metadata: {
      course: 'SC-100 Course 1 Module 3'
      archetypeEffect: effect
    }
  }
}

output assignmentId string = archetypeAssignment.id
output assignmentDisplayName string = assignmentDisplayName
output effect string = effect
