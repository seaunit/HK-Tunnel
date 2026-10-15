<#
    hev-socks5-tunnel and its submodules track a number of headers as symbolic
    links. A Windows checkout without symlink support turns those into small
    text files holding the link target, which the C compiler then chokes on.

    This replaces every such placeholder with a real copy of its target. Run it
    once after cloning on Windows, before the first Gradle build.
#>
param(
    [string]$Root = (Join-Path $PSScriptRoot '..\app\src\main\jni\hev-socks5-tunnel')
)

$ErrorActionPreference = 'Stop'

$repos = @(
    $Root,
    (Join-Path $Root 'src\core'),
    (Join-Path $Root 'third-part\hev-task-system'),
    (Join-Path $Root 'third-part\lwip'),
    (Join-Path $Root 'third-part\yaml')
)

$total = 0
foreach ($repo in $repos) {
    if (-not (Test-Path -LiteralPath (Join-Path $repo '.git'))) { continue }

    $repoPath = [System.IO.Path]::GetFullPath($repo)
    $links = git -C $repoPath ls-files -s | Where-Object { $_ -match '^120000 ' }

    foreach ($entry in $links) {
        $relative = ($entry -split "`t")[1]
        $link = Join-Path $repoPath $relative
        if (-not (Test-Path -LiteralPath $link)) { continue }

        $target = (Get-Content -LiteralPath $link -Raw).Trim()
        $resolved = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $link) $target))

        if (-not $resolved.StartsWith($repoPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Warning "skipped, target escapes the repository: $relative"
            continue
        }
        if (-not (Test-Path -LiteralPath $resolved)) {
            Write-Warning "skipped, target is missing: $relative -> $target"
            continue
        }

        Remove-Item -LiteralPath $link -Force
        Copy-Item -LiteralPath $resolved -Destination $link -Force
        $total++
    }
}

Write-Host "Materialized $total symlinked file(s) under $Root"
