# SBRadioEQ -- decode a Squeezebox Radio framebuffer dump to PNG.
#
# The panel is 240x320 portrait, RGB565 little-endian, stride 480, and the
# framebuffer is double-buffered (240x640 virtual). With pan=0,0 the visible
# frame is the first 153600 bytes. The UI drives it rotated 90 degrees CLOCKWISE
# to the 320x240 the applets are written against.
#
# Rotation is not cosmetic: decode without it and every screenshot is sideways,
# which reads as a rendering bug in the applet rather than in this script.

param(
  [string]$Raw = "$PSScriptRoot\..\dist\screen.raw",
  [string]$Out = "$PSScriptRoot\..\dist\screen.png",
  [ValidateSet('cw','ccw')][string]$Rotate = 'cw'
)
Add-Type -AssemblyName System.Drawing

$SW = 240   # panel width  (portrait)
$SH = 320   # panel height (portrait)

$bytes = [System.IO.File]::ReadAllBytes($Raw)
$need  = $SW * $SH * 2
if ($bytes.Length -lt $need) { throw "raw is $($bytes.Length) bytes, need at least $need" }

$px = New-Object 'int[]' ($SW * $SH)
for ($i = 0; $i -lt ($SW * $SH); $i++) {
    $v = [int]$bytes[$i*2] -bor ([int]$bytes[$i*2+1] -shl 8)
    $r = ((($v -shr 11) -band 0x1F) * 255) / 31
    $g = ((($v -shr 5)  -band 0x3F) * 255) / 63
    $b = (( $v          -band 0x1F) * 255) / 31
    $px[$i] = ([int]0xFF -shl 24) -bor ([int]$r -shl 16) -bor ([int]$g -shl 8) -bor [int]$b
}

$OW = $SH; $OH = $SW          # landscape 320x240
$outPx = New-Object 'int[]' ($OW * $OH)
for ($y = 0; $y -lt $SH; $y++) {
    for ($x = 0; $x -lt $SW; $x++) {
        if ($Rotate -eq 'cw') { $ox = $SH - 1 - $y; $oy = $x }
        else                  { $ox = $y;           $oy = $SW - 1 - $x }
        $outPx[$oy*$OW + $ox] = $px[$y*$SW + $x]
    }
}

$bmp  = New-Object System.Drawing.Bitmap($OW, $OH, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$rect = New-Object System.Drawing.Rectangle(0, 0, $OW, $OH)
$data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, $bmp.PixelFormat)
[System.Runtime.InteropServices.Marshal]::Copy($outPx, 0, $data.Scan0, $outPx.Length)
$bmp.UnlockBits($data)
$dir = Split-Path -Parent $Out
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Output "wrote $Out"
