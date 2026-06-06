# ============================================================
# DiagComplet_DINGUERIE.ps1
# Diagnostic complet : BSOD, drivers, SDIO, reboots, latence,
#                      logs 72h, points de restauration 72h,
#                      voltage/thermal/throttling, WiFi, PnP,
#                      SFC, TaskScheduler, firmware UEFI
# Auteur  : Script généré pour Minho Lee / DINGUERIE
# Machine : ROG Strix G18 G814JIR - i9-14900HX - Win11 26200
# Usage   : Clic droit → "Exécuter en tant qu'administrateur"
# ============================================================
# Complete system diagnostic: BSOD, drivers, SDIO, reboots,
# latency, 72h logs, 72h restore points, voltage/thermal,
# WiFi, PnP snapshot, SFC integrity, TaskScheduler, UEFI
# Author  : Script generated for Minho Lee / DINGUERIE
# Usage   : Right-click → "Run as administrator"
# ============================================================

#region ── CONFIG ────────────────────────────────────────────
# Fenêtre d'analyse principale : depuis le 21/05/2026 00:00
# Main analysis window: since 2026-05-21 00:00

#   FR  Fenêtre glissante 3 semaines
#  ENG  Rolling 3-week window
$SINCE        = (Get-Date).AddDays(-21)

# Fenêtre 72h glissante à partir de maintenant
# Rolling 72h window from now
$SINCE_72H    = (Get-Date).AddDays(-21)
$SDIO_PATH    = "C:\Users\Minho Lee\Desktop\Sasha\A\SDIO_1.17.5.826"
$LATMON_EXE   = "C:\Program Files\LatencyMon\LatMon.exe"
$MINIDUMP_DIR = "C:\WINDOWS\Minidump"
$REPORT_DIR   = "$env:USERPROFILE\Desktop\DiagRapports"
$TIMESTAMP    = Get-Date -Format 'yyyyMMdd_HHmm'
$REPORT_FILE  = "$REPORT_DIR\DiagComplet_$TIMESTAMP.txt"
$PNPCSV_FILE  = "$REPORT_DIR\PnPSnapshot_$TIMESTAMP.csv"
$SEP          = "=" * 70
$SEP2         = "-" * 70

# Contexte voltage manuel du jour (à mettre à jour si changement)
# Manual voltage offset context for the day (update if changed)
$VOLT_MATIN   = "+80 mV"   # offset configuré en début d'après-midi
$VOLT_APRESMIDI = "-50 mV" # rollback prudentiel

# Création du dossier de rapport si inexistant
# Create report folder if it doesn't exist
if (-not (Test-Path $REPORT_DIR)) { New-Item -ItemType Directory -Path $REPORT_DIR | Out-Null }
#endregion

#region ── HELPERS ───────────────────────────────────────────
# Fonction d'affichage coloré + écriture dans le rapport
# Colored display function + write to report file
$script:ReportLines = [System.Collections.Generic.List[string]]::new()

function Write-Log {
    param(
        [string]$Text,
        [string]$Color = "White",
        [switch]$NoNewline
    )
    if ($NoNewline) {
        Write-Host $Text -ForegroundColor $Color -NoNewline
    } else {
        Write-Host $Text -ForegroundColor $Color
    }
    $script:ReportLines.Add($Text)
}

function Write-Section {
    param([string]$Title)
    Write-Log ""
    Write-Log $SEP "Cyan"
    Write-Log "  $Title" "Cyan"
    Write-Log $SEP "Cyan"
}

function Write-Sub {
    param([string]$Title)
    Write-Log ""
    Write-Log "  ── $Title ──" "Yellow"
    Write-Log $SEP2 "DarkGray"
}

# Sauvegarde du rapport en cours de route
# Save report incrementally
function Save-Report {
    $script:ReportLines | Out-File -FilePath $REPORT_FILE -Encoding UTF8
}

# Conversion date WMI → DateTime
# WMI date to DateTime conversion
function ConvertFrom-WmiDate {
    param([string]$WmiDate)
    try {
        return [System.Management.ManagementDateTimeConverter]::ToDateTime($WmiDate)
    } catch { return $null }
}

# Troncature sécurisée de message
# Safe message truncation
function Truncate {
    param([string]$s, [int]$max = 150)
    if (-not $s) { return "(vide)" }
    if ($s.Length -le $max) { return $s }
    return $s.Substring(0, $max) + "…"
}
#endregion

# ════════════════════════════════════════════════════════════
# BANNER
# ════════════════════════════════════════════════════════════
Clear-Host
Write-Log $SEP "Cyan"
Write-Log "  DIAGNOSTIC COMPLET — DINGUERIE" "Cyan"
Write-Log "  $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')" "Cyan"
Write-Log "  Fenêtre principale : depuis $($SINCE.ToString('dd/MM/yyyy HH:mm'))" "Cyan"
Write-Log "  Fenêtre 72h        : depuis $($SINCE_72H.ToString('dd/MM/yyyy HH:mm')) (logs & restore)" "Cyan"
Write-Log "  Rapport texte      : $REPORT_FILE" "Cyan"
Write-Log "  Snapshot PnP CSV   : $PNPCSV_FILE" "Cyan"
Write-Log $SEP "Cyan"

# ════════════════════════════════════════════════════════════
# 0. INFOS SYSTÈME DE BASE
# System info
# ════════════════════════════════════════════════════════════
Write-Section "0/14 — INFORMATIONS SYSTÈME"

try {
    $cs  = Get-CimInstance Win32_ComputerSystem
    $os  = Get-CimInstance Win32_OperatingSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $ram = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)

    Write-Log "  Hostname    : $($cs.Name)"
    Write-Log "  OS          : $($os.Caption) — Build $($os.BuildNumber)"
    Write-Log "  CPU         : $($cpu.Name)"
    Write-Log "  RAM         : $ram GB"
    Write-Log "  Uptime      : Démarré le $($os.LastBootUpTime.ToString('dd/MM/yyyy HH:mm:ss'))"

    # Temps depuis dernier démarrage / time since last boot
    $uptime = (Get-Date) - $os.LastBootUpTime
    Write-Log "  Uptime dur. : $([math]::Floor($uptime.TotalHours))h $($uptime.Minutes)min"
} catch {
    Write-Log "  ERREUR lecture infos système : $_" "Red"
}

Save-Report

# ════════════════════════════════════════════════════════════
# 1. BSOD — ANALYSE DES MINIDUMPS
# BSOD — Minidump analysis
# ════════════════════════════════════════════════════════════
Write-Section "1/14 — BSOD & MINIDUMPS"

# 1a. Fichiers .dmp présents
# Check .dmp files present
Write-Sub "Fichiers Minidump disponibles"

if (Test-Path $MINIDUMP_DIR) {
    $dumps = Get-ChildItem $MINIDUMP_DIR -Filter "*.dmp" |
             Sort-Object LastWriteTime -Descending
    if ($dumps) {
        Write-Log "  $($dumps.Count) fichier(s) .dmp trouvé(s) :" "White"
        foreach ($d in $dumps) {
            $age = (Get-Date) - $d.LastWriteTime
            $ageStr = if ($age.TotalHours -lt 24) { "il y a $([math]::Round($age.TotalHours,1))h" } else { "il y a $([math]::Floor($age.TotalDays))j" }
            Write-Log "  [$($d.LastWriteTime.ToString('dd/MM HH:mm'))] $($d.Name) — $([math]::Round($d.Length/1MB,1)) MB ($ageStr)" "White"
        }
        # Dumps récents (depuis $SINCE)
        # Recent dumps since analysis start
        $recentDumps = $dumps | Where-Object { $_.LastWriteTime -ge $SINCE }
        if ($recentDumps) {
            Write-Log ""
            Write-Log "  ⚠  $($recentDumps.Count) dump(s) depuis le 21/05/2026 !" "Red"
        }
    } else {
        Write-Log "  Aucun fichier .dmp dans $MINIDUMP_DIR" "Green"
    }
} else {
    Write-Log "  Dossier Minidump introuvable : $MINIDUMP_DIR" "DarkYellow"
}

# 1b. Événements BSOD (ID 1001 = BugCheck, ID 41 = arrêt inattendu)
# BSOD events from Windows Event Log
Write-Sub "Événements BSOD dans les journaux Windows (ID 1001 / 41)"

$bsodEvents = Get-WinEvent -FilterHashtable @{
    LogName   = 'System'
    StartTime = $SINCE
    Id        = 1001, 41
} -ErrorAction SilentlyContinue | Sort-Object TimeCreated -Descending

if ($bsodEvents) {
    Write-Log "  $($bsodEvents.Count) événement(s) trouvé(s) :" "Red"
    foreach ($e in $bsodEvents) {
        $label = if ($e.Id -eq 41) { "🔴 ARRET INATTENDU (Kernel-Power 41)" } else { "🔵 BSOD BugCheck (1001)" }
        Write-Log "  [$($e.TimeCreated.ToString('dd/MM HH:mm:ss'))] $label" "Red"
        Write-Log "    Source  : $($e.ProviderName)" "Gray"
        Write-Log "    Message : $(Truncate $e.Message 200)" "Gray"
        Write-Log ""
    }
} else {
    Write-Log "  Aucun événement BSOD/Kernel-Power 41 depuis le 21/05/2026." "Green"
}

# 1c. Événements critiques généraux du noyau
# General critical kernel events
Write-Sub "Autres événements critiques noyau (Level 1-2)"

$critEvents = Get-WinEvent -FilterHashtable @{
    LogName   = 'System'
    StartTime = $SINCE
    Level     = 1, 2
} -ErrorAction SilentlyContinue |
    Where-Object { $_.Id -notin @(1001, 41) } |
    Sort-Object TimeCreated -Descending |
    Select-Object -First 20

if ($critEvents) {
    Write-Log "  $($critEvents.Count) événement(s) critique(s) (top 20) :" "DarkYellow"
    foreach ($e in $critEvents) {
        Write-Log "  [$($e.TimeCreated.ToString('dd/MM HH:mm'))] ID:$($e.Id) $($e.ProviderName)" "DarkYellow"
        Write-Log "    $(Truncate $e.Message 120)" "Gray"
    }
} else {
    Write-Log "  Aucun événement critique supplémentaire." "Green"
}

Save-Report

# ════════════════════════════════════════════════════════════
# 2. REBOOTS — CAUSES ET HISTORIQUE
# Reboot history and causes
# ════════════════════════════════════════════════════════════
Write-Section "2/14 — HISTORIQUE DES REBOOTS"

# 2a. Kernel-Power ID 41 = arrêt sale / unexpected
# ID 109 = mise en veille prolongée
# ID 6008 = arrêt inattendu précédent (EventLog)
Write-Sub "Arrêts inattendus (Kernel-Power 41 + EventLog 6008)"

$unexpectedReboots = Get-WinEvent -FilterHashtable @{
    LogName   = 'System'
    StartTime = $SINCE
    Id        = 41, 6008
} -ErrorAction SilentlyContinue | Sort-Object TimeCreated -Descending

if ($unexpectedReboots) {
    Write-Log "  ⚠  $($unexpectedReboots.Count) arrêt(s) inattendu(s) !" "Red"
    foreach ($e in $unexpectedReboots) {
        Write-Log "  [$($e.TimeCreated.ToString('dd/MM HH:mm:ss'))] ID:$($e.Id) — $($e.ProviderName)" "Red"
        # Extraction BugCheckCode si présent / Extract BugCheckCode if present
        if ($e.Message -match 'BugcheckCode\s+(\d+)') {
            Write-Log "    BugCheckCode : $($Matches[1]) (0x$('{0:X}' -f [int]$Matches[1]))" "DarkRed"
        }
        if ($e.Message -match 'BugcheckParameter1\s+(\d+)') {
            Write-Log "    Param1       : $($Matches[1])" "DarkRed"
        }
        Write-Log "    $(Truncate $e.Message 200)" "Gray"
        Write-Log ""
    }
} else {
    Write-Log "  Aucun arrêt inattendu depuis le 21/05/2026." "Green"
}

# 2b. Reboots planifiés / propres (ID 1074 = shutdown demandé)
# Planned reboots (user/system requested)
Write-Sub "Reboots planifiés / demandés (ID 1074)"

$plannedReboots = Get-WinEvent -FilterHashtable @{
    LogName   = 'System'
    StartTime = $SINCE
    Id        = 1074
} -ErrorAction SilentlyContinue | Sort-Object TimeCreated -Descending

if ($plannedReboots) {
    Write-Log "  $($plannedReboots.Count) reboot(s) planifié(s) :" "White"
    foreach ($e in $plannedReboots) {
        Write-Log "  [$($e.TimeCreated.ToString('dd/MM HH:mm:ss'))] $(Truncate $e.Message 180)" "White"
    }
} else {
    Write-Log "  Aucun reboot planifié trouvé." "Gray"
}

# 2c. Démarrages du système (ID 12 = kernel started)
# System startups
Write-Sub "Démarrages système (Kernel ID 12)"

$startups = Get-WinEvent -FilterHashtable @{
    LogName      = 'System'
    StartTime    = $SINCE
    ProviderName = 'Microsoft-Windows-Kernel-General'
    Id           = 12
} -ErrorAction SilentlyContinue | Sort-Object TimeCreated

if ($startups) {
    Write-Log "  $($startups.Count) démarrage(s) depuis le 21/05/2026 :"
    foreach ($e in $startups) {
        Write-Log "  [$($e.TimeCreated.ToString('dd/MM HH:mm:ss'))] Système démarré" "Cyan"
    }
} else {
    Write-Log "  Aucun démarrage trouvé dans les journaux." "Gray"
}

Save-Report

# ════════════════════════════════════════════════════════════
# 3. DRIVERS INSTALLÉS / MODIFIÉS LE 21/05/2026
# Drivers installed/modified on 2026-05-21
# ════════════════════════════════════════════════════════════
Write-Section "3/14 — DRIVERS DU 21/05/2026"

# 3a. Via WMI
# Via WMI query
Write-Sub "Drivers signés installés (Win32_PnPSignedDriver)"

$drivers = Get-WmiObject Win32_PnPSignedDriver |
    Where-Object { $_.DriverDate -ne $null } |
    Select-Object DeviceName, DriverVersion, DriverDate, InfName, Manufacturer |
    Where-Object {
        $d = ConvertFrom-WmiDate $_.DriverDate
        $d -ne $null -and $d -ge $SINCE
    } |
    Sort-Object DriverDate -Descending

if ($drivers) {
    Write-Log "  $($drivers.Count) driver(s) installé(s) :" "White"
    $drivers | ForEach-Object {
        $date = ConvertFrom-WmiDate $_.DriverDate
        Write-Log ("  [{0}] {1,-45} v{2,-15} — {3}" -f `
            $date.ToString('dd/MM HH:mm'), `
            (Truncate $_.DeviceName 45), `
            $_.DriverVersion, `
            $_.Manufacturer) "White"
        Write-Log ("          INF: {0}" -f $_.InfName) "Gray"
    }
} else {
    Write-Log "  Aucun driver WMI daté du 21/05/2026." "Gray"
}

# 3b. Fichiers INF récents dans C:\Windows\INF
# Recent INF files in Windows INF directory
Write-Sub "Fichiers OEM INF récents (C:\Windows\INF)"

$infDir = "$env:SystemRoot\INF"
$recentInf = Get-ChildItem $infDir -Filter "oem*.inf" -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -ge $SINCE } |
    Sort-Object LastWriteTime -Descending

if ($recentInf) {
    Write-Log "  $($recentInf.Count) fichier(s) INF du 21/05/2026 :" "White"
    foreach ($inf in $recentInf) {
        Write-Log "  [$($inf.LastWriteTime.ToString('dd/MM HH:mm'))] $($inf.Name)" "White"
        $content = Get-Content $inf.FullName -TotalCount 15 -ErrorAction SilentlyContinue
        $meta    = $content | Where-Object { $_ -match 'Provider|DriverDesc|Class|Version' } | Select-Object -First 5
        $meta | ForEach-Object { Write-Log "    $_" "Gray" }
    }
} else {
    Write-Log "  Aucun INF OEM récent." "Gray"
}

# 3c. Événements d'installation de drivers (SetupAPI)
# Driver install events from System log
Write-Sub "Événements journaux drivers (System — Device*)"

$drvEvents = Get-WinEvent -FilterHashtable @{
    LogName   = 'System'
    StartTime = $SINCE
    Id        = 20001, 20003, 7045, 7034, 7023, 7000
} -ErrorAction SilentlyContinue | Sort-Object TimeCreated -Descending | Select-Object -First 30

if ($drvEvents) {
    Write-Log "  $($drvEvents.Count) événement(s) de drivers :" "DarkYellow"
    foreach ($e in $drvEvents) {
        $col = if ($e.Level -le 2) { "Red" } else { "DarkYellow" }
        Write-Log "  [$($e.TimeCreated.ToString('dd/MM HH:mm'))] ID:$($e.Id) $($e.ProviderName)" $col
        Write-Log "    $(Truncate $e.Message 140)" "Gray"
    }
} else {
    Write-Log "  Aucun événement driver notable." "Green"
}

Save-Report

# ════════════════════════════════════════════════════════════
# 4. LOGS SDIO
# SDIO installation logs
# ════════════════════════════════════════════════════════════
Write-Section "4/14 — LOGS SDIO"

if (Test-Path $SDIO_PATH) {
    Write-Log "  Dossier SDIO trouvé : $SDIO_PATH" "Green"

    # 4a. Logs texte SDIO (*.log, *.txt)
    # SDIO text logs
    Write-Sub "Fichiers de logs SDIO"
    $sdioLogs = Get-ChildItem $SDIO_PATH -Recurse -Include "*.log","*.txt" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $SINCE } |
        Sort-Object LastWriteTime -Descending

    if ($sdioLogs) {
        Write-Log "  $($sdioLogs.Count) fichier(s) log trouvé(s) :" "White"
        foreach ($log in $sdioLogs) {
            Write-Log "  [$($log.LastWriteTime.ToString('dd/MM HH:mm'))] $($log.FullName)" "White"
            # Lire les 40 dernières lignes de chaque log
            # Read last 40 lines of each log
            $lines = Get-Content $log.FullName -Tail 40 -ErrorAction SilentlyContinue
            if ($lines) {
                Write-Log "  --- Extrait (40 dernières lignes) ---" "DarkGray"
                $lines | ForEach-Object { Write-Log "    $_" "Gray" }
                Write-Log "  --- Fin extrait ---" "DarkGray"
            }
        }
    } else {
        Write-Log "  Aucun fichier log SDIO récent trouvé." "Gray"
    }

    # 4b. Liste de tous les drivers que SDIO a importés
    # List all drivers SDIO imported
    Write-Sub "Drivers téléchargés/présents dans le dossier SDIO"
    $sdioDrvs = Get-ChildItem $SDIO_PATH -Recurse -Include "*.inf" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
    if ($sdioDrvs) {
        Write-Log "  $($sdioDrvs.Count) fichier(s) INF dans l'arborescence SDIO :" "White"
        foreach ($inf in $sdioDrvs) {
            Write-Log "  $($inf.FullName)" "Gray"
        }
    }

    # 4c. Exécutable SDIO — version
    # SDIO executable version
    $sdioExe = Get-ChildItem $SDIO_PATH -Filter "SDIO_x64*.exe" | Select-Object -First 1
    if ($sdioExe) {
        $ver = $sdioExe.VersionInfo
        Write-Log ""
        Write-Log "  Exécutable SDIO : $($sdioExe.Name)" "White"
        Write-Log "  Version         : $($ver.FileVersion)" "White"
    }

} else {
    Write-Log "  ⚠  Dossier SDIO introuvable : $SDIO_PATH" "Red"
    Write-Log "  (Normal si SDIO a été déplacé/supprimé après usage)" "Gray"
}

Save-Report

# ════════════════════════════════════════════════════════════
# 5. LATENCYMON — LANCEMENT AUTO 60s + CAPTURE
# LatencyMon auto-launch 60s + log capture
# ════════════════════════════════════════════════════════════
Write-Section "5/14 — LATENCYMON (Capture des Rapports)"

# 5a. Mesure DPC via compteurs de performance Windows (fallback toujours actif)
# DPC measurement via Windows performance counters (always-active fallback)
Write-Sub "Mesure DPC/ISR via compteurs Windows (built-in)"

try {
    Write-Log "  Capture compteurs DPC/ISR pendant 10 secondes..." "White"
    $dpcSamples = @()
    for ($i = 0; $i -lt 5; $i++) {
        $sample = Get-Counter '\Processor(_Total)\% DPC Time',
                              '\Processor(_Total)\% Interrupt Time',
                              '\Processor(_Total)\% Privileged Time' `
                  -ErrorAction SilentlyContinue
        if ($sample) { $dpcSamples += $sample }
        Start-Sleep -Seconds 2
    }

    if ($dpcSamples) {
        $dpcVals  = $dpcSamples | ForEach-Object { ($_.CounterSamples | Where-Object { $_.Path -match 'DPC' }).CookedValue }
        $intrVals = $dpcSamples | ForEach-Object { ($_.CounterSamples | Where-Object { $_.Path -match 'Interrupt' }).CookedValue }

        $dpcAvg  = [math]::Round(($dpcVals  | Measure-Object -Average).Average, 3)
        $dpcMax  = [math]::Round(($dpcVals  | Measure-Object -Maximum).Maximum, 3)
        $intrAvg = [math]::Round(($intrVals | Measure-Object -Average).Average, 3)
        $intrMax = [math]::Round(($intrVals | Measure-Object -Maximum).Maximum, 3)

        $dpcCol  = if ($dpcMax -gt 5) { "Red" } elseif ($dpcMax -gt 1) { "DarkYellow" } else { "Green" }
        $intrCol = if ($intrMax -gt 5) { "Red" } elseif ($intrMax -gt 1) { "DarkYellow" } else { "Green" }

        Write-Log "  % DPC Time       : avg=$dpcAvg%  max=$dpcMax%  $(if ($dpcMax -gt 5) {'⚠ ÉLEVÉ'} elseif ($dpcMax -gt 1) {'△ à surveiller'} else {'✅ OK'})" $dpcCol
        Write-Log "  % Interrupt Time : avg=$intrAvg%  max=$intrMax%  $(if ($intrMax -gt 5) {'⚠ ÉLEVÉ'} elseif ($intrMax -gt 1) {'△ à surveiller'} else {'✅ OK'})" $intrCol
        Write-Log ""
        Write-Log "  Seuils de référence : DPC < 1% = normal / > 5% = problématique (audio/latence)" "Gray"
    }
} catch {
    Write-Log "  Erreur compteurs performance : $_" "DarkYellow"
}

# 5b. Récupération de tous les rapports LatencyMon existants (7 derniers jours)
# Retrieve all existing LatencyMon reports (last 7 days)
Write-Sub "Rapports LatencyMon existants (7 jours)"

$searchPaths = @(
    [Environment]::GetFolderPath("Desktop"),                     # Bureau
    "$env:USERPROFILE\Documents",
    "$env:USERPROFILE\Downloads",
    "C:\Users\Minho Lee\Desktop\Sasha",                         # ton dossier spécifique
    "C:\Program Files\LatencyMon",                              # répertoire d'installation
    "$env:LOCALAPPDATA\LatencyMon",                             # éventuels logs locaux
    $REPORT_DIR                                                  # déjà défini
) | Where-Object { Test-Path $_ }

$latmonReports = [System.Collections.Generic.List[object]]::new()
$sevenDaysAgo = (Get-Date).AddDays(-7)

foreach ($p in $searchPaths) {
    # Recherche récursive de tous les .txt / .html modifiés dans les 7 jours
    $candidates = Get-ChildItem -Path $p -Recurse -Include "*.txt","*.html" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $sevenDaysAgo }

    foreach ($c in $candidates) {
        # Vérifie si le fichier contient les mots-clés typiques d'un rapport LatencyMon
        $content = Get-Content $c.FullName -TotalCount 50 -ErrorAction SilentlyContinue
        if ($content -match 'LatencyMon|Highest DPC routine|Highest ISR routine|Driver with highest DPC') {
            $latmonReports.Add($c)
        }
    }
}

# Dédupliquer par chemin complet et trier par date décroissante
$latmonReports = $latmonReports | Sort-Object FullName -Unique | Sort-Object LastWriteTime -Descending

if ($latmonReports) {
    Write-Log "  $($latmonReports.Count) rapport(s) LatencyMon trouvé(s) :" "White"
    foreach ($r in $latmonReports) {
        Write-Log "  [$($r.LastWriteTime.ToString('dd/MM HH:mm'))] $($r.FullName)" "White"
        $content = Get-Content $r.FullName -ErrorAction SilentlyContinue
        if ($content) {
            $inConclusion  = $false
            $conclusionLines = @()
            $dpcLine   = $content | Where-Object { $_ -match 'Highest DPC routine' } | Select-Object -First 1
            $isrLine   = $content | Where-Object { $_ -match 'Highest ISR routine' } | Select-Object -First 1
            $driverDPC = $content | Where-Object { $_ -match 'Driver with highest DPC' } | Select-Object -First 1

            foreach ($line in $content) {
                if ($line -match 'CONCLUSION') { $inConclusion = $true }
                if ($inConclusion) {
                    $conclusionLines += $line
                    if ($conclusionLines.Count -ge 6) { break }
                }
            }
            if ($dpcLine)   { Write-Log "    $dpcLine" "DarkYellow" }
            if ($driverDPC) { Write-Log "    $driverDPC" "DarkYellow" }
            if ($isrLine)   { Write-Log "    $isrLine" "Gray" }
            $conclusionLines | ForEach-Object { Write-Log "    $_" "DarkYellow" }
        }
        Write-Log ""
    }
} else {
    Write-Log "  Aucun rapport LatencyMon trouvé dans les 7 derniers jours." "Gray"
}

Save-Report

# ════════════════════════════════════════════════════════════
# 5b-EXT. VOLTAGE / THERMAL / THROTTLING — CPU i9-14900HX
# Voltage offset context, thermal throttling, CPU perf states
# ════════════════════════════════════════════════════════════
Write-Section "5b/14 — VOLTAGE / THERMAL / THROTTLING"

# ── 5b-1. Contexte voltage du jour (entrée manuelle)
# Daily voltage context — manually logged
Write-Sub "Contexte voltage — Historique du jour"

Write-Log "  Historique offset voltage relevé manuellement :" "Cyan"
Write-Log "  [Début après-midi] Offset CPU Core : $VOLT_MATIN    (configuré via BIOS ASUS G814JIR)" "DarkYellow"
Write-Log "  [Après rollback  ] Offset CPU Core : $VOLT_APRESMIDI (rollback prudentiel)" "Cyan"
Write-Log ""
Write-Log "  Rappel seuils pour i9-14900HX (P-core / E-core) :" "Gray"
Write-Log "  • Offset positif  (+mV) → augmente voltage → stabilité accrue, chauffe plus" "Gray"
Write-Log "  • Offset négatif  (-mV) → undervolt → risque instabilité si trop bas" "Gray"
Write-Log "  • Plage typique stable sur 14900HX : -20mV à -80mV (core)" "Gray"
Write-Log "  • +80mV est inhabituel — compense souvent une instab en undervolt" "Gray"
Write-Log "  • -50mV : conservateur, ne devrait pas poser problème" "Gray"
Write-Log ""
Write-Log "  → Corréler les événements thermiques ci-dessous avec ces horaires" "Cyan"
Write-Log "  → Si crashes post-rollback : peut indiquer une dépendance à l'overvolt" "DarkYellow"

# ── 5b-2. Événements thermiques & power throttling (72h)
# Thermal and power throttling events from Event Log
Write-Sub "Événements thermiques & power throttling (72h)"

# IDs clés pour throttling/thermal sur Intel :
# 19  = Microsoft-Windows-Kernel-Power : changement état puissance
# 37  = Microsoft-Windows-Kernel-Processor-Power : perf dégradée
# 55  = Microsoft-Windows-Kernel-Power : thermal throttle
# 56  = Microsoft-Windows-Kernel-Processor-Power : état processeur réduit
# 25  = Microsoft-Windows-Kernel-Acpi : thermal zone
# 109 = Microsoft-Windows-Kernel-Power : transition veille anormale
$thermalEvents = Get-WinEvent -FilterHashtable @{
    LogName   = 'System'
    StartTime = $SINCE_72H
} -ErrorAction SilentlyContinue |
    Where-Object {
        ($_.ProviderName -match 'Kernel-Power|Kernel-Processor-Power|Kernel-Acpi|ThermalZone') -and
        ($_.Id -in @(6, 19, 25, 37, 55, 56, 109))
    } |
    Sort-Object TimeCreated -Descending |
    Select-Object -First 50

if ($thermalEvents) {
    Write-Log "  ⚠  $($thermalEvents.Count) événement(s) thermique(s)/throttling (72h) :" "Red"
    foreach ($e in $thermalEvents) {
        $col = if ($e.Level -le 2) { "Red" } else { "DarkYellow" }
        $label = switch ($e.Id) {
            37  { "⚡ PERF DÉGRADÉE (throttle CPU)" }
            55  { "🌡 THERMAL THROTTLE" }
            56  { "⚡ ÉTAT PROC RÉDUIT" }
            25  { "🌡 THERMAL ZONE ACPI" }
            19  { "⚡ CHANGEMENT ÉTAT POWER" }
            109 { "💤 INIT HIBERNATE (anormal ?)" }
            6   { "💤 TRANSITION SLEEP" }
            default { "ID $($e.Id)" }
        }
        Write-Log ("  [{0}] {1} — {2}" -f `
            $e.TimeCreated.ToString('dd/MM HH:mm:ss'), $label, $e.ProviderName) $col
        Write-Log "    $(Truncate $e.Message 160)" "Gray"
    }
} else {
    Write-Log "  Aucun événement thermal/throttling détecté sur 72h. ✅" "Green"
}

# ── 5b-3. Dégradation performance CPU (Kernel-Processor-Power ID 37)
# CPU performance degradation events — dedicated sub-section
Write-Sub "Dégradation performance CPU (Kernel-Processor-Power ID 37)"

$perfDeg = Get-WinEvent -FilterHashtable @{
    LogName      = 'System'
    StartTime    = $SINCE_72H
    ProviderName = 'Microsoft-Windows-Kernel-Processor-Power'
    Id           = 37
} -ErrorAction SilentlyContinue | Sort-Object TimeCreated -Descending

if ($perfDeg) {
    Write-Log "  ⚠  $($perfDeg.Count) dégradation(s) CPU détectée(s) :" "Red"
    Write-Log "     → Typique d'un offset trop agressif ou d'un TDP mal configuré" "DarkRed"
    foreach ($e in $perfDeg) {
        Write-Log "  [$($e.TimeCreated.ToString('dd/MM HH:mm:ss'))] $(Truncate $e.Message 200)" "Red"
    }
} else {
    Write-Log "  Aucune dégradation performance CPU sur 72h. ✅" "Green"
}

# ── 5b-4. Fréquence CPU temps réel via compteurs de performance
# Real-time CPU frequency via Windows performance counters
Write-Sub "Fréquence CPU temps réel (10 échantillons × 2s = 20s)"

try {
    Write-Log "  Capture 20s de données CPU en cours..." "White"
    $cpuSamples = @()
    for ($i = 0; $i -lt 10; $i++) {
        $s = Get-Counter `
            '\Processor Information(_Total)\% Processor Performance', `
            '\Processor Information(_Total)\% of Maximum Frequency', `
            '\Processor(_Total)\% Processor Time' `
            -ErrorAction SilentlyContinue
        if ($s) { $cpuSamples += $s }
        Start-Sleep -Seconds 2
    }

    if ($cpuSamples) {
        $perfVals = $cpuSamples | ForEach-Object {
            ($_.CounterSamples | Where-Object { $_.Path -match 'Processor Performance' }).CookedValue
        }
        $freqVals = $cpuSamples | ForEach-Object {
            ($_.CounterSamples | Where-Object { $_.Path -match 'Maximum Frequency' }).CookedValue
        }
        $cpuVals  = $cpuSamples | ForEach-Object {
            ($_.CounterSamples | Where-Object { $_.Path -match 'Processor Time' }).CookedValue
        }

        $perfAvg = [math]::Round(($perfVals | Measure-Object -Average).Average, 1)
        $perfMin = [math]::Round(($perfVals | Measure-Object -Minimum).Minimum, 1)
        $freqAvg = [math]::Round(($freqVals | Measure-Object -Average).Average, 1)
        $freqMin = [math]::Round(($freqVals | Measure-Object -Minimum).Minimum, 1)
        $cpuAvg  = [math]::Round(($cpuVals  | Measure-Object -Average).Average, 1)

        # Détection throttling : chute de % of Maximum Frequency
        # Throttle detection: drop in % of Maximum Frequency
        $throttleCol = if ($freqMin -lt 50) { "Red" } elseif ($freqMin -lt 75) { "DarkYellow" } else { "Green" }
        $throttleMsg = if ($freqMin -lt 50) { "⚠ THROTTLING SÉVÈRE DÉTECTÉ" } `
                       elseif ($freqMin -lt 75) { "△ Throttling modéré" } `
                       else { "✅ Fréquence stable" }

        Write-Log "  % Processor Performance  : avg=$perfAvg%  min=$perfMin%" "White"
        Write-Log "  % of Maximum Frequency   : avg=$freqAvg%  min=$freqMin%  → $throttleMsg" $throttleCol
        Write-Log "  % Processor Time (load)  : avg=$cpuAvg%" "White"
        Write-Log ""
        Write-Log "  Base clock i9-14900HX : 2.2 GHz → max 5.8 GHz (P-core boost)" "Gray"
        # Estimation fréquence basée sur 5800 MHz max / Estimate based on 5800 MHz max
        $estimatedMHz = [math]::Round($freqAvg * 58, 0)
        Write-Log "  Fréquence estimée moy. : ~$estimatedMHz MHz" "White"

        if ($freqMin -lt 50) {
            Write-Log ""
            Write-Log "  → CPU se bride significativement — offset voltage ou TDP suspect" "Red"
            Write-Log "  → Contexte du jour : $VOLT_MATIN (matin) → $VOLT_APRESMIDI (après-midi)" "DarkRed"
            Write-Log "  → Tester avec OCCT/Cinebench pour valider la stabilité à $VOLT_APRESMIDI" "DarkRed"
        }
    }
} catch {
    Write-Log "  Erreur lecture compteurs CPU fréquence : $_" "DarkYellow"
}

# ── 5b-5. Températures ACPI instantanées via WMI
# Instant temperatures via WMI MSAcpi_ThermalZoneTemperature
Write-Sub "Températures ACPI instantanées (WMI)"

try {
    $thermalZones = Get-WmiObject MSAcpi_ThermalZoneTemperature -Namespace "root\wmi" -ErrorAction SilentlyContinue
    if ($thermalZones) {
        Write-Log "  Zones thermiques ACPI :" "White"
        foreach ($tz in $thermalZones) {
            # Conversion : Kelvin × 10 → Celsius / Convert: Kelvin × 10 to Celsius
            $tempC = [math]::Round(($tz.CurrentTemperature / 10) - 273.15, 1)
            $critC = [math]::Round(($tz.CriticalTripPoint / 10) - 273.15, 1)
            $col   = if ($tempC -gt 95) { "Red" } elseif ($tempC -gt 80) { "DarkYellow" } else { "Green" }
            Write-Log ("  {0,-40} Actuelle : {1}°C  /  Critique : {2}°C" -f `
                $tz.InstanceName, $tempC, $critC) $col
        }
    } else {
        Write-Log "  Zones thermiques ACPI non disponibles via WMI (normal sur certains UEFI)." "Gray"
        Write-Log "  → Utiliser HWiNFO64 pour un suivi précis des températures CPU/GPU" "DarkYellow"
    }
} catch {
    Write-Log "  Erreur lecture températures ACPI : $_" "DarkYellow"
}

# ── 5b-6. Logs HWiNFO / ThrottleStop / Intel XTU si présents
# HWiNFO / ThrottleStop / Intel XTU logs if present
Write-Sub "Logs HWiNFO / ThrottleStop / Intel XTU (si présents)"

$voltLogPaths = @(
    "$env:USERPROFILE\Documents\HWiNFO64.CSV",
    "$env:USERPROFILE\Desktop\HWiNFO64.CSV",
    "C:\Users\Minho Lee\Desktop\Sasha\A\HWiNFO64.CSV",
    "$env:APPDATA\ThrottleStop\ThrottleStop.ini",
    "$env:LOCALAPPDATA\Intel\Intel Extreme Tuning Utility\Logs",
    "C:\XTU\Logs"
)

$foundVoltLog = $false
foreach ($vp in $voltLogPaths) {
    if (Test-Path $vp) {
        $foundVoltLog = $true
        $vpItem = Get-Item $vp
        Write-Log "  ✅ Trouvé : $vp" "Green"

        if ($vpItem.PSIsContainer) {
            # Dossier XTU/logs : lister les fichiers récents / XTU folder: list recent logs
            $xtuLogs = Get-ChildItem $vp -Filter "*.log" -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -ge $SINCE_72H } |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 3
            foreach ($xl in $xtuLogs) {
                Write-Log "  [$($xl.LastWriteTime.ToString('dd/MM HH:mm'))] $($xl.Name)" "White"
                Get-Content $xl.FullName -Tail 30 -ErrorAction SilentlyContinue |
                    Where-Object { $_ -match 'volt|mV|offset|throttl|temp|crash' } |
                    ForEach-Object { Write-Log "    $_" "Gray" }
            }
        } elseif ($vp -match '\.CSV$') {
            # HWiNFO CSV — extraire les 20 dernières lignes
            # HWiNFO CSV — extract last 20 lines
            $hwLines = Get-Content $vp -Tail 20 -ErrorAction SilentlyContinue
            Write-Log "  Dernières 20 lignes HWiNFO :" "Gray"
            $hwLines | ForEach-Object { Write-Log "    $_" "Gray" }
        } elseif ($vp -match 'ThrottleStop\.ini') {
            # ThrottleStop config — lire les paramètres voltage
            # ThrottleStop config — read voltage parameters
            $tsConfig = Get-Content $vp -ErrorAction SilentlyContinue
            $tsVolt = $tsConfig | Where-Object { $_ -match 'VoltageOffset|FIVR|Core Volt' }
            if ($tsVolt) {
                Write-Log "  ThrottleStop voltage config :" "White"
                $tsVolt | ForEach-Object { Write-Log "    $_" "Gray" }
            }
        }
    }
}

if (-not $foundVoltLog) {
    Write-Log "  Aucun log HWiNFO/ThrottleStop/XTU trouvé." "Gray"
    Write-Log "  → Conseil : activer HWiNFO64 'Log to file' pour le prochain test" "DarkYellow"
    Write-Log "  → Chemin suggéré : $env:USERPROFILE\Documents\HWiNFO64.CSV" "Gray"
}

Save-Report

# ════════════════════════════════════════════════════════════
# 6. SERVICES EN ECHEC / INSTABLES
# Failed / unstable services
# ════════════════════════════════════════════════════════════
Write-Section "6/14 — SERVICES PROBLÉMATIQUES"

# 6a. Services auto arrêtés anormalement
# Auto services that are stopped — should not be
Write-Sub "Services AUTO anormalement arrêtés"

# Exclure les services connus pour être stop par design
# Exclude services known to be stopped by design
$knownStoppedOK = @('MapsBroker','PrintNotify','RemoteRegistry','RetailDemo',
                    'PeerDistSvc','WbioSrvc','WpcMonSvc','XblAuthManager',
                    'XblGameSave','XboxGipSvc','XboxNetApiSvc','PhoneSvc',
                    'SEMgrSvc','autotimesvc','AJRouter','bthserv')

$failedSvcs = Get-Service -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Status -eq 'Stopped' -and
        $_.StartType -eq 'Automatic' -and
        $_.Name -notin $knownStoppedOK
    }

if ($failedSvcs) {
    Write-Log "  ⚠  $($failedSvcs.Count) service(s) AUTO arrêté(s) (hors liste blanche) :" "Red"
    $failedSvcs | ForEach-Object {
        Write-Log "  [$($_.Name)] $($_.DisplayName)" "DarkRed"
    }
} else {
    Write-Log "  Aucun service AUTO arrêté anormalement. ✅" "Green"
}

# 6b. Erreurs SCM depuis le 21/05
# Service Control Manager errors since analysis start
Write-Sub "Erreurs Service Control Manager (ID 7000-7043)"

$svcErrors = Get-WinEvent -FilterHashtable @{
    LogName   = 'System'
    StartTime = $SINCE
    Id        = 7000, 7001, 7009, 7011, 7023, 7024, 7026, 7034, 7043
} -ErrorAction SilentlyContinue |
    Sort-Object TimeCreated -Descending |
    Select-Object -First 20

if ($svcErrors) {
    Write-Log "  $($svcErrors.Count) erreur(s) SCM (top 20) :" "DarkYellow"
    foreach ($e in $svcErrors) {
        Write-Log "  [$($e.TimeCreated.ToString('dd/MM HH:mm'))] ID:$($e.Id)" "DarkYellow"
        Write-Log "    $(Truncate $e.Message 140)" "Gray"
    }
} else {
    Write-Log "  Aucune erreur SCM depuis le 21/05/2026. ✅" "Green"
}

# 6c. Services suspects installés par SDIO (PTIMon, AltA2DP, etc.)
# Suspect services installed by SDIO
Write-Sub "Services suspects (PTIMon / AltA2DP / Sonix)"

$suspectSvcs = @('PTIMon','AltA2DP','snDMFT','usbvideo')
foreach ($svc in $suspectSvcs) {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($s) {
        $col = if ($s.Status -eq 'Running') { "Red" } else { "DarkYellow" }
        Write-Log "  [$svc] Status: $($s.Status) — StartType: $($s.StartType)" $col
        if ($svc -eq 'PTIMon') {
            Write-Log "    ⚠  Driver Intel de 2012 — INCOMPATIBLE avec i9-14900HX — À supprimer !" "Red"
        }
        if ($svc -eq 'AltA2DP') {
            Write-Log "    ⚠  Reboot nécessaire après install — peut causer IRQL BSOD" "DarkYellow"
        }
    } else {
        Write-Log "  [$svc] Non trouvé (probablement supprimé par RAPR ✓)" "Green"
    }
}

# 6d. Logs RAPR (Driver Store Explorer) s'ils existent
Write-Sub "Logs RAPR (Driver Store Explorer)"

$raprLogPaths = @(
    "C:\Users\Minho Lee\Desktop\Sasha\RAPR",
    "C:\Users\Minho Lee\Desktop\Sasha\Rapr",
    "C:\Users\Minho Lee\Desktop\Sasha\DriverStoreExplorer",
	"C:\Users\Minho Lee\Desktop\Sasha\A\DriverStoreExplorer.v0.11.114",
	"C:\Users\Minho Lee\Desktop\Sasha\A\DriverStoreExplorer*",
	"C:\Users\Minho Lee\Desktop\Sasha\A\DriverStoreExplorer.*",
    "$env:USERPROFILE\Desktop\Sasha\RAPR",
    "$env:USERPROFILE\Desktop\Sasha\Rapr"
) | Where-Object { Test-Path $_ }

if ($raprLogPaths) {
    foreach ($raprPath in $raprLogPaths) {
        Write-Log "  Dossier RAPR trouvé : $raprPath" "Green"
        $raprLogs = Get-ChildItem $raprPath -Recurse -Include "*.log","*.txt","*.csv" -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $SINCE } |
            Sort-Object LastWriteTime -Descending

        if ($raprLogs) {
            Write-Log "  $($raprLogs.Count) fichier(s) log RAPR :" "White"
            foreach ($log in $raprLogs) {
                Write-Log "  [$($log.LastWriteTime.ToString('dd/MM HH:mm'))] $($log.FullName)" "White"
                $lines = Get-Content $log.FullName -Tail 40 -ErrorAction SilentlyContinue
                if ($lines) {
                    Write-Log "  --- Extrait (40 dernières lignes) ---" "DarkGray"
                    $lines | ForEach-Object { Write-Log "    $_" "Gray" }
                    Write-Log "  --- Fin extrait ---" "DarkGray"
                }
            }
        } else {
            Write-Log "  Aucun log RAPR récent trouvé dans ce dossier." "Gray"
        }
    }
} else {
    Write-Log "  Aucun dossier RAPR trouvé dans Desktop\Sasha." "DarkYellow"
    Write-Log "  → Si RAPR est ailleurs, ajouter son chemin dans `$raprLogPaths`." "Gray"
}

Save-Report

# ════════════════════════════════════════════════════════════
# 7. ÉTAT DES DRIVERS ACTUELS (RAPR/PnPUtil)
# Current driver state
# ════════════════════════════════════════════════════════════
Write-Section "7/14 — ÉTAT DRIVERS ACTUELS (PnPUtil)"

# 7a. Liste des drivers tiers dans le store
# List third-party drivers in the driver store
Write-Sub "Drivers tiers dans le DriverStore"

try {
    $pnpOut = pnputil /enum-drivers 2>&1
    Write-Log ($pnpOut | Out-String) "Gray"
} catch {
    Write-Log "  Impossible d'interroger pnputil : $_" "Red"
}

# 7b. Périphériques en erreur
# Devices with errors
Write-Sub "Périphériques en erreur (ConfigManager Error > 0)"

$brokenDevs = Get-WmiObject Win32_PnPEntity |
    Where-Object { $_.ConfigManagerErrorCode -gt 0 } |
    Select-Object Name, DeviceID, ConfigManagerErrorCode |
    Sort-Object ConfigManagerErrorCode -Descending

if ($brokenDevs) {
    Write-Log "  ⚠  $($brokenDevs.Count) périphérique(s) en erreur :" "Red"
    foreach ($d in $brokenDevs) {
        $errMsg = switch ($d.ConfigManagerErrorCode) {
            1  { "Device not configured" }
            3  { "Driver corrupt or missing" }
            10 { "Device cannot start" }
            18 { "Reinstall drivers" }
            22 { "Device disabled" }
            28 { "Drivers not installed" }
            43 { "Device stopped (Windows reported a problem)" }
            default { "Error code $($d.ConfigManagerErrorCode)" }
        }
        Write-Log "  [Err $($d.ConfigManagerErrorCode)] $($d.Name) — $errMsg" "Red"
    }
} else {
    Write-Log "  Aucun périphérique en erreur. ✅" "Green"
}

# 7c. Snapshot complet PnP exporté en CSV (référence future)
# Full PnP snapshot exported to CSV for future reference
Write-Sub "Snapshot PnP complet → CSV (référence future)"

try {
    $pnpAll = Get-PnpDevice -ErrorAction SilentlyContinue |
        Select-Object Status, Class, FriendlyName, InstanceId, Present
    if ($pnpAll) {
        $pnpAll | Export-Csv -Path $PNPCSV_FILE -Encoding UTF8 -NoTypeInformation
        Write-Log "  ✅ Snapshot PnP complet exporté : $PNPCSV_FILE" "Green"
        Write-Log "  $($pnpAll.Count) périphériques enregistrés" "White"

        # Résumé par statut / Summary by status
        $pnpGroups = $pnpAll | Group-Object Status | Sort-Object Count -Descending
        foreach ($g in $pnpGroups) {
            $col = if ($g.Name -eq 'OK') { "Green" } elseif ($g.Name -eq 'Error') { "Red" } else { "DarkYellow" }
            Write-Log "  Statut $($g.Name) : $($g.Count) périphérique(s)" $col
        }
    }
} catch {
    Write-Log "  Erreur export PnP CSV : $_" "DarkYellow"
}

Save-Report

# ════════════════════════════════════════════════════════════
# 8. CONFIGURATION BCD + BOOT + FIRMWARE UEFI
# BCD configuration, boot events, UEFI firmware entries
# ════════════════════════════════════════════════════════════
Write-Section "8/14 — BCD & CONFIGURATION BOOT & FIRMWARE UEFI"

# 8a. BCD complet
# Full BCD configuration
Write-Sub "Configuration BCD (bcdedit /enum ALL)"
try {
    $bcd = bcdedit /enum ALL 2>&1
    $bcd | ForEach-Object { Write-Log "  $_" "Gray" }
} catch {
    Write-Log "  Erreur lecture BCD : $_" "Red"
}

# 8b. Entrées firmware UEFI (bcdedit /enum firmware)
# UEFI firmware boot entries — valider que rien n'a bougé avec les modifs BIOS
Write-Sub "Entrées firmware UEFI (bcdedit /enum firmware)"

try {
    $firmware = bcdedit /enum firmware 2>&1
    if ($firmware -match 'The boot configuration data store could not be opened') {
        Write-Log "  ⚠  Accès firmware UEFI refusé (normal si Secure Boot strict)." "DarkYellow"
    } else {
        Write-Log "  Entrées UEFI firmware :" "White"
        $firmware | ForEach-Object { Write-Log "  $_" "Gray" }
    }
} catch {
    Write-Log "  Erreur lecture firmware UEFI : $_" "DarkYellow"
}

# 8c. Événements boot critiques
# Critical boot events
Write-Sub "Événements boot critiques (System)"

$bootEvents = Get-WinEvent -FilterHashtable @{
    LogName   = 'System'
    StartTime = $SINCE
    Level     = 1, 2
} -ErrorAction SilentlyContinue |
    Where-Object {
        $_.ProviderName -match 'Boot|Loader|winload|BCD|EFI|UEFI|disk|NVMe|storage' -or
        $_.Message      -match 'winload|efi|boot|BCD|NVMe|firmware|disk'
    } |
    Sort-Object TimeCreated -Descending |
    Select-Object -First 15

if ($bootEvents) {
    foreach ($e in $bootEvents) {
        Write-Log "  [$($e.TimeCreated.ToString('dd/MM HH:mm'))] ID:$($e.Id) $($e.ProviderName)" "Red"
        Write-Log "    $(Truncate $e.Message 150)" "Gray"
    }
} else {
    Write-Log "  Aucun événement critique lié au boot. ✅" "Green"
}

Save-Report

# ════════════════════════════════════════════════════════════
# 9. WIFI — HISTORIQUE DÉCONNEXIONS (Intel AX211)
# WiFi — disconnect history — Intel AX211 known driver bugs
# ════════════════════════════════════════════════════════════
Write-Section "9/14 — WIFI (Intel AX211 — Déconnexions & État)"

# 9a. Interface WiFi actuelle
# Current WiFi interface state
Write-Sub "État interface WiFi (netsh wlan show interfaces)"

try {
    $wlanIf = netsh wlan show interfaces 2>&1
    $wlanIf | ForEach-Object { Write-Log "  $_" "Gray" }
} catch {
    Write-Log "  Erreur lecture interface WiFi : $_" "DarkYellow"
}

# 9b. Drivers WiFi installés
# Installed WiFi drivers
Write-Sub "Driver WiFi actuel (netsh wlan show drivers)"

try {
    $wlanDrv = netsh wlan show drivers 2>&1
    $wlanDrv | ForEach-Object { Write-Log "  $_" "Gray" }
} catch {
    Write-Log "  Erreur lecture driver WiFi : $_" "DarkYellow"
}

# 9c. Événements déconnexion WiFi depuis 72h
# WiFi disconnect events last 72h — WLAN-Autoconfig source
# ID 8001 = connected, 8003 = disconnected, 11001/11002 = scan, 4001 = auth fail
Write-Sub "Événements WiFi (WLAN-Autoconfig 72h) — déconnexions & erreurs"

$wifiEvents = Get-WinEvent -FilterHashtable @{
    LogName      = 'Microsoft-Windows-WLAN-AutoConfig/Operational'
    StartTime    = $SINCE_72H
} -ErrorAction SilentlyContinue |
    Where-Object { $_.Id -in @(8001, 8003, 11001, 11002, 4001, 20019) } |
    Sort-Object TimeCreated -Descending |
    Select-Object -First 40

if ($wifiEvents) {
    $disconnects = $wifiEvents | Where-Object { $_.Id -eq 8003 }
    $connects    = $wifiEvents | Where-Object { $_.Id -eq 8001 }
    Write-Log "  Connexions     : $($connects.Count)" "Green"
    Write-Log "  Déconnexions   : $($disconnects.Count)$(if ($disconnects.Count -gt 5) {' ⚠ Instabilité WiFi !'} else {''})" $(if ($disconnects.Count -gt 5) {"Red"} else {"White"})
    Write-Log ""
    foreach ($e in $wifiEvents) {
        $col = switch ($e.Id) {
            8001 { "Green" }
            8003 { "DarkYellow" }
            4001 { "Red" }
            default { "Gray" }
        }
        $label = switch ($e.Id) {
            8001  { "✅ CONNECTÉ" }
            8003  { "⚡ DÉCONNECTÉ" }
            11001 { "🔍 Scan réseau" }
            4001  { "❌ ÉCHEC AUTH" }
            20019 { "⚠  Erreur WLAN" }
            default { "ID $($e.Id)" }
        }
        Write-Log ("  [{0}] {1}" -f $e.TimeCreated.ToString('dd/MM HH:mm:ss'), $label) $col
        Write-Log "    $(Truncate $e.Message 130)" "Gray"
    }
} else {
    Write-Log "  Aucun événement WiFi notable sur 72h (journal peut être vide si désactivé)." "Gray"
    Write-Log "  → Activer : eventvwr → Applications et services → Microsoft-Windows-WLAN-AutoConfig" "DarkYellow"
}

# 9d. Événements NDIS (Network Driver Interface) — erreurs driver réseau
# NDIS network driver events — driver-level errors
Write-Sub "Événements NDIS (System 72h) — erreurs driver réseau"

$ndisEvents = Get-WinEvent -FilterHashtable @{
    LogName   = 'System'
    StartTime = $SINCE_72H
} -ErrorAction SilentlyContinue |
    Where-Object {
        $_.ProviderName -match 'NDIS|ndis|Tcpip|netio' -and $_.Level -le 3
    } |
    Sort-Object TimeCreated -Descending |
    Select-Object -First 20

if ($ndisEvents) {
    Write-Log "  $($ndisEvents.Count) événement(s) NDIS/réseau (top 20) :" "DarkYellow"
    foreach ($e in $ndisEvents) {
        $col = if ($e.Level -le 2) { "Red" } else { "DarkYellow" }
        Write-Log "  [$($e.TimeCreated.ToString('dd/MM HH:mm'))] ID:$($e.Id) $($e.ProviderName)" $col
        Write-Log "    $(Truncate $e.Message 130)" "Gray"
    }
} else {
    Write-Log "  Aucun événement NDIS/réseau notable sur 72h. ✅" "Green"
}

Save-Report

# ════════════════════════════════════════════════════════════
# 10. TACHES PLANIFIÉES SUSPECTES (Armoury Crate, ASUS, SDIO)
# Scheduled tasks — Armoury Crate zombies, ASUS, SDIO
# ════════════════════════════════════════════════════════════
Write-Section "10/14 — TÂCHES PLANIFIÉES SUSPECTES"

# 10a. Tâches liées à Armoury Crate / ASUS / SDIO
# Tasks related to Armoury Crate / ASUS / SDIO
Write-Sub "Tâches planifiées ASUS / Armoury Crate / SDIO / ROG"

try {
    $allTasks = Get-ScheduledTask -ErrorAction SilentlyContinue
    $suspectTasks = $allTasks | Where-Object {
        $_.TaskName -match 'ASUS|Armoury|ArmouryCrate|ROG|Aura|GameFirst|LiveDash|SDIO|PTIMon|AltA2DP' -or
        $_.TaskPath -match 'ASUS|Armoury|ROG'
    }

    if ($suspectTasks) {
        Write-Log "  $($suspectTasks.Count) tâche(s) ASUS/Armoury/ROG trouvée(s) :" "DarkYellow"
        foreach ($t in $suspectTasks) {
            $state = $t.State
            $col   = if ($state -eq 'Running') { "Red" } elseif ($state -eq 'Ready') { "DarkYellow" } else { "Gray" }
            Write-Log ("  [{0}] {1}{2}" -f $state, $t.TaskPath, $t.TaskName) $col
            # Afficher l'action de la tâche (exécutable lancé)
            # Show task action (executable being launched)
            $t.Actions | ForEach-Object {
                if ($_.Execute) {
                    Write-Log "    → Execute : $($_.Execute) $($_.Arguments)" "Gray"
                }
            }
        }
        Write-Log ""
        Write-Log "  → Les tâches Armoury Crate 'Ready' peuvent se réactiver post-update." "DarkYellow"
        Write-Log "  → Désactiver via : Disable-ScheduledTask -TaskName '<nom>'" "Gray"
    } else {
        Write-Log "  Aucune tâche planifiée ASUS/Armoury/ROG trouvée. ✅" "Green"
    }
} catch {
    Write-Log "  Erreur lecture tâches planifiées : $_" "DarkYellow"
}

# 10b. Événements TaskScheduler (72h) — échecs de tâches
# TaskScheduler events (72h) — failed tasks
Write-Sub "Événements TaskScheduler (72h) — échecs (ID 101, 103, 201, 203)"

$taskEvents = Get-WinEvent -FilterHashtable @{
    LogName   = 'Microsoft-Windows-TaskScheduler/Operational'
    StartTime = $SINCE_72H
    Id        = 101, 103, 201, 203  # Launch/completion failures
} -ErrorAction SilentlyContinue |
    Sort-Object TimeCreated -Descending |
    Select-Object -First 30

if ($taskEvents) {
    Write-Log "  $($taskEvents.Count) échec(s) de tâches planifiées (top 30) :" "DarkYellow"
    foreach ($e in $taskEvents) {
        $col = if ($e.Id -in @(101,201)) { "Red" } else { "DarkYellow" }
        Write-Log "  [$($e.TimeCreated.ToString('dd/MM HH:mm'))] ID:$($e.Id) $(Truncate $e.Message 120)" $col
    }
} else {
    Write-Log "  Aucun échec de tâche planifiée sur 72h. ✅" "Green"
}

Save-Report

# ════════════════════════════════════════════════════════════
# 11. LOGS COMPLETS — 72 DERNIÈRES HEURES
# Full logs — last 72 hours
# ════════════════════════════════════════════════════════════
Write-Section "11/14 — LOGS COMPLETS 72H (System / Application / Setup / Security)"

# 11a. Journal System — toutes sévérités sur 72h
# System log — all severities over 72h
Write-Sub "Journal System (72h) — Erreurs & Avertissements"

$sys72 = Get-WinEvent -FilterHashtable @{
    LogName   = 'System'
    StartTime = $SINCE_72H
    Level     = 1, 2, 3   # Critical, Error, Warning
} -ErrorAction SilentlyContinue |
    Sort-Object TimeCreated -Descending |
    Select-Object -First 100

if ($sys72) {
    Write-Log "  $($sys72.Count) entrée(s) System (top 100 — Critical/Error/Warning) :" "White"
    foreach ($e in $sys72) {
        $col = switch ($e.Level) {
            1 { "Red" }
            2 { "DarkRed" }
            3 { "DarkYellow" }
            default { "Gray" }
        }
        $lvl = switch ($e.Level) { 1 {"CRIT"} 2 {"ERR "} 3 {"WARN"} default {"INFO"} }
        Write-Log ("  [{0}] {1} ID:{2,-5} {3}" -f `
            $e.TimeCreated.ToString('dd/MM HH:mm:ss'), $lvl, $e.Id, $e.ProviderName) $col
        Write-Log "    $(Truncate $e.Message 130)" "Gray"
    }
} else {
    Write-Log "  Aucune erreur/avertissement System sur 72h. ✅" "Green"
}

# 11b. Journal Application — 72h
# Application log — 72h
Write-Sub "Journal Application (72h) — Erreurs & Avertissements"

$app72 = Get-WinEvent -FilterHashtable @{
    LogName   = 'Application'
    StartTime = $SINCE_72H
    Level     = 1, 2, 3
} -ErrorAction SilentlyContinue |
    Sort-Object TimeCreated -Descending |
    Select-Object -First 80

if ($app72) {
    Write-Log "  $($app72.Count) entrée(s) Application (top 80) :" "White"
    foreach ($e in $app72) {
        $col = switch ($e.Level) { 1 {"Red"} 2 {"DarkRed"} 3 {"DarkYellow"} default {"Gray"} }
        $lvl = switch ($e.Level) { 1 {"CRIT"} 2 {"ERR "} 3 {"WARN"} default {"INFO"} }
        Write-Log ("  [{0}] {1} ID:{2,-5} {3}" -f `
            $e.TimeCreated.ToString('dd/MM HH:mm:ss'), $lvl, $e.Id, $e.ProviderName) $col
        Write-Log "    $(Truncate $e.Message 130)" "Gray"
    }
} else {
    Write-Log "  Aucune erreur/avertissement Application sur 72h. ✅" "Green"
}

# 11c. Journal Setup — 72h (installations Windows Update, drivers)
# Setup log — 72h
Write-Sub "Journal Setup (72h) — Installations & Mises à jour"

$setup72 = Get-WinEvent -FilterHashtable @{
    LogName   = 'Setup'
    StartTime = $SINCE_72H
} -ErrorAction SilentlyContinue |
    Sort-Object TimeCreated -Descending |
    Select-Object -First 50

if ($setup72) {
    Write-Log "  $($setup72.Count) entrée(s) Setup (top 50) :" "White"
    foreach ($e in $setup72) {
        $col = if ($e.Level -le 2) { "DarkRed" } elseif ($e.Level -eq 3) { "DarkYellow" } else { "Gray" }
        Write-Log ("  [{0}] ID:{1,-5} {2}" -f `
            $e.TimeCreated.ToString('dd/MM HH:mm:ss'), $e.Id, $e.ProviderName) $col
        Write-Log "    $(Truncate $e.Message 130)" "Gray"
    }
} else {
    Write-Log "  Aucune entrée Setup sur 72h." "Gray"
}

# 11d. Journal Security — 72h (échecs d'audit, accès refusés)
# Security log — 72h
Write-Sub "Journal Security (72h) — Échecs d'audit (ID 4625, 4673, 4674)"

$sec72 = Get-WinEvent -FilterHashtable @{
    LogName   = 'Security'
    StartTime = $SINCE_72H
    Id        = 4625, 4673, 4674, 4776, 4648
} -ErrorAction SilentlyContinue |
    Sort-Object TimeCreated -Descending |
    Select-Object -First 30

if ($sec72) {
    Write-Log "  $($sec72.Count) événement(s) de sécurité notables (top 30) :" "DarkYellow"
    foreach ($e in $sec72) {
        Write-Log ("  [{0}] ID:{1} {2}" -f `
            $e.TimeCreated.ToString('dd/MM HH:mm:ss'), $e.Id, $e.ProviderName) "DarkYellow"
        Write-Log "    $(Truncate $e.Message 120)" "Gray"
    }
} else {
    Write-Log "  Aucun échec d'audit de sécurité notable sur 72h. ✅" "Green"
}

# 11e. Reliability Monitor — crashes & freezes applicatifs
# Reliability Monitor events — app crashes and hangs
Write-Sub "Journal Fiabilité Windows (72h) — Crashes & Freezes"

$reliability72 = Get-WinEvent -FilterHashtable @{
    LogName   = 'Application'
    StartTime = $SINCE_72H
    Id        = 1000, 1001, 1002
} -ErrorAction SilentlyContinue |
    Sort-Object TimeCreated -Descending |
    Select-Object -First 30

if ($reliability72) {
    Write-Log "  $($reliability72.Count) crash(s)/hang(s) applicatif(s) (top 30) :" "DarkYellow"
    foreach ($e in $reliability72) {
        $type = switch ($e.Id) {
            1000 { "CRASH appli" }
            1001 { "RAPPORT WER" }
            1002 { "FREEZE appli" }
        }
        Write-Log ("  [{0}] {1} — {2}" -f `
            $e.TimeCreated.ToString('dd/MM HH:mm:ss'), $type, $e.ProviderName) "DarkYellow"
        Write-Log "    $(Truncate $e.Message 150)" "Gray"
    }
} else {
    Write-Log "  Aucun crash/freeze applicatif sur 72h. ✅" "Green"
}

# 11f. Journaux WDF / DCOM / WMI / Kernel-PnP (72h)
# WDF / DCOM / WMI / Kernel-PnP logs
Write-Sub "Journaux WDF / DCOM / WMI / Kernel-PnP (72h)"

$wdf72 = Get-WinEvent -FilterHashtable @{
    LogName   = 'System'
    StartTime = $SINCE_72H
} -ErrorAction SilentlyContinue |
    Where-Object {
        $_.ProviderName -match 'Wdf|DCOM|WMI|Kernel-PnP|Ntfs|disk|volmgr|storahci' -and
        $_.Level -le 3
    } |
    Sort-Object TimeCreated -Descending |
    Select-Object -First 40

if ($wdf72) {
    Write-Log "  $($wdf72.Count) événement(s) WDF/DCOM/WMI/PnP (top 40) :" "DarkYellow"
    foreach ($e in $wdf72) {
        $col = if ($e.Level -le 2) { "Red" } else { "DarkYellow" }
        Write-Log ("  [{0}] ID:{1,-5} {2}" -f `
            $e.TimeCreated.ToString('dd/MM HH:mm:ss'), $e.Id, $e.ProviderName) $col
        Write-Log "    $(Truncate $e.Message 130)" "Gray"
    }
} else {
    Write-Log "  Aucun événement WDF/DCOM/WMI/PnP notable sur 72h. ✅" "Green"
}

# 11g. SetupAPI Dev Log — dernières 200 lignes filtrées
# SetupAPI file logs — driver installations detail
Write-Sub "SetupAPI Dev Log (fichier — dernières 200 lignes)"

$setupApiLog = "$env:SystemRoot\INF\setupapi.dev.log"
if (Test-Path $setupApiLog) {
    $setupApiAge = (Get-Date) - (Get-Item $setupApiLog).LastWriteTime
    Write-Log "  Fichier : $setupApiLog" "White"
    Write-Log ("  Modifié il y a : {0}h {1}min" -f [math]::Floor($setupApiAge.TotalHours), $setupApiAge.Minutes) "White"
    $setupLines = Get-Content $setupApiLog -Tail 200 -ErrorAction SilentlyContinue
    if ($setupLines) {
        # Filtrer les lignes importantes (erreurs, warnings, installs)
        # Filter important lines (errors, warnings, installs)
        $important = $setupLines | Where-Object {
            $_ -match '^\!|error|warning|failed|Section start|Section end|EXIT STATUS' -or
            $_ -match 'PTIMon|AltA2DP|ptimon|alta2dp|Luculent|Sonix'
        }
        if ($important) {
            Write-Log "  Lignes importantes filtrées :" "Yellow"
            $important | ForEach-Object { Write-Log "    $_" "Gray" }
        }
        Write-Log ""
        Write-Log "  Dernières 50 lignes brutes :" "DarkGray"
        $setupLines | Select-Object -Last 50 | ForEach-Object { Write-Log "    $_" "Gray" }
        Write-Log "  --- Fin extrait ---" "DarkGray"
    }
} else {
    Write-Log "  Fichier setupapi.dev.log introuvable." "DarkYellow"
}

Save-Report

# ════════════════════════════════════════════════════════════
# 12. POINTS DE RESTAURATION — 72 DERNIÈRES HEURES
# Restore points — last 72 hours
# ════════════════════════════════════════════════════════════
Write-Section "12/14 — POINTS DE RESTAURATION (72H)"

# 12a. Tous les points de restauration disponibles
# All available restore points
Write-Sub "Tous les points de restauration disponibles"

try {
    $allRP = Get-ComputerRestorePoint -ErrorAction Stop | Sort-Object CreationTime -Descending

    if ($allRP) {
        Write-Log "  $($allRP.Count) point(s) de restauration au total :" "White"
        Write-Log ""
        foreach ($rp in $allRP) {
            $isRecent   = $rp.CreationTime -ge $SINCE_72H
            $isCrashDay = $rp.CreationTime -ge $SINCE

            $col   = if ($isRecent) { "Cyan" } else { "Gray" }
            $badge = if ($isRecent) { "🕐 72H" } elseif ($isCrashDay) { "📅 21/05" } else { "     " }

            Write-Log ("  {0} [{1}] RP#{2,-5} — {3}" -f `
                $badge,
                $rp.CreationTime.ToString('dd/MM/yyyy HH:mm:ss'),
                $rp.SequenceNumber,
                $rp.Description) $col

            $rpType = switch ($rp.RestorePointType) {
                0  { "Manual checkpoint" }
                1  { "Application install" }
                2  { "Application uninstall" }
                6  { "Restore operation" }
                7  { "Checkpoint" }
                10 { "Device driver install" }
                12 { "Modify settings" }
                13 { "Cancelled operation" }
                default { "Type $($rp.RestorePointType)" }
            }
            Write-Log ("             Type   : {0}" -f $rpType) "DarkGray"

            # Avertissement si antérieur aux drivers SDIO (09h04 le 21/05)
            # Warning if it predates SDIO driver install
            $crashTime = [datetime]"2026-05-21 09:00:00"
            if ($rp.CreationTime -lt $crashTime -and $rp.CreationTime -ge $SINCE.AddDays(-7)) {
                Write-Log "             ✅ Antérieur aux drivers SDIO (09h04) — UTILISABLE pour rollback" "Green"
            }
        }

        Write-Log ""
        $recent72 = $allRP | Where-Object { $_.CreationTime -ge $SINCE_72H }
        if ($recent72) {
            Write-Log "  Points dans les 72h :" "Cyan"
            foreach ($rp in $recent72) {
                Write-Log ("  → [#{0}] {1} — {2}" -f `
                    $rp.SequenceNumber,
                    $rp.CreationTime.ToString('dd/MM/yyyy HH:mm:ss'),
                    $rp.Description) "Cyan"
            }
        } else {
            Write-Log "  Aucun point de restauration dans les 72 dernières heures." "DarkYellow"
            Write-Log "  (Protection système peut être désactivée ou espace disque insuffisant)" "Gray"
        }

    } else {
        Write-Log "  Aucun point de restauration trouvé." "DarkYellow"
        Write-Log "  → Vérifier : Panneau de config → Système → Protection du système" "Gray"
    }
} catch {
    Write-Log "  Erreur lecture des points de restauration : $_" "Red"
    Write-Log "  (Nécessite d'être Administrateur + Protection système activée)" "Gray"
}

# 12b. État de la Protection Système par volume (VSS + espace disque)
# System Protection status per volume
Write-Sub "État Protection Système + VSS + espace disque C:"

try {
    $srKey    = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore"
    $srConfig = Get-ItemProperty $srKey -ErrorAction SilentlyContinue

    if ($srConfig) {
        Write-Log "  RPSessionInterval : $($srConfig.RPSessionInterval)" "Gray"
        Write-Log "  RPLifeInterval    : $($srConfig.RPLifeInterval) sec ($([math]::Round($srConfig.RPLifeInterval/86400,1)) jours)" "Gray"
    }

    $vss = vssadmin list shadowstorage 2>&1
    if ($vss) {
        Write-Log ""
        Write-Log "  Stockage VSS (Shadow Copy) :" "White"
        $vss | ForEach-Object { Write-Log "  $_" "Gray" }
    }

    $disk = Get-PSDrive C -ErrorAction SilentlyContinue
    if ($disk) {
        $usedGB  = [math]::Round(($disk.Used / 1GB), 1)
        $freeGB  = [math]::Round(($disk.Free / 1GB), 1)
        $totalGB = [math]::Round(($usedGB + $freeGB), 1)
        $freePC  = [math]::Round(($freeGB / $totalGB) * 100, 1)
        $col     = if ($freeGB -lt 10) { "Red" } elseif ($freeGB -lt 20) { "DarkYellow" } else { "Green" }
        Write-Log ""
        Write-Log ("  Disque C: — {0} GB libres / {1} GB total ({2}% libre)" -f $freeGB, $totalGB, $freePC) $col
        if ($freeGB -lt 10) {
            Write-Log "  ⚠  Moins de 10 GB libres — Windows peut supprimer des points de restauration !" "Red"
        }
    }

} catch {
    Write-Log "  Erreur lecture état Protection Système : $_" "Red"
}

Save-Report

# ════════════════════════════════════════════════════════════
# 13. SFC /SCANNOW — INTÉGRITÉ FICHIERS SYSTÈME
# SFC — System file integrity check (background, non-bloquant)
# ════════════════════════════════════════════════════════════
Write-Section "13/14 — SFC INTÉGRITÉ FICHIERS SYSTÈME"

Write-Sub "Lancement sfc /scannow (arrière-plan — résultat dans CBS.log)"

Write-Log "  Lancement sfc /scannow en cours (peut prendre 2-5 minutes)..." "Cyan"
Write-Log "  Le script attend la fin avant de continuer." "Gray"

try {
    # ── Passe 1 : sfc /scannow initial
    # Pass 1: initial SFC scan
    Write-Log "  ── Passe 1/2 : sfc /scannow ──" "Yellow"
    $sfcResult = & sfc /scannow 2>&1
    $sfcStr    = $sfcResult | Out-String

    Write-Log ""
    $sfcNeedDism = $false

    if ($sfcStr -match 'did not find any integrity violations') {
        Write-Log "  ✅ SFC Passe 1 : Aucune violation d'intégrité détectée." "Green"

    } elseif ($sfcStr -match 'found corrupt files and successfully repaired') {
        Write-Log "  ⚠  SFC Passe 1 : Fichiers corrompus trouvés et RÉPARÉS par SFC." "DarkYellow"
        Write-Log "     → Une 2ème passe SFC sera lancée pour confirmer la réparation." "Gray"
        $sfcNeedDism = $false   # SFC a réparé lui-même, juste re-scan de confirmation
        $sfcRepaired = $true

    } elseif ($sfcStr -match 'found corrupt files but was unable to fix') {
        Write-Log "  ❌ SFC Passe 1 : Fichiers corrompus IRRÉPARABLES par SFC seul." "Red"
        Write-Log "     → Lancement automatique de DISM pour reconstruire l'image Windows." "DarkYellow"
        $sfcNeedDism = $true

    } else {
        Write-Log "  SFC Passe 1 terminé — résultat brut :" "White"
        $sfcResult | ForEach-Object { Write-Log "  $_" "Gray" }
    }

    # ── DISM /RestoreHealth si SFC n'a pas pu réparer
    # DISM RestoreHealth if SFC couldn't fix the issues
    if ($sfcNeedDism) {
        Write-Log ""
        Write-Log "  ── DISM /Online /Cleanup-Image /RestoreHealth ──" "Yellow"
        Write-Log "  Reconstruction de l'image Windows depuis Windows Update..." "Cyan"
        Write-Log "  (Nécessite une connexion internet — peut prendre 5-15 minutes)" "Gray"
        Write-Log ""

        $dismResult = & DISM /Online /Cleanup-Image /RestoreHealth 2>&1
        $dismStr    = $dismResult | Out-String

        Write-Log ""
        if ($dismStr -match 'The restore operation completed successfully') {
            Write-Log "  ✅ DISM : Image Windows restaurée avec succès." "Green"
        } elseif ($dismStr -match 'The source files could not be found') {
            Write-Log "  ❌ DISM : Sources introuvables (pas d'accès Windows Update ?)." "Red"
            Write-Log "     → Lancer manuellement avec une ISO : DISM /Source:X:\sources\install.wim" "DarkRed"
        } elseif ($dismStr -match 'Error') {
            Write-Log "  ❌ DISM : Erreur détectée." "Red"
            $dismResult | Where-Object { $_ -match 'Error|error' } |
                ForEach-Object { Write-Log "    $_" "Gray" }
        } else {
            Write-Log "  DISM terminé — résultat brut :" "White"
            $dismResult | Select-Object -Last 10 | ForEach-Object { Write-Log "  $_" "Gray" }
        }

        # Log DISM détaillé / Detailed DISM log
        $dismLog = "$env:SystemRoot\Logs\DISM\dism.log"
        if (Test-Path $dismLog) {
            Write-Log ""
            Write-Log "  Log DISM détaillé : $dismLog" "Gray"
            $dismLines = Get-Content $dismLog -Tail 30 -ErrorAction SilentlyContinue
            $dismImportant = $dismLines | Where-Object { $_ -match 'Error|Failed|Restored|success' }
            if ($dismImportant) {
                $dismImportant | ForEach-Object { Write-Log "    $_" "Gray" }
            }
        }
    }

    # ── Passe 2 : re-scan SFC après DISM (ou après réparation auto SFC)
    # Pass 2: re-scan SFC after DISM (or after SFC self-repair)
    if ($sfcNeedDism -or $sfcRepaired) {
        Write-Log ""
        Write-Log "  ── Passe 2/2 : sfc /scannow (vérification post-réparation) ──" "Yellow"
        $sfcResult2 = & sfc /scannow 2>&1
        $sfcStr2    = $sfcResult2 | Out-String

        Write-Log ""
        if ($sfcStr2 -match 'did not find any integrity violations') {
            Write-Log "  ✅ SFC Passe 2 : Système propre — aucune corruption résiduelle." "Green"
        } elseif ($sfcStr2 -match 'found corrupt files and successfully repaired') {
            Write-Log "  ⚠  SFC Passe 2 : Corrections supplémentaires effectuées." "DarkYellow"
            Write-Log "     → Relancer une 3ème passe manuellement pour confirmer." "Gray"
        } elseif ($sfcStr2 -match 'found corrupt files but was unable to fix') {
            Write-Log "  ❌ SFC Passe 2 : Corruptions persistantes malgré DISM." "Red"
            Write-Log "     → Envisager une réparation Windows via ISO (upgrade in-place)." "DarkRed"
            Write-Log "     → Commande : setup.exe /auto upgrade /quiet" "DarkRed"
        } else {
            $sfcResult2 | ForEach-Object { Write-Log "  $_" "Gray" }
        }
    }

    # ── CBS.log — lignes importantes (toujours)
    # CBS.log — important lines (always shown)
    $cbsLog = "$env:SystemRoot\Logs\CBS\CBS.log"
    if (Test-Path $cbsLog) {
        $cbsAge = (Get-Date) - (Get-Item $cbsLog).LastWriteTime
        Write-Log ""
        Write-Log "  Log SFC/CBS détaillé : $cbsLog" "Gray"
        Write-Log ("  Modifié il y a       : {0}h {1}min" -f [math]::Floor($cbsAge.TotalHours), $cbsAge.Minutes) "Gray"
        $cbsLines     = Get-Content $cbsLog -Tail 100 -ErrorAction SilentlyContinue
        $cbsImportant = $cbsLines | Where-Object { $_ -match 'corrupt|repair|Cannot repair|Repairing|CSI' }
        if ($cbsImportant) {
            Write-Log "  Lignes CBS importantes (corruption/réparation) :" "DarkYellow"
            $cbsImportant | Select-Object -Last 20 | ForEach-Object { Write-Log "    $_" "Gray" }
        }
    }

} catch {
    Write-Log "  ❌ Erreur lancement SFC/DISM : $_" "Red"
    Write-Log "  → Lancer manuellement : sfc /scannow" "DarkYellow"
}

Save-Report

# ════════════════════════════════════════════════════════════
# 14. RECOMMANDATIONS & RÉSUMÉ
# Recommendations and summary
# ════════════════════════════════════════════════════════════
Write-Section "14/14 — RÉSUMÉ & RECOMMANDATIONS"

Write-Log ""
Write-Log "  ANALYSE AUTOMATIQUE DES RÉSULTATS" "Cyan"
Write-Log $SEP2 "Cyan"

# Check PTIMon
$ptMon = Get-Service 'PTIMon' -ErrorAction SilentlyContinue
if ($ptMon) {
    Write-Log "  🔴 PTIMon ACTIF   → Driver Intel 2012 incompatible i9-14900HX" "Red"
    Write-Log "     → Supprimer : sc stop PTIMon && sc delete PTIMon" "DarkRed"
    Write-Log "     → Puis supprimer via RAPR : ptimon.inf" "DarkRed"
} else {
    Write-Log "  ✅ PTIMon         → Non présent (RAPR a fait son travail)" "Green"
}

# Check AltA2DP
$a2dp = Get-Service 'AltA2DP' -ErrorAction SilentlyContinue
if ($a2dp) {
    Write-Log "  🟡 AltA2DP ACTIF  → Vérifier si reboot complet effectué après install" "DarkYellow"
    Write-Log "     → Si BSOD persiste : sc stop AltA2DP && sc delete AltA2DP" "DarkYellow"
} else {
    Write-Log "  ✅ AltA2DP        → Non présent" "Green"
}

# Check BSOD récents
if ($bsodEvents) {
    Write-Log "  🔴 BSOD           → $($bsodEvents.Count) crash(s) détecté(s) depuis le 21/05" "Red"
    Write-Log "     → Analyser les dumps avec WinDbg ou BlueScreenView" "DarkRed"
} else {
    Write-Log "  ✅ BSOD           → Aucun crash depuis le 21/05 dans les journaux" "Green"
}

# Check reboots inattendus
if ($unexpectedReboots) {
    Write-Log "  🔴 Reboots        → $($unexpectedReboots.Count) arrêt(s) inattendu(s) détecté(s)" "Red"
    Write-Log "     → Corrélés aux drivers SDIO ou instabilité noyau" "DarkRed"
} else {
    Write-Log "  ✅ Reboots        → Aucun arrêt inattendu détecté" "Green"
}

# Check throttling
if ($perfDeg -and $perfDeg.Count -gt 0) {
    Write-Log "  🔴 Throttling     → $($perfDeg.Count) événement(s) de dégradation CPU détecté(s)" "Red"
    Write-Log "     → Corréler avec changement voltage du jour" "DarkRed"
} else {
    Write-Log "  ✅ Throttling     → Aucune dégradation CPU détectée" "Green"
}

# Check périphériques cassés
if ($brokenDevs -and $brokenDevs.Count -gt 0) {
    Write-Log "  🟡 Périphériques  → $($brokenDevs.Count) en erreur — vérifier Gestionnaire de périphériques" "DarkYellow"
} else {
    Write-Log "  ✅ Périphériques  → Aucune erreur PnP détectée" "Green"
}

# Check WiFi instabilité
if ($wifiEvents) {
    $wifiDiscos = $wifiEvents | Where-Object { $_.Id -eq 8003 }
    if ($wifiDiscos -and $wifiDiscos.Count -gt 5) {
        Write-Log "  🟡 WiFi           → $($wifiDiscos.Count) déconnexion(s) sur 72h — driver Intel AX211 à surveiller" "DarkYellow"
    } else {
        Write-Log "  ✅ WiFi           → Stable sur 72h" "Green"
    }
}

Write-Log ""
Write-Log "  CONTEXTE VOLTAGE DU JOUR" "Cyan"
Write-Log $SEP2 "Cyan"
Write-Log "  [Matin → après-midi] $VOLT_MATIN → $VOLT_APRESMIDI" "DarkYellow"
Write-Log "  → Surveiller les événements ID 37 / 55 / 56 dans la section 5b" "Gray"
Write-Log "  → Si instabilité post-rollback : tenter -30mV comme compromis" "Gray"
Write-Log "  → Valider avec OCCT CPU Linpack 15min + Cinebench R23 multi-core" "Gray"

Write-Log ""
Write-Log "  PROCHAINES ÉTAPES RECOMMANDÉES :" "Cyan"
Write-Log $SEP2 "Cyan"
Write-Log "  1. Si BSOD encore présent → utiliser RP antérieur à 09h04 21/05" "White"
Write-Log "  2. Supprimer PTIMon (driver 2012) via RAPR ou sc delete" "White"
Write-Log "  3. Rebooter proprement (1x minimum post-changements)" "White"
Write-Log "  4. Lancer LatencyMon 5min sous charge → exporter rapport" "White"
Write-Log "  5. Activer HWiNFO64 'Log to file' pour capturer voltage/temp en live" "White"
Write-Log "  6. Relancer ce script pour confirmer l'assainissement" "White"
Write-Log "  7. BIOS ASUS G814JIR → vérifier maj sur asus.com (build actuel: G814JIR.322)" "White"
Write-Log "  8. Ne PAS réinstaller Armoury Crate — utiliser G-Helper + NVIDIA Broadcast" "White"
Write-Log "  9. Tâches planifiées ASUS résiduelles → désactiver si trouvées (section 10)" "White"
Write-Log " 10. Si SFC a trouvé des corruptions → lancer DISM /RestoreHealth" "White"

Write-Log ""
Write-Log $SEP "Cyan"
Write-Log "  Rapport texte  : $REPORT_FILE" "Cyan"
Write-Log "  Snapshot PnP   : $PNPCSV_FILE" "Cyan"
Write-Log $SEP "Cyan"
Write-Log ""

# ════════════════════════════════════════════════════════════
# EXPORT FINAL DU RAPPORT
# Final report export
# ════════════════════════════════════════════════════════════
Save-Report
Write-Log "  ✅ Diagnostic terminé — $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')" "Cyan"
Write-Log ""

# Ouvrir le rapport automatiquement dans le Bloc-notes
# Automatically open report in Notepad
$open = Read-Host "  Ouvrir le rapport dans le Bloc-notes ? (o/n)"
if ($open -eq 'o') {
    Start-Process notepad.exe $REPORT_FILE
}
