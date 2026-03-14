#Requires -Module Microsoft.Graph.Authentication
<#
.SYNOPSIS
    Finds Intune groups that have no policy or app assignments.
.DESCRIPTION
    Retrieves all security groups whose display name starts with a given prefix (default:
    "Intune"), then collects every assignment across all Intune workloads and cross-references.
    Groups that are neither directly assigned nor nested inside an assigned group are reported
    as unused and exported to Excel (or CSV if ImportExcel is not installed).
.AUTHOR
    Daniel Petri
.EXAMPLE
    .\Get-AllIntuneGroupsWithoutAssignments.ps1
    Finds all groups starting with "Intune" that have no assignments.
.EXAMPLE
    .\Get-AllIntuneGroupsWithoutAssignments.ps1 -Prefix "MDM"
    Finds all groups starting with "MDM" that have no assignments.
.EXAMPLE
    .\Get-AllIntuneGroupsWithoutAssignments.ps1 -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    Targets a specific tenant.
.EXAMPLE
    .\Get-AllIntuneGroupsWithoutAssignments.ps1 -ExportPath "C:\Reports" -NoGridView
    Exports to a specific folder without opening the grid view.
.NOTES
    Requires: Microsoft.Graph.Authentication, ImportExcel (optional, falls back to CSV)
    Permissions: Group.Read.All, DeviceManagementApps.Read.All,
        DeviceManagementConfiguration.Read.All, DeviceManagementServiceConfig.Read.All,
        DeviceManagementManagedDevices.Read.All, DeviceManagementScripts.Read.All
    Version: 2.0.0
#>

param(
    [string]$Prefix = 'Intune',

    [string]$TenantId,

    [string]$ExportPath,

    [switch]$NoGridView
)

#region Graph helpers
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
#endregion

#region Connect
$scopes = @(
    'Group.Read.All'
    'DeviceManagementApps.Read.All'
    'DeviceManagementConfiguration.Read.All'
    'DeviceManagementServiceConfig.Read.All'
    'DeviceManagementManagedDevices.Read.All'
    'DeviceManagementScripts.Read.All'
)

$connectParams = @{ Scopes = $scopes }
if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
    $connectParams['TenantId'] = $TenantId
}
Connect-MgGraph @connectParams -ErrorAction Stop | Out-Null

$mgContext = Get-MgContext
Write-Host "Connected: $($mgContext.Account) | Tenant: $($mgContext.TenantId)" -ForegroundColor DarkCyan
#endregion

#region Collect all assigned group IDs from every workload
Write-Host 'Collecting assignments from all Intune workloads...' -ForegroundColor Cyan

$assignedGroupIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

$workloads = @(
    @{ Label = 'Device Configurations';             ListUri = 'https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations?$select=id';             Template = 'https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations/{id}/assignments' }
    @{ Label = 'Group Policy Configurations';        ListUri = 'https://graph.microsoft.com/beta/deviceManagement/groupPolicyConfigurations?$select=id';        Template = 'https://graph.microsoft.com/beta/deviceManagement/groupPolicyConfigurations/{id}/assignments' }
    @{ Label = 'Compliance Policies';                ListUri = 'https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicies?$select=id';         Template = 'https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicies/{id}/assignments' }
    @{ Label = 'Settings Catalog';                   ListUri = 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies?$select=id';            Template = 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/{id}/assignments' }
    @{ Label = 'Endpoint Security Intents';          ListUri = 'https://graph.microsoft.com/beta/deviceManagement/intents?$select=id';                          Template = 'https://graph.microsoft.com/beta/deviceManagement/intents/{id}/assignments' }
    @{ Label = 'Feature Update Profiles';            ListUri = 'https://graph.microsoft.com/beta/deviceManagement/windowsFeatureUpdateProfiles?$select=id';     Template = 'https://graph.microsoft.com/beta/deviceManagement/windowsFeatureUpdateProfiles/{id}/assignments' }
    @{ Label = 'Quality Update Profiles (legacy)';   ListUri = 'https://graph.microsoft.com/beta/deviceManagement/windowsQualityUpdateProfiles?$select=id';     Template = 'https://graph.microsoft.com/beta/deviceManagement/windowsQualityUpdateProfiles/{id}/assignments' }
    @{ Label = 'Quality Update Policies';            ListUri = 'https://graph.microsoft.com/beta/deviceManagement/windowsQualityUpdatePolicies?$select=id';     Template = 'https://graph.microsoft.com/beta/deviceManagement/windowsQualityUpdatePolicies/{id}/assignments' }
    @{ Label = 'App Configurations';                 ListUri = 'https://graph.microsoft.com/beta/deviceAppManagement/mobileAppConfigurations?$select=id';       Template = 'https://graph.microsoft.com/beta/deviceAppManagement/mobileAppConfigurations/{id}/assignments' }
    @{ Label = 'Device Management Scripts';          ListUri = 'https://graph.microsoft.com/beta/deviceManagement/deviceManagementScripts?$select=id';          Template = 'https://graph.microsoft.com/beta/deviceManagement/deviceManagementScripts/{id}/assignments' }
    @{ Label = 'Proactive Remediations';             ListUri = 'https://graph.microsoft.com/beta/deviceManagement/deviceHealthScripts?$select=id';              Template = 'https://graph.microsoft.com/beta/deviceManagement/deviceHealthScripts/{id}/assignments' }
    @{ Label = 'Autopilot Profiles';                 ListUri = 'https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeploymentProfiles?$select=id'; Template = 'https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeploymentProfiles/{id}/assignments' }
    @{ Label = 'Enrollment Configurations';          ListUri = 'https://graph.microsoft.com/beta/deviceManagement/deviceEnrollmentConfigurations?$select=id';   Template = 'https://graph.microsoft.com/beta/deviceManagement/deviceEnrollmentConfigurations/{id}/assignments' }
    @{ Label = 'macOS Scripts';                      ListUri = 'https://graph.microsoft.com/beta/deviceManagement/deviceShellScripts?$select=id';               Template = 'https://graph.microsoft.com/beta/deviceManagement/deviceShellScripts/{id}/assignments' }
    @{ Label = 'Terms and Conditions';               ListUri = 'https://graph.microsoft.com/beta/deviceManagement/termsAndConditions?$select=id';               Template = 'https://graph.microsoft.com/beta/deviceManagement/termsAndConditions/{id}/assignments' }
    @{ Label = 'Mobile Apps';                        ListUri = 'https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?$select=id';                    Template = 'https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/{id}/assignments' }
)

foreach ($workload in $workloads) {
    $items = Invoke-GraphGetPaged -Uri $workload.ListUri
    if (-not $items -or $items.Count -eq 0) {
        Write-Host "  $($workload.Label): 0" -ForegroundColor DarkGray
        continue
    }
    Write-Host "  $($workload.Label): $($items.Count)"

    foreach ($item in $items) {
        $uri = $workload.Template -replace '\{id\}', $item.id
        $assignments = Invoke-GraphGetPaged -Uri $uri
        foreach ($assignment in $assignments) {
            $groupId = $assignment.target.groupId
            if ($groupId) {
                [void]$assignedGroupIds.Add($groupId)
            }
        }
    }
}

# App Protection Policies (each type has its own assignment endpoint)
Write-Host '  App Protection Policies...'
$AllManagedAppPolicies = Invoke-GraphGetPaged -Uri 'https://graph.microsoft.com/beta/deviceAppManagement/managedAppPolicies?$select=id'

$appPolicyEndpoints = @{
    'iosManagedAppProtection'               = 'iosManagedAppProtections'
    'androidManagedAppProtection'           = 'androidManagedAppProtections'
    'targetedManagedAppConfiguration'       = 'targetedManagedAppConfigurations'
    'windowsInformationProtectionPolicy'    = 'windowsInformationProtectionPolicies'
    'mdmWindowsInformationProtectionPolicy' = 'mdmWindowsInformationProtectionPolicies'
}

foreach ($policy in $AllManagedAppPolicies) {
    $odataType = if ($policy.'@odata.type') { $policy.'@odata.type'.Split('.')[2] } else { $null }
    if ($odataType -and $appPolicyEndpoints.ContainsKey($odataType)) {
        $endpoint = $appPolicyEndpoints[$odataType]
        $assignments = Invoke-GraphGetPaged -Uri "https://graph.microsoft.com/beta/deviceAppManagement/$endpoint/$($policy.id)/assignments"
        foreach ($assignment in $assignments) {
            $groupId = $assignment.target.groupId
            if ($groupId) {
                [void]$assignedGroupIds.Add($groupId)
            }
        }
    }
}

Write-Host "Unique assigned group IDs: $($assignedGroupIds.Count)" -ForegroundColor Cyan
#endregion

#region Fetch groups matching prefix
Write-Host "Fetching groups starting with '$Prefix'..." -ForegroundColor Cyan
$AllPrefixGroups = Invoke-GraphGetPaged -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=startswith(displayName,'$Prefix')&`$select=id,displayName"

if (-not $AllPrefixGroups -or $AllPrefixGroups.Count -eq 0) {
    Write-Warning "No groups found starting with '$Prefix'."
    return
}
Write-Host "Groups matching '$Prefix': $($AllPrefixGroups.Count)" -ForegroundColor Cyan
#endregion

#region Find unassigned groups (direct check)
$unassignedGroups = [System.Collections.Generic.List[object]]::new()
foreach ($group in $AllPrefixGroups) {
    if (-not $assignedGroupIds.Contains($group.id)) {
        [void]$unassignedGroups.Add($group)
    }
}
Write-Host "Groups with no direct assignment: $($unassignedGroups.Count)" -ForegroundColor Yellow
#endregion

#region Parent group check -- exclude groups nested inside an assigned group
Write-Host 'Checking parent group memberships...' -ForegroundColor Cyan
$report = [System.Collections.Generic.List[object]]::new()

foreach ($group in $unassignedGroups) {
    $memberOf = Invoke-GraphGetPaged -Uri "https://graph.microsoft.com/v1.0/groups/$($group.id)/memberOf?`$select=id,displayName"
    $parentAssigned = $false

    foreach ($parent in $memberOf) {
        if ($assignedGroupIds.Contains($parent.id)) {
            $parentAssigned = $true
            break
        }
    }

    if (-not $parentAssigned) {
        $parentNames = if ($memberOf.Count -gt 0) { ($memberOf | ForEach-Object { $_.displayName }) -join ', ' } else { '' }
        [void]$report.Add([PSCustomObject]@{
            GroupName = $group.displayName
            GroupID   = $group.id
            MemberOf  = $parentNames
        })
    }
}

Write-Host "Truly unassigned groups: $($report.Count)" -ForegroundColor Yellow
#endregion

#region Output
if ($report.Count -eq 0) {
    Write-Host "No unassigned groups found. All '$Prefix' groups are in use." -ForegroundColor Green
    return
}

if (-not $NoGridView) {
    try {
        $report | Out-GridView -Title "Unassigned '$Prefix' Groups ($($mgContext.TenantId))"
    }
    catch {
        Write-Warning 'Out-GridView not available (requires desktop environment). Use -NoGridView to suppress.'
    }
}

# Export
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$fileName = "UnassignedGroups-$Prefix-$timestamp"

$exportDir = if (-not [string]::IsNullOrWhiteSpace($ExportPath)) { $ExportPath } else { $env:TEMP }
if (-not (Test-Path $exportDir)) {
    [void](New-Item -Path $exportDir -ItemType Directory -Force)
}

if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
    $csvFile = Join-Path $exportDir "$fileName.csv"
    $report | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8
    Write-Host "CSV exported: $csvFile" -ForegroundColor Green
}
else {
    Import-Module ImportExcel -ErrorAction Stop
    $xlsxFile = Join-Path $exportDir "$fileName.xlsx"
    $report | Export-Excel -Path $xlsxFile -TableStyle Medium1 -AutoSize -FreezeTopRow
    Write-Host "Excel exported: $xlsxFile" -ForegroundColor Green
}
#endregion
