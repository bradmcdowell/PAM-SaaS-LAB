#This script is aimed at creating the PSMConnect and PSMAdminConnect account in the domain and provide the appropriate configuration as per documentation.
#Important: Do not use those scripts in your own environment, this script is only designed to work in this training environment. 

# Define accounts to create and a secure default password
$accountsToCreate = @("PSMConnect", “PSMAdminConnect")
$ou = "OU=Service Accounts,OU=CyberArk,OU=Domain Users and Groups,DC=acme,DC=corp"
$defaultPassword  = "Cyberark1"
$secureDefaultPwd = ConvertTo-SecureString $defaultPassword -AsPlainText -Force   # Convert plaintext to SecureString
$allowedComputers = "connector1"
$envPSMConnect = @'
                                                P	CtxCfgPresent㔵攱戰ぢCtxCfgFlags1〰〱㈲〸CtxShadow㐰〰〰〰.CtxMaxDisconnectionTime〶慥〰〰*CtxMinEncryptionLevel㄰ ^CtxWorkDirectory㌴愳挵〵㈷昶㜶㈷ㄶ搶〲㘴㤶挶㔶㌷〲㠲㠷㠳㘳㤲挵㌴㤷㈶㔶㈷ㄴ㈷戶挵〵㌵搴挵㌴昶搶〷昶收㔶收㐷㌷〰"¼CtxWorkDirectoryW㌴〰愳〰挵〰〵〰㈷〰昶〰㜶〰㈷〰ㄶ〰搶〰〲〰㘴〰㤶〰挶〰㔶〰㌷〰〲〰㠲〰㠷〰㠳〰㘳〰㤲〰挵〰㌴〰㤷〰㈶〰㔶〰㈷〰ㄴ〰㈷〰戶〰挵〰〵〰㌵〰搴〰挵〰㌴〰昶〰搶〰〷〰昶〰收〰㔶〰收〰㐷〰㌷〰〰〰"CtxInitialProgram㌴愳挵〵㈷昶㜶㈷ㄶ搶〲㘴㤶挶㔶㌷〲㠲㠷㠳㘳㤲挵㌴㤷㈶㔶㈷ㄴ㈷戶挵〵㌵搴挵㌴昶搶〷昶收㔶收㐷㌷挵〵㌵搴㤴收㤶㐷㌵㔶㌷㌷㤶昶收攲㔶㠷㔶〰$ĈCtxInitialProgramW㌴〰愳〰挵〰〵〰㈷〰昶〰㜶〰㈷〰ㄶ〰搶〰〲〰㘴〰㤶〰挶〰㔶〰㌷〰〲〰㠲〰㠷〰㠳〰㘳〰㤲〰挵〰㌴〰㤷〰㈶〰㔶〰㈷〰ㄴ〰㈷〰戶〰挵〰〵〰㌵〰搴〰挵〰㌴〰昶〰搶〰〷〰昶〰收〰㔶〰收〰㐷〰㌷〰挵〰〵〰㌵〰搴〰㤴〰收〰㤶〰㐷〰㌵〰㔶〰㌷〰㌷〰㤶〰昶〰收〰攲〰㔶〰㠷〰㔶〰〰〰
'@
$envPSMAdmin = @'
                                                PCtxCfgPresent㔵攱戰ぢCtxCfgFlags1〰〱〲〸CtxShadow㐰〰〰〰*CtxMinEncryptionLevel㄰ ^CtxWorkDirectory㌴愳挵〵㈷昶㜶㈷ㄶ搶〲㘴㤶挶㔶㌷〲㠲㠷㠳㘳㤲挵㌴㤷㈶㔶㈷ㄴ㈷戶挵〵㌵搴挵㌴昶搶〷昶收㔶收㐷㌷〰"¼CtxWorkDirectoryW㌴〰愳〰挵〰〵〰㈷〰昶〰㜶〰㈷〰ㄶ〰搶〰〲〰㘴〰㤶〰挶〰㔶〰㌷〰〲〰㠲〰㠷〰㠳〰㘳〰㤲〰挵〰㌴〰㤷〰㈶〰㔶〰㈷〰ㄴ〰㈷〰戶〰挵〰〵〰㌵〰搴〰挵〰㌴〰昶〰搶〰〷〰昶〰收〰㔶〰收〰㐷〰㌷〰〰〰"CtxInitialProgram㌴愳挵〵㈷昶㜶㈷ㄶ搶〲㘴㤶挶㔶㌷〲㠲㠷㠳㘳㤲挵㌴㤷㈶㔶㈷ㄴ㈷戶挵〵㌵搴挵㌴昶搶〷昶收㔶收㐷㌷挵〵㌵搴㤴收㤶㐷㌵㔶㌷㌷㤶昶收攲㔶㠷㔶〰$ĈCtxInitialProgramW㌴〰愳〰挵〰〵〰㈷〰昶〰㜶〰㈷〰ㄶ〰搶〰〲〰㘴〰㤶〰挶〰㔶〰㌷〰〲〰㠲〰㠷〰㠳〰㘳〰㤲〰挵〰㌴〰㤷〰㈶〰㔶〰㈷〰ㄴ〰㈷〰戶〰挵〰〵〰㌵〰搴〰挵〰㌴〰昶〰搶〰〷〰昶〰收〰㔶〰收〰㐷〰㌷〰挵〰〵〰㌵〰搴〰㤴〰收〰㤶〰㐷〰㌵〰㔶〰㌷〰㌷〰㤶〰昶〰收〰攲〰㔶〰㠷〰㔶〰〰〰
'@
# Import the module containing reusable functions
Import-Module "$PWD\AccountProvisioningHelper.psm1"

# 1. Start logging (transcript)
$LogFileName = "AccountProvisioningOutput.txt"
$logPath = Join-Path $PWD $LogFileName
Write-Host "Log file location: $logPath"
Start-Transcript -Path $logPath -Append

# 2. Import AD module
Import-ADModuleSafe

# 3 & 4. Prompt and validate Domain Admin credentials
$AdminCred = Get-VerifiedAdminCredential -PromptMessage "Enter Domain Admin level credentials for acme\mike_da"

# 5. Define accounts, OU, and password
$accountsToCreate = @("PSMConnect", “PSMAdminConnect")
$defaultPassword  = "Cyberark1"
$ou = "OU=Service Accounts,OU=CyberArk,OU=Domain Users and Groups,DC=acme,DC=corp"
$secureDefaultPwd = ConvertTo-SecureString $defaultPassword -AsPlainText -Force
$allowedComputers = "connector1"

# 6. Create each account
foreach ($user in $accountsToCreate) {
    Write-Host "`n===== Processing account: $user ====="
   
    # Check if the user already exists
    $existingUser = Get-ADUser -Filter "SamAccountName -eq '$user'" -Credential $AdminCred -ErrorAction SilentlyContinue
   
    if ($existingUser) 
    {
    Write-Warning "User '$user' already exists in Active Directory."

    $response = Read-Host "Do you want to delete and recreate the user '$user'? (Y/N)"
    if ($response -match '^[Yy]$') {
        try {
            Remove-ADUser -Identity $existingUser -Credential $AdminCred -Confirm:$false -ErrorAction Stop
            Write-Host "Deleted existing user '$user'."
        } catch {
            Write-Error "Failed to delete existing user '$user': $_"
           return $false
                }
        } else {
            Write-Host "Skipping creation of user '$user'."
            return $false
                }
    }

    try {
       New-ADUser -Name $user -SamAccountName $user -UserPrincipalName "$user@ACME.corp" `
                 -Path $ou -AccountPassword $secureDefaultPwd -Enabled $true `
                 -ChangePasswordAtLogon $false -PasswordNeverExpires $true `
                 -Credential $AdminCred -ErrorAction Stop
       Write-Host "Created AD user '$user'."
    } catch {
       Write-Error "Failed to create user." 
       continue
    }

    #Restrict allowed logon workstations to "dc01,connector1"
    Try {
        Set-ADUser -Identity $user -LogonWorkstations $allowedComputers -Credential $AdminCred -ErrorAction Stop
        Write-Host "Restricted logon for $user to workstations: $allowedComputers."
    } Catch {
       #Write-Error "Failed to set LogonWorkstations for $user: $_"
        # Continue to delegation even if this fails (or use 'continue' to skip delegation for this user)
    }

}
Try {
        Set-ADUser -Identity "PSMConnect" -Add @{userParameters=$envPSMConnect} -Credential $AdminCred -ErrorAction Stop
        Write-Host "Adding Environment parameters."
    } Catch {
        Write-Error "Failed to set environmental variables"
    }

        #Inject the environment values for PSMAdminConnect
    Try {
        Set-ADUser -Identity "PSMAdminConnect" -Add @{userParameters=$envPSMAdmin} -Credential $AdminCred -ErrorAction Stop
        Write-Host "Adding Environment parameters"
    } Catch {
        Write-Error "Failed to set environmental variables"
    }

# 7. Stop logging and cleanup
Stop-LoggingSession -Credential $AdminCred