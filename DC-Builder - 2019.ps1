<#
This script should be run from the Administrator account of a new Windows Server
It requires Powershell V4.0 and will not work on Windows 2003
This WILL reboot the system a couple of times as it installs and configures different
components.

#>
#Inspiration came from the following blog article. Many errors were hopefully corrected.
# http://www.diyitshop.com/2013/04/17/windows-server-2012-setting-up-a-domain-controller-with-powershell/
#
#

Param(
[string]$NetworkNumber        = "1",
[string]$Networkbase          = "192.168."+$NetworkNumber,
[string]$SystemName           = "DC1",
[string]$DomainName           = "lab"+$NetworkNumber,
[string]$NetworkPrefixLength  = "24",
[string]$SetDNSSuffix         = "lab"+$NetworkNumber+".local",
[string]$CACommonName         = $SetDNSSuffix + " Root CA",
[string]$AdminPassword        = "VMware1!",
[string]$IPAddress            = "192.168."+$NetworkNumber+".10",
[string]$Gateway              = "192.168."+$NetworkNumber+".252",
[string]$DNSServerList        = "192.168."+$NetworkNumber+".1,127.0.0.1",
[string]$NetworkID            = “192.168."+$NetworkNumber+".0/24",
[string]$ReverseZoneFile      = $NetworkNumber+"168.192.in-addr.arpa.dns"
)
Start-Transcript -path c:\dc-builder-transcript.txt

#Create informative messages
$Date = Get-Date
$Scriptout = "$date  " + "DCBuilderScript-Info-"

#Static Variables. Change as necessary



#Let's get started by renaming the system and setting up the network adapter
Write-host $Scriptout"Rename system"
Rename-Computer -NewName $SystemName


Get-NetAdapter -Physical

Write-host $Scriptout"Re-IP Network Interface"
$Nic = Get-NetAdapter
$ifIndex = $Nic.ifIndex
Get-NetAdapter -InterfaceIndex $ifIndex | Rename-NetAdapter -NewName "Local Network"
New-NetIPAddress -IPAddress $IPAddress -DefaultGateway $Gateway `
    -PrefixLength $NetworkPrefixLength -InterfaceIndex ifIndex

Write-host $Scriptout"SetDNS"
Set-DnsClientServerAddress -InterfaceIndex $ifIndex `
    -ServerAddresses $DNSServerList

Write-host $Scriptout"SetDNSSuffix"
Set-DNSClient -InterfaceIndex $ifIndex -ConnectionSpecificSuffix $SetDNSSuffix `
    -RegisterThisConnectionsAddress $true -UseSuffixWhenRegistering $true

Write-host $Scriptout"EnableWINS"
Invoke-CimMethod -ClassName Win32_NetworkAdapterConfiguration -MethodName `
    EnableWINS -Arguments @{DNSEnabledForWINSResolution = $false; `
    WINSEnableLMHostsLookup = $false}

#NetBios over TCP didn't seem to be on the system
#Get-CimInstance win32_networkadapterconfiguration `
#    -Filter ‘servicename = “netvsc”‘ | Invoke-CimMethod `
#    -MethodName settcpipnetbios -Arguments @{TcpipNetbiosOptions = 2}

Write-host $Scriptout"NewVolumeLabel"
Set-volume -driveletter c -newfilesystemlabel System

#Change CD drive to "Z:"
#Code from http://www.vinithmenon.com/2012/10/change-cd-rom-drive-letter-in-newly.html
#
Write-host $Scriptout"ChangeCDDriveLetter"
(gwmi Win32_cdromdrive).drive | `
    %{$a = mountvol $_ /l;mountvol $_ /d;$a = $a.Trim();mountvol z: $a}

Get-CimInstance Win32_Volume -Filter ‘drivetype = 5' | `
Set-CimInstance -Arguments @{driveletter = “Z:”}

Write-host $Scriptout"CreateInstallFolder"
New-item c:\installdvd -ItemType directory

#Get-WindowsEdition -Online

Write-host $Scriptout"Ensure the Windows Server ISO is mounted to the CD drive"
$Error.Clear()
Get-WindowsImage -ImagePath z:\sources\install.wim
if ($error.Count -eq 0)
        {
        write-host "Windows Server Install.wim was successfully found. Continuing..." 0 "full"
        }
    else
        {
        write-host "Ensure that the Windows Server DVD is connected to this VM. Looping for 5 minutes..."
        #nice little while loop from http://mjolinor.wordpress.com/2012/01/14/making-a-timed-loop-in-powershell/
        $timeout = new-timespan -Minutes 5
        $sw = [diagnostics.stopwatch]::StartNew()
        while ($sw.elapsed -lt $timeout){
        if (test-path z:\sources\install.wim){
        write-host $scriptout"Found a z:\sources\install.wim. Continuing with the build"
        return
        }

    start-sleep -seconds 5
}

write-host $scriptout"I waited for 5 minutes for you to mount the Windows Server ISO. I have timed out. Try again"
Exit

        }

Write-host $Scriptout"MountInstallImage"
Mount-windowsimage -imagepath z:\sources\install.wim -index 3 -path c:\installdvd -readonly

Write-host $Scriptout"InstallADandDNS"
Install-Windowsfeature AD-Domain-Services -IncludeManagementTools
Install-WindowsFeature DNS -IncludeManagementTools `
    -Source C:\installdvd\Windows\WinSxS
dismount-windowsimage -path c:\installdvd -discard

#Make sure the Administrator account has a password. Ran into a situation
#building a Windows Server VM using Fusion and the Administrator account password
#was blank.
#Change password with this script block
#
Write-host $Scriptout"ChangeAdminPassword"
$comp=hostname
([adsi]"WinNT://$comp/Administrator").SetPassword($AdminPassword)

#
#([adsi]“WinNT://<Local or Remote Computer Name>/<Username>”).SetPassword(“<Password>”)
#

#Time to create all the PS1 and Bat files that will get called after reboots.
#Create the .bat file to run from RunOnce. Note that you need to use -encoding ASCII
#otherwise it chokes. .BAT files can't be UTF-8
#
Write-host $Scriptout"CreateInstallForestBat"

$InstallForestbat = @"
REM -----------------------------InstallForest.BAT------------------------------
SET FileToDelete="c:\InstallForest-transcript.txt"
IF EXIST %FileToDelete% del /F %FileToDelete%
powershell -executionpolicy bypass -noprofile -file c:\InstallForest.ps1 > c:\InstallForest-transcript.txt
REM Powershell.exe set-executionpolicy RemoteSigned
"@


#Write out the Post-Reboot*.ps1 files and the batch files that sets them to run
Write-host $Scriptout"CreateInstallADForestPS1"

$InstallForestPS1 = @"
#--------------------------------------------------------------------------
#Post-Reboot-InstallForest.ps1
#--------------------------------------------------------------------------
# This script runs a bunch more commands.
Start-Transcript -path c:\post-reboot-InstallForest-transcript.txt

#Moved this section. It couldn't be run in the main section because the name-change was pending.
#Set password for Domain creation.
Write-Host "ConvertTo-SecureString"
`$safemodeadminpwd = ConvertTo-SecureString -String $AdminPassword -asplaintext -force

Write-Host "Install-ADDSForest"
Install-ADDSForest -DomainName $SetDNSSuffix -DomainNetbiosName $DomainName -DomainMode Win2012R2 -ForestMode Win2012R2 -InstallDns -SafeModeAdministratorPassword `$safemodeadminpwd -Force -NoRebootOnCompletion

#Now write out to RunOnce the running of the cleanup bat file that runs the cleanup PS1 file.
#Note that you need to use -encoding ASCII. Otherwise it chokes. .BAT files can't be UTF-8

`$AdminKey = "HKLM:"
`$WinLogonKey = `$AdminKey + "\SOFTWARE\Microsoft\Windows NT\CurrentVersion\WinLogon"
`$RunOnceKey = `$AdminKey + "\Software\Microsoft\Windows\CurrentVersion\RunOnce"
Set-ItemProperty -Path `$RunOncekey -Name Foo -Value "c:\Post-DC-Cleanup.bat"

Write-Host "Configure Windows Update"
Add-WindowsUpdate -auto

#Need to restart after this.
Stop-Transcript
Restart-computer -Force
"@

Write-Host $Scriptout"Writing out InstallForest PS1 and Bat  files"
$InstallForestPS1           |out-file -FilePath  C:\InstallForest.ps1  -Force
$InstallForestBat           |Out-File -FilePath  c:\InstallForest.bat  -Force -encoding ASCII
#
#Using RunOnce to setup the running of the post-configuration files we just wrote out.
#Code to autologin the Administrator account so RunOnce can run in the right context
#from: http://gallery.technet.microsoft.com/scriptcenter/a449b284-f2fb-4964-9c3e-76a02e00342f

$AdminKey = "HKLM:"
$WinLogonKey = $AdminKey + "\SOFTWARE\Microsoft\Windows NT\CurrentVersion\WinLogon"
$RunOnceKey = $AdminKey + "\Software\Microsoft\Windows\CurrentVersion\RunOnce"
set-itemproperty -path $WinLogonKey -Name "DefaultUserName" -Value "Administrator"
set-itemproperty -path $WinLogonKey -Name "DefaultPassword" -Value $AdminPassword
set-itemproperty -path $WinLogonKey -Name "AutoAdminLogon" -Value "1"
set-itemproperty -path $WinLogonKey -Name "AutoLogonCount" -Value "99999"
set-itemproperty -path $WinLogonKey -Name "DefaultDomainName" -Value $DomainName
Set-ItemProperty -Path $RunOncekey -Name Foo -Value "C:\InstallForest.bat"

#Now Create the cleanup files that will be called by InstallForest

Write-host $Scriptout"Create Post-DC-cleanupBat"

$postDCCleanupbat = @"
REM -----------------------------postDCCleanupbat.BAT------------------------------
SET FileToDelete="c:\Post-DC-cleanup-transcript-*.txt"
IF EXIST %FileToDelete% del /F %FileToDelete%
powershell -executionpolicy bypass -noprofile -file C:\Post-DC-cleanup.ps1 > c:\Post-DC-cleanup-transcript-bat.txt
"@

$PostDCCleanupPS1 = @"
Start-Transcript -path c:\Post-DC-Cleanup-transcript-ps1.txt
Write-host "Checking to see if AD Web Services is running, if not, start it"
`$service = "ADWS"

`$running = get-service `$service
Write-host "ADWS Status: "`$running

if (`$running.status -eq "Stopped"){
start-service `$service }

#****Removed AD Replication. For Standard edition it just creates errors. If you're doing something***
#***this complex then adjust accordingly***
#
#Can't rename to "labx.local". Bad syntax error. Must use labx-local
#Write-Host "Get-ADReplicationSite"
#Get-ADReplicationSite -Identity Default-First-Site-Name | Rename-ADObject -NewName $SetDNSSuffix

Write-Host "New-ADReplicationSubnet"
#Can't use "labx.local". Bad syntax error. Must use labx-local
#New-ADReplicationSubnet -Name $NetworkID -Site $SetDNSSuffix

#Write-host "Enable-ADOptionalFeature -- Recycle Bin"
#Enable-ADOptionalFeature “Recycle Bin Feature” -Scope Forest -Target $SetDNSSuffix -confirm:`$false

Write-Host "Set up DNS Forwarder"
Set-DnsServerForwarder       -IPAddress  $NetworkBase".1"
Write-Host "Checking for Primary Zone"
`$PZone = Get-DNSServerZone   -Name       $SetDNSSuffix -ErrorAction SilentlyContinue

If (-Not `$PZone){
Write-Host "$SetDNSSuffix not found. Creating new Zone"
Add-DnsServerPrimaryZone     -Name      "$SetDNSSuffix"    -ZoneFile "$SystemName+.+$DNSSuffix+.dns"
}
Write-Host "Creating Reverse Zone and A records"
Add-DnsServerPrimaryZone     -NetworkID  $NetworkID        -ZoneFile $ReverseZoneFile
Add-DNSServerResourceRecordA -ZoneName   $SetDNSSuffix     -Name VCSA             -IPv4Address $NetworkBase".11" -CreatePtr
Add-DNSServerResourceRecordA -ZoneName   $SetDNSSuffix     -Name VCO              -IPv4Address $NetworkBase".21" -CreatePtr
Add-DNSServerResourceRecordA -ZoneName   $SetDNSSuffix     -Name VCAC-IAAS        -IPv4Address $NetworkBase".22" -CreatePtr
Add-DNSServerResourceRecordA -ZoneName   $SetDNSSuffix     -Name VCAC-APP         -IPv4Address $NetworkBase".23" -CreatePtr
Add-DNSServerResourceRecordA -ZoneName   $SetDNSSuffix     -Name ESXi-A           -IPv4Address $NetworkBase".30" -CreatePtr
Add-DNSServerResourceRecordA -ZoneName   $SetDNSSuffix     -Name ESXi-B           -IPv4Address $NetworkBase".31" -CreatePtr
Add-DNSServerResourceRecordA -ZoneName   $SetDNSSuffix     -Name ESXi-VSAN-1      -IPv4Address $NetworkBase".41" -CreatePtr
Add-DNSServerResourceRecordA -ZoneName   $SetDNSSuffix     -Name ESXi-VSAN-2      -IPv4Address $NetworkBase".42" -CreatePtr
Add-DNSServerResourceRecordA -ZoneName   $SetDNSSuffix     -Name ESXi-VSAN-3      -IPv4Address $NetworkBase".43" -CreatePtr



Write-Host "Set up Certificate Manager"
Import-Module ServerManager
Add-WindowsFeature RSAT-ADCS
Add-WindowsFeature RSAT-ADCS-Mgmt
Add-WindowsFeature RSAT-Online-Responder
Write-Host "Add CA role"
Add-WindowsFeature ADCS-Cert-Authority
Write-Host "Create CA"
Install-AdcsCertificationAuthority -CACommonName "Root CA" -CAType StandaloneRootCA -CryptoProviderName "RSA#Microsoft Software Key Storage Provider" -HashAlgorithmName SHA1 -KeyLength 2048 -ValidityPeriod Years -ValidityPeriodUnits 20 -force

Write-Host "get-CIMInstance -- setallowtsconnections"
get-CimInstance “Win32_TerminalServiceSetting” -Namespace root\cimv2\terminalservices | Invoke-CimMethod -MethodName setallowtsconnections -Arguments @{AllowTSConnections = 1; ModifyFirewallException = 1}

Write-Host "get-CIMInstance -- RDP-TCP"
get-CimInstance “Win32_TSGeneralSetting” -Namespace root\cimv2\terminalservices -Filter "TerminalName = 'RDP-Tcp'" | Invoke-CimMethod -MethodName SetUserAuthenticationRequired -Arguments @{UserAuthenticationRequired = 1}

Write-Host "Clearing AutoLogon values"

`$AdminKey = "HKLM:"
`$WinLogonKey = `$AdminKey + "\SOFTWARE\Microsoft\Windows NT\CurrentVersion\WinLogon"
#Uncomment if you'd like
#set-itemproperty -path `$WinLogonKey -Name "DefaultUserName" -Value ""
#set-itemproperty -path `$WinLogonKey -Name "DefaultPassword" -Value ""
#set-itemproperty -path `$WinLogonKey -Name "AutoAdminLogon" -Value "0"
#set-itemproperty -path `$WinLogonKey -Name "AutoLogonCount" -Value "0"
#set-itemproperty -path `$WinLogonKey -Name "DefaultDomainName" -Value ""

#Write-Host "Output a file onto the desktop showing that everything has completed."
#`logdate = get-date -formate "dddd-mmm-yy HH.sstt"
#`logfile = 'c:\Domain-Controller-Script-Completed at '+`$logdate+".txt"

Write-Host "Stopping Transcript and rebooting the system"
Stop-Transcript

Restart-Computer -force
"@



$PostDCCleanupPS1       |out-file -FilePath  C:\Post-DC-cleanup.ps1        -Force
$postDCCleanupbat       |Out-File -FilePath  c:\Post-DC-Cleanup.bat        -Force -encoding ASCII

#

Write-host $Scriptout"1st step completed"
Write-host $Scriptout"Rebooting to start the next step, Install Forest"
Stop-Transcript
Restart-Computer -Force
