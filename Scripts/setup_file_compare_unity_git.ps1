# ==============================================================================
# SCRIPT DE CONFIGURATION UNITY + VS CODE - PROJET SCHMILBLICK
# Unity + VS Code Configuration Script
# ==============================================================================
# FR// Ce script prépare automatiquement un dépôt Git pour un projet Unity.
# ENG// This script automatically prepares a Git repository for a Unity project.
#
# FONCTIONNALITÉS / FEATURES :
# FR// - Vérifie que Git est installé, ou le propose via winget
# FR// - Détecte automatiquement UnityYAMLMerge (Unity Hub ou installation standalone)
# FR// - Détecte automatiquement Visual Studio Code (commande 'code' ou chemin standard)
# FR// - Configure UnityYAMLMerge comme outil de merge pour les fichiers Unity
# FR// - Configure VS Code comme outil de diff visuel
# FR// - Met à jour le fichier .gitattributes sans écraser les règles existantes
# FR// - Sauvegarde automatique de .git/config et .gitattributes avant toute modification
# FR// - Teste réellement l'outil de diff en lançant VS Code sur deux fichiers temporaires
# FR// - Supprime automatiquement les fichiers temporaires après le test
#
# ENG// - Checks that Git is installed, or offers to install it via winget
# ENG// - Auto-detects UnityYAMLMerge (Unity Hub or standalone installation)
# ENG// - Auto-detects Visual Studio Code ('code' command or standard paths)
# ENG// - Configures UnityYAMLMerge as the merge tool for Unity files
# ENG// - Configures VS Code as the visual diff tool
# ENG// - Updates the .gitattributes file without overwriting existing rules
# ENG// - Automatic backup of .git/config and .gitattributes before any changes
# ENG// - Really tests the diff tool by launching VS Code on two temporary files
# ENG// - Automatically deletes temporary files after the test
# ==============================================================================

# FR// Forcer l'encodage UTF-8 dans la console pour un affichage correct des accents
# ENG// Force UTF-8 encoding in the console for proper display of accented characters
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
chcp 65001 > $null

Write-Host "=== Configuration automatique UnityYAMLMerge + VS Code Diff ===" -ForegroundColor Cyan
Write-Host "=== Automatic setup for UnityYAMLMerge + VS Code Diff ===" -ForegroundColor Cyan

# ==============================================================================
# 1. VÉRIFICATION ET INSTALLATION DE GIT
# 1. GIT CHECK AND INSTALLATION
# ==============================================================================
# FR// On s'assure que Git est disponible, sinon on tente de l'installer via winget.
# ENG// We ensure Git is available; if not, we try to install it via winget.

Write-Host "`n[Git] Vérification de Git..." -ForegroundColor DarkYellow
Write-Host "[Git] Checking Git..." -ForegroundColor DarkYellow

$gitInstalled = $false
if (Get-Command git -ErrorAction SilentlyContinue) {
    $gitInstalled = $true
    Write-Host "Git est déjà présent." -ForegroundColor Green
    Write-Host "Git already installed." -ForegroundColor Green
    git --version

    # FR// Proposer une mise à jour si winget est disponible
    # ENG// Offer an update if winget is available
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        $updateGit = Read-Host "Rechercher une mise à jour de Git via winget ? (o/n)"
        if ($updateGit -eq 'o' -or $updateGit -eq 'y') {
            winget upgrade Git.Git --accept-package-agreements
        }
    }
} else {
    Write-Host "Git n'est pas installé." -ForegroundColor Yellow
    Write-Host "Git not installed." -ForegroundColor Yellow
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "Installation via winget..." -ForegroundColor Yellow
        winget install Git.Git --silent --accept-package-agreements
        # FR// Rafraîchir le PATH pour que la commande git soit reconnue immédiatement
        # ENG// Refresh PATH so the git command is recognized immediately
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
        if (Get-Command git -ErrorAction SilentlyContinue) {
            $gitInstalled = $true
            Write-Host "Git installé avec succès." -ForegroundColor Green
            Write-Host "Git installed successfully." -ForegroundColor Green
        } else {
            Write-Host "L'installation semble avoir échoué." -ForegroundColor Red
            Write-Host "The installation seems to have failed." -ForegroundColor Red
        }
    } else {
        Write-Host "winget n'est pas disponible. Veuillez installer Git manuellement depuis https://git-scm.com" -ForegroundColor Red
        Write-Host "winget is not available. Please install Git manually from https://git-scm.com" -ForegroundColor Red
    }
}

if (-not $gitInstalled) {
    Write-Host "Configuration abandonnée (Git requis)." -ForegroundColor Red
    Write-Host "Setup aborted (Git required)." -ForegroundColor Red
    return
}

# FR// Vérifier que l'on est bien à la racine d'un dépôt Git
# ENG// Check that we are at the root of a Git repository
if (!(Test-Path ".git")) {
    Write-Host "Erreur : Ce dossier n'est pas la racine d'un dépôt Git." -ForegroundColor Red
    Write-Host "Error: This folder is not the root of a Git repository." -ForegroundColor Red
    return
}

# ==============================================================================
# 2. DÉTECTION DE UNITYYAMLMERGE
# 2. UNITYYAMLMERGE DETECTION
# ==============================================================================
# FR// On cherche UnityYAMLMerge.exe dans les emplacements habituels (Hub, standalone).
# ENG// We look for UnityYAMLMerge.exe in the usual locations (Hub, standalone).

Write-Host "`nRecherche de UnityYAMLMerge..." -ForegroundColor DarkYellow
Write-Host "Searching for UnityYAMLMerge..." -ForegroundColor DarkYellow

$unityMergeTool = $null
$possibleUnityPaths = @(
    "C:/Program Files/Unity/Hub/Editor/*/Editor/Data/Tools/UnityYAMLMerge.exe",
    "C:/Program Files/Unity/Editor/Data/Tools/UnityYAMLMerge.exe",
    "C:/Program Files/Unity */Editor/Data/Tools/UnityYAMLMerge.exe"   # FR// motif supplémentaire pour les installations standalone avec espace dans le nom
)                                                                     # ENG// extra pattern for standalone installs with space in name

foreach ($pattern in $possibleUnityPaths) {
    $found = Get-Item $pattern -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) {
        $unityMergeTool = $found.FullName
        break
    }
}

# FR// Si toujours pas trouvé, on cherche via le dossier du Hub
# ENG// If still not found, search via the Hub folder
if (-not $unityMergeTool) {
    $hubEditors = "$env:ProgramFiles/Unity/Hub/Editor"
    if (Test-Path $hubEditors) {
        $latest = Get-ChildItem $hubEditors -Directory | Sort-Object Name -Descending | Select-Object -First 1
        if ($latest) {
            $candidate = Join-Path $latest.FullName "Editor/Data/Tools/UnityYAMLMerge.exe"
            if (Test-Path $candidate) { $unityMergeTool = $candidate }
        }
    }
}

# FR// En dernier recours, on demande le chemin manuellement
# ENG// As a last resort, ask for the path manually
if (-not $unityMergeTool) {
    Write-Host "UnityYAMLMerge.exe introuvable." -ForegroundColor Red
    Write-Host "UnityYAMLMerge.exe not found." -ForegroundColor Red
    $manual = Read-Host "Chemin complet vers UnityYAMLMerge.exe (laisser vide pour abandonner) / Full path to UnityYAMLMerge.exe (leave blank to abort)"
    if ($manual -and (Test-Path $manual)) {
        $unityMergeTool = $manual
    } else {
        Write-Host "Configuration abandonnée." -ForegroundColor Red
        Write-Host "Setup aborted." -ForegroundColor Red
        return
    }
}
Write-Host "UnityYAMLMerge trouvé : $unityMergeTool" -ForegroundColor Green
Write-Host "UnityYAMLMerge found: $unityMergeTool" -ForegroundColor Green

# ==============================================================================
# 3. DÉTECTION DE VISUAL STUDIO CODE (avec correction automatique du PATH)
# 3. VISUAL STUDIO CODE DETECTION (with automatic PATH fix)
# ==============================================================================
# FR// On cherche d'abord la commande 'code' dans le PATH, puis les exécutables
# FR// standards, puis via le registre, et enfin dans les dossiers de package managers.
# FR// Si VS Code est trouvé mais que 'code' n'est pas dans le PATH, on propose de l'ajouter.
# ENG// We first look for the 'code' command in PATH, then standard executables,
# ENG// then via the registry, and finally in package manager folders.
# ENG// If VS Code is found but 'code' is not in PATH, we offer to add it.

Write-Host "`nRecherche de Visual Studio Code..." -ForegroundColor DarkYellow
Write-Host "Searching for Visual Studio Code..." -ForegroundColor DarkYellow

$vscodeExe = $null
$vscodePath = $null

# FR// 1. Vérifier si la commande 'code' existe déjà
# ENG// 1. Check if 'code' command already exists
if (Get-Command code -ErrorAction SilentlyContinue) {
    $vscodeExe = "code"
    $vscodePath = (Get-Command code).Source
    Write-Host "Commande 'code' trouvée dans le PATH." -ForegroundColor Green
    Write-Host "'code' command found in PATH." -ForegroundColor Green
}

# FR// 2. Chercher les exécutables dans les dossiers standards
# ENG// 2. Search for executables in standard folders
if (-not $vscodeExe) {
    $possibleCodePaths = @(
        "$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe",
        "${env:ProgramFiles}\Microsoft VS Code\Code.exe",
        "${env:ProgramFiles(x86)}\Microsoft VS Code\Code.exe"
    )
    foreach ($p in $possibleCodePaths) {
        if (Test-Path $p) {
            $vscodeExe = $p
            $vscodePath = $p
            break
        }
    }
    if ($vscodeExe) {
        Write-Host "VS Code exécutable trouvé : $vscodeExe" -ForegroundColor Green
        Write-Host "VS Code executable found: $vscodeExe" -ForegroundColor Green
    }
}

# FR// 3. Chercher via le registre (installation système ou utilisateur)
# ENG// 3. Search via registry (system or user installation)
if (-not $vscodeExe) {
    $regPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    foreach ($regPath in $regPaths) {
        $vsCodeEntry = Get-ItemProperty $regPath -ErrorAction SilentlyContinue |
                       Where-Object { $_.DisplayName -like "*Microsoft Visual Studio Code*" } |
                       Select-Object -First 1
        if ($vsCodeEntry) {
            $installLocation = $vsCodeEntry.InstallLocation
            if ($installLocation) {
                $candidate = Join-Path $installLocation "Code.exe"
                if (Test-Path $candidate) {
                    $vscodeExe = $candidate
                    $vscodePath = $candidate
                    break
                }
            }
        }
    }
    if ($vscodeExe) {
        Write-Host "VS Code trouvé via le registre : $vscodeExe" -ForegroundColor Green
        Write-Host "VS Code found via registry: $vscodeExe" -ForegroundColor Green
    }
}

# FR// 4. Chercher dans les dossiers de package managers (scoop, chocolatey)
# ENG// 4. Search in package manager folders (scoop, chocolatey)
if (-not $vscodeExe) {
    $extraPaths = @(
        "$env:USERPROFILE\scoop\apps\vscode\current\Code.exe",
        "$env:ProgramData\chocolatey\lib\vscode\tools\Code.exe"
    )
    foreach ($ep in $extraPaths) {
        if (Test-Path $ep) {
            $vscodeExe = $ep
            $vscodePath = $ep
            break
        }
    }
    if ($vscodeExe) {
        Write-Host "VS Code trouvé via package manager : $vscodeExe" -ForegroundColor Green
        Write-Host "VS Code found via package manager: $vscodeExe" -ForegroundColor Green
    }
}

# FR// 5. Si toujours pas trouvé, proposer l'installation
# ENG// 5. If still not found, offer installation
if (-not $vscodeExe) {
    Write-Host "Visual Studio Code introuvable." -ForegroundColor Yellow
    Write-Host "Visual Studio Code not found." -ForegroundColor Yellow
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        $ans = Read-Host "Souhaitez-vous installer VS Code via winget ? (o/n) / Install VS Code via winget? (y/n)"
        if ($ans -eq 'o' -or $ans -eq 'y') {
            winget install Microsoft.VisualStudioCode --silent --accept-package-agreements
            $vscodeExe = "$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe"
            if (-not (Test-Path $vscodeExe)) { $vscodeExe = "${env:ProgramFiles}\Microsoft VS Code\Code.exe" }
            if ($vscodeExe) { $vscodePath = $vscodeExe }
        }
    } else {
        Write-Host "Vous pouvez installer VS Code manuellement depuis https://code.visualstudio.com" -ForegroundColor Yellow
        Write-Host "You can install VS Code manually from https://code.visualstudio.com" -ForegroundColor Yellow
    }
}

# FR// 6. Si VS Code est trouvé mais que la commande 'code' n'est pas dans le PATH,
# FR//    proposer de l'ajouter au PATH utilisateur.
# ENG// 6. If VS Code is found but the 'code' command is not in PATH,
# ENG//    offer to add it to the user PATH.
if ($vscodeExe -and $vscodeExe -ne 'code') {
    $vscodeDir = Split-Path $vscodeExe -Parent
    $currentUserPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($currentUserPath -notlike "*$vscodeDir*") {
        $addPath = Read-Host "Ajouter '$vscodeDir' au PATH utilisateur pour utiliser la commande 'code' ? (o/n) / Add '$vscodeDir' to user PATH to use 'code' command? (y/n)"
        if ($addPath -eq 'o' -or $addPath -eq 'y') {
            [Environment]::SetEnvironmentVariable("Path", $currentUserPath + ";$vscodeDir", "User")
            # FR// Mettre à jour le PATH de la session courante
            # ENG// Update current session PATH
            $env:Path += ";$vscodeDir"
            Write-Host "PATH utilisateur mis à jour. Redémarrez la console pour un effet global." -ForegroundColor Green
            Write-Host "User PATH updated. Restart the console for global effect." -ForegroundColor Green
            # FR// On utilise maintenant 'code' comme commande
            # ENG// Now use 'code' as the command
            $vscodeExe = "code"
        }
    } else {
        # FR// Le dossier est déjà dans le PATH mais 'code' n'était pas reconnu ? On force 'code'.
        # ENG// Folder already in PATH but 'code' wasn't recognized? Force 'code'.
        $vscodeExe = "code"
    }
}

if (-not $vscodeExe) {
    Write-Host "L'outil de diff ne sera pas configuré." -ForegroundColor Red
    Write-Host "The diff tool will not be configured." -ForegroundColor Red
} else {
    Write-Host "VS Code utilisable : $vscodeExe" -ForegroundColor Green
    Write-Host "VS Code usable: $vscodeExe" -ForegroundColor Green
}

# ==============================================================================
# 4. SAUVEGARDE DU FICHIER .git/config
# 4. BACKUP OF .git/config
# ==============================================================================
# FR// Avant toute modification, on crée une copie horodatée.
# ENG// Before any changes, we create a timestamped copy.

Write-Host "`nSauvegarde du .git/config..." -ForegroundColor DarkYellow
Write-Host "Backing up .git/config..." -ForegroundColor DarkYellow

$gitConfigPath = Join-Path (Get-Location) ".git\config"
$backupConfig = $gitConfigPath + ".bak_" + (Get-Date -Format "yyyyMMdd_HHmmss")
Copy-Item $gitConfigPath $backupConfig
Write-Host "Sauvegarde : $backupConfig" -ForegroundColor Green
Write-Host "Backup: $backupConfig" -ForegroundColor Green

# ==============================================================================
# 5. CONFIGURATION DE L'OUTIL DE MERGE UNITY (UnityYAMLMerge)
# 5. UNITY MERGE TOOL CONFIGURATION (UnityYAMLMerge)
# ==============================================================================
# FR// On nettoie d'abord les anciennes valeurs, puis on définit les nouvelles.
# ENG// We first clean old values, then set the new ones.

Write-Host "`n[UnityYAMLMerge] Configuration..." -ForegroundColor DarkYellow
Write-Host "[UnityYAMLMerge] Setting up..." -ForegroundColor DarkYellow

# FR// Suppression des clés existantes (les erreurs sont ignorées si elles n'existent pas)
# ENG// Remove existing keys (errors are ignored if they don't exist)
git config --local --unset mergetool.unityyamlmerge.cmd 2>$null
git config --local --unset mergetool.unityyamlmerge.trustExitCode 2>$null
git config --local --unset mergetool.unityyamlmerge.keepBackup 2>$null
git config --local --unset merge.tool 2>$null

# FR// Configuration de base
# ENG// Basic configuration
git config --local merge.tool unityyamlmerge
git config --local mergetool.unityyamlmerge.trustExitCode false
git config --local mergetool.unityyamlmerge.keepBackup false

# FR// Commande de merge avec les chemins entre guillemets échappés et les variables préservées
# ENG// Merge command with paths in escaped quotes and variables preserved
$mergeCmd = '\"' + $unityMergeTool + '\" merge -p \"$BASE\" \"$REMOTE\" \"$LOCAL\" \"$MERGED\"'
git config --local mergetool.unityyamlmerge.cmd $mergeCmd
Write-Host "[UnityYAMLMerge] Configuration terminée." -ForegroundColor Green
Write-Host "[UnityYAMLMerge] Configuration done." -ForegroundColor Green

# ==============================================================================
# 6. CONFIGURATION DE L'OUTIL DE DIFF VS CODE (avec échappement correct)
# 6. VS CODE DIFF TOOL CONFIGURATION (with proper escaping)
# ==============================================================================
# FR// On configure VS Code comme outil de diff visuel, avec guillemets échappés pour protéger les espaces.
# ENG// We configure VS Code as the visual diff tool, with escaped quotes to protect spaces.

if ($vscodeExe) {
    Write-Host "`n[VS Code] Configuration de l'outil de diff..." -ForegroundColor DarkYellow
    Write-Host "[VS Code] Setting up diff tool..." -ForegroundColor DarkYellow

    git config --local --unset difftool.vscode.cmd 2>$null
    git config --local --unset diff.tool 2>$null
    git config --local diff.tool vscode

    # FR// Si on utilise la commande 'code', on ne met pas de guillemets autour du chemin mais on échappe les variables
    # ENG// If we are using the 'code' command, we don't quote the path but we escape the variables
    if ($vscodeExe -eq 'code') {
        $diffCmd = 'code --new-window --wait --diff \"$LOCAL\" \"$REMOTE\"'
    } else {
        $diffCmd = '\"' + $vscodeExe + '\" --new-window --wait --diff \"$LOCAL\" \"$REMOTE\"'
    }
    git config --local difftool.vscode.cmd $diffCmd
    Write-Host "[VS Code] Configuration terminée." -ForegroundColor Green
    Write-Host "[VS Code] Configuration done." -ForegroundColor Green
} else {
    Write-Host "`n[VS Code] Configuration ignorée (outil introuvable)." -ForegroundColor Yellow
    Write-Host "[VS Code] Configuration skipped (tool not found)." -ForegroundColor Yellow
}

# ==============================================================================
# 7. MISE À JOUR NON DESTRUCTIVE DU FICHIER .gitattributes
# 7. NON-DESTRUCTIVE UPDATE OF .gitattributes
# ==============================================================================
# FR// On ajoute les règles de merge Unity uniquement si elles ne sont pas déjà présentes.
# ENG// We add Unity merge rules only if they are not already present.

Write-Host "`n[.gitattributes] Vérification des règles Unity..." -ForegroundColor DarkYellow
Write-Host "[.gitattributes] Checking Unity rules..." -ForegroundColor DarkYellow

$attrPath = ".gitattributes"
if (Test-Path $attrPath) {
    $backupAttr = $attrPath + ".bak_" + (Get-Date -Format "yyyyMMdd_HHmmss")
    Copy-Item $attrPath $backupAttr
    Write-Host "Sauvegarde : $backupAttr" -ForegroundColor Green
    Write-Host "Backup: $backupAttr" -ForegroundColor Green
}

$requiredMerges = @("*.unity merge=unityyamlmerge", "*.prefab merge=unityyamlmerge", "*.asset merge=unityyamlmerge")
$existingLines = if (Test-Path $attrPath) { Get-Content $attrPath -Encoding UTF8 } else { @() }
$attrList = [System.Collections.Generic.List[string]]::new()
foreach ($line in $existingLines) { $attrList.Add($line) }

foreach ($rule in $requiredMerges) {
    $found = $false
    foreach ($line in $attrList) {
        if ($line.Trim() -eq $rule) { $found = $true; break }
    }
    if (-not $found) {
        $attrList.Add($rule)
        Write-Host "Ajout : $rule" -ForegroundColor DarkCyan
        Write-Host "Added: $rule" -ForegroundColor DarkCyan
    } else {
        Write-Host "Déjà présent : $rule" -ForegroundColor DarkGray
        Write-Host "Already present: $rule" -ForegroundColor DarkGray
    }
}
[System.IO.File]::WriteAllLines($attrPath, $attrList)
Write-Host "[.gitattributes] Aucune règle existante supprimée." -ForegroundColor Green
Write-Host "[.gitattributes] No existing rules were deleted." -ForegroundColor Green

# ==============================================================================
# 8. VÉRIFICATIONS FINALES ET TEST RÉEL DE L'OUTIL DE DIFF
# 8. FINAL VERIFICATIONS AND REAL DIFF TOOL TEST
# ==============================================================================
# FR// On affiche les commandes enregistrées et on lance un vrai test de diff.
# ENG// We display the registered commands and run a real diff test.

Write-Host "`n=== VÉRIFICATIONS ===" -ForegroundColor Yellow
Write-Host "=== VERIFICATIONS ===" -ForegroundColor Yellow

# FR// Commande de merge Unity
# ENG// Unity merge command
Write-Host "Commande de merge Unity :" -ForegroundColor White
Write-Host "Unity merge command:" -ForegroundColor White
git config --local mergetool.unityyamlmerge.cmd

# FR// Commande de diff VS Code (si configurée)
# ENG// VS Code diff command (if configured)
if ($vscodeExe) {
    Write-Host "Commande de diff VS Code :" -ForegroundColor White
    Write-Host "VS Code diff command:" -ForegroundColor White
    git config --local difftool.vscode.cmd

    # FR// Test réel : création de deux fichiers temporaires et lancement de VS Code
    # ENG// Real test: creation of two temporary files and launch of VS Code
    Write-Host "`nTest de l'outil de diff (VS Code)..." -ForegroundColor DarkYellow
    Write-Host "Testing diff tool (VS Code)..." -ForegroundColor DarkYellow

    $testDir = ".test_vscode_diff"
    $testFile1 = "$testDir\original.txt"
    $testFile2 = "$testDir\modified.txt"
    if (-not (Test-Path $testDir)) { New-Item -ItemType Directory $testDir | Out-Null }
    "contenu original" > $testFile1
    "contenu modifié" > $testFile2

    $cmd = if ($vscodeExe -eq 'code') { "code" } else { $vscodeExe }
    & $cmd --new-window --wait --diff $testFile1 $testFile2 2>$null

    # FR// Une fois la fenêtre VS Code fermée, on nettoie automatiquement
    # ENG// Once the VS Code window is closed, we automatically clean up
    if (Test-Path $testDir) { Remove-Item -Recurse -Force $testDir }
    Write-Host "Test terminé et fichiers temporaires supprimés." -ForegroundColor Gray
    Write-Host "Test finished and temporary files deleted." -ForegroundColor Gray
}

Write-Host "`nContenu de .gitattributes :" -ForegroundColor White
Write-Host ".gitattributes content:" -ForegroundColor White
Get-Content .gitattributes

Write-Host "`nConfiguration terminée avec succès !" -ForegroundColor Green
Write-Host "Setup completed successfully!" -ForegroundColor Green