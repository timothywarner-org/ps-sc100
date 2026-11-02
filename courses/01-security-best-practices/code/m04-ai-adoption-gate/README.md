# Module 4 lab: govern AI adoption before you enable it

This lab builds the Globomantics AI estate behind the demo **Govern AI adoption before you enable it**,
in your own Azure subscription, plus the GitHub pull request the DevSecOps half of the module uses.
Finding your AI workloads is the easy part: Azure Resource Graph lists them in about a second. The hard
part is that no inventory anywhere records whether anyone approved them, and this lab lets you see that
gap for yourself.

Globomantics is a fictional company, and every name in this lab is invented for teaching.

## What's in the folder

| File | What it does |
|---|---|
| `Deploy-C1M04AIWorkload.ps1` | Plans, deploys, reads, or removes the Microsoft Foundry estate |
| `Deploy-C1M04PipelineGate.sh` | Builds, or removes, the GitHub repository and the pull request a credential scan blocks |
| `iac\main.bicep` | The two Foundry accounts, their projects and model deployments. The header explains every design choice |
| `iac\find-ai-workloads.kql` | The Azure Resource Graph query that finds the workloads, and the one column that says anything about approval |

The PowerShell script carries full help: run `Get-Help .\Deploy-C1M04AIWorkload.ps1 -Full`. The Bash
script explains its settings in the comment block at the top.

## What the lab builds

**In Azure,** one resource group, `rg-globomantics-c1m04`, tagged `course=SC100-C1M04`:

- `aif-globomantics-marketing` plus a suffix: the marketing team's chatbot. Shadow AI, never submitted
  for review. Its project is `proj-marketing-chatbot`.
- `aif-globomantics-orderintake` plus a suffix: the order-intake pilot. Submitted to the architecture
  board, and blocked at the gate because nobody has written down its data boundary or named a risk
  owner. Its project is `proj-order-intake`.

Both are Microsoft Foundry accounts running the same small model. The only record of how they differ is a
`governance-state` tag a human typed. Foundry account names become public DNS names, so yours carry a
suffix the template derives from your resource group; in the video you'll see the names without it.

**On GitHub,** a repository named `globomantics-storefront-api` with three required checks on `main`,
and an open pull request that plants a fake Globomantics payment key. The credential scan fails and
blocks the merge while the build and unit tests pass beside it.

## Before you start

- **PowerShell 7** (`pwsh`) and the **Azure CLI**, signed in with `az login`. If you don't have the Bicep
  CLI yet, run `az bicep install`.
- **Contributor** on a subscription you use for learning. Purging the soft-deleted Foundry accounts at
  cleanup needs Contributor at subscription scope, not just on the resource group.
- **Model quota** in your region for the model's deployment SKU. Plan checks that the region still offers
  the pinned model version before anything is created.
- **For the pipeline lab:** bash, git, and the GitHub CLI signed in with `gh auth login`. Azure Cloud
  Shell has all three. On Windows, Git Bash or WSL works.

## Run it

Open PowerShell 7 in this folder and run these in order:

```powershell
az login
az account set --subscription "<your-subscription-name-or-id>"

# Check the model pin and preview. Changes nothing.
pwsh -NoProfile -File .\Deploy-C1M04AIWorkload.ps1 -Mode Plan

# Deploy the two Foundry accounts. Safe to rerun.
pwsh -NoProfile -File .\Deploy-C1M04AIWorkload.ps1 -Mode Deploy

# List the workloads and their governance-state tag.
pwsh -NoProfile -File .\Deploy-C1M04AIWorkload.ps1 -Mode Show
```

**If Plan reports the model version is no longer offered,** pick a current version from the list it
prints and pass it with `-ModelVersion` on every mode. A pinned version keeps the deployment
reproducible, and it also goes stale silently: when a pin moves into a deprecating state, deployment
fails validation with `ServiceModelDeprecating` before anything is created.

To have Defender for Cloud discover the workloads and build an AI Bill of Materials, deploy with
`-EnableDefenderCspm`. Defender CSPM bills across your whole subscription, so it's off unless you ask. If
it's already on, the script leaves it alone.

Then build the pull request, from Bash in this folder:

```bash
bash Deploy-C1M04PipelineGate.sh
```

It creates the repository under the account `gh` is signed in as. To use an organization, run
`OWNER=<your-org> bash Deploy-C1M04PipelineGate.sh`. The repository is public by default, because branch
protection on a private repository needs a paid GitHub plan; see GitHub's
[about protected branches](https://docs.github.com/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches)
page. Nothing in it is real: the code is a stub and the planted key uses a format invented for
Globomantics.

## What to look for

**The estate already knows.** In the Azure portal, open **Resource Graph Explorer**, paste
`iac\find-ai-workloads.kql`, and run it. Both workloads come back, with their kind and region. The
script's `-Mode Show` prints the same thing, plus the model behind each one.

**What the inventory can't tell you.** Read the `GovernanceState` column. One workload was never
submitted for review, and the other is blocked waiting on a data boundary. That column is a tag:
nothing validates it, nothing requires it, and deleting it changes nothing about whether either workload
serves traffic. Then read across the other columns. There's no column for the data boundary, none for
where the shared responsibility line sits, and none for who owns the risk. Those are decisions, and no
inventory records a decision.

You can make the tag mandatory with the built-in Azure Policy definition that requires a tag on
resources, assigned at a management group with a Deny effect, the way the Module 3 lab assigns its
rules. That gets you a tag that's always populated. It doesn't get you a tag that's always true.

**The gate that has to exist first.** Open `..\..\demo-artifacts\m04-ai-adoption-gate.html`. Every row
is a decision an architect signs before a model reaches production, and the last row is a name. Neither
Globomantics workload passes. When an organization has no documented position on AI data and no owner
for AI risk, the first recommendation isn't a content filter or another detection rule. It's defining
the objectives and the governance policy, because until somebody decides what's allowed, every technical
control enforces a rule that doesn't exist yet.

**Where the gate stops being a person.** Open the pull request the script printed, and give the checks a
minute or two. `credential-scan` fails and the merge is blocked; `build` and `unit-tests` pass beside it.
That asymmetry is the lesson: shift left doesn't remove the gate, it moves it onto every pull request.
Which findings block a release and which only report is the architect's decision.

**Defender for Cloud needs a day.** Its posture views and Cloud Security Explorer read a security graph
that publishes on a daily snapshot, so a workload you deploy this morning won't appear there this
afternoon. Resource Graph reads Azure Resource Manager directly, which is why the query works right
away.

## What it costs

Both Foundry accounts use the S0 tier, which carries no standing charge, and model deployments bill per
token. Nothing in the lab calls the endpoints, so an idle lab costs effectively nothing. Defender CSPM, if
you turn it on, bills per billable resource across your whole subscription until you turn it off. The
GitHub repository runs three short workflows on each push. Remove both labs when you're done.

## Clean up

```powershell
pwsh -NoProfile -File .\Deploy-C1M04AIWorkload.ps1 -Mode Remove
```

Remove deletes the resource group and then purges both soft-deleted Foundry accounts, because a deleted
account keeps its name reserved and a redeploy into the same resource group would collide with it. If
this lab turned Defender CSPM on, Remove sets it back to the Free tier.

```bash
MODE=remove bash Deploy-C1M04PipelineGate.sh
```

That deletes the GitHub repository, and only if the script created it. Deleting a repository needs the
`delete_repo` scope on your `gh` sign-in. If it's refused, run
`gh auth refresh -h github.com -s delete_repo` and try again.

If you'd rather clean up Azure by hand:

```powershell
az cognitiveservices account list --resource-group rg-globomantics-c1m04 --query "[].{name:name, location:location}" -o table
az group delete --name rg-globomantics-c1m04 --yes
az cognitiveservices account purge --location <location> --resource-group rg-globomantics-c1m04 --name <account-name>

# Only if you turned Defender CSPM on for this lab:
az security pricing create --name CloudPosture --tier Free
```

Run the purge once for each account the list printed.
