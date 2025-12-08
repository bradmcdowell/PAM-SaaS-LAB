Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$tzRegionLogonScript = "\\dc01\Distribution\tzRegion\tz-region-logon.ps1"

# --- Region definitions ---
$regions = @{
    "Australia (en-AU)" = @{
        SystemLocale = "en-AU"
        LanguageList = "en-AU"
        Culture = "en-AU"
        GeoId = 12
    }
    "United States (en-US)" = @{
        SystemLocale = "en-US"
        LanguageList = "en-US"
        Culture = "en-US"
        GeoId = 244
    }
    "United Kingdom (en-GB)" = @{
        SystemLocale = "en-GB"
        LanguageList = "en-GB"
        Culture = "en-GB"
        GeoId = 242
    }
}

# --- Timezone list with friendly display ---
$tzMap = @{}
[System.TimeZoneInfo]::GetSystemTimeZones() | ForEach-Object {
    $tzMap[$_.DisplayName] = $_.Id
}
$tzDisplayNames = $tzMap.Keys | Sort-Object

# --- Build GUI ---
$form = New-Object System.Windows.Forms.Form
$form.Text = "Select Region and Timezone"
$form.Size = New-Object System.Drawing.Size(480,310)
$form.StartPosition = "CenterScreen"

# Region label & dropdown
$regionLabel = New-Object System.Windows.Forms.Label
$regionLabel.Text = "Select Region:"
$regionLabel.Location = New-Object System.Drawing.Point(20,20)
$regionLabel.AutoSize = $true

$regionDropdown = New-Object System.Windows.Forms.ComboBox
$regionDropdown.Location = New-Object System.Drawing.Point(20,45)
$regionDropdown.Size = New-Object System.Drawing.Size(390,30)
$regionDropdown.DropDownStyle = 'DropDownList'
#$regionDropdown.Items.AddRange($regions.Keys)
foreach ($regionName in $regions.Keys) {
    $regionDropdown.Items.Add($regionName)
}
$regionDropdown.SelectedItem = "Australia (en-AU)"  # Optional default

# Timezone label & dropdown
$timezoneLabel = New-Object System.Windows.Forms.Label
$timezoneLabel.Text = "Select Timezone:"
$timezoneLabel.Location = New-Object System.Drawing.Point(20,90)
$timezoneLabel.AutoSize = $true

$timezoneDropdown = New-Object System.Windows.Forms.ComboBox
$timezoneDropdown.Location = New-Object System.Drawing.Point(20,115)
$timezoneDropdown.Size = New-Object System.Drawing.Size(420,30)
$timezoneDropdown.DropDownStyle = 'DropDownList'
$timezoneDropdown.Items.AddRange($tzDisplayNames)
$timezoneDropdown.SelectedItem = "(UTC+10:00) Canberra, Melbourne, Sydney"

# Apply to others label & dropdown
$remoteLabel = New-Object System.Windows.Forms.Label
$remoteLabel.Text = "Update logon script at $tzRegionLogonScript ?"
$remoteLabel.Location = New-Object System.Drawing.Point(20,160)
$remoteLabel.AutoSize = $true

$remoteDropdown = New-Object System.Windows.Forms.ComboBox
$remoteDropdown.Location = New-Object System.Drawing.Point(20,185)
$remoteDropdown.Size = New-Object System.Drawing.Size(420,30)
$remoteDropdown.DropDownStyle = 'DropDownList'
$remoteDropdown.Items.AddRange(@("No", "Yes"))
$remoteDropdown.SelectedItem = "Yes"

# Apply button
$applyButton = New-Object System.Windows.Forms.Button
$applyButton.Text = "Apply"
$applyButton.Location = New-Object System.Drawing.Point(180,230)
$applyButton.Size = New-Object System.Drawing.Size(100,30)

$applyButton.Add_Click({
    $selectedRegion = $regions[$regionDropdown.SelectedItem]
    $selectedTimezoneDisplay = $timezoneDropdown.SelectedItem
    $applyToOthers = $remoteDropdown.SelectedItem -eq "Yes"

    if (-not $selectedRegion -or -not $selectedTimezoneDisplay) {
        [System.Windows.Forms.MessageBox]::Show("Please select both region and timezone.","Missing Selection",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }

    $selectedTimezoneId = $tzMap[$selectedTimezoneDisplay]

    try {
        Set-WinSystemLocale -SystemLocale $selectedRegion.SystemLocale
        Set-WinUserLanguageList -LanguageList @($selectedRegion.LanguageList) -Force
        Set-Culture -CultureInfo $selectedRegion.Culture
        Set-WinHomeLocation -GeoId $selectedRegion.GeoId
        Set-TimeZone -Id $selectedTimezoneId

        [System.Windows.Forms.MessageBox]::Show("Region and Timezone applied to local machine successfully.","Success",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)

        if ($applyToOthers) {
            [System.Windows.Forms.MessageBox]::Show("Updated logon script at $tzRegionLogonScript .","Success",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)

            
            $ScriptRunTime = Get-Date
$tzRegionlogonScriptContent = @"
# This logon script was updated by the Update-TimeZone-Region script at $ScriptRunTime
Set-WinSystemLocale -SystemLocale $($selectedRegion.SystemLocale)
Set-WinUserLanguageList -LanguageList @('$($selectedRegion.LanguageList)') -Force
Set-Culture -CultureInfo $($selectedRegion.Culture)
Set-WinHomeLocation -GeoId $($selectedRegion.GeoId)
Set-TimeZone -Id "$selectedTimezoneId"
"@

Set-Content -Path $tzRegionLogonScript -Value $tzRegionlogonScriptContent -Force

        } else {
            [System.Windows.Forms.MessageBox]::Show("Apply to others Not Selected.","Success",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)
        }

        $form.Close()
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Error applying settings:`n$_","Error",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error)
    }
})


# Add controls
$form.Controls.Add($regionLabel)
$form.Controls.Add($regionDropdown)
$form.Controls.Add($timezoneLabel)
$form.Controls.Add($timezoneDropdown)
$form.Controls.Add($remoteLabel)
$form.Controls.Add($remoteDropdown)
$form.Controls.Add($applyButton)

# Show GUI
$form.Topmost = $true
$form.Add_Shown({$form.Activate()})
[void]$form.ShowDialog()