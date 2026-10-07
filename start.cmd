@echo off
cd /d C:\inetpub\whatsapp-frontend
echo [%date% %time%] avvio >> C:\Windows\Temp\frontend.log
"C:\Program Files\nodejs\node.exe" server.js >> C:\Windows\Temp\frontend.log 2>&1
echo [%date% %time%] node terminato con exit code %ERRORLEVEL% >> C:\Windows\Temp\frontend.log
