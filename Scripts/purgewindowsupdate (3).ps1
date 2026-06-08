
<#
.SYNOPSIS
    Masquer des mises à jour Windows, purger les caches et redémarrer.
.DESCRIPTION
    1. Tue les processus WU qui verrouillent les fichiers ESE (TiWorker, MoUsoCoreWorker...).
    2. Désactive temporairement les services pour empêcher leur auto-redémarrage.
    3. Arrête les services avec chaîne de fallbacks : Stop-Service / sc.exe / taskkill svchost.
    4. Liste et masque les mises à jour via PSWindowsUpdate (option A pour tout masquer).
    5. Supprime SoftwareDistribution, catroot2, BITS et DeliveryOptimization.
       Fallback : PendingFileRenameOperations si fichiers encore verrouillés.
    6. Ré-enregistre les DLLs Windows Update (évite 0x80070422 au reboot).
    7. Remet les services en mode Manuel et propose un redémarrage.
    Un journal complet est enregistré dans le dossier courant.
.NOTES
    Exécuter en tant qu'administrateur.
    Les mises à jour masquées le resteront après la purge car l'information
    est stockée dans le registre Windows, pas dans les dossiers de cache.
#>

#---------------------------------------------------------------------#
#   FR//  DÉMARRAGE — VÉRIFICATION DES DROITS ET TRANSCRIPTION        #
#                                                                     #
#        Le script doit être exécuté en tant qu'administrateur.       #
#        Une transcription est lancée pour consigner toutes les       #
#        actions dans un fichier journal dans le dossier courant.     #
#                                                                     #
#  ENG//  STARTUP — ADMIN CHECK AND TRANSCRIPTION                     #
#                                                                     #
#        The script must be run as administrator. A transcript is     #
#        started to record all actions in a log file in the current   #
#        folder.                                                      #
#---------------------------------------------------------------------#

if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "ERREUR : Ce script doit etre execute en tant qu'administrateur." -ForegroundColor Red
    exit 1
}

#--------------------------------------------------------------------------------#
#   FR//  CONFIGURATION — IDENTIFIANTS MATERIELS A BLOQUER                       #
#                                                                                #
#        Liste des identifiants materiels (Hardware IDs) pour lesquels Windows   #
#        Update ne pourra plus installer de pilotes. Modifier ce tableau pour    #
#        chaque machine en ajoutant les IDs correspondant aux peripheriques      #
#        a proteger.                                                             #
#                                                                                #
#  ENG//  CONFIGURATION — HARDWARE IDS TO BLOCK                                  #
#                                                                                #
#        List of hardware IDs for which Windows Update will no longer install    #
#        drivers. Modify this array for each machine by adding the IDs of the    #
#        devices to protect.                                                     #
#--------------------------------------------------------------------------------#

$HardwareIDsToBlock = @(
    "PCI\\VEN_8086&DEV_A788&SUBSYS_34A81043&REV_04",
    "PCI\\VEN_8086&DEV_A788&CC_038000"
)

$logPath = Join-Path $PSScriptRoot "WU_Masquage_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
Start-Transcript -Path $logPath -Append
Write-Host "Journal demarre dans le dossier courant : $logPath" -ForegroundColor Cyan

Clear-Host
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  MASQUAGE GUIDE + PURGE + REDEMARRAGE" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

#  FR//  Services a gerer — UsoSvc et WaaSMedicSvc ajoutés car ils relancent wuauserv
# ENG//  Services to manage — UsoSvc and WaaSMedicSvc added as they restart wuauserv
$allServices = @("wuauserv", "bits", "cryptsvc", "msiserver", "dosvc", "UsoSvc", "WaaSMedicSvc")

#  FR//  Processus WU connus pour verrouiller les fichiers ESE / SoftwareDistribution.
#        Sans ce kill préalable, edb.log et DataStore.edb restent verrouillés et
#        bloquent la suppression même après arrêt des services.
# ENG//  WU processes known to lock ESE files / SoftwareDistribution.
#        Without killing them first, edb.log and DataStore.edb stay locked and
#        block deletion even after services are stopped.
$wuProcesses = @(
    "TiWorker",
    "TrustedInstaller",
    "MoUsoCoreWorker",
    "WaaSMedicAgent",
    "UsoClient",
    "musnotification",
    "musnotifyicon"
)

#  FR//  Table de sauvegarde des StartTypes originaux pour restauration en fin de script
# ENG//  Hashtable to save original StartTypes for restoration at end of script
$originalStartTypes = @{}

#----------------------------------------------------------------------#
#   FR//  ETAPE 1 — TUER LES PROCESSUS WU (LIBERATION DES VERROUS)    #
#                                                                      #
#        TiWorker, MoUsoCoreWorker et WaaSMedicAgent maintiennent des  #
#        handles ouverts sur les fichiers ESE de SoftwareDistribution. #
#        Ils doivent être tués avant toute tentative d'arrêt de        #
#        service, sinon dosvc et wuauserv refusent de s'arrêter et     #
#        edb.log reste verrouillé.                                     #
#                                                                      #
#  ENG//  STEP 1 — KILL WU PROCESSES (RELEASE FILE LOCKS)              #
#                                                                      #
#        TiWorker, MoUsoCoreWorker and WaaSMedicAgent hold open        #
#        handles on SoftwareDistribution ESE files. They must be       #
#        killed before any service stop attempt, otherwise dosvc and   #
#        wuauserv refuse to stop and edb.log stays locked.             #
#----------------------------------------------------------------------#

Write-Host "[ETAPE 1/7] Arret des processus Windows Update en cours..." -ForegroundColor Yellow

foreach ($proc in $wuProcesses) {
    $running = Get-Process -Name $proc -ErrorAction SilentlyContinue
    if ($running) {
        try {
            Stop-Process -Name $proc -Force -ErrorAction Stop
            Write-Host "  OK $proc arrete (PID $($running.Id))." -ForegroundColor Green
        } catch {
            #  FR//  Fallback via taskkill si Stop-Process echoue (processus protege)
            # ENG//  Fallback via taskkill if Stop-Process fails (protected process)
            & taskkill /f /im "$proc.exe" 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  OK $proc arrete via taskkill." -ForegroundColor Green
            } else {
                Write-Host "  ! $proc non arretable (protege, on continue) : $_" -ForegroundColor DarkYellow
            }
        }
    } else {
        Write-Host "  - $proc non actif." -ForegroundColor Gray
    }
}

#  FR//  Pause courte pour laisser les handles se liberer apres les kills
# ENG//  Short pause to let file handles release after kills
Start-Sleep -Seconds 2

#----------------------------------------------------------------------#
#   FR//  ETAPE 2 — DESACTIVER LES SERVICES AVANT ARRET               #
#                                                                      #
#        Passer les services en Disabled AVANT d'appeler Stop-Service  #
#        est le seul moyen fiable d'empecher wuauserv et dosvc de se   #
#        relancer automatiquement entre l'appel Stop et la             #
#        verification d'etat. Les StartTypes originaux sont            #
#        sauvegardes pour restauration en fin de script.               #
#                                                                      #
#  ENG//  STEP 2 — DISABLE SERVICES BEFORE STOPPING                    #
#                                                                      #
#        Setting services to Disabled BEFORE calling Stop-Service is   #
#        the only reliable way to prevent wuauserv and dosvc from      #
#        auto-restarting between the Stop call and the status check.   #
#        Original StartTypes are saved for restoration at end.         #
#----------------------------------------------------------------------#

Write-Host ""
Write-Host "[ETAPE 2/7] Desactivation temporaire des services (anti-relance auto)..." -ForegroundColor Yellow

foreach ($svc in $allServices) {
    $service = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if (-not $service) { continue }

    #  FR//  Sauvegarder le StartType original via WMI avant modification
    # ENG//  Save original StartType via WMI before any modification
    try {
        $wmiSvc = Get-WmiObject Win32_Service -Filter "Name='$svc'" -ErrorAction SilentlyContinue
        if ($wmiSvc) { $originalStartTypes[$svc] = $wmiSvc.StartMode }
    } catch {}

    #  FR//  Passer en Disabled pour bloquer tout redemarrage automatique
    # ENG//  Set to Disabled to block any automatic restart
    try {
        Set-Service -Name $svc -StartupType Disabled -ErrorAction Stop
        Write-Host "  OK $svc desactive temporairement." -ForegroundColor Green
    } catch {
        #  FR//  Fallback sc.exe (WaaSMedicSvc refuse Set-Service car service protege)
        # ENG//  Fallback sc.exe (WaaSMedicSvc refuses Set-Service as it is a protected service)
        & sc.exe config $svc start= disabled 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  OK $svc desactive via sc.exe." -ForegroundColor Green
        } else {
            Write-Host "  ! $svc non desactivable (protege systeme) : $_" -ForegroundColor DarkYellow
        }
    }
}

#-----------------------------------------------------------------------#
#   FR//  ETAPE 3 — LISTER ET MASQUER LES MISES A JOUR                  #
#                                                                       #
#        wuauserv est relance brievement pour le scan PSWindowsUpdate.  #
#        Option A pour masquer toutes les mises a jour d'un coup.       #
#        Les mises a jour masquees sont stockees dans le registre et    #
#        survivent a toute purge de cache ulterieure.                   #
#                                                                       #
#  ENG//  STEP 3 — LIST AND HIDE UPDATES                                #
#                                                                       #
#        wuauserv is briefly restarted for the PSWindowsUpdate scan.    #
#        Option A to hide all listed updates at once.                   #
#        Hidden updates are stored in the registry and survive any      #
#        subsequent cache purge.                                        #
#-----------------------------------------------------------------------#

Write-Host ""
Write-Host "[ETAPE 3/7] Preparation du module PSWindowsUpdate..." -ForegroundColor Yellow

if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
    Write-Host "  Installation du module PSWindowsUpdate..." -ForegroundColor Cyan
    try {
        Install-Module -Name PSWindowsUpdate -Force -Scope CurrentUser -ErrorAction Stop
        Write-Host "  OK Module installe." -ForegroundColor Green
    } catch {
        Write-Host "  ERREUR installation : $_" -ForegroundColor Red
    }
}

#  FR//  Relancer wuauserv brievement pour le scan puis le reerreter immediatement
# ENG//  Briefly restart wuauserv for the scan then stop it again immediately
try {
    Set-Service -Name "wuauserv" -StartupType Manual -ErrorAction SilentlyContinue
    Start-Service -Name "wuauserv" -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
} catch {}

Import-Module PSWindowsUpdate -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "[ETAPE 3/7] Selection des mises a jour a masquer..." -ForegroundColor Yellow
Write-Host ""

$updates = Get-WindowsUpdate -IsInstalled:$false -ErrorAction SilentlyContinue

if (-not $updates -or $updates.Count -eq 0) {
    Write-Host "  Aucune mise a jour disponible trouvee." -ForegroundColor Green
} else {
    $continueLoop = $true
    while ($continueLoop -and $updates.Count -gt 0) {
        Write-Host "Mises a jour disponibles :" -ForegroundColor White
        Write-Host ("{0,-4} {1,-12} {2,-14} {3}" -f "N.", "KB", "Taille", "Titre") -ForegroundColor Gray
        Write-Host ("{0,-4} {1,-12} {2,-14} {3}" -f "--", "--", "------", "-----") -ForegroundColor Gray
        for ($i = 0; $i -lt $updates.Count; $i++) {
            $kb   = if ($updates[$i].KB)   { $updates[$i].KB }   else { "N/A" }
            $size = if ($updates[$i].Size) { "$([math]::Round($updates[$i].Size/1MB,0)) MB" } else { "N/A" }
            Write-Host ("{0,-4} {1,-12} {2,-14} {3}" -f ($i+1), $kb, $size, $updates[$i].Title)
        }
        Write-Host ""
        Write-Host "Numeros a masquer (ex: 1,3,5), A pour tout masquer, Q pour passer :" -ForegroundColor Cyan
        $choice = Read-Host

        if ($choice -eq "Q" -or $choice -eq "q") { $continueLoop = $false; break }

        #  FR//  Option A : masquer toutes les mises a jour listees en une fois
        # ENG//  Option A : hide all listed updates at once
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

        if (-not $numbers -or $numbers.Count -eq 0) {
            Write-Host "  [!!] Aucun numero valide. Entrer des chiffres, A ou Q." -ForegroundColor DarkYellow
            continue
        }

        #  FR//  Isoler les cibles avant de modifier la collection (evite les conflits d'index)
        # ENG//  Isolate targets before modifying the collection (avoids index conflicts)
        $selectedUpdates = @($numbers | ForEach-Object { $updates[$_ - 1] })

        foreach ($selected in $selectedUpdates) {
            Write-Host "  Masquage : $($selected.Title)" -ForegroundColor Yellow
            $hidden = $false

            #  FR//  Tentative 1 : par titre
            # ENG//  Attempt 1 : by title
            try {
                Hide-WindowsUpdate -Title $selected.Title -Confirm:$false -ErrorAction Stop
                Write-Host "    OK Masque." -ForegroundColor Green
                $hidden = $true
            } catch {}

            #  FR//  Tentative 2 : par UpdateID (plus fiable si titre avec caracteres speciaux)
            # ENG//  Attempt 2 : by UpdateID (more reliable if title has special characters)
            if (-not $hidden) {
                try {
                    Hide-WindowsUpdate -UpdateID $selected.Identity.UpdateID `
                        -RevisionNumber $selected.Identity.RevisionNumber `
                        -Confirm:$false -ErrorAction Stop
                    Write-Host "    OK Masque via UpdateID." -ForegroundColor Green
                    $hidden = $true
                } catch {
                    Write-Host "    ERREUR masquage : $_" -ForegroundColor Red
                }
            }
            if ($hidden) {
                $updates = $updates | Where-Object { $_.Title -ne $selected.Title }
            }
        }
        Write-Host ""
    }
}

#  FR//  Reerreter wuauserv et le repasser en Disabled apres le scan
# ENG//  Stop wuauserv and set it back to Disabled after the scan
try {
    Set-Service -Name "wuauserv" -StartupType Disabled -ErrorAction SilentlyContinue
    Stop-Service -Name "wuauserv" -Force -ErrorAction SilentlyContinue
} catch {}
Start-Sleep -Seconds 2

#----------------------------------------------------------------------#
#   FR//  ETAPE 4 — ARRETER LES SERVICES AVEC CHAINE DE FALLBACKS      #
#                                                                      #
#        Chaine d'arret : Stop-Service (PS natif) -> sc.exe stop ->    #
#        taskkill sur le svchost hebergeur (PID via WMI).              #
#        Verification finale avec retry jusqu'a 10s par service.       #
#        En cas d'echec : la purge continue mais peut etre partielle.  #
#                                                                      #
#  ENG//  STEP 4 — STOP SERVICES WITH FALLBACK CHAIN                   #
#                                                                      #
#        Stop chain : Stop-Service (native PS) -> sc.exe stop ->       #
#        taskkill on hosting svchost (PID via WMI).                    #
#        Final verification with retry up to 10s per service.          #
#        On failure : purge continues but may be partial.              #
#----------------------------------------------------------------------#

Write-Host ""
Write-Host "[ETAPE 4/7] Arret des services et purge des caches..." -ForegroundColor Yellow

#  FR//  Purger la file d'attente BITS avant arret pour eviter les verrous residuels
# ENG//  Purge the BITS queue before stopping to avoid residual locks
try {
    Get-BitsTransfer -AllUsers -ErrorAction SilentlyContinue | Remove-BitsTransfer -ErrorAction SilentlyContinue
    Write-Host "  OK File d'attente BITS purgee." -ForegroundColor Green
} catch {}

foreach ($svc in $allServices) {
    $service = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if (-not $service) { continue }
    if ($service.Status -eq "Stopped") {
        Write-Host "  - $svc deja arrete." -ForegroundColor Gray
        continue
    }

    $stopped = $false

    #  FR//  Tentative 1 : Stop-Service natif PowerShell
    # ENG//  Attempt 1 : native PowerShell Stop-Service
    try {
        Stop-Service -Name $svc -Force -ErrorAction Stop
        Start-Sleep -Milliseconds 800
        $stopped = (Get-Service -Name $svc -ErrorAction SilentlyContinue).Status -eq "Stopped"
        if ($stopped) { Write-Host "  OK $svc arrete." -ForegroundColor Green }
    } catch {}

    #  FR//  Tentative 2 : sc.exe stop (plus direct sur les services proteges)
    # ENG//  Attempt 2 : sc.exe stop (more direct on protected services)
    if (-not $stopped) {
        & sc.exe stop $svc 2>$null | Out-Null
        Start-Sleep -Seconds 2
        $stopped = (Get-Service -Name $svc -ErrorAction SilentlyContinue).Status -eq "Stopped"
        if ($stopped) { Write-Host "  OK $svc arrete via sc.exe." -ForegroundColor Green }
    }

    #  FR//  Tentative 3 : tuer le svchost hebergeur du service (PID recupere via WMI)
    # ENG//  Attempt 3 : kill the svchost hosting the service (PID retrieved via WMI)
    if (-not $stopped) {
        Write-Host "  ! $svc resistant, recherche du svchost hebergeur..." -ForegroundColor DarkYellow
        try {
            $svcPid = (Get-WmiObject Win32_Service -Filter "Name='$svc'" -ErrorAction SilentlyContinue).ProcessId
            if ($svcPid -and $svcPid -gt 0) {
                Stop-Process -Id $svcPid -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 1
                $stopped = (Get-Service -Name $svc -ErrorAction SilentlyContinue).Status -eq "Stopped"
                if ($stopped) {
                    Write-Host "  OK $svc arrete via kill svchost PID $svcPid." -ForegroundColor Green
                } else {
                    Write-Host "  ! $svc toujours actif (service protege OS)." -ForegroundColor Red
                }
            }
        } catch {
            Write-Host "  ! Impossible d'identifier le svchost de $svc : $_" -ForegroundColor Red
        }
    }
}

#  FR//  Verification finale de l'arret — attente jusqu'a 10s par service
# ENG//  Final stop verification — wait up to 10s per service
Write-Host ""
Write-Host "Verification de l'etat des services :" -ForegroundColor White
$servicesOK = $true
foreach ($svc in $allServices) {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if (-not $s) { continue }
    $waited = 0
    while ($s.Status -ne "Stopped" -and $waited -lt 10) {
        Start-Sleep -Seconds 1
        $waited++
        $s.Refresh()
    }
    if ($s.Status -ne "Stopped") {
        Write-Host "  [!!] $svc non arrete (Etat : $($s.Status)) — purge partielle possible." -ForegroundColor Red
        $servicesOK = $false
    } else {
        Write-Host "  [OK] $svc arrete." -ForegroundColor Green
    }
}
if (-not $servicesOK) {
    Write-Host ""
    Write-Host "  [!!] Services resistants — purge possible mais incomplete." -ForegroundColor DarkYellow
    Write-Host "       Conseil : redemarrer en Safe Mode pour une purge a 100%." -ForegroundColor Gray
}

#  FR//  Pause de securite — laisse les handles fichiers se liberer completement
# ENG//  Safety pause — lets file handles fully release after service stops
Write-Host ""
Write-Host "Pause de securite (5s) pour liberation des handles fichiers..." -ForegroundColor Gray
Start-Sleep -Seconds 5

#----------------------------------------------------------------------#
#   FR//  PURGE DES CACHES — STRATEGIE RENOMMAGE AVANT SUPPRESSION     #
#                                                                      #
#        Renommer le dossier en .old AVANT de supprimer permet de      #
#        contourner les verrous ESE residuels : le fichier renomme     #
#        n'est plus reference par les processus ESE.                   #
#        En dernier recours : PendingFileRenameOperations inscrit la   #
#        suppression pour le prochain demarrage (traite par SMSS.exe   #
#        avant le chargement de Windows Update).                       #
#                                                                      #
#  ENG//  CACHE PURGE — RENAME-BEFORE-DELETE STRATEGY                  #
#                                                                      #
#        Renaming to .old BEFORE deleting bypasses residual ESE        #
#        locks : the renamed file is no longer referenced by ESE       #
#        processes.                                                     #
#        Last resort : PendingFileRenameOperations schedules deletion   #
#        for next boot (processed by SMSS.exe before WU loads).        #
#----------------------------------------------------------------------#

function Remove-FolderWithFallback {
    #  FR//  3 niveaux : Remove-Item -> rmdir cmd -> PendingFileRenameOperations (SMSS boot)
    # ENG//  3 levels : Remove-Item -> rmdir cmd -> PendingFileRenameOperations (SMSS boot)
    param([string]$Path, [string]$Label)

    if (-not (Test-Path $Path)) {
        Write-Host "  - $Label absent : $Path" -ForegroundColor Gray
        return
    }

    #  FR//  Tentative 1 : Remove-Item PowerShell
    # ENG//  Attempt 1 : Remove-Item PowerShell
    try {
        Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
        Write-Host "  OK Dossier supprime : $Path" -ForegroundColor Green
        return
    } catch {}

    #  FR//  Tentative 2 : rmdir via cmd
    # ENG//  Attempt 2 : rmdir via cmd
    & cmd /c "rmdir /s /q `"$Path`"" 2>$null
    if (-not (Test-Path $Path)) {
        Write-Host "  OK Supprime via cmd : $Path" -ForegroundColor Green
        return
    }

    #  FR//  Tentative 3 : planifier la suppression au prochain reboot via SMSS.exe.
    #        PendingFileRenameOperations est traite par SMSS avant le chargement de WU.
    # ENG//  Attempt 3 : schedule deletion at next boot via SMSS.exe.
    #        PendingFileRenameOperations is processed by SMSS before WU loads.
    Write-Host "  [!!] $Label verrouille — suppression planifiee au reboot (SMSS)." -ForegroundColor DarkYellow
    try {
        $regKey   = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager"
        $existing = (Get-ItemProperty -Path $regKey -Name "PendingFileRenameOperations" -ErrorAction SilentlyContinue).PendingFileRenameOperations
        $newEntry = @("\??\$Path", "")
        $merged   = if ($existing) { $existing + $newEntry } else { $newEntry }
        Set-ItemProperty -Path $regKey -Name "PendingFileRenameOperations" -Value $merged -Type MultiString -ErrorAction Stop
        Write-Host "    OK Planifie au reboot." -ForegroundColor Cyan
    } catch {
        Write-Host "    ERREUR planification reboot : $_" -ForegroundColor Red
    }
}

#  FR//  catroot2 : renommer d'abord en .old, puis supprimer le .old
# ENG//  catroot2 : rename to .old first, then delete the .old
$catrootPath    = "$env:SystemRoot\System32\catroot2"
$catrootOldPath = "$env:SystemRoot\System32\catroot2.old"
if (Test-Path $catrootPath) {
    if (Test-Path $catrootOldPath) {
        Remove-FolderWithFallback -Path $catrootOldPath -Label "catroot2.old (residuel)"
    }
    try {
        Rename-Item -Path $catrootPath -NewName "catroot2.old" -Force -ErrorAction Stop
        Write-Host "  OK Dossier catroot2 isole (renomme en .old)." -ForegroundColor Green
        Remove-FolderWithFallback -Path $catrootOldPath -Label "catroot2.old"
    } catch {
        Write-Host "  ! Renommage catroot2 impossible, tentative de suppression directe..." -ForegroundColor DarkYellow
        Remove-FolderWithFallback -Path $catrootPath -Label "catroot2"
    }
}

#  FR//  SoftwareDistribution : meme strategie renommer avant supprimer
# ENG//  SoftwareDistribution : same rename-before-delete strategy
$sdPath    = "$env:SystemRoot\SoftwareDistribution"
$sdOldPath = "$env:SystemRoot\SoftwareDistribution.old"
if (Test-Path $sdPath) {
    if (Test-Path $sdOldPath) {
        Remove-FolderWithFallback -Path $sdOldPath -Label "SoftwareDistribution.old (residuel)"
    }
    try {
        Rename-Item -Path $sdPath -NewName "SoftwareDistribution.old" -Force -ErrorAction Stop
        Write-Host "  OK SoftwareDistribution isole (renomme en .old)." -ForegroundColor Green
        Remove-FolderWithFallback -Path $sdOldPath -Label "SoftwareDistribution.old"
    } catch {
        Write-Host "  ! Renommage SoftwareDistribution impossible, suppression directe..." -ForegroundColor DarkYellow
        Remove-FolderWithFallback -Path $sdPath -Label "SoftwareDistribution"
    }
} else {
    Write-Host "  - SoftwareDistribution absent (deja supprime)." -ForegroundColor Gray
}

#  FR//  Caches annexes : BITS et DeliveryOptimization
# ENG//  Ancillary caches : BITS and DeliveryOptimization
Remove-FolderWithFallback -Path "$env:ALLUSERSPROFILE\Microsoft\Network\Downloader"            -Label "Cache BITS (Downloader)"
Remove-FolderWithFallback -Path "$env:ProgramData\Microsoft\Windows\DeliveryOptimization"      -Label "Cache DeliveryOptimization"

#------------------------------------------------------------------------------#
#   FR//  ETAPE 5 — BLOQUER LES MISES A JOUR DE PILOTES INTEL PAR ID MATERIEL  #
#                                                                              #
#        Les restrictions d'installation de peripheriques sont activees        #
#        pour les identifiants materiels listes dans la configuration.         #
#        Ce blocage est stocke dans le registre et survit a toute purge.       #
#                                                                              #
#  ENG//  STEP 5 — BLOCK INTEL DRIVER UPDATES BY HARDWARE IDs                  #
#                                                                              #
#        Device installation restrictions are enabled for the hardware IDs     #
#        listed in the configuration. This block is stored in the registry     #
#        and survives any cache purge.                                         #
#------------------------------------------------------------------------------#

$regPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions"
if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }

Set-ItemProperty -Path $regPath -Name "DenyDeviceIDs"            -Value 1 -Type DWord
Set-ItemProperty -Path $regPath -Name "DenyDeviceIDsRetroactive" -Value 0 -Type DWord

$denyKeyPath = "$regPath\DenyDeviceIDs"
if (-not (Test-Path $denyKeyPath)) { New-Item -Path $denyKeyPath -Force | Out-Null }

#  FR//  Utilisation de la variable configurable (voir section CONFIG en tete de script)
# ENG//  Use the configurable variable (see CONFIG section at top of script)
$index = 1
foreach ($hwid in $HardwareIDsToBlock) {
    Set-ItemProperty -Path $denyKeyPath -Name $index.ToString() -Value $hwid -Type String
    $index++
}

Write-Host "Pilotes Intel bloques par ID materiel :" -ForegroundColor Cyan
$HardwareIDsToBlock | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
Write-Host ""

#----------------------------------------------------------------------#
#   FR//  ETAPE 6 — RE-ENREGISTREMENT DES DLL WINDOWS UPDATE           #
#                                                                      #
#        Apres une purge de cache, certaines DLL peuvent se retrouver  #
#        desenregistrees, provoquant des erreurs 0x80070422 ou         #
#        0x8024002E au redemarrage. regsvr32 /s les remet en etat.     #
#        Le service cryptsvc est aussi relance car catroot2 vient       #
#        d'etre supprime.                                              #
#                                                                      #
#  ENG//  STEP 6 — RE-REGISTER WINDOWS UPDATE DLLs                     #
#                                                                      #
#        After a cache purge, some DLLs can become unregistered,       #
#        causing 0x80070422 or 0x8024002E errors at next boot.         #
#        regsvr32 /s restores their registration.                      #
#        cryptsvc is also restarted since catroot2 was just deleted.   #
#----------------------------------------------------------------------#

Write-Host "[ETAPE 6/7] Re-enregistrement des DLL Windows Update..." -ForegroundColor Yellow

$wuDlls = @(
    "atl.dll", "urlmon.dll", "mshtml.dll", "shdocvw.dll", "browseui.dll",
    "jscript.dll", "vbscript.dll", "scrrun.dll", "msxml.dll", "msxml3.dll",
    "msxml6.dll", "actxprxy.dll", "softpub.dll", "wintrust.dll", "dssenh.dll",
    "rsaenh.dll", "gpkcsp.dll", "sccbase.dll", "slbcsp.dll", "cryptdlg.dll",
    "oleaut32.dll", "ole32.dll", "shell32.dll", "initpki.dll",
    "wuapi.dll", "wuaueng.dll", "wuaueng1.dll", "wucltui.dll",
    "wups.dll", "wups2.dll", "wuweb.dll",
    "qmgr.dll", "qmgrprxy.dll", "wucltux.dll", "muweb.dll", "wuwebv.dll"
)

$dllOK = 0; $dllFail = 0
foreach ($dll in $wuDlls) {
    & regsvr32.exe /s $dll 2>$null
    if ($LASTEXITCODE -eq 0) { $dllOK++ } else { $dllFail++ }
}
Write-Host "  OK $dllOK DLL(s) enregistrees. $dllFail echec(s) (DLL absentes = normal)." -ForegroundColor Green

#  FR//  Relancer cryptsvc (necessaire apres suppression de catroot2)
# ENG//  Restart cryptsvc (required after catroot2 deletion)
& sc.exe config cryptsvc start= auto 2>$null | Out-Null
& net start cryptsvc 2>$null | Out-Null

#  FR//  Restauration des modes de demarrage — Manuel (pas Automatique).
#        WU se relancera quand Windows en aura besoin sans tourner en fond en permanence.
# ENG//  Restore startup modes to Manual (not Automatic).
#        WU will start when Windows needs it without running permanently in background.
Write-Host ""
Write-Host "  Restauration des modes de demarrage des services..." -ForegroundColor Gray
foreach ($svc in $allServices) {
    $service = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if (-not $service) { continue }
    $targetMode = "Manual"
    if ($originalStartTypes.ContainsKey($svc)) {
        $orig = $originalStartTypes[$svc]
        if ($orig -eq "Disabled" -or $orig -eq "Manual") { $targetMode = $orig }
    }
    try {
        Set-Service -Name $svc -StartupType $targetMode -ErrorAction SilentlyContinue
        Write-Host "  OK $svc -> $targetMode." -ForegroundColor Gray
    } catch {
        & sc.exe config $svc start= demand 2>$null | Out-Null
    }
}

#-------------------------------------------------------------------------#
#   FR//  ETAPE 7 — REDEMARRAGE                                           #
#                                                                         #
#        Un redemarrage est necessaire pour appliquer les restrictions    #
#        et terminer la purge. Les suppressions planifiees via            #
#        PendingFileRenameOperations s'executent aussi au demarrage       #
#        (traitement SMSS.exe avant chargement de Windows Update).        #
#                                                                         #
#  ENG//  STEP 7 — REBOOT                                                 #
#                                                                         #
#        A reboot is required to apply the restrictions and complete the  #
#        purge. Pending deletions via PendingFileRenameOperations also    #
#        run at startup (SMSS.exe processing before WU loads).            #
#-------------------------------------------------------------------------#

Write-Host ""
Write-Host "[ETAPE 7/7] Redemarrage de l'ordinateur..." -ForegroundColor Yellow
Write-Host ""
Write-Host "Les mises a jour selectionnees sont masquees et le cache est vide." -ForegroundColor Cyan
Write-Host "Les mises a jour masquees le resteront apres la purge car l'information" -ForegroundColor Cyan
Write-Host "est stockee dans le registre Windows, pas dans les dossiers de cache." -ForegroundColor Cyan
Write-Host "Les mises a jour masquees ne devraient plus apparaitre." -ForegroundColor Cyan

$confirm = Read-Host "Voulez-vous redemarrer maintenant ? (O/N)"
if ($confirm -eq 'O' -or $confirm -eq 'o') {
    Write-Host "Redemarrage en cours..." -ForegroundColor Green
    Stop-Transcript
    Restart-Computer -Force
} else {
    Write-Host ""
    Write-Host "  [!!] Reboot annule. PENSEZ A REDEMARRER MANUELLEMENT." -ForegroundColor Red
    Write-Host "       La purge n'est complete qu'apres reboot." -ForegroundColor DarkYellow
    Write-Host "       Les suppressions planifiees via PendingFileRenameOperations" -ForegroundColor DarkYellow
    Write-Host "       s'executeront au prochain demarrage (traitement SMSS.exe)." -ForegroundColor DarkYellow
}

Stop-Transcript
