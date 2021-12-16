<#
.SYNOPSIS
  This script creates Zabbix items and triggers based on possible alerts in Prism. It takes a csv file as import which can be created using the get-ntnxAlertPolicy.ps1 script.
.DESCRIPTION
  This script creates Zabbix items and triggers based on possible alerts in Prism. It takes a csv file as import which can be created using the get-ntnxAlertPolicy.ps1 script.
  It assumes SNMP traps have been configured correctly between Prism and Zabbix, and that there is a "Template Nutanix" template object created on the Zabbix server.
.PARAMETER help
  Displays a help message (seriously, what did you think this was?)
.PARAMETER history
  Displays a release history for this script (provided the editors were smart enough to document this...)
.PARAMETER log
  Specifies that you want the output messages to be written in a log file as well as on the screen.
.PARAMETER debugme
  Turns off SilentlyContinue on unexpected error messages.
.PARAMETER inputcsv
  Path and name of the input csv file you want to use.  This file can be generated using the get-ntnxAlertPolicy.ps1 script.
.PARAMETER zabbix
  FQDN or IP address of the Zabbix server (assuming v4 or above for API methods).
.PARAMETER zabbixCreds
  Specifies a custom credentials file name (will look for %USERPROFILE\Documents\WindowsPowerShell\CustomCredentials\$prismCreds.txt). These credentials can be created using the Powershell command 'Set-CustomCredentials -credname <credentials name>'. See https://blog.kloud.com.au/2016/04/21/using-saved-credentials-securely-in-powershell-scripts/ for more details.
.PARAMETER alertName
  String to be used in the regular expressions used by Zabbix to differentiate SNMP traps.  You can use wildcards.
  Possible alert names are listed in the inputcsv file generated by the get-ntnxAlertPolicy.ps1 script.
  If you want to include all alerts, set this parameter value to "all" (without the quotes).
.PARAMETER template
  Name of the Nutanix tempalte object on the Zabbix server (default is "Template Nutanix")
.EXAMPLE
.\set-ZabbixNutanixTemplate.ps1 -zabbix zabbix-server1.local -zabbixCreds myZabbixCredsFile -alertName "File Server*" -template "Nutanix-template" -inputcsv cluster1-alertPolicy.csv
Add items and triggers for all alerts in the cluster1-alertPolicy.csv file with name that start with "File Server":
.LINK
  http://www.nutanix.com/services
.NOTES
  Author: Stephane Bourdeaud (sbourdeaud@nutanix.com)
  Revision: December 16th 2021
#>

#region parameters
    Param
    (
        #[parameter(valuefrompipeline = $true, mandatory = $true)] [PSObject]$myParam1,
        [parameter(mandatory = $false)] [switch]$help,
        [parameter(mandatory = $false)] [switch]$history,
        [parameter(mandatory = $false)] [switch]$log,
        [parameter(mandatory = $false)] [switch]$debugme,
        [parameter(mandatory = $true)] [string]$inputcsv,
        [parameter(mandatory = $true)] [string]$zabbix,
        [parameter(mandatory = $false)] $zabbixCreds,
        [parameter(mandatory = $true)] [string]$alertName,
        [parameter(mandatory = $false)] [string]$template
    )
#endregion parameters

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
#endregion functions

#region prepwork
    $HistoryText = @'
Maintenance Log
Date       By   Updates (newest updates at the top)
---------- ---- ---------------------------------------------------------------
12/01/2021 sb   Initial release.
12/09/2021 sb   Added ability to specify all alerts.
12/16/2021 sb   Made sure to remove double quotes from alert messages as this
                was causing issues on items creation.
                Added max_message_length variable to work around the 255 chars
                limits for expression in zabbix.
################################################################################
'@
    $myvarScriptName = ".\set-ZabbixNutanixTemplate.ps1"

    if ($help) {get-help $myvarScriptName; exit}
    if ($History) {$HistoryText; exit}

    #check PoSH version
    if ($PSVersionTable.PSVersion.Major -lt 5) {throw "$(get-date) [ERROR] Please upgrade to Powershell v5 or above (https://www.microsoft.com/en-us/download/details.aspx?id=50395)"}

    #check if we have all the required PoSH modules
    Write-LogOutput -Category "INFO" -LogFile $myvarOutputLogFile -Message "Checking for required Powershell modules..."

    
    Set-PoSHSSLCerts
    Set-PoshTls
#endregion prepwork

#region variables
    $myvarElapsedTime = [System.Diagnostics.Stopwatch]::StartNew() #used to store script begin timestamp
    $max_message_length = 75 #used to limit the length of alert messages
#endregion variables

#region parameters validation
    if (!$zabbixCreds) 
    {#we are not using custom credentials, so let's ask for a username and password if they have not already been specified
        $zabbixCredentials = Get-Credential -Message "Please enter Zabbix credentials"
    } 
    else 
    { #we are using custom credentials, so let's grab the username and password from that
        try 
        {
            $zabbixCredentials = Get-CustomCredentials -credname $zabbixCreds -ErrorAction Stop
        }
        catch 
        {
            Set-CustomCredentials -credname $zabbixCreds
            $zabbixCredentials = Get-CustomCredentials -credname $zabbixCreds -ErrorAction Stop
        }
    }
    $username = $zabbixCredentials.UserName
    $ZabbixSecurePassword = $zabbixCredentials.Password
    $zabbixCredentials = New-Object PSCredential $username, $ZabbixSecurePassword

    if (!$template) {$template = "Template Nutanix"}
#endregion parameters validation

#region processing	
    Write-Host "$(get-date) [INFO] Importing content from $($inputcsv)..." -ForegroundColor Green
    if (Test-Path -Path $inputcsv) 
    {#file exists
        $myvar_alert_policy = Import-Csv -Path $inputcsv
        Write-Host "$(get-date) [SUCCESS] Imported content from $($inputcsv)!" -ForegroundColor Cyan
    }
    else 
    {#file does not exist
        throw "The specified csv file $($inputcsv) does not exist!"
    }
    
    Write-Host "$(get-date) [INFO] Determining list of alerts using '$($alertName)' as the search string..." -ForegroundColor Green
    if ($alertName -ieq "all")
    {#we want all alerts
        $myvar_alert_list = $myvar_alert_policy
    }
    else 
    {#we are filtering alerts
        $myvar_alert_list = $myvar_alert_policy | Where-Object {$_.name -like $alertName}
    }
    if ($myvar_alert_list.Count -lt 1)
    {#there is no matching alert
        throw "There is no alert matching search string '$($alertName)' in $($inputcsv)!"
    }
    else 
    {#we found matching alert(s)
        Write-Host "$(get-date) [DATA] Found $($myvar_alert_list.Count) alert(s) matching search string '$($alertName)' in $($inputcsv)." -ForegroundColor White
    }

    Write-Host "$(get-date) [INFO] Logging into Zabbix server $($zabbix)..." -ForegroundColor Green
    #region prepare api call
        $api_server = $zabbix
        $api_server_endpoint = "/zabbix/api_jsonrpc.php"
        $url = "http://{0}{1}" -f $api_server,$api_server_endpoint
        $method = "POST"
        $content = @{
            jsonrpc= "2.0";
            method="user.login";
            params=@{
                user=$zabbixCredentials.UserName;
                password=$zabbixCredentials.GetNetworkCredential().password;
            }
            id= "1";
            auth=$null;
        }
        $payload = (ConvertTo-Json $content -Depth 4)
        $headers = @{
            "Content-Type"="application/json";
            "Accept"="application/json"
        }
    #endregion prepare api call
    #region make api call
        try 
        {#login to zabbix server
            $zabbix_user_login_response = Invoke-RestMethod -Method Post -Body $payload -Headers $headers -Uri $url
            $zabbix_user_login_auth = $zabbix_user_login_response.result
            Write-Host "$(get-date) [SUCCESS] Connected to Zabbix server $($zabbix) with user $($zabbixCredentials.username)!" -ForegroundColor Cyan
        }
        catch 
        {#couldn't login to zabbix server
            $saved_error = $_.Exception.Message
            Write-Host "$(Get-Date) [DEBUG] Url: $url" -ForegroundColor White
            Write-Host "$(Get-Date) [DEBUG] Headers: $headers" -ForegroundColor White
            Write-Host "$(Get-Date) [DEBUG] Payload: $payload" -ForegroundColor White
            Throw "$(get-date) [ERROR] $saved_error"
        }
    #endregion make api call
    
    Write-Host "$(get-date) [INFO] Getting template $($template) from $($zabbix)..." -ForegroundColor Green
    #region prepare api call
        $api_server = $zabbix
        $api_server_endpoint = "/zabbix/api_jsonrpc.php"
        $url = "http://{0}{1}" -f $api_server,$api_server_endpoint
        $method = "POST"
        $content = @{
            jsonrpc= "2.0";
            method="template.get";
            params=@{
                output="extend";
                filter=@{
                    host=@(
                        "$template"
                    )
                }
            }
            id= "1";
            auth=$zabbix_user_login_auth;
        }
        $payload = (ConvertTo-Json $content -Depth 4)
        $headers = @{
            "Content-Type"="application/json";
            "Accept"="application/json"
        }
    #endregion prepare api call
    #region make api call
        try 
        {#get template object
            $zabbix_template_get_response = Invoke-RestMethod -Method Post -Body $payload -Headers $headers -Uri $url
            if ($zabbix_template_get_response.result.Count -lt 1)
            {
                Throw "$(get-date) [ERROR] Could not find template $($template) on Zabbix server $($zabbix)!"
            }
            else 
            {
                $zabbix_templateid = $zabbix_template_get_response.result.templateid
                Write-Host "$(get-date) [SUCCESS] Found template '$($template)' with id $($zabbix_templateid) on server $($zabbix)!" -ForegroundColor Cyan
            }
        }
        catch 
        {#couldn't get template object
            $saved_error = $_.Exception.Message
            Write-Host "$(Get-Date) [DEBUG] Url: $url" -ForegroundColor White
            Write-Host "$(Get-Date) [DEBUG] Headers: $headers" -ForegroundColor White
            Write-Host "$(Get-Date) [DEBUG] Payload: $payload" -ForegroundColor White
            Throw "$(get-date) [ERROR] $saved_error"
        }
    #endregion make api call

    Write-Host "$(get-date) [INFO] Processing each alert..." -ForegroundColor Green
        Foreach ($alert in $myvar_alert_list)
        {
            $alert_name = $alert.name
            $alert_message = $alert.message -replace '"' #removing any double quote character from the message
            $alert_message = $alert_message.subString(0, [System.Math]::Min($max_message_length, $alert_message.Length)) #trimming alert message to a limited number of characters characters
            $alert_message = $alert_message -replace "({[\S]*})", "[\S]*" #substituting any {variable} in the message with a regex
            if ($alert_message -eq "[\S]*")
            {#message is unpredictable: replacing with title
                $alert_message = $alert.title
            }
            $alert_message = "`"$alert_message`"" #enclosing the whole thing in double quotes so special characters will be properly escaped when converted to json
            $alert_severity = $alert.severity
            $alert_comment = "Category Type: $($alert.categoryTypes)`nAffected Entity Type:$($alert.affectedEntityTypes)`nSubcategory Type:$($alert.subCategoryTypes)`nScope:$($alert.scope)`nTitle:$($alert.title)`nName:$($alert.name)`nMessage:$($alert.message)`nDescription:$($alert.description)`nDescription:$($alert.description)`nCauses:$($alert.causes)`nResolution:$($alert.resolutions)`nNutanix KB:$($alert.kblist)"

            Write-Host "$(get-date) [INFO] Creating item for alert '$($alert_name)' on $($zabbix) in template '$($template)' using '$($alert_message)' as the regex..." -ForegroundColor Green
            #region prepare api call
                $api_server = $zabbix
                $api_server_endpoint = "/zabbix/api_jsonrpc.php"
                $url = "http://{0}{1}" -f $api_server,$api_server_endpoint
                $method = "POST"
                $content = @{
                    jsonrpc= "2.0";
                    method="item.create";
                    params=@{
                        name="$($alert_name)";
                        key_="snmptrap[$alert_message]";
                        hostid=$zabbix_templateid;
                        type=17;
                        value_type="4";
                        history="90d";
                        delay="30s"
                    }
                    id= "1";
                    auth=$zabbix_user_login_auth;
                }
                $payload = (ConvertTo-Json $content -Depth 4)
                $headers = @{
                    "Content-Type"="application/json";
                    "Accept"="application/json"
                }
            #endregion prepare api call
            #region make api call
                try 
                {#create item
                    $zabbix_item_create_response = Invoke-RestMethod -Method Post -Body $payload -Headers $headers -Uri $url -ErrorAction Stop
                    if ($zabbix_item_create_response.result.Count -lt 1)
                    {#item did not create
                        if ($zabbix_item_create_response.error.data -match "already exists")
                        {#item already exists
                            Write-Host "$(get-date) [WARNING] Item for alert '$($alert_name)' on $($zabbix) in template '$($template)' using '$($alert_message)' as the regex already exists!" -ForegroundColor Yellow
                            continue
                        }
                        Throw "$($zabbix_item_create_response.error.message): $($zabbix_item_create_response.error.data)"
                    }
                    else 
                    {#item created successfully
                        $zabbix_itemid = $zabbix_item_create_response.result.itemids[0]
                        Write-Host "$(get-date) [SUCCESS] Created item id $($zabbix_itemid) in template '$($template)' on server $($zabbix) for alert '$($alert_name)'!" -ForegroundColor Cyan   
                    }
                }
                catch 
                {#couldn't create item
                    $saved_error = $_.Exception.Message
                    Write-Host "$(Get-Date) [DEBUG] Url: $url" -ForegroundColor White
                    Write-Host "$(Get-Date) [DEBUG] Headers: $headers" -ForegroundColor White
                    Write-Host "$(Get-Date) [DEBUG] Payload: $payload" -ForegroundColor White
                    Throw "$(get-date) [ERROR] $saved_error"
                }
            #endregion make api call

            Write-Host "$(get-date) [INFO] Creating trigger for alert '$($alert_name)' on $($zabbix) in template '$($template)' using '$($alert_message)' as the regex with severity $($alert_severity)..." -ForegroundColor Green
            #region prepare api call
            Switch ($alert_severity)
            {
                "kInfo" {$priority = "1"}
                "kWarning" {$priority = "2"}
                "kCritical" {$priority = "4"}
            }

            $api_server = $zabbix
            $api_server_endpoint = "/zabbix/api_jsonrpc.php"
            $url = "http://{0}{1}" -f $api_server,$api_server_endpoint
            $method = "POST"
            #$expression = "{$($template):snmptrap[$alert_message].iregexp($alert_message)}=1"
            #$expression.subString(0, [System.Math]::Min(255, $expression.Length)) #making sure the expression does not exceed 255 characters
            $content = @{
                jsonrpc= "2.0";
                method="trigger.create";
                params=@{
                    description="$($alert_name)";
                    expression="{$($template):snmptrap[$alert_message].iregexp($alert_message)}=1";
                    url="";
                    comments="$alert_comment";
                    manual_close="1";
                    priority="$priority"
                }
                id= "1";
                auth=$zabbix_user_login_auth;
            }
            $payload = (ConvertTo-Json $content -Depth 4)
            $headers = @{
                "Content-Type"="application/json";
                "Accept"="application/json"
            }
            #endregion prepare api call
            #region make api call
                try 
                {#create trigger
                    $zabbix_trigger_create_response = Invoke-RestMethod -Method Post -Body $payload -Headers $headers -Uri $url -ErrorAction Stop
                    if ($zabbix_trigger_create_response.result.Count -lt 1)
                    {#trigger did not create
                        if ($zabbix_trigger_create_response.error.data -match "already exists")
                        {#item already exists
                            Write-Host "$(get-date) [WARNING] Trigger for alert '$($alert_name)' on $($zabbix) in template '$($template)' using '$($alert_message)' as the regex already exists!" -ForegroundColor Yellow
                            continue
                        }
                        Throw "$($zabbix_trigger_create_response.error.message): $($zabbix_trigger_create_response.error.data)"
                    }
                    else 
                    {#trigger created successfully
                        $zabbix_triggerid = $zabbix_trigger_create_response.result.triggerids[0]
                        Write-Host "$(get-date) [SUCCESS] Created trigger id $($zabbix_triggerid) in template '$($template)' on server $($zabbix) for alert '$($alert_name)'!" -ForegroundColor Cyan   
                    }
                }
                catch 
                {#couldn't create trigger
                    $saved_error = $_.Exception.Message
                    Write-Host "$(Get-Date) [DEBUG] Url: $url" -ForegroundColor White
                    Write-Host "$(Get-Date) [DEBUG] Headers: $headers" -ForegroundColor White
                    Write-Host "$(Get-Date) [DEBUG] Payload: $payload" -ForegroundColor White
                    Throw "$(get-date) [ERROR] $saved_error"
                }
            #endregion make api call

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
    Remove-Variable debugme -ErrorAction SilentlyContinue
#endregion cleanup