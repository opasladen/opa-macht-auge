# Opa macht Auge – Admin-Setup
# Aktiviert WSL2-Features und installiert Docker Desktop + Flutter via winget.

# Sofort-Marker (vor allem anderen), damit wir sehen, ob das Script überhaupt geladen wurde
$marker = "$env:TEMP\opa-setup-started.txt"
"started $(Get-Date -Format o) admin=$(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))" |
    Out-File -FilePath $marker -Encoding utf8 -Append

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Dieses Script muss mit Admin-Rechten laufen. Abbruch." -ForegroundColor Red
    [void][System.Console]::ReadLine()
    exit 1
}

$ErrorActionPreference = 'Stop'
$transcript = Join-Path $env:TEMP "opa-setup-$(Get-Date -Format yyyyMMdd-HHmmss).log"
Start-Transcript -Path $transcript -Append | Out-Null

function Write-Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }

try {
    Write-Step "1/4 Windows-Features prüfen"
    $features = 'VirtualMachinePlatform','Microsoft-Windows-Subsystem-Linux'
    $needsReboot = $false
    foreach ($f in $features) {
        $state = (Get-WindowsOptionalFeature -Online -FeatureName $f).State
        Write-Host "$f : $state"
        if ($state -ne 'Enabled') {
            Write-Host "Aktiviere $f ..." -ForegroundColor Yellow
            $r = Enable-WindowsOptionalFeature -Online -FeatureName $f -NoRestart -All
            if ($r.RestartNeeded) { $needsReboot = $true }
        }
    }

    Write-Step "2/4 Docker Desktop installieren"
    $dockerInstalled = winget list --id Docker.DockerDesktop --exact --accept-source-agreements 2>$null | Select-String 'Docker.DockerDesktop'
    if ($dockerInstalled) {
        Write-Host "Docker Desktop bereits installiert."
    } else {
        winget install --id Docker.DockerDesktop --exact --silent --accept-source-agreements --accept-package-agreements
    }

    Write-Step "3/4 Flutter SDK nach G:\flutter installieren"
    if (Test-Path 'G:\flutter\bin\flutter.bat') {
        Write-Host "Flutter bereits unter G:\flutter vorhanden."
    } else {
        # winget Flutter.Flutter unterstützt --location; falls nicht: Fallback per Direktdownload
        $wingetOk = $false
        try {
            winget install --id Flutter.Flutter --exact --silent --location 'G:\flutter' --accept-source-agreements --accept-package-agreements
            if (Test-Path 'G:\flutter\bin\flutter.bat') { $wingetOk = $true }
        } catch {
            Write-Host "winget-Install fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Yellow
        }
        if (-not $wingetOk) {
            Write-Host "Fallback: Flutter stable ZIP direkt laden..." -ForegroundColor Yellow
            $zip = Join-Path $env:TEMP 'flutter_stable.zip'
            $url = 'https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_3.24.5-stable.zip'
            Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
            Expand-Archive -Path $zip -DestinationPath 'G:\' -Force
            Remove-Item $zip
        }
    }

    Write-Step "4/4 PATH für Flutter ergänzen (User-Scope)"
    $flutterBin = 'G:\flutter\bin'
    if (Test-Path $flutterBin) {
        $userPath = [Environment]::GetEnvironmentVariable('Path','User')
        if ($userPath -notlike "*$flutterBin*") {
            [Environment]::SetEnvironmentVariable('Path', "$userPath;$flutterBin", 'User')
            Write-Host "PATH aktualisiert."
        } else {
            Write-Host "PATH enthält Flutter bereits."
        }
    }

    Write-Host "`n--- FERTIG ---" -ForegroundColor Green
    if ($needsReboot) {
        Write-Host "REBOOT erforderlich (Windows-Feature aktiviert)." -ForegroundColor Yellow
    }
    Write-Host "Transcript: $transcript"
}
catch {
    Write-Host "FEHLER: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace
}
finally {
    Stop-Transcript | Out-Null
    Write-Host "`nFenster bleibt offen. Enter zum Schließen."
    [void][System.Console]::ReadLine()
}
