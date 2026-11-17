# Building and deploying on macOS

The [README](../README.md) build and deploy steps are written for Windows. On a Mac, the build
only differs in paths. `tools/Deploy-Watch.ps1` is Windows-only, so this page copies files to
the watch with the stock [libmtp](https://github.com/libmtp/libmtp) command-line tools instead.
Run every command from the repository root.

Tested on a Forerunner 265S with SDK 9.3.0 and libmtp 1.1.23.

## Requirements

- [Connect IQ SDK Manager](https://developer.garmin.com/connect-iq/sdk/), with SDK 9.3.0 or
  newer. Under **Devices**, choose **Download All**. `monkey.jungle` names every product in the
  manifest, so the build fails with *not a valid device* if any profile is missing.
- Java on the `PATH`, because `monkeyc` is a Java tool
- libmtp: `brew install libmtp`
- A developer key. If you don't have one yet:

  ```bash
  mkdir -p ~/.garmin && cd ~/.garmin
  openssl genrsa -out developer_key.pem 4096
  openssl pkcs8 -topk8 -inform PEM -outform DER -in developer_key.pem -out developer_key.der -nocrypt
  ```

  Keep it safe: updates to an installed app must be signed with the same key.

## Build

```bash
SDK="$(tr -d '\n' < ~/Library/Application\ Support/Garmin/ConnectIQ/current-sdk.cfg)bin"
KEY=~/.garmin/developer_key.der

# Release build, required for real hardware. Replace fenix7x with your device id.
"$SDK/monkeyc" -o watch/bin/release/GarminPocketCasts.prg -f watch/monkey.jungle -y "$KEY" -d fenix7x -r -w -l 3
```

For the README's debug and export builds, use `"$SDK/monkeyc"` instead of `monkeyc.bat`, and
`/` instead of `\`. Set `STAMP` in `watch/source/BuildInfo.mc` before you build, as the README
describes, so that you can tell which binary the watch is running.

## Deploy

The watch connects over MTP, so neither Finder nor `cp` can see it. `mtp-connect` runs several
commands in one session, and each command takes `source,destination`. Device paths must start
with `/`. Folder names ignore case, so `/GARMIN/APPS` also finds `Garmin/Apps`.

1. Quit Garmin Express and any other MTP app, such as OpenMTP. Only one program can use the
   watch at a time.
2. Plug the watch in.
3. Replace the app. MTP does not overwrite files, so delete the old copies first. Otherwise a
   second copy appears next to each one.

   ```bash
   export LANG=en_US.UTF-8          # silences libmtp's locale warning
   killall ptpcamerad 2>/dev/null   # see "No devices" below
   mtp-connect \
     --delete   /GARMIN/APPS/GarminPocketCasts.prg \
     --delete   /GARMIN/Debug/GarminPocketCasts.prg.debug.xml \
     --sendfile watch/bin/release/GarminPocketCasts.prg,/GARMIN/APPS \
     --sendfile watch/bin/release/GarminPocketCasts.prg.debug.xml,/GARMIN/Debug
   ```

   Each `--sendfile` should print *New file ID*. On a first deploy, each `--delete` prints
   *Failed to remove file* because there is nothing to delete yet. That is harmless.
4. On a first deploy, also add the empty log stub. The watch writes no app log without it (see
   the README's [Logs](../README.md#logs)). Later, the same command resets the log:

   ```bash
   touch watch/bin/GarminPocketCasts.TXT
   mtp-connect \
     --delete   /GARMIN/APPS/LOGS/GarminPocketCasts.TXT \
     --sendfile watch/bin/GarminPocketCasts.TXT,/GARMIN/APPS/LOGS
   ```

5. Check that each file landed, with the same size as in `ls -l watch/bin/release`. MTP
   sometimes skips a copy without an error.

   ```bash
   mtp-files 2>/dev/null | grep -E -A1 'Filename: GarminPocketCasts\.(prg|TXT)'
   ```

6. Unplug the watch and open the app. The *Build* row in Settings should show your stamp. If it
   shows the old one, restart the watch.

### "No devices", or the watch disappears mid-command

The macOS service `ptpcamerad`, which Image Capture and Photos use, can take over an MTP device,
and `launchd` restarts it after it is killed. A single `killall ptpcamerad` before
`mtp-connect`, as above, is usually enough. If it is not, run this loop in a second terminal
while you work:

```bash
while :; do killall ptpcamerad 2>/dev/null; sleep 1; done
```

## Logs

The README's [Logs](../README.md#logs) table explains each file. To copy them into `logs/`,
which git ignores:

```bash
mkdir -p logs
killall ptpcamerad 2>/dev/null
mtp-connect \
  --getfile /GARMIN/APPS/LOGS/GarminPocketCasts.TXT,logs/GarminPocketCasts.TXT \
  --getfile /GARMIN/APPS/LOGS/CIQ_LOG.YML,logs/CIQ_LOG.YML \
  --getfile /GARMIN/Debug/ERR_LOG.txt,logs/ERR_LOG.txt
```

If a file is not on the watch, it is skipped without an error: its *Get file* line has no
*Getting* line after it. Once you have the copies, reset the app log with the command from
deploy step 4, so that the next run starts with an empty log.
