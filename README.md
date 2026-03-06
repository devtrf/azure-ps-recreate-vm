# Resize-VmTempDisk

A PowerShell script that resizes an Azure VM to a size that supports a local/temp disk by rebuilding it from a snapshot of its existing OS disk.

## Why This Script Exists

Azure doesn't support in-place resizing between VM families that differ in temp-disk support (e.g., moving from a `_v4` Standard that has no temp disk to a `ds_v5` that does). The only path is to delete and recreate the VM. This script automates that process safely, preserving the NIC, OS disk content, zone placement, license type, marketplace plan, and Trusted Launch settings.

## Prerequisites

- PowerShell 7+
- Az PowerShell modules: `Az.Accounts`, `Az.Compute`, `Az.Network`
- An active Az PowerShell context (`Connect-AzAccount`) with sufficient permissions to manage VMs, disks, and snapshots in the target resource group

## How It Works

The script runs through these steps in order, saving state to a local JSON file after each one:

1. **Capture** — Reads the source VM's configuration and saves it to a state file
2. **Snapshot** — Creates a snapshot of the current OS disk (`Standard_LRS`)
3. **New disk** — Creates a new managed disk from the snapshot, matching the original SKU and zone
4. **Delete VM** — Sets delete options to `Detach` on the NIC and OS disk, then deletes the VM
5. **Recreate VM** — Creates the VM under the new size, attaching the new OS disk and existing NIC
6. **Cleanup** *(optional)* — Deletes the snapshot if `-CleanupSnapshot` was specified

## Rerun Safety

State is persisted to a local `.resize.state.json` file after each step. If the script is interrupted, rerunning it with the same parameters will pick up where it left off rather than starting over. If the target VM already exists with the correct size and disk, the script exits cleanly without making changes.

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `-ResourceGroupName` | ✅ | Resource group containing the VM |
| `-VMName` | ✅ | Name of the VM to resize |
| `-NewSize` | ✅ | Target VM size (e.g. `Standard_D4ds_v5`) |
| `-SubscriptionId` | | Azure subscription ID to select before running |
| `-SnapshotName` | | Override the auto-generated snapshot name |
| `-NewOsDiskName` | | Override the auto-generated OS disk name |
| `-StatePath` | | Override the auto-generated state file path |
| `-CleanupSnapshot` | | Delete the snapshot after a successful run |
| `-Confirm:$false` | | Skip the deletion confirmation prompt |
| `-WhatIf` | | Preview actions without making changes |

Default names are derived from the VM name and target size slug, e.g.:
- Snapshot: `vmtest-os-snap-standard-d4ds-v5`
- New OS disk: `vmtest-osdisk-standard-d4ds-v5`
- State file: `.\tfvmex-resources-vmtest-standard-d4ds-v5.resize.state.json`

## Usage

**Basic — interactive confirmation:**
```powershell
.\Resize-VmTempDisk.ps1 -ResourceGroupName tfvmex-resources -VMName vmtest -NewSize Standard_D4ds_v5
```

**With subscription selection, skip confirmation, and snapshot cleanup:**
```powershell
.\Resize-VmTempDisk.ps1 `
  -SubscriptionId 00000000-0000-0000-0000-000000000000 `
  -ResourceGroupName tfvmex-resources `
  -VMName vmtest `
  -NewSize Standard_D4ds_v5 `
  -CleanupSnapshot `
  -Confirm:$false
```

**Preview only (no changes made):**
```powershell
.\Resize-VmTempDisk.ps1 -ResourceGroupName tfvmex-resources -VMName vmtest -NewSize Standard_D4ds_v5 -WhatIf
```

## What Is Preserved

| Property | Preserved |
|---|---|
| Network interface (NIC) | ✅ |
| OS disk contents (via snapshot) | ✅ |
| Availability zone | ✅ |
| OS disk SKU | ✅ |
| HyperV generation | ✅ |
| Windows Server / AHUB license type | ✅ |
| Marketplace plan (publisher/offer/SKU) | ✅ |
| Trusted Launch (Secure Boot, vTPM) | ✅ |
| Data disks | ❌ Reattach manually after the run |
| Availability set | ❌ Not compatible with resize workflow |
| Diagnostics / extensions | ❌ Reconfigure after the run |

## What Gets Left Behind

The original OS disk and snapshot are **not** deleted automatically (unless `-CleanupSnapshot` is passed for the snapshot). You can delete them manually once you've verified the new VM is healthy.

## Supported VM Configurations

- Windows and Linux VMs
- Zonal and non-zonal VMs
- Standard and Trusted Launch security types
- Marketplace image VMs with a purchase plan

Confidential VM security types are not supported and will cause the script to throw an error.