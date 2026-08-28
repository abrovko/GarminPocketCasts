# Transcoding proxy — security findings

Reviewed 2026-08-27, against `proxy/main.py` as first written and the watch-side changes that
call it. **All three are fixed, verified against a hostile origin, and deployed** — same day.
Each is kept below with the reasoning that produced it, because the fixes are only obviously
correct next to the attack they close. The "checked and fine" list at the bottom is the other
half of the value here: read it before re-investigating anything.

**The fixes are measured, not reasoned about** — see *How it was verified*. That matters here
more than usual: two of them were wrong on the first attempt in ways that a careful reading of
the ffmpeg docs did not catch, and a container caught both in a minute.

Threat model worth stating up front: the proxy is a public, internet-facing Cloud Run service
deployed `--allow-unauthenticated`, with a shared bearer token as the only authentication. It
takes a caller-supplied URL, fetches it with ffmpeg and streams the result back.

**The token is not the only barrier, and that is what makes finding 1 worth fixing.**
`GarminPocketCastsSyncDelegate.fetch()` sends `track.url` to `/transcode`, and that value comes
from the episode enclosure URL in the podcast's own feed, relayed through the Pocket Casts
playlist API. Anyone who can publish or compromise a podcast the user subscribes to can steer
the proxy's outbound fetch without ever holding the token.

---

## 1. SSRF — the public-address check does not survive redirects or playlists

**Severity: Medium.** Becomes **High** the day a VPC connector or an internal sidecar is
attached to the service. **Fixed** — `resolve_source()` in `proxy/main.py`, plus the two argv
options; see *What was done* below.

`assert_public()` (`proxy/main.py:99`) resolves and IP-checks only the URL string the caller
supplied. Nothing re-validates what ffmpeg fetches afterwards, and `ffmpeg_argv()`
(`proxy/main.py:197`) passes neither `-protocol_whitelist` nor any redirect limit — the only
`-f` in the argv is `-f mp3` on the *output* side, so the input demuxer is chosen by sniffing
the response body.

Two bypasses follow:

- **Redirects.** libavformat's HTTP protocol follows 3xx by default. A public host that answers
  `302 Location: http://10.128.0.7:8080/…` sends ffmpeg somewhere the check never saw.
- **Playlist indirection.** If the body is `#EXTM3U`, the HLS demuxer opens every variant and
  segment URI, none of which pass through `assert_public()`.

The comment on `assert_public()` acknowledges the DNS-rebinding TOCTOU risk and knowingly
accepts it. These are a different and much easier bypass that was not accounted for.

What holds it to Medium: the GCP metadata server requires a `Metadata-Flavor: Google` header
that ffmpeg will not send here, and argument injection is unreachable (`Popen` takes a list,
and the scheme check forces the string to begin `http:`/`https:`). What remains is reach into
link-local and RFC1918 space from inside the container.

### What was done

Three parts, and the second matters more than it looks:

1. **`-protocol_whitelist http,https,tcp,tls` *and* `-format_whitelist mp3,mov,mp4,m4a,aac,wav,ogg,flac`**
   in `ffmpeg_argv()`, both inside the existing `http(s)`-only branch so the function stays
   runnable against a local file — the same reason the reconnect flags are scoped there.

   **The protocol whitelist recommended above does not stop HLS, and that was measured, not
   reasoned about.** HLS segments are fetched over plain `http`, which is necessarily on the
   protocol list, so the protocol layer cannot tell a segment from the source. Against a
   hostile origin serving `#EXTM3U` naming `http://victim:9001/secret.ts`, with
   `-protocol_whitelist` in place and no format whitelist, ffmpeg fetched it and the victim
   logged `GET /secret.ts`. **`-format_whitelist` is what closes it**, by refusing to
   instantiate the `hls` demuxer at all: the same request then failed at
   `avformat_open_input` with `Invalid argument` and the victim was never contacted.

   Both are kept. What the protocol list still earns is everything that is *not* http —
   `file:`, `concat:`, `data:`, `subfile:`.

   The four protocols are each load-bearing: libavformat nests protocols and applies the
   whitelist to every layer, so the `https` handler opens a `tls://` of its own and `tls` a
   `tcp://` under that — whitelisting `https` alone yields a handler that cannot reach a
   socket. `http` is there because `assert_public()` admits plain-http sources and older feeds
   still serve them. **`crypto` was dropped** from the recommendation: it is the AES-128
   segment decryption wrapper that every HLS whitelist on the internet carries, i.e. part of
   the thing being switched off.

   Format matching is per comma-separated token on **both** sides, which is why `mp4` matches
   the mov demuxer whose name is the whole string `mov,mp4,m4a,3gp,3g2,mj2`.
2. **`resolve_source()` walks the redirect chain in Python**, calling `assert_public()` on
   every hop and returning the final URL, which is what `validate()` now puts in `p["url"]`.
   Simply adding `-follow_redirects 0` was **not** an option: podcast CDNs are built on
   redirects and that alone breaks normal downloads.
3. **`-max_redirects 0`** then goes in beside the whitelists — safe *because* of part 2, there
   is nothing left to follow. The two are a pair; neither works alone.

   **The option is `-max_redirects`, not `-follow_redirects`.** The latter does not exist, and
   ffmpeg rejects the entire argument list with `Unrecognized option 'follow_redirects'` —
   which is not a degraded mode, it is every transcode returning 502. `ffmpeg -h protocol=http`
   is the authority; verified against ffmpeg 7.1.5 (`python:3.12-slim`, Debian 13).

`requests` was not a dependency and still is not: the hop loop is `urllib.request` with a
`HTTPRedirectHandler` subclass whose `redirect_request` returns `None`, which makes urllib
raise the 3xx as an `HTTPError` carrying the `Location` instead of chasing it. Each hop is a
`GET` with `Range: bytes=0-0` — HEAD is not reliably answered by podcast hosts, and a one-byte
range keeps the probe to a packet and below the threshold most download analytics count.

**A probe that fails for its own reasons is deliberately not fatal.** A 403, a refused
connection, a TLS error: `_redirect_target()` logs and answers `None`, and the URL — already
past `assert_public()` — goes to ffmpeg as before. Failing closed there would turn every CDN
that dislikes a range request into a broken episode, and it buys nothing: the URL handed over
is a validated one, and ffmpeg cannot leave it.

`proxy/README.md`'s *Security* section is rewritten accordingly; it previously stated as fact
that "the service cannot reach into your VPC or a metadata endpoint."

---

## 2. ffmpeg's stderr is returned to the caller in the 502 body

**Severity: Low standalone. It is what turns finding 1 into a practical attack**, so it was
fixed at the same time. **Fixed.**

`proxy/main.py:312`:

```python
tail = " | ".join(errors) or "no output from ffmpeg"
log.error("ffmpeg produced nothing, exit %s: %s", proc.returncode, tail)
raise Rejected("source fetch failed: " + tail[:300], status=502)
```

ffmpeg's error text names the target and the failure mode — `Server returned 403 Forbidden`,
`Connection refused`, `Connection timed out`, `Invalid data found when processing input`.
Combined with finding 1 that is a response oracle: point the proxy at an internal host across a
port range and the 502 bodies enumerate which services exist and how they answer.

### What was done

The client gets a fixed `{"error": "source fetch failed"}`. The `log.error` on the line
directly above still keeps the full stderr tail server-side, so nothing is lost for debugging,
and the watch never read this body anyway — it reads the status.

---

## 3. The container runs as root

**Hardening, not a vulnerability** — it was excluded from the review on those grounds.
**Fixed.** Worth
the two lines anyway, because ffmpeg parses wholly attacker-influenced media here and is one of
the larger memory-unsafe parsing surfaces in common use. Cloud Run's gVisor sandbox is the real
boundary; this is defence in depth.

`proxy/Dockerfile` sets no `USER`, so gunicorn and every ffmpeg child run as root.

### What was done

```dockerfile
RUN useradd -r -u 10001 pcproxy
USER pcproxy
```

before `CMD`. **Not named `proxy`** — Debian ships one at uid 13, so `useradd` exits 9 and the
Cloud Build step dies with `user 'proxy' already exists`, which is how the first deploy of this
change failed. `useradd -r` also warns that uid 10001 is above `SYS_UID_MAX`; that is a warning
only and the build succeeds.

Nothing is written to disk by design, so a read-only root filesystem is still an option on top;
it was not taken, since gunicorn and pip's packages are read from root-owned paths and the
value over an unprivileged user is small.

---

## Checked and fine — do not re-investigate

- **ffmpeg argument injection.** Not reachable. `subprocess.Popen` receives a list, and
  `assert_public()` requires `urlsplit` to yield scheme `http`/`https`, which forces the string
  to start `http:`/`https:`. A `-`-leading value, and `file:`, `concat:` and `subfile:` inputs,
  all fail that check.
- **Authentication.** Clean. `authorized()` uses `hmac.compare_digest`, fails closed when
  `PROXY_TOKEN` is unset, and `guard` is correctly the *inner* decorator on both `/transcode`
  and `/selftest.mp3`, so `app.route` wraps the guarded function. Only `/health` is open and it
  returns a constant.
- **IP-encoding bypasses of `assert_public()`.** Decimal, octal and hex hosts, IPv4-mapped IPv6
  (`::ffff:127.0.0.1`) and userinfo `@` tricks are all handled, because the check runs on
  `getaddrinfo()` output rather than on the literal string.
- **Token handling on the watch.** Clean, verified by grep: the token appears in no `println`
  anywhere in `source/`, is masked in the UI, is never seeded back into the `TextPicker`, and
  the sync log records `urlLen` rather than the URL or the header. The only log line mentioning
  `PROXY_TOKEN` reports that it is unset.
- **`urlsplit` control-character stripping.** `validate()` hands ffmpeg the original string
  while `assert_public()` validates the parsed one, and `urlsplit` strips tabs, CR, LF and
  leading C0 characters — so the two see different strings. No case was found where that yields
  host control, since removing characters cannot turn a public host into a private one. If you
  want it closed cheaply anyway, rebuild the URL from the `urlsplit` result instead of passing
  the raw input through.

---

## How it was verified

**In Docker, against a hostile origin — not by reading the ffmpeg docs, which were wrong twice.**
Both mistakes (`-follow_redirects`, and trusting `-protocol_whitelist` to stop HLS) survived
review and a careful reading, and both died in about a minute in a container. Do that first
next time.

The harness is two throwaway containers on a private docker network: an **origin** serving
`/good.mp3`, a two-hop redirect chain, a redirect to `169.254.169.254`, a redirect loop, and an
`#EXTM3U` playlist naming a **victim** container, which logs loudly if anything ever reaches
it. `assert_public()` is wrapped in the driver to admit those two hostnames by name — they sit
on a 172.x docker network and the real check would refuse them — while every other host,
`169.254.169.254` included, is still judged by the real function.

Eleven checks, all passing, victim never contacted:

| | |
| --- | --- |
| two-hop chain resolves to the real file | `final=…/good.mp3` |
| a hop into link-local space is refused | 400, names the address |
| a redirect loop is bounded | 400 `too many redirects` |
| a url with no redirect is passed through | unchanged |
| no token | 401 |
| a real episode transcodes (through two hops, at 1.5×) | 200, 16,509 bytes of audio |
| an HLS playlist source | 502, and **no request to the victim** |
| the 502 body | `{"error":"source fetch failed"}`, no ffmpeg stderr |
| a link-local redirect | 400, before ffmpeg runs |
| a link-local url outright | 400 |
| a `file:` url | 400 `url must be http or https` |

Also confirmed in the built image: it runs as `uid=10001(pcproxy)`, `main.py` imports, and
ffmpeg accepts the argv (a bad option name fails the *whole* invocation, so this is not a
detail).

## Deployed

**Cloud Run build and deploy clean, and a sync from the watch fetched episodes through real
podcast CDNs** — 2026-08-27. That is the half a container could not answer: the `Range:
bytes=0-0` probe is answered as the test origin answered it, the redirect chains resolve, and
the final urls are containers `ALLOWED_FORMATS` admits. Nothing outstanding.

Two things were *not* separately measured and are only as good as "the sync looked normal":
`ttfb` against the README's stated "a second or two" baseline, now that there is an extra round
trip per redirect hop, and playback of the downloaded episodes. Neither is a security question,
and the sync completing covers most of the first.

The one that failed on the first deploy is worth keeping in view, because it is the class of
thing that gets re-introduced: `useradd -r -u 10001 proxy` exits 9 on Debian, which ships a
`proxy` user at uid 13. Cloud Build reports that as `step exited with non-zero status: 9`.
The user is `pcproxy`.

## Order it was done in

Findings 1 and 2 were one change: they share a code path, and fixing 2 without 1 leaves the
hole while fixing 1 without 2 leaves a needless oracle. Finding 3 is independent and rode
along.
