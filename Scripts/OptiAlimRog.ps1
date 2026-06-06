#Requires -RunAsAdministrator
# ================================================================
# ASUS ROG Fix Kit v1.0 - Optimisations Windows / Windows Optimizations
# Description FR: Corrections problemes connus ASUS ROG/TUF 2021-2025
# Description EN: Known issue fixes for ASUS ROG/TUF 2021-2025
# Bugs corriges / Fixed:
#   - Freeze/stutter ACPI toutes 30-60s (PCIe Power Mgmt OFF)
#   - RGB bugue au boot (Fast Startup OFF)
#   - CPU throttle a 45/55W (Plan Haute Performance)
#   - Deconnexions USB (USB Selective Suspend OFF)
# Usage: PowerShell en Administrateur / Run as Administrator
# Ref: github.com/Zephkek/Asus-ROG-Aml-Deep-Dive
# ================================================================

$Plan = (powercfg /getactivescheme).Split()[3]
Write-Host "Plan actif / Active plan: $Plan" -ForegroundColor Cyan
Write-Host ""

# [1/8] Fast Startup OFF -- corrige RGB + power states au boot
Write-Host "[1/8] Fast Startup..." -ForegroundColor Yellow
REG ADD "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" /V HiberbootEnabled /T REG_DWORD /D 0 /F | Out-Null
Write-Host "      OK" -ForegroundColor Green

# [2/8] PCIe Power Management OFF -- cause principale des freezes ACPI
Write-Host "[2/8] PCIe Power Management (freeze fix)..." -ForegroundColor Yellow
powercfg -setacvalueindex $Plan 2a737441-1930-4402-8d77-b2bebba308a3 ee12f906-d277-404b-b6da-e5fa1a576df5 0
powercfg -setdcvalueindex $Plan 2a737441-1930-4402-8d77-b2bebba308a3 ee12f906-d277-404b-b6da-e5fa1a576df5 0
powercfg -setactive $Plan
Write-Host "      OK" -ForegroundColor Green

# [3/8] Plan Haute Performance -- corrige throttle CPU a 45/55W
Write-Host "[3/8] Plan Haute Performance..." -ForegroundColor Yellow
powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
Write-Host "      OK" -ForegroundColor Green

# [4/8] USB Selective Suspend OFF -- corrige deconnexions peripheriques
Write-Host "[4/8] USB Selective Suspend..." -ForegroundColor Yellow
powercfg -setacvalueindex $Plan 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0
powercfg -setdcvalueindex $Plan 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0
Write-Host "      OK" -ForegroundColor Green

# [5/8] Hibernation OFF -- libere ~32Go disque (= taille RAM)
Write-Host "[5/8] Hibernation..." -ForegroundColor Yellow
powercfg /hibernate off
Write-Host "      OK (+32Go liberes / freed)" -ForegroundColor Green

# [6/8] Timer Resolution -- reduit micro-stutters en jeu
Write-Host "[6/8] Timer Resolution..." -ForegroundColor Yellow
REG ADD "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\kernel" /V GlobalTimerResolutionRequests /T REG_DWORD /D 1 /F | Out-Null
Write-Host "      OK" -ForegroundColor Green

# [7/8] Nagle OFF -- reduit latence reseau en jeu
Write-Host "[7/8] Network latency (Nagle OFF)..." -ForegroundColor Yellow
Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces" | ForEach-Object {
    try {
        Set-ItemProperty -Path $_.PSPath -Name "TcpAckFrequency" -Value 1 -Type DWord -EA SilentlyContinue
        Set-ItemProperty -Path $_.PSPath -Name "TCPNoDelay" -Value 1 -Type DWord -EA SilentlyContinue
    } catch {}
}
Write-Host "      OK" -ForegroundColor Green

# [8/8] Maintenance Windows OFF -- evite les interferences en jeu
Write-Host "[8/8] Windows Maintenance..." -ForegroundColor Yellow
REG ADD "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance" /V MaintenanceDisabled /T REG_DWORD /D 1 /F | Out-Null
Write-Host "      OK" -ForegroundColor Green

Write-Host ""
Write-Host "TERMINE / DONE ! Redemarrez / Restart now." -ForegroundColor Green