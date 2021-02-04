<#
.SYNOPSIS
  This script can be used to create protection domains and consistency groups based on a VM folder structure in vCenter.
.DESCRIPTION
  This script creates protection domains with consistency groups including all VMs in a given vCenter server VM folder.  Protection domains and consistency groups are automatically named "<clustername>-pd-<foldername>" and "<clustername>-cg-<foldername>".
.PARAMETER help
  Displays a help message (seriously, what did you think this was?)
.PARAMETER history
  Displays a release history for this script (provided the editors were smart enough to document this...)
.PARAMETER log
  Specifies that you want the output messages to be written in a log file as well as on the screen.
.PARAMETER debugme
  Turns off SilentlyContinue on unexpected error messages.
.PARAMETER cluster
  Nutanix cluster fully qualified domain name or IP address.
.PARAMETER username
  Username used to connect to the Nutanix cluster.
.PARAMETER password
  Password used to connect to the Nutanix cluster.
.PARAMETER vcenter
  Hostname of the vSphere vCenter to which the hosts you want to mount the NFS datastore belong to.  This is optional.  By Default, if no vCenter server and vSphere cluster name are specified, then the NFS datastore is mounted to all hypervisor hosts in the Nutanix cluster.  The script assumes the user running it has access to the vcenter server.
.PARAMETER folder
  Name of the VM folder object in vCenter which contains the virtual machines to be added to the protection domain and consistency group. You can specify multiple folder names by separating them with commas in which case you must enclose them in double quotes.
.PARAMETER repeatEvery
  Valid values are HOURLY, DAILY and WEEKLY, followed by the number of repeats.  For example, if you want backups to occur once a day, specify "DAILY,1" (note the double quotes).
.PARAMETER startOn
  Specifies the date and time at which you want to start the backup in the format: "MM/dd/YYYY,HH:MM". Note that this should be in UTC znd enclosed in double quotes.
.PARAMETER retention
  Specifies the number of snapshot versions you want to keep.
.PARAMETER replicateNow
  This is an optional parameter. If you use -replicateNow, a snapshot will be taken immediately for each created consistency group.
.PARAMETER interval
  This is an optional parameter. Specify the interval in minutes at which you want to separate each schedule.  This is to prevent scheduling all protection domains snapshots at the same time. If you are processing multiple folders, the first protection domain will be scheduled at the exact specified time (say 20:00 UTC), the next protection domain will be scheduled at +interval minutes (so 20:05 UTC if your interval is 5), and so on...
.PARAMETER prismCreds
  Specifies a custom credentials file name (will look for %USERPROFILE\Documents\WindowsPowerShell\CustomCredentials\$prismCreds.txt). These credentials can be created using the Powershell command 'Set-CustomCredentials -credname <credentials name>'. See https://blog.kloud.com.au/2016/04/21/using-saved-credentials-securely-in-powershell-scripts/ for more details.
.PARAMETER vcenterCreds
  Specifies a custom credentials file name (will look for %USERPROFILE\Documents\WindowsPowerShell\CustomCredentials\$prismCreds.txt). These credentials can be created using the Powershell command 'Set-CustomCredentials -credname <credentials name>'. See https://blog.kloud.com.au/2016/04/21/using-saved-credentials-securely-in-powershell-scripts/ for more details.
.EXAMPLE
.\add-NutanixProtectionDomains.ps1 -cluster ntnxc1.local -username admin -password admin -vcenter vcenter1 -folder "appA,appB" -repeatEvery "DAILY,1" -startOn "07/29/2015,20:00" -retention 3 -replicateNow
Create a protection domain for VM folders "appA" and "appB", schedule a replication every day at 8:00PM UTC, set a retention of 3 snapshots and replicate immediately.
.LINK
  http://www.nutanix.com/services
.NOTES
  Author: Stephane Bourdeaud (sbourdeaud@nutanix.com)
  Revision: February 3rd 2021
#>

#todo: replace all Nutanix cmdlets with REST API calls
#todo: add logic to update existing protection domains (check if they exist, etc...)
#todo: have default parameters values for scheduling and retention which can be modified in the script

#region parameters
	Param
	(
		#[parameter(valuefrompipeline = $true, mandatory = $true)] [PSObject]$myParam1,
		[parameter(mandatory = $false)] [switch]$help,
		[parameter(mandatory = $false)] [switch]$history,
		[parameter(mandatory = $false)] [switch]$log,
		[parameter(mandatory = $false)] [switch]$debugme,
		[parameter(mandatory = $true)] [string]$cluster,
		[parameter(mandatory = $true)] [string]$username,
		[parameter(mandatory = $true)] [string]$password,
		[parameter(mandatory = $true)] [string]$vcenter,
		[parameter(mandatory = $true)] [string]$folder,
		[parameter(mandatory = $true)] [string]$repeatEvery,
		[parameter(mandatory = $true)] [string]$startOn,
		[parameter(mandatory = $true)] [string]$retention,
		[parameter(mandatory = $false)] [switch]$replicateNow,
		[parameter(mandatory = $false)] [int]$interval,
		[parameter(mandatory = $false)] $prismCreds,
		[parameter(mandatory = $false)] $vcenterCreds
	)
#endregion

#region functions
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
#endregion

#region prepwork
	#check if we need to display help and/or history
	$HistoryText = @'
Maintenance Log
Date       By   Updates (newest updates at the top)
---------- ---- ---------------------------------------------------------------
06/19/2015 sb   Initial release.
02/03/2021 sb   Code update with PowerCLI module and REST API calls for NTNX.
################################################################################
'@
	$myvarScriptName = ".\add-NutanixProtectionDomains.ps1"
	
	if ($help) {get-help $myvarScriptName; exit}
	if ($History) {$HistoryText; exit}


	#check PoSH version
	if ($PSVersionTable.PSVersion.Major -lt 5) {throw "$(get-date) [ERROR] Please upgrade to Powershell v5 or above (https://www.microsoft.com/en-us/download/details.aspx?id=50395)"}

	#check if we have all the required PoSH modules
	Write-Host "$(get-date) [INFO] Checking for required Powershell modules..." -ForegroundColor Green
  
	#region Load/Install VMware.PowerCLI
		if (!(Get-Module VMware.PowerCLI)) 
		{#module VMware.PowerCLI is not loaded
			try 
			{#load module VMware.PowerCLI
				Write-Host "$(get-date) [INFO] Loading VMware.PowerCLI module..." -ForegroundColor Green
				Import-Module VMware.PowerCLI -ErrorAction Stop
				Write-Host "$(get-date) [SUCCESS] Loaded VMware.PowerCLI module" -ForegroundColor Cyan
			}
			catch 
			{#couldn't load module VMware.PowerCLI
				Write-Host "$(get-date) [WARNING] Could not load VMware.PowerCLI module!" -ForegroundColor Yellow
				try 
				{#install module VMware.PowerCLI
					Write-Host "$(get-date) [INFO] Installing VMware.PowerCLI module..." -ForegroundColor Green
					Install-Module -Name VMware.PowerCLI -Scope CurrentUser -ErrorAction Stop
					Write-Host "$(get-date) [SUCCESS] Installed VMware.PowerCLI module" -ForegroundColor Cyan
					try 
					{#loading module VMware.PowerCLI
						Write-Host "$(get-date) [INFO] Loading VMware.PowerCLI module..." -ForegroundColor Green
						Import-Module VMware.VimAutomation.Core -ErrorAction Stop
						Write-Host "$(get-date) [SUCCESS] Loaded VMware.PowerCLI module" -ForegroundColor Cyan
					}
					catch 
					{#couldn't load module VMware.PowerCLI
						throw "$(get-date) [ERROR] Could not load the VMware.PowerCLI module : $($_.Exception.Message)"
					}
				}
				catch 
				{#couldn't install module VMware.PowerCLI
					throw "$(get-date) [ERROR] Could not install the VMware.PowerCLI module. Install it manually from https://www.powershellgallery.com/items?q=powercli&x=0&y=0 : $($_.Exception.Message)"
				}
			}
		}
		
		if ((Get-Module -Name VMware.VimAutomation.Core).Version.Major -lt 10) 
		{#check PowerCLI version
			try 
			{#update module VMware.PowerCLI
				Update-Module -Name VMware.PowerCLI -ErrorAction Stop
			} 
			catch 
			{#couldn't update module VMware.PowerCLI
				throw "$(get-date) [ERROR] Could not update the VMware.PowerCLI module : $($_.Exception.Message)"
			}
		}
	#endregion
	if ((Get-PowerCLIConfiguration | where-object {$_.Scope -eq "User"}).InvalidCertificateAction -ne "Ignore") {
	  Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -confirm:$false
	}

	#region module sbourdeaud is used for facilitating Prism REST calls
	$required_version = "3.0.8"
	if (!(Get-Module -Name sbourdeaud)) {
		Write-Host "$(get-date) [INFO] Importing module 'sbourdeaud'..." -ForegroundColor Green
		try
		{
			Import-Module -Name sbourdeaud -MinimumVersion $required_version -ErrorAction Stop
			Write-Host "$(get-date) [SUCCESS] Imported module 'sbourdeaud'!" -ForegroundColor Cyan
		}#end try
		catch #we couldn't import the module, so let's install it
		{
			Write-Host "$(get-date) [INFO] Installing module 'sbourdeaud' from the Powershell Gallery..." -ForegroundColor Green
			try {Install-Module -Name sbourdeaud -Scope CurrentUser -Force -ErrorAction Stop}
			catch {throw "$(get-date) [ERROR] Could not install module 'sbourdeaud': $($_.Exception.Message)"}

			try
			{
				Import-Module -Name sbourdeaud -MinimumVersion $required_version -ErrorAction Stop
				Write-Host "$(get-date) [SUCCESS] Imported module 'sbourdeaud'!" -ForegroundColor Cyan
			}#end try
			catch #we couldn't import the module
			{
				Write-Host "$(get-date) [ERROR] Unable to import the module sbourdeaud.psm1 : $($_.Exception.Message)" -ForegroundColor Red
				Write-Host "$(get-date) [WARNING] Please download and install from https://www.powershellgallery.com/packages/sbourdeaud/1.1" -ForegroundColor Yellow
				Exit
			}#end catch
		}#end catch
	}#endif module sbourdeaud
	$MyVarModuleVersion = Get-Module -Name sbourdeaud | Select-Object -Property Version
	if (($MyVarModuleVersion.Version.Major -lt $($required_version.split('.')[0])) -or (($MyVarModuleVersion.Version.Major -eq $($required_version.split('.')[0])) -and ($MyVarModuleVersion.Version.Minor -eq $($required_version.split('.')[1])) -and ($MyVarModuleVersion.Version.Build -lt $($required_version.split('.')[2])))) {
		Write-Host "$(get-date) [INFO] Updating module 'sbourdeaud'..." -ForegroundColor Green
		Remove-Module -Name sbourdeaud -ErrorAction SilentlyContinue
		Uninstall-Module -Name sbourdeaud -ErrorAction SilentlyContinue
		try {
			Update-Module -Name sbourdeaud -Scope CurrentUser -ErrorAction Stop
			Import-Module -Name sbourdeaud -ErrorAction Stop
		}
		catch {throw "$(get-date) [ERROR] Could not update module 'sbourdeaud': $($_.Exception.Message)"}
	}
	#endregion
	Set-PoSHSSLCerts
	Set-PoshTls
	
#endregion

#region variables
	#initialize variables
	#misc variables
	$myvarElapsedTime = [System.Diagnostics.Stopwatch]::StartNew() #used to store script begin timestamp
	$myvarvCenterServers = @() #used to store the list of all the vCenter servers we must connect to
	$myvarOutputLogFile = (Get-Date -UFormat "%Y_%m_%d_%H_%M_")
	$myvarOutputLogFile += "OutputLog.log"
	[System.Collections.ArrayList]$pd_list = New-Object System.Collections.ArrayList($null)
#endregion

#region parameters validation
	if (!$vcenter) {$vcenter = read-host "Enter vCenter server name or IP address"}#prompt for vcenter server name
	$myvarvCenterServers = $vcenter.Split(",") #make sure we parse the argument in case it contains several entries

	#let's initialize parameters if they haven't been specified
	$myvar_folders = $folder.Split("{,}")
	if ($interval -and (($interval -le 0) -or ($interval -ge 60)))
	{
		OutputLogData -category "ERROR" -message "Interval must be between 1 and 59 minutes!"
		break
	}
	
	if (!$prismCreds) 
    {#we are not using custom credentials, so let's ask for a username and password if they have not already been specified
        if (!$username) 
        {#if Prism username has not been specified ask for it
            $username = Read-Host "Enter the Prism username"
        } 

        if (!$password) 
        {#if password was not passed as an argument, let's prompt for it
            $PrismSecurePassword = Read-Host "Enter the Prism user $username password" -AsSecureString
        }
        else 
        {#if password was passed as an argument, let's convert the string to a secure string and flush the memory
            $PrismSecurePassword = ConvertTo-SecureString $password –asplaintext –force
            Remove-Variable password
        }
        $prismCredentials = New-Object PSCredential $username, $PrismSecurePassword
    } 
    else 
    { #we are using custom credentials, so let's grab the username and password from that
        try 
        {
            $prismCredentials = Get-CustomCredentials -credname $prismCreds -ErrorAction Stop
            $username = $prismCredentials.UserName
            $PrismSecurePassword = $prismCredentials.Password
        }
        catch 
        {
            Set-CustomCredentials -credname $prismCreds
            $prismCredentials = Get-CustomCredentials -credname $prismCreds -ErrorAction Stop
            $username = $prismCredentials.UserName
            $PrismSecurePassword = $prismCredentials.Password
        }
        $prismCredentials = New-Object PSCredential $username, $PrismSecurePassword
    }

    if ($vcenterCreds) 
    {
        try 
        {
            $vcenterCredentials = Get-CustomCredentials -credname $vcenterCreds -ErrorAction Stop
            $vcenterUsername = $vcenterCredentials.UserName
            $vcenterSecurePassword = $vcenterCredentials.Password
        }
        catch 
        {
            Set-CustomCredentials -credname $vcenterCreds
            $vcenterCredentials = Get-CustomCredentials -credname $vcenterCreds -ErrorAction Stop
            $vcenterUsername = $vcenterCredentials.UserName
            $vcenterSecurePassword = $vcenterCredentials.Password
        }
        $vcenterCredentials = New-Object PSCredential $vcenterUsername, $vcenterSecurePassword
    }
#endregion

#region processing	
	#* testing connection to prism
	#region GET cluster
		Write-Host "$(get-date) [INFO] Retrieving cluster information from Nutanix cluster $($cluster) ..." -ForegroundColor Green
		$url = "https://{0}:9440/PrismGateway/services/rest/v2.0/cluster/" -f $cluster
		$method = "GET"
		try 
		{
			$myvar_ntnx_cluster_info = Invoke-PrismRESTCall -method $method -url $url -credential $prismCredentials
		}
		catch
		{
			throw "$(get-date) [ERROR] Could not retrieve cluster information from Nutanix cluster $($cluster) : $($_.Exception.Message)"
		}
		Write-Host "$(get-date) [SUCCESS] Successfully retrieved cluster information from Nutanix cluster $($cluster)" -ForegroundColor Cyan
	#endregion

	foreach ($myvar_vcenter_ip in $myvarvCenterServers)	
	{
		#region connect to vCenter
			Write-Host "$(get-date) [INFO] Connecting to vCenter server $($myvar_vcenter_ip) ..." -ForegroundColor Green
			if ($vcenterCreds) 
			{#vcenter credentials were specified already
				try 
				{#connect to vcenter
					$myvar_vcenter_connection = Connect-VIServer -Server $myvar_vcenter_ip -Credential $vcenterCredentials -ErrorAction Stop
				}
				catch 
				{#could not connect to vcenter
					throw "$(get-date) [ERROR] Could not connect to vCenter server $($myvar_vcenter_ip) : $($_.Exception.Message)"
				}
				Write-Host "$(get-date) [SUCCESS] Successfully connected to vCenter server $($myvar_vcenter_ip)" -ForegroundColor Cyan
			} 
			else 
			{#no vcenter credentials were specified, so script will prompt for them
				try 
				{#connect to vcenter
					$myvar_vcenter_connection = Connect-VIServer -Server $myvar_vcenter_ip -ErrorAction Stop
				}
				catch 
				{#could not connect to vcenter
					throw "$(get-date) [ERROR] Could not connect to vCenter server $($myvar_vcenter_ip) : $($_.Exception.Message)"
				}
				Write-Host "$(get-date) [SUCCESS] Successfully connected to vCenter server $($myvar_vcenter_ip)" -ForegroundColor Cyan
			}
		#endregion
			
		#* getting protection domains
		#region GET protection_domains
			Write-Host "$(get-date) [INFO] Retrieving protection domains from Nutanix cluster $($cluster) ..." -ForegroundColor Green
			$url = "https://{0}:9440/PrismGateway/services/rest/v2.0/protection_domains/" -f $cluster
			$method = "GET"
			try 
			{
				$myvar_pds = Invoke-PrismRESTCall -method $method -url $url -credential $prismCredentials
			}
			catch
			{
				throw "$(get-date) [ERROR] Could not retrieve protection domains from Nutanix cluster $($cluster) : $($_.Exception.Message)"
			}
			Write-Host "$(get-date) [SUCCESS] Successfully retrieved protection domains from Nutanix cluster $($cluster)" -ForegroundColor Cyan
			
			foreach ($myvar_pd in $myvar_pds) 
			{
				$myvar_pd_info = [ordered]@{
					"name" = $myvar_pd_detail.name;
					"role" = $myvar_pd_detail.metro_avail.role;
					"remote_site" = $myvar_pd_detail.metro_avail.remote_site;
					"storage_container" = $myvar_pd_detail.metro_avail.storage_container;
					"status" = $myvar_pd_detail.metro_avail.status;
					"failure_handling" = $myvar_pd_detail.metro_avail.failure_handling
				}
				$pd_list.Add((New-Object PSObject -Property $myvar_pd_info)) | Out-Null
			}
		#endregion
		
		#! *************************
		#! resume coding effort here
		$myvarLoopCount = 0
		foreach ($myvar_folder in $myvar_folders)
		{#process each folder
			#region get VMs in folder from vCenter
				OutputLogData -category "INFO" -message "Retrieving the names of the VMs in $myvar_folder..."
				$myvar_vms = Get-Folder -Name $myvar_folder | get-vm | select -ExpandProperty Name
				if (!$myvar_vms)
				{#no VM in that folder...
					OutputLogData -category "WARN" -message "No VM object was found in $($myvar_folder) or that folder was not found! Skipping to the next item..."
					continue
				}
			#endregion

			#! delete this region and replace with if pd does not exist, then create it, else, count vms in it
			#region todelete
			#let's make sure the protection domain doesn't already exist
			$myvarPdName = (Get-NTNXClusterInfo).Name + "-pd-" + $myvarFolder
			if (Get-NTNXProtectionDomain -Name $myvarPdName)
			{
				OutputLogData -category "WARN" -message "The protection domain $myvarPdName already exists! Skipping to the next item..."
				continue
			}
			#endregion
			
			#! update this region (most likely delete it completely as pd creation is dealt with above)
			#region create the protection domain
				OutputLogData -category "INFO" -message "Creating the protection domain $myvarPdName..."
				Add-NTNXProtectionDomain -Input $myvarPdName | Out-Null
				#create the consistency group
				$myvarCgName = (Get-NTNXClusterInfo).Name + "-cg-" + $myvarFolder
				OutputLogData -category "INFO" -message "Creating the consistency group $myvarCgName..."
				Add-NTNXProtectionDomainVM -Name $myvarPdName -ConsistencyGroupName $myvarCgName -Names $myvarVMs | Out-Null
			#endregion
			
			#! update this region
			#region create the schedule
				#let's parse the repeatEvery argument (exp format: DAILY,1)
				$myvarType = ($repeatEvery.Split("{,}"))[0]
				$myvarEveryNth = ($repeatEvery.Split("{,}"))[1]
				#let's parse the startOn argument (exp format: MM/dd/YYYY,HH:MM in UTC)
				$myvarDate = ($startOn.Split("{,}"))[0]
				$myvarTime = ($startOn.Split("{,}"))[1]
				$myvarMonth = ($myvarDate.Split("{/}"))[0]
				$myvarDay = ($myvarDate.Split("{/}"))[1]
				$myvarYear = ($myvarDate.Split("{/}"))[2]
				$myvarHour = ($myvarTime.Split("{:}"))[0]
				$myvarMinute = ($myvarTime.Split("{:}"))[1]
				#let's figure out the target date for that schedule
				if ($interval -and ($myvarLoopCount -ge 1))
				{#an interval was specified and this is not the first time we create a schedule
					$myvarTargetDate = (Get-Date -Year $myvarYear -Month $myvarMonth -Day $myvarDay -Hour $myvarHour -Minute $myvarMinute -Second 00 -Millisecond 00).AddMinutes($interval * $myvarLoopCount)
				}
				else
				{#no interval was specified, or this is our first time in this loop withna valid object
					$myvarTargetDate = Get-Date -Year $myvarYear -Month $myvarMonth -Day $myvarDay -Hour $myvarHour -Minute $myvarMinute -Second 00 -Millisecond 00
				}
				$myvarUserStartTimeInUsecs = [long][Math]::Floor((($myvarTargetDate - (New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc))).Ticks / [timespan]::TicksPerSecond)) * 1000 * 1000
				
				#let's create the schedule
				OutputLogData -category "INFO" -message "Creating the schedule for $myvarPdName to start on $myvarTargetDate UTC..."
				Add-NTNXProtectionDomainCronSchedule -Name $myvarPdName -Type $myvarType -EveryNth $myvarEveryNth -UserStartTimeInUsecs $myvarUserStartTimeInUsecs | Out-Null
				#configure the retention policy
				OutputLogData -category "INFO" -message "Configuring the retention policy on $myvarPdName to $retention..."
				Set-NTNXProtectionDomainRetentionPolicy -pdname ((Get-NTNXProtectionDomain -Name $myvarPdName).Name) -Id ((Get-NTNXProtectionDomainCronSchedule -Name $myvarPdName).Id) -LocalMaxSnapshots $retention | Out-Null
			#endregion
			
			#! update this region
			#region replicate NOW
				if ($replicateNow)
				{#user wants to replicate immediately
					#replicate now
					OutputLogData -category "INFO" -message "Starting an immediate replication for $myvarPdName..."
					Add-NTNXOutOfBandSchedule -Name $myvarPdName | Out-Null
				}
				++$myvarLoopCount
			#endregion
		}

        Write-Host "$(get-date) [INFO] Disconnecting from vCenter server $vcenter..." -ForegroundColor Green
		Disconnect-viserver * -Confirm:$False #cleanup after ourselves and disconnect from vcenter
	}#end foreach vCenter

#endregion

#region cleanup
	#let's figure out how much time this all took
	OutputLogData -category "SUM" -message "total processing time: $($myvarElapsedTime.Elapsed.ToString())"
	
	#cleanup after ourselves and delete all custom variables
	Remove-Variable myvar* -ErrorAction SilentlyContinue
	Remove-Variable ErrorActionPreference -ErrorAction SilentlyContinue
	Remove-Variable help -ErrorAction SilentlyContinue
    Remove-Variable history -ErrorAction SilentlyContinue
	Remove-Variable log -ErrorAction SilentlyContinue
	Remove-Variable cluster -ErrorAction SilentlyContinue
	Remove-Variable username -ErrorAction SilentlyContinue
	Remove-Variable password -ErrorAction SilentlyContinue
	Remove-Variable folder -ErrorAction SilentlyContinue
	Remove-Variable repeatEvery -ErrorAction SilentlyContinue
	Remove-Variable startOn -ErrorAction SilentlyContinue
	Remove-Variable retention -ErrorAction SilentlyContinue
	Remove-Variable replicateNow -ErrorAction SilentlyContinue
	Remove-Variable vcenter -ErrorAction SilentlyContinue
	Remove-Variable interval -ErrorAction SilentlyContinue
    Remove-Variable debugme -ErrorAction SilentlyContinue
#endregion