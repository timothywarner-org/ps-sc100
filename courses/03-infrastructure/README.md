# SC-100 Course 3 exercise files

**[SC-100: Designing Security Solutions for Infrastructure](https://www.pluralsight.com/courses/sc-100--designing-security-solutions-for-infrastructure)**, by Tim Warner, Course 3 of the
[SC-100: Microsoft Cybersecurity Architect](https://www.pluralsight.com/paths/sc-100-microsoft-cybersecurity-architect) skill path on Pluralsight.
Built Monday, October 5, 2026, 4:01 PM CDT. Links verified Monday, November 2, 2026.

Open `SC-100-Course-3-Resources.html` in any browser. It runs offline: search, filtering and navigation all work
locally, and you only need a connection when you open a Microsoft page.

## What's in the box

| File | What it is |
|---|---|
| `SC-100-Course-3-Resources.html` | The Microsoft documentation behind every clip in the course: 214 first-party links across 37 clips, organized module by module, each one checked live. |
| `slides/` | The slides for every module as a PDF, exactly as they appear in the course. |
| `scripts/` | The code behind every demo in the course, one folder per module, ready to run in your own subscription. See **Lab scripts** below. |
| `README.md` | This file. |

## How to use it

Find the clip you just watched and open the link marked **READ FIRST**. The links under it are the
product pages that back up the design call I made on screen. When a link carries a status tag such
as **PREVIEW** or **RETIRED**, read the tag first, because a feature's status changes how you'd
answer an exam item about it.

Before exam day, read the **Names and status** table. It lists the products Microsoft has renamed
or retired, which is exactly where older pages and training data will steer you wrong.

## Lab scripts

The `scripts` folder holds the code I ran in the demos, cleaned up so it runs in your subscription.
Every script takes its subscription and tenant from your own Azure CLI sign-in.

| Folder or file | Demo | What you get |
|---|---|---|
| `scripts/m01-attack-path` | Module 1: follow an attack path to a critical asset | The lab deploy, as PowerShell and as a Cloud Shell script, plus the Exposure Management query I used to check the path |
| `scripts/m02-server-coverage` | Module 2: server coverage and plan fit | The server estate deploy, its Bicep, and the plan table you saw on screen |
| `scripts/m03-foundry-review` | Module 3: a Foundry project against the AI controls | The Foundry lab deploy, with the permission gap I planted for you to find, and the review |
| `scripts/m04-private-access` | Module 4: vendor access with Private Access | The plant network deploy, the Private Access setup, and the review |
| `scripts/Show-C3Demo.ps1` | Modules 2 to 4 | Pages through a review one screen at a time, the way I did on screen. In the videos it's named Show-C3Recording.ps1; the screens are the same. |
| `scripts/Start-C3Lab.ps1` | Modules 1 to 4 | Starts a lab's stopped VMs and changes nothing else |

Start with the README in each module folder. It gives you that lab's prerequisites, the exact run
order, and the cleanup commands.

**These labs deploy real, billable Azure resources.** Run them in a subscription you use for
learning, never in production, and delete each lab when you've finished with it. Every module
README ends with the exact cleanup commands, and I'd run them the same day.

You'll need PowerShell 7 and the Azure CLI, on Windows, macOS or Linux. Where a module includes a
Cloud Shell script, Azure Cloud Shell works too.

## Currency

The links were checked against the SC-100 skills measured as of **October 21, 2026**. Domain 3 didn't
change in that revision. Microsoft moves pages, so if a link has drifted by the time you click it,
search Microsoft Learn for the title you see on the page.

## About Globomantics

Globomantics is a fictional company, and every scenario detail in the course is invented for
teaching. Nothing here describes a real organization or a real assessment.

## Accessibility

No meaning on the page is carried by color alone. Every status is a word in a bordered tag, the
page defaults to a dark theme with a light theme one click away, and it prints in black on white.

## More from me

TechTrainerTim.com
