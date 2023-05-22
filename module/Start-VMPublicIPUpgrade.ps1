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
    of a failure during the upgrade, this file can be used to manually reassociate any detached public IPs with the appropriate IP configuration.
        1. Check that IPs to reassociate are all 'Standard' SKU--upgrade if not
        2. Attach associate each public IP to the listed IP configuration
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
    [Parameter(Mandatory = $true, ParameterSetName = 'Recovery')]
    [string]
    $vmResourceId,

    # vm resource id
    [Parameter(Mandatory = $true, ParameterSetName = 'Recovery')]
    [string]
    $recoverFromFile,

    # recovery log file path - log Public IP address and IP configuration associations for manual recovery scenario
    [Parameter(Mandatory = $false)]
    [string]
    $recoveryLogFilePath = "PublicIPUpgrade_Recovery_$(Get-Date -Format 'yyyy-MM-dd-HH-mm').csv",

    # log file path
    [Parameter(Mandatory = $false)]
    [string]
    $logFilePath = "PublicIPUpgrade.log",

    # skip prompt for confirmation
    [Parameter(Mandatory = $false)]
    [switch]
    $Force,

    # whatif
    [switch]
    $WhatIf
)

BEGIN {
    Function Add-LogEntry {
        param (
            [parameter(Position = 0, Mandatory = $true)]$message,
            [parameter(Position = 1, Mandatory = $false)][ValidateSet('INFO', 'WARNING', 'ERROR')]$severity = 'INFO'
        )

        # add timestamp to message, output to log and host
        switch ($severity) {
            'INFO' { "[{0}][{1}] {2}" -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszz'), $severity, $message | Tee-Object -FilePath $logFilePath -Append | Write-Host }
            'WARNING' { "[{0}][{1}] {2}" -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszz'), $severity, $message | Tee-Object -FilePath $logFilePath -Append | Write-Warning }
            'ERROR' { "[{0}][{1}] {2}" -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszz'), $severity, $message | Tee-Object -FilePath $logFilePath -Append | Write-Error }
        }
    }
    
    Add-LogEntry "Starting VM Public IP Upgrade process..."

    # prompt to continue if -Force or -WhatIf are not specified
    If (!$WhatIf -and !$Force) {
        While ($promptResponse -notmatch '[yYnN]') {
            $promptResponse = Read-Host "This script will upgrade all public IP addresses attached to the specified VM or VMs to Standard SKU. This will cause a brief interruption to network connectivity. Do you want to continue? (y/n)"
        }
        
        If ($promptResponse -match '[nN]') {
            Add-LogEntry "Exiting script..." -severity WARNING
            Exit
        }
        Else {
            Add-LogEntry "Continuing with script..."
        }
    }

    # initalize recovery log file
    Add-Content -Path $recoveryLogFilePath -Value 'publicIPAddress,publicIPID,ipConfigId,VMId' -Force

    Add-LogEntry "Creating recovery log file at '$($recoveryLogFilePath)'"
}

PROCESS {
    # set error action preference 
    If ($WhatIf) { $ErrorActionPreference = 'Continue' }
    Else { $ErrorActionPreference = 'Stop' }

    # get vm object, depending on parameters passed
    If ($PSCmdlet.ParameterSetName -eq 'VMName') {
        Add-LogEntry "Getting VM '$($VMName)' in resource group '$(resourceGroupName)'..."
        $VM = Get-AzVM -Name $vmName -ResourceGroupName $resourceGroupName
    }
    ElseIf ($PSCmdlet.ParameterSetName -in 'VMResourceId', 'Recovery') {
        Add-LogEntry "Getting VM with resource ID '$($vmResourceId)'..."
        $VM = Get-AzResource -ResourceId $vmResourceId | Get-AzVM
    }

    Add-LogEntry "Processing VM '$($VM.Name)'..."
    # validate scenario

    If ($PSCmdlet.ParameterSetName -ne 'Recovery') {
        # confirm VM has public IPs attached, build dictionary of public IPs and ip configurations
        Add-LogEntry "Checking that VM '$($VM.Name)' has public IP addresses attached..."
        $vmNICs = $VM.NetworkProfile.NetworkInterfaces | Get-AzResource | Get-AzNetworkInterface
        $publicIPIDs = @()
        $publicIPIPConfigAssociations = @{}
        ForEach ($ipConfig in $vmNICs.IpConfigurations) {
            If ($ipConfig.PublicIPAddress) {
                $publicIPIDs += $ipConfig.PublicIPAddress.id
                $publicIPIPConfigAssociations[$ipConfig.PublicIPAddress.id] = @{
                    publicIPId      = $ipConfig.PublicIPAddress.id
                    ipConfig        = $ipConfig
                    publicIP        = ''
                    publicIPAddress = ''
                }
            }
        }

        If ($publicIPIPConfigAssociations.count -lt 1) {
            Add-LogEntry "VM '$($VM.Name)' does not have any public IP addresses attached." -severity WARNING
            return
        }
        Else {
            Add-LogEntry "VM '$($VM.Name)' has $($publicIPIPConfigAssociations.count) public IP addresses attached."
        }
    
        # confirm public IPs are Basic SKU (VM should only have one SKU)
        Add-LogEntry "Checking that VM '$($VM.Name)' has Basic SKU public IP addresses..."
        $publicIPs = $publicIPIDs | ForEach-Object { Get-AzResource -ResourceId $_ | Get-AzPublicIpAddress }
        If (( $publicIPSKUs = $publicIPs.Sku.Name | Get-Unique) -ne @('Basic')) {
            Write-Warning "Public IP address SKUs for VM '$($VM.Name)' are not Basic: $($publicIPSKUs -join ',')"
            return
        }

        # confirm VM is not associated with a load balancer
        Add-LogEntry "Checking that VM '$($VM.Name)' is not associated with a load balancer..."
        If ($VMNICs.IpConfigurations.LoadBalancerBackendAddressPools -or $VMNICs.IpConfigurations.LoadBalancerInboundNatRules) {
            Write-Warning "VM '$($VM.Name)' is associated with a load balancer. The Load Balancer cannot be a different SKU from the VM's Public IP address(s) and must be upgraded simultaneously. See: https://learn.microsoft.com/azure/load-balancer/load-balancer-basic-upgrade-guidance"
            return
        }
    }
    Else {
        ### Failed Migration Recovery ###
        # import recovery info
        Add-LogEntry "Importing recovery file for VM '$($VM.Name)' from file '$($recoverFromFile)'"

        $recoveryInfo = Import-Csv -path $recoverFromFile | Where-Object { $_.VMId -eq $VM.Id }

        Add-LogEntry "Building recovery objects for VM '$($VM.Name)' based on recovery file '$($recoverFromFile)'..."
        # rebuild migration objects from recovery to retry
        $publicIPIDs = $recoveryInfo.PublicIPID

        $vmNICs = @()
        $vmNICsById = @{}
        $recoveryInfo.ipConfigId | 
            ForEach-Object { ($_ -split '/ipConfigurations/')[0] } | 
                Select-Object -Unique | 
                ForEach-Object { $_ | Get-AzNetworkInterface } |
                    ForEach-Object { 
                        $vmNICs += $_ 
                        $vmNICsById[$_.id] = $_
                        }

        $publicIPIPConfigAssociations = @{}
        ForEach ($recoveryItem in $recoveryInfo) {
            $ipConfigSplit = $recoveryItem.ipConfigId -split '/ipConfigurations/'
            $publicIPIDs += $ipConfig.PublicIPAddress.id
            $publicIPIPConfigAssociations[$recoveryItem.publicIPID] = @{
                publicIPId      = $recoveryItem.publicIPID
                ipConfig        = Get-AzNetworkInterfaceIpConfig -NetworkInterface $vmNICsById[$ipConfigSplit[0]] -Name $ipConfigSplit[1]
                publicIP        = Get-AzResource -ResourceId $recoveryItem.publicIPID | Get-AzPublicIpAddress
                publicIPAddress = $recoveryItem.publicIPAddress
            }
        }

        $publicIPs = $publicIPIPConfigAssociations.publicIP
    }

    # start upgrade process
    # export recovery data and add public ip object to assocation object
    ForEach ($publicIP in $publicIPs) {
        $publicIPIPConfigAssociations[$publicIP.id].publicIPAddress = $publicIP.IpAddress
        $publicIPIPConfigAssociations[$publicIP.id].publicIP = $publicIP 
        
        Add-Content -Path $recoveryLogFilePath -Value ('{0},{1},{2},{3}' -f $publicIP.publicIPAddress, $publicIP.id, $publicIPIPConfigAssociations[$publicIP.id].ipConfig.id, $VM.Id) -Force
    }

    try {
        # set all public IPs to static assignment
        Add-LogEntry "Setting all public IP addresses to static assignment..."
        ForEach ($publicIPId in $publicIPIPConfigAssociations.Keys) {
            $publicIP = $publicIPIPConfigAssociations[$publicIPId].PublicIP

            Add-LogEntry "Setting public IP address '$($publicIP.Name)' ('$($publicIP.IpAddress)') to static assignment..."
            $publicIP.PublicIpAllocationMethod = 'Static'

            If (!$WhatIf) {
                Set-AzPublicIpAddress -PublicIpAddress $publicIP | Out-Null
            }
            Else {
                Add-LogEntry "WhatIf: Set-AzPublicIpAddress -PublicIpAddress $($publicIP.id)"
            }
        }

        # disassociate all public IPs from the VM
        Add-LogEntry "Disassociating all public IP addresses from the VM..."
        Foreach ($nic in $vmNICs) {
            ForEach ($ipConfig in $nic.IpConfigurations | Where-Object { $_.PublicIPAddress }) {
                Add-LogEntry "Confirming that Public IP allocation is 'static' before disassociating..."
                If ((Get-AzResource -ResourceId $ipConfig.PublicIpAddress.Id | Get-AzPublicIpAddress).PublicIpAllocationMethod -ne 'Static') {
                    Write-Error "Public IP address '$($ipConfig.PublicIpAddress.Id)' is not set to static allocation! Script will exit to ensure that the VM's public IP addresses are not lost."
                }
                Add-LogEntry "Disassociating public IP address '$($ipConfig.PublicIpAddress.Id)' from VM '$($VM.Name)', NIC '$($nic.Name)'..."
                Set-AzNetworkInterfaceIpConfig -NetworkInterface $nic -Name $ipConfig.Name -PublicIpAddress $null | Out-Null
            }

            Add-LogEntry "Applying updates to the NIC '$($nic.Name)'..."
            If (!$WhatIf) {
                $nic | Set-AzNetworkInterface | Out-Null
            }
            Else {
                Add-LogEntry "WhatIf: Updating NIC with: `$nic | Set-AzNetworkInterface"
            }
        }

        # upgrade all public IP addresses
        Add-LogEntry "Upgrading all public IP addresses to Standard SKU..."
        ForEach ($publicIPId in $publicIPIPConfigAssociations.Keys) {
            $publicIP = $publicIPIPConfigAssociations[$publicIPId].PublicIP
            
            Add-LogEntry "Upgrading public IP address '$($publicIP.Name)' to Standard SKU..."
            $publicIP.Sku.Name = 'Standard'

            If (!$WhatIf) {
                Set-AzPublicIpAddress -PublicIpAddress $publicIP | Out-Null
            }
            Else {
                Add-LogEntry "WhatIf: Set-AzPublicIpAddress -PublicIpAddress $($_.id)"
            }
        }
    }
    catch {
        Write-Error "An error occurred during the upgrade process. We will try to reassociate all IPs with the VM: $_"
    }
    finally {
        # always reassociate all public IPs to the VM
        Add-LogEntry "Reassociating all public IP addresses to the VM..."
        Foreach ($nic in $vmNICs) {
            ForEach ($assocation in ($publicIPIPConfigAssociations | Where-Object { $_.ipconfig.Id -like "$($nic.Id)/*" })) {
                Add-LogEntry "Reassociating public IP address '$($assocation.publicIPId)' to VM '$($VM.Name)', NIC '$($nic.Name)'..."
                Set-AzNetworkInterfaceIpConfig -NetworkInterface $nic -Name $assocation.ipConfig.Name -PublicIpAddress $assocation.publicIP | Out-Null
            }

            Add-LogEntry "Applying updates to the NIC '$($nic.Name)'..."
            If (!$WhatIf) {
                $nic | Set-AzNetworkInterface | Out-Null
            }
            Else {
                Add-LogEntry "WhatIf: Updating NIC with: `$nic | Set-AzNetworkIntereface"
            }
        }

        Add-LogEntry "Applying updates to the NIC '$($nic.Name)'..."
        If (!$WhatIf) {
            $nic | Set-AzNetworkInterface | Out-Null
        }
        Else {
            Add-LogEntry "WhatIf: Updating NIC with: `$nic | Set-AzNetworkIntereface"
        }
    }

    Add-LogEntry "Upgrade of VM '$($VM.Name)' complete.'"
}

END {
    Add-LogEntry "Upgrade process complete."
}