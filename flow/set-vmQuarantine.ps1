<#
.SYNOPSIS
  This script can be used to move or remove a virtual machine in strict or forensics quarantine.
.DESCRIPTION
  Given a Prism Central instance and a virtual machine name, move or remove that virtual machine to/from quarantine in Prism Central.
.PARAMETER prism
  IP address or FQDN of Prism Central.
.PARAMETER prismCreds
  Specifies a custom credentials file name (will look for %USERPROFILE\Documents\WindowsPowerShell\CustomCredentials\$prismCreds.txt). These credentials can be created using the Powershell command 'Set-CustomCredentials -credname <credentials name>'. See https://blog.kloud.com.au/2016/04/21/using-saved-credentials-securely-in-powershell-scripts/ for more details.
.PARAMETER vm
  Name of the virtual machine to move to quarantine (as displayed in Prism Central). You can use a comman separated list.
.PARAMETER action
  Can be move or remove (to/from quarantine).
.PARAMETER type
  Can be strict or forensic (for the quarantine).
.PARAMETER help
  Displays a help message (seriously, what did you think this was?)
.PARAMETER history
  Displays a release history for this script (provided the editors were smart enough to document this...)
.PARAMETER log
  Specifies that you want the output messages to be written in a log file as well as on the screen.
.PARAMETER debugme
  Turns off SilentlyContinue on unexpected error messages.
.EXAMPLE
.\set-vmQuarantine.ps1 -prism 10.10.10.1 -prismCreds myuser -vm myvm -action move -type forensics
Move myvm to forensics quarantine.
.LINK
  http://www.nutanix.com/services
  https://github.com/sbourdeaud/nutanix
.NOTES
  Author: Stephane Bourdeaud (sbourdeaud@nutanix.com)
  Revision: November 10th 2022
#>

#region Parameters
  Param
  (
      #[parameter(valuefrompipeline = $true, mandatory = $true)] [PSObject]$myParam1,
      [parameter(mandatory = $false)] [switch]$help,
      [parameter(mandatory = $false)] [switch]$history,
      [parameter(mandatory = $false)] [switch]$log,
      [parameter(mandatory = $false)] [switch]$debugme,
      [parameter(mandatory = $false)] [string]$prism,
      [parameter(mandatory = $false)] $prismCreds,
      [parameter(mandatory = $false)] [string]$vm,
      [parameter(mandatory = $true)] [ValidateSet("move","remove")] [string]$action,
      [parameter(mandatory = $false)] [ValidateSet("strict","forensics")] [string]$type
  )
#endregion

#region functions
function Invoke-PrismAPICall
{
<#
.SYNOPSIS
  Makes api call to prism based on passed parameters. Returns the json response.
.DESCRIPTION
  Makes api call to prism based on passed parameters. Returns the json response.
.NOTES
  Author: Stephane Bourdeaud
.PARAMETER method
  REST method (POST, GET, DELETE, or PUT)
.PARAMETER credential
  PSCredential object to use for authentication.
PARAMETER url
  URL to the api endpoint.
PARAMETER payload
  JSON payload to send.
.EXAMPLE
.\Invoke-PrismAPICall -credential $MyCredObject -url https://myprism.local/api/v3/vms/list -method 'POST' -payload $MyPayload
Makes a POST api call to the specified endpoint with the specified payload.
#>
param
(
    [parameter(mandatory = $true)]
    [ValidateSet("POST","GET","DELETE","PUT")]
    [string] 
    $method,
    
    [parameter(mandatory = $true)]
    [string] 
    $url,

    [parameter(mandatory = $false)]
    [string] 
    $payload,
    
    [parameter(mandatory = $true)]
    [System.Management.Automation.PSCredential]
    $credential,
    
    [parameter(mandatory = $false)]
    [switch] 
    $checking_task_status
)

begin
{
    
}
process
{
    if (!$checking_task_status) {Write-Host "$(Get-Date) [INFO] Making a $method call to $url" -ForegroundColor Green}
    try {
        #check powershell version as PoSH 6 Invoke-RestMethod can natively skip SSL certificates checks and enforce Tls12 as well as use basic authentication with a pscredential object
        if ($PSVersionTable.PSVersion.Major -gt 5) {
            $headers = @{
                "Content-Type"="application/json";
                "Accept"="application/json"
            }
            if ($payload) {
                $resp = Invoke-RestMethod -Method $method -Uri $url -Headers $headers -Body $payload -SkipCertificateCheck -SslProtocol Tls12 -Authentication Basic -Credential $credential -ErrorAction Stop
            } else {
                $resp = Invoke-RestMethod -Method $method -Uri $url -Headers $headers -SkipCertificateCheck -SslProtocol Tls12 -Authentication Basic -Credential $credential -ErrorAction Stop
            }
        } else {
            $username = $credential.UserName
            $password = $credential.Password
            $headers = @{
                "Authorization" = "Basic "+[System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($username+":"+([System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($password))) ));
                "Content-Type"="application/json";
                "Accept"="application/json"
            }
            if ($payload) {
                $resp = Invoke-RestMethod -Method $method -Uri $url -Headers $headers -Body $payload -ErrorAction Stop
            } else {
                $resp = Invoke-RestMethod -Method $method -Uri $url -Headers $headers -ErrorAction Stop
            }
        }
        if (!$checking_task_status) {Write-Host "$(get-date) [SUCCESS] Call $method to $url succeeded." -ForegroundColor Cyan} 
        if ($debugme) {Write-Host "$(Get-Date) [DEBUG] Response Metadata: $($resp.metadata | ConvertTo-Json)" -ForegroundColor White}
    }
    catch {
        $saved_error = $_.Exception.Message
        # Write-Host "$(Get-Date) [INFO] Headers: $($headers | ConvertTo-Json)"
        Write-Host "$(Get-Date) [INFO] Payload: $payload" -ForegroundColor Green
        Throw "$(get-date) [ERROR] $saved_error"
    }
    finally {
        #add any last words here; this gets processed no matter what
    }
}
end
{
    return $resp
}    
}

function Write-LogOutput
{
<#
.SYNOPSIS
Outputs color coded messages to the screen and/or log file based on the category.

.DESCRIPTION
This function is used to produce screen and log output which is categorized, time stamped and color coded.

.PARAMETER Category
This the category of message being outputed. If you want color coding, use either "INFO", "WARNING", "ERROR" or "SUM".

.PARAMETER Message
This is the actual message you want to display.

.PARAMETER LogFile
If you want to log output to a file as well, use logfile to pass the log file full path name.

.NOTES
Author: Stephane Bourdeaud (sbourdeaud@nutanix.com)

.EXAMPLE
.\Write-LogOutput -category "ERROR" -message "You must be kidding!"
Displays an error message.

.LINK
https://github.com/sbourdeaud
#>
    [CmdletBinding(DefaultParameterSetName = 'None')] #make this function advanced

	param
	(
		[Parameter(Mandatory)]
        [ValidateSet('INFO','WARNING','ERROR','SUM','SUCCESS','STEP','DEBUG','DATA')]
        [string]
        $Category,

        [string]
		$Message,

        [string]
        $LogFile
	)

    process
    {
        $Date = get-date #getting the date so we can timestamp the output entry
	    $FgColor = "Gray" #resetting the foreground/text color
	    switch ($Category) #we'll change the text color depending on the selected category
        {
            "INFO" {$FgColor = "Green"}
            "WARNING" {$FgColor = "Yellow"}
            "ERROR" {$FgColor = "Red"}
            "SUM" {$FgColor = "Magenta"}
            "SUCCESS" {$FgColor = "Cyan"}
            "STEP" {$FgColor = "Magenta"}
            "DEBUG" {$FgColor = "White"}
            "DATA" {$FgColor = "Gray"}
        }

	    Write-Host -ForegroundColor $FgColor "$Date [$category] $Message" #write the entry on the screen
	    if ($LogFile) #add the entry to the log file if -LogFile has been specified
        {
            Add-Content -Path $LogFile -Value "$Date [$Category] $Message"
            Write-Verbose -Message "Wrote entry to log file $LogFile" #specifying that we have written to the log file if -verbose has been specified
        }
    }

}#end function Write-LogOutput

#helper-function Get-RESTError
function Help-RESTError 
{
    $global:helpme = $body
    $global:helpmoref = $moref
    $global:result = $_.Exception.Response.GetResponseStream()
    $global:reader = New-Object System.IO.StreamReader($global:result)
    $global:responseBody = $global:reader.ReadToEnd();

    return $global:responsebody

    break
}#end function Get-RESTError

function CheckModule
{
    param 
    (
        [string] $module,
        [string] $version
    )

    #getting version of installed module
    $current_version = (Get-Module -ListAvailable $module) | Sort-Object Version -Descending  | Select-Object Version -First 1
    #converting version to string
    $stringver = $current_version | Select-Object @{n='ModuleVersion'; e={$_.Version -as [string]}}
    $a = $stringver | Select-Object Moduleversion -ExpandProperty Moduleversion
    #converting version to string
    $targetver = $version | select @{n='TargetVersion'; e={$_ -as [string]}}
    $b = $targetver | Select-Object TargetVersion -ExpandProperty TargetVersion
    
    if ([version]"$a" -ge [version]"$b") {
        return $true
    }
    else {
        return $false
    }
}

function LoadModule
{#tries to load a module, import it, install it if necessary
<#
.SYNOPSIS
Tries to load the specified module and installs it if it can't.
.DESCRIPTION
Tries to load the specified module and installs it if it can't.
.NOTES
Author: Stephane Bourdeaud
.PARAMETER module
Name of PowerShell module to import.
.EXAMPLE
PS> LoadModule -module PSWriteHTML
#>
param 
(
    [string] $module
)

begin
{
    
}

process
{   
    Write-LogOutput -Category "INFO" -LogFile $myvar_log_file -Message "Trying to get module $($module)..."
    if (!(Get-Module -Name $module)) 
    {#we could not get the module, let's try to load it
        try
        {#import the module
            Import-Module -Name $module -ErrorAction Stop
            Write-LogOutput -Category "SUCCESS" -LogFile $myvar_log_file -Message "Imported module '$($module)'!"
        }#end try
        catch 
        {#we couldn't import the module, so let's install it
            Write-LogOutput -Category "INFO" -LogFile $myvar_log_file -Message "Installing module '$($module)' from the Powershell Gallery..."
            try 
            {#install module
                Install-Module -Name $module -Scope CurrentUser -Force -ErrorAction Stop
            }
            catch 
            {#could not install module
                Write-LogOutput -Category "ERROR" -LogFile $myvar_log_file -Message "Could not install module '$($module)': $($_.Exception.Message)"
                exit 1
            }

            try
            {#now that it is intalled, let's import it
                Import-Module -Name $module -ErrorAction Stop
                Write-LogOutput -Category "SUCCESS" -LogFile $myvar_log_file -Message "Imported module '$($module)'!"
            }#end try
            catch 
            {#we couldn't import the module
                Write-LogOutput -Category "ERROR" -LogFile $myvar_log_file -Message "Unable to import the module $($module).psm1 : $($_.Exception.Message)"
                Write-LogOutput -Category "WARNING" -LogFile $myvar_log_file -Message "Please download and install from https://www.powershellgallery.com"
                Exit 1
            }#end catch
        }#end catch
    }
}

end
{

}
}

function Set-CustomCredentials 
{
#input: path, credname
	#output: saved credentials file
<#
.SYNOPSIS
  Creates a saved credential file using DAPI for the current user on the local machine.
.DESCRIPTION
  This function is used to create a saved credential file using DAPI for the current user on the local machine.
.NOTES
  Author: Stephane Bourdeaud
.PARAMETER path
  Specifies the custom path where to save the credential file. By default, this will be %USERPROFILE%\Documents\WindowsPowershell\CustomCredentials.
.PARAMETER credname
  Specifies the credential file name.
.EXAMPLE
.\Set-CustomCredentials -path c:\creds -credname prism-apiuser
Will prompt for user credentials and create a file called prism-apiuser.txt in c:\creds
#>
	param
	(
		[parameter(mandatory = $false)]
        [string] 
        $path,
		
        [parameter(mandatory = $true)]
        [string] 
        $credname
	)

    begin
    {
        if (!$path)
        {
            if ($IsLinux -or $IsMacOS) 
            {
                $path = $home
            }
            else 
            {
                $path = "$Env:USERPROFILE\Documents\WindowsPowerShell\CustomCredentials"
            }
            Write-Host "$(get-date) [INFO] Set path to $path" -ForegroundColor Green
        } 
    }
    process
    {
        #prompt for credentials
        $credentialsFilePath = "$path\$credname.txt"
		$credentials = Get-Credential -Message "Enter the credentials to save in $path\$credname.txt"
		
		#put details in hashed format
		$user = $credentials.UserName
		$securePassword = $credentials.Password
        
        #convert secureString to text
        try 
        {
            $password = $securePassword | ConvertFrom-SecureString -ErrorAction Stop
        }
        catch 
        {
            throw "$(get-date) [ERROR] Could not convert password : $($_.Exception.Message)"
        }

        #create directory to store creds if it does not already exist
        if(!(Test-Path $path))
		{
            try 
            {
                $result = New-Item -type Directory $path -ErrorAction Stop
            } 
            catch 
            {
                throw "$(get-date) [ERROR] Could not create directory $path : $($_.Exception.Message)"
            }
		}

        #save creds to file
        try 
        {
            Set-Content $credentialsFilePath $user -ErrorAction Stop
        } 
        catch 
        {
            throw "$(get-date) [ERROR] Could not write username to $credentialsFilePath : $($_.Exception.Message)"
        }
        try 
        {
            Add-Content $credentialsFilePath $password -ErrorAction Stop
        } 
        catch 
        {
            throw "$(get-date) [ERROR] Could not write password to $credentialsFilePath : $($_.Exception.Message)"
        }

        Write-Host "$(get-date) [SUCCESS] Saved credentials to $credentialsFilePath" -ForegroundColor Cyan                
    }
    end
    {}
}

#this function is used to retrieve saved credentials for the current user
function Get-CustomCredentials 
{
#input: path, credname
	#output: credential object
<#
.SYNOPSIS
  Retrieves saved credential file using DAPI for the current user on the local machine.
.DESCRIPTION
  This function is used to retrieve a saved credential file using DAPI for the current user on the local machine.
.NOTES
  Author: Stephane Bourdeaud
.PARAMETER path
  Specifies the custom path where the credential file is. By default, this will be %USERPROFILE%\Documents\WindowsPowershell\CustomCredentials.
.PARAMETER credname
  Specifies the credential file name.
.EXAMPLE
.\Get-CustomCredentials -path c:\creds -credname prism-apiuser
Will retrieve credentials from the file called prism-apiuser.txt in c:\creds
#>
	param
	(
        [parameter(mandatory = $false)]
		[string] 
        $path,
		
        [parameter(mandatory = $true)]
        [string] 
        $credname
	)

    begin
    {
        if (!$path)
        {
            if ($IsLinux -or $IsMacOS) 
            {
                $path = $home
            }
            else 
            {
                $path = "$Env:USERPROFILE\Documents\WindowsPowerShell\CustomCredentials"
            }
            Write-Host "$(get-date) [INFO] Retrieving credentials from $path" -ForegroundColor Green
        } 
    }
    process
    {
        $credentialsFilePath = "$path\$credname.txt"
        if(!(Test-Path $credentialsFilePath))
	    {
            throw "$(get-date) [ERROR] Could not access file $credentialsFilePath : $($_.Exception.Message)"
        }

        $credFile = Get-Content $credentialsFilePath
		$user = $credFile[0]
		$securePassword = $credFile[1] | ConvertTo-SecureString

        $customCredentials = New-Object System.Management.Automation.PSCredential -ArgumentList $user, $securePassword

        Write-Host "$(get-date) [SUCCESS] Returning credentials from $credentialsFilePath" -ForegroundColor Cyan 
    }
    end
    {
        return $customCredentials
    }
}

function Set-PoshTls
{
<#
.SYNOPSIS
Makes sure we use the proper Tls version (1.2 only required for connection to Prism).

.DESCRIPTION
Makes sure we use the proper Tls version (1.2 only required for connection to Prism).

.NOTES
Author: Stephane Bourdeaud (sbourdeaud@nutanix.com)

.EXAMPLE
.\Set-PoshTls
Makes sure we use the proper Tls version (1.2 only required for connection to Prism).

.LINK
https://github.com/sbourdeaud
#>
[CmdletBinding(DefaultParameterSetName = 'None')] #make this function advanced

    param 
    (
        
    )

    begin 
    {
    }

    process
    {
        Write-Host "$(Get-Date) [INFO] Adding Tls12 support" -ForegroundColor Green
        [Net.ServicePointManager]::SecurityProtocol = `
        ([Net.ServicePointManager]::SecurityProtocol -bor `
        [Net.SecurityProtocolType]::Tls12)
    }

    end
    {

    }
}

#this function is used to configure posh to ignore invalid ssl certificates
function Set-PoSHSSLCerts
{
<#
.SYNOPSIS
Configures PoSH to ignore invalid SSL certificates when doing Invoke-RestMethod
.DESCRIPTION
Configures PoSH to ignore invalid SSL certificates when doing Invoke-RestMethod
#>
    begin
    {

    }#endbegin
    process
    {
        Write-Host "$(Get-Date) [INFO] Ignoring invalid certificates" -ForegroundColor Green
        if (-not ([System.Management.Automation.PSTypeName]'ServerCertificateValidationCallback').Type) {
            $certCallback = @"
using System;
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public class ServerCertificateValidationCallback
{
    public static void Ignore()
    {
        if(ServicePointManager.ServerCertificateValidationCallback ==null)
        {
            ServicePointManager.ServerCertificateValidationCallback += 
                delegate
                (
                    Object obj, 
                    X509Certificate certificate, 
                    X509Chain chain, 
                    SslPolicyErrors errors
                )
                {
                    return true;
                };
        }
    }
}
"@
            Add-Type $certCallback
        }#endif
        [ServerCertificateValidationCallback]::Ignore()
    }#endprocess
    end
    {

    }#endend
}#end function Set-PoSHSSLCerts

Function Get-PrismCentralTaskStatus
{
    <#
.SYNOPSIS
Retrieves the status of a given task uuid from Prism and loops until it is completed.

.DESCRIPTION
Retrieves the status of a given task uuid from Prism and loops until it is completed.

.PARAMETER Task
Prism task uuid.

.NOTES
Author: Stephane Bourdeaud (sbourdeaud@nutanix.com)

.EXAMPLE
.\Get-PrismCentralTaskStatus -Task $task -cluster $cluster -credential $prismCredentials
Prints progress on task $task until successfull completion. If the task fails, print the status and error code and details and exits.

.LINK
https://github.com/sbourdeaud
#>
[CmdletBinding(DefaultParameterSetName = 'None')] #make this function advanced

    param
    (
        [Parameter(Mandatory)]
        $task,
        
        [parameter(mandatory = $true)]
        [System.Management.Automation.PSCredential]
        $credential,

        [parameter(mandatory = $true)]
        [String]
        $cluster
    )

    begin
    {
        $url = "https://$($cluster):9440/api/nutanix/v3/tasks/$task"
        $method = "GET"
    }
    process 
    {
        #region get initial task details
            Write-Host "$(Get-Date) [INFO] Retrieving details of task $task..." -ForegroundColor Green
            $taskDetails = Invoke-PrismAPICall -method $method -url $url -credential $credential -checking_task_status
            Write-Host "$(Get-Date) [SUCCESS] Retrieved details of task $task" -ForegroundColor Cyan
        #endregion

        if ($taskDetails.percentage_complete -ne "100") 
        {
            Do 
            {
                New-PercentageBar -Percent $taskDetails.percentage_complete -DrawBar -Length 100 -BarView AdvancedThin2
                $Host.UI.RawUI.CursorPosition = New-Object System.Management.Automation.Host.Coordinates 2,$Host.UI.RawUI.CursorPosition.Y
                Sleep 5
                $taskDetails = Invoke-PrismAPICall -method $method -url $url -credential $credential -checking_task_status
                
                if ($taskDetails.status -ne "running") 
                {
                    if ($taskDetails.status -ne "succeeded") 
                    {
                        Write-Host "$(Get-Date) [WARNING] Task $($taskDetails.operation_type) failed with the following status and error code : $($taskDetails.status) : $($taskDetails.progress_message)" -ForegroundColor Yellow
                    }
                }
            }
            While ($taskDetails.percentage_complete -ne "100")
            
            New-PercentageBar -Percent $taskDetails.percentage_complete -DrawBar -Length 100 -BarView AdvancedThin2
            Write-Host ""
            Write-Host "$(Get-Date) [SUCCESS] Task $($taskDetails.operation_type) completed successfully!" -ForegroundColor Cyan
        } 
        else 
        {
            if ($taskDetails.status -ine "succeeded") {
                Write-Host "$(Get-Date) [WARNING] Task $($taskDetails.operation_type) status is $($taskDetails.status): $($taskDetails.progress_message) $($taskDetails.error_detail)" -ForegroundColor Yellow
            } else {
                New-PercentageBar -Percent $taskDetails.percentage_complete -DrawBar -Length 100 -BarView AdvancedThin2
                Write-Host ""
                Write-Host "$(Get-Date) [SUCCESS] Task $($taskDetails.operation_type) completed successfully!" -ForegroundColor Cyan
            }
        }
    }
    end
    {
        return $taskDetails.status
    }
}

#endregion

#region prep-work
  #check if we need to display help and/or history
  $HistoryText = @'
Maintenance Log
Date       By   Updates (newest updates at the top)
---------- ---- ---------------------------------------------------------------
11/10/2022 sb   Initial release.
################################################################################
'@
  $myvarScriptName = ".\set-vmQuarantine.ps1"
  if ($help) {get-help $myvarScriptName; exit}
  if ($History) {$HistoryText; exit}

  Set-PoSHSSLCerts
  Set-PoshTls

#endregion

#region variables
  #initialize variables
  #misc variables
  $myvarElapsedTime = [System.Diagnostics.Stopwatch]::StartNew() #used to store script begin timestamp
  $myvarOutputLogFile = (Get-Date -UFormat "%Y_%m_%d_%H_%M_")
  $myvarOutputLogFile += "OutputLog.log"
  
  $api_server_port = "9440"
  $api_server = $prism
    
  #let's initialize parameters if they haven't been specified
  if (!$prism) {$prism = read-host "Enter the hostname or IP address of Prism Central"}
  if ((!$vm) -and !($sourcecsv)) {$vm = read-host "Enter the virtual machine name"}
  $myvarListToProcess = $vm.Split(",")
  if (($action -ieq "move") -and !$action)
  {
    Write-Host "$(Get-Date) [ERROR] You must specify a quarantine type (strict or forensics) when using action move!" -ForegroundColor Red
    exit 1
  }
  
  
  if (!$prismCreds) 
  {#we are not using custom credentials, so let's ask for a username and password if they have not already been specified
      $prismCredentials = Get-Credential -Message "Please enter Prism credentials"
  } 
  else 
  { #we are using custom credentials, so let's grab the username and password from that
      try 
      {
          $prismCredentials = Get-CustomCredentials -credname $prismCreds -ErrorAction Stop
      }
      catch 
      {
          Set-CustomCredentials -credname $prismCreds
          $prismCredentials = Get-CustomCredentials -credname $prismCreds -ErrorAction Stop
      }
  }
  $username = $prismCredentials.UserName
  $PrismSecurePassword = $prismCredentials.Password
  $prismCredentials = New-Object PSCredential $username, $PrismSecurePassword
#endregion

#region processing
  ForEach ($item in $myvarListToProcess) {
    $myvar_already_tagged = $false
    $vm = $item
    $category = "Quarantine"
    if ($type -ieq "strict")
    {
      $value = "Default"
    }
    elseif ($type -ieq "forensics") 
    {
      $value = "Forensics"
    }
    #$value = (Get-Culture).TextInfo.ToTitleCase($type)

    #* step 1: retrieve vm details
    #region retrieve the vm details

      #region prepare api call
        $api_server_endpoint = "/api/nutanix/v3/vms/list"
        $url = "https://{0}:{1}{2}" -f $api_server,$api_server_port, `
            $api_server_endpoint
        $method = "POST"
        $content = @{
            filter= "vm_name==$($vm)";
            kind= "vm"
        }
        $payload = (ConvertTo-Json $content -Depth 4)
      #endregion

      #region make the api call
        Write-Host "$(Get-Date) [INFO] Retrieving the configuration of vm $vm from $prism..." -ForegroundColor Green
        try {
          $resp = Invoke-PrismAPICall -method $method -url $url -payload $payload -credential $prismCredentials
          if ($resp.metadata.total_matches -eq 0) {
              Write-Host "$(get-date) [WARNING] VM $vm was not found on $prism" -ForegroundColor Yellow
              Continue
          }
          elseif ($resp.metadata.total_matches -gt 1) {
            Write-Host "$(get-date) [WARNING] There are multiple VMs matching name $vm on $prism" -ForegroundColor Yellow
            Continue
          }
          $vm_config = $resp.entities[0]
          $vm_uuid = $vm_config.metadata.uuid
          Write-Host "$(Get-Date) [SUCCESS] Successfully retrieved the configuration of vm $vm from $prism" -ForegroundColor Cyan
        }
        catch {
          $saved_error = $_.Exception.Message
          Write-Host "$(get-date) [WARNING] $saved_error" -ForegroundColor Yellow
          Continue
        }
        finally {
        }

        #todo: if action is remove, we need to figure out the type of quarantine this vm was in and assign that to value
      #endregion

    #endregion

    #* step 2: prepare the json payload
    #region prepare the json payload
      $vm_config.PSObject.Properties.Remove('status')
    #endregion

    #* step 3: process action move
    #region process action move
      if ($action -ieq "move") {
        try {
          #$myvarNull = $vm_config.metadata.categories | Add-Member -MemberType NoteProperty -Name $category -Value $value -PassThru -ErrorAction Stop
          $myvarNull = $vm_config.metadata.categories_mapping | Add-Member -MemberType NoteProperty -Name $category -Value @($value) -PassThru -ErrorAction Stop
          $myvarNull = $vm_config | Add-Member -MemberType NoteProperty -Name "api_version" -Value "3.1" -PassThru -ErrorAction Stop
          $myvarNull = $vm_config.metadata | Add-Member -MemberType NoteProperty -Name "use_categories_mapping" -Value $true -PassThru -ErrorAction Stop
        }
        catch {
          Write-Host "$(Get-Date) [WARNING] Could not add category:value pair ($($category):$($value)). It may already be assigned to the vm $vm in $prism" -ForegroundColor Yellow
          $myvar_already_tagged = $true
          continue
        }
      }
    #endregion

    #* step 4: process action remove
    #region process action remove
      if ($action -ieq "remove") {
        #todo match the exact value pair here as a category could have multiple values assigned
        #$myvarNull = $vm_config.metadata.categories.PSObject.Properties.Remove($category)
        $myvarNull = $vm_config | Add-Member -MemberType NoteProperty -Name "api_version" -Value "3.1" -PassThru -ErrorAction Stop
        $myvarNull = $vm_config.metadata | Add-Member -MemberType NoteProperty -Name "use_categories_mapping" -Value $true -PassThru -ErrorAction Stop
        $myvarNull = $vm_config.metadata.categories_mapping.PSObject.Properties.Remove($category)
      }
    #endregion

    #* step 5: update the vm object
    #region update vm
      if (!$myvar_already_tagged)
      {
        #region prepare api call
          $api_server_endpoint = "/api/nutanix/v3/vms/{0}" -f $vm_uuid
          $url = "https://{0}:{1}{2}" -f $api_server,$api_server_port, `
              $api_server_endpoint
          $method = "PUT"

          #Write-Host "spec_version was $($vm_config.metadata.spec_version)"
          #$vm_config.metadata.spec_version += 1
          #Write-Host "spec_version now is $($vm_config.metadata.spec_version)"

          $payload = (ConvertTo-Json $vm_config -Depth 6)
        #endregion

        #region make the api call
          Write-Host "$(Get-Date) [INFO] Updating the configuration of vm $($vm) uuid $($vm_uuid) entity version $($vm_config.metadata.entity_version) with spec version $($vm_config.metadata.spec_version) in $($prism)..." -ForegroundColor Green
          do {
            try {
              $resp = Invoke-PrismAPICall -method $method -url $url -payload $payload -credential $prismCredentials
              $task_status = Get-PrismCentralTaskStatus -Task $resp.status.execution_context.task_uuid -cluster $prism -credential $prismCredentials
              if ($task_status -ine "failed") 
              {
                Write-Host "$(Get-Date) [SUCCESS] Successfully updated the configuration of vm $vm from $prism" -ForegroundColor Cyan
                $resp_return_code = 200
              }
              else 
              {
                Write-Host "$(Get-Date) [ERROR] Could not update quarantine status for $($vm) on $($prism)" -ForegroundColor Red
                exit 1
              }
            }
            catch {
              $saved_error = $_.Exception
              $resp_return_code = $_.Exception.Response.StatusCode.value__
              if ($resp_return_code -eq 409) {
                Write-Host "$(Get-Date) [WARNING] VM $vm cannot be updated now. Retrying in 5 seconds..." -ForegroundColor Yellow
                sleep 5
              }
              else {
                Write-Host $payload -ForegroundColor White
                Write-Host "$(get-date) [WARNING] $($resp.status) $($saved_error.Message)" -ForegroundColor Yellow
                Break
              }
            }
            finally {
            }
          } while ($resp_return_code -eq 409)
        #endregion
      }

    #endregion
  }
#endregion processing

#region cleanup	
  #let's figure out how much time this all took
  Write-Host "$(get-date) [SUM] total processing time: $($myvarElapsedTime.Elapsed.ToString())" -ForegroundColor Magenta

  #cleanup after ourselves and delete all custom variables
  Remove-Variable myvar* -ErrorAction SilentlyContinue
  Remove-Variable ErrorActionPreference -ErrorAction SilentlyContinue
  Remove-Variable help -ErrorAction SilentlyContinue
  Remove-Variable history -ErrorAction SilentlyContinue
  Remove-Variable log -ErrorAction SilentlyContinue
  Remove-Variable prism -ErrorAction SilentlyContinue
  Remove-Variable debugme -ErrorAction SilentlyContinue
#endregion