function Show-Menu {
    Clear-Host
    Write-Host "===============================" -ForegroundColor Cyan
    Write-Host "   CyberArk PAM SaaS LAB Launcher" -ForegroundColor Cyan
    Write-Host "===============================" -ForegroundColor Cyan
    Write-Host
    Write-Host "1. Set Mobile/Cell and email for lab users"
    Write-Host "2. Set Region and Time Zone for all Servers"
    Write-Host "3. Launch RSAT"
    Write-Host "4. Exit"
    Write-Host
}

function Run-Menu {
    while ($true) {
        Show-Menu
        $choice = Read-Host "Enter your choice"

        switch ($choice) {
            "1" { & ".\Update-SMS-EMAIL\Update-SMS-Email.ps1"; Read-Host "Press Enter to continue" }
            "2" { & "C:\Scripts\CleanupTemp.ps1"; Read-Host "Press Enter to continue" }
            "3" { & "C:\Scripts\GenerateReport.ps1"; Read-Host "Press Enter to continue" }
            "4" { Write-Host "Exiting..." -ForegroundColor Yellow; return }  # Exits the function and menu
            default { Write-Host "Invalid choice"; Start-Sleep -Seconds 1 }
        }
    }
}

# Start the menu
Run-Menu