<#
.SYNOPSIS
    Upgrades all attached public IP addresses on a VM to Standard SKU.
.DESCRIPTION
    This script upgrades the Public IP Addresses attached to VM to Standard SKU. In order to perform the upgrade, the Public IP Address
    allocation method is set to static before being disassociated from the VM. Once disassociated, the Public IP SKU is upgraded to Standard,
    then the IP is reassociated with the VM. 

    Because the Public IP allocation is set to 'Static' before detaching from the VM, the IP address will not change during the upgrade process,
    even in the event of a script failure.

    Recovering from a failure:
    The script exports the Public IP address and IP configuration associations to a CSV file before beginning the upgrade process. In the event
    of a fauilure during the upgrade, this file can be used to manually reassociate any detached public IPs with the appropriate IP configuration.
.NOTES
    VMs must not be associated with a Load Balancer to use this script
.LINK
    
.EXAMPLE
    ./Start-VMPublicIPUpgrade.ps1 -VMName 'myVM' -ResourceGroupName 'myRG'
    Upgrade a single VM, passing the VM name and resource group name as parameters. 

.EXAMPLE
    ./Start-VMPublicIPUpgrade.ps1 -VMName 'myVM' -ResourceGroupName 'myRG' -WhatIf
    Evaluate upgrading a single VM, without making any changes

.EXAMPLE
    ./Start-VMPublicIPUpgrade.ps1 -VMResourceId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/myRG/providers/Microsoft.Compute/virtualMachines/myVM'
    Upgrade a single VM, passing the VM resource ID as a parameter.

.EXAMPLE
    Get-AzVM -ResourceGroupName 'myRG' | ./Start-VMPublicIPUpgrade.ps1
    Upgrade all VMs in a resource group, piping the VM objects to the script.
#>

param (
    # vm name
    [Parameter(Mandatory = $true, ParameterSetName = 'VMName')]
    [string]
    $vmName,

    # vm resource group name
    [Parameter(Mandatory = $true, ParameterSetName = 'VMName')]
    [string]
    $resourceGroupName,

    # vm object
    [Parameter(Mandatory = $true, ParameterSetName = 'VMObject', ValueFromPipeline = $true)]
    [Microsoft.Azure.Commands.Compute.Models.PSVirtualMachine]
    $VM,

    # vm resource id
    [Parameter(Mandatory = $true, ParameterSetName = 'VMResourceId')]
    [string]
    $vmResourceId,

    # recovery log file path - log Public IP address and IP configuration associations for manual recovery scenario
    [Parameter(Mandatory = $false)]
    [string]
    $recoveryLogFilePath = "PublicIPUpgrade_Recovery_$(Get-Date -Format 'yyyy-MM-dd-HH-mm').csv",

    # whatif
    [switch]
    $WhatIf
)

BEGIN {
    Write-Host "Starting VM Public IP Upgrade process..."

    If (!$WhatIf) {
        While ($promptResponse -notmatch '[yYnN]') {
            $promptResponse = Read-Host "This script will upgrade all public IP addresses attached to the specified VM or VMs to Standard SKU. This will cause a brief interruption to network connectivity. Do you want to continue? (y/n)"
        }
        
        If ($promptResponse -match '[nN]') {
            Write-Host "Exiting script..."
            Exit
        }
        Else {
            Write-Host "Continuing with script..."
        }
    }
}

PROCESS {
    If ($WhatIf) { $ErrorActionPreference = 'Continue' }
    Else { 
        $ErrorActionPreference = 'Stop' 
    }

# get vm object, depending on parameters passed
    If ($PSCmdlet.ParameterSetName -eq 'VMName') {
        Write-Host "Getting VM '$($VMName)' in resource group '$(resourceGroupName)'..."
        $VM = Get-AzVM -Name $vmName -ResourceGroupName $resourceGroupName
    }
    ElseIf ($PSCmdlet.ParameterSetName -eq 'VMResourceId') {
        Write-Host "Getting VM with resource ID '$($vmResourceId)'..."
        $VM = Get-AzResource -ResourceId $vmResourceId
    }

# validate scenario
    # confirm VM has public IPs attached, build dictionary of public IPs and ip configurations
    Write-Host "Checking that VM '$($VM.Name)' has public IP addresses attached..."
    $vmNICs = $VM.NetworkProfile.NetworkInterfaces | Get-AzResource | Get-AzNetworkInterface
    $publicIPIDs = @()
    $publicIPIPConfigAssociations = @()
    ForEach ($ipConfig in $vmNICs.IpConfigurations) {
        If ($ipConfig.PublicIPAddress) {
            $publicIPIDs += $ipConfig.PublicIPAddress.id
            $publicIPIPConfigAssociations += @{
                publicIPId = $ipConfig.PublicIPAddress.id
                ipConfig = $ipConfig
                publicIPAddress = ''}
        }
    }

    If ($publicIPIPConfigAssociations.count -lt 1) {
        Write-Warning "VM '$($VM.Name)' does not have any public IP addresses attached."
        return
    }
    Else {
        Write-Host "VM '$($VM.Name)' has $($publicIPIPConfigAssociations.count) public IP addresses attached."
    }
    
    # confirm public IPs are Basic SKU (VM should only have one SKU)
    Write-Host "Checking that VM '$($VM.Name)' has Basic SKU public IP addresses..."
    $publicIPs = $publicIPIDs | ForEach-Object { Get-AzResource -ResourceId $_ | Get-AzPublicIpAddress }
    If (( $publicIPSKUs = $publicIPs.Sku.Name | Get-Unique) -ne @('Basic')) {
        Write-Warning "Public IP address SKUs for VM '$($VM.Name)' are not Basic: $($publicIPSKUs -join ',')"
        return
    }

    # confirm VM is not associated with a load balancer
    Write-Host "Checking that VM '$($VM.Name)' is not associated with a load balancer..."
    If ($VMNICs.IpConfigurations.LoadBalancerBackendAddressPools -or $VMNICs.IpConfigurations.LoadBalancerInboundNatRules) {
        Write-Warning "VM '$($VM.Name)' is associated with a load balancer. The Load Balancer cannot be a different SKU from the VM's Public IP address(s) and must be upgraded simultaneously. See: https://learn.microsoft.com/azure/load-balancer/load-balancer-basic-upgrade-guidance"
        return
    }

# start upgrade process
    # export recovery data
    ForEach ($publicIP in $publicIPs) {
        $publicIPIPConfigAssociations | Where-Object { $_.publicIPId -eq $publicIP.id } | ForEach-Object { 
            $_.publicIPAddress = $publicIP.IpAddress 
            
            Add-Content -Path $recoveryLogFilePath -Value ('{0},{1},{2}' -f $_.publicIPAddress,$_.publicIPId,$_.ipConfig.id) -Force
        }
    }

    try {
        # set all public IPs to static assignment
        Write-Host "Setting all public IP addresses to static assignment..."
        $publicIPs | ForEach-Object {
            Write-Host "`tSetting public IP address '$($_.Name)' ('$($_.IpAddress)') to static assignment..."
            $_.PublicIpAllocationMethod = 'Static'

            If (!$WhatIf) {
                Set-AzPublicIpAddress -PublicIpAddress $_ | Out-Null
            }
            Else {
                Write-Host "`tWhatIf: Set-AzPublicIpAddress -PublicIpAddress $($_.id)"
            }
        }

        # disassociate all public IPs from the VM
        Write-Host "Disassociating all public IP addresses from the VM..."
        Foreach ($nic in $vmNICs) {
            ForEach ($ipConfig in $nic.IpConfigurations | Where-Object { $_.PublicIPAddress }) {
                Write-Host "`tDisassociating public IP address '$($ipConfig.PublicIpAddress.Id)' from VM '$($VM.Name)'..."

                Set-AzNetworkInterfaceIpConfig -NetworkInterface $nic -Name $ipConfig.Name -PublicIpAddress $null | Out-Null
            }

            Write-Host "`Applying updates to the NIC..."
            If (!$WhatIf){
                $nic | Set-AzNetworkInterface | Out-Null
            }
            Else {
                Write-Host "`tWhatIf: Updating NIC with: `$nic | Set-AzNetworkInterface"
            }
        }

        # upgrade all public IP addresses
        Write-Host "Upgrading all public IP addresses to Standard SKU..."
        ForEach ($publicIP in $publicIPs) {
            Write-Host "`tUpgrading public IP address '$($publicIP.Name)' to Standard SKU..."
            $publicIP.Sku.Name = 'Standard'

            If (!$WhatIf) {
                Set-AzPublicIpAddress -PublicIpAddress $publicIP | Out-Null
            }
            Else {
                Write-Host "`tWhatIf: Set-AzPublicIpAddress -PublicIpAddress $($_.id)"
            }
        }
    }
    catch {
        Write-Error "An error occurred during the upgrade process. We will try to reassociate all IPs with the VM: $_"
    }
    finally {
        # always reassociate all public IPs to the VM
        Write-Host "Reassociating all public IP addresses to the VM..."
        Foreach ($nic in $vmNICs) {
            ForEach ($i in ($publicIPIPConfigAssociations.ipConfig | Where-Object {$_.Id -like "$($nic.Id)*"})) {
                Write-Host "`tReassociating public IP address '$($assn.publicIPId)' to VM '$($VM.Name)'..."

                Set-AzNetworkInterfaceIpConfig -NetworkInterface $nic -Name $ipConfig.Name -PublicIpAddress $assn.publicIPId | Out-Null
            }
        }

        Write-Host "`Applying updates to the NIC..."
        If (!$WhatIf) {
            $nic | Set-AzNetworkInterface | Out-Null
        }
        Else {
            Write-Host "`tWhatIf: Updating NIC with: `$nic | Set-AzNetworkIntereface"
        }
    }
}

END {
    Write-Host "Upgrade process complete."
}