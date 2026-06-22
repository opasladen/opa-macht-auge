# Opa macht Auge - Docker Desktop Datenstore nach G: konfigurieren
# Muss VOR dem ersten Start von Docker Desktop laufen.
# Wenn Docker Desktop schon einmal lief und WSL-Distros existieren,
# wird Fallback wsl --export/--import nach G:\WSL ausgefuehrt.

$ErrorActionPreference = 'Stop'

$wslRoot       = 'G:\WSL'
$dockerDataDir = Join-Path $wslRoot 'Docker'
$dockerVhdx    = Join-Path $dockerDataDir 'docker_data.vhdx'
$settingsPath  = Join-Path $env:APPDATA 'Docker\settings-store.json'
$settingsAlt   = Join-Path $env:APPDATA 'Docker\settings.json'

function Stop-DockerDesktop {
    Write-Host "Stoppe Docker Desktop (falls aktiv)..." -ForegroundColor Yellow
    Get-Process 'Docker Desktop','com.docker.backend','com.docker.service','com.docker.proxy','vpnkit-bridge' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    wsl --shutdown 2>$null | Out-Null
}

function Test-DockerDistros {
    $list = (wsl --list --quiet 2>$null) -replace "`0",'' -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    $hasDD     = $list -contains 'docker-desktop'
    $hasDDData = $list -contains 'docker-desktop-data'
    [pscustomobject]@{ Any = ($hasDD -or $hasDDData); DockerDesktop = $hasDD; DockerDesktopData = $hasDDData; List = $list }
}

function Move-Distro {
    param([string]$Name, [string]$TargetDir)
    $tar = Join-Path $env:TEMP "$Name-export.tar"
    Write-Host "  Export $Name -> $tar"
    wsl --export $Name $tar
    if ($LASTEXITCODE -ne 0) { throw "wsl --export $Name fehlgeschlagen" }
    Write-Host "  Unregister $Name"
    wsl --unregister $Name
    if ($LASTEXITCODE -ne 0) { throw "wsl --unregister $Name fehlgeschlagen" }
    New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
    Write-Host "  Import $Name -> $TargetDir"
    wsl --import $Name $TargetDir $tar --version 2
    if ($LASTEXITCODE -ne 0) { throw "wsl --import $Name fehlgeschlagen" }
    Remove-Item $tar -Force
    Write-Host "  $Name verschoben." -ForegroundColor Green
}

function Set-DockerDiskPath {
    param([string]$Path)
    New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
    $file = $null
    if (Test-Path $settingsPath) { $file = $settingsPath }
    elseif (Test-Path $settingsAlt) { $file = $settingsAlt }
    if ($file) {
        Write-Host "Patche $file -> diskPath = $Path"
        $json = Get-Content $file -Raw | ConvertFrom-Json
        $json | Add-Member -NotePropertyName 'diskPath' -NotePropertyValue $Path -Force
        $json | Add-Member -NotePropertyName 'wslEngineEnabled' -NotePropertyValue $true -Force
        ($json | ConvertTo-Json -Depth 20) | Set-Content -Path $file -Encoding UTF8
    } else {
        Write-Host "Erstelle neue settings-store.json mit diskPath = $Path"
        $json = [pscustomobject]@{
            wslEngineEnabled = $true
            diskPath         = $Path
        }
        $parent = Split-Path $settingsPath -Parent
        if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        ($json | ConvertTo-Json -Depth 20) | Set-Content -Path $settingsPath -Encoding UTF8
    }
}

function Ensure-WslConfig {
    $cfg = Join-Path $env:USERPROFILE '.wslconfig'
    $content = @"
[wsl2]
memory=8GB
processors=4
swap=4GB
localhostForwarding=true
"@
    if (-not (Test-Path $cfg)) {
        $content | Set-Content -Path $cfg -Encoding ASCII
        Write-Host ".wslconfig erstellt: $cfg"
    } else {
        Write-Host ".wslconfig existiert bereits: $cfg (unveraendert)"
    }
}

try {
    Write-Host "=== WSL/Docker Datenstore nach G: ===" -ForegroundColor Cyan

    if (-not (Test-Path 'G:\')) { throw 'G:\ nicht verfuegbar' }
    New-Item -ItemType Directory -Path $wslRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $dockerDataDir -Force | Out-Null

    Stop-DockerDesktop
    $distros = Test-DockerDistros
    Write-Host "Vorhandene WSL-Distros: $($distros.List -join ', ')"

    if ($distros.Any) {
        Write-Host "Docker-Distros existieren -> Fallback wsl --export/--import nach $wslRoot" -ForegroundColor Yellow
        if ($distros.DockerDesktop)     { Move-Distro -Name 'docker-desktop'      -TargetDir (Join-Path $wslRoot 'docker-desktop') }
        if ($distros.DockerDesktopData) { Move-Distro -Name 'docker-desktop-data' -TargetDir (Join-Path $wslRoot 'docker-desktop-data') }
    } else {
        Write-Host "Noch keine Docker-Distros -> Setze diskPath in Docker-Settings auf $dockerVhdx" -ForegroundColor Green
        Set-DockerDiskPath -Path $dockerVhdx
    }

    Ensure-WslConfig

    Write-Host "`n--- FERTIG ---" -ForegroundColor Green
    Write-Host "Beim ersten Start von Docker Desktop landet das VHDX nun unter G:\WSL\Docker\."
}
catch {
    Write-Host "FEHLER: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace
    exit 1
}
