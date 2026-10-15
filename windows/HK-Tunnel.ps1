<#
    HK-Tunnel  ——  香港服务器 SSH SOCKS5 隧道管理器（密码版）

    特点：
      1. 密码在界面里输入，一键启动、一键停止，不弹命令行窗口。
      2. 本机只监听 SOCKS5 和 HTTP 桥接两个回环端口，连接服务器 22 端口是主动外连。
      3. 开启「自动接管系统代理」后，启动隧道自动设置 Windows 系统代理，退出时恢复原设置。
      4. 启动时自动清理上次遗留的隧道进程，避免异常退出后端口被占死。
      5. 零外部依赖，只用 Windows 自带的 OpenSSH 和 PowerShell 5.1+。
      6. 密码默认不落盘；勾选「记住密码」时才用 DPAPI 加密保存，只能本机本账户解密。

    用法：
      - 双击同目录的「启动隧道.cmd」，或桌面快捷方式
      - 自检：powershell -ExecutionPolicy Bypass -File HK-Tunnel.ps1 -SelfTest
      - 系统代理自检：powershell -ExecutionPolicy Bypass -File HK-Tunnel.ps1 -SystemProxySelfTest
      - 浏览器上不了网时急救：powershell -ExecutionPolicy Bypass -File HK-Tunnel.ps1 -ResetProxy
#>
[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$UiSmokeTest,
    [Switch]$SystemProxySelfTest,
    [switch]$LiveTunnelSelfTest,
    [switch]$ResetProxy
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Security

# ------------------------------------------------------------------ 路径

$AppDir     = $PSScriptRoot
if (-not $AppDir) { $AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path }

$StateDir   = Join-Path $env:LOCALAPPDATA 'HKTunnel'
$ConfigFile = Join-Path $StateDir 'config.json'
$SecretFile = Join-Path $StateDir 'secret.dat'
$StateFile  = Join-Path $StateDir 'running.json'
$ProxyStateFile = Join-Path $StateDir 'proxy-stack.json'
$ProxyBackupFile = Join-Path $StateDir 'proxy-backup.json'
$KnownHosts = Join-Path $StateDir 'known_hosts'
$ErrLog     = Join-Path $StateDir 'ssh.err.log'
$OutLog     = Join-Path $StateDir 'ssh.out.log'
$BridgeErrLog = Join-Path $StateDir 'bridge.err.log'
$BridgeOutLog = Join-Path $StateDir 'bridge.out.log'

$SshExe     = Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$AskPassExe = Join-Path $AppDir 'hk-askpass.exe'
$BridgeSource = Join-Path $AppDir 'HK-Bridge.cs'
$BridgeExe = Join-Path $AppDir 'hk-httpbridge.exe'
$BridgeHashFile = Join-Path $StateDir 'bridge.sha256'
$IconFile   = Join-Path $AppDir 'hk-tunnel.ico'

if (-not (Test-Path -LiteralPath $StateDir)) {
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
}

# -------------------------------------------------------- askpass 辅助程序

function Initialize-AskPass {
    if (Test-Path -LiteralPath $AskPassExe) { return $true }

    $code = @'
using System;
public static class AskPass
{
    public static int Main(string[] args)
    {
        string pw = Environment.GetEnvironmentVariable("HKTUNNEL_PW");
        Console.Out.WriteLine(pw == null ? string.Empty : pw);
        Console.Out.Flush();
        return 0;
    }
}
'@
    try {
        Add-Type -TypeDefinition $code -OutputAssembly $AskPassExe -OutputType ConsoleApplication
    }
    catch {
        return $false
    }
    return (Test-Path -LiteralPath $AskPassExe)
}

# ------------------------------------------------------------------ 配置

function Get-DefaultConfig {
    return [pscustomobject]@{
        host      = ''
        sshPort   = 22
        user      = 'root'
        socksPort = 1080
        remember  = $false
        autoProxy = $true
    }
}

function Load-Config {
    if (-not (Test-Path -LiteralPath $ConfigFile)) { return Get-DefaultConfig }
    try {
        $obj = (Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8) | ConvertFrom-Json
        $cfg = Get-DefaultConfig
        if ($obj.host)      { $cfg.host = [string]$obj.host }
        if ($obj.sshPort)   { $cfg.sshPort = [int]$obj.sshPort }
        if ($obj.user)      { $cfg.user = [string]$obj.user }
        if ($obj.socksPort) { $cfg.socksPort = [int]$obj.socksPort }
        if ($obj.PSObject.Properties.Name -contains 'remember') { $cfg.remember = [bool]$obj.remember }
        if ($obj.PSObject.Properties.Name -contains 'autoProxy') { $cfg.autoProxy = [bool]$obj.autoProxy }
        return $cfg
    }
    catch { return Get-DefaultConfig }
}

function Save-Config {
    param($Config)
    $Config | ConvertTo-Json | Set-Content -LiteralPath $ConfigFile -Encoding UTF8
}

function Save-Secret {
    param([string]$Plain)
    if ([string]::IsNullOrEmpty($Plain)) {
        if (Test-Path -LiteralPath $SecretFile) {
            Remove-Item -LiteralPath $SecretFile -Force -ErrorAction SilentlyContinue
        }
        return
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Plain)
    $enc = [System.Security.Cryptography.ProtectedData]::Protect(
        $bytes, $null,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    [System.IO.File]::WriteAllBytes($SecretFile, $enc)
}

function Load-Secret {
    if (-not (Test-Path -LiteralPath $SecretFile)) { return '' }
    try {
        $enc = [System.IO.File]::ReadAllBytes($SecretFile)
        $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $enc, $null,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        return [System.Text.Encoding]::UTF8.GetString($bytes)
    }
    catch { return '' }
}

function Save-RunState {
    param([int]$ProcessId, [string]$Signature)
    [pscustomobject]@{
        pid       = $ProcessId
        signature = $Signature
        startedAt = (Get-Date).ToString('s')
    } | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8
}

function Clear-RunState {
    if (Test-Path -LiteralPath $StateFile) {
        Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue
    }
}

# ------------------------------------------------------ 系统代理与 HTTP 桥接

$ProxyRegPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'

function Initialize-WinInetApi {
    $existing = 'HKTunnel.WinInet' -as [type]
    if ($existing) { return }

    $code = @'
using System;
using System.Runtime.InteropServices;

namespace HKTunnel
{
    public static class WinInet
    {
        [DllImport("wininet.dll", SetLastError = true)]
        private static extern bool InternetSetOption(IntPtr hInternet, int option, IntPtr buffer, int length);

        [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        private static extern IntPtr SendMessageTimeout(
            IntPtr hWnd, uint msg, IntPtr wParam, string lParam,
            uint flags, uint timeout, out IntPtr result);

        public static void Refresh()
        {
            InternetSetOption(IntPtr.Zero, 39, IntPtr.Zero, 0);
            InternetSetOption(IntPtr.Zero, 37, IntPtr.Zero, 0);
            IntPtr result;
            SendMessageTimeout(
                new IntPtr(0xffff), 0x001A, IntPtr.Zero,
                "Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings",
                0x0002, 5000, out result);
        }
    }
}
'@
    Add-Type -TypeDefinition $code
}

function Invoke-WinInetRefresh {
    try {
        Initialize-WinInetApi
        [HKTunnel.WinInet]::Refresh()
    }
    catch { }
}

function Read-ProxyRegistryState {
    $item = Get-ItemProperty -Path $ProxyRegPath -ErrorAction SilentlyContinue
    $names = @()
    if ($item) { $names = @($item.PSObject.Properties.Name) }

    $hasProxyEnable = $names -contains 'ProxyEnable'
    $hasProxyServer = $names -contains 'ProxyServer'
    $hasProxyOverride = $names -contains 'ProxyOverride'
    $hasAutoConfigUrl = $names -contains 'AutoConfigURL'
    $hasAutoDetect = $names -contains 'AutoDetect'

    return [pscustomobject]@{
        keyExists          = [bool]$item
        proxyEnableExists  = $hasProxyEnable
        proxyEnable        = if ($hasProxyEnable) { [int]$item.ProxyEnable } else { 0 }
        proxyServerExists  = $hasProxyServer
        proxyServer        = if ($hasProxyServer) { [string]$item.ProxyServer } else { '' }
        proxyOverrideExists = $hasProxyOverride
        proxyOverride      = if ($hasProxyOverride) { [string]$item.ProxyOverride } else { '' }
        autoConfigUrlExists = $hasAutoConfigUrl
        autoConfigUrl      = if ($hasAutoConfigUrl) { [string]$item.AutoConfigURL } else { '' }
        autoDetectExists   = $hasAutoDetect
        autoDetect         = if ($hasAutoDetect) { [int]$item.AutoDetect } else { 0 }
    }
}

function Set-ProxyRegistryValue {
    param(
        [string]$Name,
        [object]$Value,
        [string]$Type
    )
    New-ItemProperty -Path $ProxyRegPath -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

function Remove-ProxyRegistryValue {
    param([string]$Name)
    Remove-ItemProperty -Path $ProxyRegPath -Name $Name -Force -ErrorAction SilentlyContinue
}

function Write-ProxyRegistryState {
    param($State)
    if (-not $State) { return }

    if (-not (Test-Path -LiteralPath $ProxyRegPath)) {
        New-Item -Path $ProxyRegPath -Force | Out-Null
    }

    if ($State.proxyEnableExists) {
        Set-ProxyRegistryValue -Name 'ProxyEnable' -Value ([int]$State.proxyEnable) -Type 'DWord'
    }
    else {
        Remove-ProxyRegistryValue -Name 'ProxyEnable'
    }

    if ($State.proxyServerExists) {
        Set-ProxyRegistryValue -Name 'ProxyServer' -Value ([string]$State.proxyServer) -Type 'String'
    }
    else {
        Remove-ProxyRegistryValue -Name 'ProxyServer'
    }

    if ($State.proxyOverrideExists) {
        Set-ProxyRegistryValue -Name 'ProxyOverride' -Value ([string]$State.proxyOverride) -Type 'String'
    }
    else {
        Remove-ProxyRegistryValue -Name 'ProxyOverride'
    }

    if ($State.autoConfigUrlExists) {
        Set-ProxyRegistryValue -Name 'AutoConfigURL' -Value ([string]$State.autoConfigUrl) -Type 'String'
    }
    else {
        Remove-ProxyRegistryValue -Name 'AutoConfigURL'
    }

    if ($State.autoDetectExists) {
        Set-ProxyRegistryValue -Name 'AutoDetect' -Value ([int]$State.autoDetect) -Type 'DWord'
    }
    else {
        Remove-ProxyRegistryValue -Name 'AutoDetect'
    }

    Invoke-WinInetRefresh
}

function Get-ProxyOverrideWithLocalBypass {
    param([string]$Existing)

    $items = New-Object System.Collections.Generic.List[string]
    if ($Existing) {
        foreach ($part in ($Existing -split ';')) {
            $value = $part.Trim()
            if ($value -and -not $items.Contains($value)) { [void]$items.Add($value) }
        }
    }

    foreach ($required in @('<local>', 'localhost', '127.*')) {
        if (-not $items.Contains($required)) { [void]$items.Add($required) }
    }
    return ($items -join ';')
}

function Test-ProxyIsManaged {
    param([string]$AppliedProxyServer)
    if (-not $AppliedProxyServer) { return $false }

    $current = Read-ProxyRegistryState
    return ([bool]$current.proxyEnable -and [string]$current.proxyServer -eq $AppliedProxyServer)
}

function Restore-SystemProxy {
    param([string]$BackupPath = $ProxyBackupFile)

    if (-not (Test-Path -LiteralPath $BackupPath)) { return 'no-backup' }

    try {
        $backup = (Get-Content -LiteralPath $BackupPath -Raw -Encoding UTF8) | ConvertFrom-Json
    }
    catch {
        # Nothing usable to restore from; no point retrying a broken file.
        Remove-Item -LiteralPath $BackupPath -Force -ErrorAction SilentlyContinue
        return 'unreadable'
    }

    if (-not (Test-ProxyIsManaged -AppliedProxyServer ([string]$backup.appliedProxyServer))) {
        Remove-Item -LiteralPath $BackupPath -Force -ErrorAction SilentlyContinue
        return 'skipped-changed'
    }

    try {
        Write-ProxyRegistryState -State $backup
        Remove-Item -LiteralPath $BackupPath -Force -ErrorAction SilentlyContinue
        return 'restored'
    }
    catch {
        # Keep the backup. If the write failed we want the next run to retry,
        # because dropping it here would strand the machine on a proxy that is
        # no longer listening.
        return 'failed'
    }
}

function Set-SystemProxy {
    param(
        [int]$Port,
        [string]$BackupPath = $ProxyBackupFile
    )

    $backup = Read-ProxyRegistryState
    $backup | Add-Member -NotePropertyName appliedProxyServer -NotePropertyValue "127.0.0.1:$Port" -Force
    $backup | Add-Member -NotePropertyName appliedAt -NotePropertyValue (Get-Date).ToString('s') -Force
    $backup | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $BackupPath -Encoding UTF8

    Set-ProxyRegistryValue -Name 'AutoConfigURL' -Value '' -Type 'String'
    Remove-ProxyRegistryValue -Name 'AutoConfigURL'
    Set-ProxyRegistryValue -Name 'AutoDetect' -Value 0 -Type 'DWord'
    Set-ProxyRegistryValue -Name 'ProxyEnable' -Value 1 -Type 'DWord'
    Set-ProxyRegistryValue -Name 'ProxyServer' -Value "127.0.0.1:$Port" -Type 'String'
    Set-ProxyRegistryValue -Name 'ProxyOverride' -Value (Get-ProxyOverrideWithLocalBypass -Existing ([string]$backup.proxyOverride)) -Type 'String'
    Invoke-WinInetRefresh
}

function Initialize-Bridge {
    if (-not (Test-Path -LiteralPath $BridgeSource)) {
        throw "找不到 HTTP 桥接源码：$BridgeSource"
    }

    $sourceHash = (Get-FileHash -LiteralPath $BridgeSource -Algorithm SHA256).Hash
    $savedHash = ''
    if (Test-Path -LiteralPath $BridgeHashFile) {
        $savedHash = (Get-Content -LiteralPath $BridgeHashFile -Raw -Encoding ASCII).Trim()
    }

    if ((Test-Path -LiteralPath $BridgeExe) -and $savedHash -eq $sourceHash) {
        return $true
    }

    [void](Stop-BridgeProcesses)
    if (Test-Path -LiteralPath $BridgeExe) {
        Remove-Item -LiteralPath $BridgeExe -Force -ErrorAction SilentlyContinue
    }

    try {
        Add-Type -Path $BridgeSource -OutputAssembly $BridgeExe -OutputType ConsoleApplication
        $sourceHash | Set-Content -LiteralPath $BridgeHashFile -Encoding ASCII
        return (Test-Path -LiteralPath $BridgeExe)
    }
    catch {
        throw "HTTP 桥接编译失败：$($_.Exception.Message)"
    }
}

function Get-ProxyStackState {
    if (-not (Test-Path -LiteralPath $ProxyStateFile)) { return $null }
    try {
        return ((Get-Content -LiteralPath $ProxyStateFile -Raw -Encoding UTF8) | ConvertFrom-Json)
    }
    catch { return $null }
}

function Save-ProxyStackState {
    param([int]$BridgePid, [int]$HttpPort, [int]$TunnelPid, [int]$SocksPort)
    [pscustomobject]@{
        bridgePid = $BridgePid
        httpPort  = $HttpPort
        tunnelPid = $TunnelPid
        socksPort = $SocksPort
        startedAt = (Get-Date).ToString('s')
    } | ConvertTo-Json | Set-Content -LiteralPath $ProxyStateFile -Encoding UTF8
}

function Clear-ProxyStackState {
    foreach ($path in @($ProxyStateFile, $ProxyBackupFile)) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-BridgeProcesses {
    $found = @()
    $seen = New-Object System.Collections.Generic.HashSet[int]
    $state = Get-ProxyStackState

    if ($state -and $state.bridgePid) {
        $proc = Get-Process -Id ([int]$state.bridgePid) -ErrorAction SilentlyContinue
        if ($proc -and $proc.ProcessName -eq 'hk-httpbridge') {
            [void]$seen.Add($proc.Id)
            $found += $proc
        }
    }

    try {
        $expected = [System.IO.Path]::GetFullPath($BridgeExe)
        foreach ($p in (Get-CimInstance Win32_Process -Filter "Name='hk-httpbridge.exe'" -ErrorAction SilentlyContinue)) {
            if ($seen.Contains([int]$p.ProcessId)) { continue }
            $path = [string]$p.ExecutablePath
            if ($path -and ([System.IO.Path]::GetFullPath($path) -ieq $expected)) {
                $proc = Get-Process -Id ([int]$p.ProcessId) -ErrorAction SilentlyContinue
                if ($proc) {
                    [void]$seen.Add($proc.Id)
                    $found += $proc
                }
            }
        }
    }
    catch { }

    return @($found)
}

function Stop-BridgeProcesses {
    $killed = @()
    foreach ($proc in (Get-BridgeProcesses)) {
        $id = [int]$proc.Id
        Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
        $killed += $id
    }
    return @($killed)
}

function Start-HttpBridge {
    param([int]$SocksPort, [int]$ListenPort = 0)

    [void](Initialize-Bridge)

    $selectedPort = 0
    if ($ListenPort -gt 0) {
        if ($ListenPort -eq $SocksPort) {
            throw 'HTTP 桥接端口不能与 SOCKS 端口相同。'
        }
        if (-not (Test-PortFree -Port $ListenPort)) {
            throw "HTTP 桥接端口 $ListenPort 已被占用。"
        }
        $selectedPort = $ListenPort
    }
    else {
        for ($port = 1081; $port -le 1101; $port++) {
            if ($port -eq $SocksPort) { continue }
            if (Test-PortFree -Port $port) {
                $selectedPort = $port
                break
            }
        }
    }
    if ($selectedPort -eq 0) {
        throw '找不到可用的本地 HTTP 桥接端口（已尝试 1081 到 1101）。'
    }

    foreach ($path in @($BridgeErrLog, $BridgeOutLog)) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }

    $arguments = "--listen $selectedPort --socks $SocksPort --owner-pid $PID"
    $proc = Start-Process -FilePath $BridgeExe `
        -ArgumentList $arguments `
        -WindowStyle Hidden `
        -PassThru `
        -RedirectStandardError $BridgeErrLog `
        -RedirectStandardOutput $BridgeOutLog

    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 200
        if (-not (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue)) {
            $detail = (Read-LogText -Path $BridgeErrLog) -replace "`r?`n", ' '
            if (-not $detail) { $detail = 'HTTP 桥接进程启动后立即退出。' }
            throw $detail
        }
        if (Get-PortListeners -Port $selectedPort) {
            return [pscustomobject]@{ pid = $proc.Id; port = $selectedPort }
        }
    }

    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    throw 'HTTP 桥接启动超时。'
}

function Start-ProxyStack {
    param($Config, [int]$TunnelPid)
    if (-not $Config.autoProxy) { return $null }

    [void](Stop-ProxyStack)
    $bridge = $null
    try {
        $bridge = Start-HttpBridge -SocksPort ([int]$Config.socksPort)
        Save-ProxyStackState -BridgePid $bridge.pid -HttpPort $bridge.port -TunnelPid $TunnelPid -SocksPort ([int]$Config.socksPort)
        Set-SystemProxy -Port $bridge.port
        return [pscustomobject]@{ pid = $bridge.pid; port = $bridge.port }
    }
    catch {
        if ($bridge) {
            Stop-Process -Id $bridge.pid -Force -ErrorAction SilentlyContinue
        }
        [void](Restore-SystemProxy)
        Clear-ProxyStackState
        throw
    }
}

function Stop-ProxyStack {
    $state = Get-ProxyStackState
    $restored = Restore-SystemProxy
    $killed = @(Stop-BridgeProcesses)
    if (Test-Path -LiteralPath $ProxyStateFile) {
        Remove-Item -LiteralPath $ProxyStateFile -Force -ErrorAction SilentlyContinue
    }

    return [pscustomobject]@{
        restored = $restored
        killed   = $killed
        state    = $state
    }
}

# Manual escape hatch: recovers a machine whose system proxy is still pointed at
# a bridge that is no longer running, which shows up as "the browser has no
# internet". Works even when the backup file has already been lost.
function Invoke-ProxyRecovery {
    Write-Host '=== 恢复 Windows 系统代理 ===' -ForegroundColor Cyan

    $before = Read-ProxyRegistryState
    Write-Host ("当前      : ProxyEnable={0}  ProxyServer='{1}'" -f $before.proxyEnable, $before.proxyServer)

    $killed = @(Stop-BridgeProcesses)
    if ($killed.Count -gt 0) { Write-Host "遗留桥接进程: 已结束 $($killed -join ', ')" }
    if (Test-Path -LiteralPath $ProxyStateFile) {
        Remove-Item -LiteralPath $ProxyStateFile -Force -ErrorAction SilentlyContinue
    }

    if (Test-Path -LiteralPath $ProxyBackupFile) {
        Write-Host "启动前备份  : 找到,开始还原"
        Write-Host "还原结果    : $(Restore-SystemProxy)"
    }
    elseif ($before.proxyEnable -eq 1) {
        Set-ProxyRegistryValue -Name 'ProxyEnable' -Value 0 -Type 'DWord'
        Remove-ProxyRegistryValue -Name 'ProxyServer'
        Invoke-WinInetRefresh
        Write-Host '启动前备份  : 没有(可能已被删除)' -ForegroundColor Yellow
        Write-Host '处理方式    : 直接关闭系统代理' -ForegroundColor Yellow
    }
    else {
        Write-Host '启动前备份  : 没有'
        Write-Host '系统代理本来就是关闭的,无需处理。'
    }

    $after = Read-ProxyRegistryState
    Write-Host ("恢复后    : ProxyEnable={0}  ProxyServer='{1}'" -f $after.proxyEnable, $after.proxyServer)
    if ($after.proxyEnable -eq 1 -and $after.proxyServer) {
        Write-Host '注意:系统代理仍处于开启状态。' -ForegroundColor Yellow
    }
    else {
        Write-Host '完成。浏览器现在应该可以正常上网了。' -ForegroundColor Green
    }
}

# -------------------------------------------------------- 进程与端口工具

function Get-SshProcesses {
    try {
        return @(Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" -ErrorAction SilentlyContinue)
    }
    catch { return @() }
}

function Convert-SshEscapes {
    # ssh 会把非 ASCII 字节转义成八进制，这里还原回字节再按系统代码页解码
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    if ($Text -notmatch '\\[0-7]{3}') { return $Text }

    $cp  = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage
    $enc = [System.Text.Encoding]::GetEncoding($cp)
    $sb     = New-Object System.Text.StringBuilder
    $buffer = New-Object System.Collections.Generic.List[byte]
    $i = 0

    while ($i -lt $Text.Length) {
        $ch = $Text[$i]
        if ($ch -eq '\' -and ($i + 3) -lt $Text.Length) {
            $oct = $Text.Substring($i + 1, 3)
            if ($oct -match '^[0-7]{3}$') {
                $buffer.Add([Convert]::ToByte($oct, 8))
                $i += 4
                continue
            }
        }
        if ($buffer.Count -gt 0) {
            [void]$sb.Append($enc.GetString($buffer.ToArray()))
            $buffer.Clear()
        }
        [void]$sb.Append($ch)
        $i++
    }
    if ($buffer.Count -gt 0) { [void]$sb.Append($enc.GetString($buffer.ToArray())) }
    return $sb.ToString()
}

function Read-LogText {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        if ($bytes.Length -eq 0) { return '' }
        $cp = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage
        $raw = [System.Text.Encoding]::GetEncoding($cp).GetString($bytes).Trim()
        return (Convert-SshEscapes -Text $raw).Trim()
    }
    catch {
        return ((Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue) + '').Trim()
    }
}

function Find-TunnelProcesses {
    param([string]$HostName, [string]$UserName, [int]$SocksPort)
    if (-not $HostName -or -not $UserName) { return @() }

    $portMarker = "-D 127.0.0.1:$SocksPort"
    $userHost   = "$UserName@$HostName"

    $found = @()
    foreach ($p in (Get-SshProcesses)) {
        $cl = $p.CommandLine
        if (-not $cl) { continue }
        if ($cl.Contains($portMarker) -and $cl.Contains($userHost)) {
            $found += $p
        }
    }
    return $found
}

function Get-TunnelPid {
    param($Config)

    # 先看状态文件里记录的 PID，避免刚启动时 WMI 枚举有延迟
    if (Test-Path -LiteralPath $StateFile) {
        try {
            $st = (Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8) | ConvertFrom-Json
            if ($st.pid) {
                $proc = Get-Process -Id ([int]$st.pid) -ErrorAction SilentlyContinue
                if ($proc -and $proc.ProcessName -eq 'ssh') { return $proc.Id }
            }
        }
        catch { }
        Clear-RunState
    }

    $procs = @(Find-TunnelProcesses -HostName $Config.host -UserName $Config.user -SocksPort $Config.socksPort)
    if ($procs.Count -gt 0) { return $procs[0].ProcessId }
    return $null
}

function Stop-TunnelProcesses {
    param([string]$HostName, [string]$UserName, [int]$SocksPort)

    $killed = @()

    if (Test-Path -LiteralPath $StateFile) {
        try {
            $st = (Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8) | ConvertFrom-Json
            if ($st.pid) {
                $proc = Get-Process -Id ([int]$st.pid) -ErrorAction SilentlyContinue
                if ($proc -and $proc.ProcessName -eq 'ssh') {
                    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                    $killed += $proc.Id
                }
            }
        }
        catch { }
        Clear-RunState
    }

    foreach ($p in (Find-TunnelProcesses -HostName $HostName -UserName $UserName -SocksPort $SocksPort)) {
        if ($killed -notcontains $p.ProcessId) {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
            $killed += $p.ProcessId
        }
    }
    return $killed
}

function Test-PortFree {
    param([int]$Port)
    $conn = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
    return (-not $conn)
}

function Get-PortListeners {
    param([int]$Port)
    return @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
}

# ---------------------------------------------------------------- 隧道动作

function Get-TunnelCommandLine {
    param($Config)
    $parts = @(
        '-N', '-C',
        '-D', "127.0.0.1:$($Config.socksPort)",
        '-o', 'ExitOnForwardFailure=yes',
        '-o', 'ConnectTimeout=15',
        '-o', 'ServerAliveInterval=30',
        '-o', 'ServerAliveCountMax=3',
        '-o', 'PreferredAuthentications=password,keyboard-interactive',
        '-o', 'NumberOfPasswordPrompts=1',
        '-o', 'StrictHostKeyChecking=accept-new',
        '-o', "UserKnownHostsFile=`"$KnownHosts`"",
        '-p', "$($Config.sshPort)",
        "$($Config.user)@$($Config.host)"
    )
    return ($parts -join ' ')
}

function Start-Tunnel {
    param($Config, [string]$Password)

    if (-not $Config.host) { throw '请先填写服务器地址。' }
    if (-not (Test-Path -LiteralPath $SshExe)) { throw "找不到 ssh.exe：$SshExe" }
    if ([string]::IsNullOrEmpty($Password)) { throw '请先填写登录密码。' }
    if (-not (Initialize-AskPass)) {
        throw "无法生成密码辅助程序 $AskPassExe，请确认程序目录可写。"
    }

    [void](Stop-ProxyStack)
    [void](Stop-TunnelProcesses -HostName $Config.host -UserName $Config.user -SocksPort $Config.socksPort)

    if (-not (Test-PortFree -Port $Config.socksPort)) {
        $who = Get-PortListeners -Port $Config.socksPort | Select-Object -First 1
        $ownerPid = if ($who) { $who.OwningProcess } else { '未知' }
        throw "本地端口 $($Config.socksPort) 已被其它程序占用（PID $ownerPid），请换一个 SOCKS 端口。"
    }

    foreach ($f in @($ErrLog, $OutLog)) {
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    }

    # 密码通过子进程环境变量传给 askpass 辅助程序，命令行里不留任何凭据
    $env:SSH_ASKPASS         = $AskPassExe
    $env:SSH_ASKPASS_REQUIRE = 'force'
    $env:HKTUNNEL_PW         = $Password

    $argLine = Get-TunnelCommandLine -Config $Config
    $proc = $null
    try {
        $proc = Start-Process -FilePath $SshExe `
            -ArgumentList $argLine `
            -WindowStyle Hidden `
            -PassThru `
            -RedirectStandardError $ErrLog `
            -RedirectStandardOutput $OutLog
    }
    finally {
        Remove-Item Env:SSH_ASKPASS         -ErrorAction SilentlyContinue
        Remove-Item Env:SSH_ASKPASS_REQUIRE -ErrorAction SilentlyContinue
        Remove-Item Env:HKTUNNEL_PW         -ErrorAction SilentlyContinue
    }

    Save-RunState -ProcessId $proc.Id -Signature $argLine

    # 轮询等待端口就绪，ssh 建立连接需要时间
    $deadline  = (Get-Date).AddSeconds(30)
    $listening = $false
    $procDied  = $false

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        if ($script:UiRunning) { [System.Windows.Forms.Application]::DoEvents() }

        if (-not (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue)) {
            $procDied = $true
            break
        }
        if (Get-PortListeners -Port $Config.socksPort) {
            $listening = $true
            break
        }
    }

    if ($listening) { return $proc.Id }

    $detail = (Read-LogText -Path $ErrLog) -replace "`r?`n", ' '
    if (-not $procDied) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    Clear-RunState

    if ($detail) { throw "隧道启动失败：$detail" }
    if ($procDied) { throw 'ssh 进程启动后立刻退出，但没有输出错误信息。请确认密码正确。' }
    throw '连接服务器超时。请检查服务器地址、SSH 端口和防火墙是否放行 22 端口。'
}

function Stop-Tunnel {
    param($Config)
    $proxy = Stop-ProxyStack
    $killed = @(Stop-TunnelProcesses -HostName $Config.host -UserName $Config.user -SocksPort $Config.socksPort)
    return [pscustomobject]@{
        killed = $killed
        proxy  = $proxy
    }
}

# ------------------------------------------------------------------ 自检

function Invoke-SelfTest {
    $ok = $true
    Write-Host '=== HK-Tunnel 自检 ===' -ForegroundColor Cyan

    Write-Host ("ssh.exe        : {0}  {1}" -f $SshExe, (Test-Path -LiteralPath $SshExe))
    if (-not (Test-Path -LiteralPath $SshExe)) { $ok = $false }

    Write-Host ("askpass 辅助   : {0}  {1}" -f $AskPassExe, (Initialize-AskPass))
    if (-not (Test-Path -LiteralPath $AskPassExe)) { $ok = $false }

    Write-Host ("状态目录       : {0}" -f $StateDir)
    try {
        $probe = Join-Path $StateDir '.write-probe'
        'ok' | Set-Content -LiteralPath $probe -Encoding ASCII
        Remove-Item -LiteralPath $probe -Force
        Write-Host '  可写         : True'
    }
    catch {
        Write-Host '  可写         : False' -ForegroundColor Red
        $ok = $false
    }

    # DPAPI 加解密往返，并确认不污染已有凭据
    try {
        $sample = 'dpapi-roundtrip-probe'
        $enc = [System.Security.Cryptography.ProtectedData]::Protect(
            [System.Text.Encoding]::UTF8.GetBytes($sample), $null,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        $dec = [System.Text.Encoding]::UTF8.GetString(
            [System.Security.Cryptography.ProtectedData]::Unprotect(
                $enc, $null,
                [System.Security.Cryptography.DataProtectionScope]::CurrentUser))
        $dpapiOk = ($dec -eq $sample)
        Write-Host ("DPAPI 加解密   : {0}" -f $dpapiOk)
        if (-not $dpapiOk) { $ok = $false }
    }
    catch {
        Write-Host ("DPAPI 加解密   : False  {0}" -f $_.Exception.Message) -ForegroundColor Red
        $ok = $false
    }

    $procs = @(Get-SshProcesses)
    Write-Host ("当前 ssh 进程数 : {0}" -f $procs.Count)

    # 进程匹配测试：起一个连不通的目标，验证能精确识别且不误伤别的会话
    $testHost = '192.0.2.1'
    $testUser = 'selftest'
    $testPort = 18080
    $fakeArgs = "-N -o ConnectTimeout=15 -D 127.0.0.1:$testPort $testUser@$testHost"
    $fake = $null
    try {
        $fake = Start-Process -FilePath $SshExe -ArgumentList $fakeArgs -WindowStyle Hidden -PassThru
        Start-Sleep -Milliseconds 1200

        $hit = Find-TunnelProcesses -HostName $testHost -UserName $testUser -SocksPort $testPort
        $matched = @($hit | Where-Object { $_.ProcessId -eq $fake.Id }).Count -gt 0
        Write-Host ("  进程精确匹配 : {0}" -f $matched)
        if (-not $matched) { $ok = $false }

        $miss = Find-TunnelProcesses -HostName 'other.invalid' -UserName $testUser -SocksPort $testPort
        $clean = ($miss.Count -eq 0)
        Write-Host ("  无误伤其它会话 : {0}" -f $clean)
        if (-not $clean) { $ok = $false }
    }
    catch {
        Write-Host ("  进程匹配测试异常 : {0}" -f $_.Exception.Message) -ForegroundColor Red
        $ok = $false
    }
    finally {
        if ($fake) { Stop-Process -Id $fake.Id -Force -ErrorAction SilentlyContinue }
    }

    $sample  = 'ssh: could not resolve hostname x: \262\273\326\252\265\300\325\342\321\371\265\304\326\367\273\372\241\243'
    $decoded = Convert-SshEscapes -Text $sample
    $escOk   = ($decoded -notmatch '\\[0-7]{3}') -and ($decoded -match '不知道这样的主机')
    Write-Host ("  报错转义还原 : {0}" -f $escOk)
    Write-Host ("    样例      : {0}" -f $decoded)
    if (-not $escOk) { $ok = $false }

    Write-Host ("端口 1080 空闲 : {0}" -f (Test-PortFree -Port 1080))
    Write-Host ''

    if ($ok) { Write-Host '自检通过。' -ForegroundColor Green }
    else     { Write-Host '自检发现问题，请看上面的 False 项。' -ForegroundColor Red }
    return $ok
}

function Invoke-SystemProxySelfTest {
    $ok = $true
    Write-Host '=== HK-Tunnel 系统代理与 HTTP 桥接自检 ===' -ForegroundColor Cyan

    function Test-Report {
        param([string]$Name, [bool]$Passed, [string]$Detail = '')
        $suffix = if ($Detail) { "  $Detail" } else { '' }
        if ($Passed) {
            Write-Host ("{0,-26}: True{1}" -f $Name, $suffix) -ForegroundColor Green
        }
        else {
            Write-Host ("{0,-26}: False{1}" -f $Name, $suffix) -ForegroundColor Red
        }
        return $Passed
    }

    try {
        [void](Initialize-Bridge)
        if (-not (Test-Report 'HTTP 桥接编译' (Test-Path -LiteralPath $BridgeExe))) { $ok = $false }
    }
    catch {
        if (-not (Test-Report 'HTTP 桥接编译' $false $_.Exception.Message)) { $ok = $false }
    }

    $testSocksPort = 18080
    while (-not (Test-PortFree -Port $testSocksPort)) { $testSocksPort++ }
    $testBridgePort = $testSocksPort + 1
    while (-not (Test-PortFree -Port $testBridgePort)) { $testBridgePort++ }

    $job = $null
    $bridge = $null
    $beforeProxy = $null
    $testBackup = Join-Path $StateDir 'proxy-selftest-backup.json'

    try {
        $job = Start-Job -ArgumentList $testSocksPort -ScriptBlock {
            param([int]$Port)

            function Read-ExactBytes {
                param($Stream, [int]$Count)
                $data = New-Object byte[] $Count
                $offset = 0
                while ($offset -lt $Count) {
                    $read = $Stream.Read($data, $offset, $Count - $offset)
                    if ($read -le 0) { throw 'Unexpected end of stream.' }
                    $offset += $read
                }
                return ,$data
            }

            $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
            $listener.Start()
            try {
                $client = $listener.AcceptTcpClient()
                try {
                    $stream = $client.GetStream()

                    $greeting = Read-ExactBytes $stream 3
                    if ($greeting[0] -ne 5 -or $greeting[1] -lt 1) { throw 'Invalid SOCKS greeting.' }
                    $helloReply = [byte[]](5, 0)
                    $stream.Write($helloReply, 0, $helloReply.Length)
                    $stream.Flush()

                    $requestHead = Read-ExactBytes $stream 4
                    if ($requestHead[0] -ne 5 -or $requestHead[1] -ne 1) { throw 'Invalid SOCKS request.' }
                    switch ([int]$requestHead[3]) {
                        1 { [void](Read-ExactBytes $stream 6) }
                        3 {
                            $length = [int](Read-ExactBytes $stream 1)[0]
                            [void](Read-ExactBytes $stream ($length + 2))
                        }
                        4 { [void](Read-ExactBytes $stream 18) }
                        default { throw 'Invalid SOCKS address type.' }
                    }

                    $connectReply = [byte[]](5, 0, 0, 1, 0, 0, 0, 0, 0, 0)
                    $stream.Write($connectReply, 0, $connectReply.Length)
                    $stream.Flush()

                    $headerStream = New-Object System.IO.MemoryStream
                    $buffer = New-Object byte[] 4096
                    while ($true) {
                        $read = $stream.Read($buffer, 0, $buffer.Length)
                        if ($read -le 0) { throw 'HTTP request ended early.' }
                        $headerStream.Write($buffer, 0, $read)
                        $text = [System.Text.Encoding]::ASCII.GetString($headerStream.ToArray())
                        if ($text.Contains("`r`n`r`n")) { break }
                    }

                    $body = 'PROXIED'
                    $response = "HTTP/1.1 200 OK`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n$body"
                    $responseBytes = [System.Text.Encoding]::ASCII.GetBytes($response)
                    $stream.Write($responseBytes, 0, $responseBytes.Length)
                    $stream.Flush()
                }
                finally {
                    if ($client) { $client.Close() }
                }
            }
            finally {
                $listener.Stop()
            }
        }

        $jobDeadline = (Get-Date).AddSeconds(10)
        while ((Get-Date) -lt $jobDeadline -and -not (Get-PortListeners -Port $testSocksPort)) {
            Start-Sleep -Milliseconds 200
        }
        if (-not (Test-PortFree -Port $testSocksPort)) {
            if (-not (Test-Report '测试 SOCKS 服务' $true)) { $ok = $false }
        }
        else {
            if (-not (Test-Report '测试 SOCKS 服务' $false '监听启动超时')) { $ok = $false }
            throw 'Test SOCKS server did not start.'
        }

        $bridge = Start-HttpBridge -SocksPort $testSocksPort -ListenPort $testBridgePort
        $bridgeStarted = [bool]($bridge -and (Get-PortListeners -Port $testBridgePort))
        if (-not (Test-Report 'HTTP 桥接监听' $bridgeStarted)) { $ok = $false }

        $client = New-Object System.Net.Sockets.TcpClient
        $client.ReceiveTimeout = 10000
        $client.SendTimeout = 10000
        $client.Connect([System.Net.IPAddress]::Loopback, $testBridgePort)
        try {
            $request = "GET http://example.test/ HTTP/1.1`r`nHost: example.test`r`nConnection: close`r`n`r`n"
            $requestBytes = [System.Text.Encoding]::ASCII.GetBytes($request)
            $stream = $client.GetStream()
            $stream.Write($requestBytes, 0, $requestBytes.Length)
            $stream.Flush()

            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::ASCII)
            $response = $reader.ReadToEnd()
            $proxyPathOk = ($response -match '200 OK') -and ($response -match 'PROXIED')
            if (-not (Test-Report 'HTTP 经 SOCKS 转发' $proxyPathOk)) { $ok = $false }
        }
        finally {
            $client.Close()
        }

        $beforeProxy = Read-ProxyRegistryState
        Set-SystemProxy -Port 18999 -BackupPath $testBackup
        $appliedProxy = Read-ProxyRegistryState
        $applyOk = ([int]$appliedProxy.proxyEnable -eq 1) -and ([string]$appliedProxy.proxyServer -eq '127.0.0.1:18999')
        if (-not (Test-Report '系统代理自动设置' $applyOk)) { $ok = $false }

        $restoreResult = Restore-SystemProxy -BackupPath $testBackup
        $afterProxy = Read-ProxyRegistryState
        $restoreOk =
            ($restoreResult -eq 'restored') -and
            ($beforeProxy.proxyEnableExists -eq $afterProxy.proxyEnableExists) -and
            ($beforeProxy.proxyEnable -eq $afterProxy.proxyEnable) -and
            ($beforeProxy.proxyServerExists -eq $afterProxy.proxyServerExists) -and
            ([string]$beforeProxy.proxyServer -eq [string]$afterProxy.proxyServer) -and
            ($beforeProxy.proxyOverrideExists -eq $afterProxy.proxyOverrideExists) -and
            ([string]$beforeProxy.proxyOverride -eq [string]$afterProxy.proxyOverride) -and
            ($beforeProxy.autoConfigUrlExists -eq $afterProxy.autoConfigUrlExists) -and
            ([string]$beforeProxy.autoConfigUrl -eq [string]$afterProxy.autoConfigUrl) -and
            ($beforeProxy.autoDetectExists -eq $afterProxy.autoDetectExists) -and
            ($beforeProxy.autoDetect -eq $afterProxy.autoDetect)
        if (-not (Test-Report '系统代理退出恢复' $restoreOk)) { $ok = $false }
    }
    catch {
        if (-not (Test-Report '系统代理自检流程' $false $_.Exception.Message)) { $ok = $false }
    }
    finally {
        if ($bridge) {
            Stop-Process -Id $bridge.pid -Force -ErrorAction SilentlyContinue
        }
        if ($job) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }
        if ($beforeProxy) {
            Write-ProxyRegistryState -State $beforeProxy
        }
        if (Test-Path -LiteralPath $testBackup) {
            Remove-Item -LiteralPath $testBackup -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host ''
    if ($ok) { Write-Host '系统代理与 HTTP 桥接自检通过。' -ForegroundColor Green }
    else { Write-Host '系统代理与 HTTP 桥接自检失败。' -ForegroundColor Red }
    return $ok
}

function Invoke-LiveTunnelSelfTest {
    $ok = $true
    Write-Host '=== HK-Tunnel 真实隧道与系统代理联调 ===' -ForegroundColor Cyan

    function Test-LiveReport {
        param([string]$Name, [bool]$Passed, [string]$Detail = '')
        $suffix = if ($Detail) { "  $Detail" } else { '' }
        if ($Passed) {
            Write-Host ("{0,-26}: True{1}" -f $Name, $suffix) -ForegroundColor Green
        }
        else {
            Write-Host ("{0,-26}: False{1}" -f $Name, $suffix) -ForegroundColor Red
        }
        return $Passed
    }

    $c = Load-Config
    $password = Load-Secret
    if (-not $c.host) {
        Write-Host '未找到已保存的服务器地址，跳过真实联调。' -ForegroundColor Yellow
        return $false
    }
    if ([string]::IsNullOrEmpty($password)) {
        Write-Host '未找到可用密码。请先勾选“记住密码”并成功启动一次。' -ForegroundColor Yellow
        return $false
    }

    $beforeProxy = Read-ProxyRegistryState
    $tunnelPid = $null
    $proxy = $null

    try {
        [void](Stop-ProxyStack)
        [void](Stop-TunnelProcesses -HostName $c.host -UserName $c.user -SocksPort $c.socksPort)

        $tunnelPid = Start-Tunnel -Config $c -Password $password
        if (-not (Test-LiveReport 'SSH SOCKS5 启动' ([bool]$tunnelPid))) { $ok = $false }

        $c.autoProxy = $true
        $proxy = Start-ProxyStack -Config $c -TunnelPid $tunnelPid
        $bridgeOk = [bool]($proxy -and (Get-PortListeners -Port $proxy.port))
        if (-not (Test-LiveReport 'HTTP 桥接启动' $bridgeOk)) { $ok = $false }

        # Set HKTUNNEL_EXPECT_EXIT_IP to your server's public address to assert
        # that traffic really leaves through it. Left unset, each path only has
        # to return an address, and the three paths must agree on which.
        $expectedExitIp = $env:HKTUNNEL_EXPECT_EXIT_IP

        $proxyAddress = "http://127.0.0.1:$($proxy.port)"
        $httpIp = (Invoke-WebRequest -Uri 'http://api.ipify.org' -Proxy $proxyAddress -UseBasicParsing -TimeoutSec 30).Content.Trim()
        $httpOk = if ($expectedExitIp) { $httpIp -eq $expectedExitIp } else { [bool]$httpIp }
        if (-not (Test-LiveReport 'HTTP 桥接出口' $httpOk "IP=$httpIp")) { $ok = $false }

        $httpsIp = (Invoke-WebRequest -Uri 'https://api.ipify.org' -Proxy $proxyAddress -UseBasicParsing -TimeoutSec 30).Content.Trim()
        $httpsOk = if ($expectedExitIp) { $httpsIp -eq $expectedExitIp } else { [bool]$httpsIp }
        if (-not (Test-LiveReport 'HTTPS CONNECT 出口' $httpsOk "IP=$httpsIp")) { $ok = $false }

        $systemProxyOk = Test-ProxyIsManaged -AppliedProxyServer "127.0.0.1:$($proxy.port)"
        if (-not (Test-LiveReport 'Windows 系统代理已接管' $systemProxyOk)) { $ok = $false }

        $systemIp = (Invoke-WebRequest -Uri 'https://api.ipify.org' -UseBasicParsing -TimeoutSec 30).Content.Trim()
        $systemOk = if ($expectedExitIp) { $systemIp -eq $expectedExitIp } else { [bool]$systemIp }
        if (-not (Test-LiveReport '系统代理默认出口' $systemOk "IP=$systemIp")) { $ok = $false }

        # Whichever address it is, all three routes have to agree on it.
        $consistentOk = [bool]($httpIp -and $httpIp -eq $httpsIp -and $httpsIp -eq $systemIp)
        if (-not (Test-LiveReport '三路出口地址一致' $consistentOk "IP=$httpIp")) { $ok = $false }
    }
    catch {
        if (-not (Test-LiveReport '真实联调流程' $false $_.Exception.Message)) { $ok = $false }
    }
    finally {
        try {
            [void](Stop-ProxyStack)
            [void](Stop-TunnelProcesses -HostName $c.host -UserName $c.user -SocksPort $c.socksPort)
        }
        catch { }

        $afterProxy = Read-ProxyRegistryState
        $restoreOk =
            ($beforeProxy.proxyEnableExists -eq $afterProxy.proxyEnableExists) -and
            ($beforeProxy.proxyEnable -eq $afterProxy.proxyEnable) -and
            ($beforeProxy.proxyServerExists -eq $afterProxy.proxyServerExists) -and
            ([string]$beforeProxy.proxyServer -eq [string]$afterProxy.proxyServer) -and
            ($beforeProxy.proxyOverrideExists -eq $afterProxy.proxyOverrideExists) -and
            ([string]$beforeProxy.proxyOverride -eq [string]$afterProxy.proxyOverride) -and
            ($beforeProxy.autoConfigUrlExists -eq $afterProxy.autoConfigUrlExists) -and
            ([string]$beforeProxy.autoConfigUrl -eq [string]$afterProxy.autoConfigUrl) -and
            ($beforeProxy.autoDetectExists -eq $afterProxy.autoDetectExists) -and
            ($beforeProxy.autoDetect -eq $afterProxy.autoDetect)
        if (-not (Test-LiveReport '停止后系统代理恢复' $restoreOk)) { $ok = $false }
    }

    Write-Host ''
    if ($ok) { Write-Host '真实隧道与系统代理联调通过。' -ForegroundColor Green }
    else { Write-Host '真实隧道与系统代理联调失败。' -ForegroundColor Red }
    return $ok
}

if ($ResetProxy) {
    Invoke-ProxyRecovery
    return
}

if ($SelfTest) {
    [void](Invoke-SelfTest)
    return
}

if ($SystemProxySelfTest) {
    $passed = Invoke-SystemProxySelfTest
    if ($passed) { exit 0 }
    exit 1
}

if ($LiveTunnelSelfTest) {
    $passed = Invoke-LiveTunnelSelfTest
    if ($passed) { exit 0 }
    exit 1
}

# -------------------------------------------------------------------- GUI

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:UiRunning = $true
$cfg = Load-Config

$form                 = New-Object System.Windows.Forms.Form
$form.Text            = 'HK-Tunnel  香港服务器隧道（系统代理）'
$form.Size            = New-Object System.Drawing.Size(580, 480)
$form.StartPosition   = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox     = $false
$form.Font            = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

function Add-Label {
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 84)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    $l.Size = New-Object System.Drawing.Size($W, 22)
    $l.TextAlign = 'MiddleLeft'
    $form.Controls.Add($l)
    return $l
}

function Add-Text {
    param([int]$X, [int]$Y, [int]$W, [switch]$Password)
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object System.Drawing.Point($X, $Y)
    $t.Size = New-Object System.Drawing.Size($W, 24)
    if ($Password) { $t.UseSystemPasswordChar = $true }
    $form.Controls.Add($t)
    return $t
}

[void](Add-Label '服务器地址' 16 18)
$txtHost = Add-Text 104 15 220
[void](Add-Label 'SSH 端口' 340 18 62)
$txtSshPort = Add-Text 408 15 70

[void](Add-Label '登录用户' 16 54)
$txtUser = Add-Text 104 51 220

[void](Add-Label '登录密码' 16 90)
$txtPass = Add-Text 104 87 220 -Password

[void](Add-Label 'SOCKS 端口' 16 126)
$txtSocks = Add-Text 104 123 70

$lblTip = New-Object System.Windows.Forms.Label
$lblTip.Text = '仅本机'
$lblTip.Location = New-Object System.Drawing.Point(184, 126)
$lblTip.Size = New-Object System.Drawing.Size(60, 22)
$lblTip.ForeColor = [System.Drawing.Color]::Gray
$form.Controls.Add($lblTip)

$chkAutoProxy = New-Object System.Windows.Forms.CheckBox
$chkAutoProxy.Text = '自动接管系统代理（退出时恢复）'
$chkAutoProxy.Location = New-Object System.Drawing.Point(300, 123)
$chkAutoProxy.Size = New-Object System.Drawing.Size(250, 22)
$form.Controls.Add($chkAutoProxy)

$chkRemember = New-Object System.Windows.Forms.CheckBox
$chkRemember.Text = '记住密码（本机加密保存）'
$chkRemember.Location = New-Object System.Drawing.Point(340, 88)
$chkRemember.Size = New-Object System.Drawing.Size(210, 22)
$form.Controls.Add($chkRemember)

$txtHost.Text      = $cfg.host
$txtSshPort.Text   = $cfg.sshPort
$txtUser.Text      = $cfg.user
$txtSocks.Text     = $cfg.socksPort
$chkRemember.Checked = $cfg.remember
$chkAutoProxy.Checked = $cfg.autoProxy
if ($cfg.remember) { $txtPass.Text = Load-Secret }

$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Text = '启动隧道'
$btnStart.Location = New-Object System.Drawing.Point(16, 164)
$btnStart.Size = New-Object System.Drawing.Size(150, 36)
$form.Controls.Add($btnStart)

$btnStop = New-Object System.Windows.Forms.Button
$btnStop.Text = '停止隧道'
$btnStop.Location = New-Object System.Drawing.Point(178, 164)
$btnStop.Size = New-Object System.Drawing.Size(150, 36)
$btnStop.Enabled = $false
$form.Controls.Add($btnStop)

$btnCopy = New-Object System.Windows.Forms.Button
$btnCopy.Text = '复制代理地址'
$btnCopy.Location = New-Object System.Drawing.Point(340, 164)
$btnCopy.Size = New-Object System.Drawing.Size(150, 36)
$form.Controls.Add($btnCopy)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object System.Drawing.Point(16, 210)
$lblStatus.Size = New-Object System.Drawing.Size(536, 26)
$lblStatus.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($lblStatus)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(16, 244)
$txtLog.Size = New-Object System.Drawing.Size(536, 190)
$txtLog.Multiline = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.ReadOnly = $true
$txtLog.BackColor = [System.Drawing.Color]::White
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$form.Controls.Add($txtLog)

function Write-Log {
    param([string]$Message)
    $ts = (Get-Date).ToString('HH:mm:ss')
    $txtLog.AppendText("[$ts] $Message`r`n")
}

function Read-UiConfig {
    $c = Get-DefaultConfig
    $c.host = $txtHost.Text.Trim()
    $c.user = $txtUser.Text.Trim()
    $c.remember = [bool]$chkRemember.Checked
    $c.autoProxy = [bool]$chkAutoProxy.Checked

    $p = 0
    if (-not [int]::TryParse($txtSshPort.Text.Trim(), [ref]$p) -or $p -lt 1 -or $p -gt 65535) {
        throw 'SSH 端口必须是 1 到 65535 之间的数字。'
    }
    $c.sshPort = $p

    $q = 0
    if (-not [int]::TryParse($txtSocks.Text.Trim(), [ref]$q) -or $q -lt 1024 -or $q -gt 65535) {
        throw 'SOCKS 端口必须是 1024 到 65535 之间的数字。'
    }
    $c.socksPort = $q

    return $c
}

function Set-UiBusy {
    param([bool]$Busy, [string]$Text)
    $btnStart.Enabled = -not $Busy
    $btnStop.Enabled  = (-not $Busy) -and [bool](Get-TunnelPid -Config (Load-Config))
    $btnCopy.Enabled  = -not $Busy
    if ($Text) { $lblStatus.Text = $Text; $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(180, 100, 0) }
    $form.Refresh()
}

function Update-Ui {
    param($Config)
    $runPid = Get-TunnelPid -Config $Config
    if ($runPid) {
        $proxyState = Get-ProxyStackState
        $proxyOk = $false
        $proxyPort = 0
        if ($proxyState -and $proxyState.bridgePid -and $proxyState.httpPort) {
            $proxyProcess = Get-Process -Id ([int]$proxyState.bridgePid) -ErrorAction SilentlyContinue
            $proxyOk = [bool]($proxyProcess -and ($proxyProcess.ProcessName -eq 'hk-httpbridge'))
            $proxyPort = [int]$proxyState.httpPort
        }

        if ($proxyOk) {
            $lblStatus.Text = "运行中    系统代理 127.0.0.1:$proxyPort    SOCKS5 127.0.0.1:$($Config.socksPort)"
        }
        else {
            $lblStatus.Text = "运行中    SOCKS5 127.0.0.1:$($Config.socksPort)    PID $runPid"
        }
        $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(0, 128, 0)
        $btnStart.Enabled = $false
        $btnStop.Enabled = $true
    }
    else {
        $lblStatus.Text = '已停止'
        $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(160, 0, 0)
        $btnStart.Enabled = $true
        $btnStop.Enabled = $false
    }
}

function Invoke-StartTunnel {
    $c = $null
    $tunnelPid = $null
    try {
        $c = Read-UiConfig
        $pwd = $txtPass.Text
        if ([string]::IsNullOrEmpty($pwd)) { throw '请填写登录密码。' }

        Save-Config -Config $c
        if ($c.remember) { Save-Secret -Plain $pwd } else { Save-Secret -Plain '' }

        Set-UiBusy -Busy $true -Text "正在连接 $($c.host) …"
        Write-Log "正在建立隧道，目标 $($c.user)@$($c.host):$($c.sshPort) …"

        $tunnelPid = Start-Tunnel -Config $c -Password $pwd
        Write-Log "隧道已启动，PID $tunnelPid，监听 127.0.0.1:$($c.socksPort)。"
        if ($c.autoProxy) {
            $proxy = Start-ProxyStack -Config $c -TunnelPid $tunnelPid
            Write-Log "HTTP 桥接已启动，PID $($proxy.pid)，监听 127.0.0.1:$($proxy.port)。"
            Write-Log 'Windows 系统代理已自动接管；退出程序时会恢复启动前的设置。'
        }
        else {
            Write-Log "未启用自动系统代理。需要时使用 SOCKS5 127.0.0.1:$($c.socksPort)。"
        }
    }
    catch {
        if ($tunnelPid) {
            [void](Stop-ProxyStack)
            $cForCleanup = if ($c) { $c } else { Load-Config }
            [void](Stop-TunnelProcesses -HostName $cForCleanup.host -UserName $cForCleanup.user -SocksPort $cForCleanup.socksPort)
        }
        Write-Log $_.Exception.Message
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '启动失败', 'OK', 'Warning')
    }
    finally {
        $btnStart.Enabled = $true
        $btnCopy.Enabled = $true
        if ($null -eq $c) { $c = Load-Config }
        Update-Ui -Config $c
    }
}

function Invoke-StopTunnel {
    # Stopping must never depend on what the form currently holds: a half-typed
    # port number used to make the button do nothing at all and leave the system
    # proxy taken over. Fall back to the saved config, which start already wrote.
    $c = $null
    try { $c = Read-UiConfig } catch { $c = $null }
    if (-not $c) { $c = Load-Config }

    try {
        $result = Stop-Tunnel -Config $c
        if ($result.proxy.restored -eq 'restored') {
            Write-Log '已恢复启动前的 Windows 系统代理设置。'
        }
        if ($result.killed.Count -gt 0) { Write-Log "已停止隧道，回收进程：$($result.killed -join ', ')" }
        else { Write-Log '没有发现运行中的隧道进程。' }
        Update-Ui -Config $c
    }
    catch { Write-Log $_.Exception.Message }
}

$btnStart.Add_Click({ Invoke-StartTunnel })

$btnStop.Add_Click({ Invoke-StopTunnel })

$btnCopy.Add_Click({
    try {
        $c = Read-UiConfig
        [System.Windows.Forms.Clipboard]::SetText("socks5h://127.0.0.1:$($c.socksPort)")
        Write-Log "已复制代理地址：socks5h://127.0.0.1:$($c.socksPort)"
    }
    catch { Write-Log $_.Exception.Message }
})

# ---------------------------------------------------------------- 托盘图标

$script:ReallyExit    = $false
$script:TrayHintShown = $false

$tray = New-Object System.Windows.Forms.NotifyIcon
try {
    if (Test-Path -LiteralPath $IconFile) {
        $tray.Icon = New-Object System.Drawing.Icon($IconFile)
    }
    else {
        $tray.Icon = [System.Drawing.SystemIcons]::Shield
    }
}
catch {
    $tray.Icon = [System.Drawing.SystemIcons]::Shield
}
$tray.Text = 'HK-Tunnel 香港服务器隧道'

$trayMenu  = New-Object System.Windows.Forms.ContextMenuStrip
$miShow    = $trayMenu.Items.Add('显示主窗口')
$miStart   = $trayMenu.Items.Add('启动隧道')
$miStop    = $trayMenu.Items.Add('停止隧道')
[void]$trayMenu.Items.Add('-')
$miExit    = $trayMenu.Items.Add('退出')
$tray.ContextMenuStrip = $trayMenu

function Show-MainWindow {
    $form.Show()
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $form.Activate()
}

$miShow.Add_Click({ Show-MainWindow })
$miStart.Add_Click({ Invoke-StartTunnel })
$miStop.Add_Click({ Invoke-StopTunnel })
$miExit.Add_Click({
    $script:ReallyExit = $true
    $form.Close()
})

$tray.Add_MouseDoubleClick({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-MainWindow }
})

$tray.Visible = $true

$form.Add_Shown({
    Write-Log '程序已就绪。填好地址、用户和密码后点「启动隧道」。'
    if ($cfg.remember -and $txtPass.Text) { Write-Log '已读取本机保存的密码。' }

    $c = Load-Config
    $cleanup = Stop-Tunnel -Config $c
    if ($cleanup.proxy.restored -eq 'restored') {
        Write-Log '检测到上次异常退出，已恢复原 Windows 系统代理设置。'
    }
    if ($cleanup.killed.Count -gt 0) { Write-Log "已清理上次残留的隧道进程：$($cleanup.killed -join ', ')" }
    else { Write-Log '检查完毕，没有发现残留隧道进程。' }
    Update-Ui -Config $c
})

$form.Add_FormClosing({
    param($sender, $e)

    # 点右上角 X 时收进托盘，隧道继续跑
    if ($e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing -and -not $script:ReallyExit) {
        $e.Cancel = $true
        $form.Hide()
        if (-not $script:TrayHintShown) {
            $script:TrayHintShown = $true
            $tray.BalloonTipTitle = 'HK-Tunnel'
            $tray.BalloonTipText = '程序已收进托盘，隧道和系统代理继续运行。双击托盘图标可以打开窗口，右键可退出。'
            $tray.ShowBalloonTip(4000)
        }
        return
    }

    # 真正退出：关掉隧道并清理托盘图标
    try {
        $c = Load-Config
        $result = Stop-Tunnel -Config $c
        if ($result.proxy.restored -eq 'restored') { Write-Log '程序退出，已恢复原 Windows 系统代理设置。' }
        if ($result.killed.Count -gt 0) { Write-Log "程序退出，已关闭隧道：$($result.killed -join ', ')" }
    }
    catch { }

    try {
        $tray.Visible = $false
        $tray.Dispose()
    }
    catch { }
})

if ($UiSmokeTest) {
    $script:SmokeStep = 0
    $script:SmokeFail = $false

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1200
    $timer.Add_Tick({
        $script:SmokeStep++
        switch ($script:SmokeStep) {
            1 {
                # 模拟点右上角 X
                $form.Close()
            }
            2 {
                $hidden = (-not $form.Visible)
                $alive  = (-not $form.IsDisposed)
                $trayOk = $tray.Visible
                Write-Host ("  点 X 后 -> 窗口已隐藏={0}  窗口未销毁={1}  托盘图标可见={2}" -f $hidden, $alive, $trayOk)
                if (-not ($hidden -and $alive -and $trayOk)) { $script:SmokeFail = $true }

                # 走托盘菜单的退出路径
                $script:ReallyExit = $true
                $timer.Stop()
                $form.Close()
            }
        }
    })
    $timer.Start()
    # 用 Application.Run 而非 ShowDialog：ShowDialog 的模态循环在 Hide() 之后会直接返回，
    # 那样"点 X 收进托盘"就变成了退出程序
    [void][System.Windows.Forms.Application]::Run($form)

    # 必须真的走到第 2 步才算数，否则说明断言被跳过了
    if ($script:SmokeStep -lt 2) { $script:SmokeFail = $true }

    if ($script:SmokeFail) {
        Write-Host 'UI 冒烟测试失败：点 X 没有按预期收进托盘。' -ForegroundColor Red
        exit 1
    }
    Write-Host ("UI 冒烟测试通过（执行 {0} 步）：窗口创建、托盘注册、点 X 收进托盘、真正退出全部正常。" -f $script:SmokeStep)
    return
}

# 同上：必须用 Application.Run，隐藏窗口时消息循环不能退出
[void][System.Windows.Forms.Application]::Run($form)
