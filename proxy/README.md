# Playback-speed transcoding proxy

The watch has no playback speed control — Connect IQ's media player does not offer one and
`Media.PlaybackProfile` has no field for it. This service makes speed possible by sending the
audio down already sped up.

It is a single Python file. It pulls an episode from its podcast CDN, pipes it through
ffmpeg's `atempo` filter, and streams the re-encoded MP3 back as the response body. Nothing is
written to disk and nothing is kept between requests.

**It is optional.** With no proxy configured the app behaves exactly as it does without one,
and if a configured proxy cannot be reached the sync retries the episode straight from its CDN
at full size. A proxy that is down costs you speed, never episodes.

## Why to use it even at 1.0×

Re-encoding to 64 kbps mono makes an episode about three times smaller. Against a real
39-minute episode (37,190,068 bytes) and the app's measured download throughput of ~25 KB/s on
battery and ~150 KB/s on the charger:

| Configuration | Size | Charging | Battery |
| --- | --- | --- | --- |
| unproxied — 1.0× / 128k stereo | 37.2 MB | 4 min | 25 min |
| 1.0× / 64k mono | 18.7 MB | 2 min | 12 min |
| 1.5× / 64k mono | 12.5 MB | 83 s | 8 min |
| 2.0× / 64k mono | 9.4 MB | 63 s | 6 min |

`speed: 100` is a valid setting: it takes the size reduction and leaves the audio alone.

## Cost

At a few episodes a day this stays inside Google Cloud's free tier. There is no bucket, no
database and no always-on instance — the container starts on the first request and scales to
zero when you stop syncing. The request is held open for the whole download, so an 8-minute
transfer on watch battery is 8 minutes of instance time.

## Deploy

You need the [gcloud CLI](https://cloud.google.com/sdk/docs/install) and a GCP project with
billing enabled. Both shells are given for every step.

**PowerShell**

```powershell
$PROJECT = "your-project-id"
$REGION  = "europe-west1"     # pick one near you
gcloud config set project $PROJECT

gcloud services enable run.googleapis.com cloudbuild.googleapis.com secretmanager.googleapis.com
```

**bash**

```bash
export PROJECT=your-project-id
export REGION=europe-west1
gcloud config set project "$PROJECT"

gcloud services enable run.googleapis.com \
                       cloudbuild.googleapis.com \
                       secretmanager.googleapis.com
```

### 1. Mint a token

The bearer token is the only thing protecting the service. Generate it; do not choose it, and
do not commit it.

**Use 16 bytes unless you know your watch takes more.** The watch's text picker caps entry at a
length the *device* chooses, and it is not one number — measured at **31 characters on a fēnix 7
and 256 on a fēnix 8**. 32 random bytes base64url-encode to 43, which a fēnix 7 cannot accept;
16 bytes give a 22-character token, which every watch can.

If the only watch you will ever set this up from has a roomy picker, use 32 bytes — it is
strictly better and costs nothing. Just know the trade: **the token has to be typed on every
watch that uses the proxy**, so a 43-character one locks out any watch with a 31-character
picker, and the only symptom there is a 401. There is no way to find a device's cap except to
try it. When in doubt, 16 bytes.

**Write the token to a file with `WriteAllText`, not through a pipe.** Piping appends a line
ending — CRLF on Windows — and the stored secret then fails every comparison with a 401 that
gives no indication why.

**PowerShell**

```powershell
$bytes = [byte[]]::new(16)
[System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
$TOKEN = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
$TOKEN     # you type this into the watch later

$tmp = Join-Path $env:TEMP "pc-proxy-token.txt"
[System.IO.File]::WriteAllText($tmp, $TOKEN, [System.Text.UTF8Encoding]::new($false))
gcloud secrets create pocketcasts-proxy-token --data-file="$tmp"
Remove-Item $tmp
```

**bash**

```bash
TOKEN=$(python3 -c "import secrets; print(secrets.token_urlsafe(16))")
echo "$TOKEN"

printf '%s' "$TOKEN" | gcloud secrets create pocketcasts-proxy-token --data-file=-
```

To rotate a token later, use `versions add` instead of `create`. The service picks up the new
value on its next deploy, since `--set-secrets` pins `:latest`.

Grant the Cloud Run runtime service account read access:

**PowerShell**

```powershell
$NUM = gcloud projects describe $PROJECT --format "value(projectNumber)"
gcloud secrets add-iam-policy-binding pocketcasts-proxy-token `
  --member "serviceAccount:$($NUM)-compute@developer.gserviceaccount.com" `
  --role roles/secretmanager.secretAccessor
```

Write `$($NUM)-compute`, not `$NUM-compute` — a PowerShell variable name ends at the hyphen.

**bash**

```bash
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')
gcloud secrets add-iam-policy-binding pocketcasts-proxy-token \
  --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --role=roles/secretmanager.secretAccessor
```

### 2. Deploy

**Name the service `pc`.** The watch's text picker can cap entry at as few as 31 characters (see
[Mint a token](#1-mint-a-token) — it is device-dependent), and the service name is the only part
of a Cloud Run hostname you control. On Cloud Run's classic URL
(`<service>-<hash>-<regioncode>.a.run.app`) the tail after the name is a fixed 24 characters,
so to fit in 31 the name must be 7 characters or fewer:

```
pocketcasts-speed-a1b2c3d4e5-wl.a.run.app     41   too long
pc-a1b2c3d4e5-wl.a.run.app                    26   fits
```

From this `proxy/` directory:

**PowerShell**

```powershell
gcloud run deploy pc `
  --source . `
  --region $REGION `
  --allow-unauthenticated `
  --memory 512Mi --cpu 1 `
  --timeout 3600 `
  --concurrency 4 --max-instances 2 `
  --set-secrets PROXY_TOKEN=pocketcasts-proxy-token:latest
```

A backtick continuation fails if any whitespace follows it, with an unrelated-looking error.
Put the command on one line if it misbehaves.

**bash**

```bash
gcloud run deploy pc \
  --source . \
  --region "$REGION" \
  --allow-unauthenticated \
  --memory 512Mi --cpu 1 \
  --timeout 3600 \
  --concurrency 4 --max-instances 2 \
  --set-secrets PROXY_TOKEN=pocketcasts-proxy-token:latest
```

Three flags are load-bearing:

- **`--timeout 3600`** — the request stays open for the whole download. The 300 s default cuts
  it off mid-episode.
- **`--allow-unauthenticated`** — the watch cannot do Google OAuth, so Cloud Run IAM cannot
  gate it. The bearer token is the gate.
- **`--max-instances 2`** — a cost ceiling.

`--no-cpu-throttling` is not needed: all the work happens inside a request handler, which is
when Cloud Run allocates CPU.

### 3. Check the address fits

```powershell
$URL = gcloud run services describe pc --region $REGION --format "value(status.url)"
$URL
($URL -replace '^https://','').Length      # must fit your watch's picker
```

You type the address **without** `https://` — the watch assumes it — so this is the number that
has to fit. A two-character service name on a classic `*.a.run.app` URL gives about 26, which
fits even a 31-character picker.

If your project uses the newer `<service>-<hash>.<region>.run.app` form, the region is spelled
out in full and even a two-character name lands in the mid-thirties. On a watch with a roomy
picker (a fēnix 8 takes 256) that is simply fine, and you can stop here. On a 31-character one,
map a short subdomain onto the service with `gcloud beta run domain-mappings create` and use
that instead.

There is no way to query a device's cap, so if you are unsure: type the address in, and if the
picker stops accepting characters part-way through, it is too long.

### 4. Verify it works

`curl` on Windows PowerShell 5.1 is an alias for `Invoke-WebRequest`. Type **`curl.exe`**.

**PowerShell**

```powershell
$URL = "https://pc-a1b2c3d4e5-wl.a.run.app"
$TOKEN = "your token"
$H = @{ Authorization = "Bearer $TOKEN"; "Content-Type" = "application/json" }

(Invoke-WebRequest "$URL/health").Content        # -> ok

# auth, ffmpeg and streaming in one call, no podcast involved
curl.exe -sS "$URL/selftest.mp3" -H "Authorization: Bearer $TOKEN" -o selftest.mp3
(Get-Item selftest.mp3).Length                   # ~40000

# a real episode
$body = '{"url":"https://example.com/episode.mp3","speed":150,"bitrate":64,"mono":true}'
curl.exe -sS -X POST "$URL/transcode" `
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" `
  -d $body -o out.mp3 `
  -w "http=%{http_code} ttfb=%{time_starttransfer}s size=%{size_download}`n"

Invoke-WebRequest "$URL/transcode" -Method POST -SkipHttpErrorCheck `
  -Headers @{ Authorization = "Bearer wrong" } -Body '{}'          # -> 401
Invoke-WebRequest "$URL/transcode" -Method POST -SkipHttpErrorCheck -Headers $H `
  -Body '{"url":"http://169.254.169.254/latest/meta-data/"}'       # -> 400
Invoke-WebRequest "$URL/transcode" -Method POST -SkipHttpErrorCheck -Headers $H `
  -Body '{"url":"https://example.com/gone.mp3"}'                   # -> 502
```

`-SkipHttpErrorCheck` needs PowerShell 7.

**bash**

```bash
URL="https://pc-a1b2c3d4e5-wl.a.run.app"
TOKEN="your token"

curl -sS "$URL/health"
curl -sS "$URL/selftest.mp3" -H "Authorization: Bearer $TOKEN" -o selftest.mp3

curl -sS -X POST "$URL/transcode" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"url":"https://example.com/episode.mp3","speed":150,"bitrate":64,"mono":true}' \
  -o out.mp3 -w 'http=%{http_code} ttfb=%{time_starttransfer}s size=%{size_download}\n'

ffprobe out.mp3      # duration = source duration / speed
```

Expect:

- `ttfb` of a second or two — most of it opening the source. A minute means ffmpeg is
  buffering instead of streaming.
- Output about a third of the source at 1.5× / 64k mono, with `ffprobe` reporting the source
  duration divided by the speed.
- 401 on a bad token, 400 on a private address, 502 on a dead source.
- No ffmpeg process left behind after `Ctrl-C` mid-download — the Cloud Run log line
  `streamed N bytes` confirms the cleanup ran.

### 5. Point the watch at it

Playback hub → *Settings* → *Playback speed*, then *Server* and *Token*. With the phone in
range the picker opens a keyboard on the phone, so both can be pasted.

Type the **hostname only** — `pc-a1b2c3d4e5-wl.a.run.app`, not `https://pc-…`. The scheme is
assumed. An explicit `http://` is honoured for a proxy on your own network, and trailing
slashes are stripped. The 22-character token from step 1 fits the picker.

*Speed* and *Quality* live on the watch and cycle in place with one tap.

Connect IQ app settings are shipped but do nothing on a sideloaded install: Garmin renders that
page from an app's store listing, not from the `.prg` on the watch.

## API

```
POST /transcode                  Authorization: Bearer <token>
     {"url": "...", "speed": 150, "bitrate": 64, "mono": true}

 200 audio/mpeg, Transfer-Encoding: chunked
     X-Speed: 150
 400 {"error": "speed must be between 50 and 300"}
 401 {"error": "unauthorized"}
 502 {"error": "source fetch failed: ..."}

GET|POST /selftest.mp3           Authorization: Bearer <token>
 200 audio/mpeg — five seconds of generated tone, ~40 KB

GET /health
 200 ok
```

`speed` is an integer percentage: 150 means 1.5×. Out-of-range values are rejected, never
clamped — the watch records the speed against the downloaded episode and divides every
playback position by it, so a substituted value would corrupt that episode's resume position.

`bitrate` is one of 32, 48, 64, 96, 128, 160, 192 kbps and defaults to 64. `mono` defaults to
true. Both may be omitted.

The episode URL travels in the request body, so there is no query string and the service keeps
no state between requests.

## Run it locally

Docker needs neither ffmpeg nor Python installed:

```
docker build -t pcspeed .
docker run --rm -p 8080:8080 -e PORT=8080 -e PROXY_TOKEN=dev-token pcspeed
```

Then run the step 4 checks against `http://localhost:8080`.

Without Docker, with ffmpeg on your PATH:

**PowerShell**

```powershell
pip install -r requirements.txt
$env:PROXY_TOKEN = "dev-token"
python main.py
```

**bash**

```bash
pip install -r requirements.txt
PROXY_TOKEN=dev-token python main.py
```

## Implementation notes

- **`-write_xing 0`.** A pipe is not seekable, so ffmpeg cannot return to fill in a Xing
  header's frame count, and writing one leaves a header of zeros that reads as a zero-length
  episode. Output is CBR, so decoders derive duration from bitrate and file size.
- **The first chunk is read before the response is committed.** ffmpeg exits immediately on an
  unusable source, after the handler has returned; without this the caller gets a 200 with an
  empty body, which on the watch becomes a `ContentRef` for a zero-byte episode.
- **Reconnect flags are passed only for http(s) inputs.** They belong to the protocol handler,
  not to ffmpeg globally, and any other input fails with `Option reconnect not found`. The
  two whitelists and `-max_redirects 0` sit in the same branch, for the same reason.
- **The redirect chain is resolved before ffmpeg starts**, one `Range: bytes=0-0` GET per hop,
  each hop address-checked. That costs a round trip on `ttfb`, and is what makes
  `-max_redirects 0` safe. A probe that fails for its own reasons — a 403, a refused
  connection — is not fatal: the url is handed over as-is, already validated, and ffmpeg
  reports whatever it finds.
- **stderr is drained on a thread.** If that pipe fills while nobody reads it, ffmpeg blocks
  writing while the server blocks reading stdout, and the request hangs.
- **ffmpeg is killed in a `finally`.** A client disconnect closes the generator; without the
  reap, every severed download leaks a process.
- **A failure after the first byte cannot be reported.** The response is committed at 200, so a
  source that dies mid-stream reaches the watch as a truncated download.

## Security

- **The bearer token is the gate, but it is not the only barrier that matters.** Keep it in
  Secret Manager and do not commit it; the service refuses every request when `PROXY_TOKEN` is
  unset rather than standing open. Note that the url it fetches comes from the episode
  enclosure in a podcast's own feed, so a compromised podcast can influence the outbound fetch
  without holding the token — which is why the checks below exist rather than resting on it.
- **Every hop of the redirect chain is checked to resolve to a public address**, and ffmpeg is
  handed the final url with `-max_redirects 0`, so there is nothing left for it to follow.
  Checking only the submitted url would have been the wrong guard: libavformat follows 3xx
  itself, and a public host answering `302 Location: http://10.128.0.7:8080/` would have gone
  wherever it pointed.
- **`-format_whitelist mp3,mov,mp4,m4a,aac,wav,ogg,flac`** is what shuts off HLS. The input
  demuxer is chosen by sniffing the body, so an `#EXTM3U` response would otherwise open the HLS
  demuxer and fetch every variant and segment uri it names, unchecked. **The protocol whitelist
  does not stop this** — measured, not assumed: HLS segments travel over plain `http`, which
  has to be on the protocol list anyway, so only refusing the demuxer closes it.
- **`-protocol_whitelist http,https,tcp,tls`** earns everything that is *not* http: `file:`,
  `concat:`, `data:`, `subfile:`. All four entries are needed — libavformat nests protocols and
  checks each layer against this list, so `https` opens a `tls://` of its own and `tls` a
  `tcp://` under that. The usual fifth, `crypto`, is deliberately absent: it is HLS's AES-128
  segment decryption, part of what is being switched off.
- The address check remains time-of-check/time-of-use — ffmpeg resolves the name again itself —
  which is accepted for a single-user service behind a token.
- **A dead source answers a bare `source fetch failed`.** ffmpeg's stderr names the target and
  the failure mode, and returning it would let anyone with the token enumerate internal hosts
  and ports off the 502 bodies. It is kept in the Cloud Run log instead.
- **Nothing runs as root.** The image adds an unprivileged `proxy` user, because ffmpeg parses
  media this service does not control. Cloud Run's gVisor sandbox is the real boundary; this is
  defence in depth behind it.
- Output is capped at 200 MB and 6 hours per request.
- The service re-encodes podcast audio you already have access to and retains none of it.
  Keep the token to yourself.
