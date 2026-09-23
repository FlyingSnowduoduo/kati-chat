# Build app icon from a source image: white-background flood-fill -> transparent,
# crop to content, pad to square, then emit multi-size ICO (DIB entries) + 512 PNG.
Add-Type -AssemblyName System.Drawing

$srcPath = 'F:\aiworking\whale-translator\assets\icon-source.jpg'
$outPng  = 'F:\aiworking\whale-translator\assets\whale.png'
$outIco  = 'F:\aiworking\whale-translator\assets\whale.ico'

# --- 1. load as 32bpp ARGB ---
$src = [System.Drawing.Image]::FromFile($srcPath)
$W = $src.Width; $H = $src.Height
$bmp = New-Object System.Drawing.Bitmap($W, $H, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
$g.DrawImage($src, 0, 0, $W, $H)
$g.Dispose(); $src.Dispose()
Write-Host "source: ${W}x${H}"

# --- 2. flood fill near-white background from borders -> transparent ---
$isBg = New-Object 'bool[]' ($W * $H)
$stack = New-Object System.Collections.Generic.Stack[int]
for ($x = 0; $x -lt $W; $x++) { $stack.Push($x); $stack.Push(($H - 1) * $W + $x) }
for ($y = 0; $y -lt $H; $y++) { $stack.Push($y * $W); $stack.Push($y * $W + ($W - 1)) }
while ($stack.Count -gt 0) {
  $idx = $stack.Pop()
  if ($isBg[$idx]) { continue }
  $x = $idx % $W; $y = [int](($idx - $x) / $W)
  $c = $bmp.GetPixel($x, $y)
  if ($c.R -ge 232 -and $c.G -ge 232 -and $c.B -ge 232) {
    $isBg[$idx] = $true
    if ($x -gt 0) { $stack.Push($idx - 1) }
    if ($x -lt $W - 1) { $stack.Push($idx + 1) }
    if ($y -gt 0) { $stack.Push($idx - $W) }
    if ($y -lt $H - 1) { $stack.Push($idx + $W) }
  }
}

# --- 3. apply alpha + content bounding box ---
$minX = $W; $minY = $H; $maxX = -1; $maxY = -1; $bgCount = 0
for ($y = 0; $y -lt $H; $y++) {
  for ($x = 0; $x -lt $W; $x++) {
    if ($isBg[$y * $W + $x]) {
      $bmp.SetPixel($x, $y, [System.Drawing.Color]::FromArgb(0, 0, 0, 0))
      $bgCount++
    } else {
      if ($x -lt $minX) { $minX = $x }
      if ($x -gt $maxX) { $maxX = $x }
      if ($y -lt $minY) { $minY = $y }
      if ($y -gt $maxY) { $maxY = $y }
    }
  }
}
Write-Host "background pixels: $bgCount / $($W*$H)"
Write-Host "content bbox: ($minX,$minY)-($maxX,$maxY)"

# --- 4. crop to content, pad 8% to square ---
$cw = $maxX - $minX + 1; $ch = $maxY - $minY + 1
$side = [int]([Math]::Max($cw, $ch) * 1.08)
$square = New-Object System.Drawing.Bitmap($side, $side, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g2 = [System.Drawing.Graphics]::FromImage($square)
$g2.Clear([System.Drawing.Color]::Transparent)
$g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$g2.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
$dx = [int](($side - $cw) / 2); $dy = [int](($side - $ch) / 2)
$dstRect = New-Object System.Drawing.Rectangle($dx, $dy, $cw, $ch)
$srcRect = New-Object System.Drawing.Rectangle($minX, $minY, $cw, $ch)
$g2.DrawImage($bmp, $dstRect, $srcRect, [System.Drawing.GraphicsUnit]::Pixel)
$g2.Dispose()

# --- 5. master 512 PNG ---
$master = New-Object System.Drawing.Bitmap(512, 512, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g3 = [System.Drawing.Graphics]::FromImage($master)
$g3.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
$g3.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$g3.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
$g3.Clear([System.Drawing.Color]::Transparent)
$g3.DrawImage($square, 0, 0, 512, 512)
$g3.Dispose()
$master.Save($outPng, [System.Drawing.Imaging.ImageFormat]::Png)
Write-Host "wrote PNG: $outPng"

# --- 6. multi-size ICO (32bpp DIB entries) ---
$sizes = @(16, 24, 32, 48, 64, 128, 256)
$entries = @()
foreach ($s in $sizes) {
  $sb = New-Object System.Drawing.Bitmap($s, $s, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $gs = [System.Drawing.Graphics]::FromImage($sb)
  $gs.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
  $gs.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $gs.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $gs.Clear([System.Drawing.Color]::Transparent)
  $gs.DrawImage($master, 0, 0, $s, $s)
  $gs.Dispose()

  $xor = New-Object byte[] ($s * $s * 4)
  $maskPitch = [int]([Math]::Floor(($s + 31) / 32) * 4)
  $and = New-Object byte[] ($maskPitch * $s)
  for ($y = 0; $y -lt $s; $y++) {
    $srcY = $s - 1 - $y
    for ($x = 0; $x -lt $s; $x++) {
      $c = $sb.GetPixel($x, $srcY)
      $o = ($y * $s + $x) * 4
      $xor[$o] = $c.B; $xor[$o + 1] = $c.G; $xor[$o + 2] = $c.R; $xor[$o + 3] = $c.A
      if ($c.A -lt 128) {
        $and[$y * $maskPitch + [int][Math]::Floor($x / 8)] = $and[$y * $maskPitch + [int][Math]::Floor($x / 8)] -bor (128 -shr ($x % 8))
      }
    }
  }
  $sb.Dispose()

  $ms = New-Object IO.MemoryStream
  $bw = New-Object IO.BinaryWriter($ms)
  $bw.Write([UInt32]40)
  $bw.Write([Int32]$s)
  $bw.Write([Int32]($s * 2))
  $bw.Write([UInt16]1)
  $bw.Write([UInt16]32)
  $bw.Write([UInt32]0)
  $bw.Write([UInt32]($s * $s * 4))
  $bw.Write([Int32]0); $bw.Write([Int32]0)
  $bw.Write([UInt32]0); $bw.Write([UInt32]0)
  $bw.Write($xor)
  $bw.Write($and)
  $bw.Flush()
  $entries += , @{ Size = $s; Data = $ms.ToArray() }
  $bw.Dispose(); $ms.Dispose()
}

$out = New-Object IO.MemoryStream
$bw2 = New-Object IO.BinaryWriter($out)
$bw2.Write([UInt16]0); $bw2.Write([UInt16]1); $bw2.Write([UInt16]$entries.Count)
$offset = 6 + 16 * $entries.Count
foreach ($e in $entries) {
  $s = $e.Size
  $dim = if ($s -ge 256) { 0 } else { $s }
  $bw2.Write([Byte]$dim); $bw2.Write([Byte]$dim)
  $bw2.Write([Byte]0); $bw2.Write([Byte]0)
  $bw2.Write([UInt16]1); $bw2.Write([UInt16]32)
  $bw2.Write([UInt32]$e.Data.Length)
  $bw2.Write([UInt32]$offset)
  $offset += $e.Data.Length
}
foreach ($e in $entries) { $bw2.Write($e.Data) }
$bw2.Flush()
[IO.File]::WriteAllBytes($outIco, $out.ToArray())
$bw2.Dispose(); $out.Dispose()
Write-Host "wrote ICO: $outIco ($([math]::Round((Get-Item $outIco).Length/1KB,1)) KB, $($entries.Count) sizes)"

# --- 7. verify ICO loads ---
$ico = New-Object System.Drawing.Icon($outIco)
Write-Host "ico load OK: $($ico.Width)x$($ico.Height)"
$ico.Dispose()
$master.Dispose(); $square.Dispose(); $bmp.Dispose()
