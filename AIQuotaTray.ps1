# AI Quota Tray (Windows) - Codex · Claude Code · Antigravity 한도 잔여율 트레이 패널
# 아이디어: github.com/tti9494/arsen-ai-quota (macOS). 이 파일은 Windows용 독자 구현.
# 읽기 전용. 인증 파일·토큰은 읽지 않는다.
#  - Codex      : ~\.codex\sessions\**\*.jsonl 의 token_count 이벤트(rate_limits), 로컬
#  - Claude     : `claude -p "/usage"` 출력(claude CLI가 자기 로그인으로 조회)
#  - Antigravity: `agy -p "/usage"` 출력(agy CLI가 자기 로그인으로 조회)
param([switch]$Probe, [string]$Shot, [switch]$Demo, [string]$Skin, [string]$IconSheet)
$ErrorActionPreference = 'Stop'

$SessionsRoot = Join-Path $env:USERPROFILE '.codex\sessions'
$StateDir     = Join-Path $env:USERPROFILE '.ai-quota-tray'
$SettingsPath = Join-Path $StateDir 'settings.json'
$TailBytes    = 512KB
if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory $StateDir | Out-Null }

# ---------- 설정 ----------
function Get-Settings {
    $s = @{ mode = 'both'; tray = @('claude', 'codex', 'antigravity'); pinned = $false; posX = $null; posY = $null; scale = 1.0; skin = 'mint' }
    try {
        $j = Get-Content $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($j.skin -in 'mint', 'aurora', 'navy', 'paper', 'terminal', 'ring') { $s.skin = $j.skin }
        if ($null -ne $j.scale) { $s.scale = [math]::Max(0.6, [math]::Min(2.5, [double]$j.scale)) }
        if ($j.pinned -eq $true) { $s.pinned = $true }
        if ($null -ne $j.posX -and $null -ne $j.posY) { $s.posX = [int]$j.posX; $s.posY = [int]$j.posY }
        if ($j.mode -in 'both', 'five', 'weekly') { $s.mode = $j.mode }
        if ($null -ne $j.tray) { $s.tray = @($j.tray | Where-Object { $_ -in 'codex', 'claude', 'antigravity' }) }
    } catch {}
    return $s
}
function Save-Settings { $script:Settings | ConvertTo-Json | Set-Content $SettingsPath -Encoding UTF8 }
$script:Settings = Get-Settings
$script:Scale = [double]$script:Settings.scale   # 화면에 그릴 때의 실제 배율(작은 화면에서는 자동으로 줄어듦)

# ---------- 공통: 한도 창 검증 ----------
function Test-Window($used, $reset, [int]$minutes, [double]$now) {
    try {
        $used = [double]$used; $reset = [double]$reset
        if ($reset -gt 1e11) { $reset = $reset / 1000 }
        if ($used -lt 0 -or $used -gt 100) { return $null }
        if ($reset -le $now -or $reset -gt $now + $minutes * 60 + 60) { return $null }
        return [pscustomobject]@{ Remaining = [math]::Round(100 - $used, 1); Reset = $reset }
    } catch { return $null }
}
function Get-Now { [double][DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

# ---------- Codex ----------
function Read-Tail($path) {
    $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
    try {
        $start = [math]::Max(0, $fs.Length - $TailBytes)
        $null = $fs.Seek($start, 'Begin')
        $buf = New-Object byte[] ($fs.Length - $start)
        $n = $fs.Read($buf, 0, $buf.Length)
        $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $n)
        if ($start -gt 0) { $i = $text.IndexOf("`n"); if ($i -ge 0) { $text = $text.Substring($i + 1) } }
        return $text -split "`n"
    } finally { $fs.Dispose() }
}
function Get-CodexQuota {
    $now = Get-Now
    $files = @()
    for ($i = 0; $i -lt 9; $i++) {
        $dir = Join-Path $SessionsRoot ((Get-Date).AddDays(-$i).ToString('yyyy\\MM\\dd'))
        if (Test-Path $dir) { $files += Get-ChildItem $dir -Filter *.jsonl -File }
    }
    foreach ($f in ($files | Sort-Object LastWriteTime -Descending | Select-Object -First 30)) {
        try { $lines = Read-Tail $f.FullName } catch { continue }
        for ($k = $lines.Count - 1; $k -ge 0; $k--) {
            $ln = $lines[$k]
            if ($ln -notlike '*"token_count"*' -or $ln -notlike '*"rate_limits"*') { continue }
            try { $e = $ln | ConvertFrom-Json } catch { continue }
            if ($e.type -ne 'event_msg' -or $e.payload.type -ne 'token_count') { continue }
            $lim = $e.payload.rate_limits
            if ($null -eq $lim) { continue }
            if ($lim.limit_id -and $lim.limit_id -ne 'codex') { continue }
            $five = $weekly = $null
            foreach ($p in @($lim.primary, $lim.secondary)) {
                if ($null -eq $p) { continue }
                $m = [int]$p.window_minutes
                if ($m -eq 300)   { $five   = Test-Window $p.used_percent $p.resets_at 300 $now }
                if ($m -eq 10080) { $weekly = Test-Window $p.used_percent $p.resets_at 10080 $now }
            }
            if ($five -or $weekly) {
                return [pscustomobject]@{ Five = $five; Weekly = $weekly; Recorded = [DateTimeOffset]::Parse($e.timestamp).LocalDateTime }
            }
        }
    }
    return $null
}

# ---------- CLI 조회 (Claude Code · Antigravity) ----------
# 두 CLI 모두 `-p "/usage"`로 한도를 출력한다. 각 CLI가 자기 로그인으로 조회하며 이 앱은 토큰·인증 파일을 읽지 않는다.
$script:Fetch = @{
    claude      = @{ Proc = $null; Task = $null; StartedAt = $null; At = $null; Parsed = $null; Err = $null }
    antigravity = @{ Proc = $null; Task = $null; StartedAt = $null; At = $null; Parsed = $null; Err = $null }
    codex       = @{ Proc = $null; Task = $null; StartedAt = $null; At = $null; Parsed = $null; Err = $null }
}
$CodexHelper = Join-Path $PSScriptRoot 'codex_usage.ps1'
function Find-Exe($name) {
    $c = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c -and $c.Source) { return $c.Source }
    # 바탕화면 바로가기/시작 프로그램으로 뜨면 PATH가 오래된 값일 수 있어 흔한 설치 위치를 직접 찾는다
    $u = $env:USERPROFILE
    $cands = switch ($name) {
        'agy'    { @("$env:LOCALAPPDATA\agy\bin\agy.exe", "$u\.local\bin\agy.exe", "$env:LOCALAPPDATA\Programs\antigravity\bin\agy.exe") }
        'claude' { @("$u\.local\bin\claude.exe", "$env:APPDATA\npm\claude.cmd", "$env:LOCALAPPDATA\Programs\claude\claude.exe") }
        default  { @() }
    }
    foreach ($p in $cands) { if (Test-Path $p) { return $p } }
    # Claude 데스크톱 앱(패키지 앱) 안에서 설치한 CLI는 AppData\Local\Packages\Claude_*\LocalCache\ 아래에 실제 파일이 있다
    if ($name -eq 'agy' -or $name -eq 'claude') {
        $leaf = if ($name -eq 'agy') { 'Local\agy\bin\agy.exe' } else { 'Local\claude\claude.exe' }
        $g = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Packages') -Directory -Filter 'Claude_*' -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName "LocalCache\$leaf" } | Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($g) { return $g }
    }
    return $null
}

function Start-CliFetch($id) {
    $f = $script:Fetch[$id]
    if ($f.Proc -and -not $f.Proc.HasExited) { return }
    if ($id -eq 'codex') { $exe = Find-Exe 'powershell.exe' } else { $exe = Find-Exe $(if ($id -eq 'claude') { 'claude' } else { 'agy' }) }
    if (-not $exe) {
        $f.Err = 'CLI를 찾을 수 없음'
        try { Write-Err ("Find-Exe 실패 id=$id LOCALAPPDATA=[$env:LOCALAPPDATA] USERPROFILE=[$env:USERPROFILE] agy존재=" + (Test-Path "$env:LOCALAPPDATA\agy\bin\agy.exe")) } catch {}
        return
    }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = switch ($id) {
        'claude' { '-p "/usage" --strict-mcp-config --no-session-persistence' }
        'codex'  { '-NoProfile -ExecutionPolicy Bypass -File "' + $CodexHelper + '"' }
        default  { '-p "/usage"' }
    }
    $psi.WorkingDirectory = $env:TEMP
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    try {
        $f.Proc = [Diagnostics.Process]::Start($psi)
        $f.Proc.BeginErrorReadLine()
        $f.Task = $f.Proc.StandardOutput.ReadToEndAsync()
        $f.StartedAt = Get-Date; $f.Err = $null
    } catch { $f.Err = '실행 실패'; $f.Proc = $null }
}

function New-Win($rem, $resetUnix, [int]$minutes) {
    $now = Get-Now
    if ($null -eq $resetUnix -or $resetUnix -le 0) { return [pscustomobject]@{ Remaining = [double]$rem; Reset = $null } }
    if ($resetUnix -le $now -or $resetUnix -gt $now + $minutes * 60 + 120) { return $null }
    return [pscustomobject]@{ Remaining = [double]$rem; Reset = $resetUnix }
}
function Get-Fresh($w) { if ($w -and $w.Reset -and $w.Reset -le (Get-Now)) { return $null } else { return $w } }

# agy: "Gemini Models<TAB>Weekly Limit Remaining<TAB>70%<TAB>2026-11-30T21:34:51Z"
function Parse-AgyUsage([string]$text) {
    $pools = @{ g = @{ Five = $null; Weekly = $null }; t = @{ Five = $null; Weekly = $null } }
    $any = $false
    foreach ($ln in ($text -split "`r?`n")) {
        $c = $ln -split "`t"
        if ($c.Count -lt 4) { continue }
        if ($c[2].Trim() -notmatch '^([\d.]+)%$') { continue }
        $rem = [double]$Matches[1]
        try { $unix = [DateTimeOffset]::Parse($c[3].Trim(), [Globalization.CultureInfo]::InvariantCulture).ToUnixTimeSeconds() } catch { $unix = 0 }
        $pool = if ($c[0] -like 'Gemini*') { 'g' } elseif ($c[0] -like 'Claude*') { 't' } else { continue }
        if ($c[1] -like 'Five Hour*') { $pools[$pool].Five = New-Win $rem $unix 300; $any = $true }
        elseif ($c[1] -like 'Weekly*') { $pools[$pool].Weekly = New-Win $rem $unix 10080; $any = $true }
    }
    if ($any) { return $pools } else { return $null }
}

# claude: "Current session: 20% used · resets Nov 25, 5:50pm (Asia/Seoul)"
function ConvertFrom-ClaudeReset([string]$t) {
    if ($t -notmatch '(?<mon>[A-Za-z]{3})[a-z]* (?<day>\d{1,2}),? (?<h>\d{1,2})(?::(?<m>\d{2}))?\s*(?<ap>am|pm)') { return $null }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $min = if ($Matches.m) { $Matches.m } else { '00' }
    $year = (Get-Date).Year
    try {
        $dt = [datetime]::ParseExact(("{0} {1} {2} {3}:{4} {5}" -f $Matches.mon, $Matches.day, $year, $Matches.h, $min, $Matches.ap.ToUpper()), 'MMM d yyyy h:mm tt', $inv)
        if ($dt -lt (Get-Date).AddDays(-1)) { $dt = $dt.AddYears(1) }
        return ([DateTimeOffset]$dt).ToUnixTimeSeconds()
    } catch { return $null }
}
function Parse-ClaudeUsage([string]$text) {
    $res = @{ Session = $null; Week = $null; Models = @() }
    $any = $false
    foreach ($ln in ($text -split "`r?`n")) {
        if ($ln -notmatch '^\s*Current (session|week)(?: \(([^)]+)\))?: ([\d.]+)% used(?:\s+\S+\s+resets\s+(.+?))?\s*$') { continue }
        $kind = $Matches[1]; $qual = $Matches[2]; $used = [double]$Matches[3]; $rt = $Matches[4]
        $unix = if ($rt) { ConvertFrom-ClaudeReset $rt } else { $null }
        $rem = [math]::Round(100 - $used, 1)
        if ($kind -eq 'session') { $res.Session = New-Win $rem $unix 300; $any = $true }
        elseif (-not $qual -or $qual -match 'all models') { $res.Week = New-Win $rem $unix 10080; $any = $true }
        else { $res.Models += @{ Name = ($qual -replace ' only$', ''); Win = (New-Win $rem $unix 10080) }; $any = $true }
    }
    if ($any) { return $res } else { return $null }
}

# codex: account/rateLimits/read 응답 JSON (usedPercent, windowDurationMins, resetsAt)
function Parse-CodexUsage([string]$text) {
    try { $j = ($text.Trim() -split "`r?`n" | Where-Object { $_ -like '{*' } | Select-Object -Last 1) | ConvertFrom-Json } catch { return $null }
    $rl = $j.result.rateLimits
    if (-not $rl) { return $null }
    $res = @{ Five = $null; Weekly = $null; Coupons = 0; CouponExpires = $null }
    foreach ($p in @($rl.primary, $rl.secondary)) {
        if ($null -eq $p) { continue }
        $m = [int]$p.windowDurationMins
        $rem = [math]::Round(100 - [double]$p.usedPercent, 1)
        if ($m -eq 300)   { $res.Five   = New-Win $rem ([double]$p.resetsAt) 300 }
        if ($m -eq 10080) { $res.Weekly = New-Win $rem ([double]$p.resetsAt) 10080 }
    }
    $cr = @($j.result.rateLimitResetCredits.credits | Where-Object { $_.status -eq 'available' })
    $res.Coupons = $cr.Count
    $exp = @($cr | Where-Object { $_.expiresAt } | ForEach-Object { [double]$_.expiresAt } | Sort-Object)
    if ($exp.Count) { $res.CouponExpires = $exp[0] }
    return $res
}

function Complete-CliFetch($id) {
    $f = $script:Fetch[$id]
    $p = $f.Proc
    if (-not $p) { return $false }
    if (-not $p.HasExited) {
        if (((Get-Date) - $f.StartedAt).TotalSeconds -gt 45) { try { $p.Kill() } catch {}; $f.Err = '시간 초과'; $f.Proc = $null }
        return $false
    }
    $text = ''
    try { $text = $f.Task.Result } catch {}
    $code = $p.ExitCode
    $f.Proc = $null
    $parsed = switch ($id) { 'claude' { Parse-ClaudeUsage $text } 'codex' { Parse-CodexUsage $text } default { Parse-AgyUsage $text } }
    if ($parsed) { $f.Parsed = $parsed; $f.At = Get-Date; $f.Err = $null }
    else { $f.Err = if ($code -ne 0) { "조회 실패(코드 $code) · 로그인 상태 확인" } else { '조회 결과를 해석하지 못함' } }
    return $true
}

function Request-Fetch([int]$maxAgeSec) {
    foreach ($id in 'claude', 'codex', 'antigravity') {
        if ($script:Settings.tray -notcontains $id) { continue }   # 꺼 둔 항목은 조회하지 않음
        $f = $script:Fetch[$id]
        if ($f.Proc -and -not $f.Proc.HasExited) { continue }
        $age = if ($f.StartedAt) { ((Get-Date) - $f.StartedAt).TotalSeconds } else { 1e9 }
        if ($age -ge $maxAgeSec) { Start-CliFetch $id }
    }
}

function Get-FetchStatus($id, $okText) {
    $f = $script:Fetch[$id]
    if ($f.Parsed) { if ($f.Err) { return "$okText · 갱신 실패($($f.Err))" } else { return $okText } }
    if ($f.Proc) { return '조회 중…' }
    if ($f.Err) { return "미확인 · $($f.Err)" }
    return '미확인 · 아직 조회 전'
}

# ---------- 제공자 모델 ----------
function Get-Providers {
    $list = New-Object System.Collections.ArrayList
    $xp = $script:Fetch.codex.Parsed
    $xsub = 'ChatGPT 계정 공유'
    if ($xp -and $xp.Coupons -gt 0) {
        $xsub = '초기화 쿠폰 {0}개' -f $xp.Coupons
        if ($xp.CouponExpires) { $xsub += ' · ' + [DateTimeOffset]::FromUnixTimeSeconds([long]$xp.CouponExpires).LocalDateTime.ToString('M\/d') + ' 만료' }
    }
    if ($xp) {
        $five = Get-Fresh $xp.Five; $weekly = Get-Fresh $xp.Weekly
        $xstatus = Get-FetchStatus 'codex' '연결됨 · codex app-server'; $xupd = $script:Fetch.codex.At; $xok = $true
    } else {
        # 실시간 조회 실패/대기 중에는 세션 기록(낡을 수 있음)으로 대체
        $q = $null; try { $q = Get-CodexQuota } catch {}
        $five = $q.Five; $weekly = $q.Weekly; $xupd = $q.Recorded; $xok = [bool]$q
        $xstatus = $(if ($q) { '세션 기록 기준(낡을 수 있음) · ' + (Get-FetchStatus 'codex' '') } else { Get-FetchStatus 'codex' '' })
    }
    [void]$list.Add(@{
        Id = 'codex'; Short = 'Codex'; Name = 'Codex'; Sub = '계정 한도 공유'; Glyph = [string][char]0x2318
        Rows = @(@{ Label = 'Codex 계정 한도'; Sub = $xsub; Five = $five; Weekly = $weekly })
        Ok = $xok; Status = $xstatus; Updated = $xupd; Action = $null
    })
    $cp = $script:Fetch.claude.Parsed
    $crow = New-Object System.Collections.ArrayList
    [void]$crow.Add(@{ Label = 'Claude 계정 전체'; Sub = '구독 한도'; Five = (Get-Fresh $cp.Session); Weekly = (Get-Fresh $cp.Week) })
    foreach ($m in @($cp.Models)) { if ($m) { [void]$crow.Add(@{ Label = $m.Name; Sub = '모델 전용 주간'; Five = $null; Weekly = (Get-Fresh $m.Win) }) } }
    [void]$list.Add(@{
        Id = 'claude'; Short = 'Claude'; Name = 'Claude Code'; Sub = '계정과 모델 전용 한도'; Glyph = [string][char]0x2733
        Rows = $crow.ToArray(); Ok = [bool]$cp; Status = (Get-FetchStatus 'claude' '연결됨 · claude /usage')
        Updated = $script:Fetch.claude.At; Action = $null
    })
    $ap = $script:Fetch.antigravity.Parsed
    [void]$list.Add(@{
        Id = 'antigravity'; Short = 'AG'; Name = 'Antigravity'; Sub = 'Gemini와 Claude/GPT 공유 한도'; Glyph = [string][char]0x2726
        Rows = @(
            @{ Label = 'Gemini 공유'; Sub = 'Gemini 4 · 3.8 Flash'; Five = (Get-Fresh $ap.g.Five); Weekly = (Get-Fresh $ap.g.Weekly) },
            @{ Label = 'Claude/GPT 공유'; Sub = 'Claude Opus·Sonnet · GPT-OSS'; Five = (Get-Fresh $ap.t.Five); Weekly = (Get-Fresh $ap.t.Weekly) })
        Ok = [bool]$ap; Status = (Get-FetchStatus 'antigravity' '연결됨 · agy /usage')
        Updated = $script:Fetch.antigravity.At; Action = $null
    })
    return (Sort-Providers $list)
}

# 표시 순서: Claude → Codex → Antigravity
$script:ProviderOrder = @('claude', 'codex', 'antigravity')
function Sort-Providers($list) {
    $out = New-Object System.Collections.ArrayList
    foreach ($id in $script:ProviderOrder) { foreach ($p in $list) { if ($p.Id -eq $id) { [void]$out.Add($p) } } }
    return $out
}

function Get-DemoProviders {
    $now = Get-Now
    function W($rem, $secs) { [pscustomobject]@{ Remaining = $rem; Reset = $now + $secs } }
    $l = New-Object System.Collections.ArrayList
    [void]$l.Add(@{ Id = 'codex'; Short = 'Codex'; Name = 'Codex'; Sub = '계정 한도 공유'; Glyph = [string][char]0x2318
        Rows = @(@{ Label = 'Codex 계정 한도'; Sub = 'ChatGPT 계정 공유'; Five = $null; Weekly = (W 9 (6 * 86400 + 7 * 3600)) })
        Ok = $true; Status = '연결됨 · Codex 세션 기록'; Updated = Get-Date; Action = $null })
    [void]$l.Add(@{ Id = 'claude'; Short = 'Claude'; Name = 'Claude Code'; Sub = '계정과 모델 전용 한도'; Glyph = [string][char]0x2733
        Rows = @(@{ Label = 'Claude 계정 전체'; Sub = '구독 한도'; Five = (W 86 (4 * 3600 + 120)); Weekly = (W 17 (2 * 86400 + 7 * 3600)) },
                 @{ Label = 'Opus'; Sub = '모델 전용 주간'; Five = $null; Weekly = (W 40 (2 * 86400)) })
        Ok = $true; Status = '연결됨 · claude /usage'; Updated = Get-Date; Action = $null })
    [void]$l.Add(@{ Id = 'antigravity'; Short = 'AG'; Name = 'Antigravity'; Sub = 'Gemini와 Claude/GPT 공유 한도'; Glyph = [string][char]0x2726
        Rows = @(@{ Label = 'Gemini 공유'; Sub = 'Gemini 4 · 3.8 Flash'; Five = (W 93.6 4000); Weekly = (W 95.8 (6 * 86400 + 7 * 3600)) },
                 @{ Label = 'Claude/GPT 공유'; Sub = 'Claude Opus·Sonnet · GPT-OSS'; Five = (New-Win 100 0 300); Weekly = (W 5.1 (3 * 86400 + 18 * 3600)) })
        Ok = $true; Status = '연결됨 · agy /usage'; Updated = Get-Date; Action = $null })
    return (Sort-Providers $l)
}

# ---------- 표시 문자열·헤드라인 ----------
function Format-Pct($v) { return ('{0:0.#}%' -f $v) }
function Format-Left($unix) {
    $span = [DateTimeOffset]::FromUnixTimeSeconds([long]$unix).LocalDateTime - (Get-Date)
    if ($span.TotalHours -ge 24) { return '{0}일 {1}시간 남음' -f [int][math]::Floor($span.TotalDays), $span.Hours }
    if ($span.TotalMinutes -ge 60) { return '{0}시간 {1}분 남음' -f [int][math]::Floor($span.TotalHours), $span.Minutes }
    return '{0}분 남음' -f [math]::Max(1, [int]$span.TotalMinutes)
}
function Format-At($unix) { return [DateTimeOffset]::FromUnixTimeSeconds([long]$unix).LocalDateTime.ToString('M\/d HH:mm') + ' 초기화' }

function Get-RowHeadline($row, $mode) {
    $w = switch ($mode) { 'five' { $row.Five } 'weekly' { $row.Weekly } default { if ($row.Weekly) { $row.Weekly } else { $row.Five } } }
    if ($w) { return [double]$w.Remaining } else { return $null }
}
function Get-ProviderHeadline($p, $mode) {
    $vals = @(foreach ($r in $p.Rows) { $h = Get-RowHeadline $r $mode; if ($null -ne $h) { $h } })
    if ($vals.Count -eq 0) { return $null }
    return ($vals | Measure-Object -Minimum).Minimum
}

function Wait-Fetch {
    $deadline = (Get-Date).AddSeconds(50)
    while ((Get-Date) -lt $deadline) {
        $busy = $false
        foreach ($id in 'claude', 'codex', 'antigravity') { if ($script:Fetch[$id].Proc) { [void](Complete-CliFetch $id); if ($script:Fetch[$id].Proc) { $busy = $true } } }
        if (-not $busy) { break }
        Start-Sleep -Milliseconds 300
    }
}
if ($Probe) {
    Request-Fetch 0; Wait-Fetch
    foreach ($p in (Get-Providers)) {
        "[{0}] {1}" -f $p.Name, $p.Status
        foreach ($r in $p.Rows) {
            foreach ($pair in @(@('5시간', $r.Five), @('주간', $r.Weekly))) {
                if ($pair[1] -and $pair[1].Reset) { "   {0} {1}: {2} 남음 · {3} · {4}" -f $r.Label, $pair[0], (Format-Pct $pair[1].Remaining), (Format-Left $pair[1].Reset), (Format-At $pair[1].Reset) }
                elseif ($pair[1]) { "   {0} {1}: {2} 남음 · 초기화 시각 없음(사용 전)" -f $r.Label, $pair[0], (Format-Pct $pair[1].Remaining) }
                else { "   {0} {1}: 미확인" -f $r.Label, $pair[0] }
            }
        }
    }
    exit 0
}

# ---------- 그리기 ----------
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Windows.Forms;
public static class QNative { [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h); }
public class QPanel : Panel { public QPanel() { this.DoubleBuffered = true; this.ResizeRedraw = true; } }
'@

$PanelW = 520
$script:Hits = New-Object System.Collections.ArrayList
$C = @{
    bg = [Drawing.Color]::FromArgb(22, 24, 28);    card = [Drawing.Color]::FromArgb(31, 34, 40)
    border = [Drawing.Color]::FromArgb(52, 56, 64); text = [Drawing.Color]::FromArgb(236, 239, 243)
    muted = [Drawing.Color]::FromArgb(138, 146, 158); mint = [Drawing.Color]::FromArgb(110, 222, 172)
    mintDark = [Drawing.Color]::FromArgb(14, 40, 30); chipOff = [Drawing.Color]::FromArgb(48, 52, 60)
    track = [Drawing.Color]::FromArgb(58, 62, 70);  amber = [Drawing.Color]::FromArgb(245, 166, 35)
    red = [Drawing.Color]::FromArgb(232, 84, 84)
}
$script:BrushCache = @{}
function Br($c) { $k = $c.ToArgb(); if (-not $script:BrushCache.ContainsKey($k)) { $script:BrushCache[$k] = New-Object Drawing.SolidBrush $c }; return $script:BrushCache[$k] }
function Rc($x, $y, $w, $h) { return New-Object Drawing.RectangleF -ArgumentList ([single]$x), ([single]$y), ([single]$w), ([single]$h) }
function New-RoundPath($r, [float]$rad) {
    $p = New-Object Drawing.Drawing2D.GraphicsPath; $d = $rad * 2
    $p.AddArc($r.X, $r.Y, $d, $d, 180, 90); $p.AddArc($r.Right - $d, $r.Y, $d, $d, 270, 90)
    $p.AddArc($r.Right - $d, $r.Bottom - $d, $d, $d, 0, 90); $p.AddArc($r.X, $r.Bottom - $d, $d, $d, 90, 90)
    $p.CloseFigure(); return $p
}
function Fill-Round($g, $color, $r, $rad) { $p = New-RoundPath $r $rad; $g.FillPath((Br $color), $p); $p.Dispose() }
function Stroke-Round($g, $color, $r, $rad) { $p = New-RoundPath $r $rad; $pen = New-Object Drawing.Pen $color, 1; $g.DrawPath($pen, $p); $pen.Dispose(); $p.Dispose() }

$F = @{}
function Build-Fonts($name) {
    $px = [Drawing.GraphicsUnit]::Pixel; $bold = [Drawing.FontStyle]::Bold; $reg = [Drawing.FontStyle]::Regular
    $F.title = New-Object Drawing.Font $name, 13, $bold, $px
    $F.h     = New-Object Drawing.Font $name, 15, $bold, $px
    $F.b     = New-Object Drawing.Font $name, 14, $bold, $px
    $F.pct   = New-Object Drawing.Font $name, 19, $bold, $px
    $F.n     = New-Object Drawing.Font $name, 12, $reg, $px
    $F.s     = New-Object Drawing.Font $name, 11, $reg, $px
    $F.sym   = New-Object Drawing.Font 'Segoe UI Symbol', 16, $reg, $px
}

# ---------- 스킨(색·글꼴·막대 모양) ----------
function Rgb($r, $g, $b, $a = 255) { return [Drawing.Color]::FromArgb($a, $r, $g, $b) }
$Skins = [ordered]@{
    mint = @{ Name = '민트'; title = 'AI 한도 · Windows'; font = 'Malgun Gothic'; bar = 'round'; radius = 12; chipR = 13; grad = $null; blobs = @()
        bg = (Rgb 22 24 28); card = (Rgb 31 34 40); border = (Rgb 52 56 64); text = (Rgb 236 239 243); muted = (Rgb 138 146 158)
        accent = (Rgb 110 222 172); accentText = (Rgb 14 40 30); chipOff = (Rgb 48 52 60); track = (Rgb 58 62 70)
        good = (Rgb 110 222 172); warn = (Rgb 245 166 35); bad = (Rgb 232 84 84) }
    aurora = @{ Name = '오로라'; title = 'AI 한도'; font = 'Malgun Gothic'; bar = 'round'; radius = 18; chipR = 13
        grad = @((Rgb 38 22 92), (Rgb 8 70 96))
        blobs = @(@(70, 50, 250, (Rgb 255 80 190)), @(470, 380, 300, (Rgb 30 200 255)), @(120, 700, 260, (Rgb 130 90 255)))
        bg = (Rgb 20 20 50); card = (Rgb 255 255 255 30); border = (Rgb 255 255 255 70); text = (Rgb 255 255 255); muted = (Rgb 205 210 235)
        accent = (Rgb 140 240 255); accentText = (Rgb 8 30 52); chipOff = (Rgb 255 255 255 36); track = (Rgb 255 255 255 46)
        good = (Rgb 120 245 205); warn = (Rgb 255 205 105); bad = (Rgb 255 125 150) }
    navy = @{ Name = '네이비'; title = 'AI 한도'; font = 'Malgun Gothic'; bar = 'glow'; radius = 14; chipR = 13
        grad = @((Rgb 10 22 46), (Rgb 6 11 24)); blobs = @(, @(480, 40, 260, (Rgb 40 130 255)))
        bg = (Rgb 8 16 32); card = (Rgb 16 30 58); border = (Rgb 34 58 100); text = (Rgb 232 240 255); muted = (Rgb 128 150 186)
        accent = (Rgb 86 196 255); accentText = (Rgb 4 20 40); chipOff = (Rgb 24 42 78); track = (Rgb 26 44 80)
        good = (Rgb 86 196 255); warn = (Rgb 255 190 70); bad = (Rgb 255 100 110) }
    paper = @{ Name = '페이퍼'; title = 'AI 한도'; font = 'Malgun Gothic'; bar = 'thin'; radius = 14; chipR = 13; grad = $null; blobs = @()
        bg = (Rgb 245 240 230); card = (Rgb 255 253 248); border = (Rgb 226 217 202); text = (Rgb 44 40 36); muted = (Rgb 134 124 110)
        accent = (Rgb 205 104 72); accentText = (Rgb 255 255 255); chipOff = (Rgb 235 227 213); track = (Rgb 231 223 209)
        good = (Rgb 64 150 108); warn = (Rgb 224 148 36); bad = (Rgb 205 66 56) }
    terminal = @{ Name = '터미널'; title = 'AI QUOTA // WIN'; font = 'GulimChe'; bar = 'seg'; radius = 2; chipR = 3; grad = $null; blobs = @()
        bg = (Rgb 5 10 6); card = (Rgb 9 18 10); border = (Rgb 28 86 40); text = (Rgb 150 255 165); muted = (Rgb 78 150 92)
        accent = (Rgb 70 255 120); accentText = (Rgb 0 22 4); chipOff = (Rgb 14 32 16); track = (Rgb 20 46 24)
        good = (Rgb 70 255 120); warn = (Rgb 255 214 60); bad = (Rgb 255 92 82) }
    ring = @{ Name = '링'; title = 'AI 한도'; font = 'Malgun Gothic'; bar = 'ring'; radius = 16; chipR = 13; grad = $null; blobs = @()
        bg = (Rgb 19 21 33); card = (Rgb 30 33 51); border = (Rgb 48 52 78); text = (Rgb 238 240 252); muted = (Rgb 142 148 178)
        accent = (Rgb 166 138 255); accentText = (Rgb 20 12 50); chipOff = (Rgb 42 46 70); track = (Rgb 46 50 76)
        good = (Rgb 96 226 172); warn = (Rgb 255 186 78); bad = (Rgb 255 108 122) }
}
function Set-Skin($id) {
    if (-not $Skins.Contains($id)) { $id = 'mint' }
    $s = $Skins[$id]; $script:SkinId = $id; $script:Sk = $s
    foreach ($k in 'bg', 'card', 'border', 'text', 'muted', 'chipOff', 'track') { $C[$k] = $s[$k] }
    $C.mint = $s.accent; $C.mintDark = $s.accentText; $C.good = $s.good; $C.amber = $s.warn; $C.red = $s.bad
    $script:BrushCache.Clear()
    Build-Fonts $s.font
}
Set-Skin $script:Settings.skin
$script:SfLine = New-Object Drawing.StringFormat
$script:SfLine.FormatFlags = [Drawing.StringFormatFlags]::NoWrap; $script:SfLine.Trimming = 'EllipsisCharacter'; $script:SfLine.LineAlignment = 'Near'
$script:SfWrap = New-Object Drawing.StringFormat
$script:SfWrap.LineAlignment = 'Near'

function T($g, $text, $font, $color, $x, $y, $w, $h, $align = 'L', $wrap = $false) {
    $sf = if ($wrap) { $script:SfWrap } else { $script:SfLine }
    $sf.Alignment = switch ($align) { 'R' { 'Far' } 'C' { 'Center' } default { 'Near' } }
    $g.DrawString([string]$text, $font, (Br $color), (Rc $x $y $w $h), $sf)
}
function Get-Level($rem) { if ($rem -ge 40) { return $C.good } elseif ($rem -ge 15) { return $C.amber } else { return $C.red } }
function Add-Hit($r, $action) { [void]$script:Hits.Add(@{ R = $r; A = $action }) }

function Draw-Chip($g, $text, $x, $y, $on, $action) {
    $tw = $g.MeasureString($text, $F.n).Width
    $w = [math]::Ceiling($tw) + 24
    $r = Rc $x $y $w 26
    Fill-Round $g $(if ($on) { $C.mint } else { $C.chipOff }) $r $script:Sk.chipR
    T $g $text $F.n $(if ($on) { $C.mintDark } else { $C.text }) $x ($y + 5) $w 18 'C'
    Add-Hit $r $action
    return $x + $w + 8
}

function Draw-Cell($g, $w, $cx, $y0, $cw) {
    if ($null -eq $w) {
        T $g '—' $F.pct $C.muted $cx ($y0 + 6) 40 26
        T $g '미확인' $F.s $C.muted $cx ($y0 + 38) $cw 16
        return
    }
    $rem = [double]$w.Remaining
    $lvl = Get-Level $rem
    $style = $script:Sk.bar
    if ($style -eq 'ring') {
        # 도넛 게이지: 가운데 숫자, 오른쪽에 남은 시간
        $d = 46; $rx = $cx + 2; $ry = $y0 + 8
        $pt = New-Object Drawing.Pen $C.track, 6
        $g.DrawEllipse($pt, [single]($rx + 3), [single]($ry + 3), [single]($d - 6), [single]($d - 6)); $pt.Dispose()
        if ($rem -gt 0) {
            $pf = New-Object Drawing.Pen $lvl, 6; $pf.StartCap = 'Round'; $pf.EndCap = 'Round'
            $g.DrawArc($pf, [single]($rx + 3), [single]($ry + 3), [single]($d - 6), [single]($d - 6), [single]-90, [single](3.6 * [math]::Min(100, $rem))); $pf.Dispose()
        }
        T $g ([string][math]::Round($rem)) $F.b $C.text $rx ($ry + 13) $d 20 'C'
        $rt = if ($w.Reset) { (Format-Left $w.Reset).Replace(' 남음', '') + "`n" + ([DateTimeOffset]::FromUnixTimeSeconds([long]$w.Reset).LocalDateTime.ToString('M\/d HH:mm')) } elseif ($rem -ge 100) { "아직`n사용 전" } else { "초기화`n미제공" }
        T $g $rt $F.s $C.muted ($cx + 56) ($y0 + 14) ($cw - 56) 40 'L' $true
        return
    }
    T $g (Format-Pct $rem) $F.pct $C.text $cx ($y0 + 6) 70 26
    $bx = $cx + 62; $bw = $cw - 62 - 4
    $fw = [math]::Floor($bw * [math]::Min(100, $rem) / 100)
    switch ($style) {
        'thin' {
            Fill-Round $g $C.track (Rc $bx ($y0 + 19) $bw 4) 2
            if ($rem -gt 0) { Fill-Round $g $lvl (Rc $bx ($y0 + 19) ([math]::Max(4, $fw)) 4) 2 }
        }
        'seg' {
            $n = 10; $gap = 2; $sw = [math]::Floor(($bw - ($n - 1) * $gap) / $n); $filled = [math]::Ceiling($rem / 10)
            for ($i = 0; $i -lt $n; $i++) { Fill-Round $g $(if ($i -lt $filled) { $lvl } else { $C.track }) (Rc ($bx + $i * ($sw + $gap)) ($y0 + 14) $sw 12) 1 }
        }
        'glow' {
            Fill-Round $g $C.track (Rc $bx ($y0 + 16) $bw 8) 4
            if ($rem -gt 0) {
                $gw = [math]::Max(8, $fw)
                Fill-Round $g ([Drawing.Color]::FromArgb(48, $lvl.R, $lvl.G, $lvl.B)) (Rc ($bx - 3) ($y0 + 13) ($gw + 6) 14) 7
                Fill-Round $g $lvl (Rc $bx ($y0 + 16) $gw 8) 4
            }
        }
        default {
            Fill-Round $g $C.track (Rc $bx ($y0 + 16) $bw 8) 4
            if ($rem -gt 0) { Fill-Round $g $lvl (Rc $bx ($y0 + 16) ([math]::Max(8, $fw)) 8) 4 }
        }
    }
    $sub = if ($w.Reset) { (Format-Left $w.Reset) + "`n" + (Format-At $w.Reset) } elseif ($rem -ge 100) { '아직 사용 안 함' } else { '초기화 시각 미제공' }
    T $g $sub $F.s $C.muted $cx ($y0 + 36) ($cw - 4) 30 'L' $true
}

# ---------- 트레이 아이콘(스킨별 모양) ----------
$script:IconStyle = @{ mint = 'fill'; aurora = 'grad'; navy = 'bar'; paper = 'fill'; terminal = 'term'; ring = 'ring' }
function New-TrayIcon([string]$text, $lvl, $rem) {
    $bmp = New-Object Drawing.Bitmap 32, 32
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'
    $g.Clear([Drawing.Color]::Transparent)
    $dark = [Drawing.Color]::FromArgb(14, 18, 24)
    $lum = 0.299 * $lvl.R + 0.587 * $lvl.G + 0.114 * $lvl.B
    $style = $script:IconStyle[$script:SkinId]
    $full = New-Object Drawing.RectangleF 0, 0, 32, 32
    $fontName = 'Segoe UI'; $size = if ($text.Length -ge 3) { 15 } elseif ($text.Length -eq 2) { 21 } else { 24 }
    $txt = [Drawing.Color]::White; $dy = 1
    switch ($style) {
        'grad' {
            $gb = New-Object Drawing.Drawing2D.LinearGradientBrush $full, $script:Sk.grad[0], $lvl, ([single]55)
            $p = New-RoundPath $full 7; $g.FillPath($gb, $p); $p.Dispose(); $gb.Dispose()
        }
        'bar' {
            $p = New-RoundPath $full 7; $g.FillPath((Br $C.card), $p); $p.Dispose()
            $pen = New-Object Drawing.Pen $C.border, 1.5; $g.DrawPath($pen, (New-RoundPath (New-Object Drawing.RectangleF 1, 1, 30, 30) 6)); $pen.Dispose()
            $txt = $C.text; $dy = -2; $size = if ($text.Length -ge 3) { 15 } else { 21 }
            $bw = 24 * [math]::Min(100, [double]$(if ($null -ne $rem) { $rem } else { 0 })) / 100
            Fill-Round $g ([Drawing.Color]::FromArgb(70, $lvl.R, $lvl.G, $lvl.B)) (Rc 4 24 24 4) 2
            if ($bw -gt 1) { Fill-Round $g $lvl (Rc 4 24 $bw 4) 2 }
        }
        'term' {
            $g.FillRectangle((Br $C.bg), 0, 0, 32, 32)
            $pen = New-Object Drawing.Pen $lvl, 2; $g.DrawRectangle($pen, 1, 1, 30, 30); $pen.Dispose()
            $txt = $lvl; $fontName = 'Consolas'; $size = if ($text.Length -ge 3) { 16 } elseif ($text.Length -eq 2) { 22 } else { 24 }
        }
        'ring' {
            $p = New-RoundPath $full 8; $g.FillPath((Br $C.bg), $p); $p.Dispose()
            $pt = New-Object Drawing.Pen $C.track, 4; $g.DrawEllipse($pt, 4, 4, 24, 24); $pt.Dispose()
            if ($null -ne $rem -and $rem -gt 0) {
                $pf = New-Object Drawing.Pen $lvl, 4; $pf.StartCap = 'Round'; $pf.EndCap = 'Round'
                $g.DrawArc($pf, 4, 4, 24, 24, -90, [single](3.6 * [math]::Min(100, $rem))); $pf.Dispose()
            }
            $txt = $C.text; $size = if ($text.Length -ge 3) { 10 } else { 13 }; $dy = 0
        }
        default {
            $p = New-RoundPath $full 7; $g.FillPath((Br $lvl), $p); $p.Dispose()
            $txt = if ($lum -gt 150) { $dark } else { [Drawing.Color]::White }
        }
    }
    $font = New-Object Drawing.Font $fontName, $size, ([Drawing.FontStyle]::Bold), ([Drawing.GraphicsUnit]::Pixel)
    # 글자가 32px 아이콘 폭을 넘으면 맞을 때까지 줄인다(Consolas 두 자리 숫자 잘림 방지)
    while ($size -gt 8 -and $g.MeasureString($text, $font).Width -gt 30) {
        $font.Dispose(); $size--
        $font = New-Object Drawing.Font $fontName, $size, ([Drawing.FontStyle]::Bold), ([Drawing.GraphicsUnit]::Pixel)
    }
    $sf = New-Object Drawing.StringFormat; $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
    $sf.FormatFlags = [Drawing.StringFormatFlags]::NoWrap
    $g.DrawString($text, $font, (Br $txt), (New-Object Drawing.RectangleF 0, $dy, 32, 32), $sf)
    $g.Dispose(); $font.Dispose()
    $h = $bmp.GetHicon(); $bmp.Dispose()
    return @{ Icon = [Drawing.Icon]::FromHandle($h); Handle = $h }
}

# '표시' 칩에서 켠 항목만 패널에 보인다
function Get-Shown($providers) { return @($providers | Where-Object { $script:Settings.tray -contains $_.Id }) }

function Get-PanelHeight($providers) {
    $h = 186
    foreach ($p in (Get-Shown $providers)) { $h += $p.Rows.Count * 70 + 96 + 10 }
    return $h + 30
}

function Render-Panel($g, $providers) {
    $script:Hits.Clear()
    $mode = $script:Settings.mode
    $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'ClearTypeGridFit'
    $g.Clear($C.bg)
    $g.ResetTransform(); $g.ScaleTransform([single]$script:Scale, [single]$script:Scale)
    # 배경(그라데이션·빛 번짐)
    $hAll = Get-PanelHeight $providers
    if ($script:Sk.grad) {
        $gb = New-Object Drawing.Drawing2D.LinearGradientBrush (Rc 0 0 $PanelW $hAll), $script:Sk.grad[0], $script:Sk.grad[1], ([single]65)
        $g.FillRectangle($gb, 0, 0, $PanelW, $hAll); $gb.Dispose()
        foreach ($b in $script:Sk.blobs) {
            $bp = New-Object Drawing.Drawing2D.GraphicsPath
            $bp.AddEllipse([single]($b[0] - $b[2]), [single]($b[1] - $b[2]), [single](2 * $b[2]), [single](2 * $b[2]))
            $pg = New-Object Drawing.Drawing2D.PathGradientBrush $bp
            $pg.CenterColor = [Drawing.Color]::FromArgb(95, $b[3].R, $b[3].G, $b[3].B)
            $pg.SurroundColors = @([Drawing.Color]::FromArgb(0, $b[3].R, $b[3].G, $b[3].B))
            $g.FillPath($pg, $bp); $pg.Dispose(); $bp.Dispose()
        }
    }
    $rad = $script:Sk.radius
    # 머리글
    Fill-Round $g $C.mint (Rc 14 12 30 30) ([math]::Min(8, $rad))
    T $g 'A' $F.h $C.mintDark 14 18 30 20 'C'
    T $g $script:Sk.title $F.title $C.text 54 17 300 22
    T $g ([string][char]0x21BB) $F.sym $C.muted ($PanelW - 44) 16 30 24 'C'
    Add-Hit (Rc ($PanelW - 48) 10 36 34) 'refresh'
    $pinR = Rc ($PanelW - 118) 14 60 26
    Fill-Round $g $(if ($script:Settings.pinned) { $C.mint } else { $C.chipOff }) $pinR $script:Sk.chipR
    T $g $(if ($script:Settings.pinned) { '고정됨' } else { '고정' }) $F.n $(if ($script:Settings.pinned) { $C.mintDark } else { $C.text }) ($PanelW - 118) 19 60 18 'C'
    Add-Hit $pinR 'pin'
    $g.FillRectangle((Br $C.border), 0, 54, $PanelW, 1)
    # 옵션 칩
    T $g '표시' $F.n $C.muted 14 71 70 18
    $x = 80
    foreach ($id in $script:ProviderOrder) {
        $label = @{ codex = 'Codex'; claude = 'Claude'; antigravity = 'Antigravity' }[$id]
        $x = Draw-Chip $g $label $x 66 ($script:Settings.tray -contains $id) "tray:$id"
    }
    T $g '보기' $F.n $C.muted 14 107 70 18
    $x = 80
    foreach ($m in @(@('both', '5시간+주간'), @('five', '5시간'), @('weekly', '주간'))) { $x = Draw-Chip $g $m[1] $x 102 ($mode -eq $m[0]) ("mode:" + $m[0]) }
    T $g '스킨' $F.n $C.muted 14 143 70 18
    $x = 80
    foreach ($sid in $Skins.Keys) { $x = Draw-Chip $g $Skins[$sid].Name $x 138 ($script:SkinId -eq $sid) "skin:$sid" }
    $g.FillRectangle((Br $C.border), 0, 174, $PanelW, 1)
    # 카드
    $y = 184
    foreach ($p in (Get-Shown $providers)) {
        $rows = $p.Rows.Count
        $ch = $rows * 70 + 96
        $card = Rc 14 $y 492 $ch
        Fill-Round $g $C.card $card $rad
        Stroke-Round $g $C.border $card $rad
        T $g $p.Glyph $F.sym $C.mint 26 ($y + 10) 24 24 'C'
        T $g $p.Name $F.h $C.text 56 ($y + 11) 140 22
        $nw = $g.MeasureString($p.Name, $F.h).Width
        T $g $p.Sub $F.s $C.muted (56 + [math]::Min($nw, 140) + 4) ($y + 14) 230 18
        if ($p.Action) {
            T $g $p.Action $F.n $C.mint 380 ($y + 12) 112 18 'R'
            Add-Hit (Rc 380 ($y + 8) 120 26) 'link'
        }
        # 열 머리글
        if ($mode -eq 'both') { $cols = @(@('five', 224, 130, '5시간 잔여'), @('weekly', 364, 130, '주간 잔여')) }
        elseif ($mode -eq 'five') { $cols = @(, @('five', 264, 230, '5시간 잔여')) }
        else { $cols = @(, @('weekly', 264, 230, '주간 잔여')) }
        T $g '모델' $F.s $C.muted 28 ($y + 44) 100 16
        foreach ($col in $cols) { T $g $col[3] $F.s $C.muted $col[1] ($y + 44) $col[2] 16 }
        $g.FillRectangle((Br $C.border), 14, $y + 66, 492, 1)
        for ($i = 0; $i -lt $rows; $i++) {
            $row = $p.Rows[$i]; $y0 = $y + 66 + $i * 70
            T $g $row.Label $F.b $C.text 28 ($y0 + 12) 190 20
            T $g $row.Sub $F.s $C.muted 28 ($y0 + 34) 190 30 'L' $true
            foreach ($col in $cols) {
                $w = if ($col[0] -eq 'five') { $row.Five } else { $row.Weekly }
                Draw-Cell $g $w $col[1] $y0 $col[2]
            }
            if ($i -lt $rows - 1) { $g.FillRectangle((Br $C.border), 14, $y0 + 69, 492, 1) }
        }
        # 바닥 줄
        $fy = $y + 66 + $rows * 70 + 2
        $dot = if ($p.Ok) { $C.mint } else { $C.muted }
        $g.FillEllipse((Br $dot), 28, $fy + 8, 7, 7)
        T $g $p.Status $F.s $C.muted 42 ($fy + 4) 360 16
        if ($p.Updated) { T $g $p.Updated.ToString('HH:mm') $F.s $C.muted 420 ($fy + 4) 72 16 'R' }
        $y += $ch + 10
    }
    T $g '각 CLI 조회(claude·agy /usage, codex app-server) · 5분마다 갱신' $F.s $C.muted 14 ($y + 4) 492 16
    $hLog = Get-PanelHeight $providers
    $g.DrawRectangle((New-Object Drawing.Pen $C.border), 0, 0, $PanelW - 1, $hLog - 1)
    # 오른쪽 아래 크기 조절 손잡이
    $pen = New-Object Drawing.Pen $C.muted, 1
    foreach ($o in 4, 8, 12) { $g.DrawLine($pen, $PanelW - 3, $hLog - 3 - $o, $PanelW - 3 - $o, $hLog - 3) }
    $pen.Dispose()
}

if ($Shot) {
    $prov = if ($Demo) { Get-DemoProviders } else { Get-Providers }
    $h = Get-PanelHeight $prov
    $script:Scale = 1.0
    if ($Skin) { Set-Skin $Skin }
    $bmp = New-Object Drawing.Bitmap $PanelW, $h
    $g = [Drawing.Graphics]::FromImage($bmp)
    Render-Panel $g $prov
    $g.Dispose(); $bmp.Save($Shot, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    "saved $Shot ($PanelW x $h)"
    exit 0
}

if ($IconSheet) {
    # 스킨 × 단계(86/30/9) 아이콘을 확대해서 한 장으로 저장(시험용)
    $cell = 96; $pad = 12; $skIds = @($Skins.Keys); $vals = 86, 30, 9
    $sheet = New-Object Drawing.Bitmap (($vals.Count * ($cell + $pad) + $pad + 110)), (($skIds.Count * ($cell + $pad)) + $pad)
    $sg = [Drawing.Graphics]::FromImage($sheet); $sg.Clear([Drawing.Color]::FromArgb(200, 214, 222)); $sg.InterpolationMode = 'NearestNeighbor'
    $lf = New-Object Drawing.Font 'Malgun Gothic', 14, ([Drawing.FontStyle]::Bold), ([Drawing.GraphicsUnit]::Pixel)
    for ($r = 0; $r -lt $skIds.Count; $r++) {
        Set-Skin $skIds[$r]
        $sg.DrawString($Skins[$skIds[$r]].Name, $lf, [Drawing.Brushes]::Black, 8, $pad + $r * ($cell + $pad) + 36)
        for ($ci = 0; $ci -lt $vals.Count; $ci++) {
            $v = $vals[$ci]; $ic = New-TrayIcon ([string]$v) (Get-Level $v) $v
            $sg.DrawImage($ic.Icon.ToBitmap(), (110 + $pad + $ci * ($cell + $pad)), ($pad + $r * ($cell + $pad)), $cell, $cell)
        }
    }
    $sg.Dispose(); $sheet.Save($IconSheet); "saved $IconSheet"
    exit 0
}

# ---------- 트레이 ----------
$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\AIQuotaTrayWin', [ref]$created)
if (-not $created) { exit 0 }

function Write-Err($e) { try { ('{0} {1}' -f (Get-Date -Format s), $e) | Add-Content (Join-Path $StateDir 'error.log') -Encoding UTF8 } catch {} }

$script:iconHandle = [IntPtr]::Zero
# (New-TrayIcon 은 스킨과 함께 쓰기 위해 위쪽 그리기 구역으로 옮김)

$ni = New-Object Windows.Forms.NotifyIcon
$menu = New-Object Windows.Forms.ContextMenuStrip
$ni.ContextMenuStrip = $menu
$miOpen = $menu.Items.Add('패널 열기')
$miRefresh = $menu.Items.Add('새로 고침')
$miStartup = New-Object Windows.Forms.ToolStripMenuItem 'Windows 시작 시 실행'
[void]$menu.Items.Add($miStartup)
[void]$menu.Items.Add('-')
$miExit = $menu.Items.Add('종료')

$StartupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'AI Quota Tray.lnk'
$miStartup.Checked = Test-Path $StartupLink
$miStartup.Add_Click({
    if (Test-Path $StartupLink) { Remove-Item $StartupLink -Force }
    else {
        $sh = New-Object -ComObject WScript.Shell
        $lnk = $sh.CreateShortcut($StartupLink)
        $lnk.TargetPath = Join-Path $PSScriptRoot 'AIQuotaTray.exe'
        $lnk.Arguments = ''
        $lnk.WorkingDirectory = Split-Path $PSCommandPath
        $lnk.Save()
    }
    $miStartup.Checked = Test-Path $StartupLink
})

function Update-TrayIcon {
    $mode = $script:Settings.mode
    $min = $null; $parts = @()
    foreach ($p in $script:Providers) {
        if ($script:Settings.tray -notcontains $p.Id) { continue }
        $h = Get-ProviderHeadline $p $mode
        if ($null -ne $h) {
            $parts += ('{0} {1}' -f $p.Short, (Format-Pct $h))
            if ($null -eq $min -or $h -lt $min) { $min = $h }
        } else { $parts += ('{0} ?' -f $p.Short) }
    }
    if ($null -eq $min) { $text = '?'; $lvl = $C.muted; $remv = $null }
    else { $text = [string][math]::Round($min); $lvl = Get-Level $min; $remv = $min }
    $new = New-TrayIcon $text $lvl $remv
    $old = $script:iconHandle
    $ni.Icon = $new.Icon; $script:iconHandle = $new.Handle
    if ($old -ne [IntPtr]::Zero) { [void][QNative]::DestroyIcon($old) }
    $tip = if ($parts.Count) { $parts -join ' · ' } else { 'AI 한도' }
    $ni.Text = $tip.Substring(0, [math]::Min(63, $tip.Length))
}

# 패널 창
$form = New-Object Windows.Forms.Form
$form.FormBorderStyle = 'None'; $form.StartPosition = 'Manual'; $form.ShowInTaskbar = $false
$form.TopMost = $true; $form.BackColor = $C.bg
$panel = New-Object QPanel
$panel.Dock = 'Fill'
$form.Controls.Add($panel)
$script:LastHide = 0

$panel.Add_Paint({ param($s, $e) try { Render-Panel $e.Graphics $script:Providers } catch { Write-Err $_ } })
$panel.Add_MouseMove({
    param($s, $e)
    if ($script:Resize) {
        $cur = [Windows.Forms.Cursor]::Position
        $dx = $cur.X - $script:DragStart.X; $dy = $cur.Y - $script:DragStart.Y
        $z = $script:Zone; $r0 = $script:StartRect
        $H = Get-PanelHeight $script:Providers
        $sW = $null; $sH = $null
        if ($z -like '*R') { $sW = ($r0.Width + $dx) / $PanelW } elseif ($z -like '*L') { $sW = ($r0.Width - $dx) / $PanelW }
        if ($z -like 'B*') { $sH = ($r0.Height + $dy) / $H } elseif ($z -like 'T*') { $sH = ($r0.Height - $dy) / $H }
        # 가로·세로 비율은 고정이므로, 모서리는 더 크게 움직인 쪽을 따른다
        $s0 = $script:StartScale
        if ($null -ne $sW -and $null -ne $sH) { $req = if ([math]::Abs($sW - $s0) -ge [math]::Abs($sH - $s0)) { $sW } else { $sH } }
        elseif ($null -ne $sW) { $req = $sW } else { $req = $sH }
        $script:Settings.scale = [math]::Max(0.6, [math]::Min(2.5, $req))
        Apply-Size
        # 반대쪽 가장자리를 고정
        $nx = if ($z -like '*L') { $r0.Right - $form.Width } else { $r0.Left }
        $ny = if ($z -like 'T*') { $r0.Bottom - $form.Height } else { $r0.Top }
        $form.Location = New-Object Drawing.Point $nx, $ny
        return
    }
    if ($script:Drag) {
        $cur = [Windows.Forms.Cursor]::Position
        $form.Location = New-Object Drawing.Point ($script:DragOrigin.X + $cur.X - $script:DragStart.X), ($script:DragOrigin.Y + $cur.Y - $script:DragStart.Y)
        return
    }
    $zone = Get-Zone $e.X $e.Y
    if ($zone) {
        $s.Cursor = switch ($zone) {
            { $_ -in 'L', 'R' } { [Windows.Forms.Cursors]::SizeWE }
            { $_ -in 'T', 'B' } { [Windows.Forms.Cursors]::SizeNS }
            { $_ -in 'TL', 'BR' } { [Windows.Forms.Cursors]::SizeNWSE }
            default { [Windows.Forms.Cursors]::SizeNESW }
        }
        return
    }
    $lx = $e.X / $script:Scale; $ly = $e.Y / $script:Scale
    $over = $null
    foreach ($h in $script:Hits) { if ($h.R.Contains([single]$lx, [single]$ly)) { $over = $h.A; break } }
    $s.Cursor = if ($over) { [Windows.Forms.Cursors]::Hand } else { [Windows.Forms.Cursors]::SizeAll }
})
# 창 이동(빈 곳을 끌면 옮겨짐), 고정 시에는 다른 곳을 눌러도 닫히지 않음
$script:Drag = $false; $script:DragStart = $null; $script:DragOrigin = $null
$script:Resize = $false; $script:Zone = ''; $script:StartRect = $null; $script:StartScale = 1.0
# 가장자리 6px, 모서리 14px 범위를 크기 조절 구역으로 사용 (T/B + L/R 조합)
function Get-Zone($x, $y) {
    $w = $panel.ClientSize.Width; $h = $panel.ClientSize.Height
    $c = 14; $m = 6
    $nl = $x -lt $c; $nr = $x -ge $w - $c; $nt = $y -lt $c; $nb = $y -ge $h - $c
    if (($nl -or $nr) -and ($nt -or $nb)) { return $(if ($nt) { 'T' } else { 'B' }) + $(if ($nl) { 'L' } else { 'R' }) }
    $z = ''
    if ($y -lt $m) { $z += 'T' } elseif ($y -ge $h - $m) { $z += 'B' }
    if ($x -lt $m) { $z += 'L' } elseif ($x -ge $w - $m) { $z += 'R' }
    return $z
}
$form.Add_Deactivate({ if (-not $script:Settings.pinned -and -not $script:Drag -and -not $script:Resize) { $form.Hide(); $script:LastHide = [Environment]::TickCount } })
# Ctrl + 마우스 휠로도 크기 조절
$panel.Add_MouseWheel({
    param($s, $e)
    if (([Windows.Forms.Control]::ModifierKeys -band [Windows.Forms.Keys]::Control) -ne 0) {
        $step = if ($e.Delta -gt 0) { 0.1 } else { -0.1 }
        $script:Settings.scale = [math]::Max(0.6, [math]::Min(2.5, [math]::Round($script:Scale + $step, 2)))
        Apply-Size $true; Save-Settings
    }
})
$panel.Add_MouseUp({
    if ($script:Resize) {
        $script:Resize = $false; $script:Settings.scale = $script:Scale
        $script:Settings.posX = $form.Location.X; $script:Settings.posY = $form.Location.Y; Save-Settings
    }
    if ($script:Drag) {
        $script:Drag = $false; $panel.Cursor = [Windows.Forms.Cursors]::Default
        $script:Settings.posX = $form.Location.X; $script:Settings.posY = $form.Location.Y; Save-Settings
    }
})

function Refresh-All {
    try { $script:Providers = Get-Providers } catch { Write-Err $_ }
    try { Update-TrayIcon } catch { Write-Err $_ }
    if ($form.Visible) { Apply-Size }
}
# 요청 배율을 화면 크기에 맞춰 줄여서(작은 화면 대응) 창 크기에 반영
function Apply-Size {
    param([bool]$clamp = $false, $scr = $null)
    # 창이 떠 있으면 '지금 있는 모니터', 아직 안 떴으면 넘겨받은 모니터(없으면 주 모니터) 기준
    if (-not $scr) { $scr = if ($form.Visible) { [Windows.Forms.Screen]::FromControl($form) } else { [Windows.Forms.Screen]::PrimaryScreen } }
    $wa = $scr.WorkingArea
    $H = Get-PanelHeight $script:Providers
    $max = [math]::Min(($wa.Height - 24) / $H, ($wa.Width - 24) / $PanelW)
    $script:Scale = [math]::Max(0.5, [math]::Min([double]$script:Settings.scale, $max))
    $form.Size = New-Object Drawing.Size ([int][math]::Round($PanelW * $script:Scale)), ([int][math]::Round($H * $script:Scale))
    if ($clamp -and $form.Visible) {
        # 사용자가 크기를 키웠을 때만, 그 모니터 화면 밖으로 나가면 안으로 밀어 넣는다(주기 갱신 때는 위치를 건드리지 않음)
        $x = [math]::Max($wa.Left, [math]::Min($form.Left, $wa.Right - $form.Width))
        $y = [math]::Max($wa.Top, [math]::Min($form.Top, $wa.Bottom - $form.Height))
        if ($x -ne $form.Left -or $y -ne $form.Top) { $form.Location = New-Object Drawing.Point $x, $y }
    }
    $panel.Invalidate()
}
function Show-Panel {
    # 저장된 위치가 어느 모니터 안이면 그 모니터를 기준으로 크기·위치를 정한다(보조 모니터 포함)
    $scr = [Windows.Forms.Screen]::PrimaryScreen; $useSaved = $false
    if ($null -ne $script:Settings.posX) {
        foreach ($sc in [Windows.Forms.Screen]::AllScreens) {
            if ($sc.WorkingArea.Contains([int]$script:Settings.posX + 40, [int]$script:Settings.posY + 20)) { $scr = $sc; $useSaved = $true; break }
        }
    }
    Apply-Size $false $scr
    $wa = $scr.WorkingArea
    $w = $form.Width; $h = $form.Height
    $loc = New-Object Drawing.Point ($wa.Right - $w - 12), ($wa.Bottom - $h - 12)
    if ($useSaved) { $loc = New-Object Drawing.Point ([int]$script:Settings.posX), ([int]$script:Settings.posY) }
    $form.Location = $loc
    $panel.Invalidate(); $form.Show(); $form.Activate()
}

$panel.Add_MouseDown({
    param($s, $e)
    if ($e.Button -ne 'Left') { return }
    $zone = Get-Zone $e.X $e.Y
    if ($zone) {
        $script:Resize = $true; $script:Zone = $zone
        $script:DragStart = [Windows.Forms.Cursor]::Position
        $script:StartRect = New-Object Drawing.Rectangle $form.Left, $form.Top, $form.Width, $form.Height
        $script:StartScale = $script:Scale
        return
    }
    $hit = $false
    $lx = $e.X / $script:Scale; $ly = $e.Y / $script:Scale
    foreach ($h in $script:Hits) {
        if (-not $h.R.Contains([single]$lx, [single]$ly)) { continue }
        $hit = $true
        $a = [string]$h.A
        if ($a -eq 'refresh') { Request-Fetch 15; Refresh-All }
        elseif ($a -eq 'pin') { $script:Settings.pinned = -not $script:Settings.pinned; Save-Settings; $panel.Invalidate() }
        elseif ($a -like 'tray:*') {
            $id = $a.Substring(5)
            $cur = @($script:Settings.tray)
            if ($cur -contains $id) { if ($cur.Count -gt 1) { $cur = @($cur | Where-Object { $_ -ne $id }) } } else { $cur += $id }
            $script:Settings.tray = $cur; Save-Settings; Request-Fetch 15; Refresh-All
        }
        elseif ($a -like 'mode:*') { $script:Settings.mode = $a.Substring(5); Save-Settings; Refresh-All }
        elseif ($a -like 'skin:*') { $script:Settings.skin = $a.Substring(5); Set-Skin $script:Settings.skin; Save-Settings; $panel.Invalidate(); try { Update-TrayIcon } catch { Write-Err $_ } }
        break
    }
    if (-not $hit) {
        $script:Drag = $true
        $script:DragStart = [Windows.Forms.Cursor]::Position
        $script:DragOrigin = $form.Location
        $panel.Cursor = [Windows.Forms.Cursors]::SizeAll
    }
})

$ni.Add_MouseClick({
    param($s, $e)
    if ($e.Button -ne 'Left') { return }
    if ($form.Visible) { $form.Hide(); return }
    if ([Environment]::TickCount - $script:LastHide -lt 400) { return }
    Request-Fetch 60; Refresh-All; Show-Panel
})
$miOpen.Add_Click({ Request-Fetch 60; Refresh-All; Show-Panel })
$miRefresh.Add_Click({ Request-Fetch 15; Refresh-All })
$miExit.Add_Click({ $ni.Visible = $false; [Windows.Forms.Application]::Exit() })

# 1분마다 Codex 기록·화면 갱신, CLI 조회는 5분마다
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 60000
$timer.Add_Tick({ try { Request-Fetch 300 } catch { Write-Err $_ }; Refresh-All })
# 2초마다 끝난 CLI 조회 결과 수거(백그라운드 조회라 창이 멈추지 않음)
$pollTimer = New-Object Windows.Forms.Timer
$pollTimer.Interval = 2000
$pollTimer.Add_Tick({
    try {
        $done = $false
        foreach ($id in 'claude', 'codex', 'antigravity') { if ($script:Fetch[$id].Proc) { if (Complete-CliFetch $id) { $done = $true } } }
        if ($done) { Refresh-All }
    } catch { Write-Err $_ }
})

$script:Providers = @()
$ni.Visible = $true
Request-Fetch 0
Refresh-All
$timer.Start(); $pollTimer.Start()
[Windows.Forms.Application]::Run()

$ni.Dispose()
if ($script:iconHandle -ne [IntPtr]::Zero) { [void][QNative]::DestroyIcon($script:iconHandle) }
$mutex.ReleaseMutex()
