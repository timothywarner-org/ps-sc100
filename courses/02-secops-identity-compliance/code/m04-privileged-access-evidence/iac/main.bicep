// SC-100 Course 2, Module 4 lab: the Defender CSPM plan with its permissions management extension.
//
// SUBSCRIPTION scope. The second half of the Module 4 demo reads an identity and access finding in
// Microsoft Defender for Cloud. Findings like it come from the Defender CSPM plan, and the
// permissions management extension adds cloud infrastructure entitlement management (CIEM). This
// file turns on that one plan with that one extension, and nothing else.
//
// THE WAIT IS THE LONG POLE, NOT THE DEPLOY. Defender for Cloud assesses on its own cycle, roughly
// 12 to 24 hours, so a finding can't appear the moment the plan turns on.
//
// COST: Defender CSPM is a paid plan billed per billable resource in the subscription. The deploy
// script turns it back to Free on Remove.
//
// Deploy it with Deploy-C2M04Cspm.ps1, which checks the plan's current state first.

targetScope = 'subscription'

resource cspm 'Microsoft.Security/pricings@2024-01-01' = {
  // CloudPosture is the API name of the Defender CSPM plan.
  name: 'CloudPosture'
  properties: {
    pricingTier: 'Standard'
    extensions: [
      {
        // The API still calls the CIEM extension EntraPermissionsManagement. The standalone product
        // of that name is retired; the capability now lives in Defender for Cloud.
        name: 'EntraPermissionsManagement'
        isEnabled: 'True'
      }
    ]
  }
}

output cloudPostureTier string = cspm.properties.pricingTier
