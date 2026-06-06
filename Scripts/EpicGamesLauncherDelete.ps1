# Script de suppression complète de l'Epic Games Launcher (avec scan des disques)
# Exécuter dans PowerShell en tant qu'administrateur

# 1. Arrêter tous les processus liés à Epic Games
Write-Host "Arrêt des processus Epic Games..." -ForegroundColor Yellow
$processes = @("EpicGamesLauncher", "EpicWebHelper", "EpicGamesLauncherProxy", "UnrealEngineLauncher", "EpicGamesSetup")
foreach ($proc in $processes) {
    $p = Get-Process -Name $proc -ErrorAction SilentlyContinue
    if ($p) {
        $p | ForEach-Object { 
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
            Write-Host "Processus $($_.Name) arrêté." -ForegroundColor Green
        }
    }
}

# 2. Rechercher le dossier d'installation du lanceur
Write-Host "Recherche du dossier d'installation du lanceur..." -ForegroundColor Yellow

# Chemins de base classiques
$searchPaths = @(
    "$env:ProgramFiles\Epic Games",
    "${env:ProgramFiles(x86)}\Epic Games",
    "C:\Epic Games",
    "D:\Epic Games",
    "E:\Epic Games",
    "F:\Epic Games",
    "G:\Epic Games",
    "H:\Epic Games"
)

# Registre de désinstallation
$uninstallKeys = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
)
foreach ($key in $uninstallKeys) {
    $apps = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "*Epic Games Launcher*" }
    foreach ($app in $apps) {
        if ($app.InstallLocation) {
            $searchPaths += $app.InstallLocation
            Write-Host "Emplacement trouvé dans le Registre : $($app.InstallLocation)" -ForegroundColor Cyan
        }
    }
}

# Autres clés de registre (installations personnalisées)
$extraRegPaths = @(
    "HKLM:\SOFTWARE\Epic Games\EpicGamesLauncher",
    "HKLM:\SOFTWARE\WOW6432Node\Epic Games\EpicGamesLauncher"
)
foreach ($regPath in $extraRegPaths) {
    if (Test-Path $regPath) {
        $props = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
        if ($props.InstallLocation) {
            $searchPaths += $props.InstallLocation
            Write-Host "Emplacement trouvé dans le Registre : $($props.InstallLocation)" -ForegroundColor Cyan
        }
    }
}

# Scan rapide des disques durs pour localiser le dossier "Launcher"
Write-Host "Scan rapide des disques durs pour localiser le lanceur Epic Games..." -ForegroundColor Yellow
$drives = (Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Used -gt 0 }).Root

foreach ($drive in $drives) {
    Write-Host "Scan du lecteur $drive ..." -ForegroundColor Gray
    # Correction de la ligne : parenthèses autour de chaque Test-Path
    $foundFolders = Get-ChildItem -Path $drive -Filter "Launcher" -Directory -Recurse -Depth 2 -ErrorAction SilentlyContinue | Where-Object { (Test-Path (Join-Path $_.FullName "Portal\Binaries\Win32\EpicGamesLauncher.exe")) -or (Test-Path (Join-Path $_.FullName "Portal\Binaries\Win64\EpicGamesLauncher.exe")) }
    
    foreach ($folder in $foundFolders) {
        Write-Host "Dossier Launcher trouvé sur le disque : $($folder.FullName)" -ForegroundColor Cyan
        $searchPaths += $folder.FullName
    }
}

# Nettoyer la liste : supprimer les doublons et les chemins invalides
$searchPaths = $searchPaths | Select-Object -Unique | Where-Object { $_ -and (Test-Path $_) }

# 3. Supprimer les dossiers Launcher trouvés
$launcherFound = $false
foreach ($basePath in $searchPaths) {
    Write-Host "Vérification de : $basePath" -ForegroundColor Gray
    if (Test-Path $basePath) {
        # Détermine si le chemin pointe déjà sur le dossier "Launcher"
        if ($basePath -match "\\Launcher$") {
            $launcherPath = $basePath
        } else {
            $launcherPath = Join-Path $basePath "Launcher"
        }
        
        if (Test-Path $launcherPath) {
            Write-Host "Suppression de : $launcherPath" -ForegroundColor Red
            Remove-Item -Path $launcherPath -Recurse -Force -ErrorAction SilentlyContinue
            $launcherFound = $true
            Write-Host "Dossier Launcher supprimé avec succès !" -ForegroundColor Green
        } else {
            Write-Host "Dossier Launcher non trouvé dans $basePath" -ForegroundColor Gray
        }
    }
}

if (-not $launcherFound) {
    Write-Host "Aucun dossier Launcher trouvé, que ce soit via le Registre ou par scan du disque." -ForegroundColor Yellow
}

# 4. Supprimer les dossiers de données locales (ciblés)
Write-Host "Suppression des dossiers de données locales..." -ForegroundColor Yellow
$localDataPaths = @(
    "$env:LOCALAPPDATA\EpicGamesLauncher",
    "$env:LOCALAPPDATA\Epic Games\Launcher",
    "$env:APPDATA\Epic Games\Launcher",
    "$env:ALLUSERSPROFILE\Epic\EpicGamesLauncher",
    "$env:ALLUSERSPROFILE\Epic Games\Launcher"
)

foreach ($dataPath in $localDataPaths) {
    if (Test-Path $dataPath) {
        Write-Host "Suppression de : $dataPath" -ForegroundColor Red
        Remove-Item -Path $dataPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Dossier de données supprimé avec succès !" -ForegroundColor Green
    } else {
        Write-Host "Dossier non trouvé : $dataPath" -ForegroundColor Gray
    }
}

# 5. Nettoyer les entrées de registre du lanceur uniquement
Write-Host "Nettoyage des entrées de registre..." -ForegroundColor Yellow
$registryPaths = @(
    "HKCU:\Software\Epic Games\EpicGamesLauncher",
    "HKLM:\SOFTWARE\Epic Games\EpicGamesLauncher",
    "HKLM:\SOFTWARE\WOW6432Node\Epic Games\EpicGamesLauncher"
)

foreach ($regPath in $registryPaths) {
    if (Test-Path $regPath) {
        Write-Host "Suppression de la clé de registre : $regPath" -ForegroundColor Red
        Remove-Item -Path $regPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Clé de registre supprimée avec succès !" -ForegroundColor Green
    } else {
        Write-Host "Clé de registre non trouvée : $regPath" -ForegroundColor Gray
    }
}

Write-Host "`nNettoyage terminé ! Redémarre ton PC, puis réinstalle l'Epic Games Launcher depuis le site officiel." -ForegroundColor Cyan
Write-Host "Une fois réinstallé, tu pourras lui indiquer le dossier où se trouvent tes jeux pour qu'il les détecte." -ForegroundColor Cyan