# Haestorm one-command first-time installer v2
# Repository: https://github.com/dreaskew23-dotcom/haestorm-updates

$ManifestUrl = 'https://raw.githubusercontent.com/dreaskew23-dotcom/haestorm-updates/main/latest.json'

$ErrorActionPreference = 'Stop'

function Step($m){ Write-Host "[Haestorm] $m" -ForegroundColor Cyan }
function Ok($m){ Write-Host "[OK] $m" -ForegroundColor Green }
function Fail($m){ Write-Host "[FAIL] $m" -ForegroundColor Red }

try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    if(-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
        throw 'Run Windows PowerShell as Administrator.'
    }

    Step 'Reading Haestorm release feed'
    $cacheBust = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $manifest = Invoke-RestMethod -Uri "$ManifestUrl?cb=$cacheBust" -Headers @{ 'User-Agent'='Haestorm-Updater' }

    if(!$manifest.url -or !$manifest.version){
        throw 'latest.json is missing version or url.'
    }

    Write-Host ("[Haestorm] Feed version: v{0}" -f $manifest.version) -ForegroundColor DarkCyan
    Write-Host ("[Haestorm] Package: {0}" -f $manifest.url) -ForegroundColor DarkCyan

    $temp = Join-Path $env:TEMP ('haestorm-first-install-' + [guid]::NewGuid().ToString('N'))
    $zip = Join-Path $temp 'release.zip'
    $extract = Join-Path $temp 'extract'

    New-Item -ItemType Directory -Force -Path $temp,$extract | Out-Null

    Step "Downloading Haestorm v$($manifest.version)"
    Invoke-WebRequest -Uri ([string]$manifest.url) -OutFile $zip -Headers @{ 'User-Agent'='Haestorm-Updater' }

    if($manifest.sha256){
        Step 'Verifying package checksum'
        $actual = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        $expected = ([string]$manifest.sha256).ToLowerInvariant()

        if($actual -ne $expected){
            throw "SHA256 mismatch. Expected $expected but got $actual"
        }

        Ok 'Package checksum verified'
    }

    Step 'Extracting setup'
    Expand-Archive -Path $zip -DestinationPath $extract -Force

    $installer = Get-ChildItem $extract -Filter 'Install-HaestormUpdater.ps1' -File -Recurse |
        Select-Object -First 1 -ExpandProperty FullName

    if(!$installer){
        throw 'Install-HaestormUpdater.ps1 was not found in the release.'
    }

    Step 'Installing Haestorm one-command updater'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -ManifestUrl $ManifestUrl

    if($LASTEXITCODE -ne 0){
        throw "Updater installer exited with code $LASTEXITCODE"
    }

    $updater = 'C:\Haestorm\Updater\Update-Haestorm.ps1'
    if(!(Test-Path $updater)){
        throw 'The updater was not installed correctly.'
    }

    Step 'Installing current Haestorm release'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $updater -Url $zip

    if($LASTEXITCODE -ne 0){
        throw "Haestorm update exited with code $LASTEXITCODE"
    }

    Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host ''
    Write-Host '============================================' -ForegroundColor Green
    Write-Host ' HAESTORM FIRST-TIME SETUP COMPLETE' -ForegroundColor Green
    Write-Host '============================================' -ForegroundColor Green
    Write-Host 'Future updates use ONE command:' -ForegroundColor White
    Write-Host '  haestorm-update' -ForegroundColor Green
}
catch {
    Fail $_.Exception.Message
    throw
}
