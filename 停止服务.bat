@echo off
rem Stop Whale Translator local service
powershell -NoProfile -Command "try { Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:7890/api/shutdown' -TimeoutSec 5 | Out-Null; Write-Host 'Service stopped.' } catch { Write-Host 'Service is not running.' }; Start-Sleep -Seconds 1"
