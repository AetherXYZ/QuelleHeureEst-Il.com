# En admin — stoppe et désactive tous les services Acronis d'un coup
Get-Service | Where-Object { $_.Name -match 'Acronis' } | ForEach-Object {
    Stop-Service $_.Name -Force -ErrorAction SilentlyContinue
    Set-Service  $_.Name -StartupType Disabled
    Write-Host "Stoppé + désactivé : $($_.Name)"
}
# Killer les process Acronis aussi
Get-Process | Where-Object { $_.Name -match 'Acronis|aakore|mms' } | Stop-Process -Force