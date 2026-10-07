$alive = Test-NetConnection 127.0.0.1 -Port 4416 -WarningAction SilentlyContinue
if (-not $alive.TcpTestSucceeded) {
  Start-Process -FilePath "node" -ArgumentList "build/main.js" -WorkingDirectory "C:\inetpub\whatsapp-frontend\pot-provider\server" -WindowStyle Hidden -RedirectStandardOutput "C:\inetpub\whatsapp-frontend\pot-provider\server.log" -RedirectStandardError "C:\inetpub\whatsapp-frontend\pot-provider\server.err.log"
}
