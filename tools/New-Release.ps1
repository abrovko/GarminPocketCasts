<#
.SYNOPSIS
    Cut a GitHub release: build a signed .prg for every product in the
    manifest, package each as a ready-to-copy watch folder, and publish the
    lot as release assets.

.DESCRIPTION
    A GitHub release is a tag plus a set of files; nothing builds those files
    for you. This script is that build, and it runs here rather than in CI
    because everything it needs is already on this machine - the SDK, the
    device definitions, and the developer key, which is per-developer, lives
    outside the repo and must never reach a public runner.

    What someone sideloading this app needs is not one file but a small tree,
    so each product ships as an archive of exactly that tree:

        GARMIN/APPS/GarminPocketCasts.prg              the app
        GARMIN/APPS/LOGS/GarminPocketCasts.TXT         empty, and required
        GARMIN/Debug/GarminPocketCasts.prg.debug.xml   symbols

    Unzip, drag GARMIN onto the watch, merge. That replaces a list of
    instructions with a layout, and the empty log file is why it is worth
    doing: the watch discards every System.println unless that file already
    exists, and nobody talked through creating a zero-byte file with an exact
    name over MTP is likely to end up with one.

    The .iq that `monkeyc -e` produces is the *store* upload bundle and is
    useless to a sideloader, so it is built only on request (-IncludeIq).

    Assets published:
        GarminPocketCasts-<version>-<device>.zip      one archive per product
        SHA256SUMS.txt

    Still one asset per watch and no all-devices bundle: sideloading is one
    download onto one watch. Each is labelled with the SDK's own displayName for
    that product ("fenix847mm" is a fēnix 8 47mm AND a 51mm AND a tactix 8 AND a
    quatix 8), and the notes carry the same mapping as a table, because a device
    id is not something anyone knows about their own watch.

    There is no separate symbols archive. A crash log resolves only against the
    .prg.debug.xml matching the binary that produced it, so the symbols ride
    inside the archive for that device - the one pairing that was ever useful -
    instead of in a bundle that has to be matched up by hand later.

    BuildInfo.STAMP is rewritten to the version for the duration of the build
    and restored afterwards, so the watch's Settings row reads "Build 1.0.0"
    and the tag says which source produced it.

.EXAMPLE
    .\tools\New-Release.ps1 -Version 1.0.0
.EXAMPLE
    .\tools\New-Release.ps1 -Version 1.1.0 -PreRelease -Draft
.EXAMPLE
    .\tools\New-Release.ps1 -Version 0.0.1 -Products fenix7x -BuildOnly
#>
[CmdletBinding()]
param(
    # Semver, with or without the leading v. The tag is always v<version>.
    [Parameter(Mandatory = $true)]
    [string]   $Version,

    # Release notes. Without either, they are generated from the commit
    # subjects since the previous tag.
    [string]   $Notes     = '',
    [string]   $NotesFile = '',

    [switch]   $PreRelease,
    [switch]   $Draft,

    # Build only; no tag, no upload. Use with -Products for a quick dry run.
    [switch]   $BuildOnly,

    # Also build the .iq store bundle. Off by default: it compiles every
    # target again and nobody sideloading wants the file.
    [switch]   $IncludeIq,

    # Subset of products to build. Default is every one in the manifest.
    [string[]] $Products = @(),

    # monkeyc warnings abort the release. This repo is warning-free at -l 3 on
    # every target, and a warning here means one device is broken in a way the
    # fenix7x build cannot show you.
    [switch]   $AllowWarnings,

    # Publish from a dirty tree / an unpushed HEAD anyway.
    [switch]   $Force,

    # Upload assets under their bare filenames instead of labelling each with
    # the watch it is for. The escape hatch if gh ever rejects a label.
    [switch]   $NoAssetLabels,

    [string]   $AppName      = 'GarminPocketCasts',
    [string]   $DeveloperKey = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Every git/gh call here is checked through $LASTEXITCODE, which only works if
# a non-zero exit is not also turned into a terminating error by the Stop
# preference above. PowerShell 7.3+ can do exactly that, and it is per-session,
# so it is pinned rather than assumed.
if (Get-Variable PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

# $RepoRoot is where git and gh operate; $AppRoot is the Connect IQ project.
# They are different directories since the app moved into watch\, and the split
# matters here more than anywhere else - the preflight reads the repo's status
# and the build reads the app's manifest.
$RepoRoot      = Split-Path -Parent $PSScriptRoot
$AppRoot       = Join-Path $RepoRoot 'watch'
$ManifestPath  = Join-Path $AppRoot 'manifest.xml'
$BuildInfoPath = Join-Path $AppRoot 'source\BuildInfo.mc'
$JunglePath    = Join-Path $AppRoot 'monkey.jungle'

function Write-Step ($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok   ($msg) { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn ($msg) { Write-Host "    $msg" -ForegroundColor Yellow }
function Write-Dim  ($msg) { Write-Host "    $msg" -ForegroundColor DarkGray }

# ------------------------------------------------------------- version -------

$ver = $Version.TrimStart('v', 'V')
if ($ver -notmatch '^\d+\.\d+\.\d+(-[0-9A-Za-z.\-]+)?$') {
    throw "Version '$Version' is not semver (expected e.g. 1.0.0 or 1.0.0-beta.1)."
}
$tag    = "v$ver"
$OutDir = Join-Path $AppRoot "bin\release\$tag"

# ------------------------------------------------------------ preflight ------

# The developer key is per-developer and lives outside the repo, so nothing
# here may hardcode a path to it. Same order as Deploy-Watch.ps1.
function Resolve-DeveloperKey {
    $candidates = @(
        $DeveloperKey,
        $env:GARMIN_DEVELOPER_KEY,
        (Join-Path $env:APPDATA 'Garmin\ConnectIQ\developer_key')
    )
    foreach ($c in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($c) -and (Test-Path -LiteralPath $c)) { return $c }
    }
    if (-not [string]::IsNullOrWhiteSpace($DeveloperKey)) {
        throw "Developer key not found at $DeveloperKey"
    }
    throw ("No developer key. Set GARMIN_DEVELOPER_KEY to its path " +
           "(setx GARMIN_DEVELOPER_KEY C:\path\to\developer_key), or pass -DeveloperKey <path>.")
}

function Resolve-MonkeyC {
    $cfg = Join-Path $env:APPDATA 'Garmin\ConnectIQ\current-sdk.cfg'
    if (-not (Test-Path $cfg)) { throw "No current-sdk.cfg at $cfg" }
    $sdkRoot = (Get-Content $cfg -Raw).Trim()
    $monkeyc = Join-Path (Join-Path $sdkRoot 'bin') 'monkeyc.bat'
    if (-not (Test-Path $monkeyc)) { throw "monkeyc.bat not found at $monkeyc" }
    return [pscustomobject]@{ Path = $monkeyc; Sdk = (Split-Path -Leaf $sdkRoot.TrimEnd('\')) }
}

# manifest.xml is the authority on what "all targets" means, so the product
# list is read from it rather than kept in a second place that goes stale.
function Get-ManifestProducts {
    if (-not (Test-Path $ManifestPath)) { throw "Missing $ManifestPath" }
    $xml = [xml](Get-Content -LiteralPath $ManifestPath -Raw)
    $ns  = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
    $ns.AddNamespace('iq', 'http://www.garmin.com/xml/connectiq')
    $ids = @($xml.SelectNodes('//iq:product', $ns) | ForEach-Object { $_.GetAttribute('id') })
    if ($ids.Count -eq 0) { throw "No <iq:product> entries found in $ManifestPath" }
    return $ids
}

# A device with no SDK definition installed cannot be built, and monkeyc's own
# error for it is easy to miss 40 products into a loop. Name them all up front.
function Assert-DevicesInstalled ($ids) {
    $missing = @($ids | Where-Object { -not (Test-Path (Get-CompilerJsonPath $_)) })
    if ($missing.Count -gt 0) {
        throw ("No SDK definition for $($missing.Count) product(s): $($missing -join ', ').`n" +
               "Install them from the Connect IQ SDK Manager (Devices tab), then re-run.")
    }
}

function Get-CompilerJsonPath ($id) {
    return (Join-Path $env:APPDATA "Garmin\ConnectIQ\Devices\$id\compiler.json")
}

# A product id is not a watch. `fenix847mm` is the part number for a fēnix 8
# 51mm and a tactix 8 and a quatix 8, and nobody browsing a release page knows
# that - so the human names come from the SDK's own compiler.json, which is
# the same file that is authoritative about app types and memory limits. All 57
# products in this manifest carry a displayName; the fallback is the id, which
# is at least what the file is called.
$script:DisplayNames = @{}
function Get-DeviceDisplayName ($id) {
    if (-not $script:DisplayNames.ContainsKey($id)) {
        $name = $id
        $path = Get-CompilerJsonPath $id
        if (Test-Path $path) {
            $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            if ($json.PSObject.Properties.Name -contains 'displayName' -and $json.displayName) {
                $name = [string]$json.displayName
            }
        }
        $script:DisplayNames[$id] = $name
    }
    return $script:DisplayNames[$id]
}

function Assert-GitReady {
    Push-Location $RepoRoot
    try {
        git rev-parse --is-inside-work-tree *> $null
        if ($LASTEXITCODE -ne 0) { throw 'Not a git repository.' }

        # BuildInfo.mc is generated on every deploy, so it is expected to be
        # dirty and is not a reason to refuse.
        $dirty = @(git status --porcelain |
                   Where-Object { $_ -notmatch 'watch/source/BuildInfo\.mc$' })
        if ($dirty.Count -gt 0 -and -not $Force) {
            throw ("Working tree is dirty - commit or stash first, or pass -Force:`n" +
                   ($dirty -join "`n"))
        }

        if (git tag -l $tag) { throw "Tag $tag already exists locally." }
        $remoteTag = git ls-remote --tags origin "refs/tags/$tag"
        if ($LASTEXITCODE -eq 0 -and $remoteTag) { throw "Tag $tag already exists on origin." }

        # gh creates the tag server-side at this sha, so the commit has to be
        # on the remote already or the release points at nothing.
        $sha      = (git rev-parse HEAD).Trim()
        $onRemote = @(git branch -r --contains HEAD 2>$null)
        if ($onRemote.Count -eq 0 -and -not $Force) {
            throw ("HEAD ($($sha.Substring(0,8))) is on no remote branch. " +
                   "Push it first, or pass -Force.")
        }
        return $sha
    } finally { Pop-Location }
}

function Assert-GhReady {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw ("GitHub CLI not found. Install it (winget install GitHub.cli), open a new " +
               "shell, run 'gh auth login', then re-run - or use -BuildOnly.")
    }
    gh auth status *> $null
    if ($LASTEXITCODE -ne 0) { throw "gh is not authenticated. Run 'gh auth login'." }
}

# -------------------------------------------------------------- stamp --------

# The stamp is what the watch shows in Settings and prints from onStart(), and
# it is generated rather than hand-maintained for the reason BuildInfo.mc
# gives: a constant you have to remember to bump goes stale, and a stale
# version number is worse than none because it is believed. For a release the
# useful value is the version itself; the tag pins the source it came from.
function Set-BuildStamp ($value) {
    if (-not (Test-Path $BuildInfoPath)) { throw "Missing $BuildInfoPath" }
    $text = Get-Content -LiteralPath $BuildInfoPath -Raw
    if ($text -notmatch 'const STAMP = "[^"]*";') {
        throw "Could not find 'const STAMP = ...' in $BuildInfoPath"
    }
    $next = [regex]::Replace($text, 'const STAMP = "[^"]*";', "const STAMP = `"$value`";")
    Set-Content -LiteralPath $BuildInfoPath -Value $next -NoNewline -Encoding utf8
}

# ------------------------------------------------------------- package -------

# One archive per device, holding the exact tree the watch expects:
#
#   GARMIN/APPS/<App>.prg                 the app - APPS, never APPS/MEDIA
#   GARMIN/APPS/LOGS/<App>.TXT            empty, and it has to exist or every
#                                         System.println is silently discarded
#   GARMIN/Debug/<App>.prg.debug.xml      symbols for this exact binary
#
# The empty log file is the reason this is an archive rather than three loose
# assets: it cannot be published as a file anyone would think to keep, and a
# user told to "create an empty file with exactly this name" mostly will not.
# Shipping the layout removes the whole instruction.
#
# Copy by name into a clean staging tree - never archive the directory monkeyc
# built in. It writes gen\, mir\ and a settings .json beside its output, and an
# earlier version of this script shipped every Rez.mcgen in the build.
function New-DeviceArchive ($id, $prg) {
    $stage = Join-Path $BuildDir "$id\stage"
    $apps  = Join-Path $stage 'GARMIN\APPS'
    $logs  = Join-Path $apps  'LOGS'
    $dbg   = Join-Path $stage 'GARMIN\Debug'
    New-Item -ItemType Directory -Force -Path $logs, $dbg | Out-Null

    Copy-Item -LiteralPath $prg -Destination (Join-Path $apps "$AppName.prg")

    # Absent only if monkeyc changes where it writes symbols; the zip is still
    # usable without them, so this warns rather than aborting the release.
    $sym = "$prg.debug.xml"
    if (Test-Path -LiteralPath $sym) {
        Copy-Item -LiteralPath $sym -Destination (Join-Path $dbg "$AppName.prg.debug.xml")
    } else {
        Write-Warn "no symbols for $id - crash logs from it will not resolve"
    }

    # -ItemType File with no -Value is a genuine zero-byte file, and a zero-byte
    # entry survives the archive (verified: it unpacks at 0 bytes, not absent).
    $stub = Join-Path $logs "$AppName.TXT"
    if (-not (Test-Path -LiteralPath $stub)) { New-Item -ItemType File -Path $stub | Out-Null }

    # Pointing -Path at the directory itself is what puts GARMIN/ at the root of
    # the archive, so it drops straight onto the watch. A trailing \* would
    # scatter APPS/ and Debug/ into the root instead.
    $zip = Join-Path $ZipDir "$AppName-$ver-$id.zip"
    Compress-Archive -Path (Join-Path $stage 'GARMIN') -DestinationPath $zip -CompressionLevel Optimal
    return $zip
}

# --------------------------------------------------------------- notes -------

# Asset links have to be written before the release exists, so the download url
# is composed rather than read back. It is a documented, stable form:
# github.com/<owner>/<repo>/releases/download/<tag>/<asset>.
function Resolve-NameWithOwner {
    $nwo = ''
    Push-Location $RepoRoot
    try {
        # gh knows about forks and renames; the remote url is the fallback that
        # works with -BuildOnly, where gh may not be installed at all.
        if (Get-Command gh -ErrorAction SilentlyContinue) {
            $nwo = (& gh repo view --json nameWithOwner -q .nameWithOwner 2>$null |
                    Select-Object -First 1)
            if ($LASTEXITCODE -ne 0) { $nwo = '' }
        }
        if (-not $nwo) {
            $url = (git remote get-url origin 2>$null)
            if ($LASTEXITCODE -eq 0 -and $url -match 'github\.com[:/](.+?)(\.git)?/?$') {
                $nwo = $Matches[1]
            }
        }
    } finally { Pop-Location }
    return "$nwo".Trim()
}

# The table is the point of the release page. A product id is not something a
# user knows about their own watch, so it is the display name that leads, and
# the rows are sorted by it - "Venu 3" is looked up under V, not under the v of
# a part number.
function Get-DeviceTable ($devices) {
    $nwo  = Resolve-NameWithOwner
    $rows = foreach ($d in ($devices | Sort-Object { $_.Name })) {
        $file = Split-Path -Leaf $d.File
        $link = if ($nwo) {
            "[$file](https://github.com/$nwo/releases/download/$tag/$file)"
        } else { "``$file``" }
        "| {0} | ``{1}`` | {2} |" -f $d.Name, $d.Id, $link
    }
    return (@(
        "### Which file for which watch",
        '',
        "| Watch | Device | Download |",
        "| --- | --- | --- |"
    ) + $rows) -join "`n"
}

function Get-ReleaseNotes ($sha, $devices) {
    if ($NotesFile) {
        if (-not (Test-Path -LiteralPath $NotesFile)) { throw "No notes file at $NotesFile" }
        $body = Get-Content -LiteralPath $NotesFile -Raw
    } elseif ($Notes) {
        $body = $Notes
    } else {
        Push-Location $RepoRoot
        try {
            $prev  = (git tag --list 'v*' --sort=-v:refname | Select-Object -First 1)
            $range = if ($prev) { "$prev..HEAD" } else { 'HEAD' }
            $log   = @(git log --no-merges --pretty=format:'- %s' $range)
            $head  = if ($prev) { "### Changes since $prev" } else { '### Changes' }
            $body  = ($head, '', ($log -join "`n")) -join "`n"
        } finally { Pop-Location }
    }

    # Every release page says this, on every release. A prebuilt binary from a
    # stranger, sideloaded past any store review, onto hardware the reader owns
    # - and this particular one holds their Pocket Casts password. Building it
    # themselves is a real option and takes minutes, so the notes say so rather
    # than leaving it as something they have to think of.
    $nwo = Resolve-NameWithOwner
    $licenceLink = if ($nwo) { "[licence](https://github.com/$nwo/blob/main/LICENSE)" }
                   else      { 'LICENSE file in the repository' }

    $risk = @"

### Sideload at your own risk

These files are built on a personal machine and signed with a personal developer key.
Sideloading bypasses the Connect IQ store, so **nothing here has been reviewed by Garmin**,
and this app handles your Pocket Casts email and password.

Installing a binary from someone else is a decision, not a formality:

- **Read the source first.** All of it is in this repository under MPL-2.0. The network
  calls are in ``watch/source/PocketCastsClient.mc`` and ``watch/source/Proxy.mc``, and there are no
  third-party libraries in the watch app to audit beyond that.
- **Better still, build it yourself.** The README documents the build. It needs the free
  Connect IQ SDK and a developer key, and takes a few minutes - that removes the question
  entirely.
- **``SHA256SUMS.txt`` proves a download arrived intact, nothing more.** It confirms the
  file matches what was uploaded here. It cannot tell you the file is safe.

No warranty of any kind - see the $licenceLink. Install these at your own risk.
"@

    $install = @"

### Installing

Sideloading, not the Connect IQ store - this app is not published there.

1. Find your watch in the table below and download **one** ``.zip``. Each build targets
   one device; a file for another watch will not work.
2. Unzip it. Inside is a ``GARMIN`` folder already laid out the way the watch expects -
   nothing needs renaming or moving.
3. Connect the watch by USB and copy that ``GARMIN`` folder onto the watch, merging it
   with the ``GARMIN`` folder already there when Windows asks.
4. Unplug the watch. No restart is needed for a first install.
5. It is an audio content provider, so it appears under **Music -> Music Providers**,
   not in the app list.

Confirm what is running from the last row of Settings - it should read ``Build $ver``.

**If you are upgrading and it still names the old build, restart the watch.** A new ``.prg``
copied over an older one is not always picked up straight away - most likely when the previous
version is still running. Restarting is the fix, and it is only ever needed in that case.

The archive holds three files. Two of them look skippable and are worth keeping:

| In the archive | What it is |
| --- | --- |
| ``GARMIN/APPS/$AppName.prg`` | the app itself |
| ``GARMIN/APPS/LOGS/$AppName.TXT`` | **empty on purpose.** The watch only writes the app's log if this file already exists, and it is easy to delete by mistake because it looks like nothing. Replacing it means making an empty file with exactly that name and copying it back |
| ``GARMIN/Debug/$AppName.prg.debug.xml`` | symbols. A crash log resolves only against the exact binary that produced it, so this is the copy that matches |

Both are inert unless something goes wrong, and together they are the difference between
a bug report that can be read and one that cannot.

Built from ``$($sha.Substring(0, [Math]::Min(8, $sha.Length)))`` with $($devices.Count) device target(s).
"@

    # A here-string drops the newline before its terminator, so the blank line
    # that separates the table's heading from the paragraph above is added here.
    return ($body.TrimEnd() + "`n" + $risk + "`n" + $install + "`n`n" +
            (Get-DeviceTable $devices) + "`n")
}

# ---------------------------------------------------------------- build ------

Write-Host ''
Write-Step "Release $tag"

$key = Resolve-DeveloperKey
$mc  = Resolve-MonkeyC
Write-Dim "sdk $($mc.Sdk)"

# @() around it: PowerShell unrolls a one-element array to a bare string, and
# -Products fenix7x would then take .Count off a String and fail under
# StrictMode - a single target is exactly what a dry run passes.
$ids = @(if ($Products.Count -gt 0) { $Products } else { Get-ManifestProducts })
Assert-DevicesInstalled $ids
Write-Ok "$($ids.Count) product(s) to build"

$sha = 'HEAD'
if (-not $BuildOnly) {
    Assert-GhReady
    $sha = Assert-GitReady
    Write-Ok "publishing from $($sha.Substring(0,8))"
}

if (Test-Path $OutDir) { Remove-Item -Recurse -Force $OutDir }

# Two directories, and keeping them apart is what stops the build's litter
# reaching a user. monkeyc writes gen\, mir\ and a settings .json beside its
# output file, so nothing may be archived from where it builds - $BuildDir is
# scratch, and the staging tree under it receives only files copied into it by
# name. $ZipDir holds what actually goes up.
$BuildDir = Join-Path $OutDir 'build'
$ZipDir   = Join-Path $OutDir 'zip'
New-Item -ItemType Directory -Force -Path $BuildDir, $ZipDir | Out-Null

$originalBuildInfo = Get-Content -LiteralPath $BuildInfoPath -Raw
$warnings = @()
$devices  = [System.Collections.Generic.List[object]]::new()
$built    = 0

try {
    Set-BuildStamp $ver
    Write-Ok "build stamp $ver"

    Write-Step "Building $($ids.Count) target(s)"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $n  = 0
    foreach ($id in $ids) {
        $n++
        # Inside the zip the .prg carries its plain name, because the watch
        # keys a lot off that filename - the log file at GARMIN/APPS/LOGS/ must
        # match it or output is silently discarded, and app Storage is keyed by
        # it too. The version and device live on the *archive* instead, which is
        # what sits in someone's Downloads folder looking like every other one.
        $devDir = Join-Path $BuildDir $id
        New-Item -ItemType Directory -Force -Path $devDir | Out-Null
        $prg = Join-Path $devDir "$AppName.prg"
        Write-Host ("    [{0,3}/{1}] {2,-24}" -f $n, $ids.Count, $id) -NoNewline

        $out = & $mc.Path -o $prg -f $JunglePath -y $key -d $id -r -w -l 3 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host ''
            Write-Host ($out | Out-String) -ForegroundColor Red
            throw "monkeyc failed for $id (exit $LASTEXITCODE)"
        }

        $zip = New-DeviceArchive $id $prg

        $warn = @($out | Where-Object { "$_" -match 'WARNING' })
        if ($warn.Count -gt 0) {
            $warnings += ($warn | ForEach-Object { "${id}: $_" })
            Write-Host ("{0,9:N0} prg {1,9:N0} zip  {2} warning(s)" -f `
                        (Get-Item $prg).Length, (Get-Item $zip).Length, $warn.Count) `
                       -ForegroundColor Yellow
        } else {
            Write-Host ("{0,9:N0} prg {1,9:N0} zip" -f `
                        (Get-Item $prg).Length, (Get-Item $zip).Length) -ForegroundColor DarkGray
        }

        $devices.Add([pscustomobject]@{
            Id   = $id
            Name = (Get-DeviceDisplayName $id)
            File = $zip
        })
        $built++
    }
    $sw.Stop()
    Write-Ok ("built $built target(s) in {0:N0}s" -f $sw.Elapsed.TotalSeconds)

    if ($IncludeIq) {
        Write-Step 'Building .iq store bundle'
        $iq  = Join-Path $OutDir "$AppName-$ver.iq"
        $out = & $mc.Path -e -o $iq -f $JunglePath -y $key -w -l 3 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host ($out | Out-String) -ForegroundColor Red
            throw "export build failed (exit $LASTEXITCODE)"
        }
        $warnings += @($out | Where-Object { "$_" -match 'WARNING' } |
                              ForEach-Object { "export: $_" })
        Write-Ok ("{0:N0} bytes" -f (Get-Item $iq).Length)
    }
}
finally {
    # Always put the placeholder back: the committed value is "dev" so that a
    # hand-built binary never claims to be a release.
    Set-Content -LiteralPath $BuildInfoPath -Value $originalBuildInfo -NoNewline -Encoding utf8
}

if ($warnings.Count -gt 0) {
    Write-Host ''
    $warnings | ForEach-Object { Write-Warn $_ }
    if (-not $AllowWarnings) {
        throw ("$($warnings.Count) warning(s) - a warning on one target means that device is " +
               "broken in a way the fenix7x build cannot show you. Fix them, or pass -AllowWarnings.")
    }
}

# ------------------------------------------------------------- package -------

Write-Step 'Packaging'

# One archive per device, each labelled with the watch it is for. Still one
# asset per watch and no all-devices bundle: sideloading is one download onto
# one watch, so an archive of all 57 would be megabytes to fetch and a folder to
# search for a name you would have to know already.
$assets = @($devices | ForEach-Object { $_.File })

# There is no separate symbols archive. Each device zip carries the
# .prg.debug.xml for its own binary, which is the only pairing that resolves a
# crash log anyway - so the symbols travel with the thing they describe instead
# of in a bundle that has to be matched up by hand after the build is gone.

if ($IncludeIq) { $assets += (Join-Path $OutDir "$AppName-$ver.iq") }

$sums = Join-Path $OutDir 'SHA256SUMS.txt'
Get-FileHash -Algorithm SHA256 $assets |
    ForEach-Object { "{0}  {1}" -f $_.Hash.ToLower(), (Split-Path -Leaf $_.Path) } |
    Set-Content -LiteralPath $sums -Encoding ascii
$assets += $sums

$totalBytes = ($assets | ForEach-Object { (Get-Item $_).Length } | Measure-Object -Sum).Sum
Write-Ok ("{0} asset(s), {1:N0} bytes" -f $assets.Count, $totalBytes)
Write-Dim ("{0,10:N0}  {1}" -f (Get-Item $sums).Length, (Split-Path -Leaf $sums))

$notesPath = Join-Path $OutDir 'RELEASE_NOTES.md'
Set-Content -LiteralPath $notesPath -Value (Get-ReleaseNotes $sha $devices) -Encoding utf8

if ($BuildOnly) {
    Write-Host ''
    Write-Host "Built, not published. Assets in: $OutDir" -ForegroundColor Green
    Write-Dim "Notes (device table included): $notesPath"
    return
}

# ------------------------------------------------------------- publish -------

Write-Step "Publishing $tag"

# gh labels an asset with anything after a '#' in the argument, and GitHub shows
# that label in place of the filename - so the assets list reads as watch names
# rather than part numbers. The '#' is the separator, so a name may not contain
# one; ™ and ® are dropped because they add nothing at this size.
$labelFor = @{}
if (-not $NoAssetLabels) {
    foreach ($d in $devices) {
        $labelFor[$d.File] = (($d.Name -replace '[™®#]', '') -replace '\s+', ' ').Trim()
    }
}

$ghArgs = @(
    'release', 'create', $tag,
    '--target', $sha,
    '--title', "$AppName $ver",
    '--notes-file', $notesPath
)
if ($PreRelease) { $ghArgs += '--prerelease' }
if ($Draft)      { $ghArgs += '--draft' }
$ghArgs += @($assets | ForEach-Object {
    if ($labelFor.ContainsKey($_)) { "$_#$($labelFor[$_])" } else { $_ }
})

Push-Location $RepoRoot
try {
    & gh @ghArgs
    if ($LASTEXITCODE -ne 0) { throw "gh release create failed (exit $LASTEXITCODE)" }
} finally { Pop-Location }

Write-Host ''
Write-Host "Released $tag - $built device build(s), stamp $ver" -ForegroundColor Green
if ($Draft) {
    Write-Host 'Draft: review and publish it on GitHub.' -ForegroundColor Cyan
    # The notes are composed before the release exists, so the device table
    # links to releases/download/<tag>/<asset>. GitHub does not create the tag
    # until the draft is published, and until then it serves the assets under a
    # placeholder - releases/download/untagged-<hash>/<asset>. So every link in
    # the table 404s while the draft is being reviewed and starts working the
    # moment it goes live. Nothing to fix; it just looks broken.
    Write-Dim "Links in the device table 404 until you publish - GitHub creates the tag"
    Write-Dim "$tag then. While it is a draft the assets sit under an 'untagged-<hash>' url."
    Write-Dim "Publish under $tag exactly, or those links point at a tag that never exists."
}
Write-Dim "Local copy: $OutDir"
