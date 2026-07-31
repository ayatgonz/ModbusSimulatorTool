# Modbus TCP/IP Tester Backend Engine in PowerShell (.NET Native)
# Runs HTTP Server on http://localhost:3000 and native Modbus TCP Client & Server

Add-Type -AssemblyName System.Net
Add-Type -AssemblyName System.Web

$script:AppPort = 8080
$script:ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$script:PublicDir = Join-Path $script:ScriptDir "public"

# Modbus Server State
$script:ServerRunning = $false
$script:ServerPort = 10502
$script:ServerUnitId = 1
$script:TcpListener = $null

# Registers (Address [int] => Value)
$script:HoldingRegisters = [hashtable]::Synchronized(@{})
$script:InputRegisters   = [hashtable]::Synchronized(@{})
$script:Coils            = [hashtable]::Synchronized(@{})
$script:DiscreteInputs   = [hashtable]::Synchronized(@{})

# Pre-fill sample registers
for ($i = 0; $i -lt 50; $i++) {
    $script:HoldingRegisters[$i] = ($i + 1) * 100
    $script:InputRegisters[$i]   = ($i + 1) * 50
    $script:Coils[$i]            = ($i % 2 -eq 1)
    $script:DiscreteInputs[$i]   = ($i % 3 -eq 0)
}

# Traffic Log Array
$script:TrafficLogs = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())

function Log-Traffic {
    param($dir, $source, $hex, $txId, $unitId, $fc, $length)
    $entry = @{
        dir           = $dir
        source        = $source
        hex           = $hex
        transactionId = $txId
        unitId        = $unitId
        functionCode  = $fc
        length        = $length
        timestamp     = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    }
    [void]$script:TrafficLogs.Add($entry)
    if ($script:TrafficLogs.Count -gt 200) {
        $script:TrafficLogs.RemoveAt(0)
    }
}

# ============================================================================
# MODBUS TCP SERVER IMPLEMENTATION
# ============================================================================
function Start-ModbusServer {
    param([int]$port = 10502, [int]$unitId = 1)

    if ($script:ServerRunning) { Stop-ModbusServer }

    $script:ServerPort = $port
    $script:ServerUnitId = $unitId

    try {
        $script:TcpListener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $port)
        $script:TcpListener.Start()
        $script:ServerRunning = $true
        Write-Host "Modbus TCP Server listening on port $port (Unit ID: $unitId)..." -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "Failed to start Modbus Server: $_" -ForegroundColor Red
        $script:ServerRunning = $false
        return $false
    }
}

function Stop-ModbusServer {
    $script:ServerRunning = $false
    if ($script:TcpListener) {
        $script:TcpListener.Stop()
        $script:TcpListener = $null
    }
    Write-Host "Modbus TCP Server stopped." -ForegroundColor Yellow
}

function Check-And-Handle-Server-Connections {
    if (-not $script:ServerRunning -or -not $script:TcpListener) { return }

    while ($script:TcpListener.Pending()) {
        $client = $script:TcpListener.AcceptTcpClient()
        Handle-ModbusClientConnection $client
    }
}

function Handle-ModbusClientConnection {
    param([System.Net.Sockets.TcpClient]$client)

    $stream = $client.GetStream()
    $stream.ReadTimeout = 2000
    $buffer = New-Object byte[] 512
    $clientRemote = $client.Client.RemoteEndPoint.ToString()

    # Wait for data to arrive (up to 2 seconds with polling)
    $waited = 0
    while (-not $stream.DataAvailable -and $waited -lt 100) {
        [System.Threading.Thread]::Sleep(20)
        $waited++
    }

    if (-not $stream.DataAvailable) {
        $client.Close()
        return
    }

    try {
        $bytesRead = $stream.Read($buffer, 0, $buffer.Length)
    } catch {
        $client.Close()
        return
    }

    if ($bytesRead -ge 7) {
        # Parse MBAP Header
        $txId = ([uint16]$buffer[0] -shl 8) -bor [uint16]$buffer[1]
        $protoId = ([uint16]$buffer[2] -shl 8) -bor [uint16]$buffer[3]
        $len = ([uint16]$buffer[4] -shl 8) -bor [uint16]$buffer[5]
        $unitId = [int]$buffer[6]

        if ($protoId -eq 0) {
            $pduLen = $bytesRead - 7
            $pdu = New-Object byte[] $pduLen
            [Array]::Copy($buffer, 7, $pdu, 0, $pduLen)
            $fc = [int]$pdu[0]

            $reqHex = [BitConverter]::ToString($buffer, 0, $bytesRead).Replace("-", "")
            Log-Traffic "RX" "Client ($clientRemote)" $reqHex $txId $unitId $fc $bytesRead

            # Process PDU
            $respPdu = Process-ModbusPdu $pdu

            # Construct Response MBAP
            $respLen = $respPdu.Length + 1
            $respFrame = New-Object byte[] (7 + $respPdu.Length)
            $respFrame[0] = [byte]($txId -shr 8)
            $respFrame[1] = [byte]($txId -band 0xFF)
            $respFrame[2] = 0
            $respFrame[3] = 0
            $respFrame[4] = [byte]($respLen -shr 8)
            $respFrame[5] = [byte]($respLen -band 0xFF)
            $respFrame[6] = [byte]$unitId
            [Array]::Copy($respPdu, 0, $respFrame, 7, $respPdu.Length)

            $stream.Write($respFrame, 0, $respFrame.Length)
            $stream.Flush()

            $respHex = [BitConverter]::ToString($respFrame).Replace("-", "")
            Log-Traffic "TX" "Server (Port $script:ServerPort)" $respHex $txId $unitId $fc $respFrame.Length
        }
    }
    $client.Close()
}

function Process-ModbusPdu {
    param([byte[]]$pdu)

    $fc = [int]$pdu[0]
    switch ($fc) {
        1 { return Read-BitsPdu $pdu $script:Coils }
        2 { return Read-BitsPdu $pdu $script:DiscreteInputs }
        3 { return Read-RegistersPdu $pdu $script:HoldingRegisters }
        4 { return Read-RegistersPdu $pdu $script:InputRegisters }
        5 {
            $addr = ([uint16]$pdu[1] -shl 8) -bor [uint16]$pdu[2]
            $valRaw = ([uint16]$pdu[3] -shl 8) -bor [uint16]$pdu[4]
            $script:Coils[$addr] = ($valRaw -eq 0xFF00)
            return $pdu[0..4]
        }
        6 {
            $addr = ([uint16]$pdu[1] -shl 8) -bor [uint16]$pdu[2]
            $val = ([uint16]$pdu[3] -shl 8) -bor [uint16]$pdu[4]
            $script:HoldingRegisters[$addr] = $val
            return $pdu[0..4]
        }
        15 {
            $addr = ([uint16]$pdu[1] -shl 8) -bor [uint16]$pdu[2]
            $qty = ([uint16]$pdu[3] -shl 8) -bor [uint16]$pdu[4]
            for ($i = 0; $i -lt $qty; $i++) {
                $byteIdx = 6 + [Math]::Floor($i / 8)
                $bitIdx = $i % 8
                $bitVal = ($pdu[$byteIdx] -shr $bitIdx) -band 1
                $script:Coils[$addr + $i] = ($bitVal -eq 1)
            }
            $resp = New-Object byte[] 5
            $resp[0] = 15
            $resp[1] = [byte]($addr -shr 8); $resp[2] = [byte]($addr -band 0xFF)
            $resp[3] = [byte]($qty -shr 8);  $resp[4] = [byte]($qty -band 0xFF)
            return $resp
        }
        16 {
            $addr = ([uint16]$pdu[1] -shl 8) -bor [uint16]$pdu[2]
            $qty = ([uint16]$pdu[3] -shl 8) -bor [uint16]$pdu[4]
            for ($i = 0; $i -lt $qty; $i++) {
                $val = ([uint16]$pdu[6 + $i*2] -shl 8) -bor [uint16]$pdu[7 + $i*2]
                $script:HoldingRegisters[$addr + $i] = $val
            }
            $resp = New-Object byte[] 5
            $resp[0] = 16
            $resp[1] = [byte]($addr -shr 8); $resp[2] = [byte]($addr -band 0xFF)
            $resp[3] = [byte]($qty -shr 8);  $resp[4] = [byte]($qty -band 0xFF)
            return $resp
        }
        default {
            return [byte[]]([byte]($fc -bor 0x80), 0x01) # Illegal Function
        }
    }
}

function Read-BitsPdu($pdu, $map) {
    $startAddr = ([uint16]$pdu[1] -shl 8) -bor [uint16]$pdu[2]
    $qty = ([uint16]$pdu[3] -shl 8) -bor [uint16]$pdu[4]
    $byteCount = [Math]::Ceiling($qty / 8)

    $resp = New-Object byte[] (2 + $byteCount)
    $resp[0] = $pdu[0]
    $resp[1] = [byte]$byteCount

    for ($i = 0; $i -lt $qty; $i++) {
        $val = if ($map.ContainsKey($startAddr + $i)) { [bool]$map[$startAddr + $i] } else { $false }
        if ($val) {
            $byteIdx = 2 + [Math]::Floor($i / 8)
            $bitIdx = $i % 8
            $resp[$byteIdx] = $resp[$byteIdx] -bor (1 -shl $bitIdx)
        }
    }
    return $resp
}

function Read-RegistersPdu($pdu, $map) {
    $startAddr = ([uint16]$pdu[1] -shl 8) -bor [uint16]$pdu[2]
    $qty = ([uint16]$pdu[3] -shl 8) -bor [uint16]$pdu[4]
    $byteCount = $qty * 2

    $resp = New-Object byte[] (2 + $byteCount)
    $resp[0] = $pdu[0]
    $resp[1] = [byte]$byteCount

    for ($i = 0; $i -lt $qty; $i++) {
        $val = if ($map.ContainsKey($startAddr + $i)) { [int]$map[$startAddr + $i] } else { 0 }
        $resp[2 + $i*2] = [byte]($val -shr 8)
        $resp[3 + $i*2] = [byte]($val -band 0xFF)
    }
    return $resp
}

# ============================================================================
# MODBUS TCP CLIENT IMPLEMENTATION
# ============================================================================
function Send-ModbusRequest {
    param(
        [string]$ip,
        [int]$port,
        [int]$unitId,
        [int]$functionCode,
        [int]$address,
        [int]$count,
        [array]$values,
        [int]$timeout = 3000
    )

    Check-And-Handle-Server-Connections

    $tcpClient = New-Object System.Net.Sockets.TcpClient
    $tcpClient.SendTimeout = $timeout
    $tcpClient.ReceiveTimeout = $timeout

    try {
        $connectTask = $tcpClient.ConnectAsync($ip, $port)
        if (-not $connectTask.Wait($timeout)) {
            throw "Connection to $ip`:$port timed out."
        }

        $stream = $tcpClient.GetStream()
        $txId = Get-Random -Minimum 100 -Maximum 65000

        # Build PDU
        $pdu = $null
        switch ($functionCode) {
            1 { $pdu = [byte[]]($functionCode, ($address -shr 8), ($address -band 0xFF), ($count -shr 8), ($count -band 0xFF)) }
            2 { $pdu = [byte[]]($functionCode, ($address -shr 8), ($address -band 0xFF), ($count -shr 8), ($count -band 0xFF)) }
            3 { $pdu = [byte[]]($functionCode, ($address -shr 8), ($address -band 0xFF), ($count -shr 8), ($count -band 0xFF)) }
            4 { $pdu = [byte[]]($functionCode, ($address -shr 8), ($address -band 0xFF), ($count -shr 8), ($count -band 0xFF)) }
            5 {
                $valRaw = if ($values[0]) { 0xFF00 } else { 0x0000 }
                $pdu = [byte[]](5, ($address -shr 8), ($address -band 0xFF), ($valRaw -shr 8), ($valRaw -band 0xFF))
            }
            6 {
                $valRaw = [uint16]$values[0]
                $pdu = [byte[]](6, ($address -shr 8), ($address -band 0xFF), ($valRaw -shr 8), ($valRaw -band 0xFF))
            }
            15 {
                $qty = $values.Length
                $byteCount = [Math]::Ceiling($qty / 8)
                $pdu = New-Object byte[] (6 + $byteCount)
                $pdu[0] = 15; $pdu[1] = [byte]($address -shr 8); $pdu[2] = [byte]($address -band 0xFF)
                $pdu[3] = [byte]($qty -shr 8); $pdu[4] = [byte]($qty -band 0xFF); $pdu[5] = [byte]$byteCount
                for ($i = 0; $i -lt $qty; $i++) {
                    if ($values[$i]) {
                        $bIdx = 6 + [Math]::Floor($i / 8)
                        $bitIdx = $i % 8
                        $pdu[$bIdx] = $pdu[$bIdx] -bor (1 -shl $bitIdx)
                    }
                }
            }
            16 {
                $qty = $values.Length
                $pdu = New-Object byte[] (6 + $qty * 2)
                $pdu[0] = 16; $pdu[1] = [byte]($address -shr 8); $pdu[2] = [byte]($address -band 0xFF)
                $pdu[3] = [byte]($qty -shr 8); $pdu[4] = [byte]($qty -band 0xFF); $pdu[5] = [byte]($qty * 2)
                for ($i = 0; $i -lt $qty; $i++) {
                    $v = [uint16]$values[$i]
                    $pdu[6 + $i*2] = [byte]($v -shr 8)
                    $pdu[7 + $i*2] = [byte]($v -band 0xFF)
                }
            }
        }

        # Build MBAP Header
        $len = $pdu.Length + 1
        $mbap = [byte[]](
            ($txId -shr 8), ($txId -band 0xFF),
            0, 0,
            ($len -shr 8), ($len -band 0xFF),
            [byte]$unitId
        )

        $fullReq = New-Object byte[] (7 + $pdu.Length)
        [Array]::Copy($mbap, 0, $fullReq, 0, 7)
        [Array]::Copy($pdu, 0, $fullReq, 7, $pdu.Length)

        $reqHex = [BitConverter]::ToString($fullReq).Replace("-", "")
        Log-Traffic "TX" "Client -> Target ($ip`:$port)" $reqHex $txId $unitId $functionCode $fullReq.Length

        $stream.Write($fullReq, 0, $fullReq.Length)
        $stream.Flush()

        # Give the loopback data time to arrive, then process server-side
        [System.Threading.Thread]::Sleep(50)
        Check-And-Handle-Server-Connections
        # Retry a few times in case data was still in flight
        for ($retry = 0; $retry -lt 10; $retry++) {
            [System.Threading.Thread]::Sleep(30)
            Check-And-Handle-Server-Connections
        }

        # Read Response with timeout
        $stream.ReadTimeout = 3000
        $respBuf = New-Object byte[] 512
        $readCount = $stream.Read($respBuf, 0, $respBuf.Length)
        $tcpClient.Close()

        if ($readCount -lt 7) { throw "Response frame invalid (< 7 bytes MBAP)." }

        $respHex = [BitConverter]::ToString($respBuf, 0, $readCount).Replace("-", "")
        $respPdu = New-Object byte[] ($readCount - 7)
        [Array]::Copy($respBuf, 7, $respPdu, 0, $respPdu.Length)
        $respFc = [int]$respPdu[0]

        Log-Traffic "RX" "Target ($ip`:$port) -> Client" $respHex $txId $unitId $respFc $readCount

        if (($respFc -band 0x80) -ne 0) {
            $exc = $respPdu[1]
            throw "Modbus Exception Code 0x$($exc.ToString('X2'))"
        }

        $parsedData = @()
        if ($respFc -eq 1 -or $respFc -eq 2) {
            $qty = $count
            for ($i = 0; $i -lt $qty; $i++) {
                $bIdx = 2 + [Math]::Floor($i / 8)
                $bitIdx = $i % 8
                $val = (($respPdu[$bIdx] -shr $bitIdx) -band 1) -eq 1
                $parsedData += $val
            }
        } elseif ($respFc -eq 3 -or $respFc -eq 4) {
            $byteCount = $respPdu[1]
            $qty = $byteCount / 2
            for ($i = 0; $i -lt $qty; $i++) {
                $val = ([uint16]$respPdu[2 + $i*2] -shl 8) -bor [uint16]$respPdu[3 + $i*2]
                $parsedData += $val
            }
        } else {
            $parsedData = @("Success")
        }

        return @{
          success = $true
          result  = @{
            functionCode = $respFc
            address      = $address
            data         = $parsedData
            rawHex       = $respHex
          }
        }
    }
    catch {
        if ($tcpClient) { $tcpClient.Close() }
        return @{ success = $false; error = $_.Exception.Message }
    }
}

# ============================================================================
# HTTP API SERVER & STATIC FILE HOST
# ============================================================================
# Kill any leftover listener on our port
try {
    $existingListener = Get-NetTCPConnection -LocalPort $script:AppPort -ErrorAction SilentlyContinue |
        Where-Object { $_.State -eq 'Listen' -and $_.OwningProcess -ne 4 } |
        Select-Object -ExpandProperty OwningProcess -Unique
    if ($existingListener) {
        $existingListener | ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 1
    }
} catch {}

$httpListener = $null
$maxRetries = 5
for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
    try {
        $httpListener = [System.Net.HttpListener]::new()
        $httpListener.Prefixes.Add("http://localhost:$($script:AppPort)/")
        $httpListener.Start()
        break
    } catch {
        if ($httpListener) { try { $httpListener.Close() } catch {} }
        if ($attempt -eq $maxRetries) { throw }
        Write-Host "Port $($script:AppPort) busy, retrying in 3s ($attempt/$maxRetries)..." -ForegroundColor Yellow
        Start-Sleep -Seconds 3
    }
}

Write-Host "========================================================" -ForegroundColor Cyan
Write-Host " Modbus TCP/IP Tester Running at http://localhost:$($script:AppPort)" -ForegroundColor Green
Write-Host "========================================================" -ForegroundColor Cyan

while ($httpListener.IsListening) {
    Check-And-Handle-Server-Connections

    $context = $httpListener.GetContext()
    $request = $context.Request
    $response = $context.Response

    $path = $request.Url.AbsolutePath
    $method = $request.HttpMethod

    # Enable CORS
    $response.AddHeader("Access-Control-Allow-Origin", "*")
    $response.AddHeader("Access-Control-Allow-Headers", "Content-Type")

    try {
        if ($path.StartsWith("/api/")) {
            $response.ContentType = "application/json"
            $reader = New-Object System.IO.StreamReader($request.InputStream)
            $bodyJson = $reader.ReadToEnd()
            $body = if ($bodyJson) { $bodyJson | ConvertFrom-Json } else { $null }

            $resObj = $null

            if ($path -eq "/api/server/state" -and $method -eq "GET") {
                # Format registers cleanly as array of objects [{ address: N, value: V }, ...]
                $formatHash = {
                    param($hash)
                    $list = New-Object System.Collections.ArrayList
                    foreach ($k in ($hash.Keys | Sort-Object)) {
                        [void]$list.Add(@{ address = [int]$k; value = $hash[$k] })
                    }
                    return $list
                }

                $resObj = @{
                    running   = $script:ServerRunning
                    port      = $script:ServerPort
                    unitId    = $script:ServerUnitId
                    registers = @{
                        holdingRegisters = & $formatHash $script:HoldingRegisters
                        inputRegisters   = & $formatHash $script:InputRegisters
                        coils            = & $formatHash $script:Coils
                        discreteInputs   = & $formatHash $script:DiscreteInputs
                    }
                }
            }
            elseif ($path -eq "/api/server/toggle" -and $method -eq "POST") {
                if ($body.action -eq "start") {
                    $p = if ($body.port) { [int]($body.port) } else { 10502 }
                    $u = if ($body.unitId) { [int]($body.unitId) } else { 1 }
                    Start-ModbusServer $p $u
                } else {
                    Stop-ModbusServer
                }
                $resObj = @{ success = $true; running = $script:ServerRunning }
            }
            elseif ($path -eq "/api/server/register" -and $method -eq "POST") {
                $rawAddr = [int]($body.address)
                $type = $body.type
                $val = $body.value

                # Support 40001+ / 30001+ / 10001+ / 1+ modbus addresses or zero-based offsets
                $addr = $rawAddr
                if ($type -eq "holding" -and $rawAddr -ge 40001) { $addr = $rawAddr - 40001 }
                elseif ($type -eq "input" -and $rawAddr -ge 30001) { $addr = $rawAddr - 30001 }
                elseif ($type -eq "discrete" -and $rawAddr -ge 10001) { $addr = $rawAddr - 10001 }
                elseif ($type -eq "coils" -and $rawAddr -ge 10001) { $addr = $rawAddr - 10001 }

                if ($type -eq "holding") { $script:HoldingRegisters[$addr] = [int]($val) }
                if ($type -eq "input")   { $script:InputRegisters[$addr]   = [int]($val) }
                if ($type -eq "coils")   { $script:Coils[$addr]            = [bool]($val -eq "true" -or $val -eq 1) }
                if ($type -eq "discrete"){ $script:DiscreteInputs[$addr]   = [bool]($val -eq "true" -or $val -eq 1) }
                
                $resObj = @{ success = $true; address = $addr; value = $val }
            }
            elseif ($path -eq "/api/client/request" -and $method -eq "POST") {
                $resObj = Send-ModbusRequest -ip $body.ip -port ([int]$body.port) -unitId ([int]$body.unitId) -functionCode ([int]$body.functionCode) -address ([int]$body.address) -count ([int]$body.count) -values $body.values
            }
            elseif ($path -eq "/api/client/scan" -and $method -eq "POST") {
                $fc = 3
                if ($body.registerType -eq "coils")    { $fc = 1 }
                if ($body.registerType -eq "discrete") { $fc = 2 }
                if ($body.registerType -eq "holding")  { $fc = 3 }
                if ($body.registerType -eq "input")    { $fc = 4 }

                $scanRes = Send-ModbusRequest -ip $body.ip -port ([int]$body.port) -unitId ([int]$body.unitId) -functionCode $fc -address ([int]$body.startAddress) -count ([int]$body.count) -values @()
                if ($scanRes.success) {
                    $resObj = @{ success = $true; startAddress = [int]($body.startAddress); count = [int]($body.count); data = $scanRes.result.data }
                } else {
                    $resObj = $scanRes
                }
            }

            $jsonBytes = [System.Text.Encoding]::UTF8.GetBytes(($resObj | ConvertTo-Json -Depth 5))
            $response.OutputStream.Write($jsonBytes, 0, $jsonBytes.Length)
        }
        else {
            # Serve Static Files
            $relPath = $path.TrimStart('/')
            if ([string]::IsNullOrEmpty($relPath)) { $relPath = "index.html" }
            $filePath = Join-Path $script:PublicDir $relPath

            if (Test-Path $filePath -PathType Leaf) {
                $ext = [System.IO.Path]::GetExtension($filePath)
                switch ($ext) {
                    ".html" { $response.ContentType = "text/html" }
                    ".css"  { $response.ContentType = "text/css" }
                    ".js"   { $response.ContentType = "text/javascript" }
                    default { $response.ContentType = "text/plain" }
                }
                $fileBytes = [System.IO.File]::ReadAllBytes($filePath)
                $response.OutputStream.Write($fileBytes, 0, $fileBytes.Length)
            } else {
                $response.StatusCode = 404
                $msg = [System.Text.Encoding]::UTF8.GetBytes("404 Not Found")
                $response.OutputStream.Write($msg, 0, $msg.Length)
            }
        }
    }
    catch {
        $response.StatusCode = 500
        $errBytes = [System.Text.Encoding]::UTF8.GetBytes("500 Internal Server Error: $_")
        $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
    }
    finally {
        $response.Close()
    }
}
