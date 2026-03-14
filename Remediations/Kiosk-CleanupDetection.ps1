<#
.SYNOPSIS
    Kiosk Cleanup Detection Script
.DESCRIPTION
    Detects unwanted AppX packages (provisioned and per-user), services that are not stopped
    or not disabled, Win32 products installed via the registry, and OneDrive user data folders.
    Returns exit code 1 if any unwanted items are found, or exit code 0 if the device is clean.
    Uses registry-based startup type check for reliable detection across all PowerShell versions.
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

$provisionedCount = 0
$installedCount = 0
$serviceCount = 0
$win32Count = 0
$oneDriveCount = 0
#endregion

#region Build Regex Patterns
$AppPattern = ($UnwantedApps | ForEach-Object { [regex]::Escape($_) }) -join '|'
$ServicePattern = ($UnwantedServices | ForEach-Object { [regex]::Escape($_) }) -join '|'
$Win32ProductPattern = ($UnwantedWin32Products | ForEach-Object { [regex]::Escape($_) }) -join '|'
#endregion

#region Detect Unwanted AppX Packages
# Detect AppX for all new users (provisioned packages)
Get-AppxProvisionedPackage -Online |
Where-Object { $_.DisplayName -match $AppPattern } |
ForEach-Object { $provisionedCount++ }

# Detect AppX for all existing users (skip SystemApps)
Get-AppxPackage -AllUsers |
Where-Object {
    $_.Name -match $AppPattern -and
    $_.InstallLocation -notlike 'C:\Windows\SystemApps*'
} |
ForEach-Object { $installedCount++ }
#endregion

#region Detect Unwanted Services
# Use registry for startup type -- Get-Service StartupType is unreliable on PowerShell 5.1
Get-Service |
Where-Object {
    $_.DisplayName -match $ServicePattern -or
    $_.Name -match $ServicePattern
} |
ForEach-Object {
    $regStart = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$($_.Name)" -ErrorAction SilentlyContinue).Start
    # Registry Start values: 2=Auto, 3=Manual, 4=Disabled
    if ($_.Status -ne 'Stopped' -or $regStart -ne 4) {
        $serviceCount++
    }
}
#endregion

#region Detect Unwanted Win32 Products
$registryPaths = @(
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$installedProducts = Get-ItemProperty $registryPaths -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName }

$installedProducts |
Where-Object { $_.DisplayName -match $Win32ProductPattern } |
ForEach-Object { $win32Count++ }
#endregion

#region Detect OneDrive
$profileRoot = 'C:\Users'
Get-ChildItem $profileRoot -Directory |
Where-Object { $_.Name -notin @('Public', 'Default', 'Default User', 'All Users') } |
ForEach-Object {
    $oneDriveDir = Join-Path $_.FullName 'OneDrive'
    if (Test-Path $oneDriveDir) {
        $oneDriveCount++
    }
}
#endregion

#region Output Detection Result
$totalCount = $provisionedCount + $installedCount + $serviceCount + $win32Count + $oneDriveCount

if ($totalCount -eq 0) {
    Write-Host 'Kiosk is clean'
    Exit 0
}
else {
    $parts = @()
    if ($provisionedCount) { $parts += "$provisionedCount provisioned" }
    if ($installedCount) { $parts += "$installedCount installed" }
    if ($serviceCount) { $parts += "$serviceCount services" }
    if ($win32Count) { $parts += "$win32Count Win32" }
    if ($oneDriveCount) { $parts += "$oneDriveCount OneDrive" }
    Write-Host "Found $totalCount unwanted items: $($parts -join ', ')"
    Exit 1
}
#endregion
