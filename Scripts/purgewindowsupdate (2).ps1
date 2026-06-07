﻿<#
.SYNOPSIS
    Masquer des mises à jour Windows, purger les caches et redémarrer.
.DESCRIPTION
    1. Tue les processus WU qui verrouillent les fichiers (TiWorker, MoUsoCoreWorker...).
    2. Desactive temporairement les services pour empecher leur auto-redemarrage.
    3. Arrête et verifie l arret effectif avec retry.
    4. Liste et masque les mises a jour via PSWindowsUpdate.
    5. Supprime SoftwareDistribution, catroot2, caches BITS et DeliveryOptimization.
    6. Re-enregistre les DLLs Windows Update.
    7. Remet les services en mode Manuel (WU peut rebuilder son cache au prochain scan).
    8. Propose un redémarrage.
    Un journal complet est enregistré dans le dossier courant.
.NOTES
    Exécuter en tant qu'administrateur.
    Les mises à jour masquées le resteront après la purge car l'information
    est stockée dans le registre Windows, pas dans les dossiers de cache.
#>

#---------------------------------------------------------------------#
#   FR//  DEMARRAGE : verification admin + transcription              #
#  ENG//  STARTUP  : admin check + transcript                        #
#---------------------------------------------------------------------#

if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]"Administrator")) {
    Write-Host "ERREUR : Ce script doit être exécuté en tant qu'administrateur." -ForegroundColor Red
    exit 1
}

#--------------------------------------------------------------------------------#
#   FR//  CONFIGURATION : IDs materiels a bloquer dans Windows Update            #
#         Modifier ce tableau pour chaque machine.                               #
#  ENG//  CONFIGURATION : hardware IDs to block from Windows Update              #
#         Modify this array per machine.                                         #
#--------------------------------------------------------------------------------#

$HardwareIDsToBlock = @(
    "PCI\VEN_8086&DEV_A788&SUBSYS_34A81043&REV_04",
    "PCI\VEN_8086&DEV_A788&CC_038000"
)

#  FR// Configuration du journal dans le dossier courant
# ENG// Log configuration in the current folder
$logPath = Join-Path $PSScriptRoot "WU_Masquage_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
Start-Transcript -Path $logPath -Append
Write-Host "Journal démarré dans le dossier courant : $logPath" -ForegroundColor Cyan

Clear-Host
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  MASQUAGE GUIDÉ + PURGE + REDÉMARRAGE" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

#  FR// Services à gérer (ordre d'arrêt important : wuauserv en premier)
# ENG// Services to manage (stop order matters : wuauserv first)
$allServices = @("wuauserv", "bits", "cryptsvc", "msiserver", "dosvc", "UsoSvc", "WaaSMedicSvc")

#  FR// Processus WU connus pour verrouiller les fichiers ESE / SoftwareDistribution
# ENG// WU processes known to lock ESE files / SoftwareDistribution
$wuProcesses = @(
    "TiWorker",
    "TrustedInstaller",
    "MoUsoCoreWorker",
    "WaaSMedicAgent",
    "UsoClient",
    "musnotification",
    "musnotifyicon"
)

#---------------------------------------------------------------------#
#   FR//  ETAPE 1 : Tuer les processus WU qui verrouillent les        #
#         fichiers avant toute tentative d arret de service.          #
#         Sans ca, dosvc et wuauserv se relancent immediatement       #
#         ou les fichiers ESE restent verrouilles.                    #
#                                                                     #
#  ENG//  STEP 1 : Kill WU processes that lock files before any       #
#         service stop attempt. Without this, dosvc and wuauserv      #
#         restart immediately or ESE files stay locked.               #
#---------------------------------------------------------------------#

Write-Host "[ETAPE 1/7] Arret des processus Windows Update en cours..." -ForegroundColor Yellow

foreach ($proc in $wuProcesses) {
    $running = Get-Process -Name $proc -ErrorAction SilentlyContinue
    if ($running) {
        try {
            Stop-Process -Name $proc -Force -ErrorAction Stop
            Write-Host "  [OK] $proc arrete (PID $($running.Id))." -ForegroundColor Green
        } catch {
            #  FR// Fallback via taskkill si Stop-Process echoue (processus protege)
            # ENG// Fallback via taskkill if Stop-Process fails (protected process)
            $tk = & taskkill /f /im "$proc.exe" 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  [OK] $proc arrete via taskkill." -ForegroundColor Green
            } else {
                Write-Host "  [!!] Impossible d arret $proc (processus protege, on continue) : $_" -ForegroundColor DarkYellow
            }
        }
    } else {
        Write-Host "  [-] $proc non actif." -ForegroundColor Gray
    }
}

#  FR// Pause courte pour laisser les handles se liberer apres kill
# ENG// Short pause to let handles release after kills
Start-Sleep -Seconds 2

#---------------------------------------------------------------------#
#   FR//  ETAPE 2 : Desactiver les services (Disabled) AVANT de les   #
#         arreter. C est le seul moyen fiable d empecher wuauserv et  #
#         dosvc de se relancer automatiquement entre l arret et la    #
#         verification d etat.                                        #
#         On sauvegarde le StartType original pour le restaurer.      #
#                                                                     #
#  ENG//  STEP 2 : Set services to Disabled BEFORE stopping them.     #
#         This is the only reliable way to prevent wuauserv and       #
#         dosvc from auto-restarting between stop and status check.   #
#         We save the original StartType to restore it afterwards.    #
#---------------------------------------------------------------------#

Write-Host "" 
Write-Host "[ETAPE 2/7] Desactivation temporaire des services (anti-relance auto)..." -ForegroundColor Yellow

$originalStartTypes = @{}

foreach ($svc in $allServices) {
    $service = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if (-not $service) { continue }

    #  FR// Sauvegarder le StartType original avant modification
    # ENG// Save original StartType before modifying
    try {
        $wmiSvc = Get-WmiObject Win32_Service -Filter "Name='$svc'" -ErrorAction SilentlyContinue
        if ($wmiSvc) {
            $originalStartTypes[$svc] = $wmiSvc.StartMode
        }
    } catch {}

    #  FR// Passer en Disabled pour bloquer tout redemarrage automatique
    # ENG// Set to Disabled to block any automatic restart
    try {
        Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
        Write-Host "  [OK] $svc desactive temporairement." -ForegroundColor Green
    } catch {
        #  FR// Fallback via sc.exe si Set-Service echoue (WaaSMedicSvc est protege)
        # ENG// Fallback via sc.exe if Set-Service fails (WaaSMedicSvc is protected)
        $sc = & sc.exe config $svc start= disabled 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  [OK] $svc desactive via sc.exe." -ForegroundColor Green
        } else {
            Write-Host "  [!!] $svc non desactivable (protege) : $_" -ForegroundColor DarkYellow
        }
    }
}

#---------------------------------------------------------------------#
#   FR//  ETAPE 3 : Arreter les services avec retry et fallbacks.     #
#         On utilise Stop-Service, puis sc.exe stop, puis taskkill    #
#         sur le svchost hebergeant le service si tout echoue.        #
#                                                                     #
#  ENG//  STEP 3 : Stop services with retry and fallbacks.            #
#         We use Stop-Service, then sc.exe stop, then taskkill on     #
#         the hosting svchost if everything else fails.               #
#---------------------------------------------------------------------#

Write-Host ""
Write-Host "[ETAPE 3/7] Arret des services Windows Update..." -ForegroundColor Yellow

#  FR// Purger la file BITS avant d arret pour eviter les verrous residuels
# ENG// Purge BITS queue before stopping to avoid residual locks
try {
    Get-BitsTransfer -AllUsers -ErrorAction SilentlyContinue | Remove-BitsTransfer -ErrorAction SilentlyContinue
    Write-Host "  [OK] File d attente BITS purgee." -ForegroundColor Green
} catch {}

foreach ($svc in $allServices) {
    $service = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if (-not $service) { continue }
    if ($service.Status -eq "Stopped") {
        Write-Host "  [-] $svc deja arrete." -ForegroundColor Gray
        continue
    }

    $stopped = $false

    #  FR// Tentative 1 : Stop-Service natif
    # ENG// Attempt 1 : native Stop-Service
    try {
        Stop-Service -Name $svc -Force -ErrorAction Stop
        Start-Sleep -Milliseconds 800
        $stopped = (Get-Service -Name $svc -ErrorAction SilentlyContinue).Status -eq "Stopped"
        if ($stopped) { Write-Host "  [OK] $svc arrete." -ForegroundColor Green }
    } catch {}

    #  FR// Tentative 2 : sc.exe stop (plus direct que Stop-Service sur les services proteges)
    # ENG// Attempt 2 : sc.exe stop (more direct than Stop-Service on protected services)
    if (-not $stopped) {
        $sc = & sc.exe stop $svc 2>&1
        Start-Sleep -Seconds 2
        $stopped = (Get-Service -Name $svc -ErrorAction SilentlyContinue).Status -eq "Stopped"
        if ($stopped) {
            Write-Host "  [OK] $svc arrete via sc.exe." -ForegroundColor Green
        }
    }

    #  FR// Tentative 3 : tuer le svchost qui heberge ce service
    # ENG// Attempt 3 : kill the svchost hosting this service
    if (-not $stopped) {
        Write-Host "  [!!] $svc resistant, recherche du svchost hebergeur..." -ForegroundColor DarkYellow
        try {
            $svcPid = (Get-WmiObject Win32_Service -Filter "Name='$svc'" -ErrorAction SilentlyContinue).ProcessId
            if ($svcPid -and $svcPid -gt 0) {
                Stop-Process -Id $svcPid -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 1
                $stopped = (Get-Service -Name $svc -ErrorAction SilentlyContinue).Status -eq "Stopped"
                if ($stopped) {
                    Write-Host "  [OK] $svc arrete via kill svchost PID $svcPid." -ForegroundColor Green
                } else {
                    Write-Host "  [!!] $svc toujours actif malgre tout (service protege OS)." -ForegroundColor Red
                }
            }
        } catch {
            Write-Host "  [!!] Impossible d'identifier le svchost de $svc : $_" -ForegroundColor Red
        }
    }
}

#  FR// Verification finale de l arret - on attend max 10s
# ENG// Final stop verification - we wait up to 10s
Write-Host ""
Write-Host "Verification de l etat final des services :" -ForegroundColor White
$retryWait = 10
$servicesOK = $true
foreach ($svc in $allServices) {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if (-not $s) { continue }
    $waited = 0
    while ($s.Status -ne "Stopped" -and $waited -lt $retryWait) {
        Start-Sleep -Seconds 1
        $waited++
        $s.Refresh()
    }
    if ($s.Status -ne "Stopped") {
        Write-Host "  [!!] $svc non arrete (Etat: $($s.Status)) - purge partielle possible" -ForegroundColor Red
        $servicesOK = $false
    } else {
        Write-Host "  [OK] $svc arrete." -ForegroundColor Green
    }
}

if (-not $servicesOK) {
    Write-Host ""
    Write-Host "  [!!] Certains services resistants - la purge continuera mais peut etre incomplete." -ForegroundColor DarkYellow
    Write-Host "       Conseil : redemarrer en Safe Mode pour une purge garantie a 100%." -ForegroundColor Gray
}

#  FR// Pause de securite apres arret - laisse les handles fichiers se liberer
# ENG// Safety pause after stop - lets file handles release
Write-Host ""
Write-Host "Pause de securite (5s) pour liberation des handles fichiers..." -ForegroundColor Gray
Start-Sleep -Seconds 5

#---------------------------------------------------------------------#
#   FR//  ETAPE 4 : Lister et masquer les mises a jour selectionnees  #
#         via PSWindowsUpdate.                                        #
#                                                                     #
#  ENG//  STEP 4 : List and hide selected updates via                 #
#         PSWindowsUpdate.                                            #
#---------------------------------------------------------------------#

Write-Host ""
Write-Host "[ETAPE 4/7] Preparation module PSWindowsUpdate..." -ForegroundColor Yellow

if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
    Write-Host "  Installation du module PSWindowsUpdate..." -ForegroundColor Cyan
    try {
        Install-Module -Name PSWindowsUpdate -Force -Scope CurrentUser -ErrorAction Stop
        Write-Host "  [OK] Module installe." -ForegroundColor Green
    } catch {
        Write-Host "  [ERR] Echec installation : $_" -ForegroundColor Red
        Write-Host "  Continuer sans masquage de mises a jour." -ForegroundColor DarkYellow
    }
}

#  FR// Relancer wuauserv brievement pour le scan PSWindowsUpdate, puis re-arreter
# ENG// Briefly restart wuauserv for PSWindowsUpdate scan, then stop again
Write-Host "  Relance breve de wuauserv pour le scan..." -ForegroundColor Gray
try {
    Set-Service -Name "wuauserv" -StartupType Manual -ErrorAction SilentlyContinue
    Start-Service -Name "wuauserv" -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
} catch {}

Import-Module PSWindowsUpdate -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "[Selection des mises a jour a masquer]" -ForegroundColor Yellow
Write-Host ""

$updates = Get-WindowsUpdate -IsInstalled:$false -ErrorAction SilentlyContinue

if (-not $updates -or $updates.Count -eq 0) {
    Write-Host "  Aucune mise a jour disponible trouvee." -ForegroundColor Green
} else {
    $continue = $true
    while ($continue -and $updates.Count -gt 0) {
        Write-Host "Mises a jour disponibles :" -ForegroundColor White
        Write-Host ("{0,-4} {1,-12} {2,-14} {3}" -f "N.", "KB", "Taille", "Titre") -ForegroundColor Gray
        Write-Host ("{0,-4} {1,-12} {2,-14} {3}" -f "--", "--", "------", "-----") -ForegroundColor Gray
        for ($i = 0; $i -lt $updates.Count; $i++) {
            $kb   = if ($updates[$i].KB)   { $updates[$i].KB }   else { "N/A" }
            $size = if ($updates[$i].Size) { "$([math]::Round($updates[$i].Size/1MB,0)) MB" } else { "N/A" }
            Write-Host ("{0,-4} {1,-12} {2,-14} {3}" -f ($i+1), $kb, $size, $updates[$i].Title)
        }
        Write-Host ""
        Write-Host "Numeros a masquer (ex: 1,3,5), A pour tout masquer, ou Q pour passer :" -ForegroundColor Cyan
        $choice = Read-Host

        if ($choice -eq "Q" -or $choice -eq "q") { $continue = $false; break }

        #  FR// "A" = masquer toutes les mises a jour listees
        # ENG// "A" = hide all listed updates
        if ($choice -eq "A" -or $choice -eq "a") {
            $numbers = 1..$updates.Count
        } else {
            $numbers = $choice -split "," |
                ForEach-Object { $_.Trim() } |
                Where-Object { $_ -match "^\d+$" } |
                ForEach-Object { [int]$_ } |
                Where-Object { $_ -ge 1 -and $_ -le $updates.Count } |
                Sort-Object -Unique -Descending
        }

        if ($numbers.Count -eq 0) {
            Write-Host "  [!!] Aucun numero valide. Entrer des chiffres, A ou Q." -ForegroundColor DarkYellow
            continue
        }

        $selectedUpdates = @($numbers | ForEach-Object { $updates[$_ - 1] })

        foreach ($selected in $selectedUpdates) {
            Write-Host "  Masquage : $($selected.Title)" -ForegroundColor Yellow
            $hidden = $false
            #  FR// Tentative 1 : par titre
            # ENG// Attempt 1 : by title
            try {
                Hide-WindowsUpdate -Title $selected.Title -Confirm:$false -ErrorAction Stop
                Write-Host "    [OK] Masque." -ForegroundColor Green
                $hidden = $true
            } catch {}
            #  FR// Tentative 2 : par UpdateID (plus fiable si le titre contient des caracteres speciaux)
            # ENG// Attempt 2 : by UpdateID (more reliable if title has special chars)
            if (-not $hidden) {
                try {
                    Hide-WindowsUpdate -UpdateID $selected.Identity.UpdateID `
                        -RevisionNumber $selected.Identity.RevisionNumber `
                        -Confirm:$false -ErrorAction Stop
                    Write-Host "    [OK] Masque via UpdateID." -ForegroundColor Green
                    $hidden = $true
                } catch {
                    Write-Host "    [ERR] Echec masquage : $_" -ForegroundColor Red
                }
            }
            if ($hidden) {
                $updates = $updates | Where-Object { $_.Title -ne $selected.Title }
            }
        }
        Write-Host ""
    }
}

#  FR// Re-arreter wuauserv apres le scan
# ENG// Stop wuauserv again after the scan
try {
    Set-Service -Name "wuauserv" -StartupType Disabled -ErrorAction SilentlyContinue
    Stop-Service -Name "wuauserv" -Force -ErrorAction SilentlyContinue
} catch {}
Start-Sleep -Seconds 2

#---------------------------------------------------------------------#
#   FR//  ETAPE 5 : Purge des caches WU.                              #
#         Strategie : renommer SoftwareDistribution et catroot2        #
#         plutot que supprimer directement, pour contourner les        #
#         verrous ESE residuels. Les dossiers .old seront supprimes    #
#         en meme temps, ou au reboot via PendingFileRenameOperations.  #
#                                                                     #
#  ENG//  STEP 5 : WU cache purge.                                    #
#         Strategy : rename SoftwareDistribution and catroot2          #
#         instead of direct delete, to bypass residual ESE locks.      #
#         The .old folders are deleted simultaneously or at reboot     #
#         via PendingFileRenameOperations.                             #
#---------------------------------------------------------------------#

Write-Host ""
Write-Host "[ETAPE 5/7] Purge des caches Windows Update..." -ForegroundColor Yellow

function Remove-FolderWithFallback {
    #   FR//  Supprimer un dossier via PS, puis cmd, puis planifier au reboot si tout echoue
    #  ENG//  Delete a folder via PS, then cmd, then schedule at reboot if all else fails
    param([string]$Path, [string]$Label)

    if (-not (Test-Path $Path)) {
        Write-Host "  [-] $Label absent : $Path" -ForegroundColor Gray
        return
    }

    #   FR//  Tentative 1 : Remove-Item PowerShell
    #  ENG//  Attempt 1 : Remove-Item PowerShell
    try {
        Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
        Write-Host "  [OK] $Label supprime." -ForegroundColor Green
        return
    } catch {}

    #   FR//  Tentative 2 : rmdir via cmd
    #  ENG//  Attempt 2 : rmdir via cmd
    & cmd /c "rmdir /s /q `"$Path`"" 2>$null
    if (-not (Test-Path $Path)) {
        Write-Host "  [OK] $Label supprime via cmd." -ForegroundColor Green
        return
    }

    #   FR//  Tentative 3 : planifier la suppression au prochain reboot via le registre
    #        PendingFileRenameOperations est traite par SMSS.EXE au boot avant WU
    #  ENG//  Attempt 3 : schedule deletion at next reboot via registry
    #        PendingFileRenameOperations is processed by SMSS.EXE at boot before WU
    Write-Host "  [!!] $Label verrouille - suppression planifiee au prochain reboot." -ForegroundColor DarkYellow
    try {
        $regKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager"
        $existing = (Get-ItemProperty -Path $regKey -Name "PendingFileRenameOperations" -ErrorAction SilentlyContinue).PendingFileRenameOperations
        #  FR// Format : paire source/"" = suppression au boot
        # ENG// Format : source/"" pair = deletion at boot
        $newEntry = @("\??\$Path", "")
        if ($existing) {
            $merged = $existing + $newEntry
        } else {
            $merged = $newEntry
        }
        Set-ItemProperty -Path $regKey -Name "PendingFileRenameOperations" -Value $merged -Type MultiString -ErrorAction Stop
        Write-Host "    [OK] Suppression de $Label planifiee au reboot (SMSS)." -ForegroundColor Cyan
    } catch {
        Write-Host "    [ERR] Impossible de planifier la suppression : $_" -ForegroundColor Red
    }
}

#   FR//  SoftwareDistribution : renommer d abord pour liberer le verrou ESE,
#        puis supprimer le dossier renomme (le nouveau nom n est pas verrouille)
#  ENG//  SoftwareDistribution : rename first to break the ESE lock,
#        then delete the renamed folder (new name is not locked)
$sdPath    = "$env:SystemRoot\SoftwareDistribution"
$sdOldPath = "$env:SystemRoot\SoftwareDistribution.old"

if (Test-Path $sdPath) {
    #   FR// Nettoyer un eventuel .old residuel d une purge precedente
    #  ENG// Clean up any residual .old from a previous purge
    if (Test-Path $sdOldPath) {
        Remove-FolderWithFallback -Path $sdOldPath -Label "SoftwareDistribution.old (residuel)"
    }
    try {
        Rename-Item -Path $sdPath -NewName "SoftwareDistribution.old" -Force -ErrorAction Stop
        Write-Host "  [OK] SoftwareDistribution isole (renomme en .old)." -ForegroundColor Green
        Remove-FolderWithFallback -Path $sdOldPath -Label "SoftwareDistribution.old"
    } catch {
        Write-Host "  [!!] Renommage impossible, suppression directe..." -ForegroundColor DarkYellow
        Remove-FolderWithFallback -Path $sdPath -Label "SoftwareDistribution"
    }
} else {
    Write-Host "  [-] SoftwareDistribution absent (deja supprime)." -ForegroundColor Gray
}

#   FR//  catroot2 : meme strategie renommer avant supprimer
#  ENG//  catroot2 : same rename-before-delete strategy
$catrootPath    = "$env:SystemRoot\System32\catroot2"
$catrootOldPath = "$env:SystemRoot\System32\catroot2.old"

if (Test-Path $catrootPath) {
    if (Test-Path $catrootOldPath) {
        Remove-FolderWithFallback -Path $catrootOldPath -Label "catroot2.old (residuel)"
    }
    try {
        Rename-Item -Path $catrootPath -NewName "catroot2.old" -Force -ErrorAction Stop
        Write-Host "  [OK] catroot2 isole (renomme en .old)." -ForegroundColor Green
        Remove-FolderWithFallback -Path $catrootOldPath -Label "catroot2.old"
    } catch {
        Write-Host "  [!!] Renommage catroot2 impossible, suppression directe..." -ForegroundColor DarkYellow
        Remove-FolderWithFallback -Path $catrootPath -Label "catroot2"
    }
} else {
    Write-Host "  [-] catroot2 absent." -ForegroundColor Gray
}

#  FR// Autres caches annexes
# ENG// Other ancillary caches
$extraCaches = @(
    @{ Path = "$env:ALLUSERSPROFILE\Microsoft\Network\Downloader";       Label = "Cache BITS (Downloader)" },
    @{ Path = "$env:ProgramData\Microsoft\Windows\DeliveryOptimization"; Label = "Cache DeliveryOptimization" }
)
foreach ($c in $extraCaches) {
    Remove-FolderWithFallback -Path $c.Path -Label $c.Label
}

#---------------------------------------------------------------------#
#   FR//  ETAPE 6 : Re-enregistrement des DLLs Windows Update.        #
#         Apres une purge, certaines DLLs peuvent se retrouver        #
#         desenregistrees. regsvr32 les remet en etat avant le        #
#         redemarrage pour eviter des erreurs 0x80070422 / 0x8024002E. #
#                                                                     #
#  ENG//  STEP 6 : Re-register Windows Update DLLs.                   #
#         After a purge, some DLLs can become unregistered. regsvr32  #
#         restores them before reboot to avoid 0x80070422/0x8024002E.  #
#---------------------------------------------------------------------#

Write-Host ""
Write-Host "[ETAPE 6/7] Re-enregistrement des DLLs Windows Update..." -ForegroundColor Yellow

$wuDlls = @(
    "atl.dll", "urlmon.dll", "mshtml.dll", "shdocvw.dll",
    "browseui.dll", "jscript.dll", "vbscript.dll", "scrrun.dll",
    "msxml.dll", "msxml3.dll", "msxml6.dll", "actxprxy.dll",
    "softpub.dll", "wintrust.dll", "dssenh.dll", "rsaenh.dll",
    "gpkcsp.dll", "sccbase.dll", "slbcsp.dll", "cryptdlg.dll",
    "oleaut32.dll", "ole32.dll", "shell32.dll", "initpki.dll",
    "wuapi.dll", "wuaueng.dll", "wuaueng1.dll", "wucltui.dll",
    "wups.dll", "wups2.dll", "wuweb.dll",
    "qmgr.dll", "qmgrprxy.dll", "wucltux.dll", "muweb.dll", "wuwebv.dll"
)

$dllOK = 0
$dllFail = 0
foreach ($dll in $wuDlls) {
    $result = & regsvr32.exe /s $dll 2>&1
    if ($LASTEXITCODE -eq 0) { $dllOK++ } else { $dllFail++ }
}
Write-Host "  [OK] $dllOK DLL(s) enregistrees. $dllFail echec(s) (DLLs absentes = normal)." -ForegroundColor Green

#  FR// Reinitialiser le service cryptographique (requis apres catroot2)
# ENG// Reset the cryptographic service (required after catroot2 purge)
Write-Host "  Reinit cryptsvc..." -ForegroundColor Gray
& sc.exe config cryptsvc start= auto 2>$null | Out-Null
& net start cryptsvc 2>$null | Out-Null

#---------------------------------------------------------------------#
#   FR//  RESTAURATION des StartTypes d origine (ou Manual si inconnu)#
#         On ne remet PAS les services en Automatic : ils restent en  #
#         Manual pour que WU puisse rebuilder son cache au scan        #
#         suivant, sans se relancer en tache de fond immediatement.   #
#                                                                     #
#  ENG//  RESTORE original StartTypes (or Manual if unknown).         #
#         We do NOT set services back to Automatic : they stay        #
#         Manual so WU can rebuild its cache on next scan,            #
#         without running in the background immediately.              #
#---------------------------------------------------------------------#

Write-Host ""
Write-Host "  Restauration des modes de demarrage des services..." -ForegroundColor Gray

foreach ($svc in $allServices) {
    $service = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if (-not $service) { continue }

    $targetMode = "Manual"
    if ($originalStartTypes.ContainsKey($svc)) {
        $orig = $originalStartTypes[$svc]
        #  FR// On garde Manual meme si l original etait Auto : WU se relancera
        #       quand Windows en aura besoin, pas en permanence en background
        # ENG// We keep Manual even if original was Auto : WU will restart
        #       when Windows needs it, not permanently running in background
        if ($orig -eq "Disabled" -or $orig -eq "Manual") {
            $targetMode = $orig
        } else {
            $targetMode = "Manual"
        }
    }

    try {
        Set-Service -Name $svc -StartupType $targetMode -ErrorAction SilentlyContinue
        Write-Host "  [OK] $svc -> $targetMode." -ForegroundColor Gray
    } catch {
        & sc.exe config $svc start= demand 2>$null | Out-Null
    }
}

#---------------------------------------------------------------------#
#   FR//  ETAPE 7 : Bloquer les drivers Intel via registre GPO.        #
#                                                                     #
#  ENG//  STEP 7 : Block Intel drivers via registry GPO.              #
#---------------------------------------------------------------------#

Write-Host ""
Write-Host "[ETAPE 7/7] Blocage pilotes Intel par ID materiel..." -ForegroundColor Yellow

$regPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions"
if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }

Set-ItemProperty -Path $regPath -Name "DenyDeviceIDs"           -Value 1 -Type DWord
Set-ItemProperty -Path $regPath -Name "DenyDeviceIDsRetroactive" -Value 0 -Type DWord

$denyKeyPath = "$regPath\DenyDeviceIDs"
if (-not (Test-Path $denyKeyPath)) { New-Item -Path $denyKeyPath -Force | Out-Null }

$index = 1
foreach ($hwid in $HardwareIDsToBlock) {
    Set-ItemProperty -Path $denyKeyPath -Name $index.ToString() -Value $hwid -Type String
    $index++
}

Write-Host "  Pilotes bloques par ID materiel :" -ForegroundColor Cyan
$HardwareIDsToBlock | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }

#---------------------------------------------------------------------#
#   FR//  RESUME FINAL + REBOOT                                       #
#  ENG//  FINAL SUMMARY + REBOOT                                      #
#---------------------------------------------------------------------#

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  RESUME" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  - Processus WU tues avant arret services." -ForegroundColor White
Write-Host "  - Services desactives temporairement (anti-relance auto)." -ForegroundColor White
Write-Host "  - Caches SoftwareDistribution + catroot2 + BITS + DO purges." -ForegroundColor White
Write-Host "  - DLLs Windows Update re-enregistrees." -ForegroundColor White
Write-Host "  - Services remis en mode Manuel (WU rebuildera au prochain scan)." -ForegroundColor White
Write-Host "  - Blocage registre actif pour : $($HardwareIDsToBlock -join ', ')" -ForegroundColor White
Write-Host ""
Write-Host "  Les mises a jour masquees sont stockees dans le registre" -ForegroundColor Cyan
Write-Host "  et survivront au reboot et a toute purge de cache future." -ForegroundColor Cyan
Write-Host ""

$confirm = Read-Host "Redemarrer maintenant ? (O/N)"
if ($confirm -eq "O" -or $confirm -eq "o") {
    Write-Host "Redemarrage en cours..." -ForegroundColor Green
    Stop-Transcript
    Restart-Computer -Force
} else {
    Write-Host "[!!] Reboot annule. PENSEZ A REDEMARRER - la purge n est complete qu apres reboot." -ForegroundColor Red
    Write-Host "     Les suppressions planifiees via PendingFileRenameOperations" -ForegroundColor DarkYellow
    Write-Host "     ne s executeront qu au prochain demarrage (traitement SMSS)." -ForegroundColor DarkYellow
}

Stop-Transcript
