do {
    Clear-Host
    Write-Host "CyberArk PAM SaaS LAB Launcher"
    Write-Host "1. Set Mobile/Cell and email for lab users"
    Write-Host "2. Cleanup Temp"
    Write-Host "3. Generate Report"
    Write-Host "4. Exit"

    $choice = Read-Host "Enter your choice"

    switch ($choice) {
        "1" { & ".\Update-SMS-EMAIL\Update-SMS-Email.ps1"; Read-Host "Press Enter to continue" }
        "2" { & "C:\Scripts\CleanupTemp.ps1"; Read-Host "Press Enter to continue" }
        "3" { & "C:\Scripts\GenerateReport.ps1"; Read-Host "Press Enter to continue" }
        "4" { break }
        default { Write-Host "Invalid choice"; Start-Sleep -Seconds 1 }
    }
} while ($true)