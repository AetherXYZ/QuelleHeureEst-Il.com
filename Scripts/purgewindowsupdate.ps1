
﻿<#
.SYNOPSIS
    Masquer des mises à jour Windows, purger les caches et redémarrer.
.DESCRIPTION
    1. Relance les services Windows Update.
    2. Prépare PSWindowsUpdate.
    3. Liste toutes les mises à jour disponibles.
    4. Permet de masquer plusieurs mises à jour en une seule saisie (ex: 1,3,5).
    5. Arrête les services et vérifie leur arrêt.
    6. Supprime les dossiers SoftwareDistribution, catroot2 et le cache BITS.
    7. Propose un redémarrage.
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
    Write-Host "ERREUR : Ce script doit être exécuté en tant qu'administrateur." -ForegroundColor Red
    exit 1
}

#--------------------------------------------------------------------------------#
#   FR//  CONFIGURATION — IDENTIFIANTS MATÉRIELS À BLOQUER                       #
#                                                                                #
#        Liste des identifiants matériels (Hardware IDs) pour lesquels Windows   #
#        Update ne pourra plus installer de pilotes. Modifier ce tableau pour    #
#        chaque machine en ajoutant les IDs correspondant aux périphériques      #
#        à protéger.                                                             #
#                                                                                #
#  ENG//  CONFIGURATION — HARDWARE IDS TO BLOCK                                  #
#                                                                                #
#        List of hardware IDs for which Windows Update will no longer install    #
#        drivers. Modify this array for each machine by adding the IDs of the    #
#        devices to protect.                                                     #
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

$allServices = @("wuauserv", "bits", "cryptsvc", "msiserver", "dosvc")

#----------------------------------------------------------------------#
#   FR//  ÉTAPE 1 — RELANCER LES SERVICES                              #
#                                                                      #
#        Les services Windows Update doivent être actifs pour pouvoir  #
#        interroger la liste des mises à jour.                         #
#                                                                      #
#  ENG//  STEP 1 — START THE REQUIRED SERVICES                         #
#                                                                      #
#        Windows Update services need to be running to query the       #
#        list of available updates.                                    #
#----------------------------------------------------------------------#

Write-Host "[ÉTAPE 1/6] Relance des services Windows Update..." -ForegroundColor Yellow

foreach ($svc in $allServices) {
    try {
        $service = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if (-not $service) { continue }
        if ($service.Status -ne 'Running') {
            Start-Service -Name $svc -ErrorAction Stop
            Write-Host "  OK $svc démarré." -ForegroundColor Green
        } else {
            Write-Host "  - $svc déjà en cours d'exécution." -ForegroundColor Gray
        }
    } catch {
        Write-Host "  ! Impossible de démarrer $svc : $_" -ForegroundColor DarkYellow
    }
}

#-----------------------------------------------------------------------#
#   FR//  ÉTAPE 2 — INSTALLER LE MODULE PSWINDOWSUPDATE                 #
#                                                                       #
#        Le module PowerShell PSWindowsUpdate est requis pour masquer   #
#        les mises à jour. Il sera installé automatiquement si absent.  #
#                                                                       #
#  ENG//  STEP 2 — INSTALL THE PSWINDOWSUPDATE MODULE                   #
#                                                                       #
#        The PSWindowsUpdate PowerShell module is required to hide      #
#        updates. It will be installed automatically if missing.        #
#-----------------------------------------------------------------------#

Write-Host ""
Write-Host "[ÉTAPE 2/6] Préparation du module PSWindowsUpdate..." -ForegroundColor Yellow

if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
    Write-Host "Installation du module PSWindowsUpdate..." -ForegroundColor Cyan
    try {
        Install-Module -Name PSWindowsUpdate -Force -Scope CurrentUser -ErrorAction Stop
        Write-Host "  OK Module installé." -ForegroundColor Green
    } catch {
        Write-Host "  ERREUR lors de l'installation : $_" -ForegroundColor Red
        Stop-Transcript
        exit 1
    }
}

Import-Module PSWindowsUpdate -Force

#--------------------------------------------------------------------#
#   FR//  ÉTAPE 3 — LISTER ET MASQUER LES MISES À JOUR               #
#                                                                    #
#        Toutes les mises à jour disponibles sont affichées.         #
#        Vous pouvez en masquer plusieurs en entrant leurs numéros   #
#        séparés par des virgules (ex: 1,3,5).                       #
#                                                                    #
#  ENG//  STEP 3 — LIST AND HIDE UPDATES                             #
#                                                                    #
#        All available updates are displayed. You can hide multiple  #
#        ones by entering their numbers separated by commas          #
#        (e.g. 1,3,5).                                               #
#--------------------------------------------------------------------#

Write-Host ""
Write-Host "[ÉTAPE 3/6] Sélection des mises à jour à masquer..." -ForegroundColor Yellow
Write-Host ""

#  FR//  Récupérer toutes les mises à jour disponibles
# ENG//  Retrieve all available updates
$updates = Get-WindowsUpdate -IsInstalled:$false -ErrorAction SilentlyContinue

if (-not $updates) {
    Write-Host "Aucune mise à jour disponible trouvée." -ForegroundColor Green
} else {
    #  FR//  Boucle de sélection interactive
    # ENG//  Interactive selection loop
    $continue = $true
    while ($continue -and $updates.Count -gt 0) {
        #  FR//  Afficher les mises à jour avec un numéro
        # ENG//  Display updates with an index number
        Write-Host "Mises à jour disponibles :" -ForegroundColor White
        Write-Host ("{0,-4} {1,-10} {2,-12} {3}" -f "N°", "KB", "Taille", "Titre") -ForegroundColor Gray
        Write-Host ("{0,-4} {1,-10} {2,-12} {3}" -f "--", "--", "------", "-----") -ForegroundColor Gray

        for ($i = 0; $i -lt $updates.Count; $i++) {
            $kb = if ($updates[$i].KB) { $updates[$i].KB } else { "N/A" }
            $size = if ($updates[$i].Size) { "$([math]::Round($updates[$i].Size/1MB, 1)) MB" } else { "N/A" }
            Write-Host ("{0,-4} {1,-10} {2,-12} {3}" -f ($i+1), $kb, $size, $updates[$i].Title)
        }
        Write-Host ""
        Write-Host "Entrez les numéros à masquer (séparés par des virgules, ex: 1,3,5) ou 'Q' pour terminer :" -ForegroundColor Cyan
        $choice = Read-Host
        if ($choice -eq 'Q' -or $choice -eq 'q') { $continue = $false; break }

        #  FR//  Extraire les nombres valides
        # ENG//  Extract valid numbers
        $numbers = $choice -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ } | Sort-Object -Unique -Descending
        if ($numbers.Count -eq 0) {
            Write-Host "⚠️ Aucun numéro valide trouvé. Veuillez entrer des chiffres séparés par des virgules (ex: 1,3) ou 'Q'." -ForegroundColor DarkYellow
            continue
        }

        #  FR// Isoler les cibles avant de modifier la collection principale
        # ENG// Fix Pb #4: Isolate targets before modifying the main collection
        $selectedUpdates = @()
        foreach ($num in $numbers) {
            if ($num -ge 1 -and $num -le $updates.Count) {
                $selectedUpdates += $updates[$num - 1]
            } else {
                Write-Host "Numéro $num invalide, ignoré." -ForegroundColor DarkYellow
            }
        }

        #  FR// Application séquentielle du masquage sans conflit d'index
        # ENG// Sequential application of hiding without index conflict
        foreach ($selected in $selectedUpdates) {
            Write-Host "Masquage de : $($selected.Title)" -ForegroundColor Yellow
            try {
                Hide-WindowsUpdate -UpdateID $selected.Identity.UpdateID -RevisionNumber $selected.Identity.RevisionNumber -Confirm:$false -ErrorAction Stop
                Write-Host "  OK via UpdateID." -ForegroundColor Green
                $updates = $updates | Where-Object { $_.Identity.UpdateID -ne $selected.Identity.UpdateID }
            } catch {
                Write-Host "  ERREUR : $_" -ForegroundColor Red
                Write-Host "  Tentative via Title..." -ForegroundColor DarkYellow
                try {
                    Hide-WindowsUpdate -Title $selected.Title -Confirm:$false -ErrorAction Stop
                    Write-Host "  OK Mise à jour masquée via Title." -ForegroundColor Green
                    $updates = $updates | Where-Object { $_.Title -ne $selected.Title }
                } catch {
                    Write-Host "  ÉCHEC également." -ForegroundColor Red
                }
            }
        }
        Write-Host ""
    }
}

#----------------------------------------------------------------------#
#   FR//  ÉTAPE 4 — ARRÊTER LES SERVICES ET PURGER LES CACHES          #
#                                                                      #
#        Tous les services Windows Update sont arrêtés puis leur état  #
#        est vérifié. Les dossiers SoftwareDistribution, catroot2      #
#        et le cache BITS sont supprimés.                              #
#                                                                      #
#  ENG//  STEP 4 — STOP SERVICES AND PURGE CACHES                      #
#                                                                      #
#        All Windows Update services are stopped and their status is   #
#        verified. The SoftwareDistribution, catroot2 folders and      #
#        BITS cache are deleted.                                       #
#----------------------------------------------------------------------#

Write-Host ""
Write-Host "[ÉTAPE 4/6] Arrêt des services et purge des caches..." -ForegroundColor Yellow

# [FR] Purger proprement la file d'attente logique de BITS
# [EN] Cleanly purge the logical BITS queue
try {
    Get-BitsTransfer -AllUsers -ErrorAction SilentlyContinue | Remove-BitsTransfer -ErrorAction SilentlyContinue
    Write-Host "  OK File d'attente BITS purgée." -ForegroundColor Green
} catch {}

#  FR//  Arrêter tous les services
# ENG//  Stop all services
foreach ($svc in $allServices) {
    try {
        $service = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($service -and $service.Status -ne 'Stopped') {
            Stop-Service -Name $svc -Force -ErrorAction Stop
            Write-Host "  OK $svc arrêté." -ForegroundColor Green
        } else {
            Write-Host "  - $svc déjà arrêté ou absent." -ForegroundColor Gray
        }
    } catch {
        Write-Host "  ! Impossible d'arrêter $svc : $_" -ForegroundColor DarkYellow
    }
}

#  FR//  Vérification de l'arrêt effectif
# ENG//  Verify that services are actually stopped
Write-Host "`nVérification de l'état des services :" -ForegroundColor White
foreach ($svc in $allServices) {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($s -and $s.Status -ne 'Stopped') {
        Write-Host "  ⚠️  $svc n'est pas arrêté (État: $($s.Status))" -ForegroundColor Red
    } else {
        Write-Host "  ✅ $svc bien arrêté" -ForegroundColor Green
    }
}

#   FR//  Micro-pause de sécurité pour s'assurer que les descripteurs de fichiers sont libérés
#  ENG//  Safety micro-pause to ensure file handles are released
Write-Host "`nAttente de libération des fichiers système (3s)..." -ForegroundColor Gray
Start-Sleep -Seconds 3

#   FR//  Traitement spécial pour catroot2 (Renommage préventif pour éviter les verrous de cryptsvc)
#  ENG//  Special treatment for catroot2 (Preventive renaming to avoid cryptsvc locks)
$catrootPath = "$env:SystemRoot\System32\catroot2"
if (Test-Path $catrootPath) {
    try {
        $oldCatroot = "$catrootPath.old"
        if (Test-Path $oldCatroot) { Remove-Item -Path $oldCatroot -Recurse -Force -ErrorAction SilentlyContinue }
        Rename-Item -Path $catrootPath -NewName "catroot2.old" -Force -ErrorAction Stop
        Write-Host "  OK Dossier catroot2 isolé (renommé en .old)." -ForegroundColor Green
    } catch {
        Write-Host "  ! Impossible de renommer catroot2, tentative de suppression directe..." -ForegroundColor DarkYellow
    }
}

#  FR// Suppression des principaux caches Windows Update et composants associés
# ENG// Delete main Windows Update cache folders and related components
$cachePaths = @(
    "$env:SystemRoot\SoftwareDistribution",
    "$env:SystemRoot\System32\catroot2.old",
    "$env:ALLUSERSPROFILE\Microsoft\Network\Downloader",
    "$env:ProgramData\Microsoft\Windows\DeliveryOptimization"
)

foreach ($p in $cachePaths) {
    if (Test-Path $p) {
        try {
            Remove-Item -Path $p -Recurse -Force -ErrorAction Stop
            Write-Host "  OK Dossier supprimé : $p" -ForegroundColor Green
        } catch {
            Write-Host "  Échec via PowerShell, tentative via cmd..." -ForegroundColor DarkYellow
            $cmdError = cmd /c "rmdir /s /q `"$p`"" 2>&1
            if (Test-Path $p) {
                Write-Host "  [!] ÉCHEC également via cmd (fichiers verrouillés, ils sauteront au reboot)." -ForegroundColor Red
                if ($cmdError) {
                    Write-Host "  Détail cmd: $($cmdError -join ' ')" -ForegroundColor DarkGray
                }
            } else {
                Write-Host "  OK Supprimé via cmd." -ForegroundColor Green
            }
        }
    } else {
        #  FR// Ne pas logguer comme absent si c'est le catroot2 d'origine qui a déjà été renommé
        # ENG// Do not log as missing if it is the original catroot2 that has already been renamed
        if ($p -ne "$env:SystemRoot\System32\catroot2.old") {
            Write-Host "  - Dossier absent : $p" -ForegroundColor Gray
        }
    }
}


#------------------------------------------------------------------------------#
#   FR//  ÉTAPE 5 — BLOQUER LES MISES À JOUR DE PILOTES INTEL PAR ID MATÉRIEL  #
#                                                                              #
#        Les restrictions d’installation de périphériques sont activées        #
#        pour les identifiants matériels listés dans la configuration.         #
#        Cela empêche Windows Update d’écraser les pilotes manuels.            #
#                                                                              #
#  ENG//  STEP 5 — BLOCK INTEL DRIVER UPDATES BY HARDWARE IDs                  #
#                                                                              #
#        Device installation restrictions are enabled for the hardware IDs     #
#        listed in the configuration. This prevents Windows Update from        #
#        overwriting manually installed drivers.                               #
#------------------------------------------------------------------------------#

# FR//  Créer la clé de restriction de pilotes
# ENG//  Create the driver restriction registry key
$regPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions"
if (-not (Test-Path $regPath)) {
    New-Item -Path $regPath -Force | Out-Null
}

# FR//  Activer les restrictions par ID matériel
# ENG//  Enable hardware ID restrictions
Set-ItemProperty -Path $regPath -Name "DenyDeviceIDs" -Value 1 -Type DWord
Set-ItemProperty -Path $regPath -Name "DenyDeviceIDsRetroactive" -Value 0 -Type DWord

# FR//  Ajouter les ID matériels à bloquer
# ENG//  Add hardware IDs to block
$denyKeyPath = "$regPath\DenyDeviceIDs"
if (-not (Test-Path $denyKeyPath)) {
    New-Item -Path $denyKeyPath -Force | Out-Null
}

#  FR//  Utilisation de la variable configurable
# ENG//  Use the configurable variable
$index = 1
foreach ($hwid in $HardwareIDsToBlock) {
    Set-ItemProperty -Path $denyKeyPath -Name $index.ToString() -Value $hwid -Type String
    $index++
}

Write-Host "Pilotes Intel bloqués par ID matériel :" -ForegroundColor Cyan
$HardwareIDsToBlock | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
Write-Host ""


#-------------------------------------------------------------------------#
#   FR//  ÉTAPE 6 — REDÉMARRAGE                                           #
#                                                                         #
#        Un redémarrage est nécessaire pour appliquer les restrictions    #
#        et terminer la purge. Le script peut redémarrer automatiquement  #
#        ou vous laisser le faire manuellement.                           #
#                                                                         #
#  ENG//  STEP 6 — REBOOT                                                 #
#                                                                         #
#        A reboot is required to apply the restrictions and complete      #
#        the purge. The script can restart automatically or let you       #
#        do it manually.                                                  #
#-------------------------------------------------------------------------#

Write-Host ""
Write-Host "[ÉTAPE 6/6] Redémarrage de l'ordinateur..." -ForegroundColor Yellow
Write-Host ""
Write-Host "Les mises à jour sélectionnées sont masquées et le cache est vidé." -ForegroundColor Cyan
Write-Host "Les mises à jour masquées le resteront après la purge car l'information" -ForegroundColor Cyan
Write-Host "est stockée dans le registre Windows, pas dans les dossiers de cache." -ForegroundColor Cyan
Write-Host "Les mises à jour masquées ne devraient plus apparaître." -ForegroundColor Cyan

$confirm = Read-Host "Voulez-vous redémarrer maintenant ? (O/N)"
if ($confirm -eq 'O' -or $confirm -eq 'o') {
    Write-Host "Redémarrage en cours..." -ForegroundColor Green
    Stop-Transcript
    Restart-Computer -Force
} else {
    Write-Host "Redémarrage annulé. Pensez à redémarrer manuellement." -ForegroundColor DarkYellow
}

Stop-Transcript
