param(
    [switch]$DryRun
)

# Détermination dossier courant robuste
if ($PSScriptRoot) { $CurrentDir = $PSScriptRoot } else { $CurrentDir = (Get-Location).Path }

$TimeStamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$LogFile = Join-Path -Path $CurrentDir -ChildPath "IntelDSA_Cleanup_$TimeStamp.log"
$RegBackupFile = Join-Path -Path $CurrentDir -ChildPath "IntelDSA_RegistryBackup_$TimeStamp.reg"
$ShortcutBackupDir = Join-Path -Path $CurrentDir -ChildPath "Backup_Shortcuts_$TimeStamp"

New-Item -Path $ShortcutBackupDir -ItemType Directory -Force | Out-Null

function Log {
    param($msg)
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $msg"
    Write-Output $line
    Add-Content -Path $LogFile -Value $line
}

function SafeRun {
    param($scriptBlock, $desc)
    try {
        & $scriptBlock
        Log "OK - $desc"
    } catch {
        Log "ERROR - $desc - $($_.Exception.Message)"
    }
}

"Windows Registry Editor Version 5.00" | Out-File -FilePath $RegBackupFile -Encoding ASCII

Log "=== Début Intel DSA Cleanup - $TimeStamp ==="
Log "Dossier courant : $CurrentDir"
Log "DryRun : $($DryRun.IsPresent)"

# 1) Service info before
Log "Recherche du service DSAService..."
$svc = Get-Service -Name "DSAService" -ErrorAction SilentlyContinue
if ($svc) {
    $svcPath = (Get-WmiObject -Class Win32_Service -Filter "Name='DSAService'").PathName
    Log "Service trouvé : $($svc.DisplayName) | Status: $($svc.Status) | StartupType: $(Get-Service -Name DSAService | Select-Object -ExpandProperty StartType 2>$null)"
    Log "Chemin binaire : $svcPath"
} else {
    Log "Service DSAService introuvable."
}

# 2) Stop + disable service (only DSAService)
if ($svc) {
    if ($DryRun) {
        Log "[DryRun] Arrêt et désactivation du service DSAService simulés."
    } else {
        try {
            if ($svc.Status -ne 'Stopped') {
                Stop-Service -Name "DSAService" -Force -ErrorAction Stop
                Log "Service arrêté."
            } else {
                Log "Service déjà arrêté."
            }
        } catch {
            Log "Erreur lors de l'arrêt du service : $($_.Exception.Message)"
        }
        try {
            Set-Service -Name "DSAService" -StartupType Disabled -ErrorAction Stop
            Log "StartupType défini sur Disabled."
        } catch {
            Log "Erreur lors du changement de StartupType : $($_.Exception.Message)"
        }
    }
}

# 3) Registre - recherche et backup des entrées correspondantes
$regPaths = @(
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run",
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run",
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce",
    "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run"
)

$foundCount = 0
$removedCount = 0

foreach ($path in $regPaths) {
    if (Test-Path $path) {
        Log "Analyse registre : $path"
        $props = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
        if ($props) {
            foreach ($p in $props.PSObject.Properties) {
                $name = $p.Name
                $value = $p.Value
                if ($value -and ($value -match "Intel.*Driver.*Support.*Assistant" -or $name -match "Intel|DSA")) {
                    $foundCount++
                    Log "Trouvé : $path -> $name = $value"
                    # Backup to .reg
                    $regKeyEscaped = $path -replace "HKLM:","HKEY_LOCAL_MACHINE\" -replace "HKCU:","HKEY_CURRENT_USER\"
                    $regLine = "`"$regKeyEscaped`"`n`"$name`"=" + '"' + ($value -replace '"','\"') + '"'
                    Add-Content -Path $RegBackupFile -Value ("[" + $regKeyEscaped + "]")
                    Add-Content -Path $RegBackupFile -Value ('"' + $name + '"="' + ($value -replace '"','\"') + '"')
                    if ($DryRun) {
                        Log "[DryRun] Entrée registre marquée pour suppression : $path -> $name"
                    } else {
                        try {
                            Remove-ItemProperty -Path $path -Name $name -ErrorAction Stop
                            $removedCount++
                            Log "Supprimé : $path -> $name"
                        } catch {
                            Log "Erreur suppression registre $path -> $name : $($_.Exception.Message)"
                        }
                    }
                }
            }
        } else {
            Log "Aucune propriété trouvée dans $path"
        }
    } else {
        Log "Chemin registre inexistant : $path"
    }
}

# 4) Startup folders - backup then remove
$startupPaths = @(
    "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup",
    "$env:PROGRAMDATA\Microsoft\Windows\Start Menu\Programs\Startup"
)

$shortcutFound = 0
$shortcutRemoved = 0

foreach ($folder in $startupPaths) {
    if (Test-Path $folder) {
        Log "Analyse dossier Startup : $folder"
        $files = Get-ChildItem -Path $folder -Filter "*.lnk" -ErrorAction SilentlyContinue
        foreach ($file in $files) {
            if ($file.Name -match "Intel|DSA") {
                $shortcutFound++
                Log "Raccourci trouvé : $($file.FullName)"
                $dest = Join-Path -Path $ShortcutBackupDir -ChildPath $file.Name
                if ($DryRun) {
                    Log "[DryRun] Raccourci marqué pour déplacement : $($file.FullName) -> $dest"
                } else {
                    try {
                        Move-Item -Path $file.FullName -Destination $dest -Force -ErrorAction Stop
                        $shortcutRemoved++
                        Log "Raccourci déplacé vers backup : $dest"
                    } catch {
                        Log "Erreur déplacement raccourci : $($_.Exception.Message)"
                    }
                }
            }
        }
    } else {
        Log "Dossier Startup inexistant : $folder"
    }
}

# 5) Service info after
if ($svc) {
    $svcAfter = Get-Service -Name "DSAService" -ErrorAction SilentlyContinue
    if ($svcAfter) {
        $svcPathAfter = (Get-WmiObject -Class Win32_Service -Filter "Name='DSAService'").PathName
        Log "Etat final service : Status: $($svcAfter.Status) | StartupType: $(Get-Service -Name DSAService | Select-Object -ExpandProperty StartType 2>$null)"
        Log "Chemin binaire final : $svcPathAfter"
    } else {
        Log "Service DSAService introuvable après opérations."
    }
}

# Résumé
Log "=== Résumé ==="
Log "Entrées registre trouvées : $foundCount"
Log "Entrées registre supprimées : $removedCount"
Log "Raccourcis trouvés : $shortcutFound"
Log "Raccourcis déplacés vers backup : $shortcutRemoved"
Log "Fichier de backup registre : $RegBackupFile"
Log "Dossier de backup raccourcis : $ShortcutBackupDir"
Log "Log complet : $LogFile"

if ($DryRun) {
    Log "Mode DryRun activé : aucune suppression réelle n'a été effectuée."
}

Log "=== Fin du script ==="
