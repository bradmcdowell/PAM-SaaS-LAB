# Prompt user for Light or Dark mode
Write-Host "Select Windows Theme Mode:"
Write-Host "1. Light"
Write-Host "2. Dark"

$choice = Read-Host "Enter your choice (1 or 2)"

switch ($choice) {
    "1" { $Mode = "Light" }
    "2" { $Mode = "Dark" }
    default {
        Write-Host "Invalid choice. Exiting."
        exit
    }
}

# Registry path for personalization settings
$registryPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"

# Apply the theme
switch ($Mode) {
    "Dark" {
        Set-ItemProperty -Path $registryPath -Name "AppsUseLightTheme" -Value 0
        Set-ItemProperty -Path $registryPath -Name "SystemUsesLightTheme" -Value 0
        Write-Host "Switched to Dark Mode"
    }
    "Light" {
        Set-ItemProperty -Path $registryPath -Name "AppsUseLightTheme" -Value 1
        Set-ItemProperty -Path $registryPath -Name "SystemUsesLightTheme" -Value 1
        Write-Host "Switched to Light Mode"
    }
}

# Refresh theme without logoff
RUNDLL32.EXE user32.dll,UpdatePerUserSystemParameters
