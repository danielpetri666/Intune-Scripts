#Requires -Module Microsoft.Graph.Authentication
<#
.SYNOPSIS
    Updates display names and group tags on Windows Autopilot device identities.
.DESCRIPTION
    Connects to Microsoft Graph and updates Autopilot device properties (display name
    and/or group tag) via the updateDeviceProperties action. Supports three input modes:

    - CSV:         A CSV file with a SerialNumber column and optional DisplayName/GroupTag columns.
    - Single:      A single device identified by serial number.
    - Interactive:  Out-GridView selection with a shared group tag and/or display name.

    With -ExportCsv, exports current Autopilot device state to CSV without making changes.
    Use this to generate a template CSV for the -CsvPath parameter.

    Supports -WhatIf for dry runs without making any changes.
.AUTHOR
    Daniel Petri
.PARAMETER CsvPath
    Path to a CSV file with a SerialNumber column. Optional DisplayName and GroupTag
    columns override the corresponding parameters per row.
    Cannot be used together with -SerialNumber.
.PARAMETER SerialNumber
    A single device serial number to update. Cannot be used together with -CsvPath.
.PARAMETER DisplayName
    The display name to set. In Single and Interactive modes, applied to all targeted
    devices. Overridden per row if the CSV has a DisplayName column.
.PARAMETER GroupTag
    The group tag to set. In Single and Interactive modes, applied to all targeted
    devices. Overridden per row if the CSV has a GroupTag column.
.PARAMETER ExportCsv
    Export all Autopilot device identities to CSV. If used alone (no other update
    parameters), no updates are made. The exported CSV can be edited and fed back
    with -CsvPath.
.EXAMPLE
    .\Set-AutopilotDeviceProperties.ps1
    Lists all Autopilot devices with serial number, display name, group tag, model, and manufacturer.
.EXAMPLE
    .\Set-AutopilotDeviceProperties.ps1 -ExportCsv "C:\Data\AutopilotDevices.csv"
    Exports all Autopilot devices to CSV without making changes.
.EXAMPLE
    .\Set-AutopilotDeviceProperties.ps1 -CsvPath "C:\Data\Devices.csv"
    Updates devices from CSV. Each row needs SerialNumber; DisplayName and GroupTag
    columns are used per row if present.
.EXAMPLE
    .\Set-AutopilotDeviceProperties.ps1 -SerialNumber "1234-5678-9012" -GroupTag "Kiosk"
    Sets the group tag on a single device.
.EXAMPLE
    .\Set-AutopilotDeviceProperties.ps1 -SerialNumber "1234-5678-9012" -DisplayName "KIOSK-LOBBY-01" -GroupTag "Kiosk"
    Sets both display name and group tag on a single device.
.EXAMPLE
    .\Set-AutopilotDeviceProperties.ps1 -GroupTag "Kiosk"
    Opens Out-GridView for device selection, then sets the group tag on all selected devices.
.EXAMPLE
    .\Set-AutopilotDeviceProperties.ps1 -CsvPath "C:\Data\Devices.csv" -WhatIf
    Shows what would be changed without making any changes.
.NOTES
    Requires: Microsoft.Graph.Authentication
    Permissions: DeviceManagementServiceConfig.ReadWrite.All (delegated)
    Version: 2.0.0
#>

[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Interactive')]
param(
    [Parameter(Mandatory, ParameterSetName = 'CSV')]
    [string]$CsvPath,

    [Parameter(Mandatory, ParameterSetName = 'Single')]
    [string]$SerialNumber,

    [string]$DisplayName,

    [string]$GroupTag,

    [string]$ExportCsv
)

#region Connect to Microsoft Graph
Connect-MgGraph -Scopes 'DeviceManagementServiceConfig.ReadWrite.All' -ErrorAction Stop | Out-Null
$ctx = Get-MgContext
Write-Host "Connected to Microsoft Graph | $($ctx.Account) | TenantId: $($ctx.TenantId)" -ForegroundColor Green
#endregion

#region Graph POST helper with retry
function Invoke-GraphPost {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter(Mandatory)]
        [hashtable]$Body
    )

    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            Invoke-MgGraphRequest -Method POST -Uri $Uri -Body $Body | Out-Null
            return
        }
        catch {
            $statusCode = $null
            if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode }

            if ($statusCode -eq 429) {
                $retryHeader = try { $_.Exception.Response.Headers['Retry-After'] } catch { $null }
                $wait = if ($retryHeader) { [int]$retryHeader } else { [Math]::Min(5 * [Math]::Pow(2, $attempt - 1), 60) }
                Write-Host "  Throttled (attempt $attempt/5), waiting ${wait}s..." -ForegroundColor DarkYellow
                Start-Sleep -Seconds $wait
                continue
            }

            throw
        }
    }

    throw "Failed after 5 retries: $Uri"
}
#endregion

#region Fetch all Autopilot device identities
Write-Host 'Fetching Autopilot device identities...' -ForegroundColor Cyan

$uri = 'https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities'
$rawDevices = [System.Collections.Generic.List[object]]::new()

$response = Invoke-MgGraphRequest -Method GET -Uri $uri
$rawDevices.AddRange(@($response['value']))
$next = $response['@odata.nextLink']
while ($next) {
    $page = Invoke-MgGraphRequest -Method GET -Uri $next
    $rawDevices.AddRange(@($page['value']))
    $next = $page['@odata.nextLink']
}

$allDevices = @($rawDevices | ForEach-Object {
    [PSCustomObject]@{
        id           = $_['id']
        serialNumber = $_['serialNumber']
        displayName  = $_['displayName']
        groupTag     = $_['groupTag']
        model        = $_['model']
        manufacturer = $_['manufacturer']
    }
})

if ($allDevices.Count -eq 0) { throw 'No Autopilot device identities found.' }
Write-Host "  Devices in tenant: $($allDevices.Count)"
#endregion

#region List-only mode (no parameters) or export
$listOnly = $PSCmdlet.ParameterSetName -eq 'Interactive' -and -not $DisplayName -and -not $GroupTag -and -not $ExportCsv

if ($listOnly -or $ExportCsv) {
    $report = $allDevices | ForEach-Object {
        [PSCustomObject]@{
            SerialNumber = $_.serialNumber
            DisplayName  = $_.displayName
            GroupTag     = $_.groupTag
            Model        = $_.model
            Manufacturer = $_.manufacturer
        }
    }

    if ($ExportCsv) {
        $report | Export-Csv -Path $ExportCsv -NoTypeInformation -Encoding UTF8
        Write-Host "Exported $($report.Count) devices to: $ExportCsv" -ForegroundColor Green
    }

    if ($listOnly -or ($ExportCsv -and -not $DisplayName -and -not $GroupTag)) {
        $report | Format-Table -AutoSize
        return
    }
}
#endregion

#region Build device list to update
$devicesToUpdate = [System.Collections.Generic.List[object]]::new()
$perRowDisplayName = $false
$perRowGroupTag = $false

switch ($PSCmdlet.ParameterSetName) {
    'CSV' {
        if (-not (Test-Path $CsvPath)) { throw "CSV not found: $CsvPath" }
        $csv = Import-Csv -Path $CsvPath
        if (-not $csv -or -not $csv.SerialNumber) { throw "CSV must contain a 'SerialNumber' column with values." }

        $perRowDisplayName = ($csv | Get-Member -Name DisplayName -MemberType NoteProperty) -ne $null
        $perRowGroupTag = ($csv | Get-Member -Name GroupTag -MemberType NoteProperty) -ne $null
        Write-Host "CSV rows: $($csv.Count) | Per-row DisplayName: $perRowDisplayName | Per-row GroupTag: $perRowGroupTag" -ForegroundColor Cyan

        foreach ($row in $csv) {
            $serial = [string]$row.SerialNumber
            if ([string]::IsNullOrWhiteSpace($serial)) { continue }

            $device = $allDevices | Where-Object { $_.serialNumber -eq $serial }
            if (-not $device) {
                Write-Warning "Device not found: $serial"
                continue
            }

            $newDN = if ($perRowDisplayName -and $row.DisplayName) { [string]$row.DisplayName } elseif ($DisplayName) { $DisplayName } else { $null }
            $newGT = if ($perRowGroupTag -and $row.GroupTag) { [string]$row.GroupTag } elseif ($GroupTag) { $GroupTag } else { $null }

            if (-not $newDN -and -not $newGT) {
                Write-Warning "No DisplayName or GroupTag to set for: $serial"
                continue
            }

            [void]$devicesToUpdate.Add(@{
                Device      = $device
                DisplayName = $newDN
                GroupTag    = $newGT
            })
        }
    }
    'Single' {
        if (-not $DisplayName -and -not $GroupTag) { throw 'Specify at least -DisplayName or -GroupTag.' }

        $trimmed = $SerialNumber.Trim()
        $device = $allDevices | Where-Object {
            $_.serialNumber -ieq $trimmed -or $_.id -ieq $trimmed
        }
        if (-not $device) {
            Write-Warning "Device not found: '$trimmed'"
            Write-Warning 'Available devices:'
            $allDevices | ForEach-Object {
                Write-Warning "  serial='$($_.serialNumber)' id=$($_.id) displayName='$($_.displayName)' groupTag='$($_.groupTag)'"
            }
            throw "No matching device. Use the serial number or Autopilot device ID shown above."
        }

        Write-Host "Found device: $($device.serialNumber) | current displayName='$($device.displayName)' groupTag='$($device.groupTag)'" -ForegroundColor Cyan

        [void]$devicesToUpdate.Add(@{
            Device      = $device
            DisplayName = $DisplayName
            GroupTag    = $GroupTag
        })
    }
    'Interactive' {

        $selected = $allDevices | ForEach-Object {
            [PSCustomObject]@{
                SerialNumber = $_.serialNumber
                DisplayName  = $_.displayName
                GroupTag     = $_.groupTag
                Model        = $_.model
                Manufacturer = $_.manufacturer
                Id           = $_.id
            }
        } | Out-GridView -Title 'Select Autopilot devices to update' -PassThru

        if (-not $selected) {
            Write-Host 'No devices selected. Exiting.' -ForegroundColor Yellow
            return
        }

        foreach ($sel in $selected) {
            $device = $allDevices | Where-Object { $_.id -eq $sel.Id }
            [void]$devicesToUpdate.Add(@{
                Device      = $device
                DisplayName = $DisplayName
                GroupTag    = $GroupTag
            })
        }

        Write-Host "Selected $($devicesToUpdate.Count) devices." -ForegroundColor Cyan
    }
}

if ($devicesToUpdate.Count -eq 0) {
    Write-Host 'No devices to update.' -ForegroundColor Yellow
    return
}
#endregion

#region Update device properties
$stats = [ordered]@{
    Total    = 0
    Updated  = 0
    NoChange = 0
    Skipped  = 0
    Errors   = 0
}

foreach ($entry in $devicesToUpdate) {
    $stats.Total++
    $device = $entry.Device
    $id = $device.id
    $serial = $device.serialNumber

    $body = @{}
    $changes = @()

    if ($entry.DisplayName) {
        if ($entry.DisplayName -eq $device.displayName) {
            Write-Host "  DisplayName already set: $serial -> '$($entry.DisplayName)'" -ForegroundColor Yellow
        }
        else {
            $body['displayName'] = $entry.DisplayName
            $changes += "displayName='$($entry.DisplayName)'"
        }
    }

    if ($entry.GroupTag) {
        if ($entry.GroupTag -eq $device.groupTag) {
            Write-Host "  GroupTag already set: $serial -> '$($entry.GroupTag)'" -ForegroundColor Yellow
        }
        else {
            $body['groupTag'] = $entry.GroupTag
            $changes += "groupTag='$($entry.GroupTag)'"
        }
    }

    if ($body.Count -eq 0) {
        $stats.NoChange++
        continue
    }

    $description = "$serial | $($changes -join ', ')"

    if ($PSCmdlet.ShouldProcess($description, 'Update Autopilot device properties')) {
        try {
            Invoke-GraphPost `
                -Uri "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities/$id/updateDeviceProperties" `
                -Body $body
            Write-Host "Updated: $description" -ForegroundColor Green
            $stats.Updated++
        }
        catch {
            Write-Error "Failed: $description | $($_.Exception.Message)"
            $stats.Errors++
        }
    }
    else {
        $stats.Skipped++
    }
}
#endregion

#region Summary
Write-Host "`n=== Summary ===" -ForegroundColor Cyan
$stats.GetEnumerator() | ForEach-Object { '{0,-10} {1}' -f $_.Key, $_.Value } | Write-Host
#endregion
