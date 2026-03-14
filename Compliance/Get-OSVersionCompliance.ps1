#Requires -Module Microsoft.Graph.Authentication
#Requires -Module Microsoft.Graph.DeviceManagement
<#
.SYNOPSIS
    Reports OS version distribution across all Intune-managed devices.
.DESCRIPTION
    Connects to Microsoft Graph and retrieves all managed devices from Intune.
    Groups devices by platform (Windows, iOS/iPadOS, Android, macOS) and OS version,
    showing how many devices are on each version.

    Use this before raising compliance policy OS version baselines to see the current
    version landscape across your fleet. The output shows you exactly where your devices
    are -- so you can decide where to draw the line without guessing.
.AUTHOR
    Daniel Petri
.EXAMPLE
    .\Get-OSVersionCompliance.ps1
    Shows OS version distribution for all platforms.
.EXAMPLE
    .\Get-OSVersionCompliance.ps1 -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    Shows OS version distribution for a specific tenant.
.EXAMPLE
    .\Get-OSVersionCompliance.ps1 -ExportCsv "C:\Temp\OSVersionReport.csv"
    Shows the distribution and exports the full breakdown to CSV.
.NOTES
    Requires: Microsoft.Graph.Authentication, Microsoft.Graph.DeviceManagement
    Permissions required: DeviceManagementManagedDevices.Read.All (delegated)
    Version: 1.0.0
#>

[CmdletBinding()]
param(
    [string]$TenantId,

    [string]$ExportCsv
)

#region Connect to Microsoft Graph
$connectParams = @{
    Scopes = @('DeviceManagementManagedDevices.Read.All')
}
if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
    $connectParams['TenantId'] = $TenantId
}
Connect-MgGraph @connectParams -ErrorAction Stop | Out-Null
#endregion

#region Retrieve devices
Write-Host 'Retrieving managed devices from Intune...' -ForegroundColor Cyan
$devices = Get-MgDeviceManagementManagedDevice -All `
    -Property Id, DeviceName, OperatingSystem, OsVersion, UserPrincipalName

if (-not $devices -or $devices.Count -eq 0) {
    Write-Warning 'No managed devices found.'
    return
}
Write-Host "Total managed devices: $($devices.Count)" -ForegroundColor Cyan
#endregion

#region Build platform map
$platformMap = @{
    'Windows'  = 'Windows'
    'iOS'      = 'iOS/iPadOS'
    'iPadOS'   = 'iOS/iPadOS'
    'Android'  = 'Android'
    'macOS'    = 'macOS'
}
#endregion

#region Helper function
function Normalize-VersionString {
    param([string]$Version)
    if (-not $Version) { return '(unknown)' }
    $v = $Version.Trim()
    if (-not $v) { return '(unknown)' }
    # Pad single numbers like "16" to "16.0" so they group with "16.0"
    if ($v -notmatch '\.') { $v = "$v.0" }
    return $v
}
#endregion

#region Build version distribution
$report = @()

foreach ($device in $devices) {
    $platformName = $platformMap[$device.OperatingSystem]
    if (-not $platformName) { continue }

    $report += [PSCustomObject]@{
        Platform          = $platformName
        OsVersion         = Normalize-VersionString $device.OsVersion
        DeviceName        = $device.DeviceName
        UserPrincipalName = $device.UserPrincipalName
    }
}
#endregion

#region Output per platform
$platformGroups = $report | Group-Object Platform | Sort-Object Name

foreach ($platformGroup in $platformGroups) {
    $platform = $platformGroup.Name
    $platformDevices = $platformGroup.Group
    $total = $platformDevices.Count

    Write-Host ''
    Write-Host "$platform -- $total device(s)" -ForegroundColor Cyan
    Write-Host ('-' * ($platform.Length + 20)) -ForegroundColor Cyan

    $versionGroups = $platformDevices |
        Group-Object OsVersion |
        Sort-Object {
            if ($_.Name -eq '(unknown)') { return [version]'0.0' }
            try { [version]$_.Name } catch { [version]'0.0' }
        } -Descending

    $versionTable = foreach ($vg in $versionGroups) {
        $pct = [math]::Round(($vg.Count / $total) * 100, 1)
        [PSCustomObject]@{
            Version  = $vg.Name
            Devices  = $vg.Count
            Pct      = "$pct%"
        }
    }

    $versionTable | Format-Table -AutoSize
}
#endregion

#region Export
if ($ExportCsv) {
    $exportData = foreach ($platformGroup in $platformGroups) {
        $platform = $platformGroup.Name
        $platformDevices = $platformGroup.Group
        $total = $platformDevices.Count

        $platformDevices |
            Group-Object OsVersion |
            Sort-Object {
                if ($_.Name -eq '(unknown)') { return [version]'0.0' }
                try { [version]$_.Name } catch { [version]'0.0' }
            } -Descending |
            ForEach-Object {
                [PSCustomObject]@{
                    Platform = $platform
                    OsVersion = $_.Name
                    DeviceCount = $_.Count
                    PctOfPlatform = "$([math]::Round(($_.Count / $total) * 100, 1))%"
                }
            }
    }
    $exportData | Export-Csv -Path $ExportCsv -NoTypeInformation -Encoding UTF8
    Write-Host ''
    Write-Host "Report exported to: $ExportCsv" -ForegroundColor Green
}
#endregion
