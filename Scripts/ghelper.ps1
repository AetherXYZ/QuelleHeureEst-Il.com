# ================================================================
# ASUS ROG Fix Kit - Installation G-Helper
# Description FR: Alternative legere a Armoury Crate
# Description EN: Lightweight alternative to Armoury Crate
# Ref: https://github.com/seerge/g-helper
# ================================================================

Write-Host "=== Installation G-Helper ===" -ForegroundColor Cyan

# Verifier winget / Check winget availability
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Host "winget requis. Installez 'App Installer' depuis le Microsoft Store." -ForegroundColor Red
    Write-Host "winget required. Install 'App Installer' from Microsoft Store." -ForegroundColor Red
    Start-Process "ms-windows-store://pdp/?ProductId=9NBLGGH4NNS1"
    Exit 1
}

Write-Host "Installation en cours... / Installing..." -ForegroundColor Yellow
winget install --id seerge.g-helper -e --accept-package-agreements --accept-source-agreements

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "OK G-Helper installe! / installed!" -ForegroundColor Green
    Write-Host ""
    Write-Host "CONFIGURATION RECOMMANDEE / RECOMMENDED SETTINGS" -ForegroundColor Cyan
    Write-Host "  Mode (branche/plugged)  : Performance" -ForegroundColor White
    Write-Host "  Mode (batterie/battery) : Balanced ou Silent" -ForegroundColor White
    Write-Host "  Battery Limit           : 80% (vie batterie / battery lifespan)" -ForegroundColor White
    Write-Host "  GPU Mode                : Ultimate (branche) / Optimized (batt.)" -ForegroundColor White
    Write-Host "  Undervolt CPU           : Commencer -75mV, tester, puis -100mV" -ForegroundColor White
    Write-Host "  Fan curve               : Full speed (6000+ rpm) au-dessus 75 C" -ForegroundColor White
    Write-Host ""
    Write-Host "! Testez l'undervolt par paliers de -25mV / Test in -25mV steps" -ForegroundColor Yellow
} else {
    Write-Host "Echec winget. Telechargement manuel / Manual download:" -ForegroundColor Yellow
    Start-Process "https://github.com/seerge/g-helper/releases/latest"
    Write-Host "Page GitHub ouverte / GitHub page opened." -ForegroundColor Cyan
}