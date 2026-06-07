﻿#Requires -RunAsAdministrator
$ScriptVersion = 'v?'
<#
.SYNOPSIS
    Script de mise-à-jour complète Windows
    Complete Windows update script

.DESCRIPTION
    FR : Effectue toutes les mises à jour disponibles en protégeant les applications en cours.
    EN : Performs all available updates while protecting running applications.

    Couverture / Coverage :
      - Windows Update (système + pilotes / system + drivers)
      - Winget (tous packages, source winget + msstore séparément / all packages, winget + msstore sources)
      - Microsoft Store (apps UWP + source msstore + WinRT)
      - PowerShell 7 + modules PS
      - Chocolatey (si installé / if installed)
      - Scoop (si installé / if installed)
      - Outils dev : pip, npm -g, oh-my-posh, git
      - EdgeWebView2 (réparation automatique / auto repair)
      - Roblox (auto-update natif via son launcher)
      - Nettoyage système + DISM + SFC

    Protections :
      - Détection des processus actifs avant chaque mise à jour
      - Liste blanche configurable : apps jamais tuées en cours d'utilisation
      - Roblox : géré via son launcher natif (winget ne sait pas le faire)
      - Log horodaté dans %TEMP%
      - Exclusion interactive d'étapes ou de packages Winget

.NOTES
    FR //  Nécessite : PowerShell 5.1+ en tant qu'Administrateur.
   ENG //  Requires  : PowerShell 5.1+ as Administrator.
    Auteur.trice / Author  : AetherXYZ
#>

# ══════════════════════════════════════════════════════════════
#  ██████╗ ██████╗ ███╗   ██╗███████╗██╗ ██████╗
# ██╔════╝██╔═══██╗████╗  ██║██╔════╝██║██╔════╝
# ██║     ██║   ██║██╔██╗ ██║█████╗  ██║██║  ███╗
# ██║     ██║   ██║██║╚██╗██║██╔══╝  ██║██║   ██║
# ╚██████╗╚██████╔╝██║ ╚████║██║     ██║╚██████╔╝
#  ╚═════╝ ╚═════╝ ╚═╝  ╚═══╝╚═╝     ╚═╝ ╚═════╝
# ══════════════════════════════════════════════════════════════

# ─────────────────────────────────────────────────────────────
#  CONFIGURATION — modifiable par l'utilisateur
#  CONFIGURATION — user editable
# ─────────────────────────────────────────────────────────────

# FR : Apps à ne JAMAIS mettre à jour si leur processus tourne.
# EN : Apps to NEVER update while their process is running.
# Format : @{ "WingetPackageId" = @("ProcessName1","ProcessName2") }
$ProtectedApps = @{
    # Launchers de jeux / Game launchers
    "EpicGames.EpicGamesLauncher"    = @("EpicGamesLauncher", "EpicWebHelper", "UnrealEngineLauncher")
    "Valve.Steam"                    = @("steam", "steamwebhelper")
    "ElectronicArts.EADesktop"       = @("EADesktop", "EALauncher", "EABackgroundService")
    "GOG.Galaxy"                     = @("GalaxyClient", "GalaxyClientService")
    "Ubisoft.Connect"                = @("UbisoftConnect", "upc")
    "BattleNet.BattleNet"            = @("Battle.net", "BattleNet")
    # Navigateurs / Browsers (mise à jour auto intégrée / have built-in updater)
    "Mozilla.Firefox"                = @("firefox")
    "Google.Chrome"                  = @("chrome")
    # Outils de conf / Conf tools
    "Discord.Discord"                = @("Discord", "DiscordPTB", "DiscordCanary")
    # Outils de dev / Dev tools
    "Microsoft.VisualStudio.2022.Community"   = @("devenv")
    "Microsoft.VisualStudio.2022.Professional" = @("devenv")
    "JetBrains.Rider"                = @("rider64")
    "JetBrains.IntelliJIDEA.Ultimate"= @("idea64")
}

# FR : Apps gérées uniquement par leur propre updater (winget les skip complètement).
# EN : Apps managed only by their own updater (winget skips them entirely).
$SelfUpdatingApps = @(
    "Roblox.Roblox"          # FR: se met à jour via RobloxPlayerLauncher / EN: updates via RobloxPlayerLauncher
    "Microsoft.Teams"        # FR: mise à jour auto intégrée / EN: has built-in auto-update
    "Spotify.Spotify"        # FR: mise à jour auto intégrée / EN: has built-in auto-update
)

#   FR// Lancer Roblox pour déclencher son auto-update natif ?
#  ENG// Launch Roblox to trigger its native self-update?
$TriggerRobloxUpdate = $true

# ─────────────────────────────────────────────────────────────
#   FR//  VARIABLES INTERNES — Ne pas modifier
#  ENG//  INTERNAL VARIABLES — Do not modify
# ─────────────────────────────────────────────────────────────
$LogFile   = "$env:TEMP\WindowsFullUpdate_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$Separator        = "=" * 60
$Script:LogBuffer = [System.Collections.Generic.List[string]]::new()
$TotalSteps       = 9   # 9 étapes principales (sans Roblox)

# Liste des packages winget à ignorer (ID exacts), peuplée par le menu
$Script:WingetIgnore = [System.Collections.Generic.List[string]]::new()

# Étapes désactivées par le menu (noms courts)
$Script:SkipSteps = [System.Collections.Generic.HashSet[string]]::new()

# Jobs en cours — utilisé par le gestionnaire Ctrl+C pour tout nettoyer
$Script:ActiveJobs = [System.Collections.Generic.List[System.Management.Automation.Job]]::new()

# Apps ignorées car en cours d'exécution
$Script:SkippedDueToRunning = [System.Collections.Generic.List[string]]::new()

# Compteurs globaux pour le résumé / Global counters
$Script:CountOK   = 0
$Script:CountFail = 0
$Script:CountSkip = 0

# ─────────────────────────────────────────────
#  FONCTIONS UTILITAIRES — LOG
# ─────────────────────────────────────────────

function Flush-Log {
    if ($Script:LogBuffer.Count -gt 0) {
        $Script:LogBuffer | Add-Content $LogFile -Encoding UTF8
        $Script:LogBuffer.Clear()
    }
}

function Write-Log  { param([string]$m) $Script:LogBuffer.Add($m) }
function Write-OK   { param([string]$m) Write-Host "  [OK]  $m" -ForegroundColor Green;    Write-Log "  [OK]  $m"; $Script:CountOK++ }
function Write-INFO { param([string]$m) Write-Host "  [..]  $m" -ForegroundColor Yellow;   Write-Log "  [..]  $m" }
function Write-FAIL { param([string]$m) Write-Host "  [!!]  $m" -ForegroundColor Red;      Write-Log "  [!!]  $m"; $Script:CountFail++ }
function Write-SKIP { param([string]$m) Write-Host "  [--]  $m" -ForegroundColor DarkGray; Write-Log "  [--]  $m"; $Script:CountSkip++ }

function Write-Header {
    param([string]$Title, [int]$Step, [int]$Total)
    $line = "-" * 60
    Write-Progress -Activity "Windows Full Update" `
                   -Status $Title `
                   -PercentComplete ([int](($Step - 1) / $Total * 100)) `
                   -Id 0
    Write-Host ""
    Write-Host $line      -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host $line      -ForegroundColor Cyan
    Write-Log "`n$line`n  $Title`n$line"
    Flush-Log
}

# ─────────────────────────────────────────────
#  FONCTIONS UTILITAIRES — DIVERS
# ─────────────────────────────────────────────

function Test-Cmd { param([string]$cmd) return [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }

function Stop-ServiceSafe {
    param([string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Stopped') {
        Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
        $timeout = 15
        while ((Get-Service -Name $Name).Status -ne 'Stopped' -and $timeout -gt 0) {
            Start-Sleep 1; $timeout--
        }
    }
}

function Strip-Ansi { param([string]$s) return [regex]::Replace($s, '\x1B\[[0-9;]*[A-Za-z]', '') }

function Show-ExternalOutput {
    param([string[]]$Lines, [string]$Prefix = "    ")
    foreach ($l in $Lines) {
        $clean = Strip-Ansi $l
        if ([string]::IsNullOrWhiteSpace($clean))    { continue }
        if ($clean -match '^\s*[-=\\|/]{3,}\s*$')    { continue }
        if ($clean -match '\[#{1,}[\s#]*\]')          { continue }
        if ($clean -match '^\s*\d+\.?\d*\s*%\s*$')   { continue }
        Write-Log "$Prefix$clean"
        Write-Host "$Prefix$clean" -ForegroundColor DarkGray
    }
}

# ─────────────────────────────────────────────
#  PROTECTION PROCESSUS POUR WINGET
#  PROCESS PROTECTION FOR WINGET
# ─────────────────────────────────────────────

function Test-AppIsRunning {
    # FR : Vérifie si une app protégée est actuellement en cours d'exécution.
    # EN : Checks whether a protected app is currently running.
    param([string]$WingetId)

    if (-not $ProtectedApps.ContainsKey($WingetId)) { return $false }

    foreach ($procName in $ProtectedApps[$WingetId]) {
        $running = Get-Process -Name $procName -ErrorAction SilentlyContinue
        if ($running) {
            Write-SKIP "Processus '$procName' détecté — mise à jour de '$WingetId' ignorée."
            $Script:SkippedDueToRunning.Add($WingetId) | Out-Null
            return $true
        }
    }
    return $false
}

function Invoke-WingetUpgradeWithSpinner {
    # FR : Lance winget upgrade pour un package avec spinner, protection processus et auto-update.
    # EN : Runs winget upgrade for a package with spinner, process protection and self-update check.
    param(
        [string]$PackageId,
        [string]$Source = "winget"
    )

    # FR : App auto-update ? On saute.
    # EN : Self-updating app? We skip.
    if ($SelfUpdatingApps -contains $PackageId) {
        Write-SKIP "$PackageId — géré par son propre updater, ignoré."
        return
    }

    # FR : App en cours d'utilisation ? On saute.
    # EN : App currently in use? We skip.
    if (Test-AppIsRunning -WingetId $PackageId) { return }

    # FR : Exclusion manuelle via menu ?
    # EN : Manual exclusion via menu?
    if ($Script:WingetIgnore -contains $PackageId) {
        Write-SKIP "$PackageId — explicitement ignoré par l'utilisateur."
        return
    }

    $job = Start-Job -ScriptBlock {
        param($id, $src)
        $out = & winget upgrade --id $id --silent --disable-interactivity `
            --accept-source-agreements --accept-package-agreements --source $src 2>&1
        [PSCustomObject]@{ ExitCode = $LASTEXITCODE; Output = $out }
    } -ArgumentList $PackageId, $Source

    $result = Wait-JobWithSpinner -Label "winget : $PackageId" -Job $job

    $output = $result.Output
    $exitCode = $result.ExitCode

    if ($exitCode -eq 0) {
        Write-OK "$PackageId — mis à jour."
    } elseif ($output -match "No applicable update found|already installed|No available upgrade") {
        Write-SKIP "$PackageId — déjà à jour."
    } else {
        Write-FAIL "$PackageId — échec (code $exitCode)."
        Show-ExternalOutput -Lines ($output -split "`n" | Select-Object -Last 3)
    }
}

# ─────────────────────────────────────────────
#  SPINNER — job background + animation sur place
# ─────────────────────────────────────────────

function Wait-JobWithSpinner {
    param([string]$Label, [System.Management.Automation.Job]$Job)

    $frames = @('|', '/', '-', '\')
    $fi     = 0
    $Script:ActiveJobs.Add($Job)

    while ($Job.State -eq 'Running') {
        $f = $frames[$fi % 4]; $fi++
        try {
            $pos = $Host.UI.RawUI.CursorPosition
            $pos.X = 0
            $Host.UI.RawUI.CursorPosition = $pos
            Write-Host ("  [{0}]  {1}   " -f $f, $Label) -NoNewline -ForegroundColor DarkYellow
        } catch {}
        Start-Sleep -Milliseconds 150
    }

    # Effacer la ligne du spinner
    try {
        $pos = $Host.UI.RawUI.CursorPosition
        $pos.X = 0
        $Host.UI.RawUI.CursorPosition = $pos
        Write-Host (" " * ($Label.Length + 16)) -NoNewline
        $pos.X = 0
        $Host.UI.RawUI.CursorPosition = $pos
    } catch {}

    $Script:ActiveJobs.Remove($Job) | Out-Null
    $result = Receive-Job -Job $Job -ErrorAction SilentlyContinue
    Remove-Job -Job $Job -Force
    return $result
}

# ─────────────────────────────────────────────
#  NETTOYAGE D'URGENCE  (Ctrl+C ou erreur fatale)
# ─────────────────────────────────────────────

function Invoke-Cleanup {
    param([string]$Reason = "Interruption")

    Write-Progress -Id 0 -Completed -Activity "Windows Full Update" -ErrorAction SilentlyContinue
    Write-Progress -Id 1 -Completed -Activity "Cleanup"             -ErrorAction SilentlyContinue

    Write-Host ""
    Write-Host ("  " + ("─" * 56)) -ForegroundColor DarkRed
    Write-Host "  [!!]  $Reason — nettoyage en cours..." -ForegroundColor Red
    Write-Log  "`n  [!!]  $Reason — $(Get-Date)"

    # Tuer tous les jobs background enregistrés
    foreach ($j in $Script:ActiveJobs) {
        try { Stop-Job -Job $j -ErrorAction SilentlyContinue } catch {}
        try { Remove-Job -Job $j -Force -ErrorAction SilentlyContinue } catch {}
    }
    # Aussi tous les jobs PS restants au cas où
    Get-Job | Where-Object { $_.State -in 'Running','Stopped' } |
        ForEach-Object { Stop-Job $_ -ErrorAction SilentlyContinue; Remove-Job $_ -Force -ErrorAction SilentlyContinue }

    # Remettre les services Windows Update s'ils auraient été arrêtés
    try { Start-Service -Name "bits"     -ErrorAction SilentlyContinue } catch {}
    try { Start-Service -Name "wuauserv" -ErrorAction SilentlyContinue } catch {}

    Write-Host "  [OK]  Jobs arrêtés, services WU remis en route." -ForegroundColor DarkGray
    Write-Host "  [OK]  Log partiel disponible : $LogFile"          -ForegroundColor DarkGray
    Write-Host ("  " + ("─" * 56)) -ForegroundColor DarkRed

    Write-Log "  Nettoyage terminé — $(Get-Date)"
    Flush-Log
}

# ─────────────────────────────────────────────
#  MENU D'EXCLUSIONS
# ─────────────────────────────────────────────

function Show-ExclusionMenu {

    $allSteps = [ordered]@{
        'winupdate' = '1  Windows Update (KB + drivers)'
        'winget'    = '2  Winget (tous les packages)'
        'powershell'= '3  PowerShell + modules PS'
        'store'     = '4  Microsoft Store'
        'edge'      = '5  Edge WebView2'
        'choco'     = '6  Chocolatey'
        'scoop'     = '7  Scoop'
        'dev'       = '8  Outils dev (pip / npm / git / oh-my-posh)'
        'cleanup'   = '9  Nettoyage système (DISM / SFC / cache WU)'
    }

    Write-Host ""
    Write-Host "  ┌─────────────────────────────────────────────────────┐" -ForegroundColor Yellow
    Write-Host "  │         CONFIGURATION DES EXCLUSIONS                │" -ForegroundColor Yellow
    Write-Host "  └─────────────────────────────────────────────────────┘" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Étapes disponibles :" -ForegroundColor White
    foreach ($k in $allSteps.Keys) {
        Write-Host "    [$k]  $($allSteps[$k])" -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host "  Entrez les clés des étapes à IGNORER, séparées par des virgules." -ForegroundColor White
    Write-Host "  Laissez vide pour tout exécuter." -ForegroundColor DarkGray
    Write-Host ""
    $inputSteps = (Read-Host "  Étapes à ignorer").Trim()

    if ($inputSteps -ne '') {
        foreach ($token in ($inputSteps -split ',')) {
            $key = $token.Trim().ToLower()
            if ($allSteps.Contains($key)) {
                $Script:SkipSteps.Add($key) | Out-Null
                Write-Host "    → Étape ignorée : $($allSteps[$key])" -ForegroundColor DarkYellow
            } else {
                Write-Host "    → Clé inconnue ignorée : '$key'" -ForegroundColor DarkGray
            }
        }
    }

    # Exclusions de packages winget individuels
    Write-Host ""
    Write-Host "  Packages winget à exclure (IDs exacts, ex: Mozilla.Firefox,Spotify.Spotify)" -ForegroundColor White
    Write-Host "  Laissez vide pour aucune exclusion." -ForegroundColor DarkGray
    Write-Host ""
    $inputPkgs = (Read-Host "  Packages winget à ignorer").Trim()

    if ($inputPkgs -ne '') {
        foreach ($pkg in ($inputPkgs -split ',')) {
            $id = $pkg.Trim()
            if ($id -ne '') {
                $Script:WingetIgnore.Add($id) | Out-Null
                Write-Host "    → Package exclu : $id" -ForegroundColor DarkYellow
            }
        }
    }

    Write-Log "Exclusions étapes  : $($Script:SkipSteps -join ', ')"
    Write-Log "Exclusions winget  : $($Script:WingetIgnore -join ', ')"
    Write-Host ""
}

function Test-StepSkipped { param([string]$key) return $Script:SkipSteps.Contains($key) }

# ─────────────────────────────────────────────
#  BANNIÈRE
# ─────────────────────────────────────────────

Clear-Host
Write-Host $Separator                                                         -ForegroundColor Magenta
Write-Host "   WINDOWS FULL UPDATE SCRIPT $ScriptVersion"                              -ForegroundColor Magenta
Write-Host "   $(Get-Date -Format 'dddd dd MMMM yyyy - HH:mm:ss')"           -ForegroundColor Magenta
Write-Host "   Machine : $env:COMPUTERNAME  |  User : $env:USERNAME"         -ForegroundColor Magenta
Write-Host $Separator                                                         -ForegroundColor Magenta
Write-Log "$Separator`n   WINDOWS FULL-UPDATE - $(Get-Date)`n   Machine: $env:COMPUTERNAME`n$Separator"
Flush-Log

Show-ExclusionMenu

# ──────────────────────────────────────────────
#  BLOC PRINCIPAL  —  Protégé contre Ctrl + C
# ──────────────────────────────────────────────
#
#  On intercepte Ctrl+C via le mécanisme PowerShell standard :
#  le finally{} du try/finally est TOUJOURS exécuté, même sur
#  une terminaison par Ctrl+C (PipelineStoppedException).
#  On désactive aussi le comportement "quitter immédiatement"
#  de la console pour avoir le temps de nettoyer.
# ─────────────────────────────────────────────

[Console]::TreatControlCAsInput = $false   # laisser PS gérer Ctrl+C proprement

try {

# ─────────────────────────────────────────────
#  1/9  WINDOWS UPDATE
# ─────────────────────────────────────────────

Write-Header "1/9  WINDOWS UPDATE" -Step 1 -Total $TotalSteps

if (Test-StepSkipped 'winupdate') {
    Write-SKIP "Étape ignorée à la demande."
} else {
    if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
        Write-INFO "Installation du module PSWindowsUpdate..."
        try {
            $installJob = Start-Job -ScriptBlock {
                Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers *>&1 | Out-Null
                Install-Module -Name PSWindowsUpdate -Force -Scope AllUsers -SkipPublisherCheck *>&1 | Out-Null
            }
            Wait-JobWithSpinner -Label "Installation de PSWindowsUpdate" -Job $installJob | Out-Null
            Write-OK "Module PSWindowsUpdate installé."
        } catch { Write-FAIL "Impossible d'installer PSWindowsUpdate : $_" }
    }

    try {
        Import-Module PSWindowsUpdate -ErrorAction Stop

        Write-INFO "Recherche et installation des mises à jour Windows..."
        $wuJob = Start-Job -ScriptBlock {
            Import-Module PSWindowsUpdate -ErrorAction SilentlyContinue
            Install-WindowsUpdate -AcceptAll -IgnoreReboot -MicrosoftUpdate `
                -Verbose:$false -WarningAction SilentlyContinue *>&1
        }
        $wuOutput = Wait-JobWithSpinner -Label "Windows Update en cours" -Job $wuJob
        $wuCount  = @($wuOutput | Where-Object { $_ -match 'KB\d+' }).Count
        if ($wuCount -gt 0) { Write-OK "$wuCount mise(s) à jour Windows appliquée(s)." ; $wuOutput | ForEach-Object { Write-Log "    $_" } }
        else                { Write-SKIP "Aucune mise à jour Windows disponible." }

        Write-INFO "Recherche des mises à jour de pilotes..."
        $drvJob = Start-Job -ScriptBlock {
            Import-Module PSWindowsUpdate -ErrorAction SilentlyContinue
            Install-WindowsUpdate -AcceptAll -IgnoreReboot -UpdateType Driver `
                -Verbose:$false -WarningAction SilentlyContinue *>&1
        }
        $drvOutput = Wait-JobWithSpinner -Label "Recherche des pilotes" -Job $drvJob
        $drvCount  = @($drvOutput | Where-Object { $_ -match 'KB\d+' }).Count
        if ($drvCount -gt 0) { Write-OK "$drvCount pilote(s) mis à jour." ; $drvOutput | ForEach-Object { Write-Log "    $_" } }
        else                 { Write-SKIP "Aucun pilote à mettre à jour." }

    } catch { Write-FAIL "Erreur Windows Update : $_" }
}
Flush-Log

# ─────────────────────────────────────────────
#  2/9  WINGET (source winget) — avec protection processus
# ─────────────────────────────────────────────

Write-Header "2/9  WINGET — TOUS LES PACKAGES (avec protection)" -Step 2 -Total $TotalSteps

if (Test-StepSkipped 'winget') {
    Write-SKIP "Étape ignorée à la demande."
} elseif (-not (Test-Cmd "winget")) {
    Write-SKIP "winget non trouvé. Installez App Installer depuis le Microsoft Store."
} else {
    Write-INFO "Mise à jour de winget (App Installer)..."
    try {
        & winget upgrade --id Microsoft.AppInstaller --silent `
            --accept-source-agreements --accept-package-agreements *>&1 | Out-Null
        Write-OK "winget à jour."
    } catch { Write-FAIL "Impossible de mettre à jour winget : $_" }

    Write-INFO "Récupération de la liste des packages à mettre à jour..."
    $listJob = Start-Job -ScriptBlock {
        & winget upgrade --include-unknown 2>&1
    }
    $listRaw = Wait-JobWithSpinner -Label "Liste winget" -Job $listJob

    $upgradeList = $listRaw |
        Where-Object { $_ -match '^\S' -and $_ -notmatch '^Nom|^Name|^-{2,}' } |
        ForEach-Object {
            $parts = $_ -split '\s{2,}'
            if ($parts.Count -ge 2) { $parts[1].Trim() }
        } | Where-Object { $_ -and $_ -notmatch '^\s*$' -and $_ -match '\.' }

    if ($upgradeList.Count -gt 0) {
        Write-INFO "$($upgradeList.Count) package(s) à traiter."
        $i = 0
        foreach ($pkgId in $upgradeList) {
            $i++
            Write-Progress -Activity "winget upgrade" -Status $pkgId `
                -PercentComplete ([int]($i / $upgradeList.Count * 100)) -Id 1 -ParentId 0
            Invoke-WingetUpgradeWithSpinner -PackageId $pkgId -Source "winget"
        }
        Write-Progress -Id 1 -Completed -Activity "winget upgrade"
    } else {
        Write-SKIP "Aucun package winget à mettre à jour."
    }
}
Flush-Log

# ─────────────────────────────────────────────
#  3/9  POWERSHELL + MODULES
# ─────────────────────────────────────────────

Write-Header "3/9  POWERSHELL + MODULES" -Step 3 -Total $TotalSteps

if (Test-StepSkipped 'powershell') {
    Write-SKIP "Étape ignorée à la demande."
} else {
    Write-INFO "Mise à jour de PowerShellGet et PackageManagement..."
    try {
        Install-Module -Name PowerShellGet -Force -AllowClobber -Scope AllUsers `
            -SkipPublisherCheck -WarningAction SilentlyContinue *>&1 | Out-Null
        Install-Module -Name PackageManagement -Force -AllowClobber -Scope AllUsers `
            -SkipPublisherCheck -WarningAction SilentlyContinue *>&1 | Out-Null
        Write-OK "PowerShellGet et PackageManagement mis à jour."
    } catch { Write-FAIL "Erreur : $_" }

    if (Test-Cmd "winget") {
        Write-INFO "Mise à jour de PowerShell 7 via winget..."
        Invoke-WingetUpgradeWithSpinner -PackageId "Microsoft.PowerShell" -Source "winget"
    } else {
        Write-SKIP "winget absent — mise à jour PowerShell 7 ignorée."
    }

    Write-INFO "Mise à jour de tous les modules PowerShell installés..."
    $psModules = Get-InstalledModule -ErrorAction SilentlyContinue
    if ($psModules) {
        $total = $psModules.Count; $i = 0
        foreach ($mod in $psModules) {
            $i++
            Write-Progress -Activity "Modules PowerShell" -Status $mod.Name `
                -PercentComplete ([int]($i / $total * 100)) -Id 1 -ParentId 0
            try {
                Update-Module -Name $mod.Name -Force `
                    -WarningAction SilentlyContinue -ErrorAction Stop *>&1 | Out-Null
                Write-OK "Module $($mod.Name) mis à jour."
            } catch { Write-FAIL "Impossible de mettre à jour $($mod.Name) : $_" }
        }
        Write-Progress -Id 1 -Completed -Activity "Modules PowerShell"
    } else {
        Write-SKIP "Aucun module PowerShell installé via PSGallery."
    }
}
Flush-Log

# ─────────────────────────────────────────────
#  4/9  MICROSOFT STORE (source msstore + WinRT)
# ─────────────────────────────────────────────

Write-Header "4/9  MICROSOFT STORE" -Step 4 -Total $TotalSteps

if (Test-StepSkipped 'store') {
    Write-SKIP "Étape ignorée à la demande."
} else {
    $storeDone = $false
    try {
        Add-Type -AssemblyName "Windows.ApplicationModel" -ErrorAction Stop
        $typeName = 'Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallManager, Windows.ApplicationModel.Store.Preview.InstallControl, ContentType=WindowsRuntime'
        $type = [Type]::GetType($typeName, $true)
        $mgr     = [Activator]::CreateInstance($type)
        $updates = $mgr.SearchForAllUpdatesAsync().GetAwaiter().GetResult()
        if ($updates.Count -gt 0) {
            foreach ($u in $updates) {
                $mgr.StartAppInstallAsync($u.PackageFamilyName, $null, $true, $false).GetAwaiter().GetResult() | Out-Null
                Write-OK "Mise à jour lancée : $($u.PackageFamilyName)"
            }
            $storeDone = $true
        } else {
            Write-SKIP "Aucune mise à jour Store disponible (WinRT)."
            $storeDone = $true
        }
    } catch {}

    if (-not $storeDone) {
        if (Test-Cmd "winget") {
            Write-INFO "Mise à jour Store via winget (source msstore)..."
            try {
                & winget upgrade --all --source msstore --silent --disable-interactivity `
                    --accept-source-agreements --accept-package-agreements *>&1 | Out-Null
                Write-OK "Apps Store mises à jour via winget."
            } catch { Write-FAIL "Erreur Store via winget : $_" }
        } else {
            Write-FAIL "Mise à jour Store impossible : winget absent et WinRT indisponible."
        }
    }
}
Flush-Log

# ─────────────────────────────────────────────
#  5/9  EDGE WEBVIEW2 (réparation automatique)
# ─────────────────────────────────────────────

Write-Header "5/9  MICROSOFT EDGE WEBVIEW2" -Step 5 -Total $TotalSteps

if (Test-StepSkipped 'edge') {
    Write-SKIP "Étape ignorée à la demande."
} else {
    Write-INFO "Mise à jour de Edge WebView2 Runtime..."
    try {
        $wv2Job = Start-Job -ScriptBlock {
            $out = & winget upgrade --id Microsoft.EdgeWebView2Runtime --silent `
                --accept-source-agreements --accept-package-agreements 2>&1
            [PSCustomObject]@{ ExitCode = $LASTEXITCODE; Output = $out }
        }
        $wv2Res = Wait-JobWithSpinner -Label "Edge WebView2" -Job $wv2Job
        $wv2ExitCode = $wv2Res.ExitCode
        $wv2Output   = $wv2Res.Output

        if ($wv2ExitCode -eq 0) {
            Write-OK "EdgeWebView2 mis à jour."
        } elseif ($wv2Output -match "already installed|No applicable") {
            Write-SKIP "EdgeWebView2 déjà à jour."
        } else {
            Write-INFO "Problème détecté — tentative de réparation EdgeWebView2..."
            # Tentative de réinstallation propre via le programme de réparation intégré
            $wv2Key = Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" -ErrorAction SilentlyContinue
            if ($wv2Key -and (Test-Path $wv2Key.path)) {
                Start-Process $wv2Key.path -ArgumentList "--reinstall --system-level --verbose-logging" -Wait -NoNewWindow
                Write-OK "EdgeWebView2 réparé via le programme natif."
            } else {
                # Fallback : téléchargement + installation directe
                $wv2Url = "https://go.microsoft.com/fwlink/p/?LinkId=2124703"
                $wv2Installer = "$env:TEMP\MicrosoftEdgeWebview2Setup.exe"
                Invoke-WebRequest -Uri $wv2Url -OutFile $wv2Installer -UseBasicParsing
                Start-Process $wv2Installer -ArgumentList "/silent /install" -Wait -NoNewWindow
                Remove-Item $wv2Installer -Force -ErrorAction SilentlyContinue
                Write-OK "EdgeWebView2 réinstallé depuis le CDN Microsoft."
            }
        }
    } catch {
        Write-FAIL "Erreur EdgeWebView2 : $_"
    }
}
Flush-Log

# ─────────────────────────────────────────────
#  6/9  CHOCOLATEY
# ─────────────────────────────────────────────

Write-Header "6/9  CHOCOLATEY" -Step 6 -Total $TotalSteps

if (Test-StepSkipped 'choco') {
    Write-SKIP "Étape ignorée à la demande."
} elseif (-not (Test-Cmd "choco")) {
    Write-SKIP "Chocolatey non installé — étape ignorée."
} else {
    Write-INFO "Mise à jour de Chocolatey..."
    & choco upgrade chocolatey -y --no-progress *>&1 | Out-Null
    Write-OK "Chocolatey mis à jour."

    Write-INFO "Mise à jour de tous les packages Chocolatey..."
    $chocoRaw = & choco upgrade all -y --no-progress 2>&1
    Show-ExternalOutput -Lines $chocoRaw
    Write-OK "Packages Chocolatey traités."
}
Flush-Log

# ─────────────────────────────────────────────
#  7/9  SCOOP
# ─────────────────────────────────────────────

Write-Header "7/9  SCOOP" -Step 7 -Total $TotalSteps

if (Test-StepSkipped 'scoop') {
    Write-SKIP "Étape ignorée à la demande."
} elseif (-not (Test-Cmd "scoop")) {
    Write-SKIP "Scoop non installé — étape ignorée."
} else {
    Write-INFO "Mise à jour de Scoop..."
    & scoop update *>&1 | Out-Null
    Write-OK "Scoop mis à jour."

    Write-INFO "Mise à jour de tous les apps Scoop..."
    $scoopRaw = & scoop update * 2>&1
    Show-ExternalOutput -Lines $scoopRaw
    Write-OK "Packages Scoop traités."

    Write-INFO "Nettoyage des anciennes versions Scoop..."
    & scoop cleanup * *>&1 | Out-Null
    Write-OK "Nettoyage Scoop terminé."
}
Flush-Log

# ─────────────────────────────────────────────
#  8/9  OUTILS DEV
# ─────────────────────────────────────────────

Write-Header "8/9  OUTILS DEV" -Step 8 -Total $TotalSteps

if (Test-StepSkipped 'dev') {
    Write-SKIP "Étape ignorée à la demande."
} else {
    # pip
    if (Test-Cmd "pip") {
        Write-INFO "Mise à jour de pip..."
        try { & python -m pip install --upgrade pip --quiet *>&1 | Out-Null ; Write-OK "pip mis à jour." }
        catch { Write-FAIL "Erreur pip : $_" }

        Write-INFO "Recherche des packages pip obsolètes..."
        try {
            $outdated = @(& pip list --outdated --format=columns 2>&1 |
                Select-Object -Skip 2 |
                ForEach-Object { ($_ -split '\s+')[0] } |
                Where-Object { $_ -ne '' -and $_ -notmatch '^-' })
            if ($outdated.Count -gt 0) {
                $i = 0
                foreach ($pkg in $outdated) {
                    $i++
                    Write-Progress -Activity "Mise à jour pip" -Status $pkg `
                        -PercentComplete ([int]($i / $outdated.Count * 100)) -Id 1 -ParentId 0
                    & pip install --upgrade $pkg --quiet *>&1 | Out-Null
                    Write-OK "pip : $pkg mis à jour."
                }
                Write-Progress -Id 1 -Completed -Activity "pip"
            } else { Write-SKIP "Tous les packages pip sont à jour." }
        } catch { Write-FAIL "Erreur mise à jour packages pip : $_" }
    } else { Write-SKIP "pip non trouvé — étape ignorée." }

    # npm global
    if (Test-Cmd "npm") {
        Write-INFO "Mise à jour de npm..."
        try { & npm install -g npm --silent *>&1 | Out-Null ; Write-OK "npm mis à jour." }
        catch { Write-FAIL "Erreur mise à jour npm : $_" }

        Write-INFO "Mise à jour des packages npm globaux..."
        try { & npm update -g --silent *>&1 | Out-Null ; Write-OK "Packages npm globaux mis à jour." }
        catch { Write-FAIL "Erreur npm update -g : $_" }
    } else { Write-SKIP "npm non trouvé — étape ignorée." }

    # Oh My Posh
    if (Test-Cmd "oh-my-posh") {
        Write-INFO "Mise à jour de Oh My Posh..."
        Invoke-WingetUpgradeWithSpinner -PackageId "JanDeDobbeleer.OhMyPosh" -Source "winget"
    } else { Write-SKIP "Oh My Posh non trouvé — étape ignorée." }

    # Git
    if (Test-Cmd "git") {
        Write-INFO "Mise à jour de Git..."
        Invoke-WingetUpgradeWithSpinner -PackageId "Git.Git" -Source "winget"
    } else { Write-SKIP "Git non trouvé — étape ignorée." }
}
Flush-Log

# ─────────────────────────────────────────────
#  9/9  NETTOYAGE & SANTÉ SYSTÈME
# ─────────────────────────────────────────────

Write-Header "9/9  NETTOYAGE & SANTÉ SYSTÈME" -Step 9 -Total $TotalSteps

if (Test-StepSkipped 'cleanup') {
    Write-SKIP "Étape ignorée à la demande."
} else {
    # Cache Windows Update
    Write-INFO "Nettoyage du cache Windows Update..."
    try {
        Stop-ServiceSafe "wuauserv"
        Stop-ServiceSafe "bits"
        Remove-Item "$env:SystemRoot\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
        Start-Service -Name "bits"     -ErrorAction SilentlyContinue
        Start-Service -Name "wuauserv" -ErrorAction SilentlyContinue
        Write-OK "Cache Windows Update vidé."
    } catch { Write-FAIL "Erreur nettoyage cache : $_" }

    # DISM — en job
    Write-INFO "Vérification de l'intégrité de l'image système (DISM)..."
    $dismJob = Start-Job -ScriptBlock {
        $out = & DISM /Online /Cleanup-Image /ScanHealth 2>&1
        [PSCustomObject]@{ ExitCode = $LASTEXITCODE; Output = $out }
    }
    $dismRes = Wait-JobWithSpinner -Label "DISM ScanHealth en cours" -Job $dismJob
    $dismRes.Output | ForEach-Object { Write-Log "    $_" }

    if ($dismRes.ExitCode -eq 0) {
        Write-OK "Image système saine (DISM)."
    } else {
        Write-INFO "Corruption détectée — tentative de réparation..."
        $dismJob2 = Start-Job -ScriptBlock {
            $out = & DISM /Online /Cleanup-Image /RestoreHealth 2>&1
            [PSCustomObject]@{ ExitCode = $LASTEXITCODE; Output = $out }
        }
        $dismRes2 = Wait-JobWithSpinner -Label "DISM RestoreHealth en cours" -Job $dismJob2
        $dismRes2.Output | ForEach-Object { Write-Log "    $_" }
        if ($dismRes2.ExitCode -eq 0) { Write-OK "Image système réparée (DISM)." }
        else { Write-FAIL "DISM RestoreHealth a échoué (code $($dismRes2.ExitCode))." }
    }

    # SFC — en job
    Write-INFO "Vérification des fichiers système (SFC)..."
    $sfcJob = Start-Job -ScriptBlock {
        $out = & sfc /scannow 2>&1
        [PSCustomObject]@{ ExitCode = $LASTEXITCODE; Output = $out }
    }
    $sfcRes = Wait-JobWithSpinner -Label "SFC /scannow en cours" -Job $sfcJob
    $sfcRes.Output | ForEach-Object { Write-Log "    $_" }

    switch ($sfcRes.ExitCode) {
        0       { Write-OK   "SFC : aucune anomalie détectée." }
        1       { Write-OK   "SFC : fichiers corrompus réparés avec succès." }
        2       { Write-FAIL "SFC : fichiers corrompus détectés mais non réparés." }
        default { Write-FAIL "SFC : code de sortie inattendu ($($sfcRes.ExitCode))." }
    }
}
Flush-Log

# ─────────────────────────────────────────────
#  ROBLOX — auto-update natif
# ─────────────────────────────────────────────

Write-Host ""
$line = "-" * 60
Write-Host $line      -ForegroundColor Cyan
Write-Host "  ⚙  ROBLOX  —  AUTO-UPDATE NATIF" -ForegroundColor Cyan
Write-Host $line      -ForegroundColor Cyan

if ($TriggerRobloxUpdate) {
    $robloxLauncher = "$env:LOCALAPPDATA\Roblox\Versions\*\RobloxPlayerLauncher.exe"
    $launcherPath   = Get-ChildItem -Path $robloxLauncher -ErrorAction SilentlyContinue |
                      Sort-Object LastWriteTime -Descending |
                      Select-Object -First 1 -ExpandProperty FullName

    if ($launcherPath) {
        $robloxRunning = Get-Process -Name "RobloxPlayerBeta","RobloxPlayer" -ErrorAction SilentlyContinue
        if ($robloxRunning) {
            Write-SKIP "Roblox est en cours d'exécution — mise à jour différée à la prochaine fermeture."
        } else {
            Write-INFO "Démarrage du launcher Roblox pour déclenchement de l'auto-update..."
            Start-Process $launcherPath -ArgumentList "--app" -ErrorAction SilentlyContinue
            Start-Sleep 8
            Stop-Process -Name "RobloxPlayerLauncher" -Force -ErrorAction SilentlyContinue
            Write-OK "Roblox launcher démarré — mise à jour native déclenchée."
        }
    } else {
        Write-SKIP "Roblox non installé ou launcher introuvable."
    }
} else {
    Write-SKIP "Mise à jour Roblox désactivée dans la config (`$TriggerRobloxUpdate = `$false)."
}
Flush-Log

Write-Progress -Id 0 -Completed -Activity "Windows Full Update"

# ─────────────────────────────────────────────
#  RÉSUMÉ FINAL AVEC APPS IGNORÉES
# ─────────────────────────────────────────────

Write-Host ""
Write-Host $Separator                                          -ForegroundColor Magenta
Write-Host "   MISE À JOUR COMPLÈTE TERMINÉE"                 -ForegroundColor Green
Write-Host "   $(Get-Date -Format 'HH:mm:ss')"                -ForegroundColor Green
Write-Host "   Succès : $Script:CountOK   Ignorés : $Script:CountSkip   Échecs : $Script:CountFail" -ForegroundColor White
Write-Host "   Log complet : $LogFile"                        -ForegroundColor Yellow
Write-Host $Separator                                          -ForegroundColor Magenta
Write-Log "`n$Separator`n   TERMINÉ : $(Get-Date)`n   Succès=$Script:CountOK Ignorés=$Script:CountSkip Échecs=$Script:CountFail`n   Log : $LogFile`n$Separator"
Flush-Log

# Affichage des apps ignorées car en cours d'exécution
if ($Script:SkippedDueToRunning.Count -gt 0) {
    Write-Host ""
    Write-Host "  ▲  Apps ignorées (processus actif au moment de la MAJ) :" -ForegroundColor DarkYellow
    foreach ($app in $Script:SkippedDueToRunning | Select-Object -Unique) {
        Write-Host "     → $app" -ForegroundColor DarkYellow
    }
    Write-Host "     Relancez le script après avoir fermé ces applications." -ForegroundColor DarkYellow
}

# Statut redémarrage
$needsReboot = $false
try { $needsReboot = (Get-WURebootStatus -Silent -ErrorAction SilentlyContinue).RebootRequired } catch {}
if (-not $needsReboot) { try { $needsReboot = Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired" } catch {} }
if (-not $needsReboot) { try { $needsReboot = Test-Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations" }          catch {} }

Write-Host ""
if ($needsReboot) {
    Write-Host "  ⚠  Un redémarrage est requis pour finaliser les mises à jour." -ForegroundColor Red
    Write-Host "      Pensez à redémarrer dès que possible."                       -ForegroundColor Yellow
} else {
    Write-Host "  ✓  Aucun redémarrage requis."                                   -ForegroundColor Green
}
Write-Host ""

} catch [System.Management.Automation.PipelineStoppedException] {
    # Ctrl+C intercepté par PowerShell
    Invoke-Cleanup -Reason "Interruption par Ctrl+C"
} catch {
    # Toute autre exception non gérée
    Invoke-Cleanup -Reason "Erreur fatale : $_"
    throw
} finally {
    # S'exécute TOUJOURS (Ctrl+C, erreur, ou fin normale)
    # Garantit que les barres de progression sont fermées et le log flushé
    Write-Progress -Id 0 -Completed -Activity "Windows Full Update" -ErrorAction SilentlyContinue
    Write-Progress -Id 1 -Completed -Activity "Cleanup"             -ErrorAction SilentlyContinue
    Flush-Log
}
