<#
.SYNOPSIS
  This script is used to migrate Horizon View 7 persistent disks from one desktop pool to another. This can be during a HV server migration, or during a DRP.
.DESCRIPTION
  There are three workflows supported by this script: export, recover and workflow. Export simply creates a csv file containing the list of persistent disk vmdk file names and the Active Directory user they are assigned to.  This csv file can then be used with recover to re-import persistent disks and recreate desktops in a DR pool, or with migrate to remove persistent disks from a given pool and to re-import them into another pool on the same or a different HV server.
.PARAMETER help
  Displays a help message (seriously, what did you think this was?)
.PARAMETER history
  Displays a release history for this script (provided the editors were smart enough to document this...)
.PARAMETER log
  Specifies that you want the output messages to be written in a log file as well as on the screen.
.PARAMETER debugme
  Turns off SilentlyContinue on unexpected error messages.
.PARAMETER SourceHv
  Hostname of the source Horizon View server. This is a required parameter for the export and migrate workflows.
.PARAMETER TargetHv
  Hostname of the target Horizon View server. This is a required parameter for the migrate and recover workflows.
.PARAMETER TargetvCenter
  Hostname of the vCenter containing the datastore with the persistsent disks vmdk files to be imported or migrated.  This is a required parameter with the migrate and recover workflows.
.PARAMETER PersistentDisksList
  Path and name of the csv file to export to or import from with the recover workflow.
.PARAMETER SourcePool
  Name of the source desktop pool you wish to export or migrate from.  If no pool is specified, it is assumed that all desktop pools must be exporter or migrated.
.PARAMETER TargetPool
  Name of the desktop pool to recover or migrate to.  Only one target desktop pool can be specified.
.PARAMETER Credentials
  Powershell credential object to be used for connecting to source and target Horizon View servers. This can be obtained with Get-Credential otherwise, the script will prompt you for it once.
.PARAMETER UserList
  Comma separated list of users you want to export or migrate. This is to limit the scope of export and migrate to only those users.
.PARAMETER Export
  Specifies you only want to export the list of persistent disks and assigned user to csv.
.PARAMETER Migrate
  Specifies you want to migrate persistent disks from a source HV server to a target HV server and pool. You can use SourcePool and UserList to limit the scope of action.  Note that source and target HV servers can be the same if you only want to migrate to a different desktop pools.
.PARAMETER Recover
  Specifies you want to import from csv a list of persistent disks into a target HV server and pool.  Used for disaster recovery purposes.
.EXAMPLE
  move-HvPersistentDisks.ps1 -sourceHv connection1.local -export -SourcePool pool2
  Export all persistent disks in desktop pool "pool2"
.EXAMPLE
  move-HvPersistentDisks.ps1 -migrate -sourceHv connection1.local -UserList "acme\JohnSmith","acme\JaneDoe" -TargetHv connection2.local -TargetPool pool1 -TargetvCenter vcenter-new.local
  Migrate persistent disks to a different pool on a different HV server for user "acme\JohnSmith" and "acme\JaneDoe"
.EXAMPLE
  move-HvPersistentDisks.ps1 -recover -sourceHv connection1.local -TargetHv connection2.local -TargetPool dr-pool -TargetvCenter vcenter-new.local -PersistentDisksList c:\source-persistentdisks.csv
  Recover all persistent disks from a csv onto a DR pool
.LINK
  http://www.nutanix.com/services
.NOTES
  Author: Stephane Bourdeaud (sbourdeaud@nutanix.com)
  Revision: August 4th 2017
#>

#region parameters
######################################
##   parameters and initial setup   ##
######################################
#let's start with some command line parsing
Param
(
    #[parameter(valuefrompipeline = $true, mandatory = $true)] [PSObject]$myParam1,
    [parameter(mandatory = $false)] [switch]$help,
    [parameter(mandatory = $false)] [switch]$history,
    [parameter(mandatory = $false)] [switch]$log,
    [parameter(mandatory = $false)] [switch]$debugme,
    [parameter(mandatory = $false)] [string]$SourceHv,
	[parameter(mandatory = $false)] [string]$TargetHv,
	[parameter(mandatory = $false)] [string]$TargetvCenter,
	[parameter(mandatory = $false)] [string]$PersistentDisksList,
	[parameter(mandatory = $false)] [string]$SourcePool,
	[parameter(mandatory = $false)] [string]$TargetPool,
	[parameter(mandatory = $false)] [System.Management.Automation.PSCredential]$Credentials,
    [parameter(mandatory = $false)] [string[]]$UserList,
	[parameter(mandatory = $false)] [switch]$Export,
	[parameter(mandatory = $false)] [switch]$Migrate,
	[parameter(mandatory = $false)] [switch]$Recover
)
#endregion

#region functions
########################
##   main functions   ##
########################

#this function is used to output log data
Function OutputLogData 
{
	#input: log category, log message
	#output: text to standard output
<#
.SYNOPSIS
  Outputs messages to the screen and/or log file.
.DESCRIPTION
  This function is used to produce screen and log output which is categorized, time stamped and color coded.
.NOTES
  Author: Stephane Bourdeaud
.PARAMETER myCategory
  This the category of message being outputed. If you want color coding, use either "INFO", "WARNING", "ERROR" or "SUM".
.PARAMETER myMessage
  This is the actual message you want to display.
.EXAMPLE
  PS> OutputLogData -mycategory "ERROR" -mymessage "You must specify a cluster name!"
#>
	[CmdletBinding()]
	param
	(
		[string] $category,
		[string] $message
	)

    begin
    {
	    $myvarDate = get-date
	    $myvarFgColor = "Gray"
	    switch ($category)
	    {
		    "INFO" {$myvarFgColor = "Green"}
		    "WARNING" {$myvarFgColor = "Yellow"}
		    "ERROR" {$myvarFgColor = "Red"}
		    "SUM" {$myvarFgColor = "Magenta"}
	    }
    }

    process
    {
	    Write-Host -ForegroundColor $myvarFgColor "$myvarDate [$category] $message"
	    if ($log) {Write-Output "$myvarDate [$category] $message" >>$myvarOutputLogFile}
    }

    end
    {
        Remove-variable category
        Remove-variable message
        Remove-variable myvarDate
        Remove-variable myvarFgColor
    }
}#end function OutputLogData

#this function is used to run an hv query
Function Invoke-HvQuery 
{
	#input: QueryType (see https://vdc-repo.vmware.com/vmwb-repository/dcr-public/f004a27f-6843-4efb-9177-fa2e04fda984/5db23088-04c6-41be-9f6d-c293201ceaa9/doc/index-queries.html), ViewAPI service object
	#output: query result object
<#
.SYNOPSIS
  Runs a Horizon View query.
.DESCRIPTION
  Runs a Horizon View query.
.NOTES
  Author: Stephane Bourdeaud
.PARAMETER QueryType
  Type of query (see https://vdc-repo.vmware.com/vmwb-repository/dcr-public/f004a27f-6843-4efb-9177-fa2e04fda984/5db23088-04c6-41be-9f6d-c293201ceaa9/doc/index-queries.html)
.PARAMETER ViewAPIObject
  View API service object.
.EXAMPLE
  PS> Invoke-HvQuery -QueryType PersistentDiskInfo -ViewAPIObject $ViewAPI
#>
	[CmdletBinding()]
	param
	(
      [string]
        [ValidateSet('ADUserOrGroupSummaryView','ApplicationIconInfo','ApplicationInfo','DesktopSummaryView','EntitledUserOrGroupGlobalSummaryView','EntitledUserOrGroupLocalSummaryView','FarmHealthInfo','FarmSummaryView','GlobalEntitlementSummaryView','MachineNamesView','MachineSummaryView','PersistentDiskInfo','PodAssignmentInfo','RDSServerInfo','RDSServerSummaryView','RegisteredPhysicalMachineInfo','SessionGlobalSummaryView','SessionLocalSummaryView','TaskInfo','UserHomeSiteInfo')]
        $QueryType,
        [VMware.Hv.Services]
        $ViewAPIObject
	)

    begin
    {
	    
    }

    process
    {
	    $serviceQuery = New-Object "Vmware.Hv.QueryServiceService"
        $query = New-Object "Vmware.Hv.QueryDefinition"
        $query.queryEntityType = $QueryType
        if ($query.QueryEntityType -eq 'PersistentDiskInfo') {
            $query.Filter = New-Object VMware.Hv.QueryFilterNotEquals -property @{'memberName'='storage.virtualCenter'; 'value' =$null}
        }
        $object = $serviceQuery.QueryService_Query($ViewAPIObject,$query)
    }

    end
    {
        if (!$object) {
            OutputLogData -category "ERROR" -message "The View API query did not return any data... Exiting!"
            exit
        }
        return $object
    }
}#end function Invoke-HvQuery

#this function is used to get the file name and assigned user for a persistent disk
Function Get-PersistentDiskInfo 
{
	#input: PersistentDisk, ViewAPI service object
	#output: PersistentDiskInfo
<#
.SYNOPSIS
  Runs a Horizon View query.
.DESCRIPTION
  Runs a Horizon View query.
.NOTES
  Author: Stephane Bourdeaud
.PARAMETER PersistentDisk
  Persistent Disk object.
.PARAMETER ViewAPI
  View API service object.
.EXAMPLE
  PS> Invoke-HvQuery -PersistentDisk $PersistentDisk -ViewAPI $ViewAPI
#>
	[CmdletBinding()]
	param
	(
        $PersistentDisk,
        $ViewAPI
	)

    begin
    {
	    
    }

    process
    {
        $PersistentDiskName = $PersistentDisk.Name #this is the vmdk file name
        $userId = $PersistentDisk.User #this is the id of the assigned user
                    
        #we need to retrieve the user name from that id
        $serviceADUserOrGroup = New-Object "Vmware.Hv.ADUserOrGroupService" #create the required object to run methods on
        $user = $serviceADUserOrGroup.ADUserOrGroup_Get($ViewAPI,$userId) #run the get method on that object filtering on the userid
        $AssignedUser = $user.Base.DisplayName #store the display name in a variable

        $PersistentDiskInfo = @{"PersistentDiskName" = $PersistentDiskName;"AssignedUser" = $AssignedUser} #we build the information for that specific disk
    }

    end
    {
        return $PersistentDiskInfo
    }
}#end function Get-PersistentDiskInfo

#this function is used to get the file name and assigned user for a persistent disk
Function Invoke-ExportWorkflow 
{
	#input: ViewAPI service object
	#output: PersistentDisksCsv
<#
.SYNOPSIS
  Runs the export workflow which creates a variable ready to be exported to csv which contains the list of persistent disk file names and assigned users for the given pool, user list of HV server.
.DESCRIPTION
  Runs the export workflow which creates a variable ready to be exported to csv which contains the list of persistent disk file names and assigned users for the given pool, user list of HV server.
.NOTES
  Author: Stephane Bourdeaud
.PARAMETER ViewAPI
  View API service object.
.EXAMPLE
  PS> Invoke-ExportWorkFlow -ViewAPI $ViewAPI
#>
	[CmdletBinding()]
	param
	(
        $ViewAPI
	)

    begin
    {
	    
    }

    process
    {       
        #retrieve list of persistent disks
        OutputLogData -category "INFO" -message "Retrieving the list of persistent disks..."
        $PersistentDisks = Invoke-HvQuery -QueryType PersistentDiskInfo -ViewAPIObject $ViewAPI

        #foreach disk, get the disk name and assigned user name
        OutputLogData -category "INFO" -message "Figuring out disk names and assigned user name..."
        [System.Collections.ArrayList]$PersistentDisksCsv = New-Object System.Collections.ArrayList($null) #we'll use this variable to collect persistent disk information
        if ($SourcePool) {$Desktops = Invoke-HvQuery -QueryType DesktopSummaryView -ViewAPIObject $ViewAPI} #let's grab all the desktop pools
        if ($UserList) {$ADUserOrGroups = Invoke-HvQuery -QueryType ADUserOrGroupSummaryView -ViewAPIObject $ViewAPI} #let's grab AD users
        ForEach ($PersistentDisk in ($PersistentDisks.Results.General | where {$_.User -ne $null})) {
            if ($SourcePool -and $UserList) {#both a source pool and userlist has been specified
                $DesktopId = ($Desktops.Results | where {$_.DesktopSummaryData.Name -eq $SourcePool}).Id
                if ($PersistentDisk.Desktop.Id -eq $DesktopId.Id) {
                    ForEach ($User in $UserList) {
                        $UserId = ($ADUserOrGroups.Results | where {$_.Base.DisplayName -eq $User}).Id
                        if ($PersistentDisk.User.Id -eq $UserId.Id) {
                            $PersistentDiskInfo = Get-PersistentDiskInfo -PersistentDisk $PersistentDisk -ViewAPI $ViewAPI
                            $PersistentDisksCsv.Add((New-Object PSObject -Property $PersistentDiskInfo)) | Out-Null #and we add it to our collection variable
                        }
                    }  
                }
            } ElseIf ($SourcePool) { #if a pool has been specified, only export this disk information if it is attached to a desktop in that pool
                $DesktopId = ($Desktops.Results | where {$_.DesktopSummaryData.Name -eq $SourcePool}).Id
                if ($PersistentDisk.Desktop.Id -eq $DesktopId.Id) {
                    $PersistentDiskInfo = Get-PersistentDiskInfo -PersistentDisk $PersistentDisk -ViewAPI $ViewAPI
                    $PersistentDisksCsv.Add((New-Object PSObject -Property $PersistentDiskInfo)) | Out-Null #and we add it to our collection variable
                }
            } ElseIf ($UserList) { #if a user list has been specified, only export that disk information if the disk is assigned to a user in that list
                ForEach ($User in $UserList) {
                    $UserId = ($ADUserOrGroups.Results | where {$_.Base.DisplayName -eq $User}).Id
                    if ($PersistentDisk.User.Id -eq $UserId.Id) {
                        $PersistentDiskInfo = Get-PersistentDiskInfo -PersistentDisk $PersistentDisk -ViewAPI $ViewAPI
                        $PersistentDisksCsv.Add((New-Object PSObject -Property $PersistentDiskInfo)) | Out-Null #and we add it to our collection variable
                    }
                }
            } else {
                $PersistentDiskInfo = Get-PersistentDiskInfo -PersistentDisk $PersistentDisk -ViewAPI $ViewAPI
                $PersistentDisksCsv.Add((New-Object PSObject -Property $PersistentDiskInfo)) | Out-Null #and we add it to our collection variable
            }
        }#end foreach PersistentDisk
    }

    end
    {
        return $PersistentDisksCsv
    }
}#end function Invoke-ExportWorkflow

#this function is used to get the file name and assigned user for a persistent disk
Function Invoke-RecoverWorkflow 
{
	#input: ViewAPI service object, PersistentDisksCsv variable
	#output: null
<#
.SYNOPSIS
  Imports all given persistent disks into the targetHv server and targetPool, then recreates VMs in that pool.
.DESCRIPTION
  Imports all given persistent disks into the targetHv server and targetPool, then recreates VMs in that pool.
.NOTES
  Author: Stephane Bourdeaud
.PARAMETER ViewAPI
  View API service object.
.PARAMETER PersistentDisksCsv
.EXAMPLE
  PS> Invoke-RecoverWorkFlow -ViewAPI $ViewAPI -PersistentDisksCsv $PersistentDisksCsv
#>
	[CmdletBinding()]
	param
	(
        $ViewAPI,
        $PersistentDisksCsv
	)

    begin
    {
	    
    }

    process
    {
        #setting things up
        $servicePersistentDisk = New-Object "Vmware.Hv.PersistentDiskService" #create the required object to run methods on
        $serviceVirtualDisk = New-Object "Vmware.Hv.VirtualDiskService" #create the required object to run methods on
        $Desktops = Invoke-HvQuery -QueryType DesktopSummaryView -ViewAPIObject $ViewAPI #retrieving the list of desktop pools
        $ADUserOrGroups = Invoke-HvQuery -QueryType ADUserOrGroupSummaryView -ViewAPIObject $ViewAPI #retrieving the list of AD users
        $AccessGroupId = ($Desktops.Results.DesktopSummaryData | where {$_.Name -eq $TargetPool} | select -Property AccessGroup).AccessGroup #figuring out the access group id for that desktop pool
        $desktopId = ($Desktops.Results | where {$_.DesktopSummaryData.Name -eq $TargetPool}).Id #figuring out the desktop id for the pool

        #import disks & recreate vms
        OutputLogData -category "INFO" -message "Importing persistent disks in $TargetHv..."
        $vCenterId = ($ViewAPI.VirtualCenter.VirtualCenter_List() | where {$_.ServerSpec.ServerName -eq $TargetvCenter} | Select -Property Id).Id #figuring out the object id for the specified vCenter server
        $VirtualDisks = $serviceVirtualDisk.VirtualDisk_List($ViewAPI,$vCenterId,$null) #retrieving the list of virtual disks from the vCenter server
        ForEach ($PersistentDisk in $PersistentDisksCsv) {
            $virtualDiskId = ($VirtualDisks | where {$_.Data.Name -eq $PersistentDisk.PersistentDiskName}).Id #figuring out the virtual disk id
            $userId = ($ADUserOrGroups.Results | where {$_.Base.DisplayName -eq $PersistentDisk.AssignedUser}).Id #figuring out the assigned user id
            
            $PersistentDiskSpec = New-Object "Vmware.Hv.PersistentDiskSpec" #building the persistent disk object specification
            $PersistentDiskSpec.VirtualDisk = $virtualDiskId
            $PersistentDiskSpec.AccessGroup = $AccessGroupId
            $PersistentDiskSpec.User = $userId
            $PersistentDiskSpec.Desktop = $desktopId #this is the desktop pool

            OutputLogData -category "INFO" -message "Importing persistent disk $($PersistentDisk.PersistentDiskName)..."
            $importedPersistentDiskId = $servicePersistentDisk.PersistentDisk_Create($ViewAPI,$PersistentDiskSpec) #import the disk
            OutputLogData -category "INFO" -message "Imported disk $($importedPersistentDiskId.Id)"
            OutputLogData -category "INFO" -message "Recreating VM from persistent disk $($PersistentDisk.PersistentDiskName)..."
            $machineId = $servicePersistentDisk.PersistentDisk_RecreateMachine($ViewAPI,$importedPersistentDiskId,$null) #recreate the vm
            OutputLogData -category "INFO" -message "Created VM $($machineId.Id)"
        }
    }

    end
    {
        
    }
}#end function Invoke-RecoverWorkflow

#endregion


#region prepwork
# get rid of annoying error messages
if (!$debugme) {$ErrorActionPreference = "SilentlyContinue"}

#check if we need to display help and/or history
$HistoryText = @'
 Maintenance Log
 Date       By   Updates (newest updates at the top)
 ---------- ---- ---------------------------------------------------------------
 08/04/2017 sb   Initial release.
################################################################################
'@
$myvarScriptName = ".\move-HvPersistentDisks.ps1"
 
if ($help) {get-help $myvarScriptName; exit}
if ($History) {$HistoryText; exit}

#let's make sure the PowerCLI modules are being used
if (!($myvarPowerCLI = Get-PSSnapin VMware.VimAutomation.Core -Registered)) {
    if (!($myvarPowerCLI = Get-Module VMware.VimAutomation.Core)) {
        Import-Module -Name VMware.VimAutomation.Core
        $myvarPowerCLI = Get-Module VMware.VimAutomation.Core
    }
}
try {
    if ($myvarPowerCLI.Version.Major -ge 6) {
        if ($myvarPowerCLI.Version.Minor -ge 5) {
            Import-Module VMware.VimAutomation.Vds -ErrorAction Stop
            OutputLogData -category "INFO" -message "PowerCLI 6.5+ module imported"
            Import-Module VMware.VimAutomation.HorizonView -ErrorAction Stop
            OutputLogData -category "INFO" -message "Horizon View 7 module imported"
        } else {
            throw "This script requires PowerCLI version 6.5 or later which can be downloaded from https://my.vmware.com/web/vmware/details?downloadGroup=PCLI650R1&productId=614"
        }
    } else {
        throw "This script requires PowerCLI version 6.5 or later which can be downloaded from https://my.vmware.com/web/vmware/details?downloadGroup=PCLI650R1&productId=614"
    }
}
catch {throw "Could not load the required VMware.VimAutomation.Vds cmdlets"}
#endregion

#region variables
#misc variables
$myvarElapsedTime = [System.Diagnostics.Stopwatch]::StartNew() #used to store script begin timestamp
$myvarOutputLogFile = (Get-Date -UFormat "%Y_%m_%d_%H_%M_")
$myvarOutputLogFile += "OutputLog.log"
#endregion

#region parameters validation
############################################################################
# command line arguments initialization
############################################################################	
#let's initialize parameters if they haven't been specified

#endregion

#region processing
	
    #region workflow 1: export
    if ($Export) {
        OutputLogData -category "INFO" -message "Starting the export workflow..."
        #check we have the required input
        if (!$SourceHv) {$SourceHv = Read-Host "Enter the name of the Horizon View server"}
        if (!$Credentials) {$Credentials = Get-Credential -Message "Enter credentials to the Horizon View server"}
        
        #connect to source hv
        OutputLogData -category "INFO" -message "Connecting to the Horizon View server $SourceHv..."
        try {Connect-HVServer -Server $SourceHv -Credential $Credentials -ErrorAction Stop | Out-Null}
        catch{OutputLogData -category "ERROR" -message "$($_.Exception.Message)"; Exit}
        $ViewAPI = $global:DefaultHVServers.ExtensionData #creates the ViewAPI object
        OutputLogData -category "INFO" -message "Connected to Horizon View server $SourceHv"
        
        $PersistentDisksCsv = Invoke-ExportWorkflow -ViewAPI $ViewAPI
        
        #export results to csv
        if (!$PersistentDisksList) {$PersistentDisksList = "$($SourceHv)-persistentDisks.csv"}
        OutputLogData -category "INFO" -message "Exporting results to csv file $PersistentDisksList ..."
        $PersistentDisksCsv | Export-Csv -NoTypeInformation $PersistentDisksList
        
        #disconnect from source hv
        OutputLogData -category "INFO" -message "Disconnecting from the Horizon View server(s)..."
        Disconnect-HVServer -Force * -Confirm:$false
    }
    #endregion

    #region workflow 2: recover
    if ($Recover) {
        OutputLogData -category "INFO" -message "Starting the recover workflow..."
        #checking we have the required input
        if (!$PersistentDisksList) {$PersistentDisksList = Read-Host "Please enter the path of the csv file containing the list of persistent disks to import"}
        
        #read from csv file
        if (!(Test-Path $PersistentDisksList)) {OutputLogData -category "ERROR" -message "$PersistentDisksList cannot be found. Please enter a valid csv file"; Exit}
        OutputLogData -category "INFO" -message "Importing persistent disks list from $PersistentDisksList..."
        $PersistentDisksCsv = Import-Csv $PersistentDisksList       

        #checking we have the required input
        if (!$TargetHv) {$TargetHv = Read-Host "Please enter the name of the target Horizon View Server"}
        if (!$Credentials) {$Credentials = Get-Credential -Message "Enter credentials to the Horizon View server"}
        if (!$TargetPool) {$TargetPool = Read-Host "Please enter the name of the target desktop pool"}
        if (!$TargetvCenter) {$TargetvCenter = Read-Host "Please enter the name of the vCenter server from which the persistent disks must be imported"}

        #connect to target hv
        OutputLogData -category "INFO" -message "Connecting to the Horizon View server $TargetHv..."
        try {Connect-HVServer -Server $TargetHv -Credential $Credentials -ErrorAction Stop | Out-Null}
        catch{OutputLogData -category "ERROR" -message "$($_.Exception.Message)"; Exit}
        $ViewAPI = $global:DefaultHVServers.ExtensionData #creates the ViewAPI object
        OutputLogData -category "INFO" -message "Connected to Horizon View server $TargetHv"

        Invoke-RecoverWorkflow -ViewAPI $ViewAPI -PersistentDisksCsv $PersistentDisksCsv

        #disconnect from target hv
        OutputLogData -category "INFO" -message "Disconnecting from the Horizon View server(s)..."
        Disconnect-HVServer -Force * -Confirm:$false
    }
    #endregion

    #region workflow 3: migrate
    if ($Migrate) {
        OutputLogData -category "INFO" -message "Starting the Migrate workflow..."
        
        #region process source
        #get persistent disks from source
        #check we have the required input
        if (!$SourceHv) {$SourceHv = Read-Host "Enter the name of the Horizon View server"}
        if (!$Credentials) {$Credentials = Get-Credential -Message "Enter credentials to the Horizon View server"}
        
        #connect to source hv
        OutputLogData -category "INFO" -message "Connecting to the Horizon View server $SourceHv..."
        try {Connect-HVServer -Server $SourceHv -Credential $Credentials -ErrorAction Stop | Out-Null}
        catch{OutputLogData -category "ERROR" -message "$($_.Exception.Message)"; Exit}
        $ViewAPI = $global:DefaultHVServers.ExtensionData #creates the ViewAPI object
        OutputLogData -category "INFO" -message "Connected to Horizon View server $SourceHv"
        
        $PersistentDisksCsv = Invoke-ExportWorkflow -ViewAPI $ViewAPI

        #delete machine and archive/detach persistent disk. This is because primary persistent disks can't be archived directly.
        $serviceMachineService = New-Object "VMware.Hv.MachineService"
        ForEach ($PersistentDisk in $PersistentDisksCsv) {
            $MachineNamesView = Invoke-HvQuery -QueryType MachineNamesView -ViewAPIObject $ViewAPI
            $MachineId = ($MachineNamesView.Results | where {$_.NamesData.UserName -eq $PersistentDisk.AssignedUser}).Id
            $MachineDeleteSpec = New-Object "Vmware.Hv.MachineDeleteSpec"
            $MachineDeleteSpec.DeleteFromDisk = $true
            $MachineDeleteSpec.ArchivePersistentDisk = $true
            OutputLogData -category "INFO" -message "Deleting virtual machine assigned to user $($PersistentDisk.AssignedUser) and archiving persistent disk $($PersistentDisk.PersistentDiskName)"
            $serviceMachineService.Machine_Delete($ViewAPI,$MachineId,$MachineDeleteSpec)
        }
        
        #remove persistent disks from source hv without deleting them from the datastore
        ForEach ($PersistentDisk in $PersistentDisksCsv) {
            $PersistentDisks = Invoke-HvQuery -QueryType PersistentDiskInfo -ViewAPIObject $ViewAPI
            Do {
                OutputLogData -category "INFO" -message "Waiting for $($PersistentDisk.PersistentDiskName) to finish archiving..."
                Start-Sleep -Seconds 15
                $PersistentDisks = Invoke-HvQuery -QueryType PersistentDiskInfo -ViewAPIObject $ViewAPI
            } While (($PersistentDisks.Results | where {$_.General.Name -eq $PersistentDisk.PersistentDiskName}).General.Status -eq "ARCHIVING")
            $PersistentDiskId = ($PersistentDisks.Results | where {$_.General.Name -eq $PersistentDisk.PersistentDiskName}).Id
            $PersistentDiskDeleteSpec = New-Object "Vmware.Hv.PersistentDiskDeleteSpec"
            $PersistentDiskDeleteSpec.DeleteFromDisk = $false #important to not delete the disks from the datastore
            OutputLogData -category "INFO" -message "Removing persistent disk $($PersistentDisk.PersistentDiskName) from $SourceHv..."
            $servicePersistentDisk.PersistentDisk_Delete($ViewAPI,$PersistentDiskId,$PersistentDiskDeleteSpec)
        }
        
        #disconnect from source hv
        OutputLogData -category "INFO" -message "Disconnecting from the Horizon View server(s)..."
        Disconnect-HVServer -Force * -Confirm:$false
        #endregion

        #region process target
        #recover vms on target
        #checking we have the required input
        if (!$TargetHv) {$TargetHv = Read-Host "Please enter the name of the target Horizon View Server"}
        if (!$Credentials) {$Credentials = Get-Credential -Message "Enter credentials to the Horizon View server"}
        if (!$TargetPool) {$TargetPool = Read-Host "Please enter the name of the target desktop pool"}
        if (!$TargetvCenter) {$TargetvCenter = Read-Host "Please enter the name of the vCenter server from which the persistent disks must be imported"}

        #connect to target hv
        OutputLogData -category "INFO" -message "Connecting to the Horizon View server $TargetHv..."
        try {Connect-HVServer -Server $TargetHv -Credential $Credentials -ErrorAction Stop | Out-Null}
        catch{OutputLogData -category "ERROR" -message "$($_.Exception.Message)"; Exit}
        $ViewAPI = $global:DefaultHVServers.ExtensionData
        OutputLogData -category "INFO" -message "Connected to Horizon View server $TargetHv"

        Invoke-RecoverWorkflow -ViewAPI $ViewAPI -PersistentDisksCsv $PersistentDisksCsv
        
        #disconnect from target hv
        OutputLogData -category "INFO" -message "Disconnecting from the Horizon View server(s)..."
        Disconnect-HVServer -Force * -Confirm:$false
        #endregion
    }
    #endregion

#endregion

#region cleanup
#########################
##       cleanup       ##
#########################

	#let's figure out how much time this all took
	OutputLogData -category "SUM" -message "total processing time: $($myvarElapsedTime.Elapsed.ToString())"
	
	#cleanup after ourselves and delete all custom variables
	Remove-Variable myvar* -ErrorAction SilentlyContinue
	Remove-Variable ErrorActionPreference -ErrorAction SilentlyContinue
	Remove-Variable help -ErrorAction SilentlyContinue
    Remove-Variable history -ErrorAction SilentlyContinue
	Remove-Variable log -ErrorAction SilentlyContinue
    Remove-Variable debugme -ErrorAction SilentlyContinue
#endregion