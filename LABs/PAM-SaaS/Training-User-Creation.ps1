# ==============================================================================
# 1. HELPER FUNCTIONS
# ==============================================================================
function Get-RandomPassword {
    [CmdletBinding()]
    Param([int]$Length = 20)
    
    $Upper   = "ABCDEFGHIJKLMNOPQRSTUVWXYZ".ToCharArray()
    $Lower   = "abcdefghijklmnopqrstuvwxyz".ToCharArray()
    $Numbers = "0123456789".ToCharArray()
    $Special = "!#$%&*?".ToCharArray()
    
    # Guarantee at least one of each type
    $Base = @($Upper | Get-Random), @($Lower | Get-Random), @($Numbers | Get-Random), @($Special | Get-Random)
    
    # Fill the rest
    $Pool = $Upper + $Lower + $Numbers + $Special
    $Base += 1..($Length - 4) | ForEach-Object { $Pool | Get-Random }
    
    return ($Base | Get-Random -Count $Length) -join ""
}

Function Get-IdentityURL($idURL) {
    Add-Type -AssemblyName System.Net.Http

    Function CreateHttpClient($allowAutoRedirect) {
        $handler = New-Object System.Net.Http.HttpClientHandler
        $handler.AllowAutoRedirect = $allowAutoRedirect
        return New-Object System.Net.Http.HttpClient($handler)
    }

    $client = CreateHttpClient($true)

    try {
        $task = $client.GetAsync($idURL)
        $task.Wait()  # Ensures the task completes and exceptions are thrown if any.

        if ($task.IsCompleted) {
            $response = $task.Result

            if (($response.StatusCode -ge 300 -and $response.StatusCode -lt 400) -or ($response.StatusCode -eq "OK")) {
                return $response.RequestMessage.RequestUri.Host
            } else {
                return "Unexpected status code: $($response.StatusCode)"
            }
        } else {
            return "Task did not complete successfully."
        }
    }
    catch {
        # Extracting detailed exception message from AggregateException
        $exception = $_.Exception
        while ($exception.InnerException) {
            $exception = $exception.InnerException
        }
        
        # Return the extracted exception message
        return "Error: $($exception.Message)"
    }
    finally {
        if ($client -ne $null) {
            $client.Dispose()
        }
    }
}

# ==============================================================================
# 2. DATA COLLECTION & VALIDATION
# ==============================================================================
Write-Host "--- CyberArk Tenant Initialization ---" -ForegroundColor Cyan

# Username
$UserPattern = '^tenantadmin@cyberark\.cloud\.[\w]+$'
do {
    $Username = Read-Host -Prompt "Enter Login Name (tenantadmin@cyberark.cloud.XXXXX)"
    if ($Username -notmatch $UserPattern) { Write-Host "Invalid format! Must be tenantadmin@cyberark.cloud.XXXXX" -ForegroundColor Red }
} while ($Username -notmatch $UserPattern)

# Password (Secure Loop using .NET class)
$PasswordsMatch = $false
while (-not $PasswordsMatch) {
    $SecPass1 = Read-Host -Prompt "Enter password" -AsSecureString
    $SecPass2 = Read-Host -Prompt "Confirm password" -AsSecureString

    $Password  = [System.Net.NetworkCredential]::new("", $SecPass1).Password
    $Password2 = [System.Net.NetworkCredential]::new("", $SecPass2).Password

    if ($Password -eq $Password2 -and -not [string]::IsNullOrWhiteSpace($Password)) {
        $PasswordsMatch = $true
        Write-Host "[+] Passwords match." -ForegroundColor Green
    } else {
        Write-Host "[-] Passwords do not match or are blank. Try again." -ForegroundColor Red
    }
}

# Tenant URL
$UrlPattern = '^https:\/\/[a-zA-Z0-9-]+.cyberark.cloud\/?$'
do {
    $PAMUrl = Read-Host -Prompt "Enter Tenant URL (https://acme-lab-XXXXX.cyberark.cloud)"
    if ($PAMUrl -notmatch $UrlPattern) { Write-Host "Invalid URL format!" -ForegroundColor Red }
} while ($PAMUrl -notmatch $UrlPattern)

$IdentityURL = Get-IdentityURL -idURL $PAMUrl
$IdentityURL = "https://${IdentityURL}"

# Generate Training Info
$TrainingUser = "training1@" + $Username.Split('@')[1]
$TrainingPwd  = Get-RandomPassword

# Export to CSV on Desktop
$ExportPath = Join-Path -Path "$HOME\Desktop" -ChildPath "TenantAdmin.csv"
[PSCustomObject]@{
    Login             = $Username
    PAM_SaaS_Url      = $PAMUrl
    Identity_Url      = $IdentityURL
    Training_User     = $TrainingUser
    Training_User_Pwd = $TrainingPwd
} | Export-Csv -Path $ExportPath -NoTypeInformation

Write-Host "`n[+] Tenant configuration saved to: $ExportPath" -ForegroundColor Green

# ==============================================================================
# 3. AUTHENTICATION (MFA FLOW)
# ==============================================================================
Write-Host "`n--- Authenticating to CyberArk Identity ---" -ForegroundColor Cyan

# Common RestMethod Splatting to save typing
$RestArgs = @{ Method = 'POST'; ContentType = 'application/json' }
$BaseHeaders = @{ "X-Idap-Native-Client" = "true" }

# Auth Step 1: Start
$body = @{ TenantId = $IdentityID; Version = "1.0"; User = $Username } | ConvertTo-Json
$res = Invoke-RestMethod -Uri "$IdentityURL/Security/StartAuthentication" -Headers $BaseHeaders -Body $body @RestArgs

if (-not $res.success) {
    Write-Error "Failed to start authentication: $($res.Message)"
    exit
}

$sid  = $res.Result.SessionId
$mid  = $res.Result.Challenges[0].Mechanisms[0].MechanismId
$mid2 = $res.Result.Challenges[1].Mechanisms[0].MechanismId

# Auth Step 2: Answer Password & Trigger MFA
$body = @{
    TenantId = $IdentityID
    SessionId = $sid
    MultipleOperations = @(
      @{ MechanismId = $mid; Answer = $Password; Action = "Answer" },
      @{ MechanismId = $mid2; Action = "StartOOB" }
    )
} | ConvertTo-Json -Depth 10
$res = Invoke-RestMethod -Uri "$IdentityURL/Security/AdvanceAuthentication" -Headers $BaseHeaders -Body $body @RestArgs

Write-Host "`n[!] MFA challenge sent to your device." -ForegroundColor Yellow
Read-Host "Press Enter AFTER you have approved the MFA..."

# Auth Step 3: Poll for Token
$body = @{ Action = "Poll"; TenantId = $IdentityID; SessionId = $sid; MechanismId = $mid2 } | ConvertTo-Json
$res = Invoke-RestMethod -Uri "$IdentityURL/Security/AdvanceAuthentication" -Headers $BaseHeaders -Body $body @RestArgs

if ($res.success) {
    $UToken = $res.Result.Token
    $BaseHeaders.Add("Authorization", "Bearer $UToken") # Add token to our reusable headers
    Write-Host "[+] Authentication Successful!" -ForegroundColor Green
} else {
    Write-Error "Authentication failed or MFA not approved in time."
    exit
}

# ==============================================================================
# 4. ENVIRONMENT SETUP: USER & SAFE MASTER ROLE
# ==============================================================================
Write-Host "`n--- Provisioning the Training Account ---" -ForegroundColor Cyan

Write-Host "IMPORTANT: If this is a Self-Paced, please leave the default email address" -ForegroundColor Yellow
Write-Host "Otherwise, you can change the email address to the trainer's email for direct support." -ForegroundColor Yellow
Write-Host "Input the trainer's email, or press Enter." -ForegroundColor Yellow

$isValid = $false

while (-not $isValid) {
    $InputEmail = Read-Host "Enter the Trainer's email (or press Enter to keep default)"

    # Check if the user just pressed Enter (empty input)
    if ([string]::IsNullOrWhiteSpace($InputEmail)) {
        $TrainingUserMail = "cybr-training-labs+PAMSAAS_Trainer@paloaltonetworks.com"
        $isValid = $true
    } else {
        # Try to cast the input to a valid mail address
        try {
            $mail = [mailaddress]$InputEmail
            $TrainingUserMail = $mail.Address
            $isValid = $true
        } catch {
            Write-Host "Invalid email format. Please enter a valid email address or press Enter for the default." -ForegroundColor Red
        }
    }
}

Write-Host "Trainer email successfully set to: $TrainingUserMail" -ForegroundColor Green
Write-Host "NOTE: You can change this email at any time in the Identity Management console." -ForegroundColor Yellow

# Create Training User
$body = @{
    Name = $TrainingUser
    Mail = $TrainingUserMail
    Password = $TrainingPwd
    InEverybodyRole = $true
    InSysAdminRole = $true
    ForcePasswordChangeNext = $false
    SendEmailInvite = $true
    SendSmsInvite = $false
    PasswordNeverExpire = $true
} | ConvertTo-Json -Depth 10

$res = Invoke-RestMethod -Uri "$IdentityURL/CDirectoryService/CreateUser" -Headers $BaseHeaders -Body $body @RestArgs
if ($res.success) {
    $UserUuid = $res.Result
    Write-Host "[+] User created: $TrainingUser" -ForegroundColor Green
} else {
    Write-Host "[-] Failed to create user: $($res.Message)" -ForegroundColor Red
}

# Create Safe Master Role
$body = @{ Name = "Safe Master1"; Description = "Grant members permissions"; RoleType = "PrincipalList" } | ConvertTo-Json
$res = Invoke-RestMethod -Uri "$IdentityURL/Roles/StoreRole" -Headers $BaseHeaders -Body $body @RestArgs
if ($res.success) {
    $RoleID = $res.Result._RowKey
    Write-Host "[+] Role created: Safe Master" -ForegroundColor Green
} else {
    Write-Host "[-] Failed to create role: $($res.Message)" -ForegroundColor Red
}

Start-Sleep -Seconds 3 # Give Identity backend a moment to sync

# Assign User to Safe Master Role
if ($null -ne $RoleID -and $null -ne $UserUuid) {
    $body = @{ Users = @{ Add = @($UserUuid) }; Name = $RoleID } | ConvertTo-Json -Depth 10
    $res = Invoke-RestMethod -Uri "$IdentityURL/Roles/UpdateRole" -Headers $BaseHeaders -Body $body @RestArgs
    if ($res.success) { Write-Host "[+] User added to Safe Master role!" -ForegroundColor Green }
} else {
    Write-Host "[-] The user is already a member of the Safe Master role." -ForegroundColor Red
}

# ==============================================================================
# 5. ASSIGN PRIVILEGE CLOUD ADMINISTRATORS ROLE
# ==============================================================================
Write-Host "`n--- Assigning Privilege Cloud Administrators Role ---" -ForegroundColor Cyan

# Query Redrock for the Role ID
$body = @{ Script = "SELECT Role.Description, Role.ID, Role.Name FROM Role WHERE Role.Name = 'Privilege Cloud Administrators'" } | ConvertTo-Json
$response = Invoke-RestMethod -Uri "$IdentityURL/Redrock/query" -Headers $BaseHeaders -Body $body @RestArgs

# Extract the Role ID
$PrivCloudAdmins = $response.Result.Results[0].Entities[0].Key

if (-not [string]::IsNullOrWhiteSpace($PrivCloudAdmins)) {
    Write-Host "[+] Found Privilege Cloud Admins Role ID: $PrivCloudAdmins" -ForegroundColor Green
    
    # Grant membership
    $authBody = @{ Users = @{ Add = @($UserUuid) }; Name = $PrivCloudAdmins } | ConvertTo-Json -Depth 10
    $response = Invoke-RestMethod -Uri "$IdentityURL/Roles/UpdateRole" -Headers $BaseHeaders -Body $authBody @RestArgs

    if ($response.success) {
        Write-Host "[+] User successfully added to Privilege Cloud Administrators!" -ForegroundColor Green
    } else {
        Write-Host "[-] API Error while adding to role: $($response.Message)" -ForegroundColor Red
    }
} else {
    Write-Host "[-] Failed: Could not find 'Privilege Cloud Administrators'." -ForegroundColor Yellow
}

$body = @{ Script = "SELECT ID, Username FROM User WHERE Username LIKE 'installeruser@%'" } | ConvertTo-Json
$response = Invoke-RestMethod -Uri "$IdentityURL/Redrock/query" -Headers $BaseHeaders -Body $body @RestArgs
$installerUserId = $response.Result.Results.Row.ID
$installerUserName = $response.Result.Results.Row.Username

# Export to CSV on Desktop
$ExportPath = Join-Path -Path "$HOME\Desktop" -ChildPath "TenantAdmin.csv"
[PSCustomObject]@{
    Login             = $Username
    PAM_SaaS_Url      = $PAMUrl
    Identity_Url      = $IdentityURL
    Training_User     = $TrainingUser
    Training_User_Pwd = $TrainingPwd
    Installer_User    = $installerUserName
    Installer_User_Pwd = "Paste Here"
    Installer_User_Id = $installerUserId
} | Export-Csv -Path $ExportPath -NoTypeInformation

Write-Host "`n--- Onboarding Complete ---" -ForegroundColor Cyan

# SIG # Begin signature block
# MIIITgYJKoZIhvcNAQcCoIIIPzCCCDsCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCD+EiBKMfYv2a1w
# zHvfAz2+xpLJ//MlwHL6BtcE9xPkiaCCBZgwggWUMIIEfKADAgECAhN+AAAAXDZd
# cRsjYYagAAAAAABcMA0GCSqGSIb3DQEBCwUAMEMxFDASBgoJkiaJk/IsZAEZFgRj
# b3JwMRQwEgYKCZImiZPyLGQBGRYEYWNtZTEVMBMGA1UEAxMMYWNtZS1EQzAxLUNB
# MB4XDTI1MTIwMjAwMjMxM1oXDTI3MTIwMjAwMzMxM1owHDEaMBgGA1UEAxMRQUNN
# RSBDb2RlIFNpZ25pbmcwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCn
# LugVsShtFlWxMIG5oXDEMqxHubR0iEHbNO8PjltukjK4hoOJZv2IzY3D9o7KcNo6
# nV1Tovj9GertL2FDFSoz7iMoQKDr0uKzkCxqQ5jBSAhV/dtht78zfcP/rlJbYO9P
# OvP5LUkpJ8T1miflziJcLmaaJ+j3BIimVxKeMnkPw853BM6HflQDdMggDJaqJD+d
# ahkV8ORiTz5LpuKuXkqr/ULHaQwLB5QtJpxW+ExVOhLfaTjji4DwlLs8zJCg8dbM
# 0KK/p1EU/bXJDg/kIBsigYwFYOIc3WRQNRTJpvR/r0WqtQ99yxyHimPVwXOSkwm4
# xem9WWZl0Lf3WlKEKOoNAgMBAAGjggKmMIICojA9BgkrBgEEAYI3FQcEMDAuBiYr
# BgEEAYI3FQiDwJNuhsfyQ4XhkxmEnNw4g7q/UyeFzf4PhKaTOQIBZAIBCjATBgNV
# HSUEDDAKBggrBgEFBQcDAzAOBgNVHQ8BAf8EBAMCBsAwGwYJKwYBBAGCNxUKBA4w
# DDAKBggrBgEFBQcDAzAdBgNVHQ4EFgQUpXEcaXx/IwMLhrAgV4y9z02JWp4wHwYD
# VR0jBBgwFoAUZ3ws+ydvUBVN4Sd3zC+8tvMpl3EwgfcGA1UdHwSB7zCB7DCB6aCB
# 5qCB44aBrmxkYXA6Ly8vQ049YWNtZS1EQzAxLUNBLENOPWRjMDEsQ049Q0RQLENO
# PVB1YmxpYyUyMEtleSUyMFNlcnZpY2VzLENOPVNlcnZpY2VzLENOPUNvbmZpZ3Vy
# YXRpb24sREM9YWNtZSxEQz1jb3JwP2NlcnRpZmljYXRlUmV2b2NhdGlvbkxpc3Q/
# YmFzZT9vYmplY3RDbGFzcz1jUkxEaXN0cmlidXRpb25Qb2ludIYwaHR0cDovL2Ny
# bC5hY21lLmNvcnAvQ2VydEVucm9sbC9hY21lLURDMDEtQ0EuY3JsMIHkBggrBgEF
# BQcBAQSB1zCB1DCBqQYIKwYBBQUHMAKGgZxsZGFwOi8vL0NOPWFjbWUtREMwMS1D
# QSxDTj1BSUEsQ049UHVibGljJTIwS2V5JTIwU2VydmljZXMsQ049U2VydmljZXMs
# Q049Q29uZmlndXJhdGlvbixEQz1hY21lLERDPWNvcnA/Y0FDZXJ0aWZpY2F0ZT9i
# YXNlP29iamVjdENsYXNzPWNlcnRpZmljYXRpb25BdXRob3JpdHkwJgYIKwYBBQUH
# MAGGGmh0dHA6Ly9vY3NwLmFjbWUuY29ycC9vY3NwMA0GCSqGSIb3DQEBCwUAA4IB
# AQCF2946OzdjjVLqxh6TXobgpbkPafR2GaL84BWhvSjS3FpfIlCpVUjRRxIDraG2
# N3GsMAIuz8AbBsl77aIXrnSKibQ6Gudgt2JumHOml+hHkvv/wBZSxlDjKBK3uD2G
# 8LHpwvsVFJDXYwMdrJiFteJzsWKWcPYsNw3ruR3F9pzleK6dzWXYZd9RwIb1BHo3
# pvgq8tJvbZhVST+hQRiEfdrD4GX/T5gZMXyBgBlTb+jS3F+KrV8rgybCCLjb88xD
# PMEn1rP+9NUoCZRI6DcNLEK1UuKbScTAgZN4qCaUKKSW/axnvRpamaCktj550pXp
# icNse97f5rpgzzuAJ04BTEVrMYICDDCCAggCAQEwWjBDMRQwEgYKCZImiZPyLGQB
# GRYEY29ycDEUMBIGCgmSJomT8ixkARkWBGFjbWUxFTATBgNVBAMTDGFjbWUtREMw
# MS1DQQITfgAAAFw2XXEbI2GGoAAAAAAAXDANBglghkgBZQMEAgEFAKCBhDAYBgor
# BgEEAYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEE
# MBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCBo
# +GWu4AjgUN9de5cQriyegF+tDmGgcnlrBdjV+3W9CTANBgkqhkiG9w0BAQEFAASC
# AQAHAvg7ZP9s0VLf986/rdildf7gtojSk2aGHQ3Ltqbkbjvv9hByCHvzBZOVGIZV
# oONwtL3ZW/7Zi7s8Z31pIne3ifE5tU5V1XM8MO8lKraA0+qUM7G9dn2Cl7b1JAx3
# Qr5EM5/sKJ6a2Cjqd6bJTJox8Hbx/c2Fd5oyfcONospD44OP4oBE2SXP+73tHInq
# DbhZM/bN838WawuFG44pS8WwWNjIUKhMGROziXrmJ8clmBrSV7fqRlZLzopxUA+P
# oY0cIFt90NGWxj/6pu/M65aruI/eLBBdIke2Y3GnN91xz4zS0+PLH5WKufM41gWI
# MA/eK03z+xlo/b6ZD8sL30GH
# SIG # End signature block
