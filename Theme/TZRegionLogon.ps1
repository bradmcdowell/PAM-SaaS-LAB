# Function to parse an INI file
function Get-IniContent {
    param (
        [Parameter(Mandatory)]
        [string]$Path
    )

    $ini = @{}
    $section = ""

    foreach ($line in Get-Content $Path) {
        $line = $line.Trim()
        if ($line -match "^\s*\[([^\]]+)\]") {
            # New section
            $section = $matches[1]
            $ini[$section] = @{}
        } elseif ($line -match "^\s*([^=]+)\s*=\s*(.*)$") {
            # Key=value
            $key = $matches[1].Trim()
            $value = $matches[2].Trim()
            if ($section -ne "") {
                $ini[$section][$key] = $value
            }
        }
    }

    return $ini
}

# Load the INI file
$configFile = "\\dc01\Distribution\TZRegion\config.ini"
$config = Get-IniContent -Path $configFile

# Access variables
$WinSystemLocale = $config["Settings"]["WinSystemLocale"]
$WinUserLanguageList = $config["Settings"]["WinUserLanguageList"]
$Culture = $config["Settings"]["Culture"]
$WinHomeLocation = $config["Settings"]["WinHomeLocation"]
$TimeZone = $config["Settings"]["TimeZone"]

# Write setttings to terminal
Write-Host "Setting WinSystemLocale to $WinSystemLocale"
Write-Host "Setting WinUserLanguageList to $WinUserLanguageList"
Write-Host "Setting Culture to $Culture"
Write-Host "Setting WinHomeLocation to $WinHomeLocation"
Write-Host "Setting TimeZone to $TimeZone"

# Set Time Zone and Region Settings
Set-WinSystemLocale -SystemLocale $WinSystemLocale
Set-WinUserLanguageList -LanguageList $WinUserLanguageList -Force
Set-Culture -CultureInfo $Culture
Set-WinHomeLocation -GeoId $WinHomeLocation
Set-TimeZone -Id "$TimeZone"