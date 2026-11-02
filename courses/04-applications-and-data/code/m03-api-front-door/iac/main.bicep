// SC-100 Course 4, Module 3 lab: the Globomantics Connected Equipment API behind Azure Front Door
// Premium and its web application firewall (WAF), with Azure API Management checking the partner's
// token and the Front Door ID, and a pipeline identity that federates with GitHub instead of holding
// a secret.
//
// WHY THIS SHAPE. Each layer of the design is one resource you can read in the portal:
//   The edge       a WAF policy in Prevention mode with the Default Rule Set, Bot Manager and one
//                  rate-limit rule, attached to the Front Door endpoint
//   The gateway    the Cancel order operation's inbound policy (check-header, validate-jwt and
//                  rate-limit-by-key), answered by a mock so there's no backend to pay for
//   The pipeline   a user-assigned managed identity with one GitHub federated credential
// Plus one piece of evidence: a Log Analytics workspace that receives the WAF log, so you can prove a
// blocked request was also logged.
//
// Deploy it with Deploy-C4M03ApiFrontDoor.ps1, which passes your tenant ID as a secure parameter so it
// never lands in the deployment history or in a readable API Management named value.
// API versions were current when this lab was written (October 2026).

targetScope = 'resourceGroup'

@description('Region for API Management, the managed identity and the workspace. Front Door, its endpoint and the WAF policy are global resources.')
param location string = resourceGroup().location

@description('Deterministic suffix for the one globally unique name (API Management). The same group always yields the same name, which is what makes a rerun converge instead of duplicating.')
@minLength(4)
@maxLength(13)
param suffix string = take(uniqueString(resourceGroup().id), 6)

@description('Microsoft Entra tenant whose tokens validate-jwt accepts. Stored as a SECRET named value, so the portal shows it masked.')
@secure()
param tokenTenantId string

@description('Audience the partner application tokens must carry. An app ID URI, not a tenant or object ID, so it is safe to show.')
param apiAudience string = 'api://glb-connected-equipment-api'

@description('Publisher contact address that API Management requires at creation. Use an address you own.')
param publisherEmail string

param publisherName string = 'Globomantics'

@description('Default Rule Set version for Front Door. 2.2 was the newest when this lab was written; check the managed rule set list for a later one.')
param defaultRuleSetVersion string = '2.2'

@description('Bot Manager rule set version. 1.1 was the newest when this lab was written.')
param botManagerRuleSetVersion string = '1.1'

@description('Edge rate limit per client IP per minute. Illustrative, like the gateway\'s 60 calls a minute per token subject, not production sizing.')
@minValue(10)
param edgeRateLimitPerMinute int = 100

var tags = {
  course: 'SC100-C4M03'
  company: 'Globomantics'
  purpose: 'course-lab'
  teardown: 'after-course'
}

// The policy lives beside this file, so the XML you read in the portal is the XML in this folder.
var cancelOrderPolicyXml = loadTextContent('cancel-order-policy.xml')

// ------------------------------------------------------------------ the gateway
resource apim 'Microsoft.ApiManagement/service@2024-05-01' = {
  name: 'apim-glb-c4m03-${suffix}'
  location: location
  tags: tags
  sku: {
    name: 'Developer' // the cheapest tier with the full policy engine; no SLA, which a lab doesn't need
    capacity: 1
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
  }
}

// Named values keep environment facts out of the policy text. The tenant is secret, so the Named
// values blade masks it; the audience and Front Door ID aren't secrets and stay readable, which lets
// you compare the Front Door ID by eye.
resource nvTenant 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'glb-tenant-id'
  properties: {
    displayName: 'glb-tenant-id'
    value: tokenTenantId
    secret: true
  }
}

resource nvAudience 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'glb-api-audience'
  properties: {
    displayName: 'glb-api-audience'
    value: apiAudience
    secret: false
  }
}

resource nvAfdId 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'glb-afd-id'
  properties: {
    displayName: 'glb-afd-id'
    // frontDoorId is the value Front Door stamps into X-Azure-FDID on every request it forwards.
    // Reading it from the profile, not typing it, means the check can't drift from the edge.
    value: afd.properties.frontDoorId
    secret: false
  }
}

resource api 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'connected-equipment-api'
  properties: {
    displayName: 'Connected Equipment API'
    description: 'Partner-facing order operations for Globomantics connected equipment.'
    path: 'connected-equipment'
    protocols: [
      'https'
    ]
    apiType: 'http'
    // No subscription key: the partner's Entra token is the credential. With a key required,
    // API Management would answer 401 for a missing key before the policy ever ran, and you'd be
    // testing the wrong control.
    subscriptionRequired: false
  }
}

resource cancelOrder 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'cancel-order'
  properties: {
    displayName: 'Cancel order'
    method: 'POST'
    urlTemplate: '/orders/{id}/cancel'
    templateParameters: [
      {
        name: 'id'
        type: 'string'
        required: true
        description: 'The order number.'
      }
    ]
    responses: [
      {
        statusCode: 202
        description: 'Cancellation accepted.'
        representations: [
          {
            contentType: 'application/json'
            // mock-response prefers an example over a schema, so this is what a caller with a valid
            // token gets back. No backend, no backend bill.
            examples: {
              default: {
                value: {
                  orderId: '1042'
                  status: 'cancellation-accepted'
                }
              }
            }
          }
        ]
      }
    ]
  }
}

resource cancelOrderPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: cancelOrder
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: cancelOrderPolicyXml
  }
  // API Management refuses a policy that references a named value that doesn't exist yet.
  dependsOn: [
    nvTenant
    nvAudience
    nvAfdId
  ]
}

// ------------------------------------------------------------------ the edge
resource afd 'Microsoft.Cdn/profiles@2025-06-01' = {
  name: 'afd-glb-c4m03'
  location: 'global'
  tags: tags
  sku: {
    name: 'Premium_AzureFrontDoor' // Premium is the tier that carries the managed rule sets and Bot Manager
  }
  properties: {
    originResponseTimeoutSeconds: 60
  }
}

resource endpoint 'Microsoft.Cdn/profiles/afdEndpoints@2025-06-01' = {
  parent: afd
  name: 'connected-equipment'
  location: 'global'
  tags: tags
  properties: {
    enabledState: 'Enabled'
  }
}

resource originGroup 'Microsoft.Cdn/profiles/originGroups@2025-06-01' = {
  parent: afd
  name: 'apim-gateway'
  properties: {
    loadBalancingSettings: {
      sampleSize: 4
      successfulSamplesRequired: 3
      additionalLatencyInMilliseconds: 50
    }
    // No health probe: with a single origin there's nothing to fail over to, and Microsoft's
    // guidance is to turn probes off in that case rather than pay for probe traffic.
    sessionAffinityState: 'Disabled'
  }
}

resource origin 'Microsoft.Cdn/profiles/originGroups/origins@2025-06-01' = {
  parent: originGroup
  name: 'apim-glb-c4m03'
  properties: {
    hostName: replace(apim.properties.gatewayUrl, 'https://', '')
    originHostHeader: replace(apim.properties.gatewayUrl, 'https://', '')
    httpPort: 80
    httpsPort: 443
    priority: 1
    weight: 1000
    enabledState: 'Enabled'
    enforceCertificateNameCheck: true
  }
}

resource waf 'Microsoft.Network/FrontDoorWebApplicationFirewallPolicies@2025-03-01' = {
  name: 'glbConnectedEquipmentWaf' // Front Door WAF policy names allow letters and digits only
  location: 'global'
  tags: tags
  sku: {
    name: 'Premium_AzureFrontDoor' // must match the profile's tier, or the security policy won't link
  }
  properties: {
    policySettings: {
      enabledState: 'Enabled'
      mode: 'Prevention' // blocking, not just logging
      requestBodyCheck: 'Enabled'
    }
    customRules: {
      rules: [
        {
          // Custom rules run before managed rules, lowest priority number first. This one caps any
          // single client IP on the order paths before the gateway's per-token limit applies.
          name: 'RateLimitPerClientIp'
          priority: 100
          enabledState: 'Enabled'
          ruleType: 'RateLimitRule'
          rateLimitDurationInMinutes: 1
          rateLimitThreshold: edgeRateLimitPerMinute
          groupBy: [
            {
              variableName: 'SocketAddr'
            }
          ]
          matchConditions: [
            {
              matchVariable: 'RequestUri'
              operator: 'Contains'
              negateCondition: false
              matchValue: [
                '/orders/'
              ]
              transforms: []
            }
          ]
          action: 'Block'
        }
      ]
    }
    managedRules: {
      managedRuleSets: [
        {
          ruleSetType: 'Microsoft_DefaultRuleSet'
          ruleSetVersion: defaultRuleSetVersion
          ruleSetAction: 'Block' // DRS 2.x scores anomalies; past the threshold, this is what happens
          ruleGroupOverrides: []
          exclusions: [] // none, until detection-mode testing earns one
        }
        {
          ruleSetType: 'Microsoft_BotManagerRuleSet'
          ruleSetVersion: botManagerRuleSetVersion
          ruleGroupOverrides: []
          exclusions: []
        }
      ]
    }
  }
}

resource securityPolicy 'Microsoft.Cdn/profiles/securityPolicies@2025-06-01' = {
  parent: afd
  name: 'connected-equipment-waf'
  properties: {
    parameters: {
      type: 'WebApplicationFirewall'
      wafPolicy: {
        id: waf.id
      }
      associations: [
        {
          domains: [
            {
              id: endpoint.id
            }
          ]
          patternsToMatch: [
            '/*'
          ]
        }
      ]
    }
  }
}

// ------------------------------------------------------------------ the evidence: WAF logs
// Front Door's WAF, access and health probe logs are OFF by default, and a diagnostic setting turns
// them on (see the Front Door WAF monitoring page on Microsoft Learn). Only the WAF category is sent,
// because that's the one record the test needs. Ingestion is billed per GB after a monthly free
// allowance, and a lab writes kilobytes.
resource wafLogs 'Microsoft.OperationalInsights/workspaces@2025-07-01' = {
  name: 'law-glb-c4m03'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30 // the minimum for this SKU
  }
}

// The "-preview" is the API version's label; diagnostic settings themselves are generally available.
resource afdDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: afd
  name: 'send-waf-logs'
  properties: {
    workspaceId: wafLogs.id
    // No logAnalyticsDestinationType: entries land in AzureDiagnostics, the table Microsoft's own
    // WAF queries read (Category == 'FrontDoorWebApplicationFirewallLog').
    logs: [
      {
        category: 'FrontDoorWebApplicationFirewallLog'
        enabled: true
      }
    ]
  }
}

resource route 'Microsoft.Cdn/profiles/afdEndpoints/routes@2025-06-01' = {
  parent: endpoint
  name: 'connected-equipment-api'
  properties: {
    originGroup: {
      id: originGroup.id
    }
    supportedProtocols: [
      'Http'
      'Https'
    ]
    patternsToMatch: [
      '/*'
    ]
    forwardingProtocol: 'HttpsOnly'
    linkToDefaultDomain: 'Enabled'
    httpsRedirect: 'Enabled'
    // No cacheConfiguration: an order-cancel API must never be served from cache.
  }
  // The route is what opens the endpoint to traffic, so it waits for the origin, for the WAF to be
  // attached, and for the WAF log to have somewhere to go. There's never a moment when the API is
  // reachable without inspection, or inspected without a record.
  dependsOn: [
    origin
    securityPolicy
    afdDiagnostics
  ]
}

// ------------------------------------------------------------------ the pipeline
resource pipelineIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: 'id-glb-ce-pipeline'
  location: location
  tags: tags
}

// The subject pins ONE repository AND one GitHub environment, so a pull request branch can't mint a
// token for production. The repository name is fictional; change it to yours if you wire up a real
// workflow.
resource productionCredential 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2024-11-30' = {
  parent: pipelineIdentity
  name: 'glb-ce-production'
  properties: {
    issuer: 'https://token.actions.githubusercontent.com'
    subject: 'repo:globomantics/connected-equipment-api:environment:production'
    audiences: [
      'api://AzureADTokenExchange'
    ]
  }
}
// No role assignment, on purpose: this lab shows how the pipeline proves who it is, and what it may
// touch is a separate decision.

output apimName string = apim.name
output gatewayHost string = replace(apim.properties.gatewayUrl, 'https://', '')
output frontDoorId string = afd.properties.frontDoorId
output endpointHost string = endpoint.properties.hostName
output wafPolicyId string = waf.id
output identityId string = pipelineIdentity.id
output workspaceCustomerId string = wafLogs.properties.customerId
