# SC-100 Course 4 exercise files

**SC-100: Designing Security Solutions for Applications and Data**, by Tim Warner, Course 4 of the
[SC-100: Microsoft Cybersecurity Architect](https://www.pluralsight.com/paths/sc-100-microsoft-cybersecurity-architect) skill path on Pluralsight.
Prepared Wednesday, October 28, 2026, 12:02 PM CDT. Links verified Monday, November 2, 2026.

Open `SC-100-Course-4-Resources.html` in any browser. It runs offline: search, filtering and navigation all work
locally, and you only need a connection when you open a Microsoft page.

## What's in the box

| File | What it is |
|---|---|
| `SC-100-Course-4-Resources.html` | The Microsoft documentation behind every clip in the course: 119 first-party links across 28 clips, linked inline module by module, each one checked live. |
| `slides/` | The slides for every module as a PDF, exactly as they appear in the course. |
| `code/` | The files behind every demo, one folder per module. See **Lab files** below. |
| `README.md` | This file. |

## How to use it

Find the clip you just watched. Its paragraph links the Microsoft documentation right on the phrase
it backs up, and the link marked **READ FIRST** is where to start, usually the Microsoft Learn unit
for that objective. When
a link carries a status word such as **PREVIEW** or **RETIRING**, read that first, because a
feature's status changes how you'd answer an exam item about it.

Before exam day, read the **Names and status** table. It lists the products Microsoft has renamed
or retired, which is exactly where older pages and training data will steer you wrong.

## Lab files

| Folder | Demo | What you get |
|---|---|---|
| `code/m01-copilot-oversharing` | Module 1: trace a Copilot answer to the files behind it | A step-by-step guide for a Microsoft 365 test tenant, and the two fictional Globomantics documents |
| `code/m02-threat-model` | Module 2: threat model the Connected Equipment API | The saved Threat Modeling Tool model, the threat register behind it, and the design in plain JSON |
| `code/m03-api-front-door` | Module 3: read the API front door | One script to plan, deploy, read, test and remove the lab, its Bicep, and the gateway policy |
| `code/m04-data-path` | Module 4: audit the customer assistant's data path | One script to plan, deploy, read and remove the lab, and its Bicep |

Start with the README in each module folder. It gives you that lab's prerequisites, the exact run
order, and the cleanup commands.

**The Module 3 and Module 4 labs deploy real, billable Azure resources.** Run them in a subscription
you use for learning, never in production, and remove each lab the same day with its
`-Mode Remove` command. The Module 3 lab bills by the hour whether or not you're using it. The
Module 1 lab changes a Microsoft 365 tenant, so use a test tenant.

You'll need PowerShell 7 and the Azure CLI for Modules 3 and 4, on Windows, macOS or Linux, and the
free Microsoft Threat Modeling Tool for Module 2.

## Course repository

The course repository is https://github.com/timothywarner-org/ps-sc100, and it holds the exercise
files for all four courses in the SC-100 skill path.

## Currency

The links were checked against the SC-100 skills measured as of **October 21, 2026**. That revision's
only Domain 4 change renamed the product in objective 4.1.5 to Microsoft 365 Copilot. Microsoft
moves pages, so if a link has drifted by the time you click it, search Microsoft Learn for the words
in the link.

## About Globomantics

Globomantics is a fictional company, and every scenario detail in the course is invented for
teaching. Nothing here describes a real organization or a real assessment.

## Accessibility

No meaning on the page is carried by color alone. Every status is a word in a bordered tag, the
page defaults to a dark theme with a light theme one click away, and it prints in black on white.

## More from me

TechTrainerTim.com
