<#
.SYNOPSIS
    Draws the media player's two skip-button glyphs.

.DESCRIPTION
    The stock skip icons have "30" baked into them, and Garmin's own doc for
    PlaybackProfile.skipBackwardTimeDelta says overriding the delta makes a
    custom icon necessary. SkipButton.mc feeds these two SVGs to the player
    through Media.SystemButton; this script is what draws them.

    THE NUMBERS ON THE BUTTONS MUST MATCH SKIP_FORWARD_SECONDS and
    SKIP_BACKWARD_SECONDS in GarminPocketCastsContentIterator.mc. Change one
    of those and re-run this, or the player advertises a skip the app does not
    perform - the exact bug the custom art exists to fix.

    Output is FILLS ONLY - no <text>, no stroke, no <g transform>. The
    launcher icon proves M/L fills rasterise; nothing proves the resource
    compiler honours text, strokes or transforms, and a glyph that silently
    comes out blank is the failure mode this project keeps paying for. So the
    digits are seven-segment rectangles rather than a font, and the backward
    icon is mirrored here, in the coordinates.

    The SVGs carry no device sizing. resources/drawables/drawables.xml scales
    them as a percentage of the screen, so there are no resources-icon<size>/
    override folders for these the way there are for the launcher icon - see
    the comment there for why.

.EXAMPLE
    .\tools\New-SkipIcons.ps1
    .\tools\New-SkipIcons.ps1 -Forward 45 -Backward 15
#>
[CmdletBinding()]
param(
    [int]$Forward = 30,
    [int]$Backward = 10,
    [string]$OutDir
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$AppRoot = Join-Path $RepoRoot "watch"
if (-not $OutDir) { $OutDir = Join-Path $AppRoot "resources\drawables" }
if (-not (Test-Path $OutDir)) { throw "No such directory: $OutDir" }

# Geometry, in the 24x24 viewBox every icon in this project uses.
$C  = 12.0    # centre
$RO = 10.0    # ring outer radius
$RI = 8.2     # ring inner radius
$ARC_START = 40.0
$ARC_END = 320.0

# Nothing may reach further than this from the centre of the 24x24 box.
#
# The media player does not draw the art on open screen: it clips it, and a
# fenix 8 proved the point - the arrowhead sat at radius 12.6, outside the
# circle inscribed in the bitmap and hard against its edge, and the playback
# screen cut it off while leaving the digits. 11.0 of a 12.0 half-width keeps
# a margin under either a square or a circular clip. Write-Icon enforces it.
$MAX_RADIUS = 11.2
$script:Mirror = $false

function N([double]$v) { return [Math]::Round($v, 3).ToString([Globalization.CultureInfo]::InvariantCulture) }

function P([double]$deg, [double]$r) {
    # Angle in degrees CLOCKWISE from 12 o'clock - the direction the arrow
    # travels for a forward skip.
    $a = $deg * [Math]::PI / 180.0
    $x = $C + $r * [Math]::Sin($a)
    $y = $C - $r * [Math]::Cos($a)
    if ($script:Mirror) { $x = 24.0 - $x }
    return @($x, $y)
}

function Poly($pts) {
    $d = "M " + (N $pts[0][0]) + " " + (N $pts[0][1])
    foreach ($p in $pts[1..($pts.Count - 1)]) { $d += " L " + (N $p[0]) + " " + (N $p[1]) }
    return $d + " Z"
}

function Arc([double]$a0, [double]$a1) {
    # Ring segment as a closed polygon: outer arc out, inner arc back.
    $pts = @()
    for ($a = $a0; $a -le $a1 + 0.001; $a += 3.0) { $pts += ,(P $a $RO) }
    for ($a = $a1; $a -ge $a0 - 0.001; $a -= 3.0) { $pts += ,(P $a $RI) }
    return Poly $pts
}

function Head([double]$a) {
    # Arrowhead at the leading end, pointing along the direction of travel.
    # Its base runs outside and inside the ring so it reads as a head rather
    # than as a thicker end to the ring - which makes it the OUTERMOST thing
    # in the glyph, and so the first thing any clip takes. MAX_RADIUS is what
    # keeps it inside; see the check in Write-Icon.
    $rad = $a * [Math]::PI / 180.0
    $sx = $(if ($script:Mirror) { -1.0 } else { 1.0 })
    $tx = [Math]::Cos($rad) * $sx
    $ty = [Math]::Sin($rad)
    $b1 = P $a 11.0
    $b2 = P $a 5.8
    $mid = P $a 8.4
    return Poly @($b1, @(($mid[0] + 4.0 * $tx), ($mid[1] + 4.0 * $ty)), $b2)
}

function Rect([double]$x, [double]$y, [double]$w, [double]$h) {
    return Poly @(@($x, $y), @(($x + $w), $y), @(($x + $w), ($y + $h)), @($x, ($y + $h)))
}

function Digit([string]$ch, [double]$x, [double]$y, [double]$w, [double]$h, [double]$t) {
    # Seven segments: A top, B upper-right, C lower-right, D bottom,
    # E lower-left, F upper-left, G middle.
    $half = $h / 2 + $t / 2
    $mid = $y + $h / 2 - $t / 2
    $A = Rect $x $y $w $t
    $B = Rect ($x + $w - $t) $y $t $half
    $Cs = Rect ($x + $w - $t) $mid $t $half
    $D = Rect $x ($y + $h - $t) $w $t
    $E = Rect $x $mid $t $half
    $F = Rect $x $y $t $half
    $G = Rect $x $mid $w $t
    switch ($ch) {
        "0" { return @($A, $B, $Cs, $D, $E, $F) }
        # A bare bar in a narrow cell, so "10" sits centred rather than hard
        # against the right edge the way seven-segment normally leaves it.
        "1" { return @((Rect $x $y $t $h)) }
        "2" { return @($A, $B, $G, $E, $D) }
        "3" { return @($A, $B, $Cs, $D, $G) }
        "4" { return @($F, $G, $B, $Cs) }
        "5" { return @($A, $F, $G, $Cs, $D) }
        "6" { return @($A, $F, $E, $G, $Cs, $D) }
        "7" { return @($A, $B, $Cs) }
        "8" { return @($A, $B, $Cs, $D, $E, $F, $G) }
        "9" { return @($A, $B, $Cs, $D, $F, $G) }
    }
    throw "no glyph for '$ch'"
}

function Digits([string]$text) {
    $h = 7.8; $t = 1.35; $gap = 1.6
    $widths = @()
    foreach ($ch in $text.ToCharArray()) { $widths += $(if ($ch -eq '1') { $t } else { 5.0 }) }
    $total = ($widths | Measure-Object -Sum).Sum + $gap * ($widths.Count - 1)
    $x = $C - $total / 2
    $y = $C - $h / 2
    $paths = @()
    for ($i = 0; $i -lt $text.Length; $i++) {
        $paths += Digit $text[$i] $x $y $widths[$i] $h $t
        $x += $widths[$i] + $gap
    }
    # The ring's inner radius is what the digits have to live inside. Two
    # digits fit; three would not, and would be unreadable at 42px anyway.
    $half = $total / 2
    foreach ($corner in @(@(($C - $half), $y), @(($C + $half), ($y + $h)))) {
        $dx = $corner[0] - $C; $dy = $corner[1] - $C
        if ([Math]::Sqrt($dx * $dx + $dy * $dy) -gt $RI - 0.4) {
            throw "'$text' does not fit inside the ring - shorten it or redraw the glyph"
        }
    }
    return $paths
}

function Write-Icon([string]$file, [string]$text, [bool]$mirror) {
    $script:Mirror = $mirror
    $paths = @((Arc $ARC_START $ARC_END), (Head $ARC_END))
    $script:Mirror = $false          # digits are never mirrored
    $paths += Digits $text
    # Every point, not just the ones that look like the outliers. The ring is
    # the obvious extreme and was not the one that got clipped.
    $worst = 0.0
    foreach ($p in $paths) {
        $nums = [regex]::Matches($p, '-?\d+(\.\d+)?') | ForEach-Object { [double]$_.Value }
        for ($i = 0; $i -lt $nums.Count; $i += 2) {
            $dx = $nums[$i] - $C; $dy = $nums[$i + 1] - $C
            $r = [Math]::Sqrt($dx * $dx + $dy * $dy)
            if ($r -gt $worst) { $worst = $r }
        }
    }
    if ($worst -gt $MAX_RADIUS) {
        throw ("$file reaches radius {0:N2}, past MAX_RADIUS {1} - the player will clip it" -f $worst, $MAX_RADIUS)
    }

    $body = ($paths | ForEach-Object { '<path d="' + $_ + '"/>' }) -join "`n"
    $svg = @"
<svg width="48" height="48" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" fill="#FFFFFF">
$body
</svg>
"@
    $path = Join-Path $OutDir $file
    Set-Content -Path $path -Value $svg -Encoding UTF8
    Write-Host ("wrote {0}  ({1}s, {2} bytes)" -f $file, $text, (Get-Item $path).Length)
}

# Forward is travelled clockwise, so the head lands at the left of the gap
# pointing right. Backward is the mirror of exactly that.
Write-Icon "skip_forward.svg"  "$Forward"  $false
Write-Icon "skip_backward.svg" "$Backward" $true
