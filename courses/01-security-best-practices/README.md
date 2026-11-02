# SC-100 Course 1 exercise files

**[SC-100: Designing Solutions with Security Best Practices](https://www.pluralsight.com/courses/sc-100--designing-solutions-with-security-best-practices)**, by Tim Warner, Course 1 of the
[SC-100: Microsoft Cybersecurity Architect](https://www.pluralsight.com/paths/sc-100-microsoft-cybersecurity-architect) skill path on Pluralsight.
Prepared Monday, November 2, 2026. Links verified Monday, November 2, 2026.

Open `SC-100-Course-1-Resources.html` in any browser. It runs offline: search, filtering and navigation
all work locally, and you only need a connection when you open a Microsoft page.

## What's in the box

| File or folder | What it is |
|---|---|
| `SC-100-Course-1-Resources.html` | The Microsoft documentation behind every objective in the course: 169 first-party links across all of Domain 1, each objective tagged with the module and clip that covers it. |
| `SC-100-Course-1-Microsoft-Docs.md` | A shorter reading list, module by module, for when you want the essentials without the search page. |
| `slides/` | The slides for every module as a PDF, exactly as they appear in the course. |
| `demo-artifacts/` | The one-page artifacts the demos close on. Each opens in any browser, offline. See **Demo artifacts** below. |
| `code/` | The labs behind the demos, one folder per module that has code. See **Lab files** below. |
| `README.md` | This file. |

## How to use it

Find the objective for the clip you just watched. The links under it are the Microsoft pages that back
up the design call I made on screen. When a link carries a status tag such as **PREVIEW**, **RENAMED** or
**DATED**, read the tag first, because a feature's status changes how you'd answer an exam item about it.

## Demo artifacts

Every demo in this course ends on a single page, because that page is what a steering committee
actually receives. The format is the least important thing about them. Copy the questions and the
structure into whatever your organization already uses.

| File | Module | What it is |
|---|---|---|
| `m01-scenario-card.html` | Module 1 | Globomantics leadership's destructive-loss requirement, with the attacker path and the recovery path drawn side by side |
| `m01-decision-artifact.html` | Module 1 | The recovery architecture decision record: every requirement paired with the control that answers it, with the gaps left visible |
| `m02-control-citation.html` | Module 2 | One control, IM-1 in the Microsoft cloud security benchmark v1, with its framework mappings and the recommendation it supports. Its resource counts are scenario data, and the file tells you how to swap in your own |
| `m03-governance-scorecard.html` | Module 3 | Governance gaps sorted by the scope that owns the fix: strategy, platform, or workload |
| `m04-ai-adoption-gate.html` | Module 4 | The gate an architect signs before a model reaches production, with the risk owner field still empty |

## Lab files

| Folder | Demo | What you get |
|---|---|---|
| `code/m01-blob-recovery` | Module 1: evidence a ransomware-resilient recovery design | One script to plan, deploy, read and remove the lab, and its Bicep: Globomantics order documents with operational backup, an empty restore target, and a Backup vault holding a vaulted copy |
| No folder | Module 2: cite the control, and prove it in the estate | Nothing to deploy. The demo reads the Module 1 lab in the regulatory compliance dashboard of Microsoft Defender for Cloud, beside the MCSB v1 IM-1 control page and the Microsoft Cybersecurity Reference Architectures download. Deploy the Module 1 lab and you have everything it uses |
| `code/m03-landing-zone-policy` | Module 3: two landing zones, one template, two answers | The hierarchy deploy, the workload script that succeeds in Online and is denied in Corp, the Bicep, and policy parameter files for assigning by hand |
| `code/m04-ai-adoption-gate` | Module 4: govern AI adoption before you enable it | The Microsoft Foundry estate deploy, the Azure Resource Graph query, and a script that builds the GitHub pull request a credential scan blocks |

Start with the README in each module folder. It gives you that lab's prerequisites, the exact run
order, and the cleanup commands.

**The Module 1 and Module 4 labs deploy real, billable Azure resources, and the Module 3 lab changes
your tenant's management group hierarchy.** Run them in a tenant and subscription you keep for learning,
never in production, and remove each lab the same day with its `-Mode Remove` command. Defender CSPM
stays off unless you pass `-EnableDefenderCspm`, because it bills across your whole subscription, not
just the lab.

Every script takes its subscription and tenant from your own Azure CLI sign-in. To pin a different one,
pass `-SubscriptionId` and `-TenantId`, or set the `AZURE_SUBSCRIPTION_ID` and `AZURE_TENANT_ID`
environment variables. An explicit parameter wins over the environment variable, and the environment
variable wins over whatever `az login` selected.

You'll need PowerShell 7 and the Azure CLI, on Windows, macOS or Linux, and Azure Cloud Shell works too.
Module 4's pipeline lab also needs git and the GitHub CLI.

## Currency

The links were last checked on November 2, 2026. The course was built against the SC-100 skills measured
as of **July 28, 2026**, and Domain 1's objective statements didn't change in the October 21, 2026 revision. Microsoft moves pages,
so if a link has drifted by the time you click it, search Microsoft Learn for the title you see on the
page.

A few names in this course have already moved, and older pages and training data will steer you wrong
on them:

- The AI platform is **Microsoft Foundry**. Some Microsoft pages still say Azure AI Foundry.
- Azure Business Continuity Center is now **Resiliency in Azure**, and that's where the portal grades a
  Backup vault's security level.
- The Microsoft cloud security benchmark **v2 is in preview**, and it renumbers controls. **v1 is
  generally available**, and it's the version the Module 2 demo cites. Always say the version with the
  control number.

## Slide footer links

A few Course 1 slides cite their Microsoft Learn source in the footer. Here's the full address behind
each one, so you can open it straight from this page:

| Slides | Microsoft Learn page |
|---|---|
| Module 1, slides 7 and 8 | [Support business resiliency](https://learn.microsoft.com/en-us/training/modules/design-resiliency-strategy-common-cyberthreats-like-ransomware/2-support-business-resiliency) |
| Module 1, slide 12 | [Design solutions for mitigating ransomware attacks](https://learn.microsoft.com/en-us/training/modules/design-resiliency-strategy-common-cyberthreats-like-ransomware/3-ransomware-protection) |
| Module 2, slide 8 | [Describe the Microsoft Cloud Security Benchmark](https://learn.microsoft.com/en-us/training/modules/design-solutions-microsoft-cybersecurity-cloud-security-benchmark/1b-describe-microsoft-cloud-security-benchmark) |
| Module 3, slide 10 | [Understand Azure landing zones](https://learn.microsoft.com/en-us/training/modules/design-solutions-align-cloud-adoption-framework-well-architected-framework/4-introduction-azure-landing-zones) |
| Module 4, slide 10 | [Design secure DevSecOps processes](https://learn.microsoft.com/en-us/training/modules/design-solutions-align-cloud-adoption-framework-well-architected-framework/8a-design-devsecops-processes) |

## About Globomantics

Globomantics is a fictional company, and every scenario detail in the course is invented for teaching.
Nothing here describes a real organization or a real assessment.

## Accessibility

No meaning in these files is carried by color alone. Every status is a word with its own shape or border,
and every script prints `[OK]`, `[WARN]` or `[FAIL]` instead of relying on color.

## More from me

TechTrainerTim.com
