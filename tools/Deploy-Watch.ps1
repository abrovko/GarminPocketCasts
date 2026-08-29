<#
.SYNOPSIS
    Build a release .prg and sideload it to a Garmin watch over MTP.

.DESCRIPTION
    fenix 7X exposes no mass-storage volume, only MTP, so there is no drive
    letter to copy to. Windows surfaces MTP through the Shell COM namespace
    ("This PC"), which is what this script drives.

    Default run: build release -> pull existing logs -> clear logs -> copy
    .prg + .prg.debug.xml -> recreate the empty log stub.

    Every copy is verified by size afterwards. This project's failure mode is
    silence, so the script refuses to report success it has not confirmed.

    The developer key is never hardcoded: it comes from -DeveloperKey, else
    $env:GARMIN_DEVELOPER_KEY, else %APPDATA%\Garmin\ConnectIQ\developer_key.

.EXAMPLE
    .\tools\Deploy-Watch.ps1
.EXAMPLE
    .\tools\Deploy-Watch.ps1 -NoBuild        # deploy whatever is in watch\bin\release
.EXAMPLE
    .\tools\Deploy-Watch.ps1 -PullOnly       # fetch logs after a test run, then clear them
.EXAMPLE
    .\tools\Deploy-Watch.ps1 -PullOnly -KeepLogs   # fetch logs and leave them on the device
#>
[CmdletBinding()]
param(
    [switch] $NoBuild,
    [switch] $PullOnly,
    [switch] $KeepLogs,
    [string] $AppName       = 'GarminPocketCasts',
    [string] $Target        = 'fenix7x',
    [string] $DevicePattern = 'fenix|garmin',
    [string] $DeveloperKey  = '',
    [int]    $TimeoutSec    = 90
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# The Connect IQ project lives in watch\ and everything it builds stays under
# it, so watch\bin is the one place build output lands whether it came from here
# or from the VS Code Monkey C extension. Log pulls are repo-level and stay at
# the root, beside docs\ and tests\.
$RepoRoot    = Split-Path -Parent $PSScriptRoot
$AppRoot     = Join-Path $RepoRoot 'watch'
$ReleaseDir  = Join-Path $AppRoot 'bin\release'
$LogPullRoot = Join-Path $RepoRoot 'logs'

function Write-Step ($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok   ($msg) { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn ($msg) { Write-Host "    $msg" -ForegroundColor Yellow }

# ---------------------------------------------------------------- build ------

# Stamp the build so a running watch can be matched against a known binary.
# Rewritten on every release build rather than hand-maintained: a constant that
# has to be remembered is a constant that goes stale, and a stale version
# number is worse than none because it is believed.
function Set-BuildStamp {
    $stamp = Get-Date -Format 'yyMMdd-HHmmss'
    $path  = Join-Path $AppRoot 'source\BuildInfo.mc'
    if (-not (Test-Path $path)) { throw "Missing $path" }

    $text = Get-Content -LiteralPath $path -Raw
    $next = [regex]::Replace($text, 'const STAMP = "[^"]*";', "const STAMP = `"$stamp`";")
    if ($next -eq $text) { throw "Could not find 'const STAMP = ...' in $path" }
    Set-Content -LiteralPath $path -Value $next -NoNewline -Encoding utf8

    Write-Ok "build stamp $stamp"
    return $stamp
}

# The developer key is per-developer and lives outside the repo, so nothing here
# may hardcode a path to it. Order: -DeveloperKey, then $env:GARMIN_DEVELOPER_KEY,
# then the spot the VS Code extension offers by default.
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

function Invoke-ReleaseBuild {
    $cfg = Join-Path $env:APPDATA 'Garmin\ConnectIQ\current-sdk.cfg'
    if (-not (Test-Path $cfg)) { throw "No current-sdk.cfg at $cfg" }
    $sdkBin  = Join-Path (Get-Content $cfg -Raw).Trim() 'bin'
    $monkeyc = Join-Path $sdkBin 'monkeyc.bat'
    if (-not (Test-Path $monkeyc)) { throw "monkeyc.bat not found at $monkeyc" }
    $key = Resolve-DeveloperKey

    New-Item -ItemType Directory -Force -Path $ReleaseDir | Out-Null
    $prg = Join-Path $ReleaseDir "$AppName.prg"

    $script:BuildStamp = Set-BuildStamp

    Write-Step "Building release $AppName.prg for $Target"
    & $monkeyc -o $prg -f (Join-Path $AppRoot 'monkey.jungle') `
               -y $key -d $Target -r -w -l 3
    if ($LASTEXITCODE -ne 0) { throw "monkeyc failed with exit code $LASTEXITCODE" }
    Write-Ok ("built {0:N0} bytes" -f (Get-Item $prg).Length)
}

# ------------------------------------------------------------------ MTP ------

# FolderItem.InvokeVerb('delete') always raises a modal "are you sure" dialog and
# gives no way to suppress it, which stalls any unattended run. IFileOperation is
# the same shell machinery with a flags argument, so FOF_NOCONFIRMATION applies.
# It has to reach the item through its PIDL: MTP display paths
# (::{20D04FE0-...}\\\?\usb#vid_...) are not valid parsing names, so
# SHCreateItemFromParsingName rejects them with E_INVALIDARG.
if (-not ('MtpIo.Ops' -as [type])) {
Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace MtpIo
{
    [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IShellItem
    {
        void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
        void GetParent(out IShellItem ppsi);
        void GetDisplayName(uint sigdnName, out IntPtr ppszName);
        void GetAttributes(uint sfgaoMask, out uint psfgaoAttribs);
        void Compare(IShellItem psi, uint hint, out int piOrder);
    }

    [ComImport, Guid("947AAB5F-0A5C-4C13-B4D6-4BF7836FC9F8"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IFileOperation
    {
        void Advise(IntPtr pfops, out uint pdwCookie);
        void Unadvise(uint dwCookie);
        void SetOperationFlags(uint dwOperationFlags);
        void SetProgressMessage([MarshalAs(UnmanagedType.LPWStr)] string pszMessage);
        void SetProgressDialog(IntPtr popd);
        void SetProperties(IntPtr pproparray);
        void SetOwnerWindow(IntPtr hwndOwner);
        void ApplyPropertiesToItem(IShellItem psiItem);
        void ApplyPropertiesToItems(object punkItems);
        void RenameItem(IShellItem psiItem, [MarshalAs(UnmanagedType.LPWStr)] string pszNewName, IntPtr pfopsItem);
        void RenameItems(object pUnkItems, [MarshalAs(UnmanagedType.LPWStr)] string pszNewName);
        void MoveItem(IShellItem psiItem, IShellItem psiDestinationFolder, [MarshalAs(UnmanagedType.LPWStr)] string pszNewName, IntPtr pfopsItem);
        void MoveItems(object punkItems, IShellItem psiDestinationFolder);
        void CopyItem(IShellItem psiItem, IShellItem psiDestinationFolder, [MarshalAs(UnmanagedType.LPWStr)] string pszCopyName, IntPtr pfopsItem);
        void CopyItems(object punkItems, IShellItem psiDestinationFolder);
        void DeleteItem(IShellItem psiItem, IntPtr pfopsItem);
        void DeleteItems(object punkItems);
        void NewItem(IShellItem psiDestinationFolder, uint dwFileAttributes,
                     [MarshalAs(UnmanagedType.LPWStr)] string pszName,
                     [MarshalAs(UnmanagedType.LPWStr)] string pszTemplateName, IntPtr pfopsItem);
        void PerformOperations();
        void GetAnyOperationsAborted([MarshalAs(UnmanagedType.Bool)] out bool pfAnyOperationsAborted);
    }

    public static class Ops
    {
        [DllImport("shell32.dll", PreserveSig = false)]
        private static extern void SHGetIDListFromObject(
            [MarshalAs(UnmanagedType.IUnknown)] object punk, out IntPtr ppidl);

        [DllImport("shell32.dll", PreserveSig = false)]
        private static extern void SHCreateItemFromIDList(
            IntPtr pidl, ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out IShellItem ppv);

        [DllImport("shell32.dll")]
        private static extern void ILFree(IntPtr pidl);

        // FOF_SILENT | FOF_NOCONFIRMATION | FOF_NOCONFIRMMKDIR | FOF_NOERRORUI
        private const uint Flags = 0x0004 | 0x0010 | 0x0200 | 0x0400;

        private static readonly Guid CLSID_FileOperation =
            new Guid("3AD05575-8857-4850-9277-11B85BDB8E09");

        /// <summary>Delete a Shell FolderItem with no confirmation UI.</summary>
        public static void Delete(object folderItem)
        {
            IntPtr pidl;
            SHGetIDListFromObject(folderItem, out pidl);
            IShellItem item;
            try
            {
                Guid iid = typeof(IShellItem).GUID;
                SHCreateItemFromIDList(pidl, ref iid, out item);
            }
            finally { ILFree(pidl); }

            var op = (IFileOperation)Activator.CreateInstance(
                         Type.GetTypeFromCLSID(CLSID_FileOperation));
            op.SetOperationFlags(Flags);
            op.SetOwnerWindow(IntPtr.Zero);
            op.DeleteItem(item, IntPtr.Zero);
            op.PerformOperations();

            bool aborted;
            op.GetAnyOperationsAborted(out aborted);
            if (aborted) throw new Exception("The shell reported the delete was aborted.");
        }
    }
}
'@
}

$Shell = New-Object -ComObject Shell.Application

function Get-MtpDevice {
    # NameSpace(17) is "This PC". MTP devices sit alongside the drives but have
    # a shell-GUID Path rather than a filesystem one.
    $thisPc = $Shell.NameSpace(17)
    if (-not $thisPc) { throw 'Could not open the "This PC" shell namespace.' }

    $candidates = @($thisPc.Items() | Where-Object { $_.IsFolder -and $_.Path -notmatch '^[A-Za-z]:\\' })
    if ($candidates.Count -eq 0) {
        throw 'No portable device found. Plug the watch in, unlock it, and wait for Windows to mount it.'
    }
    $match = @($candidates | Where-Object { $_.Name -match $DevicePattern })
    if ($match.Count -eq 1) { return $match[0] }
    if ($match.Count -gt 1) {
        throw ("Multiple devices match /$DevicePattern/: " + (($match | ForEach-Object Name) -join ', ') +
               '. Narrow it with -DevicePattern.')
    }
    if ($candidates.Count -eq 1) {
        Write-Warn "No name matched /$DevicePattern/; using the only portable device: $($candidates[0].Name)"
        return $candidates[0]
    }
    throw ("No device matched /$DevicePattern/. Candidates: " +
           (($candidates | ForEach-Object Name) -join ', '))
}

function Get-GarminRoot ($deviceItem) {
    # Some devices expose GARMIN directly, others nest it under a storage node
    # such as "Internal Storage" / "Primary".
    $root = $deviceItem.GetFolder
    $direct = $root.ParseName('GARMIN')
    if ($direct) { return $direct.GetFolder }
    foreach ($child in @($root.Items())) {
        if (-not $child.IsFolder) { continue }
        $g = $child.GetFolder.ParseName('GARMIN')
        if ($g) { return $g.GetFolder }
    }
    throw "No GARMIN folder on $($deviceItem.Name). Is the watch unlocked and finished mounting?"
}

function Get-MtpFolder ($parentFolder, [string] $relPath, [switch] $Create) {
    $cur = $parentFolder
    foreach ($seg in ($relPath -split '[\\/]' | Where-Object { $_ })) {
        $next = $cur.ParseName($seg)
        if (-not $next) {
            if (-not $Create) { return $null }
            $cur.NewFolder($seg)
            Start-Sleep -Milliseconds 400
            $next = $cur.ParseName($seg)
            if (-not $next) { throw "Could not create folder '$seg' on the device (firmware may forbid it)." }
        }
        $cur = $next.GetFolder
    }
    return $cur
}

function Get-MtpSize ($item) {
    try {
        $v = $item.ExtendedProperty('System.Size')
        if ($null -ne $v) { return [int64] $v }
    } catch { }
    return $null
}

function Remove-MtpItem ($folder, [string] $name) {
    $item = $folder.ParseName($name)
    if (-not $item) { return $false }
    [MtpIo.Ops]::Delete($item)
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 250
        if (-not $folder.ParseName($name)) { return $true }
    }
    throw "Deleted '$name' without error, but it is still listed on the device."
}

function Copy-ToDevice ($folder, [string] $localPath) {
    $file = Get-Item -LiteralPath $localPath
    Remove-MtpItem $folder $file.Name | Out-Null

    # 4 = no progress UI, 16 = answer "yes to all". The WPD shell extension
    # ignores these more often than not, hence the delete above.
    $folder.CopyHere($file.FullName, 20)

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 300
        $onDevice = $folder.ParseName($file.Name)
        if ($onDevice) {
            $size = Get-MtpSize $onDevice
            if ($null -eq $size) {
                Write-Warn "$($file.Name): copied, but the device reports no size - could not verify."
                return
            }
            if ($size -eq $file.Length) {
                Write-Ok ("{0} -> {1:N0} bytes verified" -f $file.Name, $size)
                return
            }
        }
    }
    throw "Timed out copying $($file.Name) to the device (waited $TimeoutSec s)."
}

function Copy-FromDevice ($folder, [string] $name, [string] $destDir) {
    $item = $folder.ParseName($name)
    if (-not $item) { return $false }
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    $dest = $Shell.NameSpace((Resolve-Path $destDir).Path)
    $dest.CopyHere($item, 20)

    $target = Join-Path $destDir $name
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 300
        if (Test-Path -LiteralPath $target) {
            Write-Ok ("pulled {0} ({1:N0} bytes)" -f $name, (Get-Item -LiteralPath $target).Length)
            return $true
        }
    }
    throw "Timed out pulling $name off the device."
}

function Clear-DeviceLogs ($logsFolder) {
    Write-Step 'Clearing device logs'
    foreach ($n in @("$AppName.TXT", "$AppName.BAK", 'CIQ_LOG.YML', 'CIQ_LOG.BAK')) {
        if (Remove-MtpItem $logsFolder $n) { Write-Ok "deleted $n" }
    }

    # Deleting is only half of it. Without an empty stub named after the .prg,
    # System.println output is silently discarded on the next run - so the
    # delete MUST always be followed by recreating it, on every path.
    Write-Step 'Recreating the log stub'
    $stub = Join-Path ([System.IO.Path]::GetTempPath()) "$AppName.TXT"
    Set-Content -LiteralPath $stub -Value '' -NoNewline -Encoding ascii
    Copy-ToDevice $logsFolder $stub
    Remove-Item -LiteralPath $stub -Force
}

# ----------------------------------------------------------------- main ------

if (-not $NoBuild -and -not $PullOnly) { Invoke-ReleaseBuild }

$prgLocal = Join-Path $ReleaseDir "$AppName.prg"
$symLocal = Join-Path $ReleaseDir "$AppName.prg.debug.xml"
if (-not $PullOnly) {
    foreach ($f in @($prgLocal, $symLocal)) {
        if (-not (Test-Path $f)) { throw "Missing build output: $f (drop -NoBuild?)" }
    }
}

Write-Step 'Locating the watch'
$watch = Get-MtpDevice
Write-Ok "found $($watch.Name)"

$garmin = Get-GarminRoot $watch
$apps   = Get-MtpFolder $garmin 'APPS'
if (-not $apps) { throw 'GARMIN\APPS not found on the device.' }
$logs   = Get-MtpFolder $apps 'LOGS' -Create
$debug  = Get-MtpFolder $garmin 'Debug'

# --- pull logs first: they describe the run that just happened ---------------
$stamp   = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$pullDir = Join-Path $LogPullRoot $stamp
Write-Step "Pulling logs -> logs\$stamp"
$pulled = 0
foreach ($n in @("$AppName.TXT", "$AppName.BAK", 'CIQ_LOG.YML', 'CIQ_LOG.BAK')) {
    if (Copy-FromDevice $logs $n $pullDir) { $pulled++ }
}
if ($debug) {
    foreach ($n in @('ERR_LOG.txt', 'ERR_LOG.BAK')) {
        if (Copy-FromDevice $debug $n $pullDir) { $pulled++ }
    }
}
if ($pulled -eq 0) { Write-Warn 'no logs on the device' }

if ($PullOnly) {
    # Clear here too. Logs append, so a pull that left them in place meant the
    # next pull returned the same file plus a bit more, and it was genuinely
    # hard to tell which run you were reading. -KeepLogs opts out.
    if (-not $KeepLogs) { Clear-DeviceLogs $logs }
    Write-Host ''
    Write-Host "Logs in: $pullDir" -ForegroundColor Cyan
    if (-not $KeepLogs) { Write-Host 'Device logs cleared.' -ForegroundColor DarkGray }
    return
}

# --- clear logs: stale entries have caused wrong conclusions before ----------
if (-not $KeepLogs) { Clear-DeviceLogs $logs }

# --- deploy ------------------------------------------------------------------
Write-Step 'Copying app to GARMIN\APPS'
Copy-ToDevice $apps $prgLocal

Write-Step 'Copying symbols to GARMIN\Debug'
$debug = Get-MtpFolder $garmin 'Debug' -Create
Copy-ToDevice $debug $symLocal

# Read it back out of the source rather than trusting a variable: with
# -NoBuild nothing was stamped, and this still reports what is in the binary.
$stampNow = 'unknown'
$biPath = Join-Path $AppRoot 'source\BuildInfo.mc'
if (Test-Path $biPath) {
    $m = [regex]::Match((Get-Content -LiteralPath $biPath -Raw), 'const STAMP = "([^"]*)";')
    if ($m.Success) { $stampNow = $m.Groups[1].Value }
}

Write-Host ''
Write-Host "Deployed build $stampNow" -ForegroundColor Green
Write-Host 'Now: unplug the watch and open the app.' -ForegroundColor Cyan
Write-Host "Confirm on the watch: the Settings menu's last row should read Build $stampNow." -ForegroundColor Cyan
Write-Host 'If it names an older build, restart the watch by hand - a new .prg over a' -ForegroundColor Cyan
Write-Host 'running one is not always picked up, and nothing over USB can trigger a restart.' -ForegroundColor Cyan
Write-Host 'Afterwards:  .\tools\Deploy-Watch.ps1 -PullOnly' -ForegroundColor DarkGray
