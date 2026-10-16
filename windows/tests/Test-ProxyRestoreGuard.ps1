# 系统代理"自指"防护的回归测试。
#
# 背景：如果启动前的系统代理本来就指着本工具自己的本地端口（上一轮退出没走干净），
# 那份"原设置"被还原时就会把系统指回一个已经没人监听的端口 —— 浏览器打不开网页，
# 而在隧道运行时启动、之后一直沿用该代理的程序会永远提示"等待网络"。
# 这里验证三个行为：
#   A 还原时：备份指向我们自己端口 -> 不还原那个死端口，改为关闭系统代理
#   B 还原时：备份指向别人的代理   -> 必须原样还原（不能误伤第三方代理）
#   C 备份时：启动前代理指向我们端口 -> 写出的备份里不能留下那个端口
#
# ⚠️ 测试过程会临时改写 Windows 系统代理（结束后还原）。
#    只在进程启动那一刻读一次系统代理、之后一直沿用的程序（例如 Codex 桌面端），
#    如果恰好在测试期间启动，就会记住那个临时端口 —— 跑完重启它一次即可。
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

$app = Join-Path (Split-Path -Parent $PSScriptRoot) 'HK-Tunnel.ps1'
$text = [System.IO.File]::ReadAllText($app, [System.Text.Encoding]::UTF8)

$cut = $text.IndexOf('Add-Type -AssemblyName System.Windows.Forms')
if ($cut -lt 0) { throw '找不到 GUI 段起点。' }
$prefix = $text.Substring(0, $cut)
$appDir = Split-Path -Parent $PSScriptRoot
$prefix = [regex]::Replace($prefix, '(?s)\[CmdletBinding\(\)\]\s*param\(.*?\r?\n\)', '')
$prefix = [regex]::Replace($prefix, '(?m)^\s*\$AppDir\s*=.*$', '')
$prefix = [regex]::Replace($prefix, '(?m)^\s*if \(-not \$AppDir\).*$', '')
$prefix = "`$AppDir = '$appDir'`r`n" + $prefix
. ([scriptblock]::Create($prefix))
$ErrorActionPreference = 'Continue'

$tmp = Join-Path $StateDir 'proxy-guard-test.json'
$before = Read-ProxyRegistryState
$fail = 0

function Set-CurrentProxy {
    param([int]$Enable, [string]$Server)
    Set-ProxyRegistryValue -Name 'ProxyEnable' -Value $Enable -Type 'DWord'
    if ($Server) { Set-ProxyRegistryValue -Name 'ProxyServer' -Value $Server -Type 'String' }
    else { Remove-ProxyRegistryValue -Name 'ProxyServer' }
}

function Write-FakeBackup {
    # 故意在"当前代理 = 某个本地地址"时读取状态，这样备份里记录的"原设置"就是那个地址
    param([string]$Server)
    Set-CurrentProxy -Enable 1 -Server $Server
    $b = Read-ProxyRegistryState
    $b | Add-Member -NotePropertyName appliedProxyServer -NotePropertyValue $Server -Force
    $b | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tmp -Encoding UTF8
}

try {
    Write-Host '=== A) 备份指向我们自己的桥接端口 1081：不能还原那个死端口 ===' -ForegroundColor Cyan
    Write-FakeBackup -Server '127.0.0.1:1081'
    $r = Restore-SystemProxy -BackupPath $tmp
    $after = Read-ProxyRegistryState
    $okA = ($r -eq 'restored-disabled') -and ([int]$after.proxyEnable -eq 0) -and ([string]$after.proxyServer -ne '127.0.0.1:1081')
    Write-Host ("   结果={0}  现在 ProxyEnable={1} ProxyServer='{2}'  -> {3}" -f $r, $after.proxyEnable, $after.proxyServer, $(if ($okA) { 'OK' } else { 'FAIL' })) -ForegroundColor $(if ($okA) { 'Green' } else { 'Red' })
    if (-not $okA) { $fail++ }

    Write-Host '=== B) 备份指向别人的代理 6478：必须原样还原 ===' -ForegroundColor Cyan
    Write-FakeBackup -Server '127.0.0.1:6478'
    $r = Restore-SystemProxy -BackupPath $tmp
    $after = Read-ProxyRegistryState
    $okB = ($r -eq 'restored') -and ([int]$after.proxyEnable -eq 1) -and ([string]$after.proxyServer -eq '127.0.0.1:6478')
    Write-Host ("   结果={0}  现在 ProxyEnable={1} ProxyServer='{2}'  -> {3}" -f $r, $after.proxyEnable, $after.proxyServer, $(if ($okB) { 'OK' } else { 'FAIL' })) -ForegroundColor $(if ($okB) { 'Green' } else { 'Red' })
    if (-not $okB) { $fail++ }

    Write-Host '=== C) 启动前代理指向我们自己的端口：写出的备份里不能带它 ===' -ForegroundColor Cyan
    Set-CurrentProxy -Enable 1 -Server '127.0.0.1:1081'
    Set-SystemProxy -Port 1090 -BackupPath $tmp -SocksPort 1080
    $raw = Get-Content -LiteralPath $tmp -Raw -Encoding UTF8
    $now = Read-ProxyRegistryState
    $bad = $raw -match '127\.0\.0\.1:1081'
    $okC = (-not $bad) -and ([string]$now.proxyServer -eq '127.0.0.1:1090')
    Write-Host ("   备份里含有 1081 = {0}；当前代理 = '{1}'  -> {2}" -f $bad, $now.proxyServer, $(if ($okC) { 'OK' } else { 'FAIL' })) -ForegroundColor $(if ($okC) { 'Green' } else { 'Red' })
    if (-not $okC) { $fail++ }
}
catch {
    Write-Host "异常：$($_.Exception.Message)" -ForegroundColor Red
    $fail++
}
finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    Write-ProxyRegistryState -State $before
    $restored = Read-ProxyRegistryState
    Write-Host ("`n已还原测试前的系统代理：ProxyEnable={0} ProxyServer='{1}'" -f $restored.proxyEnable, $restored.proxyServer) -ForegroundColor DarkGray
}

if ($fail -gt 0) { Write-Host "自指防护测试失败（$fail 项）。" -ForegroundColor Red; exit 1 }
Write-Host '自指防护测试通过。' -ForegroundColor Green
exit 0
