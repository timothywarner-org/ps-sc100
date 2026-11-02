// SC-100 Course 2, Module 5 lab: assign the NIST SP 800-53 R5.1.1 regulatory standard.
//
// SUBSCRIPTION scope. Assigning this built-in initiative is what makes the standard assessable on the
// regulatory compliance dashboard in Microsoft Defender for Cloud, the surface the second half of the
// Module 5 demo reads.
//
// WHY R5.1.1 AND NOT REV. 5. Both initiatives exist in Azure Policy, and either assignment deploys
// cleanly. Defender for Cloud's available-standards table lists NIST SP 800 53 R5.1.1 for Azure, so
// that's the one that renders for an Azure subscription. Assigning the other would give you a green
// deployment and an empty dashboard.
//   https://learn.microsoft.com/azure/defender-for-cloud/concept-regulatory-compliance-standards
//
// EFFECT. The regulatory compliance initiatives are built almost entirely from Audit and Manual
// definitions, so this assignment observes and reports. It denies nothing, and that difference between
// a framework and enforcement is itself part of the lesson.
//
// THE WAIT IS THE LONG POLE. A new standard takes hours to render, and Microsoft documents that a
// standard with no relevant resources in the subscription isn't shown at all, even when it's assigned.
//
// Deploy it with Deploy-C2M05Compliance.ps1, which resolves the initiative's ID live by display name,
// because a hardcoded built-in ID is how a lab quietly goes stale.

targetScope = 'subscription'

@description('Resource ID of the NIST SP 800-53 R5.1.1 built-in initiative, resolved by the deploy script.')
param nistSetDefinitionId string

@description('Assignment name. Subscription-scope assignment names are limited to 24 characters.')
@maxLength(24)
param assignmentName string = 'glb-sc100-nist-r511'

resource nistAssignment 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: assignmentName
  properties: {
    displayName: 'GLB-SC100 Globomantics regulatory baseline: NIST SP 800-53 R5.1.1'
    description: 'SC-100 Course 2 lab. Standard selection follows what law or contract requires; this assignment makes the standard assessable on the Defender for Cloud regulatory compliance dashboard.'
    policyDefinitionId: nistSetDefinitionId
    enforcementMode: 'Default'
  }
}

output assignmentId string = nistAssignment.id
output assignmentName string = nistAssignment.name
