# Sauvegarde temporaire des tâches avant désactivation (sécurité)
$backupFile = "$env:USERPROFILE\Desktop\Sasha\TaskList_ASUS_$(Get-Date -Format 'yyyyMMdd_HHmm').csv"
Get-ScheduledTask | Where-Object { $_.TaskName -match 'ASUS|Armoury|ROG|Aura|GameFirst|LiveDash' -or $_.TaskPath -match 'ASUS|Armoury|ROG' } |
    Export-Csv -Path $backupFile -NoTypeInformation -Encoding UTF8
Write-Host "Liste de référence sauvegardée dans : $backupFile" -ForegroundColor Cyan
Write-Host ""

# Récupère toutes les tâches ASUS / ROG / Armoury
$asusTasks = Get-ScheduledTask | Where-Object { $_.TaskName -match 'ASUS|Armoury|ROG|Aura|GameFirst|LiveDash' -or $_.TaskPath -match 'ASUS|Armoury|ROG' }

if (-not $asusTasks) {
    Write-Host "Aucune tâche ASUS trouvée. Rien à faire." -ForegroundColor Green
    exit 0
}

Write-Host "Tâches ASUS détectées ($($asusTasks.Count)) :" -ForegroundColor Yellow
$asusTasks | ForEach-Object {
    Write-Host "  - $($_.TaskPath)$($_.TaskName) [$($_.State)]"
}

Write-Host ""
$confirm = Read-Host "Appuyez sur 'O' pour désactiver TOUTES ces tâches, ou 'N' pour annuler"
if ($confirm -ne 'O') {
    Write-Host "Opération annulée." -ForegroundColor Red
    exit 0
}

# Désactivation
$asusTasks | ForEach-Object {
    try {
        Disable-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -ErrorAction Stop
        Write-Host "✅ Désactivée : $($_.TaskPath)$($_.TaskName)" -ForegroundColor Green
    } catch {
        Write-Host "⚠️  Échec pour $($_.TaskPath)$($_.TaskName) : $_" -ForegroundColor DarkYellow
    }
}

Write-Host ""
Write-Host "Opération terminée. Un redémarrage est recommandé." -ForegroundColor Cyan
