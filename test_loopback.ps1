$ErrorActionPreference = "Stop"
$base = "http://localhost:8080"

# 1. Start the Modbus TCP server
Write-Host "1. Starting Modbus TCP Server..." -ForegroundColor Cyan
$body = @{ action = "start"; port = 10502; unitId = 1 } | ConvertTo-Json
$res = Invoke-RestMethod -Uri "$base/api/server/toggle" -Method POST -ContentType "application/json" -Body $body
Write-Host "   Server running: $($res.running)" -ForegroundColor Green

Start-Sleep -Milliseconds 500

# 2. Set a custom register value
Write-Host "2. Setting holding register 0 = 12345..." -ForegroundColor Cyan
$body = @{ type = "holding"; address = 0; value = 12345 } | ConvertTo-Json
$res = Invoke-RestMethod -Uri "$base/api/server/register" -Method POST -ContentType "application/json" -Body $body
Write-Host "   Set result: address=$($res.address), value=$($res.value)" -ForegroundColor Green

# 3. Read register via client request (loopback)
Write-Host "3. Reading holding register 0 via Modbus TCP client..." -ForegroundColor Cyan
$body = @{
    ip = "127.0.0.1"
    port = 10502
    unitId = 1
    functionCode = 3
    address = 0
    count = 5
    values = @()
} | ConvertTo-Json
$res = Invoke-RestMethod -Uri "$base/api/client/request" -Method POST -ContentType "application/json" -Body $body

Write-Host "   Success: $($res.success)" -ForegroundColor Green
if ($res.success) {
    Write-Host "   Function Code: $($res.result.functionCode)" -ForegroundColor Green
    Write-Host "   Data: $($res.result.data -join ', ')" -ForegroundColor Green
    Write-Host "   Raw Hex: $($res.result.rawHex)" -ForegroundColor Green
    
    # Verify
    $firstVal = $res.result.data[0]
    if ($firstVal -eq 12345) {
        Write-Host "`n=== TEST PASSED: Register 0 = $firstVal (expected 12345) ===" -ForegroundColor Green
    } else {
        Write-Host "`n=== TEST FAILED: Register 0 = $firstVal (expected 12345) ===" -ForegroundColor Red
    }
} else {
    Write-Host "   ERROR: $($res.error)" -ForegroundColor Red
}
