<#
.SYNOPSIS
    Kiosk Cleanup Remediation Script
.DESCRIPTION
    Removes unwanted AppX packages (provisioned and per-user), disables unwanted services,
    uninstalls Win32 products identified via the registry, and uninstalls OneDrive and removes
    its user data folders. Intended to run after the corresponding detection script returns exit 1.
.AUTHOR
    Daniel Petri
.NOTES
    Runs as SYSTEM via Intune Remediations. No module dependencies.
    Version: 1.1.0
#>

#region Variables
$UnwantedApps = @(
    'Microsoft.XboxGameCallableUI'
    'Microsoft.XboxSpeechToTextOverlay'
    'Microsoft.Xbox.TCUI'
    'Microsoft.XboxIdentityProvider'
    'Microsoft.XboxGamingOverlay'
    'MSTeams'
    'Microsoft.ZuneMusic'
    'Microsoft.Copilot'
    'Microsoft.MicrosoftSolitaireCollection'
    'Microsoft.BingNews'
    'Microsoft.OutlookForWindows'
    'Microsoft.PowerAutomateDesktop'
    'Microsoft.WindowsFeedbackHub'
    'Microsoft.Edge.GameAssist'
    'MicrosoftCorporationII.QuickAssist'
    'Microsoft.MicrosoftStickyNotes'
    'Microsoft.WindowsSoundRecorder'
    'Clipchamp.Clipchamp'
    'Microsoft.Todos'
    'Microsoft.Paint'
    'Microsoft.Windows.DevHome'
    'Microsoft.Windows.CallingShellApp'
    'Microsoft.WindowsMaps'
    'Microsoft.BingWeather'
    'Microsoft.ZuneVideo'
    'Microsoft.MicrosoftOfficeHub'
    'Microsoft.BingSearch'
)

$UnwantedServices = @(
    'XblAuthManager'
    'XblGameSave'
    'XboxGipSvc'
    'XboxNetApiSvc'
    'RetailDemo'
    'MapsBroker'
    'WMPNetworkSvc'
    'SharedAccess'
    'PhoneSvc'
    'Workfolderssvc'
)

$UnwantedWin32Products = @(
    'Teams Meeting Add-in'
)

$deprovisionedCount = 0
$removedCount = 0
$serviceCount = 0
$win32Count = 0
$oneDriveFolderCount = 0
$oneDriveUninstalled = $false
#endregion

#region Build Regex Patterns
$AppPattern = ($UnwantedApps | ForEach-Object { [regex]::Escape($_) }) -join '|'
$ServicePattern = ($UnwantedServices | ForEach-Object { [regex]::Escape($_) }) -join '|'
$Win32ProductPattern = ($UnwantedWin32Products | ForEach-Object { [regex]::Escape($_) }) -join '|'
#endregion

#region Remove Unwanted AppX Packages
# Deprovision AppX (for new users)
Get-AppxProvisionedPackage -Online |
Where-Object { $_.DisplayName -match $AppPattern } |
ForEach-Object {
    Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue | Out-Null
    $deprovisionedCount++
}

# Remove AppX for all existing users (skip SystemApps)
Get-AppxPackage -AllUsers |
Where-Object {
    $_.Name -match $AppPattern -and
    $_.InstallLocation -notlike 'C:\Windows\SystemApps*'
} |
ForEach-Object {
    Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction SilentlyContinue | Out-Null
    $removedCount++
}
#endregion

#region Disable Unwanted Services
Get-Service |
Where-Object {
    $_.DisplayName -match $ServicePattern -or
    $_.Name -match $ServicePattern
} |
ForEach-Object {
    if ($_.Status -ne 'Stopped') {
        Stop-Service -Name $_.Name -Force -ErrorAction SilentlyContinue
    }
    Set-Service -Name $_.Name -StartupType Disabled -ErrorAction SilentlyContinue
    $serviceCount++
}
#endregion

#region Remove Unwanted Win32 Products
$registryPaths = @(
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$installedProducts = Get-ItemProperty $registryPaths -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName }

$installedProducts | Where-Object { $_.DisplayName -match $Win32ProductPattern } | ForEach-Object {
    $uninstallCmd = $_.UninstallString
    if ($uninstallCmd) {
        if ($uninstallCmd -match 'msiexec') {
            $productCode = [regex]::Match($uninstallCmd, '\{[0-9A-Fa-f-]+\}').Value
            if ($productCode) {
                Start-Process 'msiexec.exe' -ArgumentList "/x $productCode /qn /norestart" -Wait -NoNewWindow
            }
        } else {
            Start-Process cmd.exe -ArgumentList "/c `"$uninstallCmd`" /S" -Wait -NoNewWindow
        }
        $win32Count++
    }
}
#endregion

#region Uninstall OneDrive and remove user data
# Kill any running OneDrive processes before uninstalling
Get-Process -Name 'OneDrive' -ErrorAction SilentlyContinue | Stop-Process -Force

# Locate OneDriveSetup.exe in common installation paths
$oneDriveSetupCandidates = @(
    "$env:SystemRoot\SysWOW64\OneDriveSetup.exe",
    "$env:SystemRoot\System32\OneDriveSetup.exe",
    "$env:ProgramFiles\Microsoft OneDrive\OneDriveSetup.exe",
    "${env:ProgramFiles(x86)}\Microsoft OneDrive\OneDriveSetup.exe"
)

$oneDriveSetup = $oneDriveSetupCandidates |
Where-Object { Test-Path $_ } |
Select-Object -First 1

if ($oneDriveSetup) {
    Start-Process $oneDriveSetup -ArgumentList '/uninstall' -Wait -NoNewWindow
    $oneDriveUninstalled = $true
}

# Remove OneDrive folders from user profiles (excluding system profiles)
$profileRoot = 'C:\Users'
Get-ChildItem $profileRoot -Directory |
Where-Object { $_.Name -notin @('Public', 'Default', 'Default User', 'All Users') } |
ForEach-Object {
    $oneDriveDir = Join-Path $_.FullName 'OneDrive'
    if (Test-Path $oneDriveDir) {
        Remove-Item $oneDriveDir -Recurse -Force -ErrorAction SilentlyContinue
        $oneDriveFolderCount++
    }
}
#endregion

#region Output Summary
$parts = @()
if ($deprovisionedCount) { $parts += "$deprovisionedCount deprovisioned" }
if ($removedCount) { $parts += "$removedCount removed" }
if ($serviceCount) { $parts += "$serviceCount services disabled" }
if ($win32Count) { $parts += "$win32Count Win32 uninstalled" }
if ($oneDriveUninstalled) { $parts += 'OneDrive uninstalled' }
if ($oneDriveFolderCount) { $parts += "$oneDriveFolderCount OneDrive folders removed" }

if ($parts.Count -gt 0) {
    Write-Host "Remediated: $($parts -join ', ')"
} else {
    Write-Host 'Nothing to remediate'
}
#endregion

Exit 0
