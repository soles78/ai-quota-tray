# AI 한도 트레이 설치: 이 폴더 위치를 기준으로 바탕화면 바로가기(와 선택적으로 시작 프로그램)를 만든다.
# 폴더를 옮긴 뒤 한 번 실행하면 바로가기가 새 위치를 가리킨다.  -Startup 시작 프로그램도 등록 / -Remove 바로가기 제거
param([switch]$Startup, [switch]$Remove)
$ErrorActionPreference = 'Stop'
$dir = $PSScriptRoot
$exe = Join-Path $dir 'AIQuotaTray.exe'
$desk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'AI 한도.lnk'
$start = Join-Path ([Environment]::GetFolderPath('Startup')) 'AI Quota Tray.lnk'

if ($Remove) {
    foreach ($f in $desk, $start) { if (Test-Path $f) { Remove-Item $f -Force; "제거: $f" } }
    Get-Process AIQuotaTray -ErrorAction SilentlyContinue | Stop-Process -Force
    return
}

# 실행 파일이 없으면(소스만 옮겼을 때) 같은 폴더의 AIQuotaTray.cs 로 다시 만든다
if (-not (Test-Path $exe)) {
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    $sma = (Get-ChildItem (Join-Path $env:WINDIR 'Microsoft.NET\assembly\GAC_MSIL\System.Management.Automation') -Recurse -Filter System.Management.Automation.dll | Select-Object -First 1).FullName
    if (-not ((Test-Path $csc) -and $sma)) { throw 'AIQuotaTray.exe 가 없고, 다시 만들 도구(.NET Framework 4/Windows PowerShell 5.1)도 찾지 못했습니다.' }
    $icoArg = if (Test-Path (Join-Path $dir 'ai_quota.ico')) { "/win32icon:$(Join-Path $dir 'ai_quota.ico')" } else { '' }
    & $csc /nologo /target:winexe "/out:$exe" $icoArg "/reference:$sma" (Join-Path $dir 'AIQuotaTray.cs')
    if (-not (Test-Path $exe)) { throw '실행 파일 생성 실패' }
    'AIQuotaTray.exe 를 새로 만들었습니다.'
}

function New-Link($path) {
    $sh = New-Object -ComObject WScript.Shell
    $l = $sh.CreateShortcut($path)
    $l.TargetPath = $exe; $l.Arguments = ''; $l.WorkingDirectory = $dir; $l.WindowStyle = 7
    $l.Description = 'AI 한도 트레이 (Claude·Codex·Antigravity)'
    $ico = Join-Path $dir 'ai_quota.ico'
    if (Test-Path $ico) { $l.IconLocation = $ico }
    $l.Save()
}
New-Link $desk; "바탕화면 바로가기: $desk"
if ($Startup) { New-Link $start; "시작 프로그램 등록: $start" }
elseif (Test-Path $start) { New-Link $start; "시작 프로그램 바로가기를 새 위치로 갱신: $start" }
"완료. 바탕화면의 'AI 한도'를 실행하세요."
