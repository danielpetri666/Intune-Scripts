#Requires -Version 7.0
#Requires -Module Microsoft.Graph.Authentication
<#
.SYNOPSIS
    Exports all Intune policy and app assignments to an Excel file.
.DESCRIPTION
    Retrieves assignments for all Intune configuration areas including device
    configurations, compliance policies, Settings Catalog policies, endpoint security,
    app protection policies, app configurations, scripts, proactive remediations,
    update rings, Autopilot profiles, and mobile apps. Outputs one row per assignment
    with resolved group names and assignment filter details.
.AUTHOR
    Daniel Petri
.EXAMPLE
    .\Get-AllIntuneAssignments.ps1
    Connects interactively, exports to Excel in the temp folder, and opens Out-GridView.
.EXAMPLE
    .\Get-AllIntuneAssignments.ps1 -NoGridView -ExportPath C:\Reports
    Exports to a specific folder without opening the grid view.
.NOTES
    Requires: Microsoft.Graph.Authentication, ImportExcel (Install-Module ImportExcel)
    Permissions: DeviceManagementApps.Read.All, DeviceManagementServiceConfig.Read.All,
        DeviceManagementConfiguration.Read.All, DeviceManagementManagedDevices.Read.All,
        DeviceManagementScripts.Read.All, Group.Read.All
    Version: 2.0.0
#>

param(
    [string]$TenantId,
    [string]$ExportPath,
    [switch]$NoGridView
)

# ==============================
# GRAPH HELPERS
# ==============================

function Invoke-GraphGetSafe {
    param([Parameter(Mandatory)][string]$Uri)

    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            return Invoke-MgGraphRequest -Method GET -Uri $Uri -ErrorAction Stop
        }
        catch {
            $msg = $_.Exception.Message
            if (($msg -match '429') -or ($msg -match 'Too Many Requests') -or ($msg -match '503') -or ($msg -match '504')) {
                $wait = [Math]::Min(5 * [Math]::Pow(2, $attempt - 1), 60)
                Write-Host "  Throttled (attempt $attempt/5), waiting ${wait}s..." -ForegroundColor DarkYellow
                Start-Sleep -Seconds $wait
                continue
            }
            Write-Warning "Graph call failed: $msg"
            return $null
        }
    }

    Write-Warning "Failed after 5 retries: $Uri"
    return $null
}

function Invoke-GraphGetPaged {
    param([Parameter(Mandatory)][string]$Uri)

    $items = [System.Collections.Generic.List[object]]::new()
    $next = $Uri

    while (-not [string]::IsNullOrWhiteSpace($next)) {
        $response = Invoke-GraphGetSafe -Uri $next
        if ($null -eq $response) {
            Write-Warning "Failed to fetch page: $next"
            break
        }
        if ($response -is [System.Collections.IDictionary] -and $response.ContainsKey('value')) {
            foreach ($item in @($response.value)) { [void]$items.Add($item) }
            $next = $response.'@odata.nextLink'
        }
        else {
            if ($null -ne $response) { [void]$items.Add($response) }
            $next = $null
        }
    }

    return @($items)
}

# ==============================
# ASSIGNMENT NORMALIZER
# ==============================

function Get-Assignments {
    [cmdletbinding()]
    param (
        [Parameter(Mandatory)]$Config,
        [array]$Assignments,
        [string]$Type
    )

    $data = [System.Collections.Generic.List[object]]::new()

    if (-not $Type) {
        $Type = if ($Config.'@odata.type') {
            $Config.'@odata.type'.Split('.')[2]
        } else { 'Unknown' }
    }

    $Name = if ($Config.displayName) { $Config.displayName } else { $Config.name }

    if (-not $Assignments -or $Assignments.Count -eq 0) {
        [void]$data.Add([PSCustomObject][ordered]@{
            Name                 = $Name
            Type                 = $Type
            Assigned             = 'False'
            AssignmentIntent     = ''
            AssignedToAllUsers   = 'False'
            AssignedToAllDevices = 'False'
            AssignedToGroupName  = ''
            AssignedToGroupID    = ''
            AssignmentFilter     = 'none'
            AssignmentFilterName = ''
            AssignmentFilterID   = ''
        })
        return @($data)
    }

    foreach ($Assignment in $Assignments) {
        $TargetAllUsers = 'False'
        $TargetAllDevices = 'False'
        $AssignmentIntent = 'Include'

        switch ($Assignment.target.'@odata.type') {
            '#microsoft.graph.allLicensedUsersAssignmentTarget' {
                $TargetAllUsers = 'True'
                if ($Assignment.intent -eq 'required') { $AssignmentIntent = 'Require' }
                if ($Assignment.intent -eq 'available') { $AssignmentIntent = 'Available' }
            }
            '#microsoft.graph.allDevicesAssignmentTarget' {
                $TargetAllDevices = 'True'
                if ($Assignment.intent -eq 'required') { $AssignmentIntent = 'Require' }
                if ($Assignment.intent -eq 'available') { $AssignmentIntent = 'Available' }
            }
            '#microsoft.graph.groupAssignmentTarget' {
                if ($Assignment.intent -eq 'required') { $AssignmentIntent = 'Require' }
                if ($Assignment.intent -eq 'available') { $AssignmentIntent = 'Available' }
            }
            '#microsoft.graph.exclusionGroupAssignmentTarget' {
                $AssignmentIntent = 'Exclude'
            }
            default {
                $AssignmentIntent = 'Unknown'
            }
        }

        # Resolve group name
        $groupName = ''
        $groupId = $Assignment.target.groupId
        if ($groupId) {
            $match = $script:AllGroups | Where-Object { $_.id -eq $groupId }
            $groupName = if ($match) { $match.displayName } else { $groupId }
        }

        # Resolve assignment filter
        $filterType = $Assignment.target.deviceAndAppManagementAssignmentFilterType
        $filterId = $Assignment.target.deviceAndAppManagementAssignmentFilterId
        $filterName = ''
        if ($filterType -and $filterType -ne 'none' -and $filterId) {
            $filterMatch = $script:AllAssignmentFilters | Where-Object { $_.id -eq $filterId }
            $filterName = if ($filterMatch) { $filterMatch.displayName } else { $filterId }
        }
        if (-not $filterType) { $filterType = 'none' }

        [void]$data.Add([PSCustomObject][ordered]@{
            Name                 = $Name
            Type                 = $Type
            Assigned             = 'True'
            AssignmentIntent     = $AssignmentIntent
            AssignedToAllUsers   = $TargetAllUsers
            AssignedToAllDevices = $TargetAllDevices
            AssignedToGroupName  = $groupName
            AssignedToGroupID    = $groupId
            AssignmentFilter     = $filterType
            AssignmentFilterName = $filterName
            AssignmentFilterID   = $filterId
        })
    }

    return @($data)
}

function Get-WorkloadAssignments {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$ListUri,
        [Parameter(Mandatory)][string]$AssignmentUriTemplate,
        [string]$Type
    )

    $items = Invoke-GraphGetPaged -Uri $ListUri
    if (-not $items -or $items.Count -eq 0) {
        Write-Host "  $Label`: 0" -ForegroundColor DarkGray
        return @()
    }
    Write-Host "  $Label`: $($items.Count)"

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $items) {
        $uri = $AssignmentUriTemplate -replace '\{id\}', $item.id
        $assignments = Invoke-GraphGetPaged -Uri $uri
        $params = @{ Config = $item; Assignments = $assignments }
        if ($Type) { $params['Type'] = $Type }
        $rows = Get-Assignments @params
        foreach ($row in $rows) { [void]$results.Add($row) }
    }

    return @($results)
}

# ==============================
# CONNECT
# ==============================

$scopes = @(
    'DeviceManagementApps.Read.All'
    'DeviceManagementServiceConfig.Read.All'
    'DeviceManagementConfiguration.Read.All'
    'DeviceManagementManagedDevices.Read.All'
    'DeviceManagementScripts.Read.All'
    'Group.Read.All'
)

$connectParams = @{ Scopes = $scopes }
if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
    $connectParams['TenantId'] = $TenantId
}
Connect-MgGraph @connectParams -ErrorAction Stop | Out-Null

$mgContext = Get-MgContext
Write-Host "Connected: $($mgContext.Account) | Tenant: $($mgContext.TenantId)" -ForegroundColor DarkCyan

# ==============================
# PRE-LOAD REFERENCE DATA
# ==============================

Write-Host 'Loading groups and assignment filters...' -ForegroundColor Cyan

$script:AllGroups = Invoke-GraphGetPaged -Uri 'https://graph.microsoft.com/v1.0/groups?$select=id,displayName'
Write-Host "  Groups: $($script:AllGroups.Count)"

$script:AllAssignmentFilters = Invoke-GraphGetPaged -Uri 'https://graph.microsoft.com/beta/deviceManagement/assignmentFilters?$select=id,displayName'
Write-Host "  Assignment Filters: $($script:AllAssignmentFilters.Count)"

# ==============================
# COLLECT ALL ASSIGNMENTS
# ==============================

Write-Host 'Collecting assignments from all workloads...' -ForegroundColor Cyan

$AllIntuneAssignments = [System.Collections.Generic.List[object]]::new()

$workloads = @(
    @{
        Label    = 'Device Configurations'
        ListUri  = 'https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations?$select=id,displayName'
        Template = 'https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations/{id}/assignments'
    }
    @{
        Label    = 'Group Policy Configurations'
        ListUri  = 'https://graph.microsoft.com/beta/deviceManagement/groupPolicyConfigurations?$select=id,displayName'
        Template = 'https://graph.microsoft.com/beta/deviceManagement/groupPolicyConfigurations/{id}/assignments'
        Type     = 'groupPolicyConfigurations'
    }
    @{
        Label    = 'Compliance Policies'
        ListUri  = 'https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicies?$select=id,displayName'
        Template = 'https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicies/{id}/assignments'
    }
    @{
        Label    = 'Feature Update Profiles'
        ListUri  = 'https://graph.microsoft.com/beta/deviceManagement/windowsFeatureUpdateProfiles?$select=id,displayName'
        Template = 'https://graph.microsoft.com/beta/deviceManagement/windowsFeatureUpdateProfiles/{id}/assignments'
        Type     = 'windowsFeatureUpdateProfiles'
    }
    @{
        Label    = 'Quality Update Profiles (legacy)'
        ListUri  = 'https://graph.microsoft.com/beta/deviceManagement/windowsQualityUpdateProfiles?$select=id,displayName'
        Template = 'https://graph.microsoft.com/beta/deviceManagement/windowsQualityUpdateProfiles/{id}/assignments'
        Type     = 'windowsQualityUpdateProfiles'
    }
    @{
        Label    = 'Quality Update Policies'
        ListUri  = 'https://graph.microsoft.com/beta/deviceManagement/windowsQualityUpdatePolicies?$select=id,displayName'
        Template = 'https://graph.microsoft.com/beta/deviceManagement/windowsQualityUpdatePolicies/{id}/assignments'
        Type     = 'windowsQualityUpdatePolicies'
    }
    @{
        Label    = 'Settings Catalog / Configuration Policies'
        ListUri  = 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies?$select=id,name'
        Template = 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/{id}/assignments'
        Type     = 'configurationPolicies'
    }
    @{
        Label    = 'Endpoint Security Intents (legacy)'
        ListUri  = 'https://graph.microsoft.com/beta/deviceManagement/intents?$select=id,displayName'
        Template = 'https://graph.microsoft.com/beta/deviceManagement/intents/{id}/assignments'
        Type     = 'intents'
    }
    @{
        Label    = 'App Configurations'
        ListUri  = 'https://graph.microsoft.com/beta/deviceAppManagement/mobileAppConfigurations?$select=id,displayName'
        Template = 'https://graph.microsoft.com/beta/deviceAppManagement/mobileAppConfigurations/{id}/assignments'
    }
    @{
        Label    = 'Device Management Scripts'
        ListUri  = 'https://graph.microsoft.com/beta/deviceManagement/deviceManagementScripts?$select=id,displayName'
        Template = 'https://graph.microsoft.com/beta/deviceManagement/deviceManagementScripts/{id}/assignments'
        Type     = 'deviceManagementScripts'
    }
    @{
        Label    = 'Proactive Remediations'
        ListUri  = 'https://graph.microsoft.com/beta/deviceManagement/deviceHealthScripts?$select=id,displayName'
        Template = 'https://graph.microsoft.com/beta/deviceManagement/deviceHealthScripts/{id}/assignments'
        Type     = 'deviceHealthScripts'
    }
    @{
        Label    = 'Autopilot Profiles'
        ListUri  = 'https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeploymentProfiles?$select=id,displayName'
        Template = 'https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeploymentProfiles/{id}/assignments'
    }
    @{
        Label    = 'Enrollment Configurations'
        ListUri  = 'https://graph.microsoft.com/beta/deviceManagement/deviceEnrollmentConfigurations?$select=id,displayName'
        Template = 'https://graph.microsoft.com/beta/deviceManagement/deviceEnrollmentConfigurations/{id}/assignments'
        Type     = 'deviceEnrollmentConfigurations'
    }
    @{
        Label    = 'macOS Scripts'
        ListUri  = 'https://graph.microsoft.com/beta/deviceManagement/deviceShellScripts?$select=id,displayName'
        Template = 'https://graph.microsoft.com/beta/deviceManagement/deviceShellScripts/{id}/assignments'
        Type     = 'deviceShellScripts'
    }
    @{
        Label    = 'Terms and Conditions'
        ListUri  = 'https://graph.microsoft.com/beta/deviceManagement/termsAndConditions?$select=id,displayName'
        Template = 'https://graph.microsoft.com/beta/deviceManagement/termsAndConditions/{id}/assignments'
        Type     = 'termsAndConditions'
    }
    @{
        Label    = 'Mobile Apps'
        ListUri  = 'https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?$select=id,displayName'
        Template = 'https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/{id}/assignments'
    }
)

foreach ($workload in $workloads) {
    $params = @{
        Label                 = $workload.Label
        ListUri               = $workload.ListUri
        AssignmentUriTemplate = $workload.Template
    }
    if ($workload.Type) { $params['Type'] = $workload.Type }
    $rows = Get-WorkloadAssignments @params
    foreach ($row in $rows) { [void]$AllIntuneAssignments.Add($row) }
}

# App Protection Policies (each type has its own assignment endpoint)
Write-Host '  App Protection Policies...'
$AllManagedAppPolicies = Invoke-GraphGetPaged -Uri 'https://graph.microsoft.com/beta/deviceAppManagement/managedAppPolicies?$select=id,displayName'
Write-Host "    Managed App Policies: $($AllManagedAppPolicies.Count)"

$appPolicyEndpoints = @{
    'iosManagedAppProtection'                = 'iosManagedAppProtections'
    'androidManagedAppProtection'            = 'androidManagedAppProtections'
    'targetedManagedAppConfiguration'        = 'targetedManagedAppConfigurations'
    'windowsInformationProtectionPolicy'     = 'windowsInformationProtectionPolicies'
    'mdmWindowsInformationProtectionPolicy'  = 'mdmWindowsInformationProtectionPolicies'
}

foreach ($policy in $AllManagedAppPolicies) {
    $odataType = if ($policy.'@odata.type') { $policy.'@odata.type'.Split('.')[2] } else { $null }
    if ($odataType -and $appPolicyEndpoints.ContainsKey($odataType)) {
        $endpoint = $appPolicyEndpoints[$odataType]
        $assignments = Invoke-GraphGetPaged -Uri "https://graph.microsoft.com/beta/deviceAppManagement/$endpoint/$($policy.id)/assignments"
        $rows = Get-Assignments -Config $policy -Assignments $assignments
        foreach ($row in $rows) { [void]$AllIntuneAssignments.Add($row) }
    }
    elseif ($odataType) {
        Write-Warning "Unknown app policy type: $odataType (policy: $($policy.displayName))"
    }
}

# ==============================
# OUTPUT
# ==============================

$sortedRows = @($AllIntuneAssignments) | Sort-Object Type, Name, AssignmentIntent

Write-Host "`nTotal assignments: $($sortedRows.Count)" -ForegroundColor Green
$typeCounts = $sortedRows | Group-Object Type | Sort-Object Count -Descending
foreach ($tc in $typeCounts) {
    Write-Host ("  {0}: {1}" -f $tc.Name, $tc.Count) -ForegroundColor DarkGray
}

if (-not $NoGridView) {
    try {
        $sortedRows | Out-GridView -Title "Intune Assignments ($($mgContext.TenantId))"
    }
    catch {
        Write-Warning 'Out-GridView not available (requires desktop environment). Use -NoGridView to suppress.'
    }
}

# Excel export
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$defaultFileName = "IntuneAssignments-$timestamp.xlsx"

if (-not [string]::IsNullOrWhiteSpace($ExportPath)) {
    $exportDir = $ExportPath
} else {
    $exportDir = $env:TEMP
}

if (-not (Test-Path $exportDir)) {
    [void](New-Item -Path $exportDir -ItemType Directory -Force)
}

$exportFile = Join-Path $exportDir $defaultFileName

if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
    Write-Warning "ImportExcel module not installed. Exporting to CSV instead."
    $csvFile = $exportFile -replace '\.xlsx$', '.csv'
    $sortedRows | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8
    Write-Host "CSV exported: $csvFile" -ForegroundColor Green
}
else {
    Import-Module ImportExcel -ErrorAction Stop
    $sortedRows | Export-Excel -Path $exportFile -TableStyle Medium1 -AutoSize -FreezeTopRow
    Write-Host "Excel exported: $exportFile" -ForegroundColor Green
}
