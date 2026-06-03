<#
  install.ps1 — Claude Code "model + plan usage" status line installer.

  Status line shows: model  [effort]  <5h bar>  <7d bar>  <context tokens>.
  The 5h/7d bars read live from widget_limits.json (Claude Code's own /usage
  cache); ccusage cost ÷ cap is only a fallback when that cache is unavailable.

  Run it with PowerShell 7:
      pwsh -NoProfile -ExecutionPolicy Bypass -File install.ps1

  It auto-detects pwsh / node / npm paths, installs ccusage if missing,
  writes the two status-line scripts into  %USERPROFILE%\.claude\,
  merges settings.json (with a .bak backup), and primes the fallback cache.
#>

$ErrorActionPreference = 'Stop'
function Info($m){ Write-Host "[*]  $m" -ForegroundColor Cyan }
function Ok($m){   Write-Host "[OK] $m" -ForegroundColor Green }
function Warn($m){ Write-Host "[!]  $m" -ForegroundColor Yellow }
function Die($m){  Write-Host "[X]  $m" -ForegroundColor Red; exit 1 }
function WriteNoBom($path,$content){
    [System.IO.File]::WriteAllText($path, $content, (New-Object System.Text.UTF8Encoding($false)))
}

# ── 1. .claude directory ─────────────────────────────────────────────────────
$claudeDir = Join-Path $env:USERPROFILE '.claude'
if (-not (Test-Path $claudeDir)) { New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null }
Info "Claude dir: $claudeDir"

# ── 2. Locate PowerShell 7 (pwsh) ────────────────────────────────────────────
$pwsh = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
if (-not $pwsh) {
    foreach ($p in @("$env:ProgramFiles\PowerShell\7\pwsh.exe",
                     "${env:ProgramFiles(x86)}\PowerShell\7\pwsh.exe")) {
        if (Test-Path $p) { $pwsh = $p; break }
    }
}
if (-not $pwsh) { Die "PowerShell 7 not found. Install:  winget install Microsoft.PowerShell" }
Ok "pwsh: $pwsh"

# ── 3. Locate Node.js ────────────────────────────────────────────────────────
$node = (Get-Command node.exe -ErrorAction SilentlyContinue).Source
if (-not $node) { Die "Node.js not found. Install:  winget install OpenJS.NodeJS  (then re-run)" }
$nodeDir = Split-Path $node
Ok "node: $node"

# ── 4. npm global bin + ccusage ──────────────────────────────────────────────
$npmBin = (& npm config get prefix 2>$null)
if ($npmBin) { $npmBin = $npmBin.Trim() }
if (-not $npmBin) { Die "npm not found on PATH." }
$ccusage = Join-Path $npmBin 'ccusage.cmd'
if (-not (Test-Path $ccusage)) {
    Info "Installing ccusage globally (npm install -g ccusage) ..."
    & npm install -g ccusage | Out-Null
}
if (-not (Test-Path $ccusage)) { Die "ccusage install failed. Run manually:  npm install -g ccusage" }
Ok "ccusage: $ccusage"

# ── 5. statusline_model.ps1 (embedded; @@PWSH@@ is substituted) ───────────────
$statusline = @'
# ─────────────────────────────────────────────────────────────────────────────
# statusline_model.ps1  —  Claude Code status line (single line)
#   "Opus 4.8  [high]  ████░░░░ 54%  █░░░░░░░ 6%  134k tokens"
#   bar 1 (blue)  = 5-hour session usage   bar 2 (amber) = 7-day usage
#   both pulled live from widget_limits.json (Claude Code's own /usage cache);
#   ccusage cost ÷ cap is only a fallback. tokens = current context size.
# ─────────────────────────────────────────────────────────────────────────────
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$raw = [Console]::In.ReadToEnd()
try { $data = $raw | ConvertFrom-Json } catch { $data = $null }

# ── Config ───────────────────────────────────────────────────────────────────
$BAR_WIDTH      = 14
$USAGE_CAP_USD  = 20.0   # FALLBACK only: ~5-hour plan limit (cost-equiv) for ccusage estimate.
$REFRESH_SEC    = 45     # max cache age before a background ccusage refresh fires
$WIDGET_MAX_AGE = 600    # max age (s) of five_hour data before we distrust it (time-sensitive)
$WIDGET_7D_MAX_AGE = 21600  # 6h: seven_day usage moves slowly, trust it on a much longer leash

# ── ANSI helpers ─────────────────────────────────────────────────────────────
$RST = "$([char]27)[0m"
function Fg([int]$r,[int]$g,[int]$b) { "$([char]27)[38;2;$r;$g;${b}m" }
$C_MODEL  = Fg 220 220 220
$C_EFFORT = Fg 200 160 90
$C_BAR_HI = Fg 43 121 194
$C_BAR_LO = Fg 60 65 75
$C_WARN   = Fg 230 160 50
$C_CRIT   = Fg 210 60 60
$C_TOK    = Fg 180 190 205
$BAR_FULL = [char]0x2588
$BAR_EMPTY= [char]0x2591

$model = if ($data -and $data.model -and $data.model.display_name) { $data.model.display_name } else { "Claude" }

$effort = $null
try {
    $cfg = Get-Content (Join-Path $PSScriptRoot 'settings.json') -Raw | ConvertFrom-Json
    if ($cfg.effortLevel) { $effort = $cfg.effortLevel }
} catch {}

# ── Context size from the transcript ─────────────────────────────────────────
$used = 0
$tpath = if ($data) { $data.transcript_path } else { $null }
if ($tpath -and (Test-Path $tpath)) {
    $lines = Get-Content $tpath
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i] -notmatch '"usage"') { continue }
        try { $o = $lines[$i] | ConvertFrom-Json } catch { continue }
        if ($o.message.usage) {
            $u = $o.message.usage
            $used = [int]$u.input_tokens + [int]$u.cache_read_input_tokens + [int]$u.cache_creation_input_tokens
            break
        }
    }
}

# ── Plan usage ────────────────────────────────────────────────────────────────
# PRIMARY source: widget_limits.json — Claude Code's own cache of the /usage API
# (five_hour.utilization / seven_day.utilization), i.e. the exact server-side %
# the /usage command shows. Real numbers (cover ALL usage, web + Code), refreshed
# every few seconds while Claude Code runs — no cost-cap guessing needed.
$pct    = $null   # 5-hour session %
$pct7   = $null   # 7-day %
$reset5 = $null   # H:MM until the 5-hour session resets
$widget = Join-Path $PSScriptRoot 'widget_limits.json'
if (Test-Path $widget) {
    try {
        $w = Get-Content $widget -Raw | ConvertFrom-Json
        $wAge = ([datetimeoffset]::Now - [datetimeoffset]::FromUnixTimeMilliseconds([long]$w._ts)).TotalSeconds
        # 7-day usage barely moves over minutes, so trust it on a long leash — this
        # keeps the amber bar visible during idle stretches when Claude Code hasn't
        # refreshed the widget cache. (The 5-hour value below uses a strict gate.)
        if ($wAge -lt $WIDGET_7D_MAX_AGE -and $null -ne $w.seven_day.utilization) {
            $pct7 = [math]::Min(100.0, [double]$w.seven_day.utilization)
        }
        # resets_at is an absolute future timestamp — still accurate when the cache
        # is stale (and the >0 guard hides it once it passes), so compute it on the
        # long leash too rather than letting it vanish with the 5-hour value.
        if ($wAge -lt $WIDGET_7D_MAX_AGE -and $w.five_hour.resets_at) {
            try {
                # ConvertFrom-Json already turns the ISO-8601 string into a local
                # [datetime]; use it directly (re-Parsing its culture-formatted
                # string misreads MM/DD as DD/MM).
                $ra = $w.five_hour.resets_at
                $resetDto = if ($ra -is [datetime]) { [datetimeoffset]$ra } else { [datetimeoffset]::Parse($ra) }
                $span = $resetDto - [datetimeoffset]::Now
                if ($span.TotalSeconds -gt 0) { $reset5 = '{0}:{1:00}' -f [int][math]::Floor($span.TotalHours), $span.Minutes }
            } catch {}
        }
        if ($wAge -lt $WIDGET_MAX_AGE) {
            if ($null -ne $w.five_hour.utilization) { $pct  = [math]::Min(100.0, [double]$w.five_hour.utilization) }
        }
    } catch {}
}

# FALLBACK: cached ccusage cost ÷ cap (a rough estimate). Only used — and ccusage
# only spawned — when the widget cache is missing or stale.
if ($null -eq $pct) {
    $cache = Join-Path $PSScriptRoot '_usage5h.json'
    $cost = $null
    $cacheAge = [double]::PositiveInfinity
    if (Test-Path $cache) {
        try {
            $c = Get-Content $cache -Raw | ConvertFrom-Json
            $cost = [double]$c.cost
            $cacheAge = ((Get-Date) - [datetime]$c.time).TotalSeconds
        } catch {}
    }

    if ($cacheAge -gt $REFRESH_SEC) {
        $lock = Join-Path $PSScriptRoot '_usage.lock'
        $lockAge = if (Test-Path $lock) { ((Get-Date) - (Get-Item $lock).LastWriteTime).TotalSeconds } else { 9999 }
        if ($lockAge -gt 30) {
            try {
                Set-Content $lock (Get-Date -Format o)
                Start-Process -WindowStyle Hidden -FilePath '@@PWSH@@' `
                    -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',
                                    (Join-Path $PSScriptRoot 'usage_refresh.ps1'))
            } catch {}
        }
    }

    if (($null -ne $cost) -and ($USAGE_CAP_USD -gt 0)) {
        $pct = [math]::Min(100.0, $cost / $USAGE_CAP_USD * 100.0)
    }
}

$haveUsage = ($null -ne $pct)
if (-not $haveUsage) { $pct = 0 }

# ── Build the line ───────────────────────────────────────────────────────────
# Colored progress bar: amber >=75%, red >=90%, else the given base color.
function Bar([double]$p, [int]$width, [string]$base) {
    $c = if ($p -ge 90) { $C_CRIT } elseif ($p -ge 75) { $C_WARN } else { $base }
    $f = [int][math]::Round($p / 100 * $width)
    $e = $width - $f
    $c + ($BAR_FULL.ToString() * $f) + $C_BAR_LO + ($BAR_EMPTY.ToString() * $e) + "$RST $c$([math]::Round($p))%$RST"
}

$pctText = if ($haveUsage) { Bar $pct $BAR_WIDTH $C_BAR_HI } else { "$C_BAR_LO$($BAR_EMPTY.ToString() * $BAR_WIDTH)$RST --%" }

function Tk([int]$n) { "$([math]::Round($n / 1000))k" }

$sep = "$C_BAR_LO$([char]0x2502)$RST"   # dim │

$parts = @()
$parts += "$C_MODEL$model$RST"
if ($effort) { $parts += "$C_EFFORT[$effort]$RST" }
$parts += $sep
$parts += "$pctText"
if ($reset5) {
    $parts += "$sep $C_BAR_HI$reset5$RST $sep"
}
if ($null -ne $pct7) {
    $parts += (Bar $pct7 $BAR_WIDTH $C_EFFORT)
}
$parts += $sep
$parts += "$C_TOK$(Tk $used) tokens$RST"

Write-Output ($parts -join "  ")
'@
$statusline = $statusline.Replace('@@PWSH@@', $pwsh)

# ── 6. usage_refresh.ps1 (embedded; tokens substituted) ──────────────────────
$refresh = @'
# ─────────────────────────────────────────────────────────────────────────────
# usage_refresh.ps1 — background worker. Runs ccusage for the active 5-hour
# block and writes _usage5h.json. Spawned fire-and-forget by the status line.
# ─────────────────────────────────────────────────────────────────────────────
$ErrorActionPreference = 'SilentlyContinue'
$env:PATH = "@@NODEDIR@@;@@NPMBIN@@;$env:PATH"
$ccusage = "@@CCUSAGE@@"
$cache   = Join-Path $PSScriptRoot '_usage5h.json'
$lock    = Join-Path $PSScriptRoot '_usage.lock'
try {
    $raw = & $ccusage blocks --active --json 2>$null
    $j = $raw | ConvertFrom-Json
    $b = $j.blocks | Where-Object { $_.isActive } | Select-Object -First 1
    if (-not $b) { $b = $j.blocks | Select-Object -Last 1 }
    if ($b) {
        ([ordered]@{
            time       = (Get-Date -Format o)
            cost       = [double]$b.costUSD
            tokens     = [double]$b.totalTokens
            blockStart = "$($b.startTime)"
        } | ConvertTo-Json) | Set-Content $cache -Encoding utf8
    }
} catch {}
finally { Remove-Item $lock -ErrorAction SilentlyContinue }
'@
$refresh = $refresh.Replace('@@NODEDIR@@', $nodeDir).Replace('@@NPMBIN@@', $npmBin).Replace('@@CCUSAGE@@', $ccusage)

WriteNoBom (Join-Path $claudeDir 'statusline_model.ps1') $statusline
WriteNoBom (Join-Path $claudeDir 'usage_refresh.ps1')    $refresh
Ok "Wrote statusline_model.ps1 + usage_refresh.ps1"

# ── 7. Merge settings.json ───────────────────────────────────────────────────
$settingsPath = Join-Path $claudeDir 'settings.json'
if (Test-Path $settingsPath) {
    Copy-Item $settingsPath "$settingsPath.bak" -Force
    $s = Get-Content $settingsPath -Raw | ConvertFrom-Json
} else {
    $s = [pscustomobject]@{}
}
$scriptFwd = ((Join-Path $claudeDir 'statusline_model.ps1') -replace '\\','/')
$pwshFwd   = ($pwsh -replace '\\','/')
$cmd = '"' + $pwshFwd + '" -NoProfile -ExecutionPolicy Bypass -File ' + $scriptFwd
$s | Add-Member -NotePropertyName statusLine `
                -NotePropertyValue ([pscustomobject]@{ type='command'; command=$cmd; padding=1 }) -Force
if (-not $s.PSObject.Properties['effortLevel']) {
    $s | Add-Member -NotePropertyName effortLevel -NotePropertyValue 'high' -Force
}
WriteNoBom $settingsPath ($s | ConvertTo-Json -Depth 30)
Ok "Updated settings.json (backup: settings.json.bak)"

# ── 8. Prime the usage cache ─────────────────────────────────────────────────
Info "Priming usage cache ..."
& $pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $claudeDir 'usage_refresh.ps1')
if (Test-Path (Join-Path $claudeDir '_usage5h.json')) { Ok "Usage cache primed." } else { Warn "Cache not primed yet (will self-heal on first render)." }

Write-Host ""
Ok  "Install complete."
Write-Host "Next steps:" -ForegroundColor White
Write-Host "  1. Restart Claude Code, then press Shift+Tab to refresh the status line." -ForegroundColor Gray
Write-Host "  2. The 5h/7d bars use Claude Code's own /usage data (widget_limits.json)" -ForegroundColor Gray
Write-Host "     automatically - no calibration needed." -ForegroundColor Gray
Write-Host '  3. (Optional) Only if the widget cache is ever missing and the ccusage' -ForegroundColor Gray
Write-Host '     fallback kicks in, calibrate $USAGE_CAP_USD in ~/.claude/statusline_model.ps1' -ForegroundColor Gray
Write-Host '     to:  current_5h_cost / (usage_percent / 100)' -ForegroundColor Gray
