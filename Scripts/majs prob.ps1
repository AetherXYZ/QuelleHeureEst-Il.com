<#
.SYNOPSIS
  Détecte et désinstalle des mises à jour Windows considérées comme problématiques.

.NOTES
  - À exécuter en PowerShell **en tant qu’administrateur**.
  - Compatible Windows 7 → 11 (wusa.exe).
  - La liste des KB est intégrée ci-dessous.
#>

# --- 1. Liste des KB problématiques ---
$BadKBs = @(
    "KB5000802",  # BSOD à l’impression (mars 2021)
    "KB5000808",  # BSOD à l’impression (mars 2021)
    "KB5001330",  # Plantages et baisse de performance (avril 2021)
    "KB5050092",  # Impressions aléatoires de caractères (janvier 2025)
    "KB5065789"   # Problèmes vidéo HDCP/DRM (septembre 2025)
)

# --- 2. Paramètres généraux ---
$LogFile = "$env:PUBLIC\\BadUpdatesCleanup_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

Function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Write-Host $line
    Add-Content -Path $LogFile -Value $line
}

Write-Log "Démarrage du script de nettoyage des mises à jour problématiques."
Write-Log "KB ciblées : $($BadKBs -join ', ')"

# --- 3. Récupération des mises à jour installées ---
try {
    $installedUpdates = Get-HotFix | Where-Object { $_.HotFixID -like "KB*" }
} catch {
    Write-Log "Erreur lors de la récupération des mises à jour : $_" "ERROR"
    throw
}

if (-not $installedUpdates) {
    Write-Log "Aucune mise à jour installée n'a été trouvée via Get-HotFix." "WARN"
}

# --- 4. Filtrer celles qui sont dans la liste “problématique” ---
$foundBadUpdates = $installedUpdates | Where-Object { $BadKBs -contains $_.HotFixID }

if (-not $foundBadUpdates) {
    Write-Log "Aucune des KB problématiques n'est installée sur ce système."
    Write-Log "Fin du script."
    return
}

Write-Log "Mises à jour problématiques détectées :"
$foundBadUpdates | ForEach-Object {
    Write-Log (" - {0} installée le {1}" -f $_.HotFixID, $_.InstalledOn)
}

# --- 5. Demander confirmation globale ---
Write-Host ""
Write-Host "Les mises à jour ci-dessus ont été détectées comme problématiques."
$globalChoice = Read-Host "Souhaites-tu tenter de les désinstaller ? (O/N)"

if ($globalChoice -notin @("O","o","Y","y")) {
    Write-Log "L'utilisateur a choisi de ne pas désinstaller les mises à jour."
    Write-Log "Fin du script."
    return
}

# --- 6. Désinstallation une par une via wusa.exe ---
foreach ($update in $foundBadUpdates) {
    $kb = $update.HotFixID
    Write-Log "Traitement de $kb"

    $choice = Read-Host "Désinstaller $kb ? (O/N)"
    if ($choice -notin @("O","o","Y","y")) {
        Write-Log "L'utilisateur a choisi de conserver $kb."
        continue
    }

    Write-Log "Lancement de la désinstallation de $kb via wusa.exe"

    $arguments = "/uninstall /kb:$($kb.Substring(2)) /norestart"

    try {
        $process = Start-Process -FilePath "wusa.exe" -ArgumentList $arguments -Wait -PassThru
        $exitCode = $process.ExitCode
        Write-Log "wusa.exe terminé pour $kb avec le code de sortie $exitCode"

        if ($exitCode -eq 0) {
            Write-Log "La mise à jour $kb semble avoir été désinstallée avec succès."
        } else {
            Write-Log "La désinstallation de $kb a retourné un code non nul ($exitCode). Vérifie l’Observateur d’événements." "WARN"
        }
    } catch {
        Write-Log "Erreur lors de la tentative de désinstallation de $kb : $_" "ERROR"
    }
}

Write-Log "Fin du traitement de toutes les KB ciblées."
Write-Log "Un redémarrage peut être nécessaire pour finaliser la désinstallation."
Write-Host ""
Write-Host "Script terminé. Journal : $LogFile"