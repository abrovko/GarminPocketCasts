# Pocket Casts for Garmin (Unofficial)

A Garmin Connect IQ **audio content provider** app, written in Monkey C, that syncs your
Pocket Casts playlists to the watch over Wi-Fi and plays them back offline — no phone
required once the episodes have landed.

Unaffiliated with Pocket Casts / Automattic. It talks to the same unofficial web-player API
the Pocket Casts web app uses, which can change without notice.

- **App type:** `audio-content-provider-app`, `minApiLevel 5.0.0`
- **Targets:** 57 products declared in `watch/manifest.xml`; developed and tested on **fēnix 7X**
  and **fēnix 8 (47/51 mm)**

## Features

- Sign in with your Pocket Casts account **on the watch**
- Sync **Up Next** plus any of your **manual playlists** (smart playlists carry no episode
  list and are skipped)
- One-tap *Get new episodes*: refresh, download, land on the episodes it just fetched
- Playback order follows your queue
- Bidirectional **playback position sync** — pick up on the watch where the phone left off,
  and vice versa.
- Finished episodes are reported as played, drop off the list, and their audio is reclaimed
- Podcast-shaped transport controls: skip forward 30 s / back 10 s, no whole-track skipping
- Optional **playback speed** (1.0×–2.0×) and smaller downloads, via a self-hosted
  transcoding proxy — see [`proxy/`](proxy/)

## Using it on the watch

The app appears as a music source: **Music → sources → Pocket Casts (Unofficial)**. That
entry point is the hub, and everything else hangs off it.

1. **First run — sign in.** Anything reaching the app without working credentials lands on
   the sign-in screen. With your phone in range the text picker opens a keyboard **on the
   phone**; otherwise it is the on-watch character wheel. Email and password are kept in the
   watch's encrypted app storage.
2. **Pick your playlists.** *Settings → Select playlists* fetches your playlists (Up Next
   pinned first, then manual playlists) and shows them as toggles. Ticking one means
   "download everything in it". Backing out commits and starts the sync; *Download now* does
   the same explicitly.
3. **Every day after that — one tap.** *Get new episodes* on the hub refreshes and syncs in
   one go, landing on the episodes it just downloaded. Nothing new gets you *Up to date*
   rather than a screen full of toggles.
4. **Listen.** The hub lists downloaded episodes; a started one reads `23m left — Podcast
   Name`. Pick one to play. Finished episodes leave the list, and their audio is reclaimed at
   the next non-playback entry into the app.

Episodes clear themselves three ways: finishing one on the watch removes it, and a refresh
releases anything no ticked playlist still wants — so an episode you finish on your phone drops
off the watch the next time you fetch new ones. *Settings → Delete episodes* removes one by
hand for anything neither covers.

*Settings* also holds **Account** (change account / sign out — downloads keep playing),
**Playback speed** (see below) and **Reset everything** (wipes downloads, playlists and the
account; the next launch behaves like a fresh install).

### Playback speed

The watch has no playback speed control of its own, so faster-than-normal playback needs the
audio to arrive already sped up. [`proxy/`](proxy/) holds a small self-hosted service that does
that — it fetches an episode, runs it through ffmpeg and streams the result to the watch.
Deploying it takes about ten minutes on Google Cloud Run and stays inside the free tier;
`proxy/README.md` has the steps.

Once it is configured under *Settings → Playback speed*, downloads run through it at your
chosen speed (1.0×, 1.25×, 1.5×, 1.75× or 2.0×) and quality (64k/96k mono or 128k stereo).

- **Smaller downloads are the bigger win.** Re-encoding to 64 kbps mono makes an episode about
  three times smaller, and 1.0× is a valid setting if that is all you want.
- **Positions stay in the episode's own timeline**, so what the phone shows and what the watch
  shows agree regardless of speed. Skip forward and back move by the same amount of episode
  they always did.
- **It is optional and fails soft.** With no proxy configured nothing changes, and if a
  configured proxy cannot be reached the sync fetches the episode straight from its podcast
  CDN at full size instead.

### What you need connected, and when

| Step | Link |
| --- | --- |
| Refreshing the playlist / episode list | **Phone** (BLE) — Connect IQ only routes web requests through the phone outside sync mode |
| Downloading episode audio | **Wi-Fi** — a known network in range |
| Playback | nothing; it is all on the watch |

Entering the proxy address and token needs the phone in range too — the text picker opens a
keyboard on the phone. How much it accepts is up to the watch: a fēnix 7 stops at 31
characters, a fēnix 8 takes 256. The setup instructions ask for a short hostname and a
22-character token so that they fit either; if your watch has the roomier picker you are free
to use longer ones, bearing in mind that every watch you set the proxy up on has to be able to
type the same token.

The address is entered without `https://` — the watch assumes it — so those eight characters
never count against the limit. An explicit `http://` or `https://` is accepted too if you
prefer to type it.

## Getting it onto a watch

Two ways in, and they are not equally safe.

- **Build it yourself** — [Build](#build), then [Deploy to a watch](#deploy-to-a-watch). It
  needs the free Connect IQ SDK and a developer key, and takes a few minutes.
- **Download a prebuilt `.zip`** from [Releases](../../releases). One archive per device,
  each labelled with the watches it covers, plus a table in the release notes mapping
  Connect IQ device ids to real model names. Inside is a `GARMIN` folder you drag onto the
  watch as-is:

  ```
  GARMIN/APPS/GarminPocketCasts.prg
  GARMIN/APPS/LOGS/GarminPocketCasts.TXT         (empty — see below)
  GARMIN/Debug/GarminPocketCasts.prg.debug.xml
  ```

  The empty `.TXT` is deliberate and worth keeping: the watch only writes the app's log if
  that file already exists, so without it there is nothing to attach to a bug report. The
  `.prg.debug.xml` is what turns a crash log into readable line numbers, and only the copy
  built alongside that exact binary will do it.

### Sideloading is at your own risk

The prebuilt archives are built on a personal machine and signed with a personal developer key.
Sideloading bypasses the Connect IQ store, so **nothing in a release has been reviewed by
Garmin**, and this app handles your Pocket Casts email and password.

Installing a binary from someone else is a decision, not a formality:

- **Read the source before you trust it.** All of it is here under
  [MPL-2.0](LICENSE). The network calls live in `watch/source/PocketCastsClient.mc` (the Pocket
  Casts API) and `watch/source/Proxy.mc` (your own transcoding proxy, if you set one up); the watch
  app has no third-party libraries beyond the Connect IQ SDK itself, so that is the whole of
  what there is to audit.
- **Better still, build it yourself** and skip the question entirely. That is what the rest of
  this README documents.
- **`SHA256SUMS.txt` proves a download arrived intact, nothing more.** It confirms the file
  matches what was uploaded to the release. It cannot tell you the file is safe.

The licence disclaims all warranties, and that is meant literally: you install these files,
on your own hardware, at your own risk.

## Repository layout

```
watch/      the Connect IQ app — manifest, jungle, Monkey C source, resources
proxy/      optional self-hosted transcoding service (Python, Cloud Run)
tools/      build, deploy and release automation (PowerShell)
tests/api/  contract tests against the Pocket Casts API — not tests of the app
docs/       design and security notes
```

`watch/` is self-contained and is the folder to open in VS Code. `proxy/` is an entirely
separate deliverable that the app does not need in order to build, run or work.

## Requirements

- [Connect IQ SDK](https://developer.garmin.com/connect-iq/sdk/) 9.x (developed against 9.2.0)
- A Connect IQ **developer key** — `monkeyc` cannot build without one
- Windows + PowerShell for the deploy script (the build itself is platform-independent)
- Optional: VS Code with the official **Monkey C** extension

## Build

The SDK path is recorded by the SDK manager in `current-sdk.cfg` — read it rather than
hardcoding a version:

```powershell
$SDK = (Get-Content "$env:APPDATA\Garmin\ConnectIQ\current-sdk.cfg" -Raw).Trim() + "bin"
$KEY = $env:GARMIN_DEVELOPER_KEY     # or the path to your key, wherever it lives
```

The Connect IQ project lives in `watch/`, so that is where the jungle is and where the build
output lands. Paths inside a jungle resolve against the jungle file, so these run from the
repository root:

```powershell
# Debug build — simulator only
& "$SDK\monkeyc.bat" -o watch\bin\GarminPocketCasts.prg -f watch\monkey.jungle -y $KEY -d fenix7x -w -l 3

# Release build — required for real hardware
& "$SDK\monkeyc.bat" -o watch\bin\release\GarminPocketCasts.prg -f watch\monkey.jungle -y $KEY -d fenix7x -r -w -l 3

# Export build — compiles every product in the manifest, the only way to catch a
# device-specific break
& "$SDK\monkeyc.bat" -e -o watch\bin\GarminPocketCasts.iq -f watch\monkey.jungle -y $KEY -w -l 3
```

Opening the repository root in VS Code will **not** find the project: the Monkey C extension
looks for `monkey.jungle` in the folder you opened. Open `watch/` instead — the palette
commands (*Edit Products*, *Edit Application*) look for `manifest.xml` the same way.

**Building by hand leaves the build stamp alone.** `tools\Deploy-Watch.ps1` rewrites
`watch/source/BuildInfo.mc` with a `yyMMdd-HHmmss` stamp immediately before every release build, so
the *Build* row in the app's Settings menu names the binary you are running. A plain `monkeyc`
does not, so a hand-built `.prg` keeps whatever `STAMP` currently says. If you are going to
sideload it, edit that constant first — the stamp is the only way to tell which binary the
watch is actually running:

```monkeyc
module BuildInfo {
    const STAMP = "dev";      // <- put something recognisable here
}
```


## Deploy to a watch

### With the script

`tools\Deploy-Watch.ps1` does the entire round trip over MTP: stamp the build, build
release, pull the previous run's logs into `logs\<timestamp>\`, clear them on the device,
copy the `.prg` to `GARMIN/APPS/` and the `.prg.debug.xml` to `GARMIN/Debug/`.

```powershell
.\tools\Deploy-Watch.ps1                       # build + deploy + rotate logs
.\tools\Deploy-Watch.ps1 -Target fenix847mm    # another device (default: fenix7x)
.\tools\Deploy-Watch.ps1 -NoBuild              # deploy whatever is in bin\release
.\tools\Deploy-Watch.ps1 -PullOnly             # after a test run: fetch logs, then clear them
.\tools\Deploy-Watch.ps1 -KeepLogs             # leave the device logs alone
```

The script finds your developer key from `-DeveloperKey <path>`, else the
`GARMIN_DEVELOPER_KEY` environment variable, else `%APPDATA%\Garmin\ConnectIQ\developer_key`.
Setting it once is the least friction:

```powershell
setx GARMIN_DEVELOPER_KEY C:\path\to\developer_key
```

### Check the build stamp before restarting anything

**Most of the time the watch picks the new `.prg` up by itself** — but not always, and the
pattern is not clear, so now and then it keeps running the old binary after a copy. Restarting
the watch always fixes that, and it is slow, so make it the last resort rather than the first
step.

Open the app and read the last row of its **Settings** menu: it shows the build stamp compiled
into the binary that is running. The deploy script prints the same stamp when it finishes
(when building by hand, it is whatever you put in `BuildInfo.STAMP`).

- **Stamps match** → the new build is live, nothing else to do.
- **Stamp is the old one** → then restart the watch. Nothing over USB can trigger a restart,
  and the watch does not restart on unplug either, so it has to be done from the watch.

### By hand

Everything the script does can be done in Explorer. The watch exposes **no mass-storage
volume** — it mounts as an MTP device, so `Copy-Item`, `robocopy` and friends cannot see it
and you drag files in Explorer instead (that is also why the script drives the Windows Shell
COM namespace rather than the filesystem).

1. **Build the release `.prg`** with the release command above. The debug build may not
   start on hardware.
2. **Set a build stamp** in `watch/source/BuildInfo.mc` before that build if you want to be able to
   tell this binary from the last one (see above).
3. **Plug the watch in** over USB and open it in Explorer — *This PC → \<your watch\> →
   Internal Storage → GARMIN*.
4. **Copy `watch\bin\release\GarminPocketCasts.prg` into `GARMIN\APPS\`**, overwriting any earlier
   copy.
5. **Copy `watch\bin\release\GarminPocketCasts.prg.debug.xml` into `GARMIN\Debug\`** (create the
   folder if it is missing). It has to be the symbol file for *this* build — a stale one, or
   none, means crash stacks come back empty.
6. **Make sure `GARMIN\APPS\LOGS\GarminPocketCasts.TXT` exists.** Create an empty file of that
   exact name locally and drag it over; the name must match the `.prg`. Without it every
   `System.println()` is silently discarded. This and previous steps are only needed if you are
   planning to troubleshoot or report issues
7. **Verify the copies landed.** A silent no-op is the normal MTP failure — check in Explorer
   that each file's size and timestamp actually changed. (The script size-checks every copy
   for this reason.)
8. **Unplug and open the app**, then check the build stamp on its Settings menu against what
   you just built — see above. Only restart the watch if it still names the old build.



### Logs

| File | What it holds |
| --- | --- |
| `GARMIN\APPS\LOGS\GarminPocketCasts.TXT` | `System.println()` output — **must already exist as an empty file** or output is discarded |
| `GARMIN\APPS\LOGS\CIQ_LOG.YML` | App crashes |
| `GARMIN\Debug\ERR_LOG.txt` | Device-level crashes (firmware addresses only) |

Copy them off in Explorer to read them. **Delete the log between test runs** — it appends, and
stale entries are easy to mistake for the current run; then put the empty
`GarminPocketCasts.TXT` stub back, or the next run logs nothing. Logs rotate to `.BAK` at 5 KB.
`.\tools\Deploy-Watch.ps1 -PullOnly` does the pull, the delete and the stub in one go.

## License

[Mozilla Public License 2.0](LICENSE).
