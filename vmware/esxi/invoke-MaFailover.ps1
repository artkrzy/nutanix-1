<#
.SYNOPSIS
  This script is used to trigger a planned failover for the specified metro availability protection domains on the specified cluster.
.DESCRIPTION
  The script will look at the Metro Availability setup for a pair of given Nutanix clusters and will create DRS affinity groups and rules so that VMs will run on hosts which hold the active copy of a given replicated datastore. This is to avoid I/O going over two sites in normal conditions.  If DRS groups and rules already exist that match the naming convention used in this script, then it will update those groups and rules (unless you use the -noruleupdate switch in which case only groups will be updated).  This script requires having both the Nutanix cmdlets and PowerCLI installed.
.PARAMETER help
  Displays a help message (seriously, what did you think this was?)
.PARAMETER history
  Displays a release history for this script (provided the editors were smart enough to document this...)
.PARAMETER debugme
  Turns off SilentlyContinue on unexpected error messages.
.PARAMETER cluster
  Nutanix cluster fully qualified domain name or IP address.
.PARAMETER pd
  Nutanix metro availability protection domain name (can be "all" or a comma separated list).
.PARAMETER action
  This defines what status the Nutanix cluster is left in. If not specified, the Nutanix cluster will be left as is.  If "maintenance", any remaiing UVMs will be powered off, then the Nutanix cluster will be stopped, the CVMs shut down and the ESXi hosts put in maintenance mode.  If "shutdown", UVMs will be powered off, the Nutanix cluster stopped, CVMs shut down, ESXI hosts put in maintenance mode and then powered off.
.PARAMETER skipfailover
  Skip over migration of protection domains and only perform action specified on esxi hosts (maintenance or shutdown). This is useful to resume action if protection domains have already been migrated but there were still UVMs running on the cluster and it could not put hosts in maintenance mode and/or shut them down.
.PARAMETER shutdownUvms
  ***WARNING*** Specifies that if any remaining user virtual machines are found on a vmhost, they should be powered off. Those would be VMs which were not protected by a metro protection domain or were running on the wrong hosts. Be careful with this parameter!
.PARAMETER timer
  Number of seconds you want to wait for VMs to shutdown cleanly (when using -shutdownUvms) before powering them off forcefully. Default is 300 seconds (5 minutes).
.PARAMETER reEnableOnly
  Try to enable specified active but disabled metro protection domains. Do nothing else.
.PARAMETER prismCreds
  Specifies a custom credentials file name for Prism authentication (will look for %USERPROFILE\Documents\WindowsPowerShell\CustomCredentials\$prismCreds.txt). The first time you run it, it will prompt you for a username and password, and will then store this information encrypted locally (the info can be decrupted only by the same user on the machine where the file was generated).
  If you do not specify a credential file and do not use username or password, the script will prompt you for this information.
.PARAMETER vcenterCreds
  Specifies a custom credentials file name for vCenter authentication (will look for %USERPROFILE\Documents\WindowsPowerShell\CustomCredentials\$vcenterCreds.txt). The first time you run it, it will prompt you for a username and password, and will then store this information encrypted locally (the info can be decrupted only by the same user on the machine where the file was generated).
  If you do not specify a credential file, the script will prompt you for this information, unless your logged in user already has access to vCenter.
.PARAMETER cvmCreds
  Specifies a custom credentials file name for CVM ssh authentication (will look for %USERPROFILE\Documents\WindowsPowerShell\CustomCredentials\$cvmCreds.txt). The first time you run it, it will prompt you for a username and password, and will then store this information encrypted locally (the info can be decrupted only by the same user on the machine where the file was generated).
  If you do not specify a credential file, the script will prompt you for this information.
.PARAMETER resetOverrides
  Specifies that if a VM has a DRS override, you want to remove it automatically so that DRS can move the VM.
.EXAMPLE
.\invoke-MAFailover.ps1 -cluster c1.local -pd all -action maintenance
Trigger a manual failover of all metro protection domains and put esxi hosts in maintenance mode:
.LINK
  http://www.nutanix.com/services
.NOTES
  Author: Stephane Bourdeaud (sbourdeaud@nutanix.com)
  Revision: June 2nd 2021
#>

#region parameters
    Param
    (
        #[parameter(valuefrompipeline = $true, mandatory = $true)] [PSObject]$myParam1,
        [parameter(mandatory = $false)] [switch]$help,
        [parameter(mandatory = $false)] [switch]$history,
        [parameter(mandatory = $false)] [switch]$debugme,
        [parameter(mandatory = $false)] [string]$cluster,
        [parameter(mandatory = $false)] [string]$pd,
        [parameter(mandatory = $false)] $prismCreds,
        [parameter(mandatory = $false)] $vcenterCreds,
        [parameter(mandatory = $false)] $cvmCreds,
        [parameter(mandatory = $false)] [string][ValidateSet("maintenance","shutdown")]$action,
        [parameter(mandatory = $false)] [switch]$skipfailover,
        [parameter(mandatory = $false)] [switch]$shutdownUvms,
        [parameter(mandatory = $false)] [switch]$resetOverrides,
        [parameter(mandatory = $false)] [int]$timer,
        [parameter(mandatory = $false)] [switch]$reEnableOnly
    )
#endregion

#region functions
    #this function is used to connect to Prism REST API
    Function Invoke-PrismRESTCall
    {
        #input: username, password, url, method, body
        #output: REST response
    <#
    .SYNOPSIS
    Connects to Nutanix Prism REST API.
    .DESCRIPTION
    This function is used to connect to Prism REST API.
    .NOTES
    Author: Stephane Bourdeaud
    .PARAMETER username
    Specifies the Prism username.
    .PARAMETER password
    Specifies the Prism password.
    .PARAMETER url
    Specifies the Prism url.
    .EXAMPLE
    PS> PrismRESTCall -username admin -password admin -url https://10.10.10.10:9440/PrismGateway/services/rest/v1/ 
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
            $credential
        )

        begin
        {
    
        }
        process
        {
            Write-Host "$(Get-Date) [INFO] Making a $method call to $url" -ForegroundColor Green
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
                    $headers = @{
                        "Authorization" = "Basic "+[System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($username+":"+([System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($PrismSecurePassword))) ));
                        "Content-Type"="application/json";
                        "Accept"="application/json"
                    }
                    if ($payload) {
                        $resp = Invoke-RestMethod -Method $method -Uri $url -Headers $headers -Body $payload -ErrorAction Stop
                    } else {
                        $resp = Invoke-RestMethod -Method $method -Uri $url -Headers $headers -ErrorAction Stop
                    }
                }
                Write-Host "$(get-date) [SUCCESS] Call $method to $url succeeded." -ForegroundColor Cyan 
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
    }#end function Get-PrismRESTCall

    #Function Get-RESTError
    Function Get-RESTError 
    {
        $global:helpme = $body
        $global:helpmoref = $moref
        $global:result = $_.Exception.Response.GetResponseStream()
        $global:reader = New-Object System.IO.StreamReader($global:result)
        $global:responseBody = $global:reader.ReadToEnd();

        return $global:responsebody

        break
    }#end function Get-RESTError

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
    }#end function Set-CustomCredentials

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
    }#end function Get-CustomCredentials

    #this function is used to create a VM to host DRS rule
    Function Update-DRSVMToHostRule
    {
    <#
    .SYNOPSIS
    Creates a new DRS VM to host rule
    .DESCRIPTION
    This function creates a new DRS vm to host rule
    .NOTES
    Author: Arnim van Lieshout
    .PARAMETER VMGroup
    The VMGroup name to include in the rule.
    .PARAMETER HostGroup
    The VMHostGroup name to include in the rule.
    .PARAMETER Cluster
    The cluster to create the new rule on.
    .PARAMETER Name
    The name for the new rule.
    .PARAMETER AntiAffine
    Switch to make the rule an AntiAffine rule. Default rule type is Affine.
    .PARAMETER Mandatory
    Switch to make the rule mandatory (Must run rule). Default rule is not mandatory (Should run rule)
    .EXAMPLE
    PS> New-DrsVMToHostRule -VMGroup "VMGroup01" -HostGroup "HostGroup01" -Name "VMToHostRule01" -Cluster CL01 -AntiAffine -Mandatory
    #>

        Param(
            [parameter(mandatory = $true,
            HelpMessage = "Enter a VM DRS group name")]
                [String]$VMGroup,
            [parameter(mandatory = $true,
            HelpMessage = "Enter a DRS rule key")]
                [String]$RuleKey,
            [parameter(mandatory = $true,
            HelpMessage = "Enter a DRS rule uuid")]
                [String]$RuleUuid,
            [parameter(mandatory = $true,
            HelpMessage = "Enter a host DRS group name")]
                [String]$HostGroup,
            [parameter(mandatory = $true,
            HelpMessage = "Enter a cluster entity")]
                [PSObject]$Cluster,
            [parameter(mandatory = $true,
            HelpMessage = "Enter a name for the group")]
                [String]$Name,
                [Switch]$AntiAffine,
                [Switch]$Mandatory)

        switch ($Cluster.gettype().name) {
            "String" {$cluster = Get-Cluster $cluster | Get-View}
            "ClusterImpl" {$cluster = $cluster | Get-View}
            "Cluster" {}
            default {throw "No valid type for parameter -Cluster specified"}
        }

        $spec = New-Object VMware.Vim.ClusterConfigSpecEx
        $rule = New-Object VMware.Vim.ClusterRuleSpec
        $rule.operation = "edit"
        $rule.info = New-Object VMware.Vim.ClusterVmHostRuleInfo
        $rule.info.enabled = $true
        $rule.info.name = $Name
        $rule.info.mandatory = $Mandatory
        $rule.info.vmGroupName = $VMGroup
        $rule.info.Key = $RuleKey
        $rule.info.RuleUuid = $RuleUuid
        if ($AntiAffine) {
            $rule.info.antiAffineHostGroupName = $HostGroup
        }
        else {
            $rule.info.affineHostGroupName = $HostGroup
        }
        $spec.RulesSpec += $rule
        $cluster.ReconfigureComputeResource_Task($spec,$true) | Out-Null
    }#end function Update-DRSVMToHostRule

    #this function puts all the Nutanix ESXi hosts in a given cluster in maintenance mode
    Function Set-NtnxVmhostsToMaintenanceMode
    {
        #todo think about changes to make this "resumable" (assuming problems with vmotions, etc...)
        #? params/variables required: $myvar_ntnx_vmhosts, $myvar_cvm_names, $myvar_ntnx_cluster_name, $myvar_cvm_ips

        Write-Host ""
        Write-Host "$(get-date) [STEP] Checking if there are still running UVMs on the Nutanix cluster ESXi hosts..." -ForegroundColor Magenta   

        #* check if there are running uvms on each host
        #check each host ($myvar_ntnx_vmhosts) to see if they have running vms other than cvms
        foreach ($myvar_vmhost in $myvar_ntnx_vmhosts) {
            try 
            {
                $myvar_running_vms = $myvar_vmhost | Get-VM -ErrorAction Stop | Where-Object {$_.PowerState -eq "PoweredOn"}
            }
            catch 
            {
                throw "$(get-date) [ERROR] Could not retrieve VMs running on host $($myvar_vmhost.Name) from vCenter server $($myvar_vcenter_ip) : $($_.Exception.Message)"
            }
            ForEach ($myvar_cvm_name in $myvar_cvm_names) {$myvar_running_vms = $myvar_running_vms | Where-Object {$_.Name -ne $myvar_cvm_name}} #exclude CVMs
            if ($myvar_running_vms)
            {
                if (!$shutdownUvms)
                {
                    Throw "$(get-date) [ERROR] There are still virtual machines (other than CVMs) running on ESXi host $($myvar_vmhost.Name): $($myvar_running_vms.Name)"
                }
                else 
                {
                    Write-Host "$(get-date) [WARNING] Shutting down running UVMs on host $($myvar_vmhost.Name) : $($myvar_running_vms.Name)" -ForegroundColor Yellow
                    try {$myvar_uvms_shutdown_command = $myvar_running_vms | Stop-VMGuest -ErrorAction Stop -Confirm:$False}
                    catch {throw "$(get-date) [ERROR] Could not shut down UVMs running on host $($myvar_vmhost.Name) : $($_.Exception.Message)"}
                    Write-Host "$(get-date) [SUCCESS] Successfully sent shut down on running UVMs on host $($myvar_vmhost.Name) : $($myvar_running_vms.Name)" -ForegroundColor Cyan
                    Write-Host "$(get-date) [INFO] Waiting for $($timer) seconds..." -ForegroundColor Green
                    Start-Sleep $timer

                    try 
                    {#retrieve vms on this host which are still powered on
                        $myvar_running_vms = $myvar_vmhost | Get-VM -ErrorAction Stop | Where-Object {$_.PowerState -eq "PoweredOn"}
                        ForEach ($myvar_cvm_name in $myvar_cvm_names) {$myvar_running_vms = $myvar_running_vms | Where-Object {$_.Name -ne $myvar_cvm_name}}
                    }
                    catch
                    {#could not retrieve powered on vms from this host
                        Throw "$(get-date) [ERROR] Could not retrieve powered on VMs from ESXi host $($myvar_vmhost.Name): $($_.Exception.Message)"
                    }
                    if ($myvar_running_vms)
                    {#there are still powered on vms: forcefully powering them off
                        ForEach ($myvar_running_vm in $myvar_running_vms)
                        {#force power off on each running vm
                            Write-Host "$(get-date) [INFO] Forcefully powering off $($myvar_running_vm.Name)..." -ForegroundColor Green
                            try {$stopVM = Stop-VM -Confirm:$False -ErrorAction Stop -VM $myvar_running_vm -RunAsync}
                            catch {throw "$(get-date) [ERROR] Could not power off VM $($myvar_running_vm.Name) on ESXi host $($myvar_vmhost.Name): $($_.Exception.Message)"}
                        }
                        Write-Host "$(get-date) [INFO] Waiting for 60 seconds..." -ForegroundColor Green
                        Start-Sleep 60
                    }
                }
            }
            else {
                Write-Host "$(get-date) [DATA] There are no running UVMs on host $($myvar_vmhost.Name)" -ForegroundColor White
            }
        }
        
        #* nutanix cluster stop
        #region stopping the Nutanix cluster
            Write-Host ""
            Write-Host "$(get-date) [STEP] Stopping Nutanix cluster $($myvar_ntnx_cluster_name) and shutting down CVMs..." -ForegroundColor Magenta
            #sending the cluster stop command
            Write-Host "$(get-date) [INFO] Sending cluster stop command to $($myvar_cvm_ips[0])..." -ForegroundColor Green
            try {$myvar_cluster_stop_command = Invoke-SshCommand -ComputerName $myvar_cvm_ips[0] -Command "export ZOOKEEPER_HOST_PORT_LIST=zk3:9876,zk2:9876,zk1:9876 && echo 'I agree' | /usr/local/nutanix/cluster/bin/cluster stop" -ErrorAction Stop}
            catch {throw "$(get-date) [ERROR] Could not send cluster stop command to $($myvar_cvm_ips[0]) : $($_.Exception.Message)"}
            Write-Host "$(get-date) [SUCCESS] Sent cluster stop command to $($myvar_cvm_ips[0])." -ForegroundColor Cyan
        #endregion

        #* cvm shutdown
        #todo: enhance this to do while cvm is poweredon
        #region shutting down CVMs
            Write-Host "$(get-date) [INFO] Shutting down CVMs in Nutanix cluster $($myvar_ntnx_cluster_name)..." -ForegroundColor Green
            foreach ($myvar_cvm_name in $myvar_cvm_names) {
                try {$myvar_cvm_vm = Get-VM -ErrorAction Stop -Name $myvar_cvm_name}
                catch {throw "$(get-date) [ERROR] Could not retrieve VM object for CVM $($myvar_cvm_name) from vCenter server $($myvar_vcenter_ip) : $($_.Exception.Message)"}
                try {$myvar_cvm_shutdown_command = Stop-VMGuest -ErrorAction Stop -VM $myvar_cvm_vm -Confirm:$False}
                catch {throw "$(get-date) [ERROR] Could not stop CVM $($myvar_cvm_name) on vCenter server $($myvar_vcenter_ip) : $($_.Exception.Message)"}
            }
            Write-Host "$(get-date) [SUCCESS] Sent the shutdown command to all CVMs." -ForegroundColor Cyan
            Write-Host "$(get-date) [INFO] Waiting 3 minutes..." -ForegroundColor Green
            Start-Sleep 180
        #endregion

        #* put hosts in maintenance
        #region putting hosts in maintenance mode
            Write-Host ""
            Write-Host "$(get-date) [STEP] Putting ESXi hosts in Nutanix cluster $($myvar_ntnx_cluster_name) in maintenance mode..." -ForegroundColor Magenta
            foreach ($myvar_vmhost in $myvar_ntnx_vmhosts) {
                Write-Host "$(get-date) [INFO] Putting ESXi host $($myvar_vmhost.Name) in maintenance mode..." -ForegroundColor Green
                try {$myvar_vmhost_maintenance_command = $myvar_vmhost | set-vmhost -State Maintenance -ErrorAction Stop}
                catch {throw "$(get-date) [ERROR] Could not put ESXi host $($myvar_vmhost.Name) in maintenance mode : $($_.Exception.Message)"}
                Write-Host "$(get-date) [SUCCESS] Successfully put ESXi host $($myvar_vmhost.Name) in maintenance mode!" -ForegroundColor Cyan
            }
        #endregion
    }#end function Set-NtnxVmhostsToMaintenanceMode

    #this function is used to prompt the user for a yes/no/skip response in order to control the workflow of a script
    function Write-CustomPrompt 
    {
    <#
    .SYNOPSIS
    Creates a user prompt with a yes/no/skip response. Returns the response.

    .DESCRIPTION
    Creates a user prompt with a yes/no/skip response. Returns the response in lowercase. Valid responses are "y" for yes, "n" for no, "s" for skip.

    .NOTES
    Author: Stephane Bourdeaud (sbourdeaud@nutanix.com)

    .EXAMPLE
    .\Write-CustomPrompt
    Creates the prompt.

    .LINK
    https://github.com/sbourdeaud
    #>
    [CmdletBinding(DefaultParameterSetName = 'None')] #make this function advanced

    param 
    (
        [Switch]$skip
    )

    begin 
    {
        [String]$userChoice = "" #initialize our returned variable
    }
    process 
    {
        if ($skip)
        {
            do {$userChoice = Read-Host -Prompt "Do you want to continue? (Y[es]/N[o]/S[kip])"} #display the user prompt
            while ($userChoice -notmatch '[ynsYNS]') #loop until the user input is valid
        }
        else 
        {
            do {$userChoice = Read-Host -Prompt "Do you want to continue? (Y[es]/N[o])"} #display the user prompt
            while ($userChoice -notmatch '[ynYN]') #loop until the user input is valid
        }
        $userChoice = $userChoice.ToLower() #change to lowercase
    }
    end 
    {
        return $userChoice
    }

    } #end Write-CustomPrompt function
#endregion

#! if the cluster stop command does not work for you, it may be because you are running an older version of AOS, in which case you'll need to replace "I agree" with "y". This code is in the Set-NtnxVmhostsToMaintenanceMode function.
#todo: handle going out of maintenance mode where the script would:
<# 
Take ESXi hosts off maintenance mode
Power on CVMs
SSH into a CVM to start the cluster
Migrate VMs back
Re-enable replication
#>

#todo find a way to deal with ssh on non-windows systems
#todo test if vm or host drs group does not exist (and enhance with drs groups presence check)
#region prepwork
    $ErrorActionPreference = "Continue"

    Write-Host ""
    Write-Host "$(get-date) [STEP] Checking PowerShell configuration ..." -ForegroundColor Magenta
    $HistoryText = @'
 Maintenance Log
 Date       By   Updates (newest updates at the top)
 ---------- ---- ---------------------------------------------------------------
 11/03/2020 sb   Initial release.
 11/06/2020 sb   Added -reEnableOnly switch.
 02/06/2021 sb   Replaced username with get-credential
 02/16/2021 sb   Misc updates after first runs in production: moved DRS check to
                 PowerCLI commands as status in Prism cluster json object is
                 sometimes incorrect. Added code to force migrate powered off
                 virtual machines in a metro enabled container. Added code to
                 keep track of remote site cluster hypervisor hosts.  Added code
                 to display number of remaining virtual machines in a metro
                 enabled container.
 05/09/2021 sb   Added check for VM with DRS override that it is in the same
                 cluster and changed message accordingly.
 06/02/2021 sb   Adding check on failure handling method and adding step to
                 disable the protection domain if a Witness is not being used.
                 Added CUSTOMIZE markers to facilitate changing DRS naming
                 convention.
################################################################################
'@
    $myvarScriptName = ".\invoke-MAFailover.ps1"

    if ($help) 
    {
        get-help $myvarScriptName
        exit
    }
    if ($History) {
    $HistoryText
    exit
    }

    if ($PSVersionTable.PSVersion.Major -lt 5) 
    {#check PoSH version
        throw "$(get-date) [ERROR] Please upgrade to Powershell v5 or above (https://www.microsoft.com/en-us/download/details.aspx?id=50395)"
    }

    #check if we have all the required PoSH modules
    Write-Host "$(get-date) [INFO] Checking for required Powershell modules..." -ForegroundColor Green
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
    if ($action) {
        if (!(Get-Module SSHSessions)) {
            if (!(Import-Module SSHSessions)) {
                Write-Host "$(get-date) [WARNING] We need to install the SSHSessions module!" -ForegroundColor Yellow
                try {Install-Module SSHSessions -ErrorAction Stop -Scope CurrentUser}
                catch {throw "$(get-date) [ERROR] Could not install the SSHSessions module : $($_.Exception.Message)"}
                try {Import-Module SSHSessions}
                catch {throw "$(get-date) [ERROR] Could not load the SSHSessions module : $($_.Exception.Message)"}
            }
        }
    }

    # ignore SSL warnings
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
    }
    [ServerCertificateValidationCallback]::Ignore()
    # add Tls12 support
    Write-Host "$(Get-Date) [INFO] Adding Tls12 support" -ForegroundColor Green
    [Net.ServicePointManager]::SecurityProtocol = `
    ([Net.ServicePointManager]::SecurityProtocol -bor `
    [Net.SecurityProtocolType]::Tls12)

    #set some runtime variables
    $myvar_elapsed_time = [System.Diagnostics.Stopwatch]::StartNew() #used to store script begin timestamp
    [System.Collections.ArrayList]$pd_list = New-Object System.Collections.ArrayList($null)
    [System.Collections.ArrayList]$ctr_list = New-Object System.Collections.ArrayList($null)

#endregion

#region parameters validation
    Write-Host ""       
    Write-Host "$(get-date) [STEP] Validating parameters ..." -ForegroundColor Magenta
    if ($action -and ($IsMacOS -or $IsLinux)) 
    {#we need to connect to CVM using SSH but we're not running this script from a Windows machine (only platform where ssh module used works)
        Throw "$(get-date) [ERROR] You can only use -action on a Windows based system for now! Exiting."
    }

    if (!$cluster) 
    {#prompt for the Nutanix cluster name
        $cluster = read-host "Enter the hostname or IP address of the Nutanix cluster"
    }

    if (!$pd -and $action)
    {#we have specidied an action but no protection domains, so all protection domains will be processed.
        Write-Host "$(get-date) [WARNING] You have specified an action $($action) but no protection domain. We will process ALL active metro availability protection domains!" -ForegroundColor Yellow
        $pd = "all"
    } elseif (!$pd) 
    {#prompt for the Nutanix protection domain name
        $pd = read-host "Enter the name of the protection domain to failover. You can also specify 'all' or a list of names separated by a comma"
    }

    if ($pd -ne "all") 
    {#pd was specified but is not equal to all. Let's make sure we process it correctly if it is a list.
        $pd_names_list = $pd.Split(",")
    }

    if ($action -and ($pd -ne "all"))
    {#check that we are not trying to failover only some protection domains while putting esxi hosts in maintenance or shutting them down
        Throw "$(get-date) [ERROR] If you specify an action, you MUST use 'all' for protection domain as this otherwise would leave VMs on the cluster."
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
    {#vcenterCreds was specified
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
	else 
	{#no vcenter creds were given
		$vcenterCredentials = Get-Credential -Message "Please enter vCenter credentials"
	}

    if ($action -and !$cvmCreds) 
    {#we have specified an action, but we did not specify cvm credentials
        $myvar_cvm_username = Read-Host "Enter the username to ssh into CVMs"
        $myvar_cvm_secure_password = Read-Host "Enter the CVM user $($myvar_cvm_username) password" -AsSecureString
        $myvar_cvm_credentials = New-Object PSCredential $myvar_cvm_username, $myvar_cvm_secure_password
    }

    if ($cvmCreds) 
    {#we have specified cvm creds, so le's retrieve them
        try 
        {#trying to retrieve from existing encrypted file
            $myvar_cvm_credentials = Get-CustomCredentials -credname $cvmCreds -ErrorAction Stop
            $myvar_cvm_username = $myvar_cvm_credentials.UserName
            $myvar_cvm_secure_password = $myvar_cvm_credentials.Password
        }
        catch 
        {#we could not retrieve the creds from file, so prompting
            Set-CustomCredentials -credname $cvmCreds
            $myvar_cvm_credentials = Get-CustomCredentials -credname $cvmCreds -ErrorAction Stop
            $myvar_cvm_username = $myvar_cvm_credentials.UserName
            $myvar_cvm_secure_password = $myvar_cvm_credentials.Password
        }
        $myvar_cvm_credentials = New-Object PSCredential $myvar_cvm_username, $myvar_cvm_secure_password
    }

    if (!$timer) {$timer = 300}
#endregion

#region execute
    Write-Host ""
    Write-Host "$(get-date) [STEP] Retrieving information from the Nutanix cluster and checking pre-requisites conditions are met ..." -ForegroundColor Magenta
    #region get info and check pre-requisites
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
        
        #* getting cluster name and vcenter ip, checking DRS is enabled
        #region assign cluster name and vcenter ip
            $myvar_ntnx_cluster_name = $myvar_ntnx_cluster_info.name
            Write-Host "$(get-date) [DATA] Nutanix cluster name is $($myvar_ntnx_cluster_name)" -ForegroundColor White
            $myvar_management_server = $myvar_ntnx_cluster_info.management_servers | Where-Object {$_.management_server_type -eq "vcenter"}
            if ($myvar_management_server -is [array]) 
            {#houston, we have a problem, there is more than one registered vcenter
                Throw "$(get-date) [ERROR] There is more than 1 registered management server for cluster $($cluster). Exiting."
            } 
            else 
            {
                $myvar_vcenter_ip = ($myvar_ntnx_cluster_info.management_servers | Where-Object {$_.management_server_type -eq "vcenter"}).ip_address
                Write-Host "$(get-date) [DATA] vCenter IP address for Nutanix cluster $($myvar_ntnx_cluster_name) is $($myvar_vcenter_ip)" -ForegroundColor White
                <# this check does not work in some environments where vcenter may have clusters where DRS is not enabled
                if (!$reEnableOnly) 
                {#we don't really care if DRS is not enabled if all we're doing is re-enabling replication
                    if (!($myvar_ntnx_cluster_info.management_servers | Where-Object {$_.management_server_type -eq "vcenter"}).drs_enabled) 
                    {#houston we have a problem, drs is not enabled on this cluster
                        Throw "$(get-date) [ERROR] DRS is not enabled on vCenter $($myvar_vcenter_ip). Exiting."
                    } 
                    else 
                    {
                        Write-Host "$(get-date) [DATA] DRS is enabled on vCenter $($myvar_vcenter_ip)" -ForegroundColor White
                    }
                }
                #>
            }
        #endregion

        #* making sure cluster will be ready to be shutdown (if -action)
        #region cluster stop ready status
            if ($action) 
            {
                #let's make sure our current redundancy is at least 2
                if ($myvar_ntnx_cluster_info.cluster_redundancy_state.current_redundancy_factor -lt 2) 
                {
                    throw "$(get-date) [ERROR] Current redundancy is less than 2. Exiting."
                }
                #check if there is an upgrade in progress
                if ($myvar_ntnx_cluster_info.is_upgrade_in_progress) 
                {
                    throw "$(get-date) [ERROR] Cluster upgrade is in progress. Exiting."
                }
            }
        #endregion

        #* getting hosts ips
        #region GET hosts
            Write-Host "$(get-date) [INFO] Retrieving hosts information from Nutanix cluster $($cluster) ..." -ForegroundColor Green
            $url = "https://{0}:9440/PrismGateway/services/rest/v2.0/hosts/" -f $cluster
            $method = "GET"
            try 
            {
                $myvar_ntnx_hosts = Invoke-PrismRESTCall -method $method -url $url -credential $prismCredentials
            }
            catch
            {
                throw "$(get-date) [ERROR] Could not retrieve hosts information from Nutanix cluster $($cluster) : $($_.Exception.Message)"
            }
            Write-Host "$(get-date) [SUCCESS] Successfully retrieved hosts information from Nutanix cluster $($cluster)" -ForegroundColor Cyan
            $myvar_ntnx_hosts_ips = ($myvar_ntnx_hosts.entities).hypervisor_address
            if ($action) 
            {#collecting cvm ips and ipmi ips
                $myvar_cvm_ips = $myvar_ntnx_hosts.entities | %{$_.service_vmexternal_ip}
                $myvar_ipmi_ips = $myvar_ntnx_hosts.entities | %{$_.ipmi_address}
            }
        #endregion

        #* getting protection domains and checking they are active and enabled on this cluster, and build $pd_list and $ctr_list
        #region GET protection_domains
            Write-Host "$(get-date) [INFO] Retrieving protection domains from Nutanix cluster $($cluster) ..." -ForegroundColor Green
            $url = "https://{0}:9440/PrismGateway/services/rest/v2.0/protection_domains/" -f $cluster
            $method = "GET"
            try 
            {
                $myvar_ma_active_pds = Invoke-PrismRESTCall -method $method -url $url -credential $prismCredentials
            }
            catch
            {
                throw "$(get-date) [ERROR] Could not retrieve protection domains from Nutanix cluster $($cluster) : $($_.Exception.Message)"
            }
            Write-Host "$(get-date) [SUCCESS] Successfully retrieved protection domains from Nutanix cluster $($cluster)" -ForegroundColor Cyan
            $myvar_ntnx_ma_active_ctrs = ($myvar_ma_active_pds.entities | Where-Object {($_.active -eq $true) -and ($_.metro_avail.role -eq "Active")}).metro_avail.storage_container
            $myvar_ntnx_ma_active_pds = $myvar_ma_active_pds.entities | Where-Object {($_.active -eq $true) -and ($_.metro_avail.role -eq "Active")}
            if ($skipfailover) 
            {#if failover has been done already and all we're doing is maintenance or shutdown, the list of protection domains to process are those which are enabled
                $myvar_ntnx_ma_active_pds = $myvar_ma_active_pds.entities | Where-Object {$_.metro_avail.status -eq "Enabled"}
            }
            #building pd_list
            if ($pd -eq "all") 
            {
                $myvar_pd_list_details = $myvar_ntnx_ma_active_pds
                foreach ($myvar_pd_detail in $myvar_pd_list_details) 
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
                foreach ($myvar_ctr in $myvar_ntnx_ma_active_ctrs) 
                {
                    $myvar_ctr_info = [ordered]@{"name" = $myvar_ctr}
                    $ctr_list.Add((New-Object PSObject -Property $myvar_ctr_info)) | Out-Null
                }
            } 
            else 
            {#make sure all specified protection domain is indeed active on this cluster
                foreach ($pd_name in $pd_names_list) 
                {
                    if (!$skipfailover -and ($pd_name -notin $myvar_ntnx_ma_active_pds.name)) 
                    {
                        Throw "$(get-date) [ERROR] Protection domain $($pd_name) was not found active on cluster $($cluster). Exiting."
                    } 
                    else 
                    {
                        Write-Host "$(get-date) [DATA] Protection domain $($pd_name) was found active on Nutanix cluster $($cluster)" -ForegroundColor White
                        $myvar_pd_details = $myvar_ntnx_ma_active_pds | Where-Object {$_.name -eq $pd_name}
                        $myvar_pd_info = [ordered]@{
                            "name" = $myvar_pd_details.name;
                            "role" = $myvar_pd_details.metro_avail.role;
                            "remote_site" = $myvar_pd_details.metro_avail.remote_site;
                            "storage_container" = $myvar_pd_details.metro_avail.storage_container;
                            "status" = $myvar_pd_details.metro_avail.status;
                            "failure_handling" = $myvar_pd_details.metro_avail.failure_handling
                        }
                        $myvar_ctr_info = [ordered]@{"name" = $myvar_pd_details.metro_avail.storage_container}
                        $pd_list.Add((New-Object PSObject -Property $myvar_pd_info)) | Out-Null
                        $ctr_list.Add((New-Object PSObject -Property $myvar_ctr_info)) | Out-Null
                    }
                }
            }
            #checking pds are in status enabled
            if (!$skipfailover -and !$reEnableOnly)
            { 
                Write-Host "$(get-date) [INFO] Checking all active metro protection domain are in status enabled..." -ForegroundColor Green
                foreach ($pd_item in $pd_list) 
                {
                    if ($pd_item.status -ne "enabled") 
                    {
                        Throw "$(get-date) [ERROR] Protection domain $($pd_item.name) is active but not in the status enabled. Current status is $($pd_item.status). Exiting."
                    }
                }
                Write-Host "$(get-date) [DATA] All active metro protection domain are in status enabled on cluster $($myvar_ntnx_cluster_name)." -ForegroundColor White
            }
        #endregion

        #* getting remote site name, ip address, registered vcenter server and trying to connect to remote site
        #region GET remote_sites
            #* get remote site name ($remote_site_name) and make sure it is unique across all protection domains
            $remote_site_name = $pd_list.remote_site | select-object -unique
            if ($remote_site_name -is [array]) 
            {#houston we have a problem: active metro pds are pointing to more than one remote site!
                Throw "$(get-date) [ERROR] Cluster $($cluster) has metro availability protection domains which are pointing to different remote sites. Exiting."
            } 
            else 
            {
                Write-Host "$(get-date) [DATA] Remote site name is $($remote_site_name)" -ForegroundColor White
            }
            #* query prism for remote sites
            Write-Host "$(get-date) [INFO] Retrieving remote sites from Nutanix cluster $($cluster) ..." -ForegroundColor Green
            $url = "https://{0}:9440/PrismGateway/services/rest/v2.0/remote_sites/" -f $cluster
            $method = "GET"
            try 
            {
                $myvar_remote_sites = Invoke-PrismRESTCall -method $method -url $url -credential $prismCredentials
            }
            catch
            {
                throw "$(get-date) [ERROR] Could not retrieve remote sites from Nutanix cluster $($cluster) : $($_.Exception.Message)"
            }
            Write-Host "$(get-date) [SUCCESS] Successfully retrieved remote sites from Nutanix cluster $($cluster)" -ForegroundColor Cyan
            #* grab ip for our remote site
            $myvar_remote_site_ip = (($myvar_remote_sites.entities | Where-Object {$_.name -eq $remote_site_name}).remote_ip_ports).psobject.properties.name
            Write-Host "$(get-date) [DATA] Remote site $($remote_site_name) ip address is $($myvar_remote_site_ip)" -ForegroundColor White

            #* connecting to remote site cluster
            Write-Host "$(get-date) [INFO] Retrieving cluster information from Nutanix cluster $($myvar_remote_site_ip) on remote site $($remote_site_name) ..." -ForegroundColor Green
            $url = "https://{0}:9440/PrismGateway/services/rest/v2.0/cluster/" -f $myvar_remote_site_ip
            $method = "GET"
            try 
            {
                $myvar_ntnx_remote_cluster_info = Invoke-PrismRESTCall -method $method -url $url -credential $prismCredentials
            }
            catch
            {
                throw "$(get-date) [ERROR] Could not retrieve cluster information from Nutanix cluster $($myvar_remote_site_ip) : $($_.Exception.Message)"
            }
            Write-Host "$(get-date) [SUCCESS] Successfully retrieved cluster information from Nutanix cluster $($myvar_remote_site_ip)" -ForegroundColor Cyan

            #* figuring out remote cluster name and vcenter ip
            $myvar_ntnx_remote_cluster_name = $myvar_ntnx_remote_cluster_info.name
            Write-Host "$(get-date) [DATA] Nutanix cluster name for remote site $($remote_site_name) is $($myvar_ntnx_remote_cluster_name)" -ForegroundColor White
            $myvar_remote_management_server = $myvar_ntnx_remote_cluster_info.management_servers | Where-Object {$_.management_server_type -eq "vcenter"}
            if ($myvar_remote_management_server -is [array])
            {#houston, we have a problem, there is more than one registered vcenter
                Throw "$(get-date) [ERROR] There is more than 1 registered management server for remote cluster $($myvar_ntnx_remote_cluster_name). Exiting."
            } 
            else 
            {
                $myvar_remote_site_vcenter_ip = ($myvar_ntnx_remote_cluster_info.management_servers | Where-Object {$_.management_server_type -eq "vcenter"}).ip_address
                Write-Host "$(get-date) [DATA] vCenter IP address for remote Nutanix cluster $($myvar_ntnx_remote_cluster_name) is $($myvar_remote_site_vcenter_ip)" -ForegroundColor White
                if ($myvar_remote_site_vcenter_ip -ne $myvar_vcenter_ip) {#houston we have a problem, both sites have different registered vcenters
                    Throw "$(get-date) [ERROR] Nutanix clusters $($myvar_ntnx_cluster_name) and $($myvar_ntnx_remote_cluster_name) have different registered vCenter servers: $($myvar_vcenter_ip) and $($myvar_remote_site_vcenter_ip). Exiting."
                } else {
                    Write-Host "$(get-date) [DATA] Nutanix clusters $($myvar_ntnx_cluster_name) and $($myvar_ntnx_remote_cluster_name) have the same registered vCenter server." -ForegroundColor White
                }
            }

            #* getting remote site hosts information
            #region GET hosts
            Write-Host "$(get-date) [INFO] Retrieving hosts information from Nutanix cluster $($myvar_remote_site_ip) ..." -ForegroundColor Green
            $url = "https://{0}:9440/PrismGateway/services/rest/v2.0/hosts/" -f $myvar_remote_site_ip
            $method = "GET"
            try 
            {
                $myvar_remote_ntnx_hosts = Invoke-PrismRESTCall -method $method -url $url -credential $prismCredentials
            }
            catch
            {
                throw "$(get-date) [ERROR] Could not retrieve hosts information from Nutanix cluster $($myvar_remote_site_ip) : $($_.Exception.Message)"
            }
            Write-Host "$(get-date) [SUCCESS] Successfully retrieved hosts information from Nutanix cluster $($myvar_remote_site_ip)" -ForegroundColor Cyan
            $myvar_remote_ntnx_hosts_ips = ($myvar_remote_ntnx_hosts.entities).hypervisor_address   
        #endregion
        #endregion

        #* trying to connect to vcenter
        #region connect-viserver
            if (!$reEnableOnly)
            {
                Write-Host "$(get-date) [INFO] Connecting to vCenter server $($myvar_vcenter_ip) ..." -ForegroundColor Green
                try 
                {#try connecting to vcenter
                    $myvar_vcenter_connection = Connect-VIServer -Server $myvar_vcenter_ip -Credential $vcenterCredentials -ErrorAction Stop
                }
                catch 
                {#could not connect to vcenter
                    throw "$(get-date) [ERROR] Could not connect to vCenter server $($myvar_vcenter_ip) : $($_.Exception.Message)"
                }
                Write-Host "$(get-date) [SUCCESS] Successfully connected to vCenter server $($myvar_vcenter_ip)" -ForegroundColor Cyan
                
                if ($action) 
                {#figure out the vCenter and CVM VM names
                    try 
                    {
                        Write-Host "$(get-date) [INFO] Figuring out vCenter VM name..." -ForegroundColor Green
                        $myvar_vcenter_vm_name = (Get-VM -ErrorAction Stop| Select-Object Name, @{N="IP Address";E={@($_.guest.IPAddress[0])}} | Where-Object {$_."IP address" -eq $myvar_vcenter_ip}).Name
                        Write-Host "$(get-date) [SUCCESS] Successfully queried VMs from $($myvar_vcenter_ip)" -ForegroundColor Cyan
                        Write-Host "$(get-date) [DATA] vCenter VM name is $($myvar_vcenter_vm_name)" -ForegroundColor White

                        #figure out the CVM VM names
                        [System.Collections.ArrayList]$myvar_cvm_names = New-Object System.Collections.ArrayList($null)
                        Write-Host "$(get-date) [INFO] Figuring out CVM VM names..." -ForegroundColor Green
                        ForEach ($myvar_cvm_ip in $myvar_cvm_ips) 
                        {
                            try 
                            {
                                $myvar_cvm_name = (Get-VM -ErrorAction Stop | Select-Object Name, @{N="IP Address";E={@($_.guest.IPAddress[0])}} | Where-Object {$_."IP address" -eq $myvar_cvm_ip}).Name
                            }
                            catch 
                            {
                                throw "Could not retrieve list of VMs from $($myvar_vcenter_ip) : $($_.Exception.Message)"
                            }
                            $myvar_cvm_names += $myvar_cvm_name
                            Write-Host "$(get-date) [DATA] CVM with ip $($myvar_cvm_ip) VM name is $($myvar_cvm_name)" -ForegroundColor White
                        }

                        #figure out if the vCenter VM runs on one of the Nutanix compute cluster
                        #todo assess if this necessary
                        $myvar_vcenter_vm_cluster = Get-VM -Name $myvar_vcenter_vm_name | Get-Cluster
                        if ($myvar_vsphere_cluster_name  -eq $myvar_vcenter_vm_cluster.Name) 
                        {
                            $myvar_vcenter_ntnx_hosted = $true
                            Write-Host "$(get-date) [DATA] vCenter VM is hosted in the Nutanix cluster" -ForegroundColor White
                        } 
                        else 
                        {
                            $myvar_vcenter_ntnx_hosted = $false
                            Write-Host "$(get-date) [DATA] vCenter VM is not hosted in the Nutanix cluster" -ForegroundColor White
                        }
                    }
                    catch 
                    {
                        Throw "$(get-date) [ERROR] Could not retrieve vCenter VM from $($myvar_vcenter_ip) : $($_.Exception.Message)"
                    }
                }
            }
        #endregion

        #! this only works on windows with sshsessions module
        if ($action) 
        {
            #trying to ssh into cvm
            Write-Host "$(get-date) [INFO] Opening ssh session to $($myvar_cvm_ips[0])..." -ForegroundColor Green
            try 
            {
                $myvar_cvm_ssh_session = New-SshSession -ComputerName $myvar_cvm_ips[0] -Credential $myvar_cvm_credentials -ErrorAction Stop
                $myvar_ssh_sessions = Get-SshSession
                if (!$myvar_ssh_sessions) 
                {
                    throw "$(get-date) [ERROR] Could not open ssh session to $($myvar_cvm_ips[0])"
                }
            }
            catch 
            {
                throw "$(get-date) [ERROR] Could not open ssh session to $($myvar_cvm_ips[0]) : $($_.Exception.Message)"
            }
            Write-Host "$(get-date) [SUCCESS] Opened ssh session to $($myvar_cvm_ips[0])." -ForegroundColor Cyan
        }
        
    #endregion
    
    #region move vms using drs
        #* identify HA/DRS cluster and making sure HA and DRS are enabled
        #region figure out vsphere cluster name ($myvar_vsphere_cluster_name)
            if (!$reEnableOnly)
            {#we are not just renabling pds, so figure out the vcenter information
                Write-Host ""
                Write-Host "$(get-date) [STEP] Figuring out information required to move metro protected virtual machines from vmhosts in $($myvar_ntnx_cluster_name) to vmhosts in $($myvar_ntnx_remote_cluster_name) for specified metro availability protection domains..." -ForegroundColor Magenta
    
                #let's match host IP addresses we got from the Nutanix clusters to VMHost objects in vCenter
                $myvar_ntnx_vmhosts = @() #this is where we will save the hostnames of the hosts which make up the Nutanix cluster
                $myvar_remote_ntnx_vmhosts = @() #this is where we will save the hostnames of the hosts which make up the remote Nutanix cluster
                Write-Host "$(get-date) [INFO] Getting hosts registered in vCenter server $($myvar_vcenter_ip)..." -ForegroundColor Green
                try 
                {#get all the vmhosts registered in vCenter
                    $myvar_vmhosts = Get-VMHost -ErrorAction Stop 
                    Write-Host "$(get-date) [SUCCESS] Successfully retrieved vmhosts from vCenter server $($myvar_vcenter_ip)" -ForegroundColor Cyan
                }
                catch
                {#couldn't get all the vmhosts registered in vCenter
                    throw "$(get-date) [ERROR] Could not retrieve vmhosts from vCenter server $($myvar_vcenter_ip) : $($_.Exception.Message)"
                }

                foreach ($myvar_vmhost in $myvar_vmhosts) 
                {#let's look at each host and determine which is which
                    Write-Host "$(get-date) [INFO] Retrieving vmk interfaces for host $($myvar_vmhost)..." -ForegroundColor Green
                    try 
                    {#retrieve all vmk NICs for that host
                        $myvar_host_vmks = $myvar_vmhost | Get-VMHostNetworkAdapter -ErrorAction Stop | Where-Object {$_.DeviceName -like "vmk*"} 
                        Write-Host "$(get-date) [SUCCESS] Successfully retrieved vmk interfaces for host $($myvar_vmhost)" -ForegroundColor Cyan
                    }
                    catch
                    {#couldn't retrieve all vmk NICs for that host
                        throw "$(get-date) [ERROR] Could not retrieve vmk interfaces for host $($myvar_vmhost) : $($_.Exception.Message)"
                    }
                    foreach ($myvar_host_vmk in $myvar_host_vmks) 
                    {#examine all VMKs
                        foreach ($myvar_host_ip in $myvar_ntnx_hosts_ips) 
                        {#compare to the host IP addresses we got from the Nutanix cluster
                            if ($myvar_host_vmk.IP -eq $myvar_host_ip)
                            {#if we get a match, that vcenter host is in cluster 1
                                Write-Host "$(get-date) [DATA] $($myvar_vmhost.Name) is a host in Nutanix cluster $($myvar_ntnx_cluster_name)..." -ForegroundColor White
                                $myvar_ntnx_vmhosts += $myvar_vmhost
                            }
                        }#end foreach IP loop
                        foreach ($myvar_remote_host_ip in $myvar_remote_ntnx_hosts_ips) 
                        {#compare to the host IP addresses we got from the Nutanix cluster
                            if ($myvar_host_vmk.IP -eq $myvar_remote_host_ip)
                            {#if we get a match, that vcenter host is in cluster 2
                                Write-Host "$(get-date) [DATA] $($myvar_vmhost.Name) is a host in Nutanix cluster $($myvar_ntnx_remote_cluster_name)..." -ForegroundColor White
                                $myvar_remote_ntnx_vmhosts += $myvar_vmhost
                            }
                        }#end foreach IP loop
                    }#end foreach VMK loop
                }#end foreach VMhost loop
                if (!$myvar_ntnx_vmhosts) 
                {#couldn't find hosts in cluster
                    throw "$(get-date) [ERROR] No vmhosts were found for Nutanix cluster $($myvar_ntnx_cluster_name) in vCenter server $($myvar_vcenter_ip)"
                }

                #figure out vsphere cluster name
                Write-Host "$(get-date) [INFO] Checking which compute cluster contains hosts from $($myvar_ntnx_cluster_name)..." -ForegroundColor Green
                try 
                {#we look at which cluster the first vmhost in cluster belongs to.
                    $myvar_vsphere_cluster = $myvar_ntnx_vmhosts[0] | Get-Cluster -ErrorAction Stop
                    $myvar_vsphere_cluster_name = $myvar_vsphere_cluster.Name

                    Write-Host "$(get-date) [DATA] vSphere compute cluster name is $($myvar_vsphere_cluster_name) for Nutanix cluster $($myvar_ntnx_cluster_name)." -ForegroundColor White

                    foreach ($myvar_vmhost in $myvar_ntnx_vmhosts) 
                    {#make sure all hosts are part of the same cluster
                        try 
                        {
                            $myvar_vmhost_vsphere_cluster = $myvar_vmhost | Get-Cluster -ErrorAction Stop
                            $myvar_vmhost_vsphere_cluster_name = $myvar_vmhost_vsphere_cluster.Name
                            if ($myvar_vmhost_vsphere_cluster_name -ne $myvar_vsphere_cluster_name) 
                            {#houston we have a problem: some nutanix hosts are not in the same compute cluster
                                throw "$(get-date) [ERROR] Nutanix host $($myvar_vmhost) is in vsphere cluster $($myvar_vmhost_vsphere_cluster_name) instead of vsphere cluster $($myvar_vsphere_cluster_name)! Exiting."
                            }
                        }
                        catch 
                        {
                            throw "$(get-date) [ERROR] Could not retrieve vSphere cluster for host $($myvar_ntnx_vmhosts[0].Name) : $($_.Exception.Message)"
                        }
                    }
                }
                catch 
                {#couldn't retrieve cluster
                    throw "$(get-date) [ERROR] Could not retrieve vSphere cluster for host $($myvar_ntnx_vmhosts[0].Name) : $($_.Exception.Message)"
                }

                #checking vsphere cluster configuration
                Write-Host "$(get-date) [INFO] Checking HA is enabled on vSphere cluster $($myvar_vsphere_cluster_name)..." -ForegroundColor Green
                if ($myvar_vsphere_cluster.HaEnabled -ne $true) 
                {#HA is not enabled on this cluster
                    throw "$(get-date) [ERROR] HA is not enabled on vSphere cluster $($myvar_vsphere_cluster_name)!"
                }
                Write-Host "$(get-date) [INFO] Checking DRS is enabled and fully automated on vSphere cluster $($myvar_vsphere_cluster_name)..." -ForegroundColor Green
                if ($myvar_vsphere_cluster.DrsEnabled -ne $true)  
                {#DRS is not enabled on this cluster
                    throw "$(get-date) [ERROR] DRS is not enabled on vSphere cluster $($myvar_vsphere_cluster_name)!"
                }
                if ($myvar_vsphere_cluster.DrsAutomationLevel -ne "FullyAutomated")
                {#DRS is not fully automated on this cluster
                    Throw "$(get-date) [ERROR] DRS is not fully automated on VMware cluster $($myvar_vsphere_cluster_name)"
                }
            }
        #endregion
        
        if (!$skipfailover -and !$reEnableOnly)
        {#we are not skipping failover nor reenabling pds only
            #* find matching drs groups and rule(s)
            #region matching drs groups and rules
                Write-Host "$(get-date) [INFO] Getting DRS rules from vCenter server $($myvar_vcenter_ip)..." -ForegroundColor Green
                try 
                {
                    $myvar_cluster_compute_resource_view = Get-View -ErrorAction Stop -ViewType ClusterComputeResource -Property Name, ConfigurationEx | where-object {$_.Name -eq $myvar_vsphere_cluster_name}
                    $myvar_cluster_drs_rules = $myvar_cluster_compute_resource_view.ConfigurationEx.Rule
                    Write-Host "$(get-date) [SUCCESS] Successfully retrieved DRS rules from vCenter server $($myvar_vcenter_ip)..." -ForegroundColor Cyan
                }
                catch 
                {
                    throw "$(get-date) [ERROR] Could not retrieve existing DRS rules for cluster $($myvar_vsphere_cluster_name) : $($_.Exception.Message)"
                }
            #endregion

            #* update matching drs rule(s)
            #region update drs rule(s)
                #Write-Host "$(get-date) [INFO] Updating DRS rules in vCenter server $($myvar_vcenter_ip)..." -ForegroundColor Green
                #! CUSTOMIZE: you can customize drs host group names here
                $myvar_ntnx_remote_drs_host_group_name = "DRS_HG_MA_" + $myvar_ntnx_remote_cluster_name
                foreach ($myvar_datastore in $ctr_list.name)
                {#process each datastore
                    #! CUSTOMIZE: you can customize drs rules and vm group names here
                    $myvar_drs_rule_name = "DRS_Rule_MA_" + $myvar_datastore
                    $myvar_drs_vm_group_name = "DRS_VM_MA_" + $myvar_datastore
                    Write-Host ""
                    Write-Host "$(get-date) [STEP] Processing DRS rule $($myvar_drs_rule_name) in vCenter server $($myvar_vcenter_ip)..." -ForegroundColor Magenta

                    if (!($myvar_cluster_drs_rules | Where-Object {$_.Name -eq $myvar_drs_rule_name})) 
                    {#houston we have a problem: DRS rule does not exist
                        throw "$(get-date) [ERROR] DRS rule $($myvar_drs_rule_name) does not exist! Exiting."
                    } else {
                        #update drs rule
                        Write-Host "$(get-date) [INFO] Updating DRS rule $($myvar_drs_rule_name) in vCenter server $($myvar_vcenter_ip) to match VM group $($myvar_drs_vm_group_name) to host group $($myvar_ntnx_remote_drs_host_group_name)..." -ForegroundColor Green
                        Update-DRSVMToHostRule -VMGroup $myvar_drs_vm_group_name -HostGroup $myvar_ntnx_remote_drs_host_group_name -Name $myvar_drs_rule_name -Cluster $myvar_vsphere_cluster -RuleKey $(($myvar_cluster_drs_rules | Where-Object {$_.Name -eq $myvar_drs_rule_name}).Key) -RuleUuid $(($myvar_cluster_drs_rules | Where-Object {$_.Name -eq $myvar_drs_rule_name}).RuleUuid)
                        Write-Host "$(get-date) [SUCCESS] Successfully updated DRS rule $($myvar_drs_rule_name) in vCenter server $($myvar_vcenter_ip) to match VM group $($myvar_drs_vm_group_name) to host group $($myvar_ntnx_remote_drs_host_group_name)..." -ForegroundColor Cyan
                    }
                }
            #endregion

            #* loop until all vms in each datastore have been moved
            #region wait for drs to do his job
                foreach ($myvar_datastore in $ctr_list.name)
                {#process each datastore
                    Write-Host ""
                    Write-Host "$(get-date) [STEP] Checking all VMs have moved to the remote site for datastore $($myvar_datastore)..." -ForegroundColor Magenta
                    $myvar_drs_done = $false
                    Do {#loop until all vms have been moved
                        #figure out which vmhosts have vms running in this datastore
                        try 
                        {#getting vms on this datastore
                            #$myvar_datastore_vmhosts = get-datastore -name $myvar_datastore -ErrorAction Stop | get-vm -ErrorAction Stop | get-vmhost -ErrorAction Stop | Select-Object -Unique -Property name
                            $myvar_datastore_vms = get-datastore -name $myvar_datastore -ErrorAction Stop | get-vm -ErrorAction Stop
                            $myvar_datastore_poweredoff_vms = $myvar_datastore_vms | Where-Object {$_.PowerState -eq "PoweredOff"}
                            $myvar_datastore_poweredon_vms = $myvar_datastore_vms | Where-Object {$_.PowerState -eq "PoweredOn"}
                        }
                        catch 
                        {#could not get vms on datastore
                            throw "$(get-date) [ERROR] Could not retrieve datastores from vCenter server $($myvar_vcenter_ip) : $($_.Exception.Message)"
                        }

                        #* process powered on vms; dealing with DRS overrides here
                        ForEach ($myvar_datastore_poweredon_vm in $myvar_datastore_poweredon_vms)
                        {#let's make sure none of the powered on vms have DRS override
                            $myvar_datastore_poweredon_vm_details = Get-VM -Name $myvar_datastore_poweredon_vm.Name #this is required as somehow, when we get VM objects from a get-datastore pipe, the DrsAutomationLevel property does not get populated
                            if ($myvar_datastore_poweredon_vm_details.VMHost -notin $myvar_ntnx_vmhosts)
                            {#this VM is not in the same HA/DRS cluster. It could be a backup proxy or some other vm with data in the datastore
                                Write-Host "$(Get-Date) [ERROR] Virtual Machine $($myvar_datastore_poweredon_vm.Name) is not part of this Nutanix cluster. This could be a backup proxy server or some other vm which has a disk or data in the metro datastore. You will need to correct this manually!" -ForegroundColor Red
                            }
                            elseif ($myvar_datastore_poweredon_vm_details.DrsAutomationLevel -ne "AsSpecifiedByCluster")
                            {#this vm has a DRS override
                                #check vmhost for that vm
                                Write-Host "$(Get-Date) [WARNING] Virtual Machine $($myvar_datastore_poweredon_vm.Name) has a DRS override configured to $($myvar_datastore_poweredon_vm_details.DrsAutomationLevel). Changing it back to default AsSpecifiedByCluster" -ForegroundColor Yellow
                                if (!$resetOverrides)
                                {#user hasn't specified he want to remove DRS override by default, so prompting
                                    $myvar_user_choice = Write-CustomPrompt
                                }
                                else 
                                {#user has already said he wanted to remove DRS overrides by default
                                    $myvar_user_choice = "y"
                                }
                                
                                if ($myvar_user_choice -match '[yY]')
                                {#user wants to remove drs override
                                    try 
                                    {#remove VM DRS override
                                        $result = Set-VM -VM $myvar_datastore_poweredon_vm -DrsAutomationLevel "AsSpecifiedByCluster" -Confirm:$false -ErrorAction Stop
                                    }
                                    catch 
                                    {#could not remove VM DRS override
                                        Write-Host "$(get-date) [ERROR] Could not remove DRS override on VM $($myvar_datastore_poweredon_vm.Name): $($_.Exception.Message)" -ForegroundColor Red
                                        Write-Host "$(get-date) [ERROR] You will have to move that VM manually to get out of this loop!" -ForegroundColor Red
                                    }
                                }
                                else 
                                {#user does not want to remove override
                                    Write-Host "$(Get-Date) [ERROR] Virtual Machine $($myvar_datastore_poweredon_vm.Name) has a DRS override configured to $($myvar_datastore_poweredon_vm_details.DrsAutomationLevel) and you have chosen not to remove the override.  You will have to migrate the VM manually in order to get out of this loop!" -ForegroundColor Red
                                }
                            }                                
                        }
                        
                        $myvar_vmhost_found = $false
                        $myvar_vms_to_move = (($myvar_datastore_vms.vmhost).Name | Where-Object {$_ -in $myvar_ntnx_vmhosts.Name}).count
                        foreach ($myvar_ntnx_vmhost in $myvar_ntnx_vmhosts) 
                        {#process each host on this site and make sure on this datastore, vms are not running on any of those hosts
                            if (($myvar_datastore_vms.vmhost).Name -contains $myvar_ntnx_vmhost.Name) 
                            {#a vm is running on a host on this site still
                                $myvar_vmhost_found = $true
                            }
                        }
                        if ($myvar_vmhost_found) 
                        {#at least one vm is running on a host on this site still
                            Write-Host "$(get-date) [WARNING] There are still $($myvar_vms_to_move) virtual machines running on vmhosts from Nutanix cluster $($myvar_ntnx_cluster_name) in datastore $($myvar_datastore). Waiting 15 seconds..." -ForegroundColor Yellow
                            Start-Sleep 15
                        } 
                        else 
                        {#all vms in this datastore are running on hosts in the remote site
                            $myvar_drs_done = $true
                        }

                        #* force migrate any powered off vms
                        ForEach ($myvar_poweredoff_vm in $myvar_datastore_poweredoff_vms)
                        {#process each powered off vm
                            if (($myvar_poweredoff_vm.vmhost).Name -in $myvar_ntnx_vmhosts.Name)
                            {#that powered off VM needs to be moved
                                try 
                                {#moving vm
                                    Write-Host "$(get-date) [WARNING] Moving powered off VM $($myvar_poweredoff_vm.Name) to remote site host $($myvar_remote_ntnx_vmhosts[0].Name)" -ForegroundColor Yellow
                                    $result = Move-VM -Location $myvar_remote_ntnx_vmhosts[0] -VM $myvar_poweredoff_vm -ErrorAction Stop
                                }
                                catch 
                                {#couldn't move vm
                                    Write-Host "$(get-date) [ERROR] Could not move powered off VM $($myvar_poweredoff_vm.Name) to remote site host $($myvar_remote_ntnx_vmhosts[0].Name) : $($_.Exception.Message)" -ForegroundColor Red
                                }
                            }
                            else 
                            {#that vm is not in the same cluster
                                Write-Host "$(Get-Date) [WARNING] Virtual Machine $($myvar_poweredoff_vm.Name) is powered off, on a metro datastore we need to move but is not part of this Nutanix cluster. This should not prevent failover completion but is unexpected." -ForegroundColor Yellow
                            }
                        }
                    } While (!$myvar_drs_done)
                    Write-Host "$(get-date) [DATA] All virtual machines on datastore $($myvar_datastore) have been moved to $($remote_site_name)..." -ForegroundColor White
                }
                if ($pd -eq "all") 
                {#we've been processing all pds
                    Write-Host "$(get-date) [DATA] All virtual machines on all active metro protected datastores have been moved to $($remote_site_name)..." -ForegroundColor White
                } 
                else 
                {#we only processed some pds
                    Write-Host "$(get-date) [DATA] All virtual machines on specified active metro protected datastore(s) have been moved to $($remote_site_name)..." -ForegroundColor White
                }
            #endregion
        }
    #endregion
        
    #region planned failover of the protection domain(s)
        if (!$skipfailover -and !$reEnableOnly)
        {
            foreach ($myvar_pd in $pd_list) 
            {
                Write-Host ""
                Write-Host "$(get-date) [STEP] Failing over protection domain $($myvar_pd.name) from $($myvar_ntnx_cluster_name) to $($remote_site_name) ..." -ForegroundColor Magenta
                
                #* step 1 of 3: trigger pd promotion on remote
                Write-Host "$(get-date) [INFO] Promoting protection domain $($myvar_pd.name) on $($myvar_ntnx_remote_cluster_name) ..." -ForegroundColor Green
                $url = "https://{0}:9440/PrismGateway/services/rest/v2.0/protection_domains/{1}/promote?force=true" -f $myvar_remote_site_ip,$myvar_pd.name
                $method = "POST"
                try 
                {
                    $myvar_pd_activate = Invoke-PrismRESTCall -method $method -url $url -credential $prismCredentials
                }
                catch
                {
                    throw "$(get-date) [ERROR] Could not promote protection domain $($myvar_pd.name) on $($myvar_ntnx_remote_cluster_name) : $($_.Exception.Message)"
                }
                Write-Host "$(get-date) [SUCCESS] Successfully promoted protection domain $($myvar_pd.name) on $($myvar_ntnx_remote_cluster_name)." -ForegroundColor Cyan
                
                #Start-Sleep 30
                #* check remote pd is active
                Do 
                {
                    Write-Host "$(get-date) [INFO] Retrieving protection domains from Nutanix cluster $($myvar_ntnx_remote_cluster_name) ..." -ForegroundColor Green
                    $url = "https://{0}:9440/PrismGateway/services/rest/v2.0/protection_domains/" -f $myvar_remote_site_ip
                    $method = "GET"
                    try 
                    {
                        $myvar_remote_pds = Invoke-PrismRESTCall -method $method -url $url -credential $prismCredentials
                    }
                    catch
                    {
                        throw "$(get-date) [ERROR] Could not retrieve protection domains from Nutanix cluster $($myvar_ntnx_remote_cluster_name) : $($_.Exception.Message)"
                    }
                    Write-Host "$(get-date) [SUCCESS] Successfully retrieved protection domains from Nutanix cluster $($myvar_ntnx_remote_cluster_name)" -ForegroundColor Cyan

                    $myvar_remote_pd_role = ($myvar_remote_pds.entities | Where-Object {$_.name -eq $myvar_pd.name}).metro_avail.role
                    if ($myvar_remote_pd_role -ne "Active") 
                    {
                        Write-Host "$(get-date) [WARNING] Protection domain $($myvar_pd.name) on cluster $($myvar_ntnx_remote_cluster_name) does not have active role yet but role $($myvar_remote_pd_role). Waiting 15 seconds..." -ForegroundColor Yellow
                        Start-Sleep 15
                    }
                } While ($myvar_remote_pd_role -ne "Active")
                Write-Host "$(get-date) [DATA] Protection domain $($myvar_pd.name) on cluster $($myvar_ntnx_remote_cluster_name) has active role now." -ForegroundColor White


                #* step 2 of 3: if necessary, disable pd
                if ($myvar_pd.failure_handling -ne "Witness")
                {
                    Write-Host "$(get-date) [INFO] Witness is not in use, so disabling protection domain $($myvar_pd.name) on $($myvar_ntnx_cluster_name) ..." -ForegroundColor Green
                    $url = "https://{0}:9440/PrismGateway/services/rest/v2.0/protection_domains/{1}/metro_avail_disable" -f $myvar_site_ip,$myvar_pd.name
                    $method = "POST"
                    try 
                    {
                        $myvar_pd_disable = Invoke-PrismRESTCall -method $method -url $url -credential $prismCredentials
                    }
                    catch
                    {
                        throw "$(get-date) [ERROR] Could not disable protection domain $($myvar_pd.name) on $($myvar_ntnx_cluster_name) : $($_.Exception.Message)"
                    }
                    Write-Host "$(get-date) [SUCCESS] Successfully disabled protection domain $($myvar_pd.name) on $($myvar_ntnx_cluster_name)." -ForegroundColor Cyan
                }

                #* check pd status is disabled
                Do 
                {
                    Write-Host "$(get-date) [INFO] Retrieving protection domains from Nutanix cluster $($myvar_ntnx_cluster_name) ..." -ForegroundColor Green
                    $url = "https://{0}:9440/PrismGateway/services/rest/v2.0/protection_domains/" -f $myvar_site_ip
                    $method = "GET"
                    try 
                    {
                        $myvar_pds = Invoke-PrismRESTCall -method $method -url $url -credential $prismCredentials
                    }
                    catch
                    {
                        throw "$(get-date) [ERROR] Could not retrieve protection domains from Nutanix cluster $($myvar_ntnx_cluster_name) : $($_.Exception.Message)"
                    }
                    Write-Host "$(get-date) [SUCCESS] Successfully retrieved protection domains from Nutanix cluster $($myvar_ntnx_cluster_name)" -ForegroundColor Cyan

                    $myvar_pd_status = ($myvar_pds.entities | Where-Object {$_.name -eq $myvar_pd.name}).metro_avail.status
                    if ($myvar_pd_status -ne "Disabled") 
                    {
                        Write-Host "$(get-date) [WARNING] Protection domain $($myvar_pd.name) on cluster $($myvar_ntnx_cluster_name) is not disabled yet but has status $($myvar_pd_status). Waiting 15 seconds..." -ForegroundColor Yellow
                        Start-Sleep 15
                    }
                } While ($myvar_pd_status -ne "Disabled")
                Write-Host "$(get-date) [DATA] Protection domain $($myvar_pd.name) on cluster $($myvar_ntnx_cluster_name) is disabled now." -ForegroundColor White


                #* step 3 of 3: re-enable pd on remote
                Write-Host "$(get-date) [INFO] Re-enabling protection domain $($myvar_pd.name) on $($myvar_ntnx_remote_cluster_name) ..." -ForegroundColor Green
                $url = "https://{0}:9440/api/nutanix/v2.0/protection_domains/{1}/metro_avail_enable?re_enable=true" -f $myvar_remote_site_ip,$myvar_pd.name
                $method = "POST"
                $content = @{}
                $body = (ConvertTo-Json $content)
                try 
                {
                    $myvar_pd_activate = Invoke-PrismRESTCall -method $method -url $url -credential $prismCredentials -payload $body
                }
                catch
                {
                    throw "$(get-date) [ERROR] Could not re-enable protection domain $($myvar_pd.name) on $($myvar_ntnx_remote_cluster_name) : $($_.Exception.Message)"
                }
                Write-Host "$(get-date) [SUCCESS] Successfully re-enabled protection domain $($myvar_pd.name) on $($myvar_ntnx_remote_cluster_name)" -ForegroundColor Cyan
                
                #Start-Sleep 30
                #* check remote pd is enabled
                Do 
                {
                    Write-Host "$(get-date) [INFO] Retrieving protection domains from Nutanix cluster $($myvar_ntnx_remote_cluster_name) ..." -ForegroundColor Green
                    $url = "https://{0}:9440/PrismGateway/services/rest/v2.0/protection_domains/" -f $myvar_remote_site_ip
                    $method = "GET"
                    try 
                    {
                        $myvar_remote_pds = Invoke-PrismRESTCall -method $method -url $url -credential $prismCredentials
                    }
                    catch
                    {
                        throw "$(get-date) [ERROR] Could not retrieve protection domains from Nutanix cluster $($myvar_ntnx_remote_cluster_name) : $($_.Exception.Message)"
                    }
                    Write-Host "$(get-date) [SUCCESS] Successfully retrieved protection domains from Nutanix cluster $($myvar_ntnx_remote_cluster_name)" -ForegroundColor Cyan

                    $myvar_remote_pd_status = ($myvar_remote_pds.entities | Where-Object {$_.name -eq $myvar_pd.name}).metro_avail.status
                    if ($myvar_remote_pd_status -ne "Enabled") 
                    {
                        Write-Host "$(get-date) [WARNING] Protection domain $($myvar_pd.name) on cluster $($myvar_ntnx_remote_cluster_name) is not enabled yet. Current status is $($myvar_remote_pd_status). Waiting 15 seconds..." -ForegroundColor Yellow
                        Start-Sleep 15
                    }
                } While ($myvar_remote_pd_status -ne "Enabled")
                Write-Host "$(get-date) [DATA] Protection domain $($myvar_pd.name) on cluster $($myvar_ntnx_remote_cluster_name) is enabled now." -ForegroundColor White
            }
        }
    #endregion

    #region reEnableOnly
        if ($reEnableOnly)
        {
            foreach ($myvar_pd in $pd_list) 
            {
                if (($myvar_pd.role -eq "Active") -and ($myvar_pd.status -eq "Disabled")) 
                {
                    Write-Host ""
                    Write-Host "$(get-date) [STEP] Enabling replication for protection domain $($myvar_pd.name) from $($myvar_ntnx_cluster_name) to $($remote_site_name) ..." -ForegroundColor Magenta
                    #* enable specified protection domains on cluster
                    Write-Host "$(get-date) [INFO] Re-enabling protection domain $($myvar_pd.name) on $($myvar_ntnx_remote_cluster_name) ..." -ForegroundColor Green
                    $url = "https://{0}:9440/api/nutanix/v2.0/protection_domains/{1}/metro_avail_enable?re_enable=true" -f $cluster,$myvar_pd.name
                    $method = "POST"
                    $content = @{}
                    $body = (ConvertTo-Json $content)
                    try 
                    {
                        $myvar_pd_activate = Invoke-PrismRESTCall -method $method -url $url -credential $prismCredentials -payload $body
                    }
                    catch
                    {
                        throw "$(get-date) [ERROR] Could not re-enable protection domain $($myvar_pd.name) on $($myvar_ntnx_cluster_name) : $($_.Exception.Message)"
                    }
                    Write-Host "$(get-date) [SUCCESS] Successfully re-enabled protection domain $($myvar_pd.name) on $($myvar_ntnx_cluster_name)" -ForegroundColor Cyan
                    
                    #Start-Sleep 30
                    Do 
                    {
                        Write-Host "$(get-date) [INFO] Retrieving protection domains from Nutanix cluster $($myvar_ntnx_cluster_name) ..." -ForegroundColor Green
                        $url = "https://{0}:9440/PrismGateway/services/rest/v2.0/protection_domains/" -f $cluster
                        $method = "GET"
                        try 
                        {
                            $myvar_cluster_pds = Invoke-PrismRESTCall -method $method -url $url -credential $prismCredentials
                        }
                        catch
                        {
                            throw "$(get-date) [ERROR] Could not retrieve protection domains from Nutanix cluster $($myvar_ntnx_cluster_name) : $($_.Exception.Message)"
                        }
                        Write-Host "$(get-date) [SUCCESS] Successfully retrieved protection domains from Nutanix cluster $($myvar_ntnx_cluster_name)" -ForegroundColor Cyan

                        $myvar_cluster_pd_status = ($myvar_cluster_pds.entities | Where-Object {$_.name -eq $myvar_pd.name}).metro_avail.status
                        if ($myvar_cluster_pd_status -ne "Enabled") 
                        {
                            Write-Host "$(get-date) [WARNING] Protection domain $($myvar_pd.name) on cluster $($myvar_ntnx_cluster_name) is not enabled yet. Current status is $($myvar_cluster_pd_status). Waiting 15 seconds..." -ForegroundColor Yellow
                            Start-Sleep 15
                        }
                    } While ($myvar_cluster_pd_status -ne "Enabled")
                    Write-Host "$(get-date) [DATA] Protection domain $($myvar_pd.name) on cluster $($myvar_ntnx_cluster_name) is enabled now." -ForegroundColor White
                }
                else 
                {#protection domains is not Disabled, so it may have been already re-enabled or it is decoupled
                    if ($myvar_pd.role -ne "Active")
                    {
                        Write-Host "$(get-date) [INFO] Protection domain $($myvar_pd.name) on cluster $($myvar_ntnx_cluster_name) is not active. Skipping." -ForegroundColor Yellow
                    }
                    else {
                        Write-Host "$(get-date) [WARNING] Protection domain $($myvar_pd.name) on cluster $($myvar_ntnx_cluster_name) is not in disabled status so we will NOT try to re-enable it. Current status is $($myvar_pd.status)." -ForegroundColor Yellow
                    }
                }
            }
        }
    #endregion

    #region maintenance
        if ($action -eq "maintenance") 
        {
            Set-NtnxVmhostsToMaintenanceMode
        }
    #endregion

    #region shutdown
        if ($action -eq "shutdown") 
        {
            #* call maintenance function
            Set-NtnxVmhostsToMaintenanceMode
            #* shutdown esxi hosts
            Write-Host ""
            Write-Host "$(get-date) [STEP] Shutting down ESXi hosts in Nutanix cluster $($myvar_ntnx_cluster_name)..." -ForegroundColor Magenta
            foreach ($myvar_vmhost in $myvar_ntnx_vmhosts) 
            {
                Write-Host "$(get-date) [INFO] Shutting down ESXi host $($myvar_vmhost.Name)..." -ForegroundColor Green
                try 
                {
                    $myvar_vmhost_shutdown_command = $myvar_vmhost | Stop-VMhost -Confirm:$false -ErrorAction Stop
                }
                catch 
                {
                    throw "$(get-date) [ERROR] Could not shut down ESXi host $($myvar_vmhost.Name) : $($_.Exception.Message)"
                }
                Write-Host "$(get-date) [SUCCESS] Successfully shut down ESXi host $($myvar_vmhost.Name)!" -ForegroundColor Cyan
            }
        }
    #endregion
#endregion

#region cleanup
    Write-Host ""
    Write-Host "$(get-date) [STEP] Cleaning up ..." -ForegroundColor Magenta

    #disconnect viserver
    if (!$reEnableOnly)
    {
        Write-Host "$(get-date) [INFO] Disconnecting from vCenter $($myvar_vcenter_ip)" -ForegroundColor Green
        $myvar_vcenter_disconnect_command = Disconnect-viserver * -Confirm:$False -ErrorAction SilentlyContinue
    }

    if ($action)
    {#cleaning up ssh sessions and displaying ip addresses for restart if this was a shutdown
        Write-Host "$(get-date) [INFO] Closing SSH sessions..." -ForegroundColor Green
        Remove-SshSession -RemoveAll -ErrorAction SilentlyContinue
        if ($action -eq "shutdown")
        {
            Write-Host "$(get-date) [INFO] All done! Note that nodes may take as long as 20 minutes to shutdown completely. To restart your cluster, use the following IP addresses:" -ForegroundColor Green
            Write-Host "IPMI:" $myvar_ipmi_ips
            Write-Host "Hosts:" $myvar_ntnx_hosts_ips
            Write-Host "CVMs:" $myvar_cvm_ips
        }
    }

    #let's figure out how much time this all took
	Write-Host "$(get-date) [SUM] total processing time: $($myvar_elapsed_time.Elapsed.ToString())" -ForegroundColor Magenta
	
	#cleanup after ourselves and delete all custom variables
	Remove-Variable myvar* -ErrorAction SilentlyContinue
	Remove-Variable ErrorActionPreference -ErrorAction SilentlyContinue
	Remove-Variable help -ErrorAction SilentlyContinue
    Remove-Variable history -ErrorAction SilentlyContinue
	Remove-Variable log -ErrorAction SilentlyContinue
	Remove-Variable cluster -ErrorAction SilentlyContinue
	Remove-Variable username -ErrorAction SilentlyContinue
	Remove-Variable password -ErrorAction SilentlyContinue
    Remove-Variable debugme -ErrorAction SilentlyContinue
#endregion