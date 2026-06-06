# ================================================================
# ASUS ROG Fix Kit - Diagnostic Systeme / System Diagnostic
# Description FR: Verifie l'etat des corrections appliquees
# Description EN: Checks status of applied fixes
# Telecharger LatencyMon pour diagnostic DPC complet
# Download LatencyMon for full DPC diagnostic
# ================================================================

Write-Host "=== ASUS ROG Fix Kit - Diagnostic ===" -ForegroundColor Cyan
Write-Host ""

# Infos machine / Machine info
$Model = (Get-WmiObject Win32_ComputerSystem).Model
$BIOS  = (Get-WmiObject Win32_BIOS).SMBIOSBIOSVersion
$CPU   = (Get-WmiObject Win32_Processor).Name
Write-Host "Modele / Model : $Model"   -ForegroundColor White
Write-Host "BIOS Version   : $BIOS"    -ForegroundColor White
Write-Host "CPU            : $CPU"     -ForegroundColor White
Write-Host ""

# Statut des corrections / Fix status
Write-Host "--- STATUT DES CORRECTIONS / FIX STATUS ---" -ForegroundColor Yellow

# Fast Startup
$FS = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name HiberbootEnabled -EA SilentlyContinue).HiberbootEnabled
$msg = if ($FS -eq 0) {"OK  - Fast Startup desactive"} else {"FAIL - Fast Startup ACTIF (lancer script Windows)"}
Write-Host $msg -ForegroundColor $(if ($FS -eq 0) {"Green"} else {"Red"})

# Hibernation
$Hib = Test-Path "$env:SystemDrive\hiberfil.sys"
$msg = if (-not $Hib) {"OK  - Hibernation desactivee"} else {"WARN - Hibernation active (liberer ~32Go)"}
Write-Host $msg -ForegroundColor $(if (-not $Hib) {"Green"} else {"Yellow"})

# Power Plan
$PP = (powercfg /getactivescheme)
Write-Host "INFO - Plan alimentation: $PP" -ForegroundColor Cyan

Write-Host ""
Write-Host "--- SERVICES ASUS ACTIFS / ACTIVE ASUS SERVICES ---" -ForegroundColor Yellow
$svcs = Get-Service | Where-Object {$_.Name -like "*asus*" -or $_.Name -like "*armoury*"}
if ($svcs) {
    $svcs | ForEach-Object {
        $c = if ($_.Status -eq "Running") {"Yellow"} else {"DarkGray"}
        Write-Host "  [$($_.Status.ToString().PadRight(7))] $($_.Name)" -ForegroundColor $c
    }
} else {
    Write-Host "  OK - Aucun service Armoury/ASUS (mode G-Helper propre)" -ForegroundColor Green
}

Write-Host ""
Write-Host "--- LATENCYMON THRESHOLDS ---" -ForegroundColor Yellow
Write-Host "  OK   < 250  us  -- Excellent, gaming/audio parfait" -ForegroundColor Green
Write-Host "  WARN < 600  us  -- Acceptable, stutters possibles" -ForegroundColor Yellow
Write-Host "  FAIL > 1000 us  -- Probleme ACPI/PCIe actif" -ForegroundColor Red
Write-Host "  CRIT > 5000 us  -- Storm ACPI confirme, bug BIOS" -ForegroundColor DarkRed
Write-Host ""
Write-Host "Telecharger LatencyMon / Download LatencyMon:" -ForegroundColor Gray
Write-Host "  https://www.resplendent.com/downloads/LatencyMon.exe" -ForegroundColor Cyan