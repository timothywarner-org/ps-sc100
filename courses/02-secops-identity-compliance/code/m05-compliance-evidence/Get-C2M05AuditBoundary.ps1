#Requires -Version 7.2

<#
.SYNOPSIS
Measures how far back your tenant's unified audit log actually reaches, and how much of an evidence
window it can cover. Read-only.

.DESCRIPTION
The first half of the Module 5 demo walks one Globomantics obligation to its evidence: records
sufficient to evaluate whether access to the restricted Materials formulation library was limited to
authorized people, for a stated period. Before you can promise that evidence, you need one number the
portal won't hand you directly: the date of the oldest audit record you can still retrieve.

This script measures it instead of assuming it.

    1. THE ARITHMETIC FIRST. Audit (Standard) keeps records for 180 days by default. Audit (Premium)
       keeps Microsoft Entra, Exchange, OneDrive and SharePoint records for one year by default.
       A window that opens earlier than your retention reaches can't be fully evidenced, whatever the
       tenant holds, so the script says so before it signs in.
    2. THE PROBE. It searches backwards in 30-day blocks for the oldest block that returns records,
       then walks that block day by day and reports the true oldest record's own timestamp.
    3. A FAILED SEARCH ISN'T AN EMPTY ONE. Audit searches can fail mid-run when a session ages out.
       A failure is reported as UNKNOWN, retried once, and it changes the verdict, because "nothing
       before that date" isn't established while any search in the range failed.

A retention policy you create today governs collection from today forward. It restores nothing that
has already aged out, and this measurement is how you show that rather than assert it.

.PARAMETER WindowStart
The first day the obligation covers. Defaults to September 1, 2025, the fictional Globomantics window.

.PARAMETER WindowEnd
The last day the obligation covers. Defaults to August 31, 2026.

.PARAMETER UserPrincipalName
Optional. The account to sign in to Exchange Online with. Leave it out to choose in the sign-in prompt.

.PARAMETER CheckRetentionPolicies
Also connect to Security & Compliance PowerShell and list your audit log retention policies, which is
one of the things that decides where the boundary falls.

.EXAMPLE
pwsh -NoProfile -File .\Get-C2M05AuditBoundary.ps1
Measures the boundary against the fictional Globomantics window.

.EXAMPLE
pwsh -NoProfile -File .\Get-C2M05AuditBoundary.ps1 -WindowStart 2026-01-01 -WindowEnd 2026-06-30 -CheckRetentionPolicies
Measures it against your own window and lists the retention policies that shape it.

.OUTPUTS
Exit 0 when the window is fully covered, 1 when it's partly covered, not covered or not established,
2 when the script couldn't connect.

.NOTES
PREREQUISITES
    * The ExchangeOnlineManagement module: Install-Module ExchangeOnlineManagement -Scope CurrentUser
    * The View-Only Audit Logs or Audit Logs role in Exchange Online, which the Compliance Management
      and Organization Management role groups include.

It changes nothing in your tenant.

Search the audit log:            https://learn.microsoft.com/purview/audit-search
Audit log retention policies:    https://learn.microsoft.com/purview/audit-log-retention-policies
Search-UnifiedAuditLog:          https://learn.microsoft.com/powershell/module/exchangepowershell/search-unifiedauditlog
#>
[CmdletBinding()]
param(
    [datetime]$WindowStart = ([datetime]'2025-09-01'),
    [datetime]$WindowEnd = ([datetime]'2026-08-31'),
    [string]$UserPrincipalName,
    [switch]$CheckRetentionPolicies
)

$ErrorActionPreference = 'Stop'
if ($WindowEnd -le $WindowStart) { throw 'WindowEnd must be later than WindowStart.' }
$today = [datetime]::UtcNow.Date
$exitCode = 0

function Search-Block {
    <#
    One audit search, retried once. Returns @{ Records; Failed }. An empty result is cheap to confirm
    and a dead session is cheap to survive, so neither one is believed on the first try.
    #>
    param([datetime]$Start, [datetime]$End, [int]$Size = 1)
    $err = $null
    $records = Search-UnifiedAuditLog -StartDate $Start -EndDate $End -ResultSize $Size -ErrorAction SilentlyContinue -ErrorVariable err
    if (-not $records) {
        Start-Sleep -Seconds 3
        $err = $null
        $records = Search-UnifiedAuditLog -StartDate $Start -EndDate $End -ResultSize $Size -ErrorAction SilentlyContinue -ErrorVariable err
    }
    @{ Records = @($records); Failed = [bool]$err }
}

# --- 1. the arithmetic, before any sign-in --------------------------------------------
$openDays = [int]($today - $WindowStart.Date).TotalDays
Write-Host ''
Write-Host ("[INFO] Evidence window      {0:yyyy-MM-dd} to {1:yyyy-MM-dd}, opening {2} days ago" -f $WindowStart, $WindowEnd, $openDays)
Write-Host ("[INFO] Audit (Standard) default retention reaches back to {0:yyyy-MM-dd} (180 days)" -f $today.AddDays(-180))
Write-Host ("[INFO] Audit (Premium) default retention reaches back to  {0:yyyy-MM-dd} (one year, for the workloads it covers)" -f $today.AddDays(-365))
if ($WindowStart.Date -lt $today.AddDays(-365)) {
    Write-Host ("[WARN] The window opens {0} days before even the one-year default reaches." -f [int]($today.AddDays(-365) - $WindowStart.Date).TotalDays)
    Write-Host '       Its start can be evidenced only if a longer retention policy was already in place back then.'
}

# --- 2. connect --------------------------------------------------------------------------
# The module builds a log path from TMP when it loads. In a process that inherited a trimmed
# environment TMP is empty, and the import fails with an error about a null Path that looks nothing
# like the real cause. Point it at the system temp folder first.
if ([string]::IsNullOrWhiteSpace($env:TMP)) { $env:TMP = [System.IO.Path]::GetTempPath() }
if (-not (Get-Module -ListAvailable ExchangeOnlineManagement)) {
    Write-Host '[FAIL] The ExchangeOnlineManagement module is missing. Run: Install-Module ExchangeOnlineManagement -Scope CurrentUser'
    exit 2
}
try {
    Import-Module ExchangeOnlineManagement -ErrorAction Stop
    $connect = @{ ShowBanner = $false; ErrorAction = 'Stop' }
    if ($UserPrincipalName) { $connect.UserPrincipalName = $UserPrincipalName }
    Write-Host '[INFO] Connecting to Exchange Online. Complete the sign-in prompt.'
    Connect-ExchangeOnline @connect
}
catch {
    # Report the real error. The module is installed, so this is almost always a cancelled or
    # timed-out sign-in, or an account without the audit roles.
    Write-Host "[FAIL] Couldn't connect: $($_.Exception.Message)"
    exit 2
}

try {
    # Informational only. The search result decides, because a setting describes intent and the
    # search is the evidence.
    $ingestion = $null
    try { $ingestion = (Get-AdminAuditLogConfig).UnifiedAuditLogIngestionEnabled } catch { $ingestion = 'unreadable' }
    Write-Host "[INFO] UnifiedAuditLogIngestionEnabled: $ingestion (the probe below is what decides)"

    # --- 3. probe 30-day blocks, newest to oldest ---------------------------------------------
    # One wide search is slow, throttles, and an empty answer couldn't tell retention from a quiet month.
    Write-Host ''
    Write-Host 'Probing 30-day blocks for the oldest one that returns records...'
    $oldestBlock = $null
    $unknown = [System.Collections.Generic.List[datetime]]::new()
    for ($d = 30; $d -le 420; $d += 30) {
        $s = $today.AddDays(-$d); $e = $today.AddDays(-$d + 30)
        $r = Search-Block -Start $s -End $e
        if ($r.Failed) { $mark = 'UNKNOWN (the search failed; that isn''t proof of empty)'; $unknown.Add($s) }
        elseif ($r.Records.Count) { $mark = 'records'; $oldestBlock = $s }
        else { $mark = 'none' }
        Write-Host ("  {0:yyyy-MM-dd} to {1:yyyy-MM-dd}  {2}" -f $s, $e, $mark)
    }
    if (-not $oldestBlock) {
        Write-Host '[FAIL] No block returned records. Check that auditing is on and that your account holds an audit role.'
        exit 1
    }

    # --- 4. walk the oldest block day by day for the true first record ------------------------
    # A block's start date is only the earliest the boundary could be. The record's own timestamp
    # is the measurement.
    Write-Host ''
    Write-Host ("Walking {0:yyyy-MM-dd} to {1:yyyy-MM-dd} one day at a time..." -f $oldestBlock, $oldestBlock.AddDays(30))
    $trueOldest = $null
    for ($i = 0; $i -lt 30 -and -not $trueOldest; $i++) {
        $dayStart = $oldestBlock.AddDays($i)
        $r = Search-Block -Start $dayStart -End $dayStart.AddDays(1) -Size 5000
        if ($r.Failed) { $unknown.Add($dayStart); continue }
        if ($r.Records.Count) { $trueOldest = ($r.Records | Measure-Object -Property CreationDate -Minimum).Minimum }
    }

    Write-Host ''
    if ($trueOldest) {
        $reach = [int]($today - $trueOldest.Date).TotalDays
        Write-Host ("[OK] Oldest retrievable record: {0:yyyy-MM-dd HH:mm}, {1} days back" -f $trueOldest, $reach)
        if ($trueOldest.Date -le $WindowStart.Date) {
            Write-Host '[OK] The evidence window is covered from its first day.'
        }
        else {
            $gap = [int]($trueOldest.Date - $WindowStart.Date).TotalDays
            Write-Host ("[WARN] The first {0} days of the window have no records behind them. That gap is the finding." -f $gap)
            $exitCode = 1
            if ($reach -ge 170 -and $reach -le 195) {
                Write-Host ''
                Write-Host '[INFO] The boundary sits near 180 days, the Audit (Standard) default. Check before you name a cause:'
                Write-Host '         the users who performed the activity may lack Audit (Premium) licensing, or be guests'
                Write-Host '         the activity may come from a workload the default one-year policy doesn''t cover'
                Write-Host '         a custom retention policy shorter than a year may take priority'
                Write-Host '       Rerun with -CheckRetentionPolicies to see the policies.'
            }
        }
    }
    else {
        Write-Host '[WARN] The boundary couldn''t be resolved to a day, so it stays a 30-day band.'
        $exitCode = 1
    }
    if ($unknown.Count) {
        Write-Host ("[WARN] {0} search(es) failed, so the gap is UNKNOWN in those ranges, not empty. Reconnect and rerun." -f $unknown.Count)
        $exitCode = 1
    }
}
finally {
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
}

if ($CheckRetentionPolicies) {
    # Audit log retention policies live in Security & Compliance PowerShell, not Exchange Online.
    Write-Host ''
    Write-Host 'AUDIT LOG RETENTION POLICIES'
    try {
        Connect-IPPSSession -ShowBanner:$false -ErrorAction Stop
        $policies = @(Get-UnifiedAuditLogRetentionPolicy | Sort-Object Priority)
        if ($policies.Count) { $policies | Format-List Priority, Name, RecordTypes, Operations, UserIds, RetentionDuration | Out-String -Width 160 | Write-Host }
        else { Write-Host '  No custom policies. The default retention for each user and workload applies.' }
    }
    catch { Write-Host "[WARN] Couldn't read the retention policies: $($_.Exception.Message)" }
    finally { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null }
}

Write-Host ''
Write-Host 'The audit record is only half the evidence. You also need the authorization that was in force at the'
Write-Host 'time: who approved access to the library, and when. Line the two up before you call the control met.'
exit $exitCode
