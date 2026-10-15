$ErrorActionPreference = 'Stop'

$app = Join-Path (Split-Path -Parent $PSScriptRoot) 'HK-Tunnel.ps1'
if (-not (Test-Path -LiteralPath $app)) {
    throw "Application not found: $app"
}

$output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $app -LiveTunnelSelfTest 2>&1
$exitCode = $LASTEXITCODE
$output | ForEach-Object { Write-Host $_ }

if ($exitCode -ne 0) {
    throw "Live tunnel self-test failed with exit code $exitCode."
}

Write-Host 'Live tunnel test passed.'
