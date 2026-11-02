// SC-100 Course 2, Module 1 lab: one Microsoft Sentinel workspace, one synthetic investigation and
// three mapping-only rules, all for the fictional Globomantics.
//
// Every event here is synthetic. The lab demonstrates the investigation surface in the Microsoft
// Defender portal: one incident, its alert, and the Account, Host and URL entities you pivot on. It
// DOESN'T demonstrate native Microsoft Defender XDR correlation, live connector telemetry or real
// detection coverage, and the rule descriptions say so, so the disclosure travels with the evidence.
//
// Deploy it with Deploy-C2M01Investigation.ps1, which supplies the seed time.

@description('Region for the workspace. The deploy script passes the resource group region.')
param location string = resourceGroup().location

@description('Dedicated lab workspace. Never point this at a production workspace.')
param workspaceName string = 'law-glb-c2m01'

@description('Fixed UTC seed time, yyyy-MM-ddTHH:mm:ssZ. Keep it on reruns; change it only to replay the exercise.')
param fixtureStartUtc string

@description('False turns every lab rule off without deleting the incident it already produced.')
param rulesEnabled bool = true

// Pay-as-you-go with 30-day retention. The lab ingests almost nothing: the only rows it writes are
// the alert and incident records Sentinel creates.
resource law 'Microsoft.OperationalInsights/workspaces@2025-02-01' = {
  name: workspaceName
  location: location
  tags: {
    course: 'SC100-C2M01'
    company: 'Globomantics'
    purpose: 'synthetic-investigation'
  }
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// Onboarding is what turns a Log Analytics workspace into a Microsoft Sentinel workspace.
resource onboarding 'Microsoft.SecurityInsights/onboardingStates@2025-06-01' = {
  name: 'default'
  scope: law
  properties: {
    customerManagedKey: false
  }
}

// MAP ONLY rules: real technique metadata over a query that can never return a row. On the MITRE
// ATT&CK page these techniques look covered, and that's the trap the demo exposes. Active tells
// you a rule is enabled; mapped tells you which technique it claims; only a tested detection is
// evidence.
var coverage = [
  {
    key: 'glob-rule-credaccess'
    title: 'GLOB MAP ONLY Password spray'
    tactic: 'CredentialAccess'
    technique: 'T1110'
  }
  {
    key: 'glob-rule-latmove'
    title: 'GLOB MAP ONLY Lateral movement'
    tactic: 'LateralMovement'
    technique: 'T1021'
  }
  {
    key: 'glob-rule-exfil'
    title: 'GLOB MAP ONLY Storage exfiltration'
    tactic: 'Exfiltration'
    technique: 'T1567'
  }
]

resource rules 'Microsoft.SecurityInsights/alertRules@2025-06-01' = [for rule in coverage: {
  // guid() makes the rule ID deterministic, so a rerun updates the same rule instead of adding one.
  name: guid(resourceGroup().id, rule.key)
  scope: law
  kind: 'Scheduled'
  dependsOn: [
    onboarding
  ]
  properties: {
    displayName: rule.title
    description: 'SC100-C2M01 MAP ONLY. Empty query. Technique mapping alone proves no detection coverage.'
    enabled: rulesEnabled
    severity: 'Informational'
    query: 'datatable(TimeGenerated:datetime)[]'
    queryFrequency: 'PT1H'
    queryPeriod: 'PT1H'
    triggerOperator: 'GreaterThan'
    triggerThreshold: 0
    suppressionEnabled: false
    suppressionDuration: 'PT1H'
    tactics: [
      rule.tactic
    ]
    techniques: [
      rule.technique
    ]
    incidentConfiguration: {
      createIncident: false
    }
  }
}]

resource investigation 'Microsoft.SecurityInsights/alertRules@2025-06-01' = {
  name: guid(resourceGroup().id, 'glob-synthetic-investigation')
  scope: law
  kind: 'Scheduled'
  dependsOn: [
    onboarding
  ]
  properties: {
    displayName: 'GLOB SYNTHETIC Identity endpoint ERP investigation'
    description: 'SC100-C2M01 SYNTHETIC. Three fictional observations, one Sentinel analytics alert. No real compromise, connectors or native XDR correlation.'
    enabled: rulesEnabled
    severity: 'High'
    query: replace(loadTextContent('investigation.kql'), '__FIXTURE_START__', fixtureStartUtc)
    queryFrequency: 'PT5M'
    queryPeriod: 'PT30M'
    triggerOperator: 'GreaterThan'
    triggerThreshold: 0
    // Suppression outlasts the 30-minute data window, so the lab raises one alert, not one every
    // five minutes.
    suppressionEnabled: true
    suppressionDuration: 'PT1H'
    eventGroupingSettings: {
      aggregationKind: 'SingleAlert'
    }
    incidentConfiguration: {
      createIncident: true
    }
    // Custom details store the observations inside the alert, so the evidence is still readable
    // after the seed window closes and the query itself returns nothing.
    customDetails: {
      TrainingData: 'EvidenceType'
      SignalExamples: 'Signal'
      Observations: 'Observation'
    }
    entityMappings: [
      {
        entityType: 'Account'
        fieldMappings: [
          {
            identifier: 'Name'
            columnName: 'AccountName'
          }
          {
            identifier: 'UPNSuffix'
            columnName: 'AccountSuffix'
          }
        ]
      }
      {
        entityType: 'Host'
        fieldMappings: [
          {
            identifier: 'HostName'
            columnName: 'HostName'
          }
          {
            identifier: 'DnsDomain'
            columnName: 'DnsDomain'
          }
        ]
      }
      {
        entityType: 'URL'
        fieldMappings: [
          {
            identifier: 'Url'
            columnName: 'ResourceUrl'
          }
        ]
      }
    ]
  }
}

output workspaceId string = law.id
output workspaceName string = law.name
output investigationRuleId string = investigation.id
output fixtureStartUtc string = fixtureStartUtc
