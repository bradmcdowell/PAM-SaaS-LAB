# Prompt for credentials
$cred = Get-Credential

# Launch dsa.msc as the specified user
Start-Process "mmc.exe" -ArgumentList "C:\Scripts\RSAT.msc" -Credential $cred

