# 看门狗自检：真的把隧道拉起来、真的杀掉 ssh、真的让看门狗自己重拨。
# 复用 HK-Tunnel.ps1 里的真实函数（不复制逻辑），只把 GUI 相关的两个函数替换成桩。
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$app = Join-Path (Split-Path -Parent $PSScriptRoot) 'HK-Tunnel.ps1'
$text = [System.IO.File]::ReadAllText($app, [System.Text.Encoding]::UTF8)

# GUI 段之前的部分：变量初始化 + 全部隧道/代理函数
$cut = $text.IndexOf('Add-Type -AssemblyName System.Windows.Forms')
if ($cut -lt 0) { throw '找不到 GUI 段起点。' }
$prefix = $text.Substring(0, $cut)

# 这段代码原本靠 $PSScriptRoot 定位自己；在字符串构造出来的 scriptblock 里它是空的，
# 所以把这两行换成显式路径。同时去掉脚本自己的 [CmdletBinding()]/param()——
# 它必须是 scriptblock 的第一条语句，而我们要在前面插一行赋值。
$appDir = Split-Path -Parent $PSScriptRoot
$prefix = [regex]::Replace($prefix, '(?s)\s*\[CmdletBinding\(\)\]\s*param\(.*?\r?\n\)\s*', '')
$prefix = [regex]::Replace($prefix, '(?m)^\s*\$AppDir\s*=.*$', '')
$prefix = [regex]::Replace($prefix, '(?m)^\s*if \(-not \$AppDir\).*$', '')
$prefix = "`$AppDir = '$appDir'`r`n" + $prefix

$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
$wdAst = $ast.FindAll({
    param($n)
    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-TunnelWatchdog'
}, $true)
if ($wdAst.Count -ne 1) { throw '找不到 Invoke-TunnelWatchdog 函数。' }
$watchdogText = $wdAst[0].Extent.Text

. ([scriptblock]::Create($prefix))
. ([scriptblock]::Create($watchdogText))
$ErrorActionPreference = 'Continue'

# 把两个 GUI 函数换成桩：看门狗只需要它们不报错
function Write-Log { param([string]$Message) Write-Host "    [程序日志] $Message" }
function Update-Ui { param($Config) }

$cfg = Load-Config
$pw  = Load-Secret
if (-not $cfg.host) { Write-Host '未配置服务器，跳过。' -ForegroundColor Yellow; exit 2 }
if ([string]::IsNullOrEmpty($pw)) { Write-Host '未保存密码，跳过。' -ForegroundColor Yellow; exit 2 }

$script:TunnelConfig      = $cfg
$script:TunnelPassword    = $pw
$script:WatchBusy         = $false
$script:ReconnectAttempts = 0
$script:MaxReconnects     = 20

$fail = $false
$pid1 = $null
try {
    Write-Host "[1/5] 启动隧道..." -ForegroundColor Cyan
    $pid1 = Start-Tunnel -Config $cfg -Password $pw
    Write-Host "      ssh PID = $pid1"
    if (-not $pid1) { throw '隧道没起来。' }

    Write-Host '[2/5] 启动 HTTP 桥接并接管系统代理...' -ForegroundColor Cyan
    $proxy = Start-ProxyStack -Config $cfg -TunnelPid $pid1
    $proxyServer = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings').ProxyServer
    Write-Host "      桥接 PID = $($proxy.pid)，系统代理 = $proxyServer"
    if ($proxyServer -ne "127.0.0.1:$($proxy.port)") { throw '系统代理没有接管成功。' }

    Write-Host '[3/5] 模拟链路中断：强杀 ssh 进程...' -ForegroundColor Cyan
    Stop-Process -Id $pid1 -Force -ErrorAction Stop
    Start-Sleep -Seconds 2
    if (Get-TunnelPid -Config $cfg) { throw 'ssh 应该已经死了但还在。' }
    Write-Host '      ssh 已消失（模拟"用着用着突然断了"）'

    Write-Host '[4/5] 触发看门狗...' -ForegroundColor Cyan
    Invoke-TunnelWatchdog
    Start-Sleep -Seconds 1

    $pid2 = Get-TunnelPid -Config $cfg
    if (-not $pid2 -or $pid2 -eq $pid1) { Write-Host "      自动重连失败（PID = $pid2）" -ForegroundColor Red; $fail = $true }
    else { Write-Host "      自动重连成功，ssh PID = $pid2" -ForegroundColor Green }

    $proxyServer2 = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings').ProxyServer
    $enable2 = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings').ProxyEnable
    if ($enable2 -eq 1 -and $proxyServer2 -match '^127\.0\.0\.1:\d+$') {
        Write-Host "      系统代理已重新接管 = $proxyServer2" -ForegroundColor Green
    }
    else { Write-Host "      系统代理没有恢复接管（ProxyEnable=$enable2 ProxyServer=$proxyServer2）" -ForegroundColor Red; $fail = $true }

    Write-Host '[5/5] 收尾：停止隧道并还原系统代理...' -ForegroundColor Cyan
}
catch {
    Write-Host "异常：$($_.Exception.Message)" -ForegroundColor Red
    $fail = $true
}
finally {
    try { [void](Stop-Tunnel -Config (Load-Config)) } catch { }
}

if ($fail) { Write-Host '看门狗自检失败。' -ForegroundColor Red; exit 1 }
Write-Host '看门狗自检通过：断线后自动重拨并重新接管系统代理。' -ForegroundColor Green
exit 0
