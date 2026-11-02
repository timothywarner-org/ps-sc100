# corpus/ holds your downloaded copy of the SC-100 training

This folder holds Microsoft Learn's free training for course **SC-100T00** (4 learning
paths, 19 modules, 168 units) once you download it. It ships empty on purpose.

**The content belongs to Microsoft.** You download it to your own machine for personal
study, and this repository never redistributes it. The toolkit's `.gitignore` blocks
everything in this folder except this README, so your copy can't be committed by
accident. Don't publish it or share the folder.

## Download it

From the toolkit folder, in PowerShell 7 (Windows, macOS, or Linux) or Windows PowerShell 5.1:

```powershell
./scripts/Get-SC100Corpus.ps1
```

That clones the downloader into `.cache/` on first run, gives it its own virtual
environment, and pulls a fresh copy from Microsoft Learn. It takes about a minute.

## What lands here

```
corpus/
└── Microsoft Cybersecurity Architect/
    ├── 01-Design solutions that align with security best practices and priorities/
    ├── 02-Design security operations, identity, and compliance capabilities/
    ├── 03-Design security solutions for applications and data/
    └── 04-Design security solutions for infrastructure/
```

Each learning-path folder holds one Markdown file per module, a combined `_full.md`, and
an `images/` folder. Every unit keeps a `Source:` line with its Learn URL.

**Watch the numbering:** Microsoft's learning path `03` covers exam **Domain 4**
(applications and data), and path `04` covers exam **Domain 3** (infrastructure). The
chunker corrects for this, so every chunk records the exam domain, not the folder number.
