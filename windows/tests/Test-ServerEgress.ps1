# 服务器公网带宽体检：判断"慢"是被限速，还是线路/负载问题。
#
# 判据：先测服务器到阿里云内网镜像的速度（正常必然很快，作为对照），
# 再测服务器到多个公网目标的速度。若内网飞快、公网所有目标都卡在同一个
# 数值上，那就是针对这台实例的公网限速，跟你的代码、客户端、线路拥塞都无关。
[CmdletBinding()]
param(
    [int]$Seconds = 12
)

$ErrorActionPreference = 'Continue'

$app = Join-Path (Split-Path -Parent $PSScriptRoot) 'HK-Tunnel.ps1'
$text = [System.IO.File]::ReadAllText($app, [System.Text.Encoding]::UTF8)

# 复用 HK-Tunnel.ps1 里的配置/密码读取与 ssh 参数构造逻辑
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

$cfg = Load-Config
$pw = Load-Secret
if (-not $cfg.host) { Write-Host '没有已保存的服务器地址，请先启动一次隧道。' -ForegroundColor Yellow; exit 2 }
if ([string]::IsNullOrEmpty($pw)) { Write-Host '没有已保存的密码（需勾选"记住密码"）。' -ForegroundColor Yellow; exit 2 }

$env:SSH_ASKPASS = $AskPassExe
$env:SSH_ASKPASS_REQUIRE = 'force'
$env:HKTUNNEL_PW = $pw

$sshArgs = @(
    '-o', 'StrictHostKeyChecking=accept-new',
    '-o', "UserKnownHostsFile=`"$KnownHosts`"",
    '-o', 'ConnectTimeout=15',
    '-o', 'PreferredAuthentications=password,keyboard-interactive',
    '-o', 'NumberOfPasswordPrompts=1',
    '-o', 'LogLevel=ERROR',
    '-p', "$($cfg.sshPort)",
    "$($cfg.user)@$($cfg.host)",
    'bash -s'
)

# 单引号 here-string：里面的 $ 全部原样送给 bash，不会被 PowerShell 当子表达式解析。
# 需要插值的地方用占位符，稍后整体替换。
$remote = @'
probe() {
  rm -f /tmp/hkt-egress.bin
  timeout __SECONDS__ wget -q -O /tmp/hkt-egress.bin "$1" 2>/dev/null
  b=$(stat -c%s /tmp/hkt-egress.bin 2>/dev/null || echo 0)
  rm -f /tmp/hkt-egress.bin
  echo $b
}
i=$(probe http://mirrors.cloud.aliyuncs.com/ubuntu/ls-lR.gz);    echo "INTERNAL_BYTES=$i"
a=$(probe https://mirrors.aliyun.com/ubuntu/ls-lR.gz);           echo "PUBLIC_CN_BYTES=$a"
b=$(probe http://speedtest.tele2.net/100MB.zip);                 echo "PUBLIC_EU_BYTES=$b"
c=$(probe https://dl.google.com/go/go1.22.0.linux-amd64.tar.gz); echo "PUBLIC_GOOGLE_BYTES=$c"
t=$(curl -s --max-time 5 http://100.100.100.200/latest/meta-data/instance/instance-type); echo "INSTANCE_TYPE=$t"
echo ===END===
'@
$remote = $remote.Replace('__SECONDS__', "$Seconds")

Write-Host "正在测服务器带宽（每个目标最多 $Seconds 秒），请稍候…" -ForegroundColor Cyan
$out = ($remote -replace "`r`n", "`n") | & "$env:WINDIR\System32\OpenSSH\ssh.exe" @sshArgs 2>&1

function Get-Bytes($name) {
    $line = $out | Where-Object { $_ -match "^$name=(\d+)" } | Select-Object -First 1
    if ($line -match "^$name=(\d+)") { return [int64]$Matches[1] }
    return -1
}

$internal = Get-Bytes 'INTERNAL_BYTES'
$cn       = Get-Bytes 'PUBLIC_CN_BYTES'
$eu       = Get-Bytes 'PUBLIC_EU_BYTES'
$google   = Get-Bytes 'PUBLIC_GOOGLE_BYTES'
$type     = (($out | Where-Object { $_ -match '^INSTANCE_TYPE=' } | Select-Object -First 1) -replace '^INSTANCE_TYPE=','').Trim()

if ($internal -lt 0) {
    Write-Host '无法从服务器取得数据，请检查服务器是否可达。' -ForegroundColor Red
    $out | Select-Object -Last 5 | ForEach-Object { Write-Host "  $_" }
    exit 1
}

function Show-Rate($label, $bytes) {
    if ($bytes -lt 0) { Write-Host ("  {0,-24} : 失败" -f $label); return $null }
    $kbs = $bytes / $Seconds / 1024
    $mbps = $bytes * 8 / $Seconds / 1MB
    Write-Host ("  {0,-24} : {1,8:N0} KB/s   ({2:N2} Mbps)" -f $label, $kbs, $mbps)
    return $kbs
}

Write-Host ''
Write-Host "=== 服务器实测带宽（每项 $Seconds 秒） ===" -ForegroundColor Cyan
if ($type) { Write-Host "  实例规格                 : $type" }
$iRate  = Show-Rate '内网镜像（对照组）' $internal
$cnRate = Show-Rate '公网 · 阿里云内地' $cn
$euRate = Show-Rate '公网 · 欧洲' $eu
$gRate  = Show-Rate '公网 · Google' $google

$public = @($cnRate, $euRate, $gRate) | Where-Object { $_ -ne $null }
Write-Host ''
if (-not $public.Count) {
    Write-Host '公网测试全部失败，可能是出网被切断（例如被黑洞）。' -ForegroundColor Red
    exit 1
}

$maxPublic = ($public | Measure-Object -Maximum).Maximum
$minPublic = ($public | Measure-Object -Minimum).Minimum

if ($iRate -and $maxPublic -gt 0 -and $iRate -gt ($maxPublic * 10)) {
    Write-Host ("结论：内网 {0:N0} KB/s，公网最高只有 {1:N0} KB/s，两者差 {2:N0} 倍。" -f $iRate, $maxPublic, ($iRate / $maxPublic)) -ForegroundColor Yellow
    Write-Host '      这是**针对这台实例的公网带宽限制/限速**，与你本机、隧道代码、线路拥塞无关。' -ForegroundColor Yellow
    Write-Host ("      可发给阿里云的数据：内网 {0:N0} KB/s vs 公网 {1:N0} KB/s（多个目标一致），实例 {2}" -f $iRate, $maxPublic, $type) -ForegroundColor Yellow
}
elseif ($maxPublic -gt 0 -and ($maxPublic / [Math]::Max($minPublic, 1)) -lt 3) {
    Write-Host ("结论：公网各目标都在 {0:N0} KB/s 左右且彼此接近，呈限速特征。" -f $maxPublic) -ForegroundColor Yellow
    Write-Host '      建议结合内网数据联系阿里云确认带宽配额。' -ForegroundColor Yellow
}
else {
    Write-Host '结论：公网各目标速度差异较大，更像线路或目标侧问题，不像统一限速。' -ForegroundColor Green
}
Write-Host ''
