# Codex rate limits via the local app-server (WebSocket, loopback only). Prints the JSON result of account/rateLimits/read.
# Uses Codex's own login; this script never reads auth files.
$ErrorActionPreference = 'Stop'
$cx = $null
try {
    $m = [regex]::Match((Get-Content (Join-Path $env:USERPROFILE '.codex\config.toml') -Raw), "CODEX_CLI_PATH\s*=\s*'([^']+)'")
    if ($m.Success -and (Test-Path $m.Groups[1].Value)) { $cx = $m.Groups[1].Value }
} catch {}
if (-not $cx) {
    $d = Get-ChildItem 'C:\Program Files\WindowsApps' -Directory -Filter 'OpenAI.Codex_*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
    if ($d) { $t = Join-Path $d.FullName 'app\resources\codex.exe'; if (Test-Path $t) { $cx = $t } }
}
# npm 으로 설치한 Codex CLI (%APPDATA%\npm\node_modules\@openai\codex 아래 플랫폼 패키지에 실제 codex.exe 가 있다)
if (-not $cx) {
    $npmRoot = Join-Path $env:APPDATA 'npm\node_modules\@openai\codex'
    if (Test-Path $npmRoot) {
        $t = Get-ChildItem $npmRoot -Recurse -Filter codex.exe -ErrorAction SilentlyContinue | Where-Object { $_.FullName -like '*win32*' } | Select-Object -First 1
        if ($t) { $cx = $t.FullName }
    }
}
if (-not $cx) { [Console]::Error.WriteLine('codex.exe not found'); exit 3 }

$port = Get-Random -Minimum 47000 -Maximum 49000
$psi = New-Object Diagnostics.ProcessStartInfo
$psi.FileName = $cx; $psi.Arguments = "app-server --listen ws://127.0.0.1:$port"
$psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
$psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
$p = [Diagnostics.Process]::Start($psi)
$null = $p.StandardError.ReadToEndAsync(); $null = $p.StandardOutput.ReadToEndAsync()
$ws = New-Object Net.WebSockets.ClientWebSocket
$cts = New-Object Threading.CancellationTokenSource 30000
$code = 1
try {
    $ok = $false
    for ($i = 0; $i -lt 20 -and -not $ok; $i++) {
        try { $ws.ConnectAsync("ws://127.0.0.1:$port", $cts.Token).Wait(); $ok = $true }
        catch { Start-Sleep -Milliseconds 400; $ws.Dispose(); $ws = New-Object Net.WebSockets.ClientWebSocket }
    }
    if (-not $ok) { throw 'connect failed' }
    function WsSend($s) { $b = [Text.Encoding]::UTF8.GetBytes($s); $seg = New-Object ArraySegment[byte] (, $b); $ws.SendAsync($seg, 'Text', $true, $cts.Token).Wait() }
    function WsRecv($pattern) {
        $end = (Get-Date).AddSeconds(20)
        while ((Get-Date) -lt $end) {
            $buf = New-Object byte[] 262144; $seg = New-Object ArraySegment[byte] (, $buf)
            $t = $ws.ReceiveAsync($seg, $cts.Token)
            if (-not $t.Wait(8000)) { break }
            $m = [Text.Encoding]::UTF8.GetString($buf, 0, $t.Result.Count)
            if ($m -match $pattern) { return $m }
        }
        return $null
    }
    WsSend '{"id":1,"method":"initialize","params":{"clientInfo":{"name":"ai-quota-tray","version":"1.0"}}}'
    if (-not (WsRecv '"id":1[,}]')) { throw 'initialize timeout' }
    WsSend '{"method":"initialized"}'
    WsSend '{"id":2,"method":"account/rateLimits/read"}'
    $r = WsRecv '"id":2[,}]'
    if (-not $r) { throw 'rateLimits timeout' }
    [Console]::Out.WriteLine($r)
    $code = 0
} catch { [Console]::Error.WriteLine($_.Exception.Message) }
finally { try { $ws.Dispose() } catch {}; try { $p.Kill() } catch {} }
exit $code
