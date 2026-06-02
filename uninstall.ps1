<#
  uninstall.ps1 — removes the Claude Code status line installed by install.ps1.

  Run with PowerShell 7:
      pwsh -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1

  - Removes the "statusLine" key from settings.json (other keys untouched).
  - Deletes statusline_model.ps1, usage_refresh.ps1, and the usage cache/lock.
  - Leaves settings.json.bak and effortLevel alone.
#>

$ErrorActionPreference = 'Stop'
function Info($m){ Write-Host "[*]  $m" -ForegroundColor Cyan }
function Ok($m){   Write-Host "[OK] $m" -ForegroundColor Green }
function Warn($m){ Write-Host "[!]  $m" -ForegroundColor Yellow }
function WriteNoBom($path,$content){
    [System.IO.File]::WriteAllText($path, $content, (New-Object System.Text.UTF8Encoding($false)))
}

$claudeDir = Join-Path $env:USERPROFILE '.claude'
if (-not (Test-Path $claudeDir)) { Warn "No .claude dir at $claudeDir — nothing to do."; exit 0 }
Info "Claude dir: $claudeDir"

# ── 1. Strip statusLine from settings.json ───────────────────────────────────
$settingsPath = Join-Path $claudeDir 'settings.json'
if (Test-Path $settingsPath) {
    try {
        $s = Get-Content $settingsPath -Raw | ConvertFrom-Json
        if ($s.PSObject.Properties['statusLine']) {
            Copy-Item $settingsPath "$settingsPath.uninstall.bak" -Force
            $s.PSObject.Properties.Remove('statusLine')
            WriteNoBom $settingsPath ($s | ConvertTo-Json -Depth 30)
            Ok "Removed statusLine from settings.json (backup: settings.json.uninstall.bak)"
        } else {
            Warn "settings.json has no statusLine key — left as-is."
        }
    } catch {
        Warn "Could not parse settings.json — left untouched. ($_)"
    }
} else {
    Warn "No settings.json found."
}

# ── 2. Delete the status-line files ──────────────────────────────────────────
$removed = 0
foreach ($f in 'statusline_model.ps1','usage_refresh.ps1','_usage5h.json','_usage.lock') {
    $p = Join-Path $claudeDir $f
    if (Test-Path $p) { Remove-Item $p -Force; Ok "Deleted $f"; $removed++ }
}
if ($removed -eq 0) { Warn "No status-line script files found to delete." }

Write-Host ""
Ok "Uninstall complete. Restart Claude Code to clear the status line."
Write-Host "Note: 'effortLevel' and 'settings.json.bak' were left in place." -ForegroundColor Gray
Write-Host "To fully revert settings, you can restore from settings.json.bak (from install) if desired." -ForegroundColor Gray
