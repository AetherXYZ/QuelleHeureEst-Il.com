# ============================================================
# Maintenance Windows Pro - Version GUI + logique intelligente
# Auteur : Sha Kigrif (+ Copilot)
# ============================================================

# Force PowerShell 5.1
if ($PSVersionTable.PSVersion.Major -ge 7) {
    Start-Process "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# Auto-élévation si pas admin
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator"))
{
    Start-Process powershell.exe "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

$Xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Maintenance Windows Pro" Height="520" Width="820"
        WindowStartupLocation="CenterScreen" ResizeMode="CanResizeWithGrip">
    <Grid Margin="10">
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="2*"/>
            <ColumnDefinition Width="3*"/>
        </Grid.ColumnDefinitions>
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <TextBlock Grid.ColumnSpan="2" Text="Maintenance Windows Pro" 
                   FontSize="20" FontWeight="Bold" Margin="0,0,0,10"/>

        <StackPanel Grid.Row="1" Grid.Column="0" Margin="0,0,10,0">
            <GroupBox Header="Options" Margin="0,0,0,10">
                <StackPanel Margin="5">
                    <CheckBox x:Name="chkSilent" Content="Mode silencieux" Margin="0,2"/>
                    <CheckBox x:Name="chkAuto" Content="Mode automatique (moins de confirmations)" Margin="0,2"/>
                    <CheckBox x:Name="chkRepair" Content="Autoriser réparations système" Margin="0,2" IsChecked="True"/>
                    <CheckBox x:Name="chkUpdates" Content="Mettre à jour Windows / Apps / Pilotes" Margin="0,2" IsChecked="True"/>
                    <CheckBox x:Name="chkDeps" Content="Installer / MAJ .NET / VC++ / WinGetUI" Margin="0,2" IsChecked="True"/>
                    <CheckBox x:Name="chkDrivers" Content="Mettre à jour les pilotes (Intel/AMD/NVIDIA/OEM)" Margin="0,2" IsChecked="True"/>
                    <CheckBox x:Name="chkGaming" Content="Activer optimisations énergie + gaming" Margin="0,2"/>
                </StackPanel>
            </GroupBox>

            <GroupBox Header="Actions rapides">
                <StackPanel Margin="5">
                    <Button x:Name="btnInfo" Content="Infos système" Margin="0,2" Height="28"/>
                    <Button x:Name="btnNetwork" Content="Test réseau" Margin="0,2" Height="28"/>
                    <Button x:Name="btnWinget" Content="Test Winget" Margin="0,2" Height="28"/>
                    <Button x:Name="btnRepair" Content="Réparation DISM + SFC" Margin="0,2" Height="28"/>
                    <Button x:Name="btnUpdates" Content="Mises à jour" Margin="0,2" Height="28"/>
                    <Button x:Name="btnDeps" Content="Dépendances (.NET / VC++ / WinGetUI)" Margin="0,2" Height="28"/>
                    <Button x:Name="btnDrivers" Content="Pilotes" Margin="0,2" Height="28"/>
                    <Button x:Name="btnGaming" Content="Optimisations gaming" Margin="0,2" Height="28"/>
                    <Button x:Name="btnFull" Content="Maintenance complète" Margin="0,10,0,0" Height="32" FontWeight="Bold"/>
                    <Button x:Name="btnCancel" Content="Annuler l'opération en cours" Margin="0,5,0,0" Height="28"/>
                </StackPanel>
            </GroupBox>
        </StackPanel>

        <GroupBox Grid.Row="1" Grid.Column="1" Header="Journal" Margin="0,0,0,10">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <TextBox x:Name="txtLog" Grid.Row="0" Margin="5" FontFamily="Consolas" FontSize="12"
                         IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"
                         AcceptsReturn="True"/>
                <ProgressBar x:Name="progress" Grid.Row="1" Margin="5,0,5,5" Height="18" Minimum="0" Maximum="100" Value="0"/>
            </Grid>
        </GroupBox>

        <StackPanel Grid.Row="2" Grid.ColumnSpan="2" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="btnOpenLog" Content="Ouvrir le fichier log" Margin="0,0,10,0" Width="150"/>
            <Button x:Name="btnQuit" Content="Quitter" Width="100"/>
        </StackPanel>
    </Grid>
</Window>
"@

# ------------------------------------------------------------
# LOG SUR LE BUREAU (OPTIONNEL)
# ------------------------------------------------------------
$global:LogPath = Join-Path $env:USERPROFILE "Desktop\MaintenanceWindows.log"
Start-Transcript -Path $global:LogPath -Append -ErrorAction SilentlyContinue | Out-Null


# ------------------------------------------------------------
# PRÉFÉRENCES UTILISATEUR (REMPLIES PAR LA GUI)
# ------------------------------------------------------------
$global:DoSilent       = $false
$global:DoAuto         = $false
$global:DoRepair       = $true
$global:DoUpdates      = $true
$global:DoDependencies = $true
$global:DoDrivers      = $true
$global:DoGaming       = $false

# Indicateur d'occupation (évite les clics multiples)
$global:IsBusy          = $false
$global:CancelRequested = $false

# Fichier de préférences
$global:PrefsPath = Join-Path $env:APPDATA "MaintenanceWindows\prefs.json"


# ============================================================
# AFFICHAGE & WRAPPERS
# ============================================================

function Write-Info { param($m) if (-not $DoSilent) { Write-Host $m -ForegroundColor Cyan } }
function Write-Ok   { param($m) if (-not $DoSilent) { Write-Host $m -ForegroundColor Green } }
function Write-Warn { param($m) if (-not $DoSilent) { Write-Host $m -ForegroundColor Yellow } }
function Write-Err  { param($m) Write-Host $m -ForegroundColor Red }

function Safe-Run {
    param(
        [string]$Name,
        [scriptblock]$Action
    )

    Write-Info "→ $Name"

    try {
        & $Action
        Write-Ok "✓ $Name terminé"
    }
    catch {
        Write-Warn "$Name a échoué : $($_.Exception.Message)"
    }
}

function Try-Action {
    param([scriptblock]$Action)

    try {
        & $Action
    }
    catch {
        Write-Err $_.Exception.Message
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Erreur", "OK", "Error") | Out-Null
    }
}

function Set-Busy {
    param([bool]$State)

    $global:IsBusy = $State
    if ($global:Window -ne $null) {
        $global:Window.IsEnabled = -not $State
    }
}


# ============================================================
# VÉRIFICATIONS SYSTÈME
# ============================================================

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)

    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Err "Ce script doit être lancé en tant qu'administrateur."
        [System.Windows.MessageBox]::Show("Lance PowerShell en tant qu'administrateur.", "Droits insuffisants", "OK", "Error") | Out-Null
        Stop-Transcript | Out-Null
        exit 1
    }
}

function Show-SystemInfo {
    Write-Info "`n[1] Informations système"

    $os = Get-ComputerInfo

    Write-Host "Windows Edition : $($os.WindowsProductName)"
    Write-Host "Version         : $($os.WindowsVersion)"
    Write-Host "Build           : $($os.OsBuildNumber)"
    Write-Host "Architecture    : $($os.OsArchitecture)"
    Write-Host "Nom machine     : $($os.CsName)"
}

function Test-Network {
    Write-Info "Vérification de la connexion Internet..."

    if (-not (Test-Connection -Count 1 -Quiet 8.8.8.8)) {
        Write-Err "Pas de connexion Internet détectée."
        throw "Pas de connexion Internet."
    }

    try {
        Resolve-DnsName "microsoft.com" -ErrorAction Stop | Out-Null
    } catch {
        Write-Err "DNS non fonctionnel. Impossible de résoudre microsoft.com."
        throw "DNS non fonctionnel."
    }

    Write-Ok "Connexion Internet OK"
}

function Test-Winget {
    Write-Info "Vérification de Winget..."

    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        Write-Err "Winget introuvable sur ce système."
        return $false
    }

    try {
        winget source list | Out-Null
    }
    catch {
        Write-Warn "Sources Winget corrompues → réinitialisation..."
        try {
            winget source reset --force
        }
        catch {
            Write-Err "Impossible de réparer les sources Winget."
            return $false
        }
    }

    Write-Ok "Winget opérationnel"
    return $true
}

function Test-PowerShellVersion {
    $v = $PSVersionTable.PSVersion
    Write-Info "PowerShell version : $v"

    if ($v.Major -lt 7) {
        Write-Warn "Version PowerShell obsolète. Mise à jour recommandée."
    }
}

function Test-DotNet {
    Write-Info "Vérification des runtimes .NET..."
    $dotnet = & dotnet --list-runtimes 2>$null
    if ($dotnet) {
        Write-Ok ".NET déjà installé :"
        $dotnet | ForEach-Object { Write-Info " - $_" }
        return $true
    }
    Write-Warn ".NET non détecté."
    return $false
}

function Test-WingetVersion {
    try {
        $v = winget --version
        Write-Info "Winget version : $v"
    }
    catch {
        Write-Warn "Impossible de récupérer la version Winget."
    }
}


# ============================================================
# SERVICES & MODULES
# ============================================================

function Ensure-Service {
    param([string]$ServiceName)

    $svc = Get-Service $ServiceName -ErrorAction SilentlyContinue

    if ($null -eq $svc) {
        Write-Warn "Service $ServiceName introuvable sur ce système."
        return
    }

    if ($svc.Status -ne "Running") {
        Write-Warn "Service $ServiceName est arrêté → démarrage..."
        try {
            Start-Service $ServiceName
            Write-Ok "Service $ServiceName démarré"
        }
        catch {
            Write-Err "Impossible de démarrer le service $ServiceName : $($_.Exception.Message)"
        }
    }
    else {
        Write-Ok "Service $ServiceName OK"
    }
}

function Ensure-Module {
    param([string]$ModuleName)

    if (-not (Get-Module -ListAvailable -Name $ModuleName)) {
        Write-Warn "$ModuleName non présent → installation..."
        try {
            Install-Module $ModuleName -Force -Confirm:$false -Scope AllUsers
        }
        catch {
            Write-Err "Impossible d'installer le module $ModuleName : $($_.Exception.Message)"
            return
        }
    }

    try {
        Import-Module $ModuleName -ErrorAction Stop
        Write-Ok "$ModuleName chargé"
    }
    catch {
        Write-Err "Impossible de charger le module $ModuleName : $($_.Exception.Message)"
    }
}


# ============================================================
# DISM + SFC
# ============================================================

function Repair-WindowsImage {
    Write-Info "`n=== Analyse et réparation de l'image Windows (DISM intelligent) ==="

    $check = DISM /Online /Cleanup-Image /CheckHealth

    if ($check -match "No component store corruption detected") {
        Write-Ok "L'image Windows est saine. Aucune réparation DISM nécessaire."
        return
    }

    if ($check -match "The component store is repairable") {
        Write-Warn "Corruption détectée → réparation nécessaire."
    }

    if ($check -match "The component store is not repairable") {
        Write-Err "L'image Windows est endommagée de manière critique. Tentative de réparation complète..."
    }

    Safe-Run "DISM /ScanHealth" {
        DISM /Online /Cleanup-Image /ScanHealth
    }

    Safe-Run "DISM /RestoreHealth" {
        DISM /Online /Cleanup-Image /RestoreHealth
    }

    Safe-Run "DISM /StartComponentCleanup" {
        DISM /Online /Cleanup-Image /StartComponentCleanup
    }

    Safe-Run "DISM /AnalyzeComponentStore" {
        DISM /Online /Cleanup-Image /AnalyzeComponentStore
    }

    Safe-Run "DISM /ResetBase (réduction WinSxS)" {
        DISM /Online /Cleanup-Image /StartComponentCleanup /ResetBase
    }

    Safe-Run "Analyse SFC" {
        sfc /scannow
    }

    Write-Ok "Réparation DISM + SFC terminée."
}


# ============================================================
# WINGET LIVE + BACKGROUND
# ============================================================

Add-Type -AssemblyName System.Windows.Forms

function Refresh-UI {
    [System.Windows.Forms.Application]::DoEvents() | Out-Null
}

function Set-Progress {
    param([int]$Value)

    if ($global:progress -ne $null) {
        if ($Value -lt 0) { $Value = 0 }
        if ($Value -gt 100) { $Value = 100 }
        $global:progress.Value = $Value
        Refresh-UI
    }
}

function Run-InBackground {
    param([scriptblock]$Action)

    $job = Start-Job -ScriptBlock $Action
    while (-not $job.HasExited) {
        Refresh-UI
        Start-Sleep -Milliseconds 200
    }

    $result = Receive-Job $job
    Remove-Job $job
    return $result
}

function Run-WingetLive {
    param([string]$Args)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "winget.exe"
    $psi.Arguments = $Args
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $proc.Start() | Out-Null

    while (-not $proc.HasExited) {
        $line = $proc.StandardOutput.ReadLine()
        if ($line) {
            Add-LogLine "[WINGET] $line"

            if ($line -match "([0-9]+)%") {
                Set-Progress ([int]$Matches[1])
            }

            if ($line -match "Starting package upgrade: (.*)") {
                Write-Info "Mise à jour : $($Matches[1])"
                Set-Progress 0
            }
        }
        Refresh-UI
    }

    while (-not $proc.StandardOutput.EndOfStream) {
        Add-LogLine "[WINGET] " + $proc.StandardOutput.ReadLine()
    }
}


# ============================================================
# MISES À JOUR
# ============================================================

function Update-All {

    Safe-Run "Mise à jour de Winget" {
        Run-WingetLive "upgrade --id Microsoft.AppInstaller -s msstore --accept-package-agreements --accept-source-agreements"
    }

    Safe-Run "Mise à jour de PowerShell Core" {
        Run-WingetLive "upgrade --id Microsoft.PowerShell --accept-package-agreements --accept-source-agreements"
    }

    Safe-Run "Windows Update" {
        Ensure-Module "PSWindowsUpdate"
        Run-InBackground { Get-WindowsUpdate -AcceptAll -Install -AutoReboot }
    }

    Safe-Run "Microsoft Defender (mises à jour + scan rapide)" {
        Run-InBackground { Update-MpSignature }
        Run-InBackground { Start-MpScan -ScanType QuickScan }
    }

    Safe-Run "Mise à jour Microsoft Store et Apps" {
        Run-WingetLive "upgrade --source msstore --accept-package-agreements --accept-source-agreements"
    }

    Safe-Run "Mise à jour des applications Winget" {
        Run-WingetLive "upgrade --all --accept-package-agreements --accept-source-agreements"
    }

    Safe-Run "Mise à jour des pilotes Windows" {
        Run-WingetLive "upgrade --source windowsdriver --accept-package-agreements --accept-source-agreements"
    }
}


# ============================================================
# DÉPENDANCES
# ============================================================

function Install-Dependencies {
    if (-not (Test-DotNet)) {
        Safe-Run ".NET Runtime et SDK" {
            Run-WingetLive "install Microsoft.DotNet.DesktopRuntime.8 --accept-package-agreements --accept-source-agreements"
            Run-WingetLive "install Microsoft.DotNet.SDK.8 --accept-package-agreements --accept-source-agreements"
        }
    }

    Safe-Run "Visual C++ Redistributables" {
        Run-WingetLive "install Microsoft.VCRedist.2015+.x64 --accept-package-agreements --accept-source-agreements"
        Run-WingetLive "install Microsoft.VCRedist.2015+.x86 --accept-package-agreements --accept-source-agreements"
    }

    Safe-Run "Gestionnaires WinGetUI - Chocolatey / Scoop / Python / Node.js" {
        Run-WingetLive "install Chocolatey.Chocolatey --accept-package-agreements --accept-source-agreements"
        Run-WingetLive "install Scoop.Scoop --accept-package-agreements --accept-source-agreements"
        Run-WingetLive "install Python.Python.3 --accept-package-agreements --accept-source-agreements"
        Run-WingetLive "install OpenJS.NodeJS --accept-package-agreements --accept-source-agreements"
    }

    Safe-Run "WinGetUI" {
        Run-WingetLive "install SomePythonThings.WingetUIStore --accept-package-agreements --accept-source-agreements"
    }
}


# ============================================================
# PILOTES
# ============================================================

function Install-DriverTools {
    Safe-Run "Drivers Cloud" {
        Run-WingetLive "install DriversCloud.DriversCloud --accept-package-agreements --accept-source-agreements"
    }

    Safe-Run "Patch My PC" {
        Run-WingetLive "install PatchMyPC.PatchMyPC --accept-package-agreements --accept-source-agreements"
    }

    $cpu = (Get-WmiObject Win32_Processor).Name
    $gpu = (Get-WmiObject Win32_VideoController | Select-Object -First 1).Name
    $manufacturer = (Get-WmiObject Win32_ComputerSystem).Manufacturer

    if ($cpu -match "Intel") {
        Safe-Run "Intel Driver et Support Assistant" {
            Run-WingetLive "install Intel.IntelDriverAndSupportAssistant --accept-package-agreements --accept-source-agreements"
        }
    }

    if ($cpu -match "AMD") {
        Safe-Run "AMD Software" {
            Run-WingetLive "install AdvancedMicroDevices.AMDSoftware --accept-package-agreements --accept-source-agreements"
        }
    }

    if ($gpu -match "NVIDIA") {
        Safe-Run "NVIDIA GeForce Experience" {
            Run-WingetLive "install Nvidia.GeForceExperience --accept-package-agreements --accept-source-agreements"
        }
    }

    switch -Wildcard ($manufacturer) {
        "*Dell*" {
            Safe-Run "Dell Command Update" {
                Run-WingetLive "install Dell.CommandUpdate --accept-package-agreements --accept-source-agreements"
            }
        }
        "*HP*" {
            Safe-Run "HP Support Assistant" {
                Run-WingetLive "install HP.HPSupportAssistant --accept-package-agreements --accept-source-agreements"
            }
        }
        "*Lenovo*" {
            Safe-Run "Lenovo System Update" {
                Run-WingetLive "install Lenovo.SystemUpdate --accept-package-agreements --accept-source-agreements"
            }
        }
        default {
            Write-Warn "Aucun outil OEM spécifique détecté."
        }
    }
}


# ============================================================
# OPTIMISATIONS ÉNERGIE + GAMING
# ============================================================

function Optimize-PowerAndGaming {

    Write-Info "Réinitialisation des plans d'alimentation..."
    powercfg -restoredefaultschemes

    $balanced = (powercfg -list | Select-String "Equilibré").ToString().Split()[3]

    Write-Info "Activation du plan Ultimate Performance..."
    powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61
    $ultimate = (powercfg -list | Select-String "Ultimate Performance").ToString().Split()[3]
    powercfg -setactive $ultimate

    Write-Info "Configuration du plan Ultimate Performance (secteur)..."
    powercfg -setacvalueindex $ultimate SUB_PROCESSOR PROCTHROTTLEMIN 100
    powercfg -setacvalueindex $ultimate SUB_PROCESSOR PROCTHROTTLEMAX 100
    powercfg -setacvalueindex $ultimate SUB_PROCESSOR PERFINCPOL 2
    powercfg -setacvalueindex $ultimate SUB_PROCESSOR PERFDECPOL 1
    powercfg -setacvalueindex $ultimate SUB_PROCESSOR IDLEDISABLE 1
    powercfg -setacvalueindex $ultimate SUB_PROCESSOR CPMINCORES 100
    powercfg -setacvalueindex $ultimate SUB_PROCESSOR CPMAXCORES 100
    powercfg -setacvalueindex $ultimate SUB_GRAPHICS GPUPOWERLEVEL 0
    powercfg -setacvalueindex $ultimate SUB_PCIEXPRESS ASPM 0
    powercfg -S $ultimate

    Write-Info "Configuration du plan Equilibré (batterie)..."
    powercfg -setactive $balanced
    powercfg -setdcvalueindex $balanced SUB_PROCESSOR PROCTHROTTLEMIN 5
    powercfg -setdcvalueindex $balanced SUB_PROCESSOR PROCTHROTTLEMAX 70
    powercfg -setdcvalueindex $balanced SUB_PROCESSOR IDLEDISABLE 0
    powercfg -setdcvalueindex $balanced SUB_PROCESSOR CPMINCORES 10
    powercfg -setdcvalueindex $balanced SUB_PROCESSOR CPMAXCORES 100
    powercfg -setdcvalueindex $balanced SUB_GRAPHICS GPUPOWERLEVEL 1
    powercfg -setdcvalueindex $balanced SUB_PCIEXPRESS ASPM 1
    powercfg -setactive $ultimate

    Write-Info "Activation Game Mode + HAGS..."
    New-Item -Path "HKCU:\Software\Microsoft\GameBar" -Force | Out-Null
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\GameBar" -Name "AllowAutoGameMode" -Type DWord -Value 1
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\GameBar" -Name "AutoGameModeEnabled" -Type DWord -Value 1

    New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Force | Out-Null
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Name "HwSchMode" -Type DWord -Value 2

    Write-Info "Désactivation du Power Throttling..."
    New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling" -Force | Out-Null
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling" -Name "PowerThrottlingOff" -Type DWord -Value 1

    New-Item -Path "HKCU:\Software\Microsoft\DirectX\UserGpuPreferences" -Force | Out-Null

    Write-Ok "Plans d'alimentation réinitialisés et optimisés."
    Write-Info " - Secteur : Ultimate Performance + CPU/GPU à fond, écos cachées limitées."
    Write-Info " - Batterie : Equilibré, plus soft pour la conso."
    Write-Info " - Game Mode + HAGS activés."
    Write-Info "Redémarre le PC pour que HAGS et certains réglages soient pleinement pris en compte."
}


# ============================================================
# LOGIQUE INTELLIGENTE
# ============================================================

function Run-RepairsIfAllowed {
    if (-not $DoRepair) {
        Write-Warn "Réparations système désactivées par l'utilisateur."
        return
    }

    Repair-WindowsImage
}

function Run-UpdatesIfAllowed {
    if (-not $DoUpdates) {
        Write-Warn "Mises à jour désactivées par l'utilisateur."
        return
    }

    Update-All
}

function Run-DependenciesIfAllowed {
    if (-not $DoDependencies) {
        Write-Warn "Installation des dépendances désactivée."
        return
    }

    Install-Dependencies
}

function Run-DriversIfAllowed {
    if (-not $DoDrivers) {
        Write-Warn "Mise à jour des pilotes désactivée."
        return
    }

    Install-DriverTools
}

function Run-GamingIfAllowed {
    if (-not $DoGaming) {
        Write-Warn "Optimisations gaming désactivées."
        return
    }

    Optimize-PowerAndGaming
}

function Run-FullMaintenance {
    if ($IsBusy) { Write-Warn "Une opération est déjà en cours."; return }

    # Verrouillage GUI AVANT toute action
    Set-Busy $true
    $global:CancelRequested = $false

    Try-Action {
        Write-Info "`n=== DÉMARRAGE DE LA MAINTENANCE COMPLÈTE ==="

        Set-Progress 5
        Test-PowerShellVersion
        if ($CancelRequested) { throw "Annulé par l'utilisateur." }

        Set-Progress 10
        Show-SystemInfo
        if ($CancelRequested) { throw "Annulé par l'utilisateur." }

        Set-Progress 20
        Test-Network
        if ($CancelRequested) { throw "Annulé par l'utilisateur." }

        Set-Progress 30
        Test-Winget
        Test-WingetVersion
        if ($CancelRequested) { throw "Annulé par l'utilisateur." }

        Set-Progress 45
        Run-RepairsIfAllowed
        if ($CancelRequested) { throw "Annulé par l'utilisateur." }

        Set-Progress 65
        Run-UpdatesIfAllowed
        if ($CancelRequested) { throw "Annulé par l'utilisateur." }

        Set-Progress 80
        Run-DependenciesIfAllowed
        if ($CancelRequested) { throw "Annulé par l'utilisateur." }

        Set-Progress 90
        Run-DriversIfAllowed
        if ($CancelRequested) { throw "Annulé par l'utilisateur." }

        Set-Progress 100
        Run-GamingIfAllowed

        Write-Ok "`n=== MAINTENANCE COMPLÈTE TERMINÉE ==="
    }
    catch {
        Write-Warn "Maintenance interrompue : $($_.Exception.Message)"
    }

    # Déverrouillage GUI
    Set-Busy $false
}


# ============================================================
# INTERFACE GRAPHIQUE WPF
# ============================================================

Add-Type -AssemblyName PresentationFramework

$reader = New-Object System.Xml.XmlNodeReader ([xml]$Xaml)
$global:Window = [Windows.Markup.XamlReader]::Load($reader)

# Récupération des contrôles
$chkSilent   = $Window.FindName("chkSilent")
$chkAuto     = $Window.FindName("chkAuto")
$chkRepair   = $Window.FindName("chkRepair")
$chkUpdates  = $Window.FindName("chkUpdates")
$chkDeps     = $Window.FindName("chkDeps")
$chkDrivers  = $Window.FindName("chkDrivers")
$chkGaming   = $Window.FindName("chkGaming")

$btnInfo     = $Window.FindName("btnInfo")
$btnNetwork  = $Window.FindName("btnNetwork")
$btnWinget   = $Window.FindName("btnWinget")
$btnRepair   = $Window.FindName("btnRepair")
$btnUpdates  = $Window.FindName("btnUpdates")
$btnDeps     = $Window.FindName("btnDeps")
$btnDrivers  = $Window.FindName("btnDrivers")
$btnGaming   = $Window.FindName("btnGaming")
$btnFull     = $Window.FindName("btnFull")
$btnCancel   = $Window.FindName("btnCancel")
$btnOpenLog  = $Window.FindName("btnOpenLog")
$btnQuit     = $Window.FindName("btnQuit")

$txtLog      = $Window.FindName("txtLog")
$global:progress = $Window.FindName("progress")


# ============================================================
# REDIRECTION DES MESSAGES VERS LA TEXTBOX
# ============================================================

function Add-LogLine {
    param([string]$Text)

    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "[$timestamp] $Text"

    if ($txtLog -ne $null) {
        $txtLog.AppendText("$line`r`n")
        $txtLog.ScrollToEnd()
    }

    Add-Content -Path $global:LogPath -Value $line
}

Remove-Item function:Write-Info -ErrorAction SilentlyContinue
Remove-Item function:Write-Ok   -ErrorAction SilentlyContinue
Remove-Item function:Write-Warn -ErrorAction SilentlyContinue
Remove-Item function:Write-Err  -ErrorAction SilentlyContinue

function Write-Info { param($m) Add-LogLine "[INFO]  $m" }
function Write-Ok   { param($m) Add-LogLine "[OK]    $m" }
function Write-Warn { param($m) Add-LogLine "[WARN]  $m" }
function Write-Err  { param($m) Add-LogLine "[ERROR] $m" }


# ============================================================
# SYNCHRO OPTIONS GUI → VARIABLES + PREFS
# ============================================================

function Save-Prefs {
    try {
        $dir = Split-Path $PrefsPath
        if (-not (Test-Path $dir)) {
            New-Item -Path $dir -ItemType Directory -Force | Out-Null
        }

        $prefs = @{
            Silent       = $DoSilent
            Auto         = $DoAuto
            Repair       = $DoRepair
            Updates      = $DoUpdates
            Dependencies = $DoDependencies
            Drivers      = $DoDrivers
            Gaming       = $DoGaming
        }
        $prefs | ConvertTo-Json | Set-Content $PrefsPath -Encoding UTF8
    }
    catch {
        Write-Warn "Impossible d'enregistrer les préférences : $($_.Exception.Message)"
    }
}

function Load-Prefs {
    try {
        if (Test-Path $PrefsPath) {
            $prefs = Get-Content $PrefsPath -Encoding UTF8 | ConvertFrom-Json
            $chkSilent.IsChecked   = $prefs.Silent
            $chkAuto.IsChecked     = $prefs.Auto
            $chkRepair.IsChecked   = $prefs.Repair
            $chkUpdates.IsChecked  = $prefs.Updates
            $chkDeps.IsChecked     = $prefs.Dependencies
            $chkDrivers.IsChecked  = $prefs.Drivers
            $chkGaming.IsChecked   = $prefs.Gaming
        }
    }
    catch {
        Write-Warn "Impossible de charger les préférences : $($_.Exception.Message)"
    }
}

function Update-PreferencesFromGUI {
    $global:DoSilent       = $chkSilent.IsChecked
    $global:DoAuto         = $chkAuto.IsChecked
    $global:DoRepair       = $chkRepair.IsChecked
    $global:DoUpdates      = $chkUpdates.IsChecked
    $global:DoDependencies = $chkDeps.IsChecked
    $global:DoDrivers      = $chkDrivers.IsChecked
    $global:DoGaming       = $chkGaming.IsChecked

    Save-Prefs
    Write-Info "Préférences mises à jour depuis la GUI."
}


# ============================================================
# HANDLERS BOUTONS (VERSION v2.3 CORRIGÉE)
# ============================================================

$btnInfo.Add_Click({
    if ($IsBusy) { Write-Warn "Une opération est déjà en cours."; return }

    Set-Busy $true
    Update-PreferencesFromGUI
    Try-Action { Safe-Run "Informations système" { Show-SystemInfo } }
    Set-Busy $false
})

$btnNetwork.Add_Click({
    if ($IsBusy) { Write-Warn "Une opération est déjà en cours."; return }

    Set-Busy $true
    Update-PreferencesFromGUI
    Try-Action { Safe-Run "Test réseau" { Test-Network } }
    Set-Busy $false
})

$btnWinget.Add_Click({
    if ($IsBusy) { Write-Warn "Une opération est déjà en cours."; return }

    Set-Busy $true
    Update-PreferencesFromGUI
    Try-Action { 
        Safe-Run "Test Winget" { Test-Winget | Out-Null }
        Test-WingetVersion
    }
    Set-Busy $false
})

$btnRepair.Add_Click({
    if ($IsBusy) { Write-Warn "Une opération est déjà en cours."; return }

    Set-Busy $true
    Update-PreferencesFromGUI
    Try-Action { Run-RepairsIfAllowed }
    Set-Busy $false
})

$btnUpdates.Add_Click({
    if ($IsBusy) { Write-Warn "Une opération est déjà en cours."; return }

    Set-Busy $true
    Update-PreferencesFromGUI
    Try-Action { Run-UpdatesIfAllowed }
    Set-Busy $false
})

$btnDeps.Add_Click({
    if ($IsBusy) { Write-Warn "Une opération est déjà en cours."; return }

    Set-Busy $true
    Update-PreferencesFromGUI
    Try-Action { Run-DependenciesIfAllowed }
    Set-Busy $false
})

$btnDrivers.Add_Click({
    if ($IsBusy) { Write-Warn "Une opération est déjà en cours."; return }

    Set-Busy $true
    Update-PreferencesFromGUI
    Try-Action { Run-DriversIfAllowed }
    Set-Busy $false
})

$btnGaming.Add_Click({
    if ($IsBusy) { Write-Warn "Une opération est déjà en cours."; return }

    Set-Busy $true
    Update-PreferencesFromGUI
    Try-Action { Run-GamingIfAllowed }
    Set-Busy $false
})

# BOUTON MAINTENANCE COMPLÈTE
$btnFull.Add_Click({
    if ($IsBusy) { Write-Warn "Une opération est déjà en cours."; return }


    Update-PreferencesFromGUI
    Run-FullMaintenance
	
})

$btnCancel.Add_Click({
    if (-not $IsBusy) {
        Write-Warn "Aucune opération en cours à annuler."
        return
    }

    $global:CancelRequested = $true
    Write-Warn "Annulation demandée. L'opération en cours va s'arrêter dès que possible."
})

$btnOpenLog.Add_Click({
    if (Test-Path $global:LogPath) {
        Invoke-Item $global:LogPath
    }
    else {
        Write-Warn "Aucun fichier de log trouvé."
    }
})

$btnQuit.Add_Click({
    $Window.Close()
})


# Chargement des préférences au démarrage
Load-Prefs
Write-Info "Script lancé. Interface graphique en cours d'ouverture..."

# Affichage de la fenêtre
$Window.ShowDialog() | Out-Null
Write-Info "Interface fermée. Fin du script."


Stop-Transcript | Out-Null
