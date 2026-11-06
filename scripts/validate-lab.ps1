#Requires -Version 7.0
<#
.SYNOPSIS
    Validates the Azure Update Manager (AUM) lab end to end.

.DESCRIPTION
    Per VM, checks:
      1. Patch orchestration mode       = AutomaticByPlatform
      2. Patch assessment mode          = AutomaticByPlatform
      3. Bypass platform safety checks  = true (required for custom schedules)
      4. Maintenance configuration is assigned (aum-weekly-patches)
      5. Latest patch assessment result (optionally triggers a fresh one)
      6. Domain membership (optional, uses Run Command, ~1 min per VM)

    Configuration problems are FAIL. Missing critical patches are WARN by
    default, because a freshly built lab is EXPECTED to be missing patches;
    that is the finding Update Manager exists to surface. Use
    -FailOnMissingCritical to treat them as failures (post-patch validation).

.EXAMPLE
    pwsh ./validate-lab.ps1
    pwsh ./validate-lab.ps1 -RunAssessment -CheckDomain
    pwsh ./validate-lab.ps1 -SubscriptionId <sub-id> -FailOnMissingCritical
#>
[CmdletBinding()]
param(
    [string]   $SubscriptionId,
    [string]   $ResourceGroupName     = 'rg-aumlab',
    [string[]] $VmNames               = @('DC01', 'WS01', 'WS02'),
    [string]   $MaintenanceConfigName = 'aum-weekly-patches',
    [switch]   $RunAssessment,
    [switch]   $CheckDomain,
    [switch]   $FailOnMissingCritical,
    [string]   $ReportPath            = './aum-compliance-report.json'
)

$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# 0. Prerequisites: stop early with a clear fix instead of cascading errors
# -----------------------------------------------------------------------------
$requiredModules = 'Az.Accounts', 'Az.Compute', 'Az.Maintenance'
$missing = $requiredModules | Where-Object { -not (Get-Module -ListAvailable -Name $_) }
if ($missing) {
    Write-Host "Missing PowerShell modules: $($missing -join ', ')" -ForegroundColor Red
    Write-Host "Install them with:" -ForegroundColor Yellow
    Write-Host "  Install-Module $($missing -join ', ') -Scope CurrentUser -Repository PSGallery -Force"
    exit 2
}
Import-Module -Name $requiredModules | Out-Null

# -----------------------------------------------------------------------------
# 1. Authentication: reuse an existing session, only prompt when needed
# -----------------------------------------------------------------------------
if (-not (Get-AzContext)) {
    $connectArgs = @{}
    if ($SubscriptionId) { $connectArgs.Subscription = $SubscriptionId }
    Connect-AzAccount @connectArgs | Out-Null
}
if ($SubscriptionId) {
    Set-AzContext -Subscription $SubscriptionId | Out-Null
}
$ctx = Get-AzContext

Write-Host ""
Write-Host "=== Azure Update Manager Compliance Validation ===" -ForegroundColor Cyan
Write-Host "Subscription : $($ctx.Subscription.Name) ($($ctx.Subscription.Id))"
Write-Host "Resource grp : $ResourceGroupName"
Write-Host ""

# -----------------------------------------------------------------------------
# Result collection
# -----------------------------------------------------------------------------
$results = [System.Collections.Generic.List[object]]::new()

function Add-Result {
    param([string]$Vm, [string]$Check, [ValidateSet('PASS','WARN','FAIL')][string]$Status, [string]$Detail)
    $results.Add([pscustomobject]@{ VM = $Vm; Check = $Check; Status = $Status; Detail = $Detail })
    $color = @{ PASS = 'Green'; WARN = 'Yellow'; FAIL = 'Red' }[$Status]
    Write-Host ("[{0}] {1,-5} {2,-24} {3}" -f $Status, $Vm, $Check, $Detail) -ForegroundColor $color
}

function PassFail([bool]$Condition) { if ($Condition) { 'PASS' } else { 'FAIL' } }

# -----------------------------------------------------------------------------
# 2. Per-VM checks
# -----------------------------------------------------------------------------
foreach ($name in $VmNames) {

    # --- VM exists -----------------------------------------------------------
    try {
        $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $name
    }
    catch {
        Add-Result $name 'VM exists' 'FAIL' $_.Exception.Message
        continue
    }

    # --- Patch settings ------------------------------------------------------
    $ps = $vm.OSProfile.WindowsConfiguration.PatchSettings
    Add-Result $name 'Patch mode'      (PassFail ($ps.PatchMode -eq 'AutomaticByPlatform'))      "$($ps.PatchMode)"
    Add-Result $name 'Assessment mode' (PassFail ($ps.AssessmentMode -eq 'AutomaticByPlatform')) "$($ps.AssessmentMode)"

    $bypass = $ps.AutomaticByPlatformSettings.BypassPlatformSafetyChecksOnUserSchedule
    Add-Result $name 'Bypass safety checks' (PassFail ($bypass -eq $true)) "$bypass"

    # --- Maintenance configuration assignment -------------------------------
    try {
        $assignments = Get-AzConfigurationAssignment `
            -ResourceGroupName $ResourceGroupName `
            -ProviderName      'Microsoft.Compute' `
            -ResourceType      'VirtualMachines' `
            -ResourceName      $name
        $match = $assignments | Where-Object { $_.MaintenanceConfigurationId -like "*/$MaintenanceConfigName" }
        Add-Result $name 'Maintenance schedule' (PassFail ([bool]$match)) `
            ($(if ($match) { $MaintenanceConfigName } else { "not assigned to $MaintenanceConfigName" }))
    }
    catch {
        Add-Result $name 'Maintenance schedule' 'FAIL' $_.Exception.Message
    }

    # --- Patch assessment ----------------------------------------------------
    $summary = $null
    try {
        if ($RunAssessment) {
            Write-Host "        Running patch assessment on $name (typically 2-5 min)..." -ForegroundColor DarkGray
            $a = Invoke-AzVMPatchAssessment -ResourceGroupName $ResourceGroupName -VMName $name
            $summary = [pscustomobject]@{
                Status   = $a.Status
                Critical = $a.CriticalAndSecurityPatchCount
                Other    = $a.OtherPatchCount
                When     = $a.StartDateTime
            }
        }
        else {
            $s = (Get-AzVM -ResourceGroupName $ResourceGroupName -Name $name -Status).PatchStatus.AvailablePatchSummary
            if ($s) {
                $summary = [pscustomobject]@{
                    Status   = $s.Status
                    Critical = $s.CriticalAndSecurityPatchCount
                    Other    = $s.OtherPatchCount
                    When     = $s.LastModifiedTime
                }
            }
        }
    }
    catch {
        Add-Result $name 'Patch assessment' 'FAIL' $_.Exception.Message
        $summary = 'error'
    }

    if ($summary -ne 'error') {
        if (-not $summary -or -not $summary.Status) {
            Add-Result $name 'Patch assessment' 'WARN' 'No assessment yet; rerun with -RunAssessment'
        }
        elseif ($summary.Status -notin 'Succeeded', 'CompletedWithWarnings') {
            Add-Result $name 'Patch assessment' 'FAIL' "Assessment status: $($summary.Status)"
        }
        else {
            $detail = "Critical/Security: $($summary.Critical) | Other: $($summary.Other) | As of: $($summary.When)"
            if ($summary.Critical -gt 0) {
                Add-Result $name 'Missing critical' ($(if ($FailOnMissingCritical) { 'FAIL' } else { 'WARN' })) $detail
            }
            else {
                Add-Result $name 'Missing critical' 'PASS' $detail
            }
        }
    }

    # --- Domain membership (optional, slow) ---------------------------------
    if ($CheckDomain) {
        try {
            $r = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $name `
                    -CommandId 'RunPowerShellScript' `
                    -ScriptString '(Get-CimInstance Win32_ComputerSystem).Domain'
            $domain = "$($r.Value[0].Message)".Trim()
            Add-Result $name 'Domain membership' (PassFail ($domain -and $domain -ne 'WORKGROUP')) $domain
        }
        catch {
            Add-Result $name 'Domain membership' 'FAIL' $_.Exception.Message
        }
    }
}

# -----------------------------------------------------------------------------
# 3. Summary + JSON report
# -----------------------------------------------------------------------------
$failCount = @($results | Where-Object Status -eq 'FAIL').Count
$warnCount = @($results | Where-Object Status -eq 'WARN').Count
$overall   = if ($failCount) { 'FAIL' } elseif ($warnCount) { 'PASS WITH WARNINGS' } else { 'PASS' }

Write-Host ""
$overallColor = @{ 'FAIL' = 'Red'; 'PASS WITH WARNINGS' = 'Yellow'; 'PASS' = 'Green' }[$overall]
Write-Host "Overall: $overall  ($failCount fail, $warnCount warn, $($results.Count) checks)" -ForegroundColor $overallColor

[pscustomobject]@{
    GeneratedAt   = (Get-Date).ToString('o')
    Subscription  = $ctx.Subscription.Id
    ResourceGroup = $ResourceGroupName
    Overall       = $overall
    Results       = $results
} | ConvertTo-Json -Depth 5 | Set-Content -Path $ReportPath -Encoding utf8

Write-Host "Report exported: $ReportPath"

if ($failCount) { exit 1 } else { exit 0 }
