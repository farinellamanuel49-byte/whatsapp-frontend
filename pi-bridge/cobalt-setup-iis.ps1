# cobalt-setup.ps1 — eseguire su 82.223.13.114 (server IIS Windows)
# Installa Node.js + Cobalt + Caddy (HTTPS) come servizio.
# Eseguire in PowerShell come Amministratore.

$ErrorActionPreference = "Stop"
$COBALT_PORT = 9000
$DOMAIN = "82.223.13.114.sslip.io"
$CADDY_DIR = "C:\cobalt"
$COBALT_DIR = "C:\cobalt\app"

Write-Host "=== 1. Node.js ===" -ForegroundColor Cyan
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    winget install -e --id OpenJS.NodeJS.LTS --accept-package-agreements --accept-source-agreements
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
}
node --version

Write-Host "=== 2. Cobalt ===" -ForegroundColor Cyan
if (-not (Test-Path "$COBALT_DIR\api\package.json")) {
    git clone --depth 1 https://github.com/imputnet/cobalt.git $COBALT_DIR
}
Set-Location "$COBALT_DIR\api"
npm install --omit=dev

# api.json con la API key condivisa con l'app e l'IIS
@'
{
  "apiKeys": {
    "290f64f0a911460ea83fcd9668d2e93a0ab67030e44742998f42c69bbfac614e": {
      "enabledServices": ["youtube", "tiktok", "instagram", "facebook"]
    }
  },
  "audioFormat": "mp3",
  "audioBitrate": "320",
  "videoQuality": "720",
  "downloadMode": "auto",
  "listenAddress": "127.0.0.1",
  "port": 9000,
  "downloadDir": "C:\\cobalt\\downloads",
  "logging": { "level": "info" },
  "services": {
    "youtube": { "enabled": true },
    "tiktok": { "enabled": true },
    "instagram": { "enabled": true },
    "facebook": { "enabled": true },
    "twitter": { "enabled": false },
    "bluesky": { "enabled": false },
    "lemmy": { "enabled": false },
    "pinterest": { "enabled": false },
    "soundcloud": { "enabled": false },
    "streamable": { "enabled": false },
    "xenforo": { "enabled": false }
  },
  "doh": { "resolvers": ["1.1.1.1", "8.8.8.8"], "domains": [] },
  "proxy": { "enabled": false },
  "remoteFileSizeLimit": 2,
  "ignoreFilesBiggerThan": 2
}
'@ | Out-File -Encoding utf8 "$COBALT_DIR\api\api.json"
New-Item -ItemType Directory -Force "$CADDY_DIR\downloads" | Out-Null

Write-Host "=== 3. Caddy (HTTPS) ===" -ForegroundColor Cyan
# Caddy Windows: binding solo 443 (la 80 e' di IIS) — il certificato
# arriva via TLS-ALPN-01 su 443, non serve la 80.
$env:COBALT_DOMAIN = $DOMAIN
@"
https://$DOMAIN {
    reverse_proxy 127.0.0.1:$COBALT_PORT
}
"@ | Out-File -Encoding utf8 "$CADDY_DIR\Caddyfile"

if (-not (Test-Path "$CADDY_DIR\caddy.exe")) {
    Invoke-WebRequest -Uri "https://caddyserver.com/api/download?os=windows&arch=amd64" -OutFile "$CADDY_DIR\caddy.zip"
    Expand-Archive "$CADDY_DIR\caddy.zip" -DestinationPath $CADDY_DIR -Force
}

Write-Host "=== 4. Servizi Windows ===" -ForegroundColor Cyan
# Cobalt come servizio (nssm)
if (-not (Get-Command nssm -ErrorAction SilentlyContinue)) {
    Invoke-WebRequest -Uri "https://nssm.cc/release/nssm-2.24.zip" -OutFile "$env:TEMP\nssm.zip"
    Expand-Archive "$env:TEMP\nssm.zip" -DestinationPath "$env:TEMP\nssm" -Force
    Copy-Item "$env:TEMP\nssm\nssm-2.24\win64\nssm.exe" "C:\Windows\"
}

$env:API_URL = "https://$DOMAIN"
nssm install Cobalt "cmd.exe" "/c npm start"
nssm set Cobalt AppDirectory "$COBALT_DIR\api"
nssm set Cobalt AppEnvironmentExtra "API_URL=https://$DOMAIN" "PORT=9000"
nssm set Cobalt Start SERVICE_AUTO_START
nssm start Cobalt

nssm install CaddyProxy "C:\cobalt\caddy.exe" "run --config C:\cobalt\Caddyfile"
nssm set CaddyProxy AppDirectory $CADDY_DIR
nssm set CaddyProxy Start SERVICE_AUTO_START
nssm start CaddyProxy

Write-Host "=== 5. Test ===" -ForegroundColor Cyan
Start-Sleep -Seconds 8
try {
    $r = Invoke-RestMethod -Uri "https://$DOMAIN/" -Method Get -TimeoutSec 15
    Write-Host "Cobalt HTTPS OK: $DOMAIN" -ForegroundColor Green
} catch {
    Write-Host "Test fallito: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "Controlla: netstat -ano | findstr :443 e :9000"
}
Write-Host "Fatto. API key Cobalt: 290f64f0... (gia' in api.json)"
