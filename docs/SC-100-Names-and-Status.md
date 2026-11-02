# SC-100 names and status: what Microsoft calls it now

**Microsoft renames and retires security products faster than it rewrites exam outlines.** This
page lists the names that trip people up on SC-100: what a product is called now, the older name
you'll still see in books, blogs and AI answers, and the places where Microsoft's own pages
disagree. Read it before exam day. A retired product name in a scenario is usually a distractor,
and a current name you've never heard is usually the right answer.

Every row links the Microsoft page it rests on. Each row records when it was last checked against
Microsoft Learn, and Microsoft moves fast, so if a row matters to a real design, open the link.

---

## Old name to current name

| You'll still see | Call it now | What changed |
|---|---|---|
| Microsoft Entra Permissions Management | **Permissions management (CIEM) in Microsoft Defender for Cloud** | The standalone product is **retired** and its cloud infrastructure entitlement management capability moved into Defender for Cloud. Microsoft's own pages give two different retirement dates, and the exam doesn't test the date, so remember "retired, now CIEM in Defender for Cloud." Objective 2.3. |
| Azure AI Foundry | **Microsoft Foundry** | Renamed. The docs now distinguish Microsoft Foundry from "Microsoft Foundry (classic)," so check which one a page describes. Objectives 1.3, 3.3, 4.3. |
| Azure AI services (as the only name) | **Foundry Tools**, and the objective's own wording | Learn now titles the service page [What are Foundry Tools?](https://learn.microsoft.com/azure/ai-services/what-are-ai-services), while objective 3.3 still says "Azure AI services security." Know both names. Checked 2026-09-22. |
| Secure Service Edge | **Security Service Edge (SSE)** | It was never "Secure." The functional group is *Evaluate solutions for network security and Security Service Edge (SSE)*. Objective 3.4. |
| Legacy Microsoft LAPS | **Windows LAPS** | The legacy product is deprecated as of Windows 11 23H2, and installing the legacy MSI is blocked on newer OS versions. Objective 3.2. |
| Azure Disk Encryption (for new workloads) | **Encryption at host** for new VMs, or **Confidential VM sizes with OS disk encryption** for confidential workloads, with Key Vault or Managed HSM for keys | Azure Disk Encryption retires **September 15, 2028**. Workloads keep running, but encrypted disks fail to unlock after a VM reboot, and in-place conversion isn't supported, so migration means new disks and new VMs. See the [migration guide](https://learn.microsoft.com/azure/virtual-machines/disk-encryption-migrate). Objective 4.3. Checked 2026-08-24. |
| Azure Policy guest configuration | **Azure Machine Configuration** | Renamed. It comes up when you audit baselines on Azure Arc-enabled servers. Objectives 1.3, 2.4, 3.1. |
| NSG flow logs (for new designs) | **Virtual network flow logs** | New NSG flow logs couldn't be created after June 30, 2025, and NSG flow logs retire September 30, 2027. Objective 3.4. |
| Azure Business Continuity Center, or Backup center | **Resiliency in Azure** | Learn says: *"Azure Business Continuity Center is now Resiliency in Azure, a unified platform for Zone Resiliency, High Availability, Backup & Disaster Recovery, and Ransomware Protection."* It's also where a vault's security level shows up. See [Security levels in Resiliency](https://learn.microsoft.com/azure/resiliency/security-levels-concept). Objectives 1.1, 3.1. Checked 2026-08-27. |
| Defender for IoT on-premises management console | **API and syslog integration with existing IT infrastructure** | The legacy on-premises console is no longer supported, and current guidance integrates air-gapped sensors directly. Objective 3.2. |
| Secure score, with no qualifier, for Defender for Cloud | **Cloud Secure Score** (risk-based, in the Microsoft Defender portal) or **classic secure score** (control-based, in the Azure portal) | Both models are live and give different numbers for the same estate. **Microsoft Secure Score** is a third, separate score covering identity, devices, apps and data. See [Cloud Secure Score](https://learn.microsoft.com/azure/defender-for-cloud/secure-score-security-controls). Objective 3.1. Checked 2026-09-22. |
| Log Analytics agent (MMA) onboarding for non-Azure servers | **Azure Arc-enabled servers** (the Azure Connected Machine agent) with the Defender for Endpoint integration, or **direct Defender for Endpoint onboarding** where you don't need Arc governance | The Log Analytics agent is retired. Arc's agent manages the server, and the Defender for Endpoint sensor protects it. See [Prepare for retirement of the Log Analytics agent](https://learn.microsoft.com/azure/defender-for-cloud/prepare-deprecation-log-analytics-mma-agent). Objectives 3.1, 3.2. Checked 2026-10-01. |
| Adaptive network hardening | **Defender for Cloud networking recommendations** and **attack path analysis** | The feature's own Learn page now redirects to the Log Analytics agent retirement page, while the [networking recommendations reference](https://learn.microsoft.com/azure/defender-for-cloud/recommendations-reference-networking) still lists its recommendation. With Microsoft's pages split, don't build a design answer on it. Objective 3.4. Checked 2026-09-23. |
| Microsoft Copilot for Microsoft 365 | **Microsoft 365 Copilot** | That's the exam's wording as of October 21, 2026. Microsoft has also renamed the app **Microsoft Copilot** ([Copilot overview](https://learn.microsoft.com/en-us/microsoft-365/copilot/copilot-overview)), so you'll meet both. Objective 4.1. Checked 2026-10-22. |
| DSPM for AI, as the current product | **Microsoft Purview Data Security Posture Management** | Microsoft now labels the older experiences **DSPM for AI (classic)** and **Data Security Posture Management (classic)**. See [Learn about Data Security Posture Management](https://learn.microsoft.com/purview/data-security-posture-management-learn-about). Checked 2026-10-22. |
| Restricted SharePoint Search, as a design option | **Restricted Content Discovery** and **SharePoint Advanced Management** | Restricted SharePoint Search is retiring, and new enablement has been blocked since July 31, 2026. See [Restricted SharePoint Search](https://learn.microsoft.com/sharepoint/restricted-sharepoint-search). Checked 2026-10-22. |
| Azure OpenAI On Your Data | **Secure retrieval through Azure AI Search and Foundry IQ** | Microsoft's pages disagree on whether it's deprecated or already retired. Either way, it isn't an option for a new design. Objective 4.3. Checked 2026-10-22. |
| Azure Front Door (classic) | **Azure Front Door Standard or Premium** | Front Door (classic) retires **March 31, 2027**. See [Front Door tier migration](https://learn.microsoft.com/azure/frontdoor/tier-migration). Checked 2026-10-22. |

## Microsoft Sentinel is moving to the Defender portal

**The product name Microsoft Sentinel isn't changing. Only the portal is.** After **March 31,
2027**, Sentinel is available only in the **Microsoft Defender portal**. Sentinel in the Defender
portal is generally available to all customers, including those without Defender XDR or an E5
license, and new Sentinel customers have been onboarded there automatically since July 1, 2025.

This matters for objective 2.1, which asks you to design detection and response with XDR and SIEM,
and SOAR with Microsoft Sentinel and Microsoft Defender XDR. After the consolidation, the unified
Defender portal **is** the architecture answer, not a UI detail. Also note that Sentinel's old
Threat Intelligence blade is now **Intel management** in the Defender portal.

## Version traps: never quote an MCSB control number without its version

**Microsoft Cloud Security Benchmark (MCSB) v2 is in preview and supersedes v1. Both are live, and
the control numbers differ between them.** Checked 2026-08-24 against the
[MCSB v2 overview](https://learn.microsoft.com/security/benchmark/azure/overview).

| Fact | State |
|---|---|
| MCSB v2 | **Preview.** It adds an **Artificial Intelligence Security** domain |
| MCSB v2 per-service baselines | Don't exist yet. Per-service baselines are still v1 only |
| What Defender for Cloud assesses by default | v1. You can enable v2 from the Regulatory compliance dashboard |
| GA date for v2 | Not published |

Control numbers were renumbered between versions. v2's DS-6 is "Secure the workload lifecycle,"
while v1's DS-6 was "Enforce security of workload throughout DevOps lifecycle." If you memorize a
bare number against the wrong version, you'll get the item wrong.

**The SC-100 Learn training itself carries a mislabeled table.** The unit
[Design and implement standards to secure application development](https://learn.microsoft.com/en-us/training/modules/design-solutions-secure-applications/2-design-implement-standards-secure-application-development)
has a section headed "MCSBv2 DevOps Security controls," but its control names are the v1 wording.
Take DS control names from the live
[MCSB v2 DevOps Security](https://learn.microsoft.com/security/benchmark/azure/mcsb-v2-devops-security) page:

| Control | The training unit says | Actual MCSB v2 |
|---|---|---|
| DS-2 | Ensure software supply chain security | **Secure the software supply chain** |
| DS-3 | Secure DevOps infrastructure | **Secure the DevOps infrastructure** |
| DS-4 | Integrate static application security testing into DevOps pipeline | **Integrate Static Application Security Testing (SAST)** |
| DS-5 | Integrate dynamic application security testing into DevOps pipeline | **Integrate Dynamic Application Security Testing (DAST)** |
| DS-6 | Enforce security of workload throughout DevOps lifecycle | **Secure the workload lifecycle** |
| DS-7 | Enable logging and monitoring in DevOps | **Implement DevOps logging and monitoring** |

DS-1, "Conduct threat modeling," is the only one that matches.

Two more traps in the same family:

- **Microsoft SDL has no version number.** It's published as a set of practices at
  [Microsoft Security Development Lifecycle practices](https://www.microsoft.com/en-us/securityengineering/sdl/practices),
  while an older Learn compliance page still describes the five-phase model. Learn the practices,
  and recognize the phase diagram as the older presentation.
- **The benchmark contradicts the product guidance on disk encryption.** MCSB v2 PV-3's
  implementation example still recommends enforcing Azure Disk Encryption through Azure Policy,
  while the Azure Disk Encryption docs say it retires September 15, 2028 and shouldn't be used
  for new deployments. Go with the product guidance.

## Where Microsoft's own pages disagree

When two first-party pages disagree, learn the mechanism they agree on and don't stake an answer
on the maturity label.

**Secure-by-default soft delete for Backup vaults** (checked 2026-08-27). The
[secure-by-default](https://learn.microsoft.com/azure/backup/secure-by-default) page calls it GA in
some regions and preview elsewhere, while the
[enhanced soft delete](https://learn.microsoft.com/azure/backup/backup-azure-enhanced-soft-delete-configure-manage)
page calls it preview in those same regions. Both agree on the mechanism: soft delete is **Off**,
**On** or **AlwaysOn**, AlwaysOn can't be turned back off, and Microsoft is moving soft delete
toward enforced-by-default.

**The Cloud Security initiative in Microsoft Security Exposure Management** (checked 2026-09-28).
The Defender portal view of [Cloud Secure Score](https://learn.microsoft.com/azure/defender-for-cloud/secure-score-security-controls)
shows no preview banner, while the [initiatives list](https://learn.microsoft.com/security-exposure-management/initiatives-list)
marks it **Cloud Security [Preview]** and says the current Cloud initiative "will be deprecated
soon." Don't call it generally available. Both pages agree it's a risk-based score with a target
and the metrics behind it.

**Which Defender for Servers plan carries OS baseline assessment** (checked 2026-09-29). The
[Defender for Servers overview](https://learn.microsoft.com/azure/defender-for-cloud/defender-for-servers-overview)
marks it Plan 2 in its feature table, while that table's footnote says MCSB OS baseline
misconfigurations are included in free Foundational CSPM. The
[OS misconfiguration guide](https://learn.microsoft.com/azure/defender-for-cloud/operating-system-misconfiguration)
requires Plan 2 and Machine Configuration. For a design answer, go with Plan 2.

**Whether Foundational CSPM is on by default** (checked 2026-09-30). Microsoft briefly published a
change that would start new subscriptions with Foundational CSPM turned off, then removed that
page. The [CSPM overview](https://learn.microsoft.com/azure/defender-for-cloud/concept-cloud-security-posture-management)
now says only that Foundational CSPM is available at no cost. The safe design statement is that
it's free and you turn it on deliberately.

## Still current: don't let older material talk you out of these

| Product | Note |
|---|---|
| Microsoft Defender External Attack Surface Management (Defender EASM) | Current, and it now shows up as standalone Defender EASM, as the EASM initiative in Microsoft Security Exposure Management, and as EASM in Defender for Cloud. Objective 3.1 names both Defender EASM and Exposure Management initiatives, so the relationship is fair game. |
| Microsoft Entra Verified ID | The current answer for decentralized identity in objective 2.2. |
| Microsoft Security Exposure Management | Current. Attack paths, attack surface reduction, security insights and initiatives are all named in objective 3.1. |
| Microsoft Entra Agent ID | Current and named in objective 2.2. Applying Conditional Access and other Entra security features to agents requires a **Microsoft Agent 365** license. |
| Microsoft Defender XDR, Defender for Cloud, Defender for Office 365, Defender for Cloud Apps, Defender for IoT | Current. |
| Microsoft Entra ID, Microsoft Entra ID Governance, Microsoft Entra Privileged Identity Management (PIM), Conditional Access | Current. |
| Microsoft Purview and Microsoft Purview Audit | Current. Purview Audit is named in objective 2.1. |
| Microsoft Intune | Current. |
| Azure Arc, Azure Policy, Microsoft Cloud Security Benchmark | Current. |
| Microsoft Cybersecurity Reference Architectures (MCRA) | Current. Note the plural in the objective wording. |

## Names that sit on top of each other

**Security Service Edge and Global Secure Access.** The objectives name **Microsoft Entra Internet
Access** and **Microsoft Entra Private Access**. They don't name Global Secure Access, but Global
Secure Access is the portal you configure them in and the umbrella the docs use. Answer in the
objective's terms, and don't be thrown when a scenario or a screenshot says Global Secure Access.

**Microsoft Foundry and Foundry (classic).** Microsoft is mid-transition and the docs carry both.
The current RBAC roles worth knowing for objective 3.3 are **Foundry Account Owner** and **Foundry
Owner** (full resource management, encryption, networking), **Foundry Project Manager** (creates
projects, manages deployments, and can conditionally assign Foundry User), and **Foundry User**
(the least-privilege starting point for developers and project managed identities).

**The benchmark and the policy.** The Microsoft Cloud Security Benchmark is a **control
framework**. Azure Policy initiatives and definitions **assess or enforce parts of it**. There's no
clean one-to-one mapping from every MCSB control to an enforceable policy definition, and an answer
that assumes one is wrong.
