#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Nerdy Neighbor - Make Edge use Google or DuckDuckGo and stop the
    "switch back to Bing" prompt that keeps reverting customers.

.DESCRIPTION
    Two different things are needed, and which ones apply depends on the
    Windows edition:

      * The Bing / "use recommended settings" POPUP is killed by policies that
        work on EVERY edition (no management required). This is the real fix -
        with no popup, a manually-set Google default just stays.

      * Actually LOCKING the search engine by policy (DefaultSearchProvider*)
        only works on Windows Pro / Education / Enterprise, and only when the
        device looks MDM-managed. On those editions this script adds a minimal
        fake-MDM enrollment stub to unlock the lock. On Windows HOME, Microsoft
        blocks these policies no matter what (the stub can't fake it), so the
        script skips the stub entirely and relies on popup suppression.

.PARAMETER Engine
    'google' (default) or 'duckduckgo'. Via `irm ... | iex` (no parameters) set
    the environment variable instead:  $env:NN_SEARCH = 'duckduckgo'

.PARAMETER Revert
    Undo everything this script ever wrote (stub + all policies). One-liner:
    $env:NN_SEARCH = 'revert'

.NOTES
    Run:  irm edge.nerdyneighbor.net | iex        (elevated Windows PowerShell)
    Log:  C:\ProgramData\NerdyNeighbor\edge-search.log
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
$EdgePolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
$EnrollGuid    = 'FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF'
$EnrollKey     = "HKLM:\SOFTWARE\Microsoft\Enrollments\$EnrollGuid"
$OmadmKey      = "HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Accounts\$EnrollGuid"
$LogDir        = Join-Path $env:ProgramData 'NerdyNeighbor'
$LogFile       = Join-Path $LogDir 'edge-search.log'

$SearchPolicyValues = @(
    'DefaultSearchProviderEnabled','DefaultSearchProviderName','DefaultSearchProviderKeyword',
    'DefaultSearchProviderSearchURL','DefaultSearchProviderSuggestURL'
)
$NagPolicyValues = @(
    'DefaultBrowserSettingsCampaignEnabled','ShowRecommendationsEnabled',
    'HideFirstRunExperience','SpotlightExperiencesAndRecommendationsEnabled'
)

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

function Remove-Stub {
    Remove-Item -Path $EnrollKey -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $OmadmKey  -Recurse -Force -ErrorAction SilentlyContinue
}

function Restart-Edge {
    # Policies (and management state) are only re-read when EVERY msedge.exe
    # exits - closing the window is not enough (startup boost keeps it alive).
    $procs = Get-Process msedge -ErrorAction SilentlyContinue
    if (-not $procs) { Write-Log "Edge is not running - nothing to restart."; return }
    if ($script:Interactive) {
        $a = Read-Host "  Close all Edge windows now to apply? Unsaved tabs will close. [Y/n]"
        if ($a.Trim().ToLower() -eq 'n') {
            Write-Log "Skipped Edge restart - changes apply after the user fully closes Edge." 'WARN'
            return
        }
    }
    Write-Log "Closing all Edge processes..."
    $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Write-Log "Edge closed. It will apply the new settings next launch." 'OK'
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
function Resolve-Choice {
    param([string]$Raw)
    switch -Regex (($Raw + '').ToLower().Trim()) {
        '^(g|google)$'              { 'google' ; break }
        '^(d|ddg|duck|duckduckgo)$' { 'duckduckgo' ; break }
        '^(r|revert|undo)$'         { 'revert' ; break }
        default                     { $null }
    }
}

$script:Interactive = $false
$choice = $null
if ($Revert)            { $choice = 'revert' }
elseif ($Engine)        { $choice = Resolve-Choice $Engine }
elseif ($env:NN_SEARCH) { $choice = Resolve-Choice $env:NN_SEARCH }

if (-not $choice -and ($Engine -or $env:NN_SEARCH)) {
    Write-Host ""
    Write-Host "  Unrecognized engine '$($Engine)$($env:NN_SEARCH)'. Use google, duckduckgo, or revert." -ForegroundColor Red
    Write-Host ""
    return
}

Write-Host ""
Write-Host "  Nerdy Neighbor - Edge search engine setup" -ForegroundColor Cyan
Write-Host ""

if (-not $choice) {
    $script:Interactive = $true
    Write-Host "  Which search engine should Edge use?" -ForegroundColor White
    Write-Host "    [G] Google   (default)"
    Write-Host "    [D] DuckDuckGo"
    Write-Host "    [R] Revert / undo (remove everything this tool set)"
    $ans = Read-Host "  Enter G, D, or R"
    switch -Regex ($ans.Trim().ToLower()) {
        '^(d|duck|duckduckgo)$' { $choice = 'duckduckgo' }
        '^(r|revert|undo)$'     { $choice = 'revert' }
        default                 { $choice = 'google' }
    }
}

# --- Edition awareness -------------------------------------------------------
$edition = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
$isHome  = ($edition -like '*Home*')
if ($edition) { Write-Log "OS: $edition" }

# ============================================================================
#  REVERT
# ============================================================================
if ($choice -eq 'revert') {
    Write-Log "=== Revert requested on $env:COMPUTERNAME ==="
    foreach ($v in ($SearchPolicyValues + $NagPolicyValues)) {
        Remove-ItemProperty -Path $EdgePolicyKey -Name $v -ErrorAction SilentlyContinue
    }
    Remove-Stub
    Write-Log "Removed all policies and the MDM stub." 'OK'
    Restart-Edge
    Write-Host ""
    Write-Host "  Done. Edge is back to defaults and user-changeable." -ForegroundColor Green
    Write-Host "  If Tamper Protection was turned off earlier, re-enable it in" -ForegroundColor Yellow
    Write-Host "  Windows Security > Virus & threat protection > Manage settings." -ForegroundColor Yellow
    Write-Host ""
    $global:LASTEXITCODE = 0
    return
}

# ============================================================================
#  APPLY
# ============================================================================
$e = $Engines[$choice]
Write-Log "=== Apply ($($e.Name)) on $env:COMPUTERNAME (user: $env:USERNAME) ==="

try {
    # Nag suppression - works on ALL editions (no management required).
    Write-Log "Suppressing Bing / recommended-settings prompts..."
    Set-Reg $EdgePolicyKey 'DefaultBrowserSettingsCampaignEnabled'         0 DWord
    Set-Reg $EdgePolicyKey 'ShowRecommendationsEnabled'                    0 DWord
    Set-Reg $EdgePolicyKey 'HideFirstRunExperience'                        1 DWord
    Set-Reg $EdgePolicyKey 'SpotlightExperiencesAndRecommendationsEnabled' 0 DWord

    if ($isHome) {
        # ---- Windows Home: policy LOCK is impossible; don't fake MDM. --------
        Write-Log "Windows Home detected: Microsoft blocks the search-engine lock on this edition." 'WARN'
        # Clean up anything a prior run left (stub is harmful here; blocked
        # search policies just clutter edge://policy with errors).
        foreach ($v in $SearchPolicyValues) {
            Remove-ItemProperty -Path $EdgePolicyKey -Name $v -ErrorAction SilentlyContinue
        }
        Remove-Stub
        Write-Log "Removed the fake-MDM stub and the blocked search policies (they do nothing on Home)." 'OK'

        Restart-Edge

        Write-Host ""
        Write-Host "  Bing / recommended-settings popups are now suppressed." -ForegroundColor Green
        Write-Host ""
        Write-Host "  Windows Home can't LOCK the engine by policy, but that's OK:" -ForegroundColor White
        Write-Host "  with the popup gone, a manually-set default stays put." -ForegroundColor White
        Write-Host ""
        Write-Host "  Finish it (once, in Edge):" -ForegroundColor White
        Write-Host "    1. Reopen Edge."
        Write-Host "    2. Go to  edge://settings/searchEngines"
        Write-Host "    3. Set 'Address bar and search' to $($e.Name)."
        Write-Host "    It will now stick - nothing prompts to switch back to Bing." -ForegroundColor Gray
        Write-Host ""
        Write-Host "  If an earlier run turned off Defender Tamper Protection, re-enable it:" -ForegroundColor Yellow
        Write-Host "  Windows Security > Virus & threat protection > Manage settings." -ForegroundColor Yellow
        Write-Host ""
    }
    else {
        # ---- Pro / Education / Enterprise: real policy lock. -----------------
        Write-Log "Writing fake-MDM stub so the search-provider policy applies..."
        Set-Reg $EnrollKey 'EnrollmentState' 1 DWord
        Set-Reg $EnrollKey 'EnrollmentType'  0 DWord
        Set-Reg $EnrollKey 'IsFederated'     0 DWord
        Set-Reg $EnrollKey 'UPN' 'user@Fake-MDM-Provider.local' String

        Set-Reg $OmadmKey 'Flags'        0x00d6fb7f DWord
        Set-Reg $OmadmKey 'AcctUId'      '0x0000000000000000000000000000000000000000000000000000000000000000' String
        Set-Reg $OmadmKey 'RoamingCount' 0 DWord
        Set-Reg $OmadmKey 'SslClientCertReference' 'MY;User;0000000000000000000000000000000000000000' String
        Set-Reg $OmadmKey 'ProtoVer'     '1.2' String

        Write-Log "Locking default search provider to $($e.Name) by policy..."
        Set-Reg $EdgePolicyKey 'DefaultSearchProviderEnabled'    1            DWord
        Set-Reg $EdgePolicyKey 'DefaultSearchProviderName'       $e.Name      String
        Set-Reg $EdgePolicyKey 'DefaultSearchProviderKeyword'    $e.Keyword   String
        Set-Reg $EdgePolicyKey 'DefaultSearchProviderSearchURL'  $e.SearchURL String
        Set-Reg $EdgePolicyKey 'DefaultSearchProviderSuggestURL' $e.Suggest   String

        Restart-Edge

        Write-Host ""
        Write-Host "  Edge default search is now locked to $($e.Name)." -ForegroundColor Green
        Write-Host ""
        Write-Host "  Verify: open edge://policy - the DefaultSearchProvider* rows must say" -ForegroundColor White
        Write-Host "  'OK' (not 'Error'/'This policy is blocked'). If blocked, the device" -ForegroundColor White
        Write-Host "  isn't being seen as managed - reboot once and re-check." -ForegroundColor White
        Write-Host ""
        Write-Host "  Notes:" -ForegroundColor White
        Write-Host "    * Edge will say 'managed by your organization' - cosmetic." -ForegroundColor Gray
        Write-Host "    * The search engine is now locked (user can't change it)." -ForegroundColor Gray
        Write-Host "    * Defender Tamper Protection may get turned off - re-enable in" -ForegroundColor Yellow
        Write-Host "      Windows Security if the customer needs it." -ForegroundColor Yellow
        Write-Host ""
    }

    Write-Log "=== Done ($($e.Name), Home=$isHome) ==="
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
