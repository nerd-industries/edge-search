#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Nerdy Neighbor - Lock Microsoft Edge's default search engine (Google or
    DuckDuckGo) and kill the "switch back to Bing" prompt for good.

.DESCRIPTION
    Changing Edge's search engine in Settings is only a *user preference*, so
    Microsoft is allowed to nag the user to switch back to Bing - and one click
    on that popup reverts them. The only durable fix is to set the search
    provider by *policy*, which Edge honors silently and locks.

    Those policies (DefaultSearchProvider*) normally apply only on domain-joined
    or MDM-managed PCs. Residential machines are neither, so this script adds a
    minimal "fake MDM" enrollment stub that makes Edge treat the device as
    managed, which unlocks the policy. It then writes the search-provider policy
    plus the nag-suppression policies, and verifies.

.PARAMETER Engine
    'google' (default) or 'duckduckgo'. When run via `irm ... | iex` (no way to
    pass parameters), set the environment variable instead:
        $env:NN_SEARCH = 'duckduckgo'
    Or run non-interactively from an RMM the same way. If neither a parameter
    nor the env var is provided and the session is interactive, you'll be asked.

.PARAMETER Revert
    Removes everything this script created (policy + MDM stub) and unlocks Edge.
    Via one-liner:  $env:NN_SEARCH = 'revert'

.NOTES
    Run:  irm edge.nerdyneighbor.net | iex        (elevated Windows PowerShell)
    Log:  C:\ProgramData\NerdyNeighbor\edge-search.log

    Caveats surfaced to the tech in the console output:
      * Edge will show "managed by your organization" (cosmetic) and the search
        engine becomes locked (user can no longer change it).
      * The MDM stub can turn OFF Windows Defender Tamper Protection. Re-enable
        it in Windows Security if that matters for the customer.
      * Windows Home: the stub usually still works, but ALWAYS confirm at
        edge://policy that the DefaultSearchProvider* rows say "Applied", not
        "Ignored". If Ignored, the lock did not take on that machine.
#>

param(
    [string]$Engine,
    [switch]$Revert
)

$ErrorActionPreference = 'Stop'

# When run via `irm ... | iex` the #Requires line is NOT enforced (that only
# works for a real .ps1 file), so check for elevation ourselves.
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host ""
    Write-Host "  This needs an ELEVATED PowerShell (Run as Administrator)." -ForegroundColor Red
    Write-Host "  Close this window, reopen PowerShell as Administrator, and run again." -ForegroundColor Yellow
    Write-Host ""
    return
}

# --- Paths / logging ---------------------------------------------------------
$EdgePolicyKey  = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
$EnrollGuid     = 'FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF'
$EnrollKey      = "HKLM:\SOFTWARE\Microsoft\Enrollments\$EnrollGuid"
$OmadmKey       = "HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Accounts\$EnrollGuid"
$LogDir         = Join-Path $env:ProgramData 'NerdyNeighbor'
$LogFile        = Join-Path $LogDir 'edge-search.log'

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0}  [{1}]  {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
    switch ($Level) {
        'ERROR' { Write-Host "  $Message" -ForegroundColor Red }
        'WARN'  { Write-Host "  $Message" -ForegroundColor Yellow }
        'OK'    { Write-Host "  $Message" -ForegroundColor Green }
        default { Write-Host "  $Message" -ForegroundColor Gray }
    }
}

function Set-Reg {
    param([string]$Path, [string]$Name, $Value, [ValidateSet('DWord','String')][string]$Type)
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

# --- Search engine definitions ----------------------------------------------
$Engines = @{
    google = @{
        Name      = 'Google'
        Keyword   = 'google.com'
        SearchURL = '{google:baseURL}search?q={searchTerms}&{google:RLZ}{google:originalQueryForSuggestion}{google:assistedQueryStats}{google:searchFieldtrialParameter}{google:searchClient}{google:sourceId}ie={inputEncoding}'
        Suggest   = '{google:baseURL}complete/search?output=chrome&q={searchTerms}'
    }
    duckduckgo = @{
        Name      = 'DuckDuckGo'
        Keyword   = 'duckduckgo.com'
        SearchURL = 'https://duckduckgo.com/?q={searchTerms}'
        Suggest   = 'https://duckduckgo.com/ac/?q={searchTerms}&type=list'
    }
}

# --- Resolve the requested action -------------------------------------------
# Precedence: -Revert switch / -Engine param  >  $env:NN_SEARCH  >  interactive prompt.
function Resolve-Choice {
    param([string]$Raw)
    switch -Regex (($Raw + '').ToLower().Trim()) {
        '^(g|google)$'                 { 'google' ; break }
        '^(d|ddg|duck|duckduckgo)$'    { 'duckduckgo' ; break }
        '^(r|revert|undo)$'            { 'revert' ; break }
        default                        { $null }   # unknown / empty
    }
}

$choice = $null
if ($Revert)            { $choice = 'revert' }
elseif ($Engine)        { $choice = Resolve-Choice $Engine }
elseif ($env:NN_SEARCH) { $choice = Resolve-Choice $env:NN_SEARCH }

# A non-empty but unrecognized value (e.g. NN_SEARCH='bing') should fail loudly,
# not silently fall through to the interactive prompt.
if (-not $choice -and ($Engine -or $env:NN_SEARCH)) {
    Write-Host ""
    Write-Host "  Unrecognized engine '$($Engine)$($env:NN_SEARCH)'. Use google, duckduckgo, or revert." -ForegroundColor Red
    Write-Host ""
    return
}

Write-Host ""
Write-Host "  Nerdy Neighbor - Edge search engine lock" -ForegroundColor Cyan
Write-Host ""

if (-not $choice) {
    # Interactive prompt (works when run in a real PowerShell window).
    Write-Host "  Which search engine should Edge use (and lock)?" -ForegroundColor White
    Write-Host "    [G] Google   (default)"
    Write-Host "    [D] DuckDuckGo"
    Write-Host "    [R] Revert / undo (unlock Edge, remove policy)"
    $ans = Read-Host "  Enter G, D, or R"
    switch -Regex ($ans.Trim().ToLower()) {
        '^(d|duck|duckduckgo)$' { $choice = 'duckduckgo' }
        '^(r|revert|undo)$'     { $choice = 'revert' }
        default                 { $choice = 'google' }   # blank / G / anything else
    }
}

# --- Edition awareness (informational) --------------------------------------
$edition = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
if ($edition) { Write-Log "OS: $edition" }

# ============================================================================
#  REVERT
# ============================================================================
if ($choice -eq 'revert') {
    Write-Log "=== Revert requested on $env:COMPUTERNAME ==="
    # Remove only the values we set on the Edge policy key (leave other policies).
    $ourEdgeValues = @(
        'DefaultSearchProviderEnabled','DefaultSearchProviderName','DefaultSearchProviderKeyword',
        'DefaultSearchProviderSearchURL','DefaultSearchProviderSuggestURL',
        'DefaultBrowserSettingsCampaignEnabled','ShowRecommendationsEnabled',
        'HideFirstRunExperience','SpotlightExperiencesAndRecommendationsEnabled'
    )
    foreach ($v in $ourEdgeValues) {
        Remove-ItemProperty -Path $EdgePolicyKey -Name $v -ErrorAction SilentlyContinue
    }
    Remove-Item -Path $EnrollKey -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $OmadmKey  -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log "Removed search-provider policy, nag policies, and MDM stub." 'OK'
    Write-Host ""
    Write-Host "  Done. Fully close and reopen Edge. The search engine is user-changeable again." -ForegroundColor Green
    Write-Host "  (If you enabled it, re-check Tamper Protection in Windows Security.)" -ForegroundColor Yellow
    Write-Host ""
    $global:LASTEXITCODE = 0
    return
}

# ============================================================================
#  APPLY
# ============================================================================
$e = $Engines[$choice]
Write-Log "=== Locking Edge search to $($e.Name) on $env:COMPUTERNAME (user: $env:USERNAME) ==="

try {
    # 1) Fake-MDM enrollment stub -> makes Edge honor the mandatory policies.
    Write-Log "Writing MDM enrollment stub (makes DefaultSearchProvider* apply)..."
    Set-Reg $EnrollKey 'EnrollmentState' 1 DWord
    Set-Reg $EnrollKey 'EnrollmentType'  0 DWord
    Set-Reg $EnrollKey 'IsFederated'     0 DWord
    Set-Reg $EnrollKey 'UPN' 'user@Fake-MDM-Provider.local' String

    Set-Reg $OmadmKey 'Flags'        0x00d6fb7f DWord
    Set-Reg $OmadmKey 'AcctUId'      '0x0000000000000000000000000000000000000000000000000000000000000000' String
    Set-Reg $OmadmKey 'RoamingCount' 0 DWord
    Set-Reg $OmadmKey 'SslClientCertReference' 'MY;User;0000000000000000000000000000000000000000' String
    Set-Reg $OmadmKey 'ProtoVer'     '1.2' String

    # 2) Default search provider policy (the actual lock).
    Write-Log "Setting default search provider to $($e.Name) by policy..."
    Set-Reg $EdgePolicyKey 'DefaultSearchProviderEnabled'    1            DWord
    Set-Reg $EdgePolicyKey 'DefaultSearchProviderName'       $e.Name      String
    Set-Reg $EdgePolicyKey 'DefaultSearchProviderKeyword'    $e.Keyword   String
    Set-Reg $EdgePolicyKey 'DefaultSearchProviderSearchURL'  $e.SearchURL String
    Set-Reg $EdgePolicyKey 'DefaultSearchProviderSuggestURL' $e.Suggest   String

    # 3) Kill the Microsoft "switch to Bing / recommended settings" nags.
    Write-Log "Suppressing Bing / recommended-settings prompts..."
    Set-Reg $EdgePolicyKey 'DefaultBrowserSettingsCampaignEnabled'         0 DWord
    Set-Reg $EdgePolicyKey 'ShowRecommendationsEnabled'                    0 DWord
    Set-Reg $EdgePolicyKey 'HideFirstRunExperience'                        1 DWord
    Set-Reg $EdgePolicyKey 'SpotlightExperiencesAndRecommendationsEnabled' 0 DWord

    # 4) Verify what we wrote.
    $p = Get-ItemProperty -Path $EdgePolicyKey
    $okEnabled = ($p.DefaultSearchProviderEnabled -eq 1)
    $okName    = ($p.DefaultSearchProviderName -eq $e.Name)
    if ($okEnabled -and $okName) {
        Write-Log "Policy written: default search = $($p.DefaultSearchProviderName), enabled = $($p.DefaultSearchProviderEnabled)." 'OK'
    } else {
        Write-Log "Policy values did not read back as expected - check manually." 'WARN'
    }

    Write-Host ""
    Write-Host "  Edge default search is now locked to $($e.Name)." -ForegroundColor Green
    Write-Host ""
    Write-Host "  Next steps:" -ForegroundColor White
    Write-Host "    1. FULLY close Edge (all windows) and reopen it."
    Write-Host "    2. Open edge://policy and confirm the DefaultSearchProvider* rows"
    Write-Host "       say 'Applied' (not 'Ignored'). If Ignored, the lock did not take"
    Write-Host "       on this PC - tell Nerdy Neighbor which Windows edition it is."
    Write-Host ""
    Write-Host "  Notes:" -ForegroundColor White
    Write-Host "    * Edge will say 'managed by your organization' - cosmetic." -ForegroundColor Gray
    Write-Host "    * The search engine is now locked (user can't change it)." -ForegroundColor Gray
    Write-Host "    * Defender Tamper Protection may have been turned off - re-enable" -ForegroundColor Yellow
    Write-Host "      it in Windows Security if the customer needs it." -ForegroundColor Yellow
    Write-Host "    * Undo anytime:  `$env:NN_SEARCH='revert'; irm edge.nerdyneighbor.net | iex" -ForegroundColor Gray
    Write-Host ""
    Write-Log "=== Done ($($e.Name)) ==="
    $global:LASTEXITCODE = 0
    return
}
catch {
    Write-Log "Failed: $($_.Exception.Message)" 'ERROR'
    Write-Host ""
    Write-Host "  Something went wrong - see $LogFile" -ForegroundColor Red
    $global:LASTEXITCODE = 1
    return
}
