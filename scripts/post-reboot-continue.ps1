# Opa macht Auge - Nach dem Reboot: Docker, Compose, Backend hochfahren
# Annahmen:
#   - VirtualMachinePlatform ist nach Reboot aktiv
#   - move-wsl-to-g.ps1 wurde vor dem ersten Docker-Start ausgefuehrt
#   - Workspace liegt auf G:\Projekte Programmieren\Opa macht Auge

$ErrorActionPreference = 'Stop'
$workspace = 'G:\Projekte Programmieren\Opa macht Auge'

function Write-Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }

function Wait-DockerEngine {
    param([int]$TimeoutSec = 240)
    Write-Host "Warte auf Docker Engine (bis zu $TimeoutSec s)..."
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        docker info 2>$null 1>$null
        if ($LASTEXITCODE -eq 0) { Write-Host "Docker Engine bereit ($([int]$sw.Elapsed.TotalSeconds) s)" -ForegroundColor Green; return $true }
        Start-Sleep -Seconds 3
    }
    return $false
}

try {
    Write-Step "0/5 Workspace pruefen"
    if (-not (Test-Path $workspace)) { throw "Workspace nicht gefunden: $workspace" }
    Set-Location $workspace
    Write-Host "Cwd: $((Get-Location).Path)"

    Write-Step "1/5 WSL-Status"
    wsl --status
    wsl --list --verbose

    Write-Step "2/5 Docker Desktop starten"
    $dockerExe = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
    if (-not (Test-Path $dockerExe)) { throw "Docker Desktop EXE nicht gefunden: $dockerExe" }
    if (-not (Get-Process 'Docker Desktop' -ErrorAction SilentlyContinue)) {
        Start-Process -FilePath $dockerExe
        Write-Host "Docker Desktop gestartet."
    } else {
        Write-Host "Docker Desktop laeuft bereits."
    }
    if (-not (Wait-DockerEngine)) { throw 'Docker Engine wurde nicht rechtzeitig bereit. Pruefe Docker Desktop manuell.' }

    Write-Step "3/5 docker compose up -d"
    docker compose up -d
    Write-Host "Container-Status:"
    docker compose ps

    Write-Step "4/5 Backend: uv sync + Alembic"
    Set-Location (Join-Path $workspace 'backend')
    uv sync
    if (-not (Test-Path 'alembic\versions') -or ((Get-ChildItem 'alembic\versions' -Filter '*.py' -ErrorAction SilentlyContinue | Measure-Object).Count -eq 0)) {
        Write-Host "Erstelle Initial-Migration..."
        uv run alembic revision --autogenerate -m 'init'
    } else {
        Write-Host "Migrations existieren bereits."
    }
    uv run alembic upgrade head

    Write-Step "5/5 Status"
    docker compose ps
    Write-Host "`nFertig. Naechster Schritt: ML-Bootstrap" -ForegroundColor Green
    Write-Host "  cd `"$workspace\ml`""
    Write-Host "  uv sync"
    Write-Host "  `$env:PYTHONPATH = '..\\backend'"
    Write-Host "  uv run python -m ml.bootstrap.pokemontcg --set-code base1"
}
catch {
    Write-Host "FEHLER: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace
    exit 1
}
