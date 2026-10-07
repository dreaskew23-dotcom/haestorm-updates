$ErrorActionPreference='Stop'
$SelfUrl='https://raw.githubusercontent.com/dreaskew23-dotcom/haestorm-updates/main/recovery/v0.5.0.7.ps1?elevated=1'
$Updater='C:\Haestorm\Updater\Update-Haestorm.ps1'
$Config='C:\Haestorm\Updater\config.json'
$Target='94cecf68b79823c1090791aba64330025fc1248a87c2a7b2693d5ff6942d7662'
$Base='d169dfe78bc9037a2f3c40599ad55bb99f92ba95115ae0600e6c0af9c51391ce'
$PathOnly='3c4b142af86d15e6585373e2c5b011880c1a8499075d287c0865e41c7589b34c'
$Backup="$Updater.before-v0507-recovery"

function Test-Admin {
    $id=[Security.Principal.WindowsIdentity]::GetCurrent()
    $p=New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if(-not (Test-Admin)){
    $tmp=Join-Path $env:TEMP 'haestorm-v0507-recovery.ps1'
    Invoke-WebRequest -UseBasicParsing -Uri $SelfUrl -OutFile $tmp
    Write-Host '[Haestorm] Administrator permission is required. Approve the UAC prompt.' -ForegroundColor Yellow
    $args=@("-NoProfile","-ExecutionPolicy","Bypass","-File",$tmp)
    $proc=Start-Process powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList $args
    exit $proc.ExitCode
}

Write-Host '[Haestorm] Repairing Hybrid updater permissions' -ForegroundColor Cyan
attrib -R $Updater 2>$null
& takeown.exe /F $Updater /A | Out-Null
& icacls.exe $Updater /grant '*S-1-5-32-544:F' /C | Out-Null
if($LASTEXITCODE -ne 0){ throw 'Could not grant Administrators full control over the updater.' }

$OldFind=@'
function Find-Dest([string]$name){
    if($name -eq 'ai-dispatch-worker'){ return $workerPath }
    $found=Get-ChildItem -LiteralPath $resourceRoot -Directory -Recurse -ErrorAction SilentlyContinue |
        Where-Object Name -eq $name | Select-Object -First 1
    if($found){ return $found.FullName }
    return Join-Path $resourceRoot $name
}

'@
$NewFind=@'
function Find-Dest([string]$name){
    if($name -eq 'ai-dispatch-worker'){ return $workerPath }

    # Explicit resource-relative paths are used for one-time migrations and are
    # resolved directly instead of being confused with duplicate folder names.
    if($name.Contains('\') -or $name.Contains('/')){
        return Join-Path $resourceRoot ($name.Replace('/','\'))
    }

    # Prefer the normal FiveM live standalone group when it exists.
    $preferred=Join-Path $resourceRoot ('[standalone]\' + $name)
    if(Test-Path -LiteralPath $preferred){ return $preferred }

    $found=Get-ChildItem -LiteralPath $resourceRoot -Directory -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            $p=$_.FullName.ToLowerInvariant()
            $_.Name -eq $name -and
            $p -notlike '*\test\*' -and
            $p -notlike '*\haestorm-updates\*' -and
            $p -notlike '*\staging\*' -and
            $p -notlike '*\backup\*' -and
            $p -notlike '*\backups\*' -and
            $p -notlike '*\incoming\*' -and
            $p -notlike '*\temp\*'
        } |
        Sort-Object FullName |
        Select-Object -First 1

    if($found){ return $found.FullName }
    return Join-Path $resourceRoot $name
}

'@
$OldFeed=@'
function Get-RemoteFeed {
    if(!$config.manifestUrl){ return $null }
    Step 'Checking Haestorm release feed'
    try {
        return Invoke-RestMethod -Uri ([string]$config.manifestUrl) -UseBasicParsing -TimeoutSec 15
    } catch {
        WarnH "Release feed unavailable: $($_.Exception.Message)"
        return $null
    }
}

'@
$NewFeed=@'
function Get-RemoteFeed {
    if(!$config.manifestUrl){ return $null }
    Step 'Checking Haestorm release feed'
    try {
        $base=[string]$config.manifestUrl
        $sep=if($base.Contains('?')){ '&' } else { '?' }
        $uri=$base + $sep + 'haestorm_cb=' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $headers=@{ 'Cache-Control'='no-cache'; 'Pragma'='no-cache' }
        return Invoke-RestMethod -Uri $uri -Headers $headers -UseBasicParsing -TimeoutSec 15
    } catch {
        WarnH "Release feed unavailable: $($_.Exception.Message)"
        return $null
    }
}

'@

$h=(Get-FileHash -Algorithm SHA256 -LiteralPath $Updater).Hash.ToLowerInvariant()
if($h -ne $Target){
    if($h -ne $Base -and $h -ne $PathOnly){ throw "Unexpected updater hash: $h" }
    Copy-Item -LiteralPath $Updater -Destination $Backup -Force
    $t=[IO.File]::ReadAllText($Updater)
    if($h -eq $Base){
        if(!$t.Contains($OldFind)){ throw 'Updater Find-Dest anchor not found.' }
        $t=$t.Replace($OldFind,$NewFind)
    }
    if(!$t.Contains($OldFeed)){ throw 'Updater feed anchor not found.' }
    $t=$t.Replace($OldFeed,$NewFeed)
    [IO.File]::WriteAllText($Updater,$t,(New-Object Text.UTF8Encoding($false)))
    $h2=(Get-FileHash -Algorithm SHA256 -LiteralPath $Updater).Hash.ToLowerInvariant()
    if($h2 -ne $Target){
        Copy-Item -LiteralPath $Backup -Destination $Updater -Force
        throw "Updater recovery hash mismatch: $h2"
    }
    Write-Host '[OK] Hybrid updater v4 path + cache fixes installed.' -ForegroundColor Green
}else{
    Write-Host '[OK] Hybrid updater v4 fixes already installed.' -ForegroundColor Green
}

$c=Get-Content -LiteralPath $Config -Raw | ConvertFrom-Json
$oldUrl=[string]$c.manifestUrl
try {
    $c.manifestUrl='https://raw.githubusercontent.com/dreaskew23-dotcom/haestorm-updates/main/feeds/haestorm-v0.5.0.7.json?recovery=2'
    [IO.File]::WriteAllText($Config,($c|ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding($false)))
    Write-Host '[Haestorm] Applying v0.5.0.7 to the live resources' -ForegroundColor Cyan
    & 'C:\WINDOWS\haestorm-update.cmd'
    if($LASTEXITCODE -ne 0){ throw "haestorm-update exited with code $LASTEXITCODE" }
}
finally {
    $c.manifestUrl=$oldUrl
    [IO.File]::WriteAllText($Config,($c|ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding($false)))
}
Write-Host '[OK] Haestorm v0.5.0.7 recovery complete. Future updates use: haestorm-update' -ForegroundColor Green
