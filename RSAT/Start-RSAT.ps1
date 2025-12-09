# Prompt for credentials
$cred = Get-Credential

# Launch dsa.msc as the specified user
Start-Process "C:\Scripts\RSAT.msc" -Credential $cred
