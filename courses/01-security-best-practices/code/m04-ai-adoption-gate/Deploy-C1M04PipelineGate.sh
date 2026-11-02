#!/usr/bin/env bash
# =============================================================================
# Deploy-C1M04PipelineGate.sh
#
# Builds, or removes, the GitHub repository for the DevSecOps half of SC-100
# Course 1, Module 4: a pull request where a credential-scanning check has FAILED
# and is BLOCKING THE MERGE, with two other checks passing beside it. That
# asymmetry is the whole lesson. One failed check on its own proves nothing,
# because it doesn't show what DIDN'T block.
#
# WHAT IT CREATES, in the GitHub account or organization you name:
#   repo  globomantics-storefront-api (public by default, see VISIBILITY below)
#   main  a small Node service, three workflows, branch protection requiring all three
#   PR    feature/add-payment-provider, which plants a FAKE Globomantics payment key
#         -> credential-scan FAILS and blocks the merge
#         -> build and unit-tests PASS beside it
#
# WHY A PINNED GITLEAKS BINARY AND NOT A MARKETPLACE ACTION
#   The popular gitleaks action needs a paid license for organization-owned
#   repositories. Installing the gitleaks binary from a pinned release avoids the
#   license, the marketplace dependency, and a surprise when you least want one.
#
# WHY THE BLOCKING CHECK IS A WORKFLOW AND NOT SECRET SCANNING
#   GitHub secret scanning and push protection are switched on below, because a
#   realistic repository has them. But push protection blocks a PUSH, which is a
#   different screen and a different lesson. The merge-blocking pull request check
#   is the repository's own credential-scan workflow, made required by branch
#   protection. That's what "gating control" means in a DevSecOps pipeline.
#
# THE PLANTED KEY IS FAKE AND DELIBERATELY NOT A REAL PROVIDER FORMAT
#   'gk_live_' is invented for Globomantics. A real cloud provider's key pattern
#   would trip GitHub push protection and block this script's own push, and it
#   would mean committing something shaped like a live credential.
#
# PREREQUISITES
#   bash, git, and the GitHub CLI (gh), authenticated:  gh auth status
#   Azure Cloud Shell has all three. On Windows, Git Bash or WSL works.
#
# SETTINGS (environment variables, all optional)
#   MODE        deploy (default) or remove
#   OWNER       GitHub user or organization to create the repo in.
#               Defaults to the account gh is signed in as.
#   REPO        Repository name. Defaults to globomantics-storefront-api.
#   VISIBILITY  public (default) or private. Branch protection on a PRIVATE
#               repository needs a paid GitHub plan (Pro, Team, or Enterprise
#               Cloud); on GitHub Free it works on public repositories only.
#
# USAGE
#   bash Deploy-C1M04PipelineGate.sh
#   OWNER=my-org bash Deploy-C1M04PipelineGate.sh
#   MODE=remove bash Deploy-C1M04PipelineGate.sh
#
# COST
#   Nothing on Azure. On GitHub, each push runs three short workflows.
#
# CLEANUP
#   MODE=remove bash Deploy-C1M04PipelineGate.sh
#   Deleting a repository needs the delete_repo scope on your gh token:
#     gh auth refresh -h github.com -s delete_repo
# =============================================================================
set -euo pipefail

MODE="${MODE:-deploy}"
REPO="${REPO:-globomantics-storefront-api}"
VISIBILITY="${VISIBILITY:-public}"
BRANCH='feature/add-payment-provider'
# The gitleaks version the workflow installs is pinned inside credential-scan.yml below.

# Fictional commit identities, so nothing personal ever lands in the repository's history.
PLATFORM_GIT=(-c user.name='Globomantics Platform Team' -c user.email='platform@globomantics.example')
DEV_GIT=(-c user.name='Globomantics Dev' -c user.email='dev@globomantics.example')

for tool in git gh; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "[FAIL] $tool isn't installed. Install it, or run this in Azure Cloud Shell."
    exit 2
  fi
done
if ! gh auth status >/dev/null 2>&1; then
  echo "[FAIL] gh isn't signed in. Run: gh auth login"
  exit 2
fi
case "$VISIBILITY" in
  public|private) ;;
  *) echo "[FAIL] VISIBILITY must be public or private, not '$VISIBILITY'."; exit 2 ;;
esac

OWNER="${OWNER:-$(gh api user --jq .login)}"
echo "[INFO] target: $OWNER/$REPO ($VISIBILITY), mode $MODE"

if [ "$MODE" = "remove" ]; then
  if ! gh repo view "$OWNER/$REPO" >/dev/null 2>&1; then
    echo "[OK] $OWNER/$REPO is already absent."
    exit 0
  fi
  # Only delete a repository this script built: its description says so.
  if ! gh repo view "$OWNER/$REPO" --json description --jq .description | grep -q 'SC-100 Course 1 Module 4'; then
    echo "[FAIL] $OWNER/$REPO exists but wasn't created by this script. Refusing to delete it."
    exit 1
  fi
  if gh repo delete "$OWNER/$REPO" --yes; then
    echo "[OK] Deleted $OWNER/$REPO."
  else
    echo "[FAIL] Couldn't delete $OWNER/$REPO. Your gh token probably lacks the delete_repo scope:"
    echo "       gh auth refresh -h github.com -s delete_repo"
    exit 1
  fi
  exit 0
fi

if [ "$MODE" != "deploy" ]; then
  echo "[FAIL] MODE must be deploy or remove, not '$MODE'."
  exit 2
fi

# Idempotent in the safe direction: if the repository exists, stop rather than clobber it.
if gh repo view "$OWNER/$REPO" >/dev/null 2>&1; then
  echo "[STOP] $OWNER/$REPO already exists. For a clean rebuild, remove it first:"
  echo "       MODE=remove bash Deploy-C1M04PipelineGate.sh"
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "[INFO] creating $VISIBILITY repo $OWNER/$REPO ..."
gh repo create "$OWNER/$REPO" "--$VISIBILITY" \
  --description 'Globomantics storefront API - SC-100 Course 1 Module 4 teaching repo (pipeline gate)' >/dev/null

cd "$WORK"
gh repo clone "$OWNER/$REPO" repo >/dev/null 2>&1
cd repo
# Let git push with the same sign-in gh already has. --local keeps it inside this
# throwaway clone, so your global git configuration is never touched.
git config --local credential.helper '!gh auth git-credential'
git checkout -b main 2>/dev/null || git checkout main

# --- the service being built -------------------------------------------------
mkdir -p src .github/workflows

cat > README.md <<'EOF'
# Globomantics storefront API

Order-intake service for the Globomantics storefront.

> **This repository is a teaching repo** for the SC-100 skill path, Course 1
> Module 4, "Design for Secure AI Adoption and DevSecOps." It exists to show a
> gating control stopping a release. Globomantics is a fictional company, nothing
> here is production code, and no credential in this repository is real.

## Pipeline controls

| Check | What it does | Gates the merge |
|---|---|---|
| `credential-scan` | Scans the history for committed credentials | **Yes** |
| `build` | Compiles and packages the service | No, reports only |
| `unit-tests` | Runs the unit suite | No, reports only |

Credential scanning is the check that gates here: it stops leaking code from
merging. Everything else informs. Which checks block a release, and which only
report, is the architect's decision.
EOF

cat > src/config.js <<'EOF'
// Globomantics storefront API - runtime configuration.
//
// Every secret is read from the environment at boot. Nothing is committed.
// The deployment pipeline injects these from the platform team's key vault, so
// a developer never handles a production credential and a credential never
// reaches source control. That is the design the credential-scan check protects.
module.exports = {
  port: process.env.PORT || 8080,
  // Payment provider credentials - injected at deploy time, never committed.
  paymentKey: process.env.GLOBOMANTICS_PAYMENT_KEY,
  paymentEndpoint: process.env.GLOBOMANTICS_PAYMENT_ENDPOINT,
};
EOF

cat > package.json <<'EOF'
{
  "name": "globomantics-storefront-api",
  "version": "1.4.0",
  "private": true,
  "description": "Order-intake service for the Globomantics storefront",
  "scripts": {
    "build": "node -e \"require('./src/config.js'); console.log('build ok')\"",
    "test": "node -e \"console.log('12 passing')\""
  }
}
EOF

# --- the gating control ------------------------------------------------------
cat > .github/workflows/credential-scan.yml <<'EOF'
# Credential scanning - THE GATING CONTROL.
#
# Branch protection makes this check required, so a finding here blocks the merge
# rather than filing a report somebody reads later.
#
# It installs the gitleaks BINARY from a pinned release rather than using the
# marketplace action, which needs a paid license for organization repositories.
name: credential-scan

on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  scan:
    name: credential-scan
    runs-on: ubuntu-latest
    steps:
      - name: Check out the full history
        uses: actions/checkout@v4
        with:
          # gitleaks scans history, not just the tip commit.
          fetch-depth: 0

      - name: Install gitleaks (pinned)
        env:
          GITLEAKS_VERSION: '8.28.0'
        run: |
          set -euo pipefail
          curl -sSL -o /tmp/gitleaks.tar.gz \
            "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz"
          tar -xzf /tmp/gitleaks.tar.gz -C /tmp gitleaks
          sudo mv /tmp/gitleaks /usr/local/bin/gitleaks
          gitleaks version

      - name: Scan for committed credentials
        run: |
          set -euo pipefail
          # --redact so a finding never prints the secret itself into a public log.
          # Exit code 1 means findings, which fails this job and holds the merge.
          gitleaks detect \
            --source . \
            --config .gitleaks.toml \
            --redact \
            --verbose \
            --report-format sarif \
            --report-path gitleaks.sarif

      - name: Upload findings
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: credential-scan-findings
          path: gitleaks.sarif
          if-no-files-found: ignore
EOF

cat > .gitleaks.toml <<'EOF'
# gitleaks configuration for the Globomantics storefront API.
#
# Extends the default ruleset (which covers the well-known cloud and SaaS
# providers) and adds the house pattern for Globomantics-issued payment keys,
# because a scanner that only knows other companies' formats will miss the
# credential your own platform team hands out.
title = "Globomantics credential scan"

[extend]
useDefault = true

[[rules]]
id = "globomantics-payment-key"
description = "Globomantics payment provider key"
# gk_live_ prefix followed by 24 or more base62 characters.
regex = '''gk_live_[0-9a-zA-Z]{24,}'''
tags = ["key", "globomantics", "payment"]
EOF

# --- the two controls that REPORT rather than gate ---------------------------
cat > .github/workflows/build.yml <<'EOF'
# Build - reports, doesn't gate on its own.
name: build
on:
  pull_request:
  push:
    branches: [main]
permissions:
  contents: read
jobs:
  build:
    name: build
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '20'
      - run: npm run build
EOF

cat > .github/workflows/unit-tests.yml <<'EOF'
# Unit tests - reports, doesn't gate on its own.
name: unit-tests
on:
  pull_request:
  push:
    branches: [main]
permissions:
  contents: read
jobs:
  test:
    name: unit-tests
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '20'
      - run: npm test
EOF

git add -A
git "${PLATFORM_GIT[@]}" commit -q -m 'Initial storefront API with pipeline security controls'
git push -q -u origin main
echo "[OK] main pushed"

# --- the real GitHub security surfaces ---------------------------------------
# Secret scanning and push protection are switched on because a realistic repo has
# them. They don't produce the merge-blocking check. The workflow does.
echo "[INFO] enabling secret scanning and push protection ..."
if gh api -X PATCH "repos/$OWNER/$REPO" \
  -F 'security_and_analysis[secret_scanning][status]=enabled' \
  -F 'security_and_analysis[secret_scanning_push_protection][status]=enabled' >/dev/null 2>&1; then
  echo "[OK] secret scanning and push protection on"
else
  echo "[WARN] couldn't enable secret scanning. On a private repository it needs GitHub Advanced Security. The lab still works."
fi

# --- branch protection: this is what makes the merge block --------------------
echo "[INFO] requiring the three checks on main ..."
if gh api -X PUT "repos/$OWNER/$REPO/branches/main/protection" --input - >/dev/null <<'JSON'
{
  "required_status_checks": {
    "strict": false,
    "contexts": ["credential-scan", "build", "unit-tests"]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": null,
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
JSON
then
  echo "[OK] branch protection on"
else
  echo "[FAIL] couldn't protect main. On GitHub Free, branch protection works on public repositories only."
  echo "       Remove the repo (MODE=remove) and rerun with VISIBILITY=public, or use a paid plan."
  exit 1
fi

# --- the pull request that gets stopped --------------------------------------
git checkout -q -b "$BRANCH"

cat > src/payment-provider.js <<'EOF'
// Payment provider integration for the storefront checkout flow.
//
// NOTE FOR REVIEWERS: hardcoded the key to unblock local testing against the
// sandbox. Will move it to the vault before we ship. -- dev
//
// THIS IS A FAKE, NON-FUNCTIONAL KEY committed on purpose so the credential-scan
// gate has something to catch. The gk_live_ format is invented for Globomantics.
const providerKey = 'gk_live_8Qf3xNv2LpR7wZaK4mTdY9Hb';

module.exports = {
  key: providerKey,
  endpoint: 'https://sandbox.payments.globomantics.example/v2',
};
EOF

git add -A
git "${DEV_GIT[@]}" commit -q -m 'Add payment provider integration for checkout'
git push -q -u origin "$BRANCH"

PR_URL=$(gh pr create --repo "$OWNER/$REPO" \
  --base main --head "$BRANCH" \
  --title 'Add payment provider integration for checkout' \
  --body 'Wires the checkout flow up to the sandbox payment provider so QA can run end-to-end orders. Ready for review.')

echo
echo "==============================================================="
echo " PULL REQUEST: $PR_URL"
echo "==============================================================="
echo
echo " Give the checks a minute or two, then open the Checks tab. Expect:"
echo "   credential-scan   FAILED    (holds the merge)"
echo "   build             passed"
echo "   unit-tests        passed"
echo "   and the text 'Merging is blocked'"
echo
echo " Watch it from here:  gh pr checks $PR_URL --watch"
echo " Remove it later:     MODE=remove bash Deploy-C1M04PipelineGate.sh"
echo
