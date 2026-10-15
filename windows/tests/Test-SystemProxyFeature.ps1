$ErrorActionPreference = 'Stop'

$app = Join-Path (Split-Path -Parent $PSScriptRoot) 'HK-Tunnel.ps1'
if (-not (Test-Path -LiteralPath $app)) {
    throw "Application not found: $app"
}

$output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $app -SystemProxySelfTest 2>&1
$exitCode = $LASTEXITCODE
$output | ForEach-Object { Write-Host $_ }

if ($exitCode -ne 0) {
    throw "System proxy self-test failed with exit code $exitCode."
}

Write-Host 'System proxy feature test passed.'
