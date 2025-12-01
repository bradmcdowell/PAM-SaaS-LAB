# Ensure the Active Directory module is imported
Import-Module ActiveDirectory

# This function verifies the admin credentials.
function Get-VerifiedAdminCredential {
    [CmdletBinding()]
    param(
        [string] $PromptMessage = "Domain Admin Credentials"
    )
    # Prompt for credentials
    Write-Host "Please enter credentials to continue."
    $cred = Get-Credential -Message $PromptMessage

    # Validate credentials
    Add-Type -AssemblyName System.DirectoryServices.AccountManagement
    $context = New-Object System.DirectoryServices.AccountManagement.PrincipalContext([System.DirectoryServices.AccountManagement.ContextType]::Domain, $env:USERDNSDOMAIN)
    $username = $cred.UserName
    # Remove domain part if present (Domain\User)
    if($username -like "*\*") {
        $username = $username.Split("\")[1]
    }
    $password = $cred.GetNetworkCredential().Password
    $isValid = $context.ValidateCredentials($username, $password)
    $context.Dispose()  # free the PrincipalContext resource
    if(-not $isValid) {
        Stop-Transcript
        throw "Invalid admin credentials! Exiting."
    }
    Write-Host "Credentials validated. Continuing..."
    return $cred
}

# 3 & 4. Prompt and validate Domain Admin credentials
$AdminCred = Get-VerifiedAdminCredential -PromptMessage "Enter Domain Admin level credentials. For example,  acme\mike_da"
 #existingUser = Get-ADUser -Filter "SamAccountName -eq '$user'" -Credential $AdminCred -ErrorAction SilentlyContinue

# Prompt user for a mobile/cell number
$StudentMobile = Read-Host "Enter your Mobile/Cell number (e.g., +614xxxxxxxx)"

# Prompt user for an email address
$StudentEmail = Read-Host "Enter your email address (e.g., student@example.com)"

# Define users and assign the mobile number.
$users = @(
    @{ Name = "mike"},
    @{ Name = "carlos"},
    @{ Name = "cindy"},
    @{ Name = "tom"},
    @{ Name = "john"},
    @{ Name = "pamela"},
    @{ Name = "robert"},
    @{ Name = "paul"}
)

# Update mobile number for each user
foreach ($user in $users) {
    try {
        Set-ADUser -Identity $user.Name -MobilePhone $StudentMobile -Credential $AdminCred -ErrorAction SilentlyContinue
        Write-Host "Updated mobile number for $($user.Name) to $StudentMobile"
        Set-ADUser -Identity $user.Name -EmailAddress $StudentEmail -Credential $AdminCred -ErrorAction SilentlyContinue
        Write-Host "Updated email address for $($user.Name) to $StudentEmail"
    } catch {
        Write-Warning "Failed to update mobile number or email for $($user.Name): $_"
    }
}