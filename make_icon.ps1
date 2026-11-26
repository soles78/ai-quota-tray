# Generates ai_quota.ico (7 sizes) + preview PNG.  Usage: powershell -File make_icon.ps1 [-Preview path.png]
# Design: dark squircle tile, three concentric quota gauges (Claude orange / Codex green / Antigravity blue).
param([string]$Out = (Join-Path $PSScriptRoot 'ai_quota.ico'), [string]$Preview = '')
Add-Type -AssemblyName System.Drawing

function New-Frame([int]$size) {
    $ss = 4                                   # supersample then downscale for clean edges
    $S = $size * $ss
    $bmp = New-Object System.Drawing.Bitmap $S, $S, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.PixelOffsetMode = 'HighQuality'; $g.Clear([System.Drawing.Color]::Transparent)
    $k = $S / 256.0
    $small = $size -le 32

    # --- tile ---
    $m = 6 * $k; $rad = 58 * $k
    $tile = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $rad * 2; $x0 = $m; $y0 = $m; $w = $S - 2 * $m
    $tile.AddArc($x0, $y0, $d, $d, 180, 90); $tile.AddArc($x0 + $w - $d, $y0, $d, $d, 270, 90)
    $tile.AddArc($x0 + $w - $d, $y0 + $w - $d, $d, $d, 0, 90); $tile.AddArc($x0, $y0 + $w - $d, $d, $d, 90, 90); $tile.CloseFigure()
    $bgBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush ((New-Object System.Drawing.PointF 0, $m), (New-Object System.Drawing.PointF $S, ($S - $m)), ([System.Drawing.Color]::FromArgb(255, 38, 44, 92)), ([System.Drawing.Color]::FromArgb(255, 9, 11, 28)))
    $g.FillPath($bgBrush, $tile)
    # soft top-left sheen
    $clip = $g.Clip; $g.SetClip($tile)
    $sheen = New-Object System.Drawing.Drawing2D.GraphicsPath
    $sheen.AddEllipse(-80 * $k, -140 * $k, 330 * $k, 250 * $k)
    $pgb = New-Object System.Drawing.Drawing2D.PathGradientBrush $sheen
    $pgb.CenterColor = [System.Drawing.Color]::FromArgb(46, 140, 160, 255); $pgb.SurroundColors = @([System.Drawing.Color]::FromArgb(0, 140, 160, 255))
    $g.FillPath($pgb, $sheen); $g.Clip = $clip
    $edge = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(70, 170, 185, 255)), (2.2 * $k)
    $g.DrawPath($edge, $tile)

    # --- gauges ---
    $cx = $S / 2.0; $cy = $S / 2.0
    $sw = if ($small) { 27 } else { 21 }; $gap = if ($small) { 5 } else { 8 }
    $r1 = 94.0; $step = $sw + $gap
    $rings = @(
        @{ r = $r1;            sweep = 0.78; c1 = @(255, 150, 92);  c2 = @(232, 82, 28) },   # Claude
        @{ r = $r1 - $step;    sweep = 0.58; c1 = @(86, 240, 176);  c2 = @(20, 176, 120) },  # Codex
        @{ r = $r1 - 2*$step;  sweep = 0.36; c1 = @(130, 168, 255); c2 = @(96, 84, 255) }    # Antigravity
    )
    if ($small) { $rings = @($rings[0], $rings[1], $rings[2]) }
    foreach ($ring in $rings) {
        $rr = $ring.r * $k; $pw = $sw * $k
        $rect = New-Object System.Drawing.RectangleF ($cx - $rr), ($cy - $rr), (2 * $rr), (2 * $rr)
        # track
        $tp = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(34, 190, 200, 255)), $pw
        $g.DrawEllipse($tp, $rect)
        # glow
        if (-not $small) {
            foreach ($gw in @(2.2, 1.55)) {
                $gp = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(($(if ($gw -gt 2) { 22 } else { 34 })), $ring.c1[0], $ring.c1[1], $ring.c1[2])), ($pw * $gw)
                $gp.StartCap = 'Round'; $gp.EndCap = 'Round'
                $g.DrawArc($gp, $rect, -90, 360 * $ring.sweep)
            }
        }
        # arc with gradient along its bounding rect
        $br = New-Object System.Drawing.Drawing2D.LinearGradientBrush $rect, ([System.Drawing.Color]::FromArgb(255, $ring.c1[0], $ring.c1[1], $ring.c1[2])), ([System.Drawing.Color]::FromArgb(255, $ring.c2[0], $ring.c2[1], $ring.c2[2])), 45.0
        $ap = New-Object System.Drawing.Pen $br, $pw
        $ap.StartCap = 'Round'; $ap.EndCap = 'Round'
        $g.DrawArc($ap, $rect, -90, 360 * $ring.sweep)
    }
    # center spark
    if (-not $small) {
        $cr = 11 * $k
        $cb = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 255, 255, 255))
        $g.FillEllipse($cb, $cx - $cr, $cy - $cr, 2 * $cr, 2 * $cr)
        $cg = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(40, 190, 210, 255))
        $g.FillEllipse($cg, $cx - 1.9 * $cr, $cy - 1.9 * $cr, 3.8 * $cr, 3.8 * $cr)
        $g.FillEllipse($cb, $cx - $cr, $cy - $cr, 2 * $cr, 2 * $cr)
    }
    $g.Dispose()

    $out = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g2 = [System.Drawing.Graphics]::FromImage($out)
    $g2.InterpolationMode = 'HighQualityBicubic'; $g2.PixelOffsetMode = 'HighQuality'; $g2.CompositingMode = 'SourceCopy'
    $g2.DrawImage($bmp, 0, 0, $size, $size); $g2.Dispose(); $bmp.Dispose()
    return $out
}

function Get-DibBytes($bmp) {
    $w = $bmp.Width; $h = $bmp.Height
    $rect = New-Object System.Drawing.Rectangle 0, 0, $w, $h
    $bd = $bmp.LockBits($rect, 'ReadOnly', [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $raw = New-Object byte[] ($bd.Stride * $h); [System.Runtime.InteropServices.Marshal]::Copy($bd.Scan0, $raw, 0, $raw.Length); $bmp.UnlockBits($bd)
    $ms = New-Object System.IO.MemoryStream; $bw = New-Object System.IO.BinaryWriter $ms
    $bw.Write([int]40); $bw.Write([int]$w); $bw.Write([int]($h * 2)); $bw.Write([int16]1); $bw.Write([int16]32)
    $bw.Write([int]0); $bw.Write([int]($w * $h * 4)); $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0)
    for ($y = $h - 1; $y -ge 0; $y--) { $bw.Write($raw, $y * $bd.Stride, $w * 4) }
    $maskRow = [int]([math]::Ceiling($w / 32.0) * 4)
    $bw.Write((New-Object byte[] ($maskRow * $h)))
    $bw.Flush(); return , ([byte[]]$ms.ToArray())
}

$sizes = 16, 24, 32, 48, 64, 128, 256
$frames = @()
foreach ($s in $sizes) {
    $b = New-Frame $s
    [byte[]]$data = Get-DibBytes $b   # BMP frames only: csc /win32icon rejects PNG-compressed frames
    $frames += , @{ s = $s; data = $data; bmp = $b }
}
$fs = [System.IO.File]::Create($Out); $bw = New-Object System.IO.BinaryWriter $fs
$bw.Write([int16]0); $bw.Write([int16]1); $bw.Write([int16]$frames.Count)
$off = 6 + 16 * $frames.Count
foreach ($f in $frames) {
    $bw.Write([byte]$(if ($f.s -ge 256) { 0 } else { $f.s })); $bw.Write([byte]$(if ($f.s -ge 256) { 0 } else { $f.s }))
    $bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([int16]1); $bw.Write([int16]32)
    $bw.Write([int]$f.data.Length); $bw.Write([int]$off); $off += $f.data.Length
}
foreach ($f in $frames) { $bw.Write($f.data) }
$bw.Close(); $fs.Close()
"ico: $Out ($((Get-Item $Out).Length) bytes)"

if ($Preview) {
    # contact sheet on light + dark backgrounds, 16..256 shown at actual px
    $W = 760; $H = 330
    $sheet = New-Object System.Drawing.Bitmap $W, $H
    $g = [System.Drawing.Graphics]::FromImage($sheet)
    $g.Clear([System.Drawing.Color]::FromArgb(240, 240, 244))
    $g.FillRectangle((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(32, 32, 36))), 0, 170, $W, 160)
    $g.DrawImage($frames[6].bmp, 10, 6, 156, 156)
    $x = 190
    foreach ($i in 5, 4, 3, 2, 1, 0) { $f = $frames[$i]; $g.DrawImage($f.bmp, $x, 20); $x += $f.s + 16 }
    $x = 190
    foreach ($i in 5, 4, 3, 2, 1, 0) { $f = $frames[$i]; $g.DrawImage($f.bmp, $x, 200); $x += $f.s + 16 }
    $g.Dispose(); $sheet.Save($Preview, [System.Drawing.Imaging.ImageFormat]::Png)
    "preview: $Preview"
}
