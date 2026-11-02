# SC-100 skills measured, mapped to this skill path

This page holds every objective Microsoft tests on **Exam SC-100: Microsoft Cybersecurity
Architect**, quoted word for word from the official study guide, with the course in this path that
teaches each domain. Use it as your checklist: if you can't explain what an architect would
recommend for a bullet, and why, that bullet is your next study session.

| | |
|---|---|
| **Exam** | SC-100: Microsoft Cybersecurity Architect |
| **Credential** | Microsoft Certified: Cybersecurity Architect Expert |
| **Skills measured as of** | **October 21, 2026** |
| **Checked against the live study guide** | Monday, November 2, 2026, 8:25 AM CST |
| **Source** | [SC-100 study guide](https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/sc-100) |
| **Passing score** | 700 |

Microsoft doesn't publish question counts, question types or time limits, so this page doesn't
either. To see the exam interface before test day, try the [exam sandbox](https://aka.ms/examdemo).

## Where each domain is taught

Each course in the path owns one exam domain.

| Domain | Weight | Course in this path |
|---|---|---|
| 1. Design solutions that align with security best practices and priorities | 20-25% | [Course 1: SC-100: Designing Solutions with Security Best Practices](../courses/01-security-best-practices/) |
| 2. Design security operations, identity, and compliance capabilities | 25-30% | [Course 2: SC-100: Designing Security Operations, Identity, and Compliance Capabilities](../courses/02-secops-identity-compliance/) |
| 3. Design security solutions for infrastructure | 25-30% | [Course 3: SC-100: Designing Security Solutions for Infrastructure](../courses/03-infrastructure/) |
| 4. Design security solutions for applications and data | 20-25% | [Course 4: SC-100: Designing Security Solutions for Applications and Data](../courses/04-applications-and-data/) |

**Domains 2 and 3 together carry 50 to 60 percent of your score**, so budget your study time that
way. Domain 3 is tied for the heaviest even though Microsoft Learn numbers its learning path last.

## Audience profile (verbatim)

As a Microsoft cybersecurity architect, you translate a cybersecurity strategy into capabilities that protect the assets, business, and operations of an organization. You design, guide the implementation of, and maintain security solutions that follow Zero Trust principles and best practices, including security strategies for identity, devices, data, AI, applications, network, infrastructure, and DevOps. Plus, you design solutions for Governance, Risk, and Compliance (GRC), security operations, and security posture management.

As a cybersecurity architect, you continuously collaborate with leaders and practitioners in security, privacy, engineering, and other roles across an organization to plan and implement a cybersecurity strategy that meets the business needs of an organization.

As a candidate for this exam, you have experience implementing or administering solutions in the following areas: identity and access, platform protection, security operations, data and AI security, application security, and hybrid and multicloud infrastructures. You should have expert skills in at least one of those areas, and you should have experience designing security solutions that include Microsoft security technologies.

> **Microsoft's own caveat:** "The bullets that follow each of the skills measured are intended to
> illustrate how we are assessing that skill. Related topics may be covered in the exam." And:
> "Most questions cover features that are general availability (GA). The exam may contain
> questions on Preview features if those features are commonly used."

---

## Domain 1: Design solutions that align with security best practices and priorities (20-25%)

### 1.1 Design a resiliency strategy for ransomware and other attacks based on Microsoft Security Best Practices

- Design a security strategy to support business resiliency goals, including identifying and prioritizing threats to business-critical assets
- Design solutions for business continuity and disaster recovery (BCDR), including secure backup and restore for hybrid and multicloud environments
- Design solutions for mitigating ransomware attacks, including prioritization of BCDR and privileged access
- Evaluate solutions for security updates

### 1.2 Design solutions that align with the Microsoft Cybersecurity Reference Architectures (MCRA) and Microsoft Cloud Security Benchmark (MCSB)

- Design solutions that align with best practices for cybersecurity capabilities and controls
- Design solutions that align with best practices for protecting against insider, external, and supply chain attacks
- Design AI solutions that align to the Microsoft Cloud Security Benchmark.
- Design solutions that align with the Zero Trust adoption framework

### 1.3 Design solutions that align with the Microsoft Cloud Adoption Framework for Azure (CAF) and the Azure Well-Architected Framework

- Design a strategy for secure AI adoption
- Design a new or evaluate an existing strategy for security and governance based on the Microsoft Cloud Adoption Framework for Azure (CAF) and the Azure Well-Architected Framework (WAF)
- Recommend solutions for security and governance based on the Microsoft Cloud Adoption Framework for Azure (CAF) and the Azure Well-Architected Framework
- Design solutions for implementing and governing security by using Azure landing zones
- Design a DevSecOps process that aligns with best practices in the Microsoft Cloud Adoption Framework for Azure (CAF)

---

## Domain 2: Design security operations, identity, and compliance capabilities (25-30%)

### 2.1 Design solutions for security operations

- Design a solution for detection and response that includes extended detection and response (XDR) and security information and event management (SIEM)
- Design a solution for centralized logging and auditing, including Microsoft Purview Audit
- Design monitoring to support hybrid and multicloud environments
- Design a solution for security orchestration, automation, and response (SOAR), including Microsoft Sentinel and Microsoft Defender XDR
- Design and evaluate security workflows, including incident response, threat hunting, and incident management
- Design and evaluate threat detection coverage by using MITRE ATT&CK matrices, including Enterprise, Mobile, and industrial control systems (ICS)

### 2.2 Design solutions for identity and access management

- Design a solution for agent identities using Microsoft Entra Agent ID and conditional access policies
- Design a solution for access to software as a service (SaaS), platform as a service (PaaS), infrastructure as a service (IaaS), hybrid/on-premises, and multicloud resources, including identity, networking, and application controls
- Design a solution for Microsoft Entra ID, including hybrid and multi-cloud environments
- Design a solution for external identities, including business-to-business (B2B) and decentralized identity
- Design a modern authentication and authorization strategy, including Conditional Access, continuous access evaluation, risk scoring, and protected actions
- Validate the alignment of Conditional Access policies with a Zero Trust strategy
- Specify requirements to harden Active Directory Domain Services (AD DS)
- Design a solution to manage secrets, keys, and certificates

### 2.3 Design solutions for securing privileged access

- Design a solution for assigning and delegating privileged roles by using the enterprise access model
- Evaluate the security and governance of Microsoft Entra ID, including Microsoft Entra Privileged Identity Management (PIM), entitlement management, and access reviews
- Evaluate the security and governance of Active Directory Domain Services (AD DS), including resilience to common attacks
- Design a solution for securing the administration of cloud tenants, including SaaS and multicloud infrastructure and platforms
- Design a solution for cloud infrastructure entitlement management
- Evaluate an access review management solution
- Design a solution for secure workstations for privileged access, including remote access

### 2.4 Design solutions for regulatory compliance

- Translate compliance requirements into security controls
- Design a solution to address compliance requirements by using Microsoft Purview
- Design Azure Policy solutions to address security and compliance requirements
- Evaluate and validate alignment with regulatory standards and benchmarks by using Microsoft Defender for Cloud

---

## Domain 3: Design security solutions for infrastructure (25-30%)

### 3.1 Design solutions for security posture management in hybrid and multicloud environments

- Evaluate security posture by using Microsoft Defender for Cloud, including the Microsoft Cloud Security Benchmark (MCSB)
- Evaluate security posture by using Microsoft Secure Score
- Design integrated security posture management solutions that include Microsoft Defender for Cloud in hybrid and multi-cloud environments
- Select cloud workload protection solutions in Microsoft Defender for Cloud
- Design a solution for integrating hybrid and multicloud environments by using Azure Arc
- Design a solution for Microsoft Defender External Attack Surface Management (Defender EASM)
- Specify requirements and priorities for a posture management process that uses Microsoft Security Exposure Management attack paths, attack surface reduction, security insights, and initiatives

### 3.2 Specify requirements for securing server and client endpoints

- Specify security requirements for servers, including multiple platforms and operating systems
- Specify security requirements for mobile devices and clients, including endpoint protection, hardening, and configuration
- Specify security requirements for IoT devices and embedded systems
- Evaluate solutions for securing operational technology (OT) and industrial control systems (ICS) by using Microsoft Defender for IoT
- Specify security baselines for server and client endpoints
- Evaluate Windows Local Administrator Password Solution (Windows LAPS) solution

### 3.3 Specify requirements for securing SaaS, PaaS, and IaaS services

- Specify security baselines for SaaS, PaaS, and IaaS services
- Specify security requirements for IoT workloads
- Specify security requirements for web workloads
- Specify security requirements for containers
- Specify security requirements for container orchestration
- Evaluate solutions that include Azure AI services security

### 3.4 Evaluate solutions for network security and Security Service Edge (SSE)

- Evaluate network designs to align with security requirements and best practices
- Evaluate solutions that use Microsoft Entra Internet Access as a secure web gateway
- Evaluate solutions that use Microsoft Entra Internet Access for Microsoft Services, including cross-tenant configurations
- Evaluate solutions that use Microsoft Entra Private Access

---

## Domain 4: Design security solutions for applications and data (20-25%)

### 4.1 Evaluate solutions for securing Microsoft 365

- Evaluate security posture for productivity and collaboration workloads by using metrics, including Microsoft Secure Score
- Evaluate solutions that include Microsoft Defender for Office 365 and Microsoft Defender for Cloud Apps
- Evaluate device management solutions that include Microsoft Intune
- Evaluate solutions for securing data in Microsoft 365 by using Microsoft Purview
- Evaluate data security and compliance controls in Microsoft 365 Copilot

### 4.2 Design solutions for securing applications

- Evaluate the security posture of existing application portfolios
- Evaluate threats to business-critical applications by using threat modeling
- Design and implement a full lifecycle strategy for application security
- Design and implement standards and practices for securing the application development process
- Map technologies to application security requirements
- Design a solution for workload identities to authenticate and access Azure resources
- Design a solution for API management and security
- Design solutions that secure applications by using Azure Web Application Firewall (WAF)

### 4.3 Design solutions for securing an organization's data

- Evaluate solutions for data discovery and classification
- Specify priorities for mitigating threats to data
- Evaluate solutions for encryption of data at rest and in transit, including Azure Key Vault and infrastructure encryption
- Design security for data used in AI workloads
- Design a security solution for data in Azure workloads, including Azure SQL, Azure Synapse Analytics, and Azure Cosmos DB
- Design a security solution for data in Azure Storage
- Design a security solution that includes Microsoft Defender for Storage and Microsoft Defender for Databases

---

## What changed recently

### October 21, 2026 (Microsoft's change log)

| Skill area prior to October 21, 2026 | Skill area as of October 21, 2026 | Change |
|---|---|---|
| Audience profile | | No change |
| **Design security operations, identity, and compliance capabilities** | **Design security operations, identity, and compliance capabilities** | No change |
| Design solutions for security operations | Design solutions for security operations | Minor |
| **Design security solutions for applications and data** | **Design security solutions for applications and data** | No change |
| Evaluate solutions for securing Microsoft 365 | Evaluate solutions for securing Microsoft 365 | Minor |

Microsoft doesn't say which bullets the two Minor rows changed, so I diffed all 81 statements
against the previous version. Exactly two moved, and both are wording changes:

| Objective | Before October 21, 2026 | As of October 21, 2026 |
|---|---|---|
| 2.1 | Design a solution for security orchestration and automated response (SOAR), including Microsoft Sentinel and Microsoft Defender XDR | Design a solution for security orchestration, automation, and response (SOAR), including Microsoft Sentinel and Microsoft Defender XDR |
| 4.1 | Evaluate data security and compliance controls in Microsoft Copilot for Microsoft 365 services | Evaluate data security and compliance controls in Microsoft 365 Copilot |

That diff is my work, not Microsoft's. Microsoft Learn also now says "The Microsoft 365 Copilot app
is now called Microsoft Copilot" ([Copilot overview](https://learn.microsoft.com/en-us/microsoft-365/copilot/copilot-overview)),
so expect to see both names.

### April 2026 (Microsoft's change log)

| Skill area prior to April 2026 | Skill area as of April 2026 | Change |
|---|---|---|
| Audience profile | | No change |
| **Design solutions that align with security best practices and priorities** | **Design solutions that align with security best practices and priorities** | No change |
| Design solutions that align with the Microsoft Cybersecurity Reference Architectures (MCRA) and Microsoft cloud security benchmark (MCSB) | Design solutions that align with the Microsoft Cybersecurity Reference Architectures (MCRA) and Microsoft Cloud Security Benchmark (MCSB) | Minor |
| Design solutions that align with the Microsoft Cloud Adoption Framework for Azure and the Microsoft Azure Well-Architected Framework | Design solutions that align with the Microsoft Cloud Adoption Framework for Azure (CAF) and the Azure Well-Architected Framework | Minor |
| **Design security operations, identity, and compliance capabilities** | **Design security operations, identity, and compliance capabilities** | No change |
| Design solutions for identity and access management | Design solutions for identity and access management | Minor |
| Design solutions for regulatory compliance | Design solutions for regulatory compliance | Minor |
| **Design security solutions for infrastructure** | **Design security solutions for infrastructure** | No change |
| Design solutions for security posture management in hybrid and multicloud environments | Design solutions for security posture management in hybrid and multicloud environments | Minor |
| **Design security solutions for applications and data** | **Design security solutions for applications and data** | No change |
| Design solutions for securing an organization's data | Design solutions for securing an organization's data | Minor |

**Microsoft labels the April edits minor, but the objective text now names technologies the older
outline didn't.** Study these as new material, because older courses and books won't cover them:

- **Microsoft Entra Agent ID** for agent identities (2.2)
- **AI security** as a thread through the whole exam: AI solutions aligned to the MCSB (1.2), a strategy for secure AI adoption (1.3), Azure AI services security (3.3), and security for data used in AI workloads (4.3)
- **Security Service Edge** as a functional group title, with **Microsoft Entra Internet Access** and **Microsoft Entra Private Access** named explicitly (3.4)
- **Microsoft Security Exposure Management** attack paths, attack surface reduction, security insights and initiatives (3.1)
- **Microsoft Purview Audit** by name for centralized logging (2.1)
- **Windows LAPS** as its own objective (3.2)
- **Microsoft 365 Copilot** data security and compliance controls (4.1)

---

## How the free Microsoft Learn path lines up

Microsoft's free training for this exam is course [SC-100T00](https://learn.microsoft.com/en-us/training/courses/sc-100t00),
which ships as four learning paths. **Watch the numbering: Learn path 03 covers exam Domain 4, and
Learn path 04 covers exam Domain 3.** If you study in Learn's order, you'll do applications and
data before infrastructure, which is the reverse of the exam outline.

| Exam domain | Weight | Learn path |
|---|---|---|
| 1. Best practices and priorities | 20-25% | 01: [Design solutions that align with security best practices and priorities](https://learn.microsoft.com/en-us/training/paths/sc-100-design-solutions-best-practices-priorities/) |
| 2. Security operations, identity, compliance | 25-30% | 02: [Design security operations, identity, and compliance capabilities](https://learn.microsoft.com/en-us/training/paths/sc-100-design-operations-identity-compliance-capabilities/) |
| 3. Infrastructure | 25-30% | 04: [Design security solutions for infrastructure](https://learn.microsoft.com/en-us/training/paths/sc-100-design-security-solutions-infrastructure/) |
| 4. Applications and data | 20-25% | 03: [Design security solutions for applications and data](https://learn.microsoft.com/en-us/training/paths/sc-100-design-security-solutions-applications-data/) |

### Where the free path runs thin

I counted how often each objective topic appears across the full text of those four learning
paths, as a rough measure of how deeply each one is taught. These topics are exam objectives where
the free training gives you a sentence instead of a lesson, so they're the ones most likely to
catch you out if Learn is all you studied:

| Objective topic | Mentions in the Learn path |
|---|---|
| Microsoft Purview Audit | 9 |
| Continuous access evaluation | 9 |
| Protected actions | 8 |
| Security Service Edge, as a named architecture | 6 |
| Azure AI services security | 6 |
| Decentralized identity | 3 |
| Agents as a concept | 1 |

For comparison, Microsoft Entra Agent ID, Azure landing zones and AI workload security each appear
more than 70 times. That count is my own analysis of the training text, not anything Microsoft
publishes.

---

## Official study resources

| Resource | What it's for |
|---|---|
| [Study guide](https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/sc-100) | The skills measured, the change logs, and Microsoft's own study links |
| [Exam page](https://learn.microsoft.com/en-us/credentials/certifications/exams/sc-100) | Scheduling, languages, and the two ways Microsoft suggests you prepare |
| [Course SC-100T00](https://learn.microsoft.com/en-us/training/courses/sc-100t00) | Microsoft's free training, as four learning paths |
| [Free practice assessment](https://learn.microsoft.com/en-us/credentials/certifications/exams/sc-100/practice/assessment) | Microsoft's own practice questions, scored |
| [Exam sandbox](https://aka.ms/examdemo) | The exam interface, so test day holds no surprises |
| [Microsoft security documentation](https://learn.microsoft.com/en-us/security/) | The product documentation every objective rests on |
| [Microsoft Cybersecurity Reference Architectures (MCRA)](https://learn.microsoft.com/en-us/security/adoption/mcra) | The reference architecture objective 1.2 names |
| [Microsoft Defender for Cloud documentation](https://learn.microsoft.com/en-us/azure/defender-for-cloud/) | Posture, workload protection and regulatory compliance in one place |
| [Zero Trust Guidance Center](https://learn.microsoft.com/en-us/security/zero-trust/) | Zero Trust principles and the adoption framework |
| [Exam Readiness Zone](https://learn.microsoft.com/en-us/shows/exam-readiness-zone/) | Microsoft's exam prep videos |
| [Certification renewal](https://learn.microsoft.com/en-us/credentials/certifications/renew-your-microsoft-certification) | The free annual renewal assessment once you pass |

## Check whether the exam changed since this page

Microsoft revises the outline without much warning. The study guide's section heading carries the
version date in its id, so this PowerShell prints the version that's live right now:

```powershell
# Prints the live skills-measured heading id. Two ids mean Microsoft has posted an upcoming
# version beside the current one, and you should study the newer outline.
$page = Invoke-WebRequest 'https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/sc-100' -UseBasicParsing
[regex]::Matches($page.Content, '<h2[^>]*id="(skills-measured[^"]+)"') | ForEach-Object { $_.Groups[1].Value }
# This page matches: skills-measured-as-of-october-21-2026
```

If you see a later date, read Microsoft's change log on the study guide first. It tells you which
skill areas moved, and that's where to put your review time.
