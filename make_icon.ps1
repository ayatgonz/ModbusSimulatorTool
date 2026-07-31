Add-Type -AssemblyName System.Drawing

$srcPath = "C:\Users\abrah\.gemini\antigravity\brain\7adc1ed4-b4fd-42f8-be90-d333cf9e0861\modbus_icon_1784850920102.jpg"
$icoPath = "C:\Users\abrah\.gemini\antigravity\scratch\modbus-tester\app.ico"

$img = [System.Drawing.Image]::FromFile($srcPath)

# Create multiple sizes for proper ICO
$sizes = @(16, 32, 48, 256)
$pngBytesList = @()

foreach ($size in $sizes) {
    $bmp = New-Object System.Drawing.Bitmap($img, $size, $size)
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $pngBytesList += ,($ms.ToArray())
    $ms.Dispose()
    $bmp.Dispose()
}
$img.Dispose()

# Write multi-size ICO file
$fs = [System.IO.File]::Create($icoPath)
$bw = New-Object System.IO.BinaryWriter($fs)

$count = $sizes.Count
# ICO Header
$bw.Write([UInt16]0)       # reserved
$bw.Write([UInt16]1)       # type = icon
$bw.Write([UInt16]$count)  # image count

# Calculate data offset: header(6) + entries(count * 16)
$dataOffset = 6 + ($count * 16)

# Write directory entries
for ($i = 0; $i -lt $count; $i++) {
    $size = $sizes[$i]
    $pngBytes = $pngBytesList[$i]
    
    $w = if ($size -ge 256) { 0 } else { $size }
    $h = if ($size -ge 256) { 0 } else { $size }
    
    $bw.Write([byte]$w)                    # width
    $bw.Write([byte]$h)                    # height
    $bw.Write([byte]0)                     # color palette
    $bw.Write([byte]0)                     # reserved
    $bw.Write([UInt16]1)                   # color planes
    $bw.Write([UInt16]32)                  # bits per pixel
    $bw.Write([UInt32]$pngBytes.Length)     # image data size
    $bw.Write([UInt32]$dataOffset)         # offset to image data
    
    $dataOffset += $pngBytes.Length
}

# Write image data
for ($i = 0; $i -lt $count; $i++) {
    $bw.Write($pngBytesList[$i])
}

$bw.Close()
$fs.Close()

Write-Host "Multi-size ICO created: $icoPath ($count sizes: $($sizes -join ', ')px)"
