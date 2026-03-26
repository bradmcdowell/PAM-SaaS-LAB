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
# MIIesgYJKoZIhvcNAQcCoIIeozCCHp8CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCD+EiBKMfYv2a1w
# zHvfAz2+xpLJ//MlwHL6BtcE9xPkiaCCGNIwggWNMIIEdaADAgECAhAOmxiO+dAt
# 5+/bUOIIQBhaMA0GCSqGSIb3DQEBDAUAMGUxCzAJBgNVBAYTAlVTMRUwEwYDVQQK
# EwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xJDAiBgNV
# BAMTG0RpZ2lDZXJ0IEFzc3VyZWQgSUQgUm9vdCBDQTAeFw0yMjA4MDEwMDAwMDBa
# Fw0zMTExMDkyMzU5NTlaMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2Vy
# dCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lD
# ZXJ0IFRydXN0ZWQgUm9vdCBHNDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoC
# ggIBAL/mkHNo3rvkXUo8MCIwaTPswqclLskhPfKK2FnC4SmnPVirdprNrnsbhA3E
# MB/zG6Q4FutWxpdtHauyefLKEdLkX9YFPFIPUh/GnhWlfr6fqVcWWVVyr2iTcMKy
# unWZanMylNEQRBAu34LzB4TmdDttceItDBvuINXJIB1jKS3O7F5OyJP4IWGbNOsF
# xl7sWxq868nPzaw0QF+xembud8hIqGZXV59UWI4MK7dPpzDZVu7Ke13jrclPXuU1
# 5zHL2pNe3I6PgNq2kZhAkHnDeMe2scS1ahg4AxCN2NQ3pC4FfYj1gj4QkXCrVYJB
# MtfbBHMqbpEBfCFM1LyuGwN1XXhm2ToxRJozQL8I11pJpMLmqaBn3aQnvKFPObUR
# WBf3JFxGj2T3wWmIdph2PVldQnaHiZdpekjw4KISG2aadMreSx7nDmOu5tTvkpI6
# nj3cAORFJYm2mkQZK37AlLTSYW3rM9nF30sEAMx9HJXDj/chsrIRt7t/8tWMcCxB
# YKqxYxhElRp2Yn72gLD76GSmM9GJB+G9t+ZDpBi4pncB4Q+UDCEdslQpJYls5Q5S
# UUd0viastkF13nqsX40/ybzTQRESW+UQUOsxxcpyFiIJ33xMdT9j7CFfxCBRa2+x
# q4aLT8LWRV+dIPyhHsXAj6KxfgommfXkaS+YHS312amyHeUbAgMBAAGjggE6MIIB
# NjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBTs1+OC0nFdZEzfLmc/57qYrhwP
# TzAfBgNVHSMEGDAWgBRF66Kv9JLLgjEtUYunpyGd823IDzAOBgNVHQ8BAf8EBAMC
# AYYweQYIKwYBBQUHAQEEbTBrMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdp
# Y2VydC5jb20wQwYIKwYBBQUHMAKGN2h0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNv
# bS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RDQS5jcnQwRQYDVR0fBD4wPDA6oDigNoY0
# aHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9vdENB
# LmNybDARBgNVHSAECjAIMAYGBFUdIAAwDQYJKoZIhvcNAQEMBQADggEBAHCgv0Nc
# Vec4X6CjdBs9thbX979XB72arKGHLOyFXqkauyL4hxppVCLtpIh3bb0aFPQTSnov
# Lbc47/T/gLn4offyct4kvFIDyE7QKt76LVbP+fT3rDB6mouyXtTP0UNEm0Mh65Zy
# oUi0mcudT6cGAxN3J0TU53/oWajwvy8LpunyNDzs9wPHh6jSTEAZNUZqaVSwuKFW
# juyk1T3osdz9HNj0d1pcVIxv76FQPfx2CWiEn2/K2yCNNWAcAgPLILCsWKAOQGPF
# mCLBsln1VWvPJ6tsds5vIy30fnFqI2si/xK4VC0nftg62fC2h5b9W9FcrBjDTZ9z
# twGpn1eqXijiuZQwggWUMIIEfKADAgECAhN+AAAAXDZdcRsjYYagAAAAAABcMA0G
# CSqGSIb3DQEBCwUAMEMxFDASBgoJkiaJk/IsZAEZFgRjb3JwMRQwEgYKCZImiZPy
# LGQBGRYEYWNtZTEVMBMGA1UEAxMMYWNtZS1EQzAxLUNBMB4XDTI1MTIwMjAwMjMx
# M1oXDTI3MTIwMjAwMzMxM1owHDEaMBgGA1UEAxMRQUNNRSBDb2RlIFNpZ25pbmcw
# ggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCnLugVsShtFlWxMIG5oXDE
# MqxHubR0iEHbNO8PjltukjK4hoOJZv2IzY3D9o7KcNo6nV1Tovj9GertL2FDFSoz
# 7iMoQKDr0uKzkCxqQ5jBSAhV/dtht78zfcP/rlJbYO9POvP5LUkpJ8T1miflziJc
# LmaaJ+j3BIimVxKeMnkPw853BM6HflQDdMggDJaqJD+dahkV8ORiTz5LpuKuXkqr
# /ULHaQwLB5QtJpxW+ExVOhLfaTjji4DwlLs8zJCg8dbM0KK/p1EU/bXJDg/kIBsi
# gYwFYOIc3WRQNRTJpvR/r0WqtQ99yxyHimPVwXOSkwm4xem9WWZl0Lf3WlKEKOoN
# AgMBAAGjggKmMIICojA9BgkrBgEEAYI3FQcEMDAuBiYrBgEEAYI3FQiDwJNuhsfy
# Q4XhkxmEnNw4g7q/UyeFzf4PhKaTOQIBZAIBCjATBgNVHSUEDDAKBggrBgEFBQcD
# AzAOBgNVHQ8BAf8EBAMCBsAwGwYJKwYBBAGCNxUKBA4wDDAKBggrBgEFBQcDAzAd
# BgNVHQ4EFgQUpXEcaXx/IwMLhrAgV4y9z02JWp4wHwYDVR0jBBgwFoAUZ3ws+ydv
# UBVN4Sd3zC+8tvMpl3EwgfcGA1UdHwSB7zCB7DCB6aCB5qCB44aBrmxkYXA6Ly8v
# Q049YWNtZS1EQzAxLUNBLENOPWRjMDEsQ049Q0RQLENOPVB1YmxpYyUyMEtleSUy
# MFNlcnZpY2VzLENOPVNlcnZpY2VzLENOPUNvbmZpZ3VyYXRpb24sREM9YWNtZSxE
# Qz1jb3JwP2NlcnRpZmljYXRlUmV2b2NhdGlvbkxpc3Q/YmFzZT9vYmplY3RDbGFz
# cz1jUkxEaXN0cmlidXRpb25Qb2ludIYwaHR0cDovL2NybC5hY21lLmNvcnAvQ2Vy
# dEVucm9sbC9hY21lLURDMDEtQ0EuY3JsMIHkBggrBgEFBQcBAQSB1zCB1DCBqQYI
# KwYBBQUHMAKGgZxsZGFwOi8vL0NOPWFjbWUtREMwMS1DQSxDTj1BSUEsQ049UHVi
# bGljJTIwS2V5JTIwU2VydmljZXMsQ049U2VydmljZXMsQ049Q29uZmlndXJhdGlv
# bixEQz1hY21lLERDPWNvcnA/Y0FDZXJ0aWZpY2F0ZT9iYXNlP29iamVjdENsYXNz
# PWNlcnRpZmljYXRpb25BdXRob3JpdHkwJgYIKwYBBQUHMAGGGmh0dHA6Ly9vY3Nw
# LmFjbWUuY29ycC9vY3NwMA0GCSqGSIb3DQEBCwUAA4IBAQCF2946OzdjjVLqxh6T
# XobgpbkPafR2GaL84BWhvSjS3FpfIlCpVUjRRxIDraG2N3GsMAIuz8AbBsl77aIX
# rnSKibQ6Gudgt2JumHOml+hHkvv/wBZSxlDjKBK3uD2G8LHpwvsVFJDXYwMdrJiF
# teJzsWKWcPYsNw3ruR3F9pzleK6dzWXYZd9RwIb1BHo3pvgq8tJvbZhVST+hQRiE
# fdrD4GX/T5gZMXyBgBlTb+jS3F+KrV8rgybCCLjb88xDPMEn1rP+9NUoCZRI6DcN
# LEK1UuKbScTAgZN4qCaUKKSW/axnvRpamaCktj550pXpicNse97f5rpgzzuAJ04B
# TEVrMIIGtDCCBJygAwIBAgIQDcesVwX/IZkuQEMiDDpJhjANBgkqhkiG9w0BAQsF
# ADBiMQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQL
# ExB3d3cuZGlnaWNlcnQuY29tMSEwHwYDVQQDExhEaWdpQ2VydCBUcnVzdGVkIFJv
# b3QgRzQwHhcNMjUwNTA3MDAwMDAwWhcNMzgwMTE0MjM1OTU5WjBpMQswCQYDVQQG
# EwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMTOERpZ2lDZXJ0
# IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2IDIwMjUgQ0Ex
# MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAtHgx0wqYQXK+PEbAHKx1
# 26NGaHS0URedTa2NDZS1mZaDLFTtQ2oRjzUXMmxCqvkbsDpz4aH+qbxeLho8I6jY
# 3xL1IusLopuW2qftJYJaDNs1+JH7Z+QdSKWM06qchUP+AbdJgMQB3h2DZ0Mal5kY
# p77jYMVQXSZH++0trj6Ao+xh/AS7sQRuQL37QXbDhAktVJMQbzIBHYJBYgzWIjk8
# eDrYhXDEpKk7RdoX0M980EpLtlrNyHw0Xm+nt5pnYJU3Gmq6bNMI1I7Gb5IBZK4i
# vbVCiZv7PNBYqHEpNVWC2ZQ8BbfnFRQVESYOszFI2Wv82wnJRfN20VRS3hpLgIR4
# hjzL0hpoYGk81coWJ+KdPvMvaB0WkE/2qHxJ0ucS638ZxqU14lDnki7CcoKCz6eu
# m5A19WZQHkqUJfdkDjHkccpL6uoG8pbF0LJAQQZxst7VvwDDjAmSFTUms+wV/FbW
# Bqi7fTJnjq3hj0XbQcd8hjj/q8d6ylgxCZSKi17yVp2NL+cnT6Toy+rN+nM8M7Ln
# LqCrO2JP3oW//1sfuZDKiDEb1AQ8es9Xr/u6bDTnYCTKIsDq1BtmXUqEG1NqzJKS
# 4kOmxkYp2WyODi7vQTCBZtVFJfVZ3j7OgWmnhFr4yUozZtqgPrHRVHhGNKlYzyjl
# roPxul+bgIspzOwbtmsgY1MCAwEAAaOCAV0wggFZMBIGA1UdEwEB/wQIMAYBAf8C
# AQAwHQYDVR0OBBYEFO9vU0rp5AZ8esrikFb2L9RJ7MtOMB8GA1UdIwQYMBaAFOzX
# 44LScV1kTN8uZz/nupiuHA9PMA4GA1UdDwEB/wQEAwIBhjATBgNVHSUEDDAKBggr
# BgEFBQcDCDB3BggrBgEFBQcBAQRrMGkwJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3Nw
# LmRpZ2ljZXJ0LmNvbTBBBggrBgEFBQcwAoY1aHR0cDovL2NhY2VydHMuZGlnaWNl
# cnQuY29tL0RpZ2lDZXJ0VHJ1c3RlZFJvb3RHNC5jcnQwQwYDVR0fBDwwOjA4oDag
# NIYyaHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3RlZFJvb3RH
# NC5jcmwwIAYDVR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9bAcBMA0GCSqGSIb3
# DQEBCwUAA4ICAQAXzvsWgBz+Bz0RdnEwvb4LyLU0pn/N0IfFiBowf0/Dm1wGc/Do
# 7oVMY2mhXZXjDNJQa8j00DNqhCT3t+s8G0iP5kvN2n7Jd2E4/iEIUBO41P5F448r
# SYJ59Ib61eoalhnd6ywFLerycvZTAz40y8S4F3/a+Z1jEMK/DMm/axFSgoR8n6c3
# nuZB9BfBwAQYK9FHaoq2e26MHvVY9gCDA/JYsq7pGdogP8HRtrYfctSLANEBfHU1
# 6r3J05qX3kId+ZOczgj5kjatVB+NdADVZKON/gnZruMvNYY2o1f4MXRJDMdTSlOL
# h0HCn2cQLwQCqjFbqrXuvTPSegOOzr4EWj7PtspIHBldNE2K9i697cvaiIo2p61E
# d2p8xMJb82Yosn0z4y25xUbI7GIN/TpVfHIqQ6Ku/qjTY6hc3hsXMrS+U0yy+GWq
# AXam4ToWd2UQ1KYT70kZjE4YtL8Pbzg0c1ugMZyZZd/BdHLiRu7hAWE6bTEm4XYR
# kA6Tl4KSFLFk43esaUeqGkH/wyW4N7OigizwJWeukcyIPbAvjSabnf7+Pu0VrFgo
# iovRDiyx3zEdmcif/sYQsfch28bZeUz2rtY/9TCA6TD8dC3JE3rYkrhLULy7Dc90
# G6e8BlqmyIjlgp2+VqsS9/wQD7yFylIz0scmbKvFoW2jNrbM1pD2T7m3XDCCBu0w
# ggTVoAMCAQICEAqA7xhLjfEFgtHEdqeVdGgwDQYJKoZIhvcNAQELBQAwaTELMAkG
# A1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdp
# Q2VydCBUcnVzdGVkIEc0IFRpbWVTdGFtcGluZyBSU0E0MDk2IFNIQTI1NiAyMDI1
# IENBMTAeFw0yNTA2MDQwMDAwMDBaFw0zNjA5MDMyMzU5NTlaMGMxCzAJBgNVBAYT
# AlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjE7MDkGA1UEAxMyRGlnaUNlcnQg
# U0hBMjU2IFJTQTQwOTYgVGltZXN0YW1wIFJlc3BvbmRlciAyMDI1IDEwggIiMA0G
# CSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDQRqwtEsae0OquYFazK1e6b1H/hnAK
# Ad/KN8wZQjBjMqiZ3xTWcfsLwOvRxUwXcGx8AUjni6bz52fGTfr6PHRNv6T7zsf1
# Y/E3IU8kgNkeECqVQ+3bzWYesFtkepErvUSbf+EIYLkrLKd6qJnuzK8Vcn0DvbDM
# emQFoxQ2Dsw4vEjoT1FpS54dNApZfKY61HAldytxNM89PZXUP/5wWWURK+IfxiOg
# 8W9lKMqzdIo7VA1R0V3Zp3DjjANwqAf4lEkTlCDQ0/fKJLKLkzGBTpx6EYevvOi7
# XOc4zyh1uSqgr6UnbksIcFJqLbkIXIPbcNmA98Oskkkrvt6lPAw/p4oDSRZreiwB
# 7x9ykrjS6GS3NR39iTTFS+ENTqW8m6THuOmHHjQNC3zbJ6nJ6SXiLSvw4Smz8U07
# hqF+8CTXaETkVWz0dVVZw7knh1WZXOLHgDvundrAtuvz0D3T+dYaNcwafsVCGZKU
# hQPL1naFKBy1p6llN3QgshRta6Eq4B40h5avMcpi54wm0i2ePZD5pPIssoszQyF4
# //3DoK2O65Uck5Wggn8O2klETsJ7u8xEehGifgJYi+6I03UuT1j7FnrqVrOzaQoV
# JOeeStPeldYRNMmSF3voIgMFtNGh86w3ISHNm0IaadCKCkUe2LnwJKa8TIlwCUNV
# wppwn4D3/Pt5pwIDAQABo4IBlTCCAZEwDAYDVR0TAQH/BAIwADAdBgNVHQ4EFgQU
# 5Dv88jHt/f3X85FxYxlQQ89hjOgwHwYDVR0jBBgwFoAU729TSunkBnx6yuKQVvYv
# 1Ensy04wDgYDVR0PAQH/BAQDAgeAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMIGV
# BggrBgEFBQcBAQSBiDCBhTAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNl
# cnQuY29tMF0GCCsGAQUFBzAChlFodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20v
# RGlnaUNlcnRUcnVzdGVkRzRUaW1lU3RhbXBpbmdSU0E0MDk2U0hBMjU2MjAyNUNB
# MS5jcnQwXwYDVR0fBFgwVjBUoFKgUIZOaHR0cDovL2NybDMuZGlnaWNlcnQuY29t
# L0RpZ2lDZXJ0VHJ1c3RlZEc0VGltZVN0YW1waW5nUlNBNDA5NlNIQTI1NjIwMjVD
# QTEuY3JsMCAGA1UdIAQZMBcwCAYGZ4EMAQQCMAsGCWCGSAGG/WwHATANBgkqhkiG
# 9w0BAQsFAAOCAgEAZSqt8RwnBLmuYEHs0QhEnmNAciH45PYiT9s1i6UKtW+FERp8
# FgXRGQ/YAavXzWjZhY+hIfP2JkQ38U+wtJPBVBajYfrbIYG+Dui4I4PCvHpQuPqF
# gqp1PzC/ZRX4pvP/ciZmUnthfAEP1HShTrY+2DE5qjzvZs7JIIgt0GCFD9ktx0Lx
# xtRQ7vllKluHWiKk6FxRPyUPxAAYH2Vy1lNM4kzekd8oEARzFAWgeW3az2xejEWL
# NN4eKGxDJ8WDl/FQUSntbjZ80FU3i54tpx5F/0Kr15zW/mJAxZMVBrTE2oi0fcI8
# VMbtoRAmaaslNXdCG1+lqvP4FbrQ6IwSBXkZagHLhFU9HCrG/syTRLLhAezu/3Lr
# 00GrJzPQFnCEH1Y58678IgmfORBPC1JKkYaEt2OdDh4GmO0/5cHelAK2/gTlQJIN
# qDr6JfwyYHXSd+V08X1JUPvB4ILfJdmL+66Gp3CSBXG6IwXMZUXBhtCyIaehr0Xk
# BoDIGMUG1dUtwq1qmcwbdUfcSYCn+OwncVUXf53VJUNOaMWMts0VlRYxe5nK+At+
# DI96HAlXHAL5SlfYxJ7La54i71McVWRP66bW+yERNpbJCjyCYG2j+bdpxo/1Cy4u
# PcU3AWVPGrbn5PhDBf3Froguzzhk++ami+r3Qrx5bIbY3TVzgiFI7Gq3zWcxggU2
# MIIFMgIBATBaMEMxFDASBgoJkiaJk/IsZAEZFgRjb3JwMRQwEgYKCZImiZPyLGQB
# GRYEYWNtZTEVMBMGA1UEAxMMYWNtZS1EQzAxLUNBAhN+AAAAXDZdcRsjYYagAAAA
# AABcMA0GCWCGSAFlAwQCAQUAoIGEMBgGCisGAQQBgjcCAQwxCjAIoAKAAKECgAAw
# GQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEOMAwGCisG
# AQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIGj4Za7gCOBQ3117lxCuLJ6AX60OYaBy
# eWsF2NX7db0JMA0GCSqGSIb3DQEBAQUABIIBAAcC+Dtk/2zRUt/3zr+t2KV1/uC2
# iNKTZoYdDcu2puRuO+/2EHIIe/MFk5UYhlWg43C0vdlb/tmLuzxnfWkid7eJ8Tm1
# TlXVczww7yUqtoDT6pQzsb12fYKXtvUkDHdCvkQzn+wonprYKOp3pslMmjHwdvH9
# zYV3mjJ9w42iykPjg4/igETZJc/7ve0cieoNuFkz9s3zfxZrC4UbjilLxbBY2MhQ
# qEwZE7OJeuYnxyWYGtJXt+pGVkvOinFQD4+hjRwgW33Q0ZbGP/qm78zrlqu4j94s
# EF0iR7Zjcac33XHPjNLT48sflYq58zjWBYgwD94rTfP7GWj9vpkPywvfQYehggMm
# MIIDIgYJKoZIhvcNAQkGMYIDEzCCAw8CAQEwfTBpMQswCQYDVQQGEwJVUzEXMBUG
# A1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMTOERpZ2lDZXJ0IFRydXN0ZWQg
# RzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2IDIwMjUgQ0ExAhAKgO8YS43x
# BYLRxHanlXRoMA0GCWCGSAFlAwQCAQUAoGkwGAYJKoZIhvcNAQkDMQsGCSqGSIb3
# DQEHATAcBgkqhkiG9w0BCQUxDxcNMjYwMzI2MDY0NjM0WjAvBgkqhkiG9w0BCQQx
# IgQghlMfYULPsmRm3gnKwMZr3fl/10IWE2JTu/+zJ0hc7J0wDQYJKoZIhvcNAQEB
# BQAEggIAUadW3NXg162gB9N0Y26Xqj2oQ0PFjg62rqzyTSM0fvvFj2j58MeYW05Z
# Q4oL6U83dF7EHp1CjtwLFgmsKGnIdfeDCOugeg6wtGwyzhVsv8TfLTrBjSTE9ggX
# jdcBU5q6gQCJ4uXYAVT99pzUlFDubsqXGJ/Wcw4hpbPLSTW1Pp7KyJpLjMO4FNom
# neaMBh0CzS0t35lXKImJW3C/SIFwAmvl9KlW6OaowmUn+OfvdfDzMH/Rfbe6n5ba
# iMBJKcp4atLMesRlpiYDN0VmEwmlIwQz5Ifb2hBrBcBo64/dNf9w2ig0qtGqi3wa
# L+kIaF3KSZC+6qajt8z5iH6r7AByx3yN997mBcfbOkmniND+V/jIJe1c0zQUmjie
# dOISdOhApjln7dyaBrgnXIZlKJw8HCnADNniak9I7XbgfEQf9uRWuJKLbvfB2yM/
# JI873dgwNFEfHIxMtxea9UUaj5geLWCIdveIo/ujFQQ3pTgTBSVQGL2PlvIGVgqy
# SESPNlgpYWTcuP2o6tyI7xn1J4R1UFdFT/Re5Sf0oga6mGWs2xDYymLJ3efNo+5x
# sVK2rXvIBjbOjw3xLf5BjPqytJWa4vY+bN0RLHxzp3o2tEgBh4bJDzr7EaDKcuKI
# IwxRwyTSVyTVtlKgrE08Qsm0XpKZkE5Q4dfwARPeZ4vnpuNpruU=
# SIG # End signature block
