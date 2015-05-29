$NetworkNumber = 3
$vmname = "DC1-DOT"+$NetworkNumber
$template = Get-Template "Win2012 Template for DC Builder"
$datastore = Get-DatastoreCluster -Name "DatastoreCluster - NFS"
$spec = Get-OSCustomizationSpec "Dot3 of Network-config DC Windows 2012"
$rpool = Get-ResourcePool -Name "Resources"
$vmhost = "w3r6c1-tm-h360-04.pml.local"
$cluster = get-cluster -name "Infra-Cluster"
$folder = Get-Folder -Name "Dot3 Network"
$RunOnce = "%systemroot%\system32\WindowsPowershell\v1.0\Powershell.exe -executionpolicy bypass -file \\10.144.107.17\vLAB\DC-Builder.ps1 -NetworkNumber $NetworkNumber"
$vmspec = Get-OSCustomizationSpec -Name "Dot3 of Network-config DC Windows 2012" | Set-OSCustomizationSpec -GuiRunOnce $RunOnce

Write-Host "Creating VM $vmname"

New-VM -Name $vmname -Template $template -vmhost $vmhost  -Location $folder `
        -Datastore $datastore -ResourcePool $rpool 

Write-Host "Moving $vmname to $NetworkName"
Get-VM $vmname |Get-NetworkAdapter|Set-NetworkAdapter -NetworkName $NetworkName  -confirm:$false 

Write-Host "Setting memory and customization spec on $vmname"
Get-VM $vmname | Set-VM -MemoryMB 2048 
#-OSCustomizationSpec $vmspec -Confirm:$false


Write-Host "Starting VM $vmname"
#|Start-VM $vmname