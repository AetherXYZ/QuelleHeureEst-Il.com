#Requires -RunAsAdministrator
# ================================================================
# ASUS ROG Fix Kit - Desinstallation Armoury Crate
# Description FR: Suppression propre d'Armoury Crate et ses services
# Description EN: Clean removal of Armoury Crate and its services
# IMPORTANT: Redemarrez apres / Restart after execution
# Remplacez par G-Helper / Replace with G-Helper
# ================================================================

Write-Host "=== Desinstallation Armoury Crate ===" -ForegroundColor Red
$ok = Read-Host "Continuer? (o/y pour oui/yes -- n pour annuler/cancel)"
if ($ok -notmatch '^[oOyY]') { Write-Host "Annule / Cancelled."; Exit 0 }

# [1/4] Arret des services ASUS / Stop ASUS services
Write-Host "[1/4] Arret services / Stopping services..." -ForegroundColor Yellow
@("ArmouryCrateControlInterface","ASUS_SOFTWARE_MANAGER","AsusAppService",
  "AsusCertService","asus_framework","ASUSOptimization","ASUSLinkerService") | ForEach-Object {
    if (Get-Service $_ -EA SilentlyContinue) {
        Stop-Service $_ -Force -EA SilentlyContinue
        Set-Service $_ -StartupType Disabled -EA SilentlyContinue
        Write-Host "  Stop: $_" -ForegroundColor DarkGray
    }
}

# [2/4] Desinstallation via winget / Winget uninstall
Write-Host "[2/4] Winget uninstall..." -ForegroundColor Yellow
@("ASUS.ArmouryCrate","Armoury Crate","Armoury Crate Service") | ForEach-Object {
    winget uninstall $_ --silent --accept-source-agreements 2>$null
}

# [3/4] Nettoyage fichiers residuels / Residual file cleanup
Write-Host "[3/4] Nettoyage fichiers / File cleanup..." -ForegroundColor Yellow
@("$env:LOCALAPPDATA\ASUS\ArmouryCrate",
  "$env:PROGRAMFILES\ASUS\ArmouryCrate",
  "$env:PROGRAMDATA\ASUS") | ForEach-Object {
    if (Test-Path $_) { Remove-Item $_ -Recurse -Force -EA SilentlyContinue; Write-Host "  Del: $_" }
}

# [4/4] Nettoyage registre / Registry cleanup
Write-Host "[4/4] Nettoyage registre / Registry cleanup..." -ForegroundColor Yellow
@("HKCU:\Software\ASUS\ArmouryCrate",
  "HKLM:\SOFTWARE\ASUS\ArmouryCrate",
  "HKLM:\SOFTWARE\WOW6432Node\ASUS\ArmouryCrate") | ForEach-Object {
    if (Test-Path $_) { Remove-Item $_ -Recurse -Force -EA SilentlyContinue; Write-Host "  Del: $_" }
}

Write-Host ""
Write-Host "OK Armoury Crate supprime / removed" -ForegroundColor Green
Write-Host "! Redemarrez AVANT d'installer G-Helper / Restart BEFORE G-Helper" -ForegroundColor Yellow