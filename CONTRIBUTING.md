# Contributing

Thanks for helping keep this repo current. Microsoft renames products and moves pages constantly,
so the most useful thing you can send me is a precise report of something that drifted.

## Report a drifted link, a renamed product or a broken lab

Open an issue and include:

- **The course and module**, for example "Course 3, Module 2."
- **The file**, for example `courses/03-infrastructure/scripts/m02-server-coverage/README.md`.
- **What you saw and what you expected.** For a lab, paste the command you ran and the full error
  text, with your subscription and tenant IDs removed.
- **Your environment:** PowerShell version (`$PSVersionTable.PSVersion`), Azure CLI version
  (`az version`), and whether you ran it locally or in Azure Cloud Shell.

For a renamed or retired product, link the Microsoft Learn page that shows the current name. I
check every name against a first-party Microsoft page before it goes in, so that link is what lets
me fix it quickly.

## Pull requests

Small fixes are welcome: a corrected link, a typo, a script that fails on macOS or Linux. Please
keep each pull request to one fix, and never commit anything from your own tenant, such as IDs,
user names or domain names. Changes to what a course teaches stay with me, because they have to
match the videos.

## Code style

Lab code here is a teaching artifact. Comments explain why, not what. Scripts take their subscription
and tenant from the learner's own sign-in, validate their parameters, fail with a readable message,
and are safe to run twice. Output never carries meaning by color alone; use words such as `[OK]`
and `[FAIL]`.
