#requires -Version 5.1
<#
Overnight-Pipeline fuer den Detector-Sprint.

Schritte (sequentiell, jeder Step bricht bei Fehler ab):
    1. uv sync --group train             (torch CPU + ultralytics + onnx)
    2. Voll-Dataset 8000+1000            (datasets/cards_obb/)
    3. YOLO11n OBB Training              (runs/detector/yolo11n_obb_cards/)

Aufruf:
    pwsh.exe -ExecutionPolicy Bypass -File scripts\train_overnight.ps1

Output landet zusaetzlich in scripts\logs\train_<timestamp>.log.
#>

$ErrorActionPreference = 'Stop'

# --- ENV-Setup (Pflicht fuer G:-only Workflow) ----------------------------
$env:TMP            = 'G:\temp'
$env:TEMP           = 'G:\temp'
$env:PUB_CACHE      = 'G:\pub-cache'
$env:UV_CACHE_DIR   = 'G:\uv-cache'
$env:UV_LINK_MODE   = 'copy'   # exFAT auf G: unterstuetzt keine Hardlinks
$env:PYTHONPATH     = '..\backend'
$env:PYTHONIOENCODING = 'utf-8'

# Damit Ultralytics keine Telemetry probiert + kein implizites Browser-Open
$env:YOLO_OFFLINE          = '1'
$env:YOLO_AUTOINSTALL      = 'False'
$env:ULTRALYTICS_HUB       = 'False'

$workspaceRoot = 'g:\Projekte Programmieren\Opa macht Auge'
$mlDir         = Join-Path $workspaceRoot 'ml'
$logDir        = Join-Path $workspaceRoot 'scripts\logs'
$null = New-Item -ItemType Directory -Force -Path $logDir
$null = New-Item -ItemType Directory -Force -Path 'G:\temp'

$stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
$logFile = Join-Path $logDir "train_$stamp.log"

function Write-Section {
    param([string]$title)
    $line = "================================================================"
    $msg  = "`n$line`n  $title  ($(Get-Date -Format 'HH:mm:ss'))`n$line`n"
    Write-Host $msg -ForegroundColor Cyan
    Add-Content -Path $logFile -Value $msg
}

function Invoke-Step {
    param([string]$name, [scriptblock]$action)
    Write-Section $name
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    try {
        & $action 2>&1 | Tee-Object -FilePath $logFile -Append
        $code = $LASTEXITCODE
        if ($null -ne $code -and $code -ne 0) {
            throw "$name beendet mit Exit-Code $code"
        }
        $sw.Stop()
        Add-Content -Path $logFile -Value "  -> OK in $($sw.Elapsed)"
        Write-Host "  -> OK in $($sw.Elapsed)" -ForegroundColor Green
    } catch {
        $sw.Stop()
        $err = "  -> FEHLER nach $($sw.Elapsed): $($_.Exception.Message)"
        Add-Content -Path $logFile -Value $err
        Write-Host $err -ForegroundColor Red
        throw
    } finally {
        $ErrorActionPreference = $prevEAP
    }
}

Set-Location $mlDir

Add-Content -Path $logFile -Value "Start: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Add-Content -Path $logFile -Value "Workspace: $workspaceRoot"
Add-Content -Path $logFile -Value "Logfile: $logFile"

# --- Schritt 1: uv sync --group train ------------------------------------
Invoke-Step 'Schritt 1/3: uv sync --group train (torch CPU + ultralytics)' {
    uv sync --group train
}

# --- Schritt 2: Voll-Dataset ---------------------------------------------
Invoke-Step 'Schritt 2/3: Dataset 8000 train + 1000 val' {
    uv run python -m ml.detector.synth_dataset `
        --num-train 8000 `
        --num-val 1000 `
        --output-dir datasets/cards_obb `
        --card-sample 5000 `
        --img-size 1024 `
        --max-cards 9 `
        --concurrency 24
}

# --- Schritt 3: YOLO11n OBB Training -------------------------------------
Invoke-Step 'Schritt 3/3: YOLO11n OBB Training (imgsz=640, batch=8, epochs=40)' {
    uv run python -m ml.detector.train `
        --data datasets/cards_obb/data.yaml `
        --epochs 40 `
        --imgsz 640 `
        --batch 8
}

Write-Section 'FERTIG'
$summary = @"
Alle Schritte erfolgreich.
Best-Weights:    runs/detector/yolo11n_obb_cards/weights/best.pt
ONNX-Export:     runs/detector/yolo11n_obb_cards/weights/best.onnx
Logfile:         $logFile
Ende:            $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
"@
Add-Content -Path $logFile -Value $summary
Write-Host $summary -ForegroundColor Green
