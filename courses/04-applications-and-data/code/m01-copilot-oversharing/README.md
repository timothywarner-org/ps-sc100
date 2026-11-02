# Module 1 lab: trace a Copilot answer to the files behind it

This lab rebuilds the scenario behind the demo "Trace a Copilot answer to the files behind it" in a
Microsoft 365 test tenant. You'll put a labeled margin report on an overshared site, let Copilot
answer from it, and then prove from the audit record that Copilot only used a file you could already
open. That proof is what supports fixing access at the source instead of pulling Copilot licenses.

Globomantics is a fictional company, and both documents open with a line marking them as fictional
training data.

## What's in the folder

| File | What it is |
|---|---|
| `files/Materials Q3 margin report.docx` | The file worth worrying about: fictional margins and floor prices |
| `files/Coolant pump product sheet.docx` | A harmless product sheet for the second site, so you have a real choice to make at the end |
| `README.md` | This guide |

## Before you start

- **A Microsoft 365 E5 test tenant**, never your organization's production tenant. This lab creates
  groups and sites and changes what Copilot can see.
- **A Microsoft 365 Copilot license** on the account you'll ask Copilot with.
- **A sensitivity label that marks content without encrypting it.** The course calls it Highly
  Confidential. Check its settings in the Microsoft Purview portal under Information Protection,
  Sensitivity labels. A label that encrypts changes the outcome, because Copilot honors the usage
  rights on encrypted content.
- **Rights to create Microsoft 365 groups and to search the audit log**, and access to Data Security
  Posture Management in the Microsoft Purview portal.

There's no Azure cost. The lab uses licenses the tenant already holds.

## Build the scenario

Allow three days from start to finish, because indexing and the data risk assessment both take time.

1. **Create two public sites.** Create two Microsoft 365 groups with public privacy, named
   **GLB Materials Pricing** and **GLB Product Marketing**. Make a different account the owner of both,
   and make sure the account you'll ask Copilot with is neither an owner nor a member. Your access then
   comes only from the public setting, which is the overshare you're about to prove.
2. **Upload the documents.** In GLB Materials Pricing, create a folder named **Pricing** and upload
   `Materials Q3 margin report.docx`. In GLB Product Marketing, create a folder named
   **Product sheets** and upload `Coolant pump product sheet.docx`.
3. **Label the margin report.** Open it in Word for the web and apply your non-encrypting label from
   Sensitivity. The next day, check that the library's Sensitivity column shows it. Microsoft
   documents a delay for labels that don't encrypt.
4. **Start a custom data risk assessment.** In the Microsoft Purview portal, open Data Security
   Posture Management, then Discover, then Data risk assessments, and create a custom assessment
   scoped to the two sites. Results take at least 48 hours. The portal marks custom assessments as
   preview.
5. **Ask Copilot, at least a day after the upload.** Open Microsoft Copilot at
   `copilot.cloud.microsoft` with your Copilot-licensed account, make sure it's answering from work
   content, and ask: *Summarize Globomantics Materials third-quarter pricing and margins.* Continue
   once the answer's references include the margin report. If they don't, the file isn't indexed yet,
   so ask again the next day.

## Trace the answer

1. **Find the interaction.** In the Microsoft Purview portal, open Audit and run a search for the
   operation `CopilotInteraction`, filtered to your account, with a UTC time range around the moment
   you asked. Searches run as jobs, so wait for the job to complete.
2. **Read the record.** Open the row whose activity reads Interacted with Copilot and find the
   accessed resources. You should see the margin report's file name, the GLB Materials Pricing site
   address, and a sensitivity label ID. The record holds no prompt or response text.
3. **Explain the access.** Open the GLB Materials Pricing site's permissions. On a public
   group-connected site, Everyone except external users sits in the Members group with Edit access,
   so everyone in the tenant could already open that file. Copilot created no new access.
4. **Pick the fix.** Open your data risk assessment and compare the two sites. Which one would you fix
   first, and how? Commit to an answer before you read on.

**The answer the course defends:** fix the margin report's site first, because it holds the
sensitive file behind broad access. Make the site private, or remove Everyone except external users
from it. While that change works through the business, Restricted Content Discovery hides the site
from Copilot without changing its permissions. If the site has to stay open but the labeled file must
stay out of answers, a data loss prevention policy for the Microsoft 365 Copilot location, conditioned
on the label, does that job.

## Clean up

Delete the two Microsoft 365 groups, which removes their sites. Deleted groups stay restorable for
30 days, so you can undo a mistake. Delete the custom assessment too if you no longer need it, or let
it expire.
