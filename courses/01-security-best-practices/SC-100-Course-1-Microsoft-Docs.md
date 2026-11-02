# SC-100 Course 1 - Microsoft documentation links

Every link on this page was fetched and verified on **2026-09-03** through the Microsoft
Learn MCP server, and checked live again on **2026-11-02**. Not one of them was written from memory or guessed from a URL pattern.
If a page had moved, the redirect target is what you see here.

These are **first-party Microsoft pages only**. That is deliberate. On exam day the
question is what Microsoft recommends, so a blog post that disagrees with Learn will cost
you points even when the blog post is right.

**Exam blueprint stamp: July 28, 2026.** Passing score is 700. Microsoft does not publish
question counts, question types, or time limits, so treat any source that states them as
unreliable.

---

## Start here

| Page | Why you want it |
|---|---|
| [Exam SC-100: Microsoft Cybersecurity Architect](https://learn.microsoft.com/credentials/certifications/exams/sc-100/) | The exam page itself. Confirms the July 28, 2026 update, the 700 passing score, and the four skill areas with their percentage weights. |
| [SC-100 study guide](https://learn.microsoft.com/credentials/certifications/resources/study-guides/sc-100) | Every objective, worded exactly as the exam writers worded it. Read the bullets literally. When a bullet says "design a strategy" you get asked to sequence decisions, not to name a product. |

---

## Module 1 - Ransomware resilience and recovery

| Page | Why you want it |
|---|---|
| [Quickly protect against ransomware attacks](https://learn.microsoft.com/security/ransomware/protect-against-ransomware) | The three-step priority order Microsoft actually recommends. The order is the answer to a lot of stem questions: recovery plan first, then limit privilege, then harden entry. |
| [Backup and restore plan to protect against ransomware](https://learn.microsoft.com/azure/security/fundamentals/backup-plan-to-protect-against-ransomware) | The five business-critical system categories in priority order, and the 3-2-1 rule. Your prioritized backup list becomes your prioritized restore list, which is a favorite exam idea. |
| [Immutable vault for Azure Backup](https://learn.microsoft.com/azure/backup/backup-azure-immutable-vault-concept) | Read the three states: Disabled, Enabled, and Enabled and locked. Locking is irreversible, and that irreversibility is the whole point when the attacker already has your admin account. |
| [Multiuser authorization using Resource Guard](https://learn.microsoft.com/azure/backup/multi-user-authorization-concept) | Why the backup admin must NOT hold Contributor on the Resource Guard. If one person can both delete backups and remove the control that stops them, you have a diagram, not a control. |
| [Security features in Azure Backup](https://learn.microsoft.com/azure/backup/security-overview) | The vault security levels, from Excellent down to Poor, and exactly which settings earn each one. Handy for "evaluate this design" questions. |
| [Privileged access strategy](https://learn.microsoft.com/security/privileged-access-workstations/privileged-access-strategy) | Microsoft's position that privileged access is the top security priority at every organization. This is why ransomware questions keep turning into privileged access questions. |

---

## Module 2 - Reference architectures and benchmarks

| Page | Why you want it |
|---|---|
| [Zero Trust as a security foundation](https://learn.microsoft.com/security/zero-trust/zero-trust-overview) | Verify explicitly, use least privilege access, assume breach. Know all three by name and be able to say which one a given control serves. |
| [Microsoft Cybersecurity Reference Architectures (MCRA)](https://learn.microsoft.com/security/zero-trust/microsoft-reference-architecture) | Where to download the current deck. Use MCRA to find gaps and overlaps in capability, not to pick a product. |
| [Microsoft cloud security benchmark v2 overview](https://learn.microsoft.com/security/benchmark/azure/overview) | The v2 domain list, including the Artificial Intelligence Security domain. Note that **v2 is in preview**; say so out loud in any design discussion, because preview status changes what you can commit to. |
| [MCSB v2 Artificial Intelligence Security](https://learn.microsoft.com/security/benchmark/azure/mcsb-v2-artificial-intelligence-security) | The AI control family, AI-1 through AI-7, split across platform security, application security, and monitoring. |
| [What is Cloud Security Posture Management (CSPM)](https://learn.microsoft.com/azure/defender-for-cloud/concept-cloud-security-posture-management) | The Foundational versus Defender CSPM split, feature by feature. **Heads up: starting October 27, 2026, Foundational CSPM becomes opt-in for new Azure subscriptions.** |

---

## Module 3 - CAF, WAF, and governance

| Page | Why you want it |
|---|---|
| [Cloud Adoption Framework Secure methodology](https://learn.microsoft.com/azure/cloud-adoption-framework/secure/overview) | Security across every CAF phase, with the cloud security checklist. CAF governs the estate over its lifecycle. |
| [What is the Azure Well-Architected Framework?](https://learn.microsoft.com/azure/well-architected/what-is-well-architected-framework) | The five pillars and the maturity model. WAF evaluates one workload. Conflating CAF and WAF is a reliable way to lose a point. |
| [What is an Azure landing zone?](https://learn.microsoft.com/azure/cloud-adoption-framework/ready/landing-zone/) | Platform landing zone versus application landing zone, and the Corp, Online, and Local archetypes. An archetype is a governance profile, not a folder. |
| [What are Azure management groups?](https://learn.microsoft.com/azure/governance/management-groups/overview) | Inheritance, the six-level depth limit, and the fact that a subscription has exactly one parent. Where you put a subscription decides what it may do. |
| [What is Azure Policy?](https://learn.microsoft.com/azure/governance/policy/overview) | Definitions, initiatives, assignments, and the 24-hour standard compliance evaluation cycle. Also the recommendation to start with audit before you enforce. |
| [Azure Policy deny effect](https://learn.microsoft.com/azure/governance/policy/concepts/effect-deny) | Deny blocks the request before it reaches the resource provider and returns 403. Existing resources are marked non-compliant, not deleted. Deny is a gate, not a cleanup crew. |
| [Resolve RequestDisallowedByPolicy errors](https://learn.microsoft.com/azure/azure-resource-manager/troubleshooting/error-policy-requestdisallowedbypolicy) | What a real denial returns. The policy assignment and definition come back as resource IDs, and the readable part is the non-compliance message somebody wrote. Write one on every Deny assignment. |

---

## Module 4 - Secure AI adoption and DevSecOps

| Page | Why you want it |
|---|---|
| [AI strategy](https://learn.microsoft.com/azure/cloud-adoption-framework/ai/strategy) | The CAF AI adoption phases, strategy through manage, and the four adoption models from Copilots to raw infrastructure. |
| [AI governance process](https://learn.microsoft.com/azure/cloud-adoption-framework/ai/govern) | The risk assessment table that maps each Responsible AI principle to a question you can actually ask in a review. Also the instruction to integrate AI risk into your existing risk framework rather than beside it. |
| [Responsible AI policies](https://learn.microsoft.com/azure/cloud-adoption-framework/ai/responsible-ai-policies) | Turning principles into standards teams can implement, plus ownership and auditing. Accountability is the principle that puts a name against a risk. |
| [AI shared responsibility model](https://learn.microsoft.com/azure/security/fundamentals/shared-responsibility-ai) | The three layers, AI platform, AI application, and AI usage, and how the line moves across SaaS, PaaS, and IaaS. This is the Seam, and both attackers and auditors look there. |
| [AI security posture management](https://learn.microsoft.com/azure/defender-for-cloud/ai-security-posture) | What Defender CSPM discovers: Azure OpenAI Service, Foundry, Azure Machine Learning, Amazon Bedrock, Google Vertex AI. Also the AI Bill of Materials. |
| [Discover generative AI workloads](https://learn.microsoft.com/azure/defender-for-cloud/identify-ai-workload-model) | The exact click path for the "AI workloads and models in use" query template, plus its prerequisites. |
| [Transition AI agent security to Microsoft Agent 365](https://learn.microsoft.com/defender-xdr/security-for-ai/transition-agent-security-to-agent-365) | **Read this one.** As of July 1, 2026, AI agent discovery and posture need a Microsoft Agent 365 license. Defender CSPM still discovers Foundry accounts and projects. Agent-level capability moved. |
| [Prompt injection, direct and indirect](https://learn.microsoft.com/security/zero-trust/catalog-ai-attack-techniques/prompt-injection) | Both directions of the attack and the layered controls, mapped to OWASP LLM Top 10 and MITRE ATLAS. |
| [MCSB v2 DevOps Security](https://learn.microsoft.com/security/benchmark/azure/mcsb-v2-devops-security) | The DS control family. This is where the word **gating** is used for static analysis, and for nothing else. That single word decides a lot of "which finding blocks the build" questions. |
| [Overview of Microsoft Foundry Models](https://learn.microsoft.com/azure/foundry/concepts/foundry-models-overview) | Models sold by Azure versus models from partners and community, and what that split means for support and responsibility. |

---

## Two naming traps worth memorizing

**Say Microsoft Foundry, not Azure AI Foundry.** The product was renamed. Some Microsoft
pages still carry the old name, so the page you are reading is not a safe source for the
current product name.

**MCSB v2 is in preview and v1 is GA.** The AI control family lives in v2. Never present a
preview control set as though you can build an audit commitment on it today.
