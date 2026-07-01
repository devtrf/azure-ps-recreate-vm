<#
.SYNOPSIS
Resizes an Azure VM to a temp-disk-backed size by rebuilding it from a snapshot-derived OS disk.

.DESCRIPTION
Captures the source VM configuration, snapshots the current OS disk, creates or reuses a managed
disk from that snapshot, deletes the VM while preserving NICs, OS resources, and data disks, and recreates
the VM on the requested size using Az PowerShell cmdlets.

The script is rerun-safe through a local JSON state file and preserves relevant VM properties such
as zone, license type, marketplace plan, Trusted Launch settings, network interfaces, and data disks when present.

.PARAMETER ResourceGroupName
Name of the Azure resource group that contains the VM.

.PARAMETER VMName
Name of the Azure virtual machine to rebuild.

.PARAMETER NewSize
Target Azure VM size, for example Standard_D4ds_v5.

.PARAMETER SubscriptionId
Optional Azure subscription ID to select before running any Az PowerShell operations.

.PARAMETER SnapshotName
Optional snapshot name to create or reuse. Defaults to a name derived from the VM and target size.

.PARAMETER NewOsDiskName
Optional managed disk name to create or reuse. Defaults to a name derived from the VM and target size.

.PARAMETER StatePath
Optional local path for the rerun state JSON file.

.PARAMETER CleanupSnapshot
Deletes the temporary snapshot after a successful rebuild.

.EXAMPLE
.\Resize-VmTempDisk.ps1 -ResourceGroupName tfvmex-resources -VMName vmtest -NewSize Standard_D4ds_v5

.EXAMPLE
.\Resize-VmTempDisk.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -ResourceGroupName tfvmex-resources -VMName vmtest -NewSize Standard_D4ds_v5 -Confirm:$false
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$VMName,

    [Parameter(Mandatory = $true)]
    [string]$NewSize,

    [string]$SubscriptionId,
    [string]$SnapshotName,
    [string]$NewOsDiskName,
    [string]$StatePath,
    [switch]$CleanupSnapshot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[$timestamp] $Message"
}

function Assert-Module {
    param([string]$Name)
    if (-not (Get-Module -ListAvailable -Name $Name)) {
        throw "Required PowerShell module '$Name' is not installed."
    }
}

function Get-Slug {
    param([string]$Value)
    $lower = $Value.ToLowerInvariant()
    $slug = [System.Text.RegularExpressions.Regex]::Replace($lower, '[^a-z0-9]+', '-')
    return $slug.Trim('-')
}

function Save-State {
    param(
        [hashtable]$State,
        [string]$Path
    )

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $State | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Load-State {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable)
}

function Get-OptionalValue {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }

    $stringValue = [string]$Value
    if ([string]::IsNullOrWhiteSpace($stringValue)) {
        return $null
    }

    return $stringValue
}

function Get-SourceVm {
    param(
        [string]$ResourceGroupName,
        [string]$VMName
    )

    try {
        return Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName
    }
    catch {
        return $null
    }
}

function Get-SourceVmStatus {
    param(
        [string]$ResourceGroupName,
        [string]$VMName
    )

    try {
        return Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Status
    }
    catch {
        return $null
    }
}

function Get-ExistingSnapshot {
    param(
        [string]$ResourceGroupName,
        [string]$SnapshotName
    )

    try {
        return Get-AzSnapshot -ResourceGroupName $ResourceGroupName -SnapshotName $SnapshotName
    }
    catch {
        return $null
    }
}

function Get-ExistingDisk {
    param(
        [string]$ResourceGroupName,
        [string]$DiskName
    )

    try {
        return Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $DiskName
    }
    catch {
        return $null
    }
}

function Wait-ForDiskSucceeded {
    param(
        [string]$ResourceGroupName,
        [string]$DiskName,
        [int]$TimeoutSeconds = 1800
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $disk = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $DiskName
        if ($disk.ProvisioningState -eq 'Succeeded') {
            return $disk
        }

        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $deadline)

    throw "Timed out waiting for disk '$DiskName' to reach ProvisioningState=Succeeded."
}

function Get-DataDiskStateFromVm {
    param($Vm)

    if (-not $Vm.StorageProfile.DataDisks -or $Vm.StorageProfile.DataDisks.Count -eq 0) {
        return @()
    }

    $disks = foreach ($dataDisk in ($Vm.StorageProfile.DataDisks | Sort-Object { [int]$_.Lun })) {
        @{
            Lun                     = [int]$dataDisk.Lun
            Name                    = $dataDisk.Name
            DiskId                  = $dataDisk.ManagedDisk.Id
            Caching                 = Get-OptionalValue $dataDisk.Caching
            WriteAcceleratorEnabled = if ($null -ne $dataDisk.WriteAcceleratorEnabled) { [bool]$dataDisk.WriteAcceleratorEnabled } else { $null }
        }
    }

    return @($disks)
}

function Get-NetworkInterfaceStateFromVm {
    param($Vm)

    if (-not $Vm.NetworkProfile.NetworkInterfaces -or $Vm.NetworkProfile.NetworkInterfaces.Count -eq 0) {
        throw 'VM has no network interfaces.'
    }

    $singleNic = $Vm.NetworkProfile.NetworkInterfaces.Count -eq 1
    $nics = foreach ($nicRef in $Vm.NetworkProfile.NetworkInterfaces) {
        @{
            Id      = $nicRef.Id
            Primary = if ($null -ne $nicRef.Primary) {
                [bool]$nicRef.Primary
            }
            elseif ($singleNic) {
                $true
            }
            else {
                $false
            }
        }
    }

    return @($nics | Sort-Object { -not $_.Primary })
}

function Get-StateNetworkInterfaces {
    param([hashtable]$State)

    if ($State.NetworkInterfaces -and @($State.NetworkInterfaces).Count -gt 0) {
        return @($State.NetworkInterfaces)
    }

    if ($State.NicId) {
        return @(
            @{
                Id      = [string]$State.NicId
                Primary = $true
            }
        )
    }

    return @()
}

function Test-VmNetworkInterfacesMatch {
    param(
        $Vm,
        $ExpectedNetworkInterfaces
    )

    $expected = if ($ExpectedNetworkInterfaces) { @($ExpectedNetworkInterfaces) } else { @() }
    $actual = if ($Vm.NetworkProfile.NetworkInterfaces) { @($Vm.NetworkProfile.NetworkInterfaces) } else { @() }

    if ($expected.Count -ne $actual.Count) {
        return $false
    }

    foreach ($expectedNic in $expected) {
        $expectedId = [string]$expectedNic.Id
        $actualNic = $actual | Where-Object { $_.Id -eq $expectedId } | Select-Object -First 1
        if (-not $actualNic) {
            return $false
        }

        if ([bool]$actualNic.Primary -ne [bool]$expectedNic.Primary) {
            return $false
        }
    }

    return $true
}

function Test-VmDataDisksMatch {
    param(
        $Vm,
        $ExpectedDataDisks
    )

    $expected = if ($ExpectedDataDisks) { @($ExpectedDataDisks) } else { @() }
    $actual = if ($Vm.StorageProfile.DataDisks) { @($Vm.StorageProfile.DataDisks) } else { @() }

    if ($expected.Count -ne $actual.Count) {
        return $false
    }

    foreach ($expectedDisk in ($expected | Sort-Object { [int]$_.Lun })) {
        $expectedLun = [int]$expectedDisk.Lun
        $actualDisk = $actual | Where-Object { [int]$_.Lun -eq $expectedLun } | Select-Object -First 1
        if (-not $actualDisk) {
            return $false
        }

        if ($actualDisk.ManagedDisk.Id -ne [string]$expectedDisk.DiskId) {
            return $false
        }
    }

    return $true
}

function Test-VmCoreMatchesTarget {
    param(
        $Vm,
        [string]$ExpectedSize,
        [string]$ExpectedDiskId
    )

    return (
        $Vm.HardwareProfile.VmSize -eq $ExpectedSize -and
        $Vm.StorageProfile.OsDisk.ManagedDisk.Id -eq $ExpectedDiskId
    )
}

function CurrentVmMatchesTarget {
    param(
        [string]$ResourceGroupName,
        [string]$VMName,
        [string]$ExpectedSize,
        [string]$ExpectedDiskId,
        $ExpectedNetworkInterfaces,
        $ExpectedDataDisks
    )

    $vm = Get-SourceVm -ResourceGroupName $ResourceGroupName -VMName $VMName
    if (-not $vm) {
        return $false
    }

    return (
        (Test-VmCoreMatchesTarget -Vm $vm -ExpectedSize $ExpectedSize -ExpectedDiskId $ExpectedDiskId) -and
        (Test-VmNetworkInterfacesMatch -Vm $vm -ExpectedNetworkInterfaces $ExpectedNetworkInterfaces) -and
        (Test-VmDataDisksMatch -Vm $vm -ExpectedDataDisks $ExpectedDataDisks)
    )
}

function Add-NetworkInterfacesToVmConfig {
    param(
        $VmConfig,
        $NetworkInterfaces
    )

    $nicRefs = if ($NetworkInterfaces) { @($NetworkInterfaces) } else { @() }
    foreach ($nicRef in ($nicRefs | Sort-Object { -not [bool]$_.Primary })) {
        if ([bool]$nicRef.Primary) {
            $VmConfig = Add-AzVMNetworkInterface -VM $VmConfig -Id ([string]$nicRef.Id) -Primary
        }
        else {
            $VmConfig = Add-AzVMNetworkInterface -VM $VmConfig -Id ([string]$nicRef.Id)
        }
    }

    return $VmConfig
}

function Add-DataDisksToVmConfig {
    param(
        $VmConfig,
        $DataDisks
    )

    $dataDiskRefs = if ($DataDisks) { @($DataDisks) } else { @() }
    foreach ($dataDiskRef in ($dataDiskRefs | Sort-Object { [int]$_.Lun })) {
        $attachParams = @{
            VM             = $VmConfig
            Name           = [string]$dataDiskRef.Name
            ManagedDiskId  = [string]$dataDiskRef.DiskId
            Lun            = [int]$dataDiskRef.Lun
            CreateOption   = 'Attach'
        }

        if ($dataDiskRef.Caching) {
            $attachParams.Caching = [string]$dataDiskRef.Caching
        }
        if ($null -ne $dataDiskRef.WriteAcceleratorEnabled) {
            $attachParams.WriteAccelerator = [bool]$dataDiskRef.WriteAcceleratorEnabled
        }

        $VmConfig = Add-AzVMDataDisk @attachParams
    }

    return $VmConfig
}

function Repair-MissingDataDisks {
    param([hashtable]$State)

    $vm = Get-SourceVm -ResourceGroupName $State.ResourceGroupName -VMName $State.VMName
    if (-not $vm) {
        return $false
    }

    if (-not (Test-VmCoreMatchesTarget -Vm $vm -ExpectedSize $State.NewSize -ExpectedDiskId $State.NewOsDiskId)) {
        return $false
    }

    if (Test-VmDataDisksMatch -Vm $vm -ExpectedDataDisks $State.DataDisks) {
        return $true
    }

    $expectedDisks = if ($State.DataDisks) { @($State.DataDisks) } else { @() }
    $attachedLuns = @(
        if ($vm.StorageProfile.DataDisks) {
            $vm.StorageProfile.DataDisks | ForEach-Object { [int]$_.Lun }
        }
    )

    foreach ($dataDiskRef in ($expectedDisks | Sort-Object { [int]$_.Lun })) {
        if ($attachedLuns -contains [int]$dataDiskRef.Lun) {
            continue
        }

        Write-Log "Attaching data disk '$($dataDiskRef.Name)' at LUN $($dataDiskRef.Lun)"
        $attachParams = @{
            VM            = $vm
            Name          = [string]$dataDiskRef.Name
            ManagedDiskId = [string]$dataDiskRef.DiskId
            Lun           = [int]$dataDiskRef.Lun
            CreateOption  = 'Attach'
        }

        if ($dataDiskRef.Caching) {
            $attachParams.Caching = [string]$dataDiskRef.Caching
        }
        if ($null -ne $dataDiskRef.WriteAcceleratorEnabled) {
            $attachParams.WriteAccelerator = [bool]$dataDiskRef.WriteAcceleratorEnabled
        }

        $vm = Add-AzVMDataDisk @attachParams
    }

    Update-AzVM -ResourceGroupName $State.ResourceGroupName -VM $vm | Out-Null
    return (Test-VmDataDisksMatch -Vm (Get-SourceVm -ResourceGroupName $State.ResourceGroupName -VMName $State.VMName) -ExpectedDataDisks $State.DataDisks)
}

function Repair-MissingNetworkInterfaces {
    param([hashtable]$State)

    $vm = Get-SourceVm -ResourceGroupName $State.ResourceGroupName -VMName $State.VMName
    if (-not $vm) {
        return $false
    }

    if (-not (Test-VmCoreMatchesTarget -Vm $vm -ExpectedSize $State.NewSize -ExpectedDiskId $State.NewOsDiskId)) {
        return $false
    }

    $expectedNics = Get-StateNetworkInterfaces -State $State
    if (Test-VmNetworkInterfacesMatch -Vm $vm -ExpectedNetworkInterfaces $expectedNics) {
        return $true
    }

    $attachedNicIds = @(
        if ($vm.NetworkProfile.NetworkInterfaces) {
            $vm.NetworkProfile.NetworkInterfaces | ForEach-Object { $_.Id }
        }
    )

    foreach ($nicRef in ($expectedNics | Sort-Object { -not [bool]$_.Primary })) {
        if ($attachedNicIds -contains [string]$nicRef.Id) {
            continue
        }

        Write-Log "Attaching network interface '$($nicRef.Id)' (Primary=$([bool]$nicRef.Primary))"
        if ([bool]$nicRef.Primary) {
            $vm = Add-AzVMNetworkInterface -VM $vm -Id ([string]$nicRef.Id) -Primary
        }
        else {
            $vm = Add-AzVMNetworkInterface -VM $vm -Id ([string]$nicRef.Id)
        }
    }

    Update-AzVM -ResourceGroupName $State.ResourceGroupName -VM $vm | Out-Null
    return (Test-VmNetworkInterfacesMatch -Vm (Get-SourceVm -ResourceGroupName $State.ResourceGroupName -VMName $State.VMName) -ExpectedNetworkInterfaces $expectedNics)
}

function Repair-MissingVmAttachments {
    param([hashtable]$State)

    $nicsOk = Repair-MissingNetworkInterfaces -State $State
    $disksOk = Repair-MissingDataDisks -State $State
    return ($nicsOk -and $disksOk)
}

function Get-SourceState {
    param(
        [string]$ResourceGroupName,
        [string]$VMName,
        [string]$NewSize,
        [string]$SnapshotName,
        [string]$NewOsDiskName,
        [string]$StatePath
    )

    $vm = Get-SourceVm -ResourceGroupName $ResourceGroupName -VMName $VMName
    if (-not $vm) {
        $context = Get-AzContext
        $contextSummary = if ($context) {
            "Current Az context subscription: '$($context.Subscription.Name)' ($($context.Subscription.Id)); tenant: '$($context.Tenant.Id)'."
        }
        else {
            'No Az PowerShell context is currently selected.'
        }
        throw "VM '$VMName' in resource group '$ResourceGroupName' was not found and no state file exists at '$StatePath'. $contextSummary"
    }

    $osDisk = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $vm.StorageProfile.OsDisk.Name
    $zone = $null
    if ($vm.Zones -and $vm.Zones.Count -gt 0) {
        $zone = $vm.Zones[0]
    }

    $securityProfile = $vm.SecurityProfile
    $uefiSettings = if ($securityProfile) { $securityProfile.UefiSettings } else { $null }

    $state = @{
        ResourceGroupName = $ResourceGroupName
        VMName            = $VMName
        NewSize           = $NewSize
        SnapshotName      = $SnapshotName
        NewOsDiskName     = $NewOsDiskName
        OriginalOsDiskId  = $osDisk.Id
        OriginalOsDiskName = $osDisk.Name
        OriginalOsDiskSku = $osDisk.Sku.Name
        OriginalOsDiskStorageAccountType = $vm.StorageProfile.OsDisk.ManagedDisk.StorageAccountType
        NetworkInterfaces = Get-NetworkInterfaceStateFromVm -Vm $vm
        Location          = $vm.Location
        Zone              = $zone
        OsType            = [string]$vm.StorageProfile.OsDisk.OsType
        HyperVGeneration  = Get-OptionalValue $osDisk.HyperVGeneration
        SecurityType      = Get-OptionalValue $(if ($securityProfile) { $securityProfile.SecurityType } else { $null })
        SecureBootEnabled = if ($uefiSettings -and $null -ne $uefiSettings.SecureBootEnabled) { [bool]$uefiSettings.SecureBootEnabled } else { $null }
        VtpmEnabled       = if ($uefiSettings -and $null -ne $uefiSettings.vTpmEnabled) { [bool]$uefiSettings.vTpmEnabled } else { $null }
        LicenseType       = Get-OptionalValue $vm.LicenseType
        Plan              = if ($vm.Plan) {
            @{
                Name      = $vm.Plan.Name
                Product   = $vm.Plan.Product
                Publisher = $vm.Plan.Publisher
            }
        }
        else {
            $null
        }
        SnapshotId        = $null
        NewOsDiskId       = $null
        DataDisks         = Get-DataDiskStateFromVm -Vm $vm
        Completed         = $false
    }

    return $state
}

function Ensure-Snapshot {
    param([hashtable]$State)

    $snapshot = Get-ExistingSnapshot -ResourceGroupName $State.ResourceGroupName -SnapshotName $State.SnapshotName
    if ($snapshot) {
        Write-Log "Reusing existing snapshot '$($State.SnapshotName)'"
        $State.SnapshotId = $snapshot.Id
        return
    }

    Write-Log "Creating snapshot '$($State.SnapshotName)' from original OS disk"
    $snapshotConfig = New-AzSnapshotConfig `
        -Location $State.Location `
        -SourceUri $State.OriginalOsDiskId `
        -CreateOption Copy `
        -SkuName Standard_LRS

    $snapshot = New-AzSnapshot `
        -ResourceGroupName $State.ResourceGroupName `
        -SnapshotName $State.SnapshotName `
        -Snapshot $snapshotConfig

    $State.SnapshotId = $snapshot.Id
}

function Ensure-NewDisk {
    param([hashtable]$State)

    $disk = Get-ExistingDisk -ResourceGroupName $State.ResourceGroupName -DiskName $State.NewOsDiskName
    if ($disk) {
        Write-Log "Reusing existing managed disk '$($State.NewOsDiskName)'"
        $State.NewOsDiskId = $disk.Id
        return
    }

    Write-Log "Creating managed disk '$($State.NewOsDiskName)' from snapshot"
    $diskConfigParams = @{
        Location         = $State.Location
        CreateOption     = 'Copy'
        SourceResourceId = $State.SnapshotId
        SkuName          = $State.OriginalOsDiskSku
        OsType           = $State.OsType
    }

    if ($State.HyperVGeneration) {
        $diskConfigParams.HyperVGeneration = $State.HyperVGeneration
    }
    if ($State.Zone) {
        $diskConfigParams.Zone = @([string]$State.Zone)
    }

    $diskConfig = New-AzDiskConfig @diskConfigParams
    $disk = New-AzDisk `
        -ResourceGroupName $State.ResourceGroupName `
        -DiskName $State.NewOsDiskName `
        -Disk $diskConfig

    Write-Log "Waiting for managed disk '$($State.NewOsDiskName)' to reach ProvisioningState=Succeeded"
    $disk = Wait-ForDiskSucceeded -ResourceGroupName $State.ResourceGroupName -DiskName $State.NewOsDiskName
    $State.NewOsDiskId = $disk.Id
}

function Ensure-SourceVmRemoved {
    param([hashtable]$State)

    if ($State.NewOsDiskId -and (CurrentVmMatchesTarget -ResourceGroupName $State.ResourceGroupName -VMName $State.VMName -ExpectedSize $State.NewSize -ExpectedDiskId $State.NewOsDiskId -ExpectedNetworkInterfaces (Get-StateNetworkInterfaces -State $State) -ExpectedDataDisks $State.DataDisks)) {
        Write-Log "VM already matches the requested size, recreated OS disk, network interfaces, and data disks; skipping deletion"
        $State.Completed = $true
        return
    }

    $vm = Get-SourceVm -ResourceGroupName $State.ResourceGroupName -VMName $State.VMName
    if (-not $vm) {
        Write-Log "Source VM already deleted"
        return
    }

    if ($State.NewOsDiskId -and (Test-VmCoreMatchesTarget -Vm $vm -ExpectedSize $State.NewSize -ExpectedDiskId $State.NewOsDiskId)) {
        Write-Log "Target VM already exists with the requested size and recreated OS disk; skipping deletion"
        return
    }

    if (-not $PSCmdlet.ShouldProcess("$($State.ResourceGroupName)/$($State.VMName)", "Delete VM after setting disk/NIC delete options to Detach")) {
        throw 'Operation cancelled.'
    }

    Write-Log "Setting delete options to Detach for the current VM"
    $vm.StorageProfile.OsDisk.DeleteOption = 'Detach'
    if ($vm.StorageProfile.DataDisks) {
        foreach ($dataDisk in $vm.StorageProfile.DataDisks) {
            $dataDisk.DeleteOption = 'Detach'
        }
    }
    foreach ($nicRef in $vm.NetworkProfile.NetworkInterfaces) {
        $nicRef.DeleteOption = 'Detach'
    }
    Update-AzVM -ResourceGroupName $State.ResourceGroupName -VM $vm | Out-Null

    Write-Log "Deleting VM '$($State.VMName)'"
    Remove-AzVM -ResourceGroupName $State.ResourceGroupName -Name $State.VMName -Force

    do {
        Start-Sleep -Seconds 10
    } while (Get-SourceVm -ResourceGroupName $State.ResourceGroupName -VMName $State.VMName)
}

function New-ReplacementVm {
    param([hashtable]$State)

    if (CurrentVmMatchesTarget -ResourceGroupName $State.ResourceGroupName -VMName $State.VMName -ExpectedSize $State.NewSize -ExpectedDiskId $State.NewOsDiskId -ExpectedNetworkInterfaces (Get-StateNetworkInterfaces -State $State) -ExpectedDataDisks $State.DataDisks) {
        Write-Log "Target VM already exists with the requested size, recreated OS disk, network interfaces, and data disks"
        $State.Completed = $true
        return
    }

    $existingVm = Get-SourceVm -ResourceGroupName $State.ResourceGroupName -VMName $State.VMName
    if ($existingVm) {
        if (Repair-MissingVmAttachments -State $State) {
            Write-Log "Attached missing network interfaces and/or data disks to the existing target VM"
            $State.Completed = $true
            return
        }

        throw "VM '$($State.VMName)' already exists but does not match the expected target state."
    }

    $disk = Get-AzDisk -ResourceGroupName $State.ResourceGroupName -DiskName $State.NewOsDiskName

    if ($disk.ProvisioningState -ne 'Succeeded') {
        $disk = Wait-ForDiskSucceeded -ResourceGroupName $State.ResourceGroupName -DiskName $State.NewOsDiskName
    }

    Write-Log "Creating replacement VM '$($State.VMName)' with size '$($State.NewSize)'"
    $vmConfigParams = @{
        VMName = $State.VMName
        VMSize = $State.NewSize
    }

    if ($State.Zone) {
        $vmConfigParams.Zone = @([string]$State.Zone)
    }
    if ($State.LicenseType) {
        $vmConfigParams.LicenseType = $State.LicenseType
    }
    if ($State.SecurityType -and $State.SecurityType -eq 'TrustedLaunch') {
        $vmConfigParams.SecurityType = 'TrustedLaunch'
        if ($null -ne $State.SecureBootEnabled) {
            $vmConfigParams.EnableSecureBoot = [bool]$State.SecureBootEnabled
        }
        if ($null -ne $State.VtpmEnabled) {
            $vmConfigParams.EnableVtpm = [bool]$State.VtpmEnabled
        }
    }
    elseif ($State.SecurityType -and $State.SecurityType -notin @('TrustedLaunch', 'Standard')) {
        throw "Unsupported source security type '$($State.SecurityType)'."
    }

    $vmConfig = New-AzVMConfig @vmConfigParams
    $networkInterfaces = Get-StateNetworkInterfaces -State $State
    $nicCount = $networkInterfaces.Count
    if ($nicCount -gt 0) {
        Write-Log "Adding $nicCount network interface(s) to replacement VM configuration"
        $vmConfig = Add-NetworkInterfacesToVmConfig -VmConfig $vmConfig -NetworkInterfaces $networkInterfaces
    }
    else {
        throw 'State has no network interfaces to attach to the replacement VM.'
    }

    if ($State.Plan) {
        $vmConfig = Set-AzVMPlan `
            -VM $vmConfig `
            -Name $State.Plan.Name `
            -Product $State.Plan.Product `
            -Publisher $State.Plan.Publisher
    }

    $storageType = if ($State.OriginalOsDiskStorageAccountType) { $State.OriginalOsDiskStorageAccountType } else { $disk.Sku.Name }

    if ($State.OsType -eq 'Windows') {
        $vmConfig = Set-AzVMOSDisk `
            -VM $vmConfig `
            -ManagedDiskId $disk.Id `
            -Name $disk.Name `
            -StorageAccountType $storageType `
            -CreateOption Attach `
            -Windows
    }
    elseif ($State.OsType -eq 'Linux') {
        $vmConfig = Set-AzVMOSDisk `
            -VM $vmConfig `
            -ManagedDiskId $disk.Id `
            -Name $disk.Name `
            -StorageAccountType $storageType `
            -CreateOption Attach `
            -Linux
    }
    else {
        throw "Unsupported OS type '$($State.OsType)'."
    }

    $dataDiskCount = if ($State.DataDisks) { @($State.DataDisks).Count } else { 0 }
    if ($dataDiskCount -gt 0) {
        Write-Log "Adding $dataDiskCount data disk(s) to replacement VM configuration"
        $vmConfig = Add-DataDisksToVmConfig -VmConfig $vmConfig -DataDisks $State.DataDisks
    }

    New-AzVM `
        -ResourceGroupName $State.ResourceGroupName `
        -Location $State.Location `
        -VM $vmConfig | Out-Null

    $State.Completed = $true
}

function Remove-SnapshotIfRequested {
    param(
        [hashtable]$State,
        [switch]$CleanupSnapshot
    )

    if (-not $CleanupSnapshot) {
        return
    }

    $snapshot = Get-ExistingSnapshot -ResourceGroupName $State.ResourceGroupName -SnapshotName $State.SnapshotName
    if (-not $snapshot) {
        return
    }

    Write-Log "Deleting snapshot '$($State.SnapshotName)'"
    Remove-AzSnapshot -ResourceGroupName $State.ResourceGroupName -SnapshotName $State.SnapshotName -Force
}

Assert-Module -Name Az.Accounts
Assert-Module -Name Az.Compute
Assert-Module -Name Az.Network

$null = Get-AzContext

if ($SubscriptionId) {
    Write-Log "Selecting subscription '$SubscriptionId'"
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
}

$sizeSlug = Get-Slug -Value $NewSize
if (-not $SnapshotName) {
    $SnapshotName = "$VMName-os-snap-$sizeSlug"
}
if (-not $NewOsDiskName) {
    $NewOsDiskName = "$VMName-osdisk-$sizeSlug"
}
if (-not $StatePath) {
    $StatePath = ".\$(Get-Slug -Value "$ResourceGroupName-$VMName-$sizeSlug").resize.state.json"
}

$state = Load-State -Path $StatePath
if ($state) {
    Write-Log "Loading existing state from '$StatePath'"
    $sourceVm = Get-SourceVm -ResourceGroupName $ResourceGroupName -VMName $VMName
    $stateUpdated = $false

    if (-not $state.ContainsKey('NetworkInterfaces') -or $null -eq $state.NetworkInterfaces) {
        if ($sourceVm) {
            Write-Log 'State file has no network interface info; capturing NICs from the current VM'
            $state.NetworkInterfaces = Get-NetworkInterfaceStateFromVm -Vm $sourceVm
        }
        elseif ($state.NicId) {
            Write-Log 'State file has legacy NicId only; converting to NetworkInterfaces'
            $state.NetworkInterfaces = @(
                @{
                    Id      = [string]$state.NicId
                    Primary = $true
                }
            )
        }
        else {
            $state.NetworkInterfaces = @()
        }
        $stateUpdated = $true
    }

    if (-not $state.ContainsKey('DataDisks') -or $null -eq $state.DataDisks) {
        if ($sourceVm) {
            Write-Log 'State file has no data disk info; capturing data disks from the current VM'
            $state.DataDisks = Get-DataDiskStateFromVm -Vm $sourceVm
        }
        else {
            $state.DataDisks = @()
        }
        $stateUpdated = $true
    }

    if ($stateUpdated) {
        Save-State -State $state -Path $StatePath
    }
}
else {
    Write-Log 'Capturing source VM state'
    $state = Get-SourceState `
        -ResourceGroupName $ResourceGroupName `
        -VMName $VMName `
        -NewSize $NewSize `
        -SnapshotName $SnapshotName `
        -NewOsDiskName $NewOsDiskName `
        -StatePath $StatePath
    Save-State -State $state -Path $StatePath
}

Ensure-Snapshot -State $state
Save-State -State $state -Path $StatePath

Ensure-NewDisk -State $state
Save-State -State $state -Path $StatePath

Ensure-SourceVmRemoved -State $state
Save-State -State $state -Path $StatePath

New-ReplacementVm -State $state
Save-State -State $state -Path $StatePath

Remove-SnapshotIfRequested -State $state -CleanupSnapshot:$CleanupSnapshot

Write-Host ''
Write-Host 'Completed successfully.'
Write-Host ''
Write-Host ("Resource group : {0}" -f $state.ResourceGroupName)
Write-Host ("VM name        : {0}" -f $state.VMName)
Write-Host ("New size       : {0}" -f $state.NewSize)
$networkInterfaces = Get-StateNetworkInterfaces -State $state
Write-Host ("Network IFs    : {0}" -f $networkInterfaces.Count)
foreach ($nic in ($networkInterfaces | Sort-Object { -not [bool]$_.Primary })) {
    Write-Host ("                 Primary={0} -> {1}" -f $nic.Primary, $nic.Id)
}
Write-Host ("Original OS    : {0}" -f $state.OriginalOsDiskId)
Write-Host ("New OS disk    : {0}" -f $state.NewOsDiskId)
Write-Host ("Data disks     : {0}" -f $(if ($state.DataDisks) { @($state.DataDisks).Count } else { 0 }))
if ($state.DataDisks) {
    foreach ($dataDisk in ($state.DataDisks | Sort-Object { [int]$_.Lun })) {
        Write-Host ("                 LUN {0} -> {1}" -f $dataDisk.Lun, $dataDisk.DiskId)
    }
}
Write-Host ("Snapshot       : {0}" -f $state.SnapshotName)
Write-Host ("State file     : {0}" -f $StatePath)
