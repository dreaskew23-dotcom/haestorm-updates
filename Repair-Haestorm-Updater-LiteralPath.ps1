# Haestorm updater LiteralPath repair
# Fixes PowerShell wildcard handling for resource paths such as resources\[standalone]\...

$ErrorActionPreference = 'Stop'
$UpdaterPath = 'C:\Haestorm\Updater\Update-Haestorm.ps1'

function Step($m){ Write-Host "[Haestorm] $m" -ForegroundColor Cyan }
function Ok($m){ Write-Host "[OK] $m" -ForegroundColor Green }

if (!(Test-Path -LiteralPath $UpdaterPath)) {
    throw "Updater not found: $UpdaterPath"
}

$backup = "$UpdaterPath.before-literalpath-fix"
Copy-Item -LiteralPath $UpdaterPath -Destination $backup -Force
Step "Backup created: $backup"

$text = Get-Content -LiteralPath $UpdaterPath -Raw

$replacements = [ordered]@{
    'if (!(Test-Path $bridgePath))' = 'if (!(Test-Path -LiteralPath $bridgePath))'
    'if(Test-Path $resultPath)' = 'if(Test-Path -LiteralPath $resultPath)'
    'Get-Content $resultPath -Raw' = 'Get-Content -LiteralPath $resultPath -Raw'
    'if(!(Test-Path $restart))' = 'if(!(Test-Path -LiteralPath $restart))'
    'if(!(Test-Path $source))' = 'if(!(Test-Path -LiteralPath $source))'
    'if(!(Test-Path (Join-Path $releaseRoot $name)))' = 'if(!(Test-Path -LiteralPath (Join-Path $releaseRoot $name)))'
    "if(`$changed -contains 'ai-dispatch-worker' -and (Test-Path `$workerPath))" = "if(`$changed -contains 'ai-dispatch-worker' -and (Test-Path -LiteralPath `$workerPath))"
    'if(Test-Path $src)' = 'if(Test-Path -LiteralPath $src)'
    'Move-Item $src $dst -Force' = 'Move-Item -LiteralPath $src -Destination $dst -Force'
    'if(Test-Path $dest)' = 'if(Test-Path -LiteralPath $dest)'
    'Copy-Item $dest $b -Recurse -Force' = 'Copy-Item -LiteralPath $dest -Destination $b -Recurse -Force'
    'Remove-Item $dest -Recurse -Force' = 'Remove-Item -LiteralPath $dest -Recurse -Force'
    'Copy-Item $src $dest -Recurse -Force' = 'Copy-Item -LiteralPath $src -Destination $dest -Recurse -Force'
    'if(Test-Path $srcp)' = 'if(Test-Path -LiteralPath $srcp)'
    'Copy-Item $srcp $dstp -Recurse -Force' = 'Copy-Item -LiteralPath $srcp -Destination $dstp -Recurse -Force'
    'if(Test-Path $entry.dest)' = 'if(Test-Path -LiteralPath $entry.dest)'
    'Remove-Item $entry.dest -Recurse -Force -ErrorAction SilentlyContinue' = 'Remove-Item -LiteralPath $entry.dest -Recurse -Force -ErrorAction SilentlyContinue'
    'if(Test-Path $old)' = 'if(Test-Path -LiteralPath $old)'
    'Copy-Item $old $entry.dest -Recurse -Force' = 'Copy-Item -LiteralPath $old -Destination $entry.dest -Recurse -Force'
}

$changedCount = 0
foreach ($pair in $replacements.GetEnumerator()) {
    if ($text.Contains($pair.Key)) {
        $text = $text.Replace($pair.Key, $pair.Value)
        $changedCount++
    }
}

# Also protect the updater bridge command/result paths explicitly.
$text = $text.Replace(
    "[IO.File]::WriteAllText((Join-Path `$bridgePath 'command.json'),`$json,(New-Object Text.UTF8Encoding(`$false)))",
    "[IO.File]::WriteAllText((Join-Path `$bridgePath 'command.json'),`$json,(New-Object Text.UTF8Encoding(`$false)))"
)

Set-Content -LiteralPath $UpdaterPath -Value $text -Encoding UTF8

Step "Applied $changedCount LiteralPath fixes"

# Verify the critical bridge line is fixed before declaring success.
$verify = Get-Content -LiteralPath $UpdaterPath -Raw
if ($verify -notmatch 'Test-Path\s+-LiteralPath\s+\$bridgePath') {
    Copy-Item -LiteralPath $backup -Destination $UpdaterPath -Force
    throw 'Critical bridge fix did not apply. Original updater restored.'
}

Ok 'Haestorm updater repaired for [standalone] paths.'
Write-Host ''
Write-Host 'Now run:' -ForegroundColor White
Write-Host '  haestorm-update' -ForegroundColor Green
