# SC-100 Course 2 exercise files

**[SC-100: Designing Security Operations, Identity, and Compliance Capabilities](https://www.pluralsight.com/courses/sc-100--designing-security-operations--identity--and-compliance-capabilities)**,
by Tim Warner, Course 2 of the [SC-100: Microsoft Cybersecurity Architect](https://www.pluralsight.com/paths/sc-100-microsoft-cybersecurity-architect) skill path on Pluralsight.

Open `SC-100-Course-2-Resources.html` in any browser. It's the reference library for every Course 2
objective, and it runs offline: search, filtering and navigation all work locally, and you only need
a connection when you open a Microsoft page.

## What's in the box

| File | What it is |
|---|---|
| `SC-100-Course-2-Resources.html` | The Microsoft documentation behind every Course 2 objective, mapped module by module, with the limits worth carrying into a design recommendation |
| `slides/` | The slides for every module as a PDF, exactly as they appear in the course |
| `code/` | The files behind every demo, one folder per module. See **Lab files** below |
| `README.md` | This file |

## How to use the reference library

Find the module you just watched, then the objective. Each topic links the Microsoft documentation
that backs it up, and a status word such as **PREVIEW** or **BETA API** tells you to read that first,
because a feature's status changes how you'd answer an exam item about it. The **Read with these
limits** box under each module lists the places where a quick reading of the documentation leads you
to the wrong recommendation.

## Lab files

| Folder | Demo | What it touches |
|---|---|---|
| `code/m01-sentinel-investigation` | Module 1: investigate one incident across three signals | Azure: a Microsoft Sentinel workspace with a synthetic investigation |
| `code/m02-agent-conditional-access` | Module 2: govern an agent identity with Conditional Access | Microsoft Entra: report-only policies, an agent identity blueprint and an agent |
| `code/m03-what-if-and-key-vault` | Module 3: prove what the estate actually decides | Microsoft Entra: What If objects. Azure: a Key Vault and four objects to triage |
| `code/m04-privileged-access-evidence` | Module 4: read the grant, then find the evidence | Microsoft Entra: PIM assignments. Azure: the Defender CSPM plan |
| `code/m05-compliance-evidence` | Module 5: walk one obligation to its evidence | Microsoft 365: an audit log measurement. Azure: a regulatory standard assignment |
| `code/shared` | Helpers the module scripts load | Nothing on its own |

Start with the README in each module folder. It gives you that lab's prerequisites, licensing, roles,
the exact run order, and the cleanup commands. Every script also carries full help, so
`Get-Help .\<script>.ps1 -Full` tells you what it changes before you run it.

**Run the Module 2 lab before the Module 3 lab.** Module 3's evaluation depends on the all-users MFA
policy Module 2 creates.

**The Module 2, 3 and 4 labs change a Microsoft Entra tenant.** Run them only in a test tenant you
control, never in production. Every Conditional Access policy they create is report-only, so none of
them can lock anyone out, and no script ever switches one on. Each Graph script prints the tenant name
right after you sign in, so you can stop before anything changes.

**The Module 1, 3 and 4 labs deploy billable Azure resources or turn on a paid plan.** Run them in a
subscription you use for learning, and remove each lab the same day with its Remove mode.

Every script follows the same pattern: a **Plan** mode that changes nothing, a **Deploy** mode that's
safe to rerun, a **Show** mode that reads the result back, and a **Remove** mode that deletes only
what that lab created. Lab objects carry the `GLB-SC100` prefix or the `course=SC100-C2Mx` resource
group tag, and Remove checks the marker before it deletes anything.

## What you'll need

- **PowerShell 7.2 or later**, on Windows, macOS or Linux. Azure Cloud Shell works too.
- **The Azure CLI** with Bicep (`az bicep install`) for Modules 1, 3, 4 and 5.
- **Microsoft Graph PowerShell** for Modules 2, 3 and 4:
  `Install-Module Microsoft.Graph.Authentication -Scope CurrentUser`
- **The Exchange Online module** for Module 5:
  `Install-Module ExchangeOnlineManagement -Scope CurrentUser`

## Where the scripts get your subscription and tenant

From your own sign-in. Nothing in these files names a subscription or tenant of its own. Each script
resolves them in this order:

1. The `-SubscriptionId` and `-TenantId` parameters you pass.
2. The `AZURE_SUBSCRIPTION_ID` and `AZURE_TENANT_ID` environment variables.
3. Your current Azure CLI context (`az account show`), or for the Graph scripts, the tenant you sign
   in to.

`-TenantId` is a guard as well as a target. Pass it, and an Azure script refuses to continue when the
subscription belongs to a different tenant, and a Graph script refuses a sign-in that lands anywhere
else.

## Before any lab: sign in so Azure accepts writes

**Azure enforces mandatory multifactor authentication on create, update and delete calls.** That
enforcement happens at the Azure Resource Manager layer, so a session that signed in without
completing MFA can read everything you own and still have its first write refused with
`AADSTS50076`. `az account show` can't tell you which kind of session you have, because it reads a
cached local profile.

So every Azure script checks the token itself before it writes. It decodes your Azure Resource Manager
access token, which it never prints, and looks for `mfa` in the `amr` claim, the list of methods you
signed in with. If `mfa` is missing, the script stops and prints the fix. There are two that work:

1. **Sign in again from your shell and complete MFA when you're prompted.**

   ```powershell
   az logout
   az login --tenant <your-tenant-id>
   ```

   If that sign-in never asks for MFA, Azure answers the refused write with a claims challenge. Pass
   it back exactly as Microsoft's
   [Azure CLI troubleshooting guide](https://learn.microsoft.com/cli/azure/use-azure-cli-successfully-troubleshooting#troubleshooting-multifactor-authentication-mfa)
   shows:

   ```powershell
   az login --tenant <your-tenant-id> --scope "https://management.core.windows.net//.default" --claims-challenge "<claims-challenge>"
   ```

2. **Use Azure Cloud Shell.** Sign in at [portal.azure.com](https://portal.azure.com) and complete MFA
   there. If the portal sign-in didn't prompt for MFA, make one small change in the portal, such as
   adding a tag to a resource group you own, and complete the prompt that follows. Then open Cloud
   Shell, choose PowerShell, bring this folder over, and run the same commands. Cloud Shell inherits
   your portal session.

Don't turn MFA off to get past this. The requirement is part of the design you're learning. If your
organization satisfies MFA in a way that doesn't show up in the token, every Azure script takes
`-SkipMfaCheck`, and a refused write then fails with `AADSTS50076` instead of stopping early. Service
principal sign-ins skip the check automatically, because mandatory MFA applies to user sign-ins.
[Mandatory MFA for Azure](https://learn.microsoft.com/entra/identity/authentication/concept-mandatory-multifactor-authentication)
has the details.

## Course repository

The course repository is https://github.com/timothywarner-org/ps-sc100, and it holds the exercise
files for all four courses in the SC-100 skill path.

## Currency

The reference library was built against the SC-100 skills measured as of July 28, 2026, and its links
were last checked on November 2, 2026. Microsoft's October 21, 2026 revision changed one Domain 2 statement, objective
2.1.4, and only in wording: it now expands SOAR as security orchestration, automation, and response.
Microsoft moves pages, so if a link has drifted by the time you click it, search Microsoft Learn for
the words in the link.

Two product facts are worth carrying to the exam. Microsoft Entra Permissions Management is
**retired**, and its cloud infrastructure entitlement management (CIEM) capability now lives in
Microsoft Defender for Cloud. And Microsoft Sentinel is used in the **Microsoft Defender portal**,
which is where these labs send you.

## About Globomantics

Globomantics is a fictional company, and every scenario detail in the course is invented for
teaching. Nothing here describes a real organization or a real assessment.

## Accessibility

No meaning in these files is carried by color alone. In the reference library every status is a word
in a bordered tag. In the lab scripts every result line starts with a word in brackets, such as
`[OK]`, `[WARN]`, `[FAIL]` or `[WAIT]`, so the output reads the same in any terminal theme.

## More from me

TechTrainerTim.com
