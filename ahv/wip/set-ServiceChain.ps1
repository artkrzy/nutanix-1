<#
.SYNOPSIS
  Creates a service chain in either inline or tap mode for AHV.
.DESCRIPTION
  This script implements the steps described in KB5486 in order to create a service chain on AHV.
  It is meant to be used when setting up partner solutions such as Darktrace (even though it can create
  both inline and tap service chains).
  It covers the following steps:
  1. Creating the category:value pair required for service chaining based on the specified vendor nam.
  2. Create the network function chain for the specified cluster.
  3. Configure each NFVM (Network Function Virtual Machine) on each AHV host to be an agent VM and to have 
  the proper vnic types based in the desired mode (inline or tap).
  4. Configure NFVM to host affinity rules.
  5. Categorize each NFVM with the category:value pair created in step 1.
  6. Add the network function chain reference to the designated subnet(s).
  Note that this script does NOT cover updating Flow Network Security rules with service chains.
  This script can also be used to process a single AHV host in a cluster that's already been configured (such
  as after having done a cluster expand) and removing the service chain configuration alltogether.
  It assumes NFVMs have already been deployed on each AHV host and left powered off.
  It assumes the service chain will be applied to an AHV subnet/network (as opposed to being used in a Flow 
  rule or for a single UVM vnic).
.PARAMETER help
  Displays a help message (seriously, what did you think this was?)
.PARAMETER history
  Displays a release history for this script (provided the editors were smart enough to document this...)
.PARAMETER log
  Specifies that you want the output messages to be written in a log file as well as on the screen.
.PARAMETER debugme
  Turns off SilentlyContinue on unexpected error messages.
.PARAMETER prismcentral
  Nutanix Prism Central instance fully qualified domain name or IP address.
.PARAMETER prismCreds
  Specifies a custom credentials file name (will look for %USERPROFILE\Documents\WindowsPowerShell\CustomCredentials\$prismCreds.txt). These credentials can be created using the Powershell command 'Set-CustomCredentials -credname <credentials name>'. See https://blog.kloud.com.au/2016/04/21/using-saved-credentials-securely-in-powershell-scripts/ for more details.
  If you do not specify a credentials file, you will be prompted for the PC username and password.
  The script assumes that PC and PE credentials are the same.
.PARAMETER cluster
  Name of the Nutanix AHV custer for which you want to create a service chain for (as it appears in Prism Central).
.PARAMETER nfvms
  Comma separated list of NFVM names. They will be pinned to the AHV hosts in the order that you specify in this list.
.PARAMETER subnets
  Comma separated list of AHV subnets/networks that you want to apply the service chain to.
.PARAMETER mode
  Either INLINE or TAP.
.PARAMETER action
  Either "create" to configure a cluster for the first time, "delete" to remove the service chain alltogether, 
  "add_host" if you just want to add a new host, "add_subnet" if you want to associate the service chain with a
  new AHV subnet/network or "remove_subnet" if you want to remove the service function from an AHV subnet/network.
.PARAMETER ahvhost
  Required only if you specified action "add_host". Designates the AHV host name as it appears in Prism to which you want
  to add the service chain to.
.PARAMETER vendor
  Name of the vendor you're adding this service chain for (exp:darktrace).
.EXAMPLE
.\template.ps1 -cluster ntnxc1.local
Connect to a Nutanix cluster of your choice:
.LINK
  http://www.nutanix.com/services
.NOTES
  Author: Stephane Bourdeaud (sbourdeaud@nutanix.com)
  Revision: February 22nd 2023
#>

#region parameters
    Param
    (
        #[parameter(valuefrompipeline = $true, mandatory = $true)] [PSObject]$myParam1,
        [parameter(mandatory = $false)] [switch]$help,
        [parameter(mandatory = $false)] [switch]$history,
        [parameter(mandatory = $false)] [switch]$log,
        [parameter(mandatory = $false)] [switch]$debugme,
        [parameter(mandatory = $true)] [string]$prismcentral,
        [parameter(mandatory = $true)] [string]$cluster,
        [parameter(mandatory = $false)] [string]$nfvms,
        [parameter(mandatory = $true)] [string]$subnets,
        [parameter(mandatory = $false)] [ValidateSet("INLINE","TAP")][string]$mode,
        [parameter(mandatory = $true)] [ValidateSet("create","delete","add_host","add_subnet","remove_subnet")][string]$action,
        [parameter(mandatory = $false)] [string]$ahvhost,
        [parameter(mandatory = $true)] [string]$vendor,
        [parameter(mandatory = $false)] $prismCreds
    )
#endregion

#region functions
#this function is used to process output to console (timestamped and color coded) and log file
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


#this function loads a powershell module
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


#this function is used to make a REST api call to Prism
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
        #Write-Host "$(Get-Date) [INFO] Payload: $payload" -ForegroundColor Green
        if ($resp)
        {
            Throw "$(get-date) [ERROR] Error code: $($resp.code) with message: $($resp.message_list.details)"
        }
        else 
        {
            Throw "$(get-date) [ERROR] $saved_error"
        } 
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


#this function is used to create saved credentials for the current user
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


#this function is used to make sure we use the proper Tls version (1.2 only required for connection to Prism)
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


function Get-PrismCentralObjectList
{#retrieves multiple pages of Prism REST objects v3
    [CmdletBinding()]
    param 
    (
        [Parameter(mandatory = $true)][string] $pc,
        [Parameter(mandatory = $true)][string] $object,
        [Parameter(mandatory = $true)][string] $kind
    )

    begin 
    {
        if (!$length) {$length = 100} #we may not inherit the $length variable; if that is the case, set it to 100 objects per page
        $total, $cumulated, $first, $last, $offset = 0 #those are used to keep track of how many objects we have processed
        [System.Collections.ArrayList]$myvarResults = New-Object System.Collections.ArrayList($null) #this is variable we will use to keep track of entities
        $url = "https://{0}:9440/api/nutanix/v3/{1}/list" -f $pc,$object
        $method = "POST"
        $content = @{
            kind=$kind;
            offset=0;
            length=$length
        }
        $payload = (ConvertTo-Json $content -Depth 4) #this is the initial payload at offset 0
    }
    
    process 
    {
        Do {
            try {
                $resp = Invoke-PrismAPICall -method $method -url $url -payload $payload -credential $prismCredentials
                
                if ($total -eq 0) {$total = $resp.metadata.total_matches} #this is the first time we go thru this loop, so let's assign the total number of objects
                $first = $offset #this is the first object for this iteration
                $last = $offset + ($resp.entities).count #this is the last object for this iteration
                if ($total -le $length)
                {#we have less objects than our specified length
                    $cumulated = $total
                }
                else 
                {#we have more objects than our specified length, so let's increment cumulated
                    $cumulated += ($resp.entities).count
                }
                
                Write-Host "$(Get-Date) [INFO] Processing results from $(if ($first) {$first} else {"0"}) to $($last) out of $($total)" -ForegroundColor Green
                if ($debugme) {Write-Host "$(Get-Date) [DEBUG] Response Metadata: $($resp.metadata | ConvertTo-Json)" -ForegroundColor White}
    
                #grab the information we need in each entity
                ForEach ($entity in $resp.entities) {                
                    $myvarResults.Add($entity) | Out-Null
                }
                
                $offset = $last #let's increment our offset
                #prepare the json payload for the next batch of entities/response
                $content = @{
                    kind=$kind;
                    offset=$offset;
                    length=$length
                }
                $payload = (ConvertTo-Json $content -Depth 4)
            }
            catch {
                $saved_error = $_.Exception.Message
                # Write-Host "$(Get-Date) [INFO] Headers: $($headers | ConvertTo-Json)"
                if ($payload) {Write-Host "$(Get-Date) [INFO] Payload: $payload" -ForegroundColor Green}
                Throw "$(get-date) [ERROR] $saved_error"
            }
            finally {
                #add any last words here; this gets processed no matter what
            }
        }
        While ($last -lt $total)
    }
    
    end 
    {
        return $myvarResults
    }
}


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
                Write-Host "$(Get-Date) [WARNING] Task $($taskDetails.operation_type) status is $($taskDetails.status): $($taskDetails.progress_message)" -ForegroundColor Yellow
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


#function used to display progress with a percentage bar
Function New-PercentageBar
{
	
<#
.SYNOPSIS
	Create percentage bar.
.DESCRIPTION
	This cmdlet creates percentage bar.
.PARAMETER Percent
	Value in percents (%).
.PARAMETER Value
	Value in arbitrary units.
.PARAMETER MaxValue
	100% value.
.PARAMETER BarLength
	Bar length in chars.
.PARAMETER BarView
	Different char sets to build the bar.
.PARAMETER GreenBorder
	Percent value to change bar color from green to yellow (relevant with -DrawBar parameter only).
.PARAMETER YellowBorder
	Percent value to change bar color from yellow to red (relevant with -DrawBar parameter only).
.PARAMETER NoPercent
	Exclude percentage number from the bar.
.PARAMETER DrawBar
	Directly draw the colored bar onto the PowerShell console (unsuitable for calculated properties).
.EXAMPLE
	PS C:\> New-PercentageBar -Percent 90 -DrawBar
	Draw single bar with all default settings.
.EXAMPLE
	PS C:\> New-PercentageBar -Percent 95 -DrawBar -GreenBorder 70 -YellowBorder 90
	Draw the bar and move the both color change borders.
.EXAMPLE
	PS C:\> 85 |New-PercentageBar -DrawBar -NoPercent
	Pipeline the percent value to the function and exclude percent number from the bar.
.EXAMPLE
	PS C:\> For ($i=0; $i -le 100; $i+=10) {New-PercentageBar -Percent $i -DrawBar -Length 100 -BarView AdvancedThin2; "`r"}
	Demonstrates advanced bar view with custom bar length and different percent values.
.EXAMPLE
	PS C:\> $Folder = 'C:\reports\'
	PS C:\> $FolderSize = (Get-ChildItem -Path $Folder |measure -Property Length -Sum).Sum
	PS C:\> Get-ChildItem -Path $Folder -File |sort Length -Descending |select -First 10 |select Name,Length,@{N='SizeBar';E={New-PercentageBar -Value $_.Length -MaxValue $FolderSize}} |ft -au
	Get file size report and add calculated property 'SizeBar' that contains the percent of each file size from the folder size.
.EXAMPLE
	PS C:\> $VolumeC = gwmi Win32_LogicalDisk |? {$_.DeviceID -eq 'c:'}
	PS C:\> Write-Host -NoNewline "Volume C Usage:" -ForegroundColor Yellow; `
	PS C:\> New-PercentageBar -Value ($VolumeC.Size-$VolumeC.Freespace) -MaxValue $VolumeC.Size -DrawBar; "`r"
	Get system volume usage report.
.NOTES
	Author      :: Roman Gelman @rgelman75
	Version 1.0 :: 04-Jul-2016 :: [Release] :: Publicly available
.LINK
	https://ps1code.com/2016/07/16/percentage-bar-powershell
#>
	
	[CmdletBinding(DefaultParameterSetName = 'PERCENT')]
	Param (
		[Parameter(Mandatory, Position = 1, ValueFromPipeline, ParameterSetName = 'PERCENT')]
		[ValidateRange(0, 100)]
		[int]$Percent
		 ,
		[Parameter(Mandatory, Position = 1, ValueFromPipeline, ParameterSetName = 'VALUE')]
		[ValidateRange(0, [double]::MaxValue)]
		[double]$Value
		 ,
		[Parameter(Mandatory, Position = 2, ParameterSetName = 'VALUE')]
		[ValidateRange(1, [double]::MaxValue)]
		[double]$MaxValue
		 ,
		[Parameter(Mandatory = $false, Position = 3)]
		[Alias("BarSize", "Length")]
		[ValidateRange(10, 100)]
		[int]$BarLength = 20
		 ,
		[Parameter(Mandatory = $false, Position = 4)]
		[ValidateSet("SimpleThin", "SimpleThick1", "SimpleThick2", "AdvancedThin1", "AdvancedThin2", "AdvancedThick")]
		[string]$BarView = "SimpleThin"
		 ,
		[Parameter(Mandatory = $false, Position = 5)]
		[ValidateRange(50, 80)]
		[int]$GreenBorder = 60
		 ,
		[Parameter(Mandatory = $false, Position = 6)]
		[ValidateRange(80, 90)]
		[int]$YellowBorder = 80
		 ,
		[Parameter(Mandatory = $false)]
		[switch]$NoPercent
		 ,
		[Parameter(Mandatory = $false)]
		[switch]$DrawBar
	)
	
	Begin
	{
		
		If ($PSBoundParameters.ContainsKey('VALUE'))
		{
			
			If ($Value -gt $MaxValue)
			{
				Throw "The [-Value] parameter cannot be greater than [-MaxValue]!"
			}
			Else
			{
				$Percent = $Value/$MaxValue * 100 -as [int]
			}
		}
		
		If ($YellowBorder -le $GreenBorder) { Throw "The [-YellowBorder] value must be greater than [-GreenBorder]!" }
		
		Function Set-BarView ($View)
		{
			Switch -exact ($View)
			{
				"SimpleThin"	{ $GreenChar = [char]9632; $YellowChar = [char]9632; $RedChar = [char]9632; $EmptyChar = "-"; Break }
				"SimpleThick1"	{ $GreenChar = [char]9608; $YellowChar = [char]9608; $RedChar = [char]9608; $EmptyChar = "-"; Break }
				"SimpleThick2"	{ $GreenChar = [char]9612; $YellowChar = [char]9612; $RedChar = [char]9612; $EmptyChar = "-"; Break }
				"AdvancedThin1"	{ $GreenChar = [char]9632; $YellowChar = [char]9632; $RedChar = [char]9632; $EmptyChar = [char]9476; Break }
				"AdvancedThin2"	{ $GreenChar = [char]9642; $YellowChar = [char]9642; $RedChar = [char]9642; $EmptyChar = [char]9643; Break }
				"AdvancedThick"	{ $GreenChar = [char]9617; $YellowChar = [char]9618; $RedChar = [char]9619; $EmptyChar = [char]9482; Break }
			}
			$Properties = [ordered]@{
				Char1 = $GreenChar
				Char2 = $YellowChar
				Char3 = $RedChar
				Char4 = $EmptyChar
			}
			$Object = New-Object PSObject -Property $Properties
			$Object
		} #End Function Set-BarView
		
		$BarChars = Set-BarView -View $BarView
		$Bar = $null
		
		Function Draw-Bar
		{
			
			Param (
				[Parameter(Mandatory)]
				[string]$Char
				 ,
				[Parameter(Mandatory = $false)]
				[string]$Color = 'White'
				 ,
				[Parameter(Mandatory = $false)]
				[boolean]$Draw
			)
			
			If ($Draw)
			{
				Write-Host -NoNewline -ForegroundColor ([System.ConsoleColor]$Color) $Char
			}
			Else
			{
				return $Char
			}
			
		} #End Function Draw-Bar
		
	} #End Begin
	
	Process
	{
		
		If ($NoPercent)
		{
			$Bar += Draw-Bar -Char "[ " -Draw $DrawBar
		}
		Else
		{
			If ($Percent -eq 100) { $Bar += Draw-Bar -Char "$Percent% [ " -Draw $DrawBar }
			ElseIf ($Percent -ge 10) { $Bar += Draw-Bar -Char " $Percent% [ " -Draw $DrawBar }
			Else { $Bar += Draw-Bar -Char "  $Percent% [ " -Draw $DrawBar }
		}
		
		For ($i = 1; $i -le ($BarValue = ([Math]::Round($Percent * $BarLength / 100))); $i++)
		{
			
			If ($i -le ($GreenBorder * $BarLength / 100)) { $Bar += Draw-Bar -Char ($BarChars.Char1) -Color 'DarkGreen' -Draw $DrawBar }
			ElseIf ($i -le ($YellowBorder * $BarLength / 100)) { $Bar += Draw-Bar -Char ($BarChars.Char2) -Color 'Yellow' -Draw $DrawBar }
			Else { $Bar += Draw-Bar -Char ($BarChars.Char3) -Color 'Red' -Draw $DrawBar }
		}
		For ($i = 1; $i -le ($EmptyValue = $BarLength - $BarValue); $i++) { $Bar += Draw-Bar -Char ($BarChars.Char4) -Draw $DrawBar }
		$Bar += Draw-Bar -Char " ]" -Draw $DrawBar
		
	} #End Process
	
	End
	{
		If (!$DrawBar) { return $Bar }
	} #End End
	
} #EndFunction New-PercentageBar
#endregion

#region prepwork
    $HistoryText = @'
Maintenance Log
Date       By   Updates (newest updates at the top)
---------- ---- ---------------------------------------------------------------
02/22/2023 sb   Initial release.
################################################################################
'@
    $myvarScriptName = ".\set-ServiceChain.ps1"

    if ($help) {get-help $myvarScriptName; exit}
    if ($History) {$HistoryText; exit}

    #check PoSH version
    if ($PSVersionTable.PSVersion.Major -lt 5) {throw "$(get-date) [ERROR] Please upgrade to Powershell v5 or above (https://www.microsoft.com/en-us/download/details.aspx?id=50395)"}

    #check if we have all the required PoSH modules
    Write-LogOutput -Category "INFO" -LogFile $myvarOutputLogFile -Message "Checking for required Powershell modules..."
    if (!(Get-Module -ListAvailable -Name Posh-SSH)) {
        if (!(Import-Module Posh-SSH)) {
            Write-Host "$(get-date) [WARNING] We need to install the Posh-SSH module!" -ForegroundColor Yellow
            try {Install-Module Posh-SSH -ErrorAction Stop -Scope CurrentUser}
            catch {throw "Could not install the Posh-SSH module : $($_.Exception.Message)"}
            try {Import-Module Posh-SSH}
            catch {throw "Could not load the Posh-SSH module : $($_.Exception.Message)"}
        }
    }

    Set-PoSHSSLCerts
    Set-PoshTls
#endregion

#region variables
    $myvarElapsedTime = [System.Diagnostics.Stopwatch]::StartNew() #used to store script begin timestamp
#endregion

#region parameters validation
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

    if (($action -in "create","delete","add_host") -and (!$nfvms))
    {
        #we need nfmvs
        Write-Host "$(get-date) [WARNING] You need to specify the list of NFVMs (Network Function Virtual Machines) to process..." -ForegroundColor Yellow
        $nfvms = Read-Host "Please enter list of NFVMs to process:"
    }
    elseif (($action -in "create","add_host",'add_subnet') -and (!$mode))
    {
        Write-Host "$(get-date) [ERROR] You need to specify the service chain mode with the -mode parameter as either inline or tap!" -ForegroundColor Yellow
        exit 1
    }
    elseif (($action -eq "add_host") -and (!$ahvhost))
    {
        #we need ahvhost
        Write-Host "$(get-date) [WARNING] You need to specify the name of the AHV host to process..." -ForegroundColor Yellow
        $nfvms = Read-Host "Please enter the name of the AHV host to process:"
    }
#endregion

#todo: move nfvm processing to a function (list of nfms to process as a param)
#todo: move subnet processing to a function (nfc uuid and list of subnets to process as params and add/remove as an option)
#region processing
    #region getting the information we need
    Write-Host "$(get-date) [INFO] Retrieving list of clusters from Prism Central..." -ForegroundColor Green
    $myvar_clusters = Get-PrismCentralObjectList -pc $prismcentral -object "clusters" -kind "cluster"

    Write-Host "$(get-date) [INFO] Retrieving list of categories from Prism Central..." -ForegroundColor Green
    $myvar_categories = Get-PrismCentralObjectList -pc $prismcentral -object "categories" -kind "category"

    Write-Host "$(get-date) [INFO] Retrieving list of virtual machines from Prism Central..." -ForegroundColor Green
    $myvar_vms = Get-PrismCentralObjectList -pc $prismcentral -object "vms" -kind "vm"

    Write-Host "$(get-date) [INFO] Retrieving list of subnets from Prism Central..." -ForegroundColor Green
    $myvar_subnets = Get-PrismCentralObjectList -pc $prismcentral -object "subnets" -kind "subnet"
    #endregion getting the information we need

    #region checking specified objects exist
    #* cluster
    if ($myvar_cluster = $myvar_clusters | ?{$_.spec.name -eq $cluster})
    {#we found our cluster
        $myvar_cluster_uuid = $myvar_cluster.metadata.uuid
        Write-Host "$(get-date) [DATA] Cluster $($cluster) has uuid $($myvar_cluster_uuid)..." -ForegroundColor White
        $myvar_nfvms_count = ($nfvms.Split(",")).Count
        $myvar_cluster_hosts = $myvar_cluster.status.resources.nodes.hypervisor_server_list | ?{$_.ip -ne "127.0.0.1"}
        $myvar_cluster_hosts_count = $myvar_cluster_hosts.Count
        
        if ($myvar_nfvms_count -ne $myvar_cluster_hosts_count)
        {#the number of nfvms does not match the number of hosts in the cluster
            Write-Host "$(get-date) [ERROR] You have specifed $($myvar_nfvms_count) NFVM(s) but there are $($myvar_cluster_hosts_count) hosts in cluster $($cluster): those numbers must match!" -ForegroundColor Red
            exit 1
        }
        
        ForEach ($myvar_cluster_host in $myvar_cluster.status.resources.nodes.hypervisor_server_list)
        {#let's check each host in the cluser to make sure it is running the AHV hypervisor
            if ($myvar_cluster_host.type -ne "AHV")
            {#one of our host is not running the AHV hypervisor
                Write-Host "$(get-date) [ERROR] Host with IP $($myvar_cluster_host.ip) in cluster $($cluster) is not running AHV!" -ForegroundColor Red
                exit 1
            }
        }
    }
    else 
    {#we can't find our cluster
        Write-Host "$(get-date) [ERROR] Could not find cluster $($cluster) on $($prismcentral)!" -ForegroundColor Red
        exit 1
    }

    #* subnet
    [System.Collections.ArrayList]$myvar_subnet_objects = New-Object System.Collections.ArrayList($null)
    ForEach ($myvar_subnet in $subnets.Split(","))
    {#let's find each subnet
        if ($myvar_subnet_object = $myvar_subnets | ?{$_.spec.name -eq $myvar_subnet})
        {#we found one of our subnets
            $myvar_subnet_uuid = $myvar_subnet_object.metadata.uuid
            Write-Host "$(get-date) [DATA] Subnet $($myvar_subnet) has uuid $($myvar_subnet_uuid)..." -ForegroundColor White
            $myvar_subnet_objects.Add($myvar_subnet_object) | Out-Null
        }
        else 
        {#we couldn't find one of our subnets
            Write-Host "$(get-date) [ERROR] Could not find subnet $($myvar_subnet) on $($prismcentral)!" -ForegroundColor Red
            exit 1
        }
    }

    #* nfvms
    [System.Collections.ArrayList]$myvar_nfvms_objects = New-Object System.Collections.ArrayList($null)
    ForEach ($myvar_nfvm in $nfvms.Split(","))
    {#let's find each nfvm
        if ($myvar_nfvm_object = $myvar_vms | ?{$_.spec.name -eq $myvar_nfvm})
        {#we found one of our nfvms
            $myvar_nfvm_uuid = $myvar_nfvm_object.metadata.uuid
            Write-Host "$(get-date) [DATA] NFVM $($myvar_nfvm) has uuid $($myvar_nfvm_uuid)..." -ForegroundColor White
            $myvar_nfvms_objects.Add($myvar_nfvm_object) | Out-Null
        }
        else 
        {#we couldn't find one of our nfvm
            Write-Host "$(get-date) [ERROR] Could not find NFVM $($myvar_nfvm) on $($prismcentral)!" -ForegroundColor Red
            exit 1
        }
    }
    #endregion checking specified objects exist


    if ($action -eq "create")
    {
        #* step 1: create category
        Write-Host "$(get-date) [STEP] Processing the creation of the category" -ForegroundColor Magenta
        #region create category
        if ($myvar_category_key = $myvar_categories | ?{$_.name -eq "network_function_provider"})
        {#our category key already exists
            Write-Host "$(get-date) [WARNING] The category key $($myvar_category_key.name) already exists in Prism Central $($prismcentral)" -ForegroundColor Yellow
        }
        else 
        {#we need to create our category key
            Write-Host "$(get-date) [INFO] Adding network_function_provider category to Prism Central..." -ForegroundColor Green
            $url = "https://$($prismcentral):9440/api/nutanix/v3/categories/network_function_provider"
            $method = "PUT"
            $content = @{
                name="network_function_provider"
            }
            $payload = (ConvertTo-Json $content -Depth 4)
            $CreateCategoryKeyRequest = Invoke-PrismAPICall -method $method -url $url -credential $prismCredentials -payload $payload
        }
        #endregion create category

        #* step 2: create vendor value in category
        Write-Host "$(get-date) [STEP] Processing the creation of the vendor value in the category" -ForegroundColor Magenta
        #region create vendor value in category
        Write-Host "$(get-date) [INFO] Getting values for the network_function_provider category key from $($prismcentral)..." -ForegroundColor Green
        $url = "https://$($prismcentral):9440/api/nutanix/v3/categories/network_function_provider/list"
        $method = "POST"
        $content = @{
            kind="category"
        }
        $payload = (ConvertTo-Json $content -Depth 4)
        $myvar_category_values = Invoke-PrismAPICall -method $method -url $url -credential $prismCredentials -payload $payload
        if ($myvar_category_value = $myvar_category_values.entities | ?{$_.value -eq $vendor})
        {#our category value already exists
            Write-Host "$(get-date) [WARNING] The value $($vendor) already exists for category key network_function_provider in Prism Central $($prismcentral)" -ForegroundColor Yellow
        }
        else 
        {#we need to create our category value
            Write-Host "$(get-date) [INFO] Adding the value $($vendor) to network_function_provider category in Prism Central $($prismcentral)" -ForegroundColor Green
            $url = "https://$($prismcentral):9440/api/nutanix/v3/categories/network_function_provider/$($vendor)"
            $method = "PUT"
            $content = @{
                value=$vendor
            }
            $payload = (ConvertTo-Json $content -Depth 4)
            $CreateCategoryValueRequest = Invoke-PrismAPICall -method $method -url $url -credential $prismCredentials -payload $payload
        }
        #endregion create vendor value in category

        #* step 3: create the network function chain on the cluster
        Write-Host "$(get-date) [STEP] Processing the creation of the network function chain for the cluster" -ForegroundColor Magenta
        #region create the network function chain on the cluster
        Write-Host "$(get-date) [INFO] Getting existing service chains from $($prismcentral)..." -ForegroundColor Green
        $url = "https://$($prismcentral):9440/api/nutanix/v3/network_function_chains/list"
        $method = "POST"
        $content = @{
            kind="network_function_chain"
        }
        $payload = (ConvertTo-Json $content -Depth 4)
        $myvar_network_function_chains = Invoke-PrismAPICall -method $method -url $url -credential $prismCredentials -payload $payload
        $myvar_service_chain_already_exists = $false
        if ($myvar_network_function_chain = ($myvar_network_function_chains.entities | ?{$_.spec.name -eq $vendor}))
        {#we have found one or more network_function_chain with the same name
            ForEach ($myvar_network_function_chain_entity in $myvar_network_function_chain)
            {#let's check if any of them apply to our cluster already
                if ($myvar_network_function_chain_entity.spec.cluster_reference.uuid -eq $myvar_cluster_uuid)
                {#we found the service chain already created on our cluster
                    Write-Host "$(get-date) [WARNING] Service chain $($vendor) already exists for cluster $($cluster) with uuid $($myvar_cluster_uuid)" -ForegroundColor Yellow
                    $myvar_service_chain_already_exists = $true
                    $myvar_network_function_chain_uuid = $myvar_network_function_chain_entity.metadata.uuid
                    break
                }
            }
        }
        if ($myvar_service_chain_already_exists -eq $false)
        {#service chain does not already exist so we need to create it for that cluster
            Write-Host "$(get-date) [INFO] Creating the network function chain for the AHV cluster..." -ForegroundColor Green
            $url = "https://$($prismcentral):9440/api/nutanix/v3/network_function_chains"
            $method = "POST"
            $content = @{
                spec=@{
                    name=$vendor;
                    resources=@{
                        network_function_list=@(
                            @{
                                network_function_type=$mode.ToUpper();
                                category_filter=@{
                                    type="CATEGORIES_MATCH_ANY";
                                    params=@{
                                        network_function_provider=@(
                                            $vendor
                                        )
                                    }
                                }
                            }
                        )
                    };
                    cluster_reference=@{
                        kind="cluster";
                        name=$cluster;
                        uuid=$myvar_cluster_uuid
                    }
                };
                api_version="3.1.0";
                metadata=@{
                    kind="network_function_chain"
                }
            }
            $payload = (ConvertTo-Json $content -Depth 9)
            $myvar_network_function_chain_create = Invoke-PrismAPICall -method $method -url $url -credential $prismCredentials -payload $payload
            $myvar_network_function_chain_uuid = $myvar_network_function_chain_create.metadata.uuid
        }
        #endregion create the network function chain on the cluster

        #* step 4: configure nfvms
        Write-Host "$(get-date) [STEP] Processing the configuration of the NFVMs" -ForegroundColor Magenta
        #region configure nfvms
        $myvar_cluster_vip = $myvar_cluster.spec.resources.network.external_ip #figure out the target cluster vip which we will use to ssh into
        $myvar_cvm_nutanix_creds = Get-Credential -Message "Please enter the CVM credentials for the target cluster $($cluster)" -UserName nutanix
        
        Write-Host "$(get-date) [INFO] Opening ssh session to $($cluster) at $($myvar_cluster_vip)..." -ForegroundColor Green
        try {$myvar_ssh_session = New-SshSession -ComputerName $myvar_cluster_vip -Credential $myvar_cvm_nutanix_creds -AcceptKey -ErrorAction Stop}
        catch {throw "$(get-date) [ERROR] Could not open ssh session to $($cluster) at $($myvar_cluster_vip) : $($_.Exception.Message)"}
        Write-Host "$(get-date) [SUCCESS] Opened ssh session to $($cluster) at $($myvar_cluster_vip)." -ForegroundColor Cyan
        
        $myvar_host_index = 0 #we're going to use this in the loop below to pin each NFVM to a different host in the cluster
        ForEach ($myvar_nfvm_object in $myvar_nfvms_objects)
        {#let's process each NFVM object
            Write-Host "$(get-date) [INFO] Processing NFVM $($myvar_nfvm_object.spec.name)..." -ForegroundColor Green
            #todo: build the new spec payload to:
            <# acli
            <acropolis> vm.update steph-rocky1 agent_vm=true extra_flags=is_system_vm=true
            in spec.resources.is_agent_vm, update:
            "is_agent_vm": true
            <acropolis> vm.nic_create steph-rocky1 type=kNetworkFunctionNic network_function_nic_type=kIngress
            <acropolis> vm.nic_create steph-rocky1 type=kNetworkFunctionNic network_function_nic_type=kEgress
            #REPLACE ABOVE TWO STEPS WITH THE FOLLOWING FOR TAP
            <acropolis> vm.nic_create steph-rocky1 type=kNetworkFunctionNic network_function_nic_type=kTap
            in spec.resources.nic_list, add:
            {
                "nic_type": "NETWORK_FUNCTION_NIC",
                "network_function_nic_type": "TAP",
                "vlan_mode": "ACCESS",
                "is_connected": true,
                "trunked_vlan_list": []
            }
            #Tie the NFV VM to a single host so it is guaranteed to capture traffic on this AHV host only.
            <acropolis> vm.affinity_set steph-rocky1 host_list=10.68.97.201 
            this would create a legacy vm:host affinity rule. Need to look in the right way of doing this now (and check PC/AOS/AHV reqs)
            #>
            #todo: check to see if the NFVM has previously been configured
            
            #* mark NFVM as agent and system vm
            Write-Host "$(get-date) [INFO] Marking NFVM $($myvar_nfvm_object.spec.name) as an agent and system vm..." -ForegroundColor Green
            try {$myvar_mark_nfvm_as_agent_system_command_results = Invoke-SshCommand -SessionId $myvar_ssh_session.SessionId -Command "/usr/local/nutanix/bin/acli vm.update $($myvar_nfvm_object.spec.name) agent_vm=true extra_flags=is_system_vm=true" -ErrorAction Stop}
            catch 
            {
                $myvar_saved_error_message = $_.Exception.Message
                Remove-SshSession -SessionId $myvar_ssh_session.SessionId | Out-Null
                throw "$(get-date) [ERROR] Could not mark NFVM $($myvar_nfvm_object.spec.name) as an agent and system vm: $($myvar_saved_error_message)"
            }
            Write-Host "$(get-date) [SUCCESS] Successfully marked NFVM $($myvar_nfvm_object.spec.name) as an agent and system vm" -ForegroundColor Cyan

            #* add required vnic(s) to NFVM
            if ($mode.ToUpper() -eq "TAP") 
            {
                Write-Host "$(get-date) [INFO] Adding $($mode.ToUpper()) vNIC to $($myvar_nfvm_object.spec.name)..." -ForegroundColor Green
                try {$myvar_adding_tap_vnic_command_results = Invoke-SshCommand -SessionId $myvar_ssh_session.SessionId -Command "/usr/local/nutanix/bin/acli vm.nic_create $($myvar_nfvm_object.spec.name) type=kNetworkFunctionNic network_function_nic_type=kTap" -ErrorAction Stop}
                catch 
                {
                    $myvar_saved_error_message = $_.Exception.Message
                    Remove-SshSession -SessionId $myvar_ssh_session.SessionId | Out-Null
                    throw "$(get-date) [ERROR] Could not add $($mode.ToUpper()) vNIC to $($myvar_nfvm_object.spec.name): $($myvar_saved_error_message)"
                }
                Write-Host "$(get-date) [SUCCESS] Successfully added $($mode.ToUpper()) vNIC to $($myvar_nfvm_object.spec.name)" -ForegroundColor Cyan
            }
            elseif ($mode.ToUpper() -eq "INLINE") 
            {
                Write-Host "$(get-date) [INFO] Adding $($mode.ToUpper()) ingress vNIC to $($myvar_nfvm_object.spec.name)..." -ForegroundColor Green
                try {$myvar_adding_tap_vnic_command_results = Invoke-SshCommand -SessionId $myvar_ssh_session.SessionId -Command "/usr/local/nutanix/bin/acli vm.nic_create $($myvar_nfvm_object.spec.name) type=kNetworkFunctionNic network_function_nic_type=kIngress" -ErrorAction Stop}
                catch 
                {
                    $myvar_saved_error_message = $_.Exception.Message
                    Remove-SshSession -SessionId $myvar_ssh_session.SessionId | Out-Null
                    throw "$(get-date) [ERROR] Could not add $($mode.ToUpper()) ingress vNIC to $($myvar_nfvm_object.spec.name): $($myvar_saved_error_message)"
                }
                Write-Host "$(get-date) [SUCCESS] Successfully added $($mode.ToUpper()) ingress vNIC to $($myvar_nfvm_object.spec.name)" -ForegroundColor Cyan

                Write-Host "$(get-date) [INFO] Adding $($mode.ToUpper()) egress vNIC to $($myvar_nfvm_object.spec.name)..." -ForegroundColor Green
                try {$myvar_adding_tap_vnic_command_results = Invoke-SshCommand -SessionId $myvar_ssh_session.SessionId -Command "/usr/local/nutanix/bin/acli vm.nic_create $($myvar_nfvm_object.spec.name) type=kNetworkFunctionNic network_function_nic_type=kEgress" -ErrorAction Stop}
                catch 
                {
                    $myvar_saved_error_message = $_.Exception.Message
                    Remove-SshSession -SessionId $myvar_ssh_session.SessionId | Out-Null
                    throw "$(get-date) [ERROR] Could not add $($mode.ToUpper()) egress vNIC to $($myvar_nfvm_object.spec.name): $($myvar_saved_error_message)"
                }
                Write-Host "$(get-date) [SUCCESS] Successfully added $($mode.ToUpper()) egress vNIC to $($myvar_nfvm_object.spec.name)" -ForegroundColor Cyan
            }
            
            #* create nfvm:host affinity
            $myvar_affinity_host = ($myvar_cluster_hosts | Sort-Object -Property ip)[$myvar_host_index].ip
            Write-Host "$(get-date) [INFO] Creating affinity rule to assign NFVM $($myvar_nfvm_object.spec.name) to host $($myvar_affinity_host)..." -ForegroundColor Green
            try {$myvar_create_affinity_rule_command_results = Invoke-SshCommand -SessionId $myvar_ssh_session.SessionId -Command "/usr/local/nutanix/bin/acli vm.affinity_set $($myvar_nfvm_object.spec.name) host_list=$($myvar_affinity_host)" -ErrorAction Stop}
            catch 
            {
                $myvar_saved_error_message = $_.Exception.Message
                Remove-SshSession -SessionId $myvar_ssh_session.SessionId | Out-Null
                throw "$(get-date) [ERROR] Could not create affinity rule to assign NFVM $($myvar_nfvm_object.spec.name) to host $($myvar_affinity_host): $($myvar_saved_error_message)"
            }
            Write-Host "$(get-date) [SUCCESS] Successfully created affinity rule to assign NFVM $($myvar_nfvm_object.spec.name) to host $($myvar_affinity_host)" -ForegroundColor Cyan

            $myvar_host_index += 1
        }
        
        Remove-SshSession -SessionId $myvar_ssh_session.SessionId | Out-Null
        #endregion configure nfvms

        #* step 5: assign service chain to nfvms
        Write-Host "$(get-date) [STEP] Processing the categorization of NFVMs" -ForegroundColor Magenta
        #region assign service chain to nfvms
        ForEach ($myvar_nfvm_object in $myvar_nfvms_objects)
        {
            Write-Host "$(get-date) [INFO] Assigning the service chain to NFVM $($myvar_nfvm_object.spec.name)" -ForegroundColor Green
            $myvar_already_tagged = $false #assuming our nfvm does not already belong to the category:value

            if (!($myvar_nfvm_object.metadata.categories | ?{$_.network_function_provider -eq "darktrace"}))
            {#this nfvm is not yet associated with the category
                #removing the status section of the vm payload
                $myvar_nfvm_object.PSObject.Properties.Remove('status')

                #adding the category
                try 
                {
                    $myvar_null = $myvar_nfvm_object | Add-Member -MemberType NoteProperty -Name "api_version" -Value "3.1" -PassThru -ErrorAction Stop
                    $myvar_null = $myvar_nfvm_object.metadata.categories_mapping | Add-Member -MemberType NoteProperty -Name "network_function_provider" -Value @($vendor) -PassThru -ErrorAction Stop
                    $myvar_null = $myvar_nfvm_object.metadata.categories | Add-Member -MemberType NoteProperty -Name "network_function_provider" -Value $vendor -PassThru -ErrorAction Stop
                }
                catch {
                    Write-Host "$(Get-Date) [WARNING] Could not add category:value pair $("network_function_provider"):$($vendor) to the NFVM $($myvar_nfvm_object.name)" -ForegroundColor Yellow
                    $myvar_already_tagged = $true
                    continue
                }

                #updating the vm definition
                if (!$myvar_already_tagged)
                {
                    #prepare api call
                    $url = "https://$($prismcentral):9440/api/nutanix/v3/vms/$($myvar_nfvm_object.metadata.uuid)"
                    $method = "PUT"
                    $payload = (ConvertTo-Json $myvar_nfvm_object -Depth 9)

                    #make api call
                    do 
                    {
                        try 
                        {
                            $resp = Invoke-PrismAPICall -method $method -url $url -payload $payload -credential $prismCredentials
                            $task_status = Get-PrismCentralTaskStatus -Task $resp.status.execution_context.task_uuid -cluster $prismcentral -credential $prismCredentials
                            if ($task_status -ine "failed") 
                            {
                                Write-Host "$(Get-Date) [SUCCESS] Successfully updated the configuration of NFVM $($myvar_nfvm_object.spec.name)" -ForegroundColor Cyan
                                $resp_return_code = 200
                            }
                        }
                        catch 
                        {
                            $saved_error = $_.Exception
                            $resp_return_code = $_.Exception.Response.StatusCode.value__
                            if ($resp_return_code -eq 409) 
                            {
                                Write-Host "$(Get-Date) [WARNING] NFVM $($myvar_nfvm_object.name) cannot be updated now. Retrying in 5 seconds..." -ForegroundColor Yellow
                                sleep 5
                            }
                            else 
                            {
                                Write-Host $payload -ForegroundColor White
                                Write-Host "$(get-date) [WARNING] $($saved_error.Message)" -ForegroundColor Yellow
                                Break
                            }
                        }
                    } while ($resp_return_code -eq 409)
                }
            }
            else 
            {
                Write-Host "$(Get-Date) [WARNING] Category:value pair $("network_function_provider"):$($vendor) is already assigned to the NFVM $($myvar_nfvm_object.name)" -ForegroundColor Yellow
            }
        }
        #endregion assign service chain to nfvms

        #* step 6: assign service chain to subnets
        Write-Host "$(get-date) [STEP] Processing the addition of the network chain reference to subnets" -ForegroundColor Magenta
        #region assign service chain to subnets
        ForEach ($myvar_subnet_object in $myvar_subnet_objects)
        {
            Write-Host "$(get-date) [INFO] Processing subnet $($myvar_subnet_object.spec.name)..." -ForegroundColor Green

            $myvar_already_tagged = $false #assuming our nfvm does not already belong to the category:value

            #removing the status section of the subnet payload
            $myvar_subnet_object.PSObject.Properties.Remove('status')

            #adding the nfc reference
            try 
            {
                $myvar_network_function_chain_content = @"
{
    "kind": "network_function_chain",
    "name": "$($vendor)",
    "uuid": "$($myvar_network_function_chain_uuid)"
}
"@
                if (!$myvar_subnet_object.spec.resources.network_function_chain_reference)
                {
                    $myvar_null = $myvar_subnet_object.spec.resources | Add-Member -MemberType NoteProperty -Name "network_function_chain_reference" -Value $(ConvertFrom-Json -InputObject $myvar_network_function_chain_content) -PassThru -ErrorAction Stop
                }
                else 
                {
                    Write-Host "$(get-date) [WARNING] Subnet $($myvar_subnet_object.spec.name) already has a network function chain reference section!" -ForegroundColor Yellow
                    $myvar_already_tagged = $true
                }
            }
            catch 
            {
                Write-Host "$(Get-Date) [WARNING] Could not add the network function chain reference to subnet $($myvar_subnet_object.name)" -ForegroundColor Yellow
                $myvar_already_tagged = $true
                continue
            }

            #updating the subnet definition
            if (!$myvar_already_tagged)
            {
                #prepare api call
                $url = "https://$($prismcentral):9440/api/nutanix/v3/subnets/$($myvar_subnet_object.metadata.uuid)"
                $method = "PUT"

                $payload = (ConvertTo-Json $myvar_subnet_object -Depth 9)

                #make api call
                do 
                {
                    try 
                    {
                        $resp = Invoke-PrismAPICall -method $method -url $url -payload $payload -credential $prismCredentials
                        $task_status = Get-PrismCentralTaskStatus -Task $resp.status.execution_context.task_uuid -cluster $prismcentral -credential $prismCredentials
                        if ($task_status -ine "failed") 
                        {
                            Write-Host "$(Get-Date) [SUCCESS] Successfully updated the configuration of subnet $($myvar_subnet_object.name)" -ForegroundColor Cyan
                            $resp_return_code = 200
                        }
                    }
                    catch 
                    {
                        $saved_error = $_.Exception
                        $resp_return_code = $_.Exception.Response.StatusCode.value__
                        if ($resp_return_code -eq 409) 
                        {
                            Write-Host "$(Get-Date) [WARNING] Subnet $($myvar_subnet_object.name) cannot be updated now. Retrying in 5 seconds..." -ForegroundColor Yellow
                            sleep 5
                        }
                        else 
                        {
                            Write-Host $payload -ForegroundColor White
                            Write-Host "$(get-date) [WARNING] $($saved_error.Message)" -ForegroundColor Yellow
                            Break
                        }
                    }
                } while ($resp_return_code -eq 409)
            }
        }
        #endregion assign service chain to subnets
    }
    elseif ($action -eq "delete")
    {
        #* step 1: remove network function chain reference from subnets
        Write-Host "$(get-date) [STEP] Removing network function chain reference from subnets" -ForegroundColor Magenta
        #todo: retrieve list of subnets and identify those which have the nfc reference in their spec.resources section
        ForEach ($myvar_subnet_object in $myvar_subnet_objects)
        {
            Write-Host "$(get-date) [INFO] Processing subnet $($myvar_subnet_object.spec.name)..." -ForegroundColor Green

            $myvar_already_tagged = $false #assuming our nfvm does not already belong to the category:value

            #removing the status section of the subnet payload
            $myvar_subnet_object.PSObject.Properties.Remove('status')
            $myvar_subnet_object.spec.resources.PSObject.Properties.Remove('network_function_chain_reference')

            #prepare api call
            $url = "https://$($prismcentral):9440/api/nutanix/v3/subnets/$($myvar_subnet_object.metadata.uuid)"
            $method = "PUT"

            $payload = (ConvertTo-Json $myvar_subnet_object -Depth 9)

            #make api call
            do 
            {
                try 
                {
                    $resp = Invoke-PrismAPICall -method $method -url $url -payload $payload -credential $prismCredentials
                    $task_status = Get-PrismCentralTaskStatus -Task $resp.status.execution_context.task_uuid -cluster $prismcentral -credential $prismCredentials
                    if ($task_status -ine "failed") 
                    {
                        Write-Host "$(Get-Date) [SUCCESS] Successfully updated the configuration of subnet $($myvar_subnet_object.name)" -ForegroundColor Cyan
                        $resp_return_code = 200
                    }
                }
                catch 
                {
                    $saved_error = $_.Exception
                    $resp_return_code = $_.Exception.Response.StatusCode.value__
                    if ($resp_return_code -eq 409) 
                    {
                        Write-Host "$(Get-Date) [WARNING] Subnet $($myvar_subnet_object.name) cannot be updated now. Retrying in 5 seconds..." -ForegroundColor Yellow
                        sleep 5
                    }
                    else 
                    {
                        Write-Host $payload -ForegroundColor White
                        Write-Host "$(get-date) [WARNING] $($saved_error.Message)" -ForegroundColor Yellow
                        Break
                    }
                }
            } while ($resp_return_code -eq 409)
        }
        
        #* step 2: remove category from nfvms
        Write-Host "$(get-date) [STEP] Removing category from NFVMs" -ForegroundColor Magenta
        ForEach ($myvar_nfvm_object in $myvar_nfvms_objects)
        {
            Write-Host "$(get-date) [INFO] Removing the service chain from NFVM $($myvar_nfvm_object.spec.name)" -ForegroundColor Green
            $myvar_already_tagged = $false #assuming our nfvm does not already belong to the category:value

            if ($myvar_nfvm_object.metadata.categories | ?{$_.network_function_provider -eq "darktrace"})
            {#this nfvm is associated with the category
                #removing the status section of the vm payload
                $myvar_nfvm_object.PSObject.Properties.Remove('status')

                #removing the category
                try 
                {
                    $myvar_null = $myvar_nfvm_object | Add-Member -MemberType NoteProperty -Name "api_version" -Value "3.1" -PassThru -ErrorAction Stop
                    $myvar_null = $myvar_nfvm_object.metadata.categories_mapping | Add-Member -MemberType NoteProperty -Name "network_function_provider" -Value @($vendor) -PassThru -ErrorAction Stop
                    $myvar_null = $myvar_nfvm_object.metadata.categories | Add-Member -MemberType NoteProperty -Name "network_function_provider" -Value $vendor -PassThru -ErrorAction Stop
                }
                catch {
                    Write-Host "$(Get-Date) [WARNING] Could not add category:value pair $("network_function_provider"):$($vendor) to the NFVM $($myvar_nfvm_object.name)" -ForegroundColor Yellow
                    $myvar_already_tagged = $true
                    continue
                }

                #updating the vm definition
                if (!$myvar_already_tagged)
                {
                    #prepare api call
                    $url = "https://$($prismcentral):9440/api/nutanix/v3/vms/$($myvar_nfvm_object.metadata.uuid)"
                    $method = "PUT"
                    $payload = (ConvertTo-Json $myvar_nfvm_object -Depth 9)

                    #make api call
                    do 
                    {
                        try 
                        {
                            $resp = Invoke-PrismAPICall -method $method -url $url -payload $payload -credential $prismCredentials
                            $task_status = Get-PrismCentralTaskStatus -Task $resp.status.execution_context.task_uuid -cluster $prismcentral -credential $prismCredentials
                            if ($task_status -ine "failed") 
                            {
                                Write-Host "$(Get-Date) [SUCCESS] Successfully updated the configuration of NFVM $($myvar_nfvm_object.spec.name)" -ForegroundColor Cyan
                                $resp_return_code = 200
                            }
                        }
                        catch 
                        {
                            $saved_error = $_.Exception
                            $resp_return_code = $_.Exception.Response.StatusCode.value__
                            if ($resp_return_code -eq 409) 
                            {
                                Write-Host "$(Get-Date) [WARNING] NFVM $($myvar_nfvm_object.name) cannot be updated now. Retrying in 5 seconds..." -ForegroundColor Yellow
                                sleep 5
                            }
                            else 
                            {
                                Write-Host $payload -ForegroundColor White
                                Write-Host "$(get-date) [WARNING] $($saved_error.Message)" -ForegroundColor Yellow
                                Break
                            }
                        }
                    } while ($resp_return_code -eq 409)
                }
            }
            else 
            {
                Write-Host "$(Get-Date) [WARNING] Category:value pair $("network_function_provider"):$($vendor) is not assigned to the NFVM $($myvar_nfvm_object.name)" -ForegroundColor Yellow
            }
        }

        #* step 3: delete the network function chain
        Write-Host "$(get-date) [STEP] Deleting the network function chain" -ForegroundColor Magenta
        Write-Host "$(get-date) [INFO] Retrieving list of network function chains from Prism Central..." -ForegroundColor Green
        $myvar_network_function_chains = Get-PrismCentralObjectList -pc $prismcentral -object "network_function_chains" -kind "network_function_chain"
        $myvar_network_function_chain = $myvar_network_function_chains | ?{$_.spec.name -ieq $vendor}
        if (!$myvar_network_function_chain)
        {#we couldn't find the network function chain
            Write-Host "$(get-date) [WARNING] Network function chain $($vendor) has not been found on Prism Central $($prismcentral). Maybe it was already deleted." -ForegroundColor Green
        }
        else 
        {#we found the network function chain, let's delete it
            Write-Host "$(get-date) [INFO] Deleting the network function chain for the AHV cluster..." -ForegroundColor Green
            $url = "https://$($prismcentral):9440/api/nutanix/v3/network_function_chains/$($myvar_network_function_chain.metadata.uuid)"
            $method = "DELETE"
            $myvar_network_function_chain_delete = Invoke-PrismAPICall -method $method -url $url -credential $prismCredentials
        }
    }
    elseif ($action -eq "add_host")
    {
        #todo: make sure the specified host is in the cluster
        #todo: make sure the specified nfvm exists
        #todo: configure the new nfvm
    }
    elseif ($action -eq "add_subnet")
    {
        #todo: make sure the specified subnet exists and does not already have the nfc reference
        #todo: make sure the specified nfc exists
        #todo: update the subnet with the nfc reference
    }
    elseif ($action -eq "remove_subnet")
    {
        #todo: make sure the specified subnet exists and has the nfc reference
        #todo: update the subnet to remove the nfc reference
    }
#endregion

#region cleanup
    #let's figure out how much time this all took
    Write-Host "$(get-date) [SUM] total processing time: $($myvarElapsedTime.Elapsed.ToString())" -ForegroundColor Magenta

    #cleanup after ourselves and delete all custom variables
    Remove-Variable myvar* -ErrorAction SilentlyContinue
    Remove-Variable ErrorActionPreference -ErrorAction SilentlyContinue
    Remove-Variable help -ErrorAction SilentlyContinue
    Remove-Variable history -ErrorAction SilentlyContinue
    Remove-Variable log -ErrorAction SilentlyContinue
    Remove-Variable cluster -ErrorAction SilentlyContinue
    Remove-Variable debugme -ErrorAction SilentlyContinue
#endregion