"""Playback-speed transcoding proxy for the GarminPocketCasts watch app.

The watch cannot vary playback rate, so the audio has to arrive already sped
up. This service pulls an episode from its podcast CDN, pipes it through
ffmpeg's `atempo` filter, and hands the re-encoded MP3 back as the response
body. Nothing is remembered between requests.

THE OUTPUT CARRIES AN ID3v2 TAG AND THAT IS LOAD-BEARING, not metadata
politeness: without a tag at the head of the file the watch cannot seek
inside the episode at all - every skip restarts the audio while the progress
ring advances normally. See ffmpeg_argv().

The body is streamed; PC_BUFFER=1 sends a finished temp file instead, which
costs a silent window but buys a Xing seek table and a real Content-Length.
Neither mode changes whether an episode can be seeked - see sink_args() and
buffered_enabled().

Speeding an episode up also shrinks it - 1.5x at 64 kbps mono turns a typical
37 MB episode into about 12 MB - which matters more than the speed itself: on
real hardware the full-size downloads have never once completed.

ONE REQUEST, AND NO SERVER STATE. The episode url travels in a POST body and
the transcoded audio streams back as that same response.

Connect IQ documents media downloads only as GETs and says nothing about
whether makeWebRequest will do one with POST, so this was settled on hardware
before the shape was chosen. Measured on a fenix 8, 2026-08-27: a POST asking
for HTTP_RESPONSE_CONTENT_TYPE_AUDIO came back with a Media.ContentRef exactly
as the GET control did. A 422-character url also went through untouched, so
there was never a length ceiling worth designing around either.

Two fallback shapes - a GET carrying everything in the query string, and a
ticketed POST /prepare followed by GET /f/<id>.mp3 - were built and then
removed once that was known. The ticketed one was the only thing that made
this service stateful, and with it went the need for --max-instances 1.
"""

import collections
import hmac
import ipaddress
import logging
import os
import socket
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
from urllib.parse import urljoin, urlsplit

from flask import Flask, Response, jsonify, request

app = Flask(__name__)
log = logging.getLogger("proxy")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

USER_AGENT = "GarminPocketCasts/1.0"

# Speed travels as an integer percentage so it survives Connect IQ's Storage
# without float rounding: 150 means 1.5x.
MIN_SPEED, MAX_SPEED = 50, 300
ALLOWED_BITRATES = (32, 48, 64, 96, 128, 160, 192)
DEFAULT_BITRATE = 64

# Hard ceilings. A leaked token should not be able to run up a bill, and a
# url that turns out to be a 24-hour livestream should not be followed
# forever. Both are enforced by ffmpeg itself now (-fs and -t), because the
# output no longer passes through a pump that could count it.
#
# MAX_OUTPUT_BYTES is also a MEMORY ceiling, which it was not before: the
# transcode lands in a temp file, and Cloud Run's /tmp is tmpfs, i.e. RAM.
# See the deploy notes in README.md - the buffered design wants
# --concurrency 1 and headroom over this number.
MAX_OUTPUT_BYTES = 200 * 1024 * 1024
MAX_OUTPUT_SECONDS = 6 * 60 * 60

# Wall clock for one ffmpeg run. Nothing reaches the client until it exits, so
# this is a reaper for a request whose client gave up long ago rather than a
# limit the watch will ever meet: the watch abandons a download after 120s
# with no bytes (STALL_MS), which is the real ceiling on how long a transcode
# may take. Measured on hardware, a 15-40 minute episode takes about 30s.
MAX_TRANSCODE_SECONDS = 300

CHUNK = 64 * 1024

# Redirect chain limits. A podcast enclosure url redirects to a CDN as a
# matter of course - usually once, occasionally twice - so eight hops is
# generous without letting a hostile host walk the proxy around forever.
MAX_REDIRECTS = 8
HOP_TIMEOUT = 15

# Input demuxers a source is allowed to be. THIS is what shuts off HLS, not
# the protocol whitelist - see the comment in ffmpeg_argv(), which is the
# result of a measurement rather than a reading of the docs. The list covers
# what podcast enclosures actually are: mp3 overwhelmingly, m4a/mp4 next,
# then the occasional adts, ogg/opus, wav or flac. Matching is per
# comma-separated token on both sides, so "mp4" matches the mov demuxer
# whose name is the whole string "mov,mp4,m4a,3gp,3g2,mj2".
ALLOWED_FORMATS = "mp3,mov,mp4,m4a,aac,wav,ogg,flac"


class Rejected(Exception):
    """A bad request we can still answer properly.

    Only useful BEFORE the first byte is written. Once the generator starts,
    the response is committed at 200 and a failure can only be signalled by
    cutting the stream short - which reaches the watch as a failed download
    and nothing more.
    """

    def __init__(self, message, status=400):
        super().__init__(message)
        self.message = message
        self.status = status


# ---------------------------------------------------------------------------
# auth
# ---------------------------------------------------------------------------

def authorized(req):
    expected = os.environ.get("PROXY_TOKEN", "")
    if not expected:
        # Refuse everything rather than stand open to the internet because a
        # secret failed to mount.
        log.error("PROXY_TOKEN is not set; refusing every request")
        return False
    sent = req.headers.get("Authorization", "")
    if sent.startswith("Bearer "):
        sent = sent[len("Bearer "):]
    return hmac.compare_digest(sent, expected)


# ---------------------------------------------------------------------------
# validation
# ---------------------------------------------------------------------------

def assert_public(url):
    """Reject anything resolving inside the network this service runs in.

    The service fetches urls chosen by the caller, which is a server-side
    request forgery vector into the VPC if left unguarded. And the token is
    not the only barrier in front of it: the url comes from the episode
    enclosure in the podcast's own feed, so anyone who can publish or
    compromise a subscribed podcast can steer the outbound fetch without ever
    holding the token.

    THIS CHECKS ONE URL, NOT A CHAIN. It is the wrong guard on its own, since
    libavformat follows 3xx by default and would land wherever the last hop
    pointed. resolve_source() is what calls it per hop; do not go back to
    calling it once on the caller's string.

    Still time-of-check/time-of-use: ffmpeg resolves the name again itself, so
    a DNS record that flips between the two would slip past. Closing that
    needs the address pinned into the request, which ffmpeg does not make
    easy. Behind a bearer token on a single-user service that is an accepted
    risk rather than an overlooked one.
    """
    parts = urlsplit(url)
    if parts.scheme not in ("http", "https"):
        raise Rejected("url must be http or https")

    host = parts.hostname
    if not host:
        raise Rejected("url has no host")

    port = parts.port or (443 if parts.scheme == "https" else 80)
    try:
        infos = socket.getaddrinfo(host, port, proto=socket.IPPROTO_TCP)
    except socket.gaierror:
        raise Rejected("cannot resolve host: " + host)

    for info in infos:
        ip = ipaddress.ip_address(info[4][0])
        if not ip.is_global or ip.is_multicast:
            raise Rejected("url resolves to a non-public address: " + str(ip))


class _NoRedirects(urllib.request.HTTPRedirectHandler):
    """Hand every 3xx back to the caller instead of following it.

    Returning None from redirect_request leaves the response unhandled, which
    urllib then raises as an HTTPError carrying the status and the headers -
    which is exactly the Location we want to look at ourselves.
    """

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


_opener = urllib.request.build_opener(_NoRedirects)


def _redirect_target(url):
    """One hop. Returns the Location of a 3xx, or None if this url is final.

    Anything that is not a redirect answers None - a 200, a 206, a 404, a
    refused connection - so a probe that fails for its own reasons hands the
    url straight to ffmpeg as before and lets ffmpeg report it. That is safe
    because the url being handed over has already passed assert_public(), and
    -follow_redirects 0 means ffmpeg cannot leave it.
    """
    req = urllib.request.Request(url, method="GET", headers={
        "User-Agent": USER_AGENT,
        # Ask for one byte. A CDN that honours it answers in a single packet;
        # one that ignores it sends a body that is closed unread. HEAD would
        # be tidier and is not reliably answered by podcast hosts.
        "Range": "bytes=0-0",
        "Accept": "*/*",
    })
    try:
        resp = _opener.open(req, timeout=HOP_TIMEOUT)
        resp.close()
        return None
    except urllib.error.HTTPError as e:
        location = e.headers.get("Location") if e.headers else None
        code = e.code
        try:
            e.close()
        except Exception:
            # HTTPError is only file-like when urllib had a body to give it.
            pass
        if 300 <= code < 400 and location:
            return location
        return None
    except Exception as e:
        log.warning("redirect probe failed, handing url to ffmpeg as-is: %s", e)
        return None


def resolve_source(url):
    """Walk the redirect chain here, checking every hop, return the final url.

    assert_public() can only vouch for the string it is given, and ffmpeg
    follows redirects itself: a public host answering
    `302 Location: http://10.128.0.7:8080/` used to send it somewhere the
    check never saw. Refusing to follow redirects is not an option either -
    podcast CDNs are built on them - so the chain is resolved here, validated
    hop by hop, and ffmpeg is handed a url with nothing left to follow.
    """
    current = url
    for _ in range(MAX_REDIRECTS):
        assert_public(current)
        location = _redirect_target(current)
        if location is None:
            return current
        nxt = urljoin(current, location.strip())
        log.info("redirect -> %s", nxt[:120])
        current = nxt
    raise Rejected("too many redirects")


def as_bool(value, default):
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in ("1", "true", "yes", "on")


def pick(source, *names):
    for name in names:
        if name in source and source[name] is not None:
            return source[name]
    return None


def validate(source):
    """Check and normalise the request body.

    Tolerates short key names as well as long ones. They cost nothing and were
    what the query-string shape used before it was removed, so a hand-rolled
    curl against this service can still use either.

    Out-of-range values are REJECTED, never clamped. The watch records the
    speed it asked for against the downloaded episode and divides every
    playback position by it forever after, so a silent substitution here is a
    permanent and invisible corruption of that episode's resume position.
    """
    if not source:
        raise Rejected("missing request body")

    url = (pick(source, "url", "u") or "").strip()
    if not url:
        raise Rejected("url is required")
    # The FINAL url of the redirect chain, every hop of it checked. What
    # ffmpeg is given must be what was validated - see resolve_source().
    url = resolve_source(url)

    try:
        speed = int(pick(source, "speed", "s") or 100)
    except (TypeError, ValueError):
        raise Rejected("speed must be an integer percentage, e.g. 150")
    if not MIN_SPEED <= speed <= MAX_SPEED:
        raise Rejected("speed must be between %d and %d" % (MIN_SPEED, MAX_SPEED))

    try:
        bitrate = int(pick(source, "bitrate", "b") or DEFAULT_BITRATE)
    except (TypeError, ValueError):
        raise Rejected("bitrate must be an integer in kbps, e.g. 64")
    if bitrate not in ALLOWED_BITRATES:
        raise Rejected("bitrate must be one of " + str(list(ALLOWED_BITRATES)))

    mono = as_bool(pick(source, "mono", "m"), True)
    return {"url": url, "speed": speed, "bitrate": bitrate, "mono": mono}


# ---------------------------------------------------------------------------
# ffmpeg
# ---------------------------------------------------------------------------

def atempo_chain(factor):
    """atempo accepts 0.5-2.0 per instance, so anything outside that chains."""
    parts = []
    while factor > 2.0:
        parts.append(2.0)
        factor /= 2.0
    while factor < 0.5:
        parts.append(0.5)
        factor /= 0.5
    parts.append(factor)
    return ",".join("atempo=%.6g" % p for p in parts)


def ffmpeg_argv(p, out_path):
    argv = ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error"]

    # Input-side resilience: podcast urls redirect to a CDN and the CDN
    # occasionally stalls. These must come BEFORE -i to apply to the input.
    #
    # They belong to the http/https PROTOCOL handler rather than to ffmpeg
    # globally, so passing them for any other kind of input fails the whole
    # invocation with "Option reconnect not found". validate() only ever
    # admits http(s), so this guard is really about keeping the function
    # runnable against a local file - which is how the problem was found.
    if p["url"].lower().startswith(("http://", "https://")):
        argv += [
            "-reconnect", "1",
            "-reconnect_streamed", "1",
            "-reconnect_delay_max", "30",
            "-user_agent", USER_AGENT,
            # No indirection. The input demuxer is picked by sniffing the
            # body, so an `#EXTM3U` response opens the HLS demuxer and every
            # variant and segment uri it names is fetched without ever
            # passing the public-address check. Both whitelists are scoped to
            # the http branch so this function stays runnable against a local
            # file, which is how the reconnect problem above was found.
            #
            # THE PROTOCOL WHITELIST DOES NOT STOP HLS, and believing it does
            # is the trap here - it is what the security review recommended
            # and it is not enough. Measured in a container against a hostile
            # origin: with protocol_whitelist alone, a playlist naming
            # `http://victim:9001/secret.ts` was fetched and the victim
            # logged the request. HLS segments travel over plain http, which
            # is necessarily on the protocol list, so the protocol layer
            # cannot see the difference. -format_whitelist is what closes it,
            # by refusing to instantiate the hls demuxer at all; the same run
            # with it in place failed at avformat_open_input with "Invalid
            # argument" and the victim was never touched.
            #
            # What the protocol list still earns is everything that is not
            # http: file:, concat:, data:, subfile:. Keep both.
            #
            # ALL FOUR PROTOCOLS ARE LOAD-BEARING - "https" alone does not
            # work. libavformat nests protocols and applies this list to
            # every layer: the https handler opens a tls:// url of its own,
            # and tls opens a tcp:// under that. Drop either and https cannot
            # reach a socket. "http" is here because assert_public() admits
            # plain-http sources and older feeds still serve them; take it
            # out and those fail as a confusing 502 rather than a clean 400.
            #
            # "crypto" is NOT here, though every HLS whitelist on the
            # internet carries it: it is the AES-128 segment decryption
            # wrapper, i.e. part of the thing this exists to switch off.
            "-protocol_whitelist", "http,https,tcp,tls",
            "-format_whitelist", ALLOWED_FORMATS,
            # resolve_source() has already walked the chain and validated
            # every hop, so this url is the end of it. Safe to forbid here
            # precisely because it is not forbidden there.
            #
            # The option is -max_redirects, NOT -follow_redirects: that one
            # does not exist and ffmpeg rejects the whole argument list with
            # "Unrecognized option", i.e. every transcode 502s. Verified
            # against ffmpeg 7.1.5 with `ffmpeg -h protocol=http`.
            "-max_redirects", "0",
        ]

    argv += [
        "-i", p["url"],
        # Drop cover art. It costs bytes, and an attached image can otherwise
        # be picked up as a video stream by the muxer.
        "-vn", "-map", "0:a:0",
    ]

    if p["speed"] != 100:
        argv += ["-af", atempo_chain(p["speed"] / 100.0)]

    argv += [
        "-c:a", "libmp3lame",
        "-b:a", "%dk" % p["bitrate"],
        "-ar", "44100",
    ]
    if p["mono"]:
        argv += ["-ac", "1"]

    argv += [
        # AN ID3v2 TAG IS WHAT MAKES THE EPISODE SEEKABLE ON THE WATCH. It is
        # not metadata politeness and it is not optional: this was
        # `-id3v2_version 0` to save a few dozen bytes, and with no tag at the
        # head of the file every skip inside a proxied episode restarted the
        # AUDIO from the beginning while the progress ring advanced normally.
        #
        # Bisected against a fenix 9 Pro over five rounds, 2026-09-08/09. The
        # seek table was never the problem - a working file and a failing one
        # both carried a complete Info tag (`flags=0x0000000f`: frames, bytes,
        # TOC and quality, TOC populated and monotonic). Relaying the CDN's
        # own bytes over this same POST seeked correctly; putting those very
        # same frames through this muxer with `-c:a copy` did not. The only
        # structural difference left was the head of the file:
        #
        #   works: ID3v2 45 bytes, first frame at 45, Info at 81
        #   fails: no ID3v2,       first frame at  0, Info at 36
        #
        # Writing the tag fixed it, on an ordinary 64 kbps mono 2x transcode.
        # v3 rather than v4 for the wider compatibility; the tag ffmpeg writes
        # from the source's metadata is a few dozen bytes.
        "-id3v2_version", "3",
        "-t", str(MAX_OUTPUT_SECONDS),
    ]
    return argv + sink_args(out_path)


def sink_args(out_path):
    """Where the mp3 goes, and what that costs the Xing header.

    `out_path` None means a pipe (the default, streamed); a path means the
    buffered mode, PC_BUFFER=1. See buffered_enabled().

    ffmpeg writes the Xing/Info header at the top of the stream and seeks back
    at the end to fill in its frame count, byte count and seek table. A PIPE
    CANNOT BE SEEKED, so a streamed mp3 can carry only a header full of zeros
    - which reads as a zero-length episode - or, with -write_xing 0, none at
    all. None at all is the lesser evil and is what the streamed path does.

    A file can be seeked, so the buffered path leaves -write_xing at its
    default of 1 and gets a real seek table, plus a real Content-Length on the
    response. NEITHER IS WHAT MAKES AN EPISODE SEEKABLE ON THE WATCH - the
    ID3v2 tag above is, and both paths write it. Measured on a fenix 9 Pro,
    2026-09-09: a buffered transcode with a complete Xing table and no ID3 tag
    did not seek, and the buffered mode was built for exactly that theory.

    The byte cap is enforced by ffmpeg's own -fs on the buffered path, where
    nothing else is watching, and by the pump on the streamed one.
    """
    if out_path is None:
        return ["-write_xing", "0", "-f", "mp3", "pipe:1"]
    return ["-fs", str(MAX_OUTPUT_BYTES), "-y", "-f", "mp3", out_path]


def selftest_argv(out_path, seconds=5, bitrate=64):
    """A few seconds of generated tone, for proving reachability.

    Deliberately depends on nothing outside this container: pointing a watch
    at a podcast CDN to answer "can it talk to the proxy at all" mixes two
    questions together, and the interesting one is the connection.
    """
    return [
        "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error",
        "-f", "lavfi", "-i", "sine=frequency=440:duration=%d" % seconds,
        "-c:a", "libmp3lame", "-b:a", "%dk" % bitrate, "-ac", "1", "-ar", "44100",
        "-id3v2_version", "3",
    ] + sink_args(out_path)


def buffered_enabled():
    """PC_BUFFER=1 sends the finished file instead of streaming ffmpeg's output.

    Streaming is the default: the watch starts receiving bytes as soon as the
    first ones exist, which keeps the whole transfer clear of STALL_MS - the
    120s the sync delegate allows with nothing transferred - however long the
    episode.

    Buffering trades that for two things a pipe cannot give: a real Xing seek
    table (see sink_args()) and a real Content-Length, which makes the watch's
    sync progress bar exact rather than an estimate off Proxy.expectedBytes().
    It costs a silent window the length of the whole transcode - about 30s for
    a 15-40 minute episode, and the reason a multi-hour one is a stall risk -
    and it puts the output in Cloud Run's tmpfs, i.e. RAM, so it wants
    --memory 1Gi --concurrency 1.

    NEITHER MODE AFFECTS WHETHER AN EPISODE CAN BE SEEKED. That is the ID3v2
    tag, which both write; buffering was built for the theory that it was the
    Xing header, and that theory was measured wrong.

        gcloud run services update pc --region  --set-env-vars PC_BUFFER=1
        gcloud run services update pc --region  --remove-env-vars PC_BUFFER

    Either flips the running service in seconds without rebuilding the image.
    """
    return os.environ.get("PC_BUFFER", "").strip().lower() in ("1", "true", "yes", "on")


def stream(p):
    """Transcode an episode and hand the mp3 back as the body."""
    buffered = buffered_enabled()
    log.info("transcode speed=%s bitrate=%s mono=%s mode=%s url=%s",
             p["speed"], p["bitrate"], p["mono"],
             "buffered" if buffered else "streamed", p["url"][:120])
    if buffered:
        return transcode_and_send(lambda out: ffmpeg_argv(p, out), p["speed"], p["bitrate"])
    return stream_argv(ffmpeg_argv(p, None), p["speed"], p["bitrate"])


def stream_argv(argv, speed, bitrate):
    """Run ffmpeg to a pipe and hand its stdout back as the response body.

    The default mode - see buffered_enabled() for the alternative and what
    each costs. No Content-Length is possible here, so the watch falls back to
    Proxy.expectedBytes() for its progress bar.
    """
    proc = subprocess.Popen(
        argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0
    )

    # ffmpeg is chatty on stderr. If that pipe fills while nobody is reading
    # it, ffmpeg blocks writing to it while we block reading stdout, and the
    # request hangs forever. Drain it on a thread and keep the tail for logs.
    errors = collections.deque(maxlen=20)

    def drain():
        try:
            for line in proc.stderr:
                errors.append(line.decode("utf-8", "replace").rstrip())
        except Exception:
            pass
        finally:
            try:
                proc.stderr.close()
            except Exception:
                pass

    threading.Thread(target=drain, daemon=True).start()

    # Pull the first chunk BEFORE committing to a 200.
    #
    # ffmpeg reports an unusable source - a 404, a 403, a 5XX from the CDN -
    # by exiting immediately, and without this the response has already been
    # committed by the time that happens. The caller then gets a perfectly
    # successful 200 carrying an empty body, and on the watch that means a
    # ContentRef for a zero-byte episode: a download that looks like it
    # worked and is silently unplayable. Reading one chunk first is what
    # makes a dead source a 502 instead.
    first = proc.stdout.read(CHUNK)
    if not first:
        proc.wait(timeout=10)
        tail = " | ".join(errors) or "no output from ffmpeg"
        log.error("ffmpeg produced nothing, exit %s: %s", proc.returncode, tail)
        # The tail stays in the log and goes no further. ffmpeg names the
        # target and the failure mode - "Connection refused", "Server
        # returned 403 Forbidden", "Connection timed out" - and returning
        # that to the caller turns any SSRF into a response oracle that
        # enumerates internal hosts and ports. Nothing on the watch reads
        # this body anyway; it reads the status.
        raise Rejected("source fetch failed", status=502)

    def pump():
        sent = len(first)
        started = time.monotonic()
        try:
            yield first
            while True:
                chunk = proc.stdout.read(CHUNK)
                if not chunk:
                    break
                sent += len(chunk)
                if sent > MAX_OUTPUT_BYTES:
                    log.warning("output cap hit at %d bytes, cutting off", sent)
                    break
                yield chunk
        finally:
            # The watch hanging up mid-download is the NORMAL failure on this
            # hardware, and every one would leave an ffmpeg running if this
            # did not reap it. The generator is closed on client disconnect,
            # so this always runs.
            try:
                proc.stdout.close()
            except Exception:
                pass
            proc.kill()
            proc.wait()
            # -9 and -15 are us killing it just above, i.e. a disconnect.
            if proc.returncode not in (0, -9, -15):
                log.error("ffmpeg exited %s after %d bytes: %s",
                          proc.returncode, sent, " | ".join(errors))
            else:
                log.info("streamed %d bytes in %.1fs",
                         sent, time.monotonic() - started)

    return Response(
        pump(),
        mimetype="audio/mpeg",
        headers={
            # What the server actually applied. The watch may well not be
            # able to read response headers off an audio download - see the
            # README - so treat this as a diagnostic, never a source of truth.
            "X-Speed": str(speed),
            "X-Bitrate": str(bitrate),
            "Cache-Control": "no-store",
        },
    )



def transcode_and_send(build_argv, speed, bitrate):
    # NOT named transcode(): that is the /transcode route handler below, and
    # defining it second silently shadowed this one.

    """Run ffmpeg to a temp file, then stream that file back.

    BUFFERED RATHER THAN STREAMED, AND THAT IS DELIBERATE - see the comment
    on the output arguments in ffmpeg_argv(). ffmpeg can only write a usable
    Xing header if it can seek back to it when the encode ends, which rules
    out a pipe, and without that header the watch cannot seek inside the
    episode at all.

    The cost is WHEN the bytes move, not how many: the transcode is paced by
    the source download either way, so the total is much the same, but the
    client now waits in silence for all of it and then receives the file at
    local speed. The watch abandons a download after 120s with nothing
    transferred, so a transcode has to fit inside that; a 15-40 minute
    episode takes about 30s. The "transcoded N bytes in Ns" line below is
    what to read if a sync ever starts stalling.

    Buffering also buys a real Content-Length, which the streamed response
    never had - so the sync progress bar stops being an estimate.
    """
    fd, path = tempfile.mkstemp(prefix="pc-", suffix=".mp3")
    os.close(fd)
    try:
        size = run_ffmpeg(build_argv(path), path)
    except BaseException:
        discard(path)
        raise

    return Response(
        drain_file(path),
        mimetype="audio/mpeg",
        headers={
            "Content-Length": str(size),
            # What the server actually applied. The watch may well not be
            # able to read response headers off an audio download - see the
            # README - so treat this as a diagnostic, never a source of truth.
            "X-Speed": str(speed),
            "X-Bitrate": str(bitrate),
            "Cache-Control": "no-store",
        },
    )


def run_ffmpeg(argv, path):
    """Transcode into `path`, or raise. Returns the size written.

    Everything here happens BEFORE the response is committed, which is the
    window in which a dead source can still be reported as a status rather
    than as a cut stream. ffmpeg reports an unusable source - a 404, a 403, a
    5XX from the CDN - by exiting immediately, and a 200 carrying an empty
    body means a ContentRef for a zero-byte episode on the watch: a download
    that looks like it worked and is silently unplayable.
    """
    started = time.monotonic()
    try:
        proc = subprocess.run(
            argv,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            timeout=MAX_TRANSCODE_SECONDS,
        )
    except subprocess.TimeoutExpired:
        log.error("ffmpeg killed after %ds", MAX_TRANSCODE_SECONDS)
        raise Rejected("source fetch failed", status=502)

    tail = proc.stderr.decode("utf-8", "replace").strip() or "no output from ffmpeg"
    size = os.path.getsize(path) if os.path.exists(path) else 0

    if proc.returncode != 0 or size == 0:
        log.error("ffmpeg exit %s, %d bytes: %s", proc.returncode, size, tail[-2000:])
        # The tail stays in the log and goes no further. ffmpeg names the
        # target and the failure mode - "Connection refused", "Server
        # returned 403 Forbidden", "Connection timed out" - and returning
        # that to the caller turns any SSRF into a response oracle that
        # enumerates internal hosts and ports. Nothing on the watch reads
        # this body anyway; it reads the status.
        raise Rejected("source fetch failed", status=502)

    log.info("transcoded %d bytes in %.1fs", size, time.monotonic() - started)
    return size


def drain_file(path):
    """Yield the file, then delete it however the response ends.

    The generator is closed on client disconnect as well as on completion,
    so the finally always runs - which matters more here than it did with a
    pipe, because /tmp is RAM on Cloud Run and a leaked file is leaked
    memory for the life of the instance.
    """
    def gen():
        try:
            with open(path, "rb") as fh:
                while True:
                    chunk = fh.read(CHUNK)
                    if not chunk:
                        break
                    yield chunk
        finally:
            discard(path)
    return gen()


def discard(path):
    try:
        os.unlink(path)
    except OSError:
        pass


# ---------------------------------------------------------------------------
# routes
# ---------------------------------------------------------------------------

def guard(fn):
    """Authenticate, then turn a Rejected into a real status code.

    Everything wrapped here runs before the first byte, which is the only
    window in which an error can be reported as anything but a cut stream.
    """
    def wrapper(*args, **kwargs):
        if not authorized(request):
            return jsonify(error="unauthorized"), 401
        try:
            return fn(*args, **kwargs)
        except Rejected as e:
            log.warning("rejected: %s", e.message)
            return jsonify(error=e.message), e.status
    wrapper.__name__ = fn.__name__
    return wrapper


@app.get("/health")
def health():
    return "ok", 200


# Five seconds of tone, as audio/mpeg, reachable by BOTH methods.
#
# A reachability check that depends on nothing outside this container: it
# exercises auth, ffmpeg and the streaming response in one call, so a failure
# here is the service rather than a podcast CDN having a bad day. It answered
# the original question too - whether makeWebRequest would do a POST with an
# audio response type, which the SDK documents only as a GET. Measured on a
# fenix 8, 2026-08-27: both methods returned a Media.ContentRef, which is what
# lets the episode url travel in a POST body and keeps this service stateless.
@app.route("/selftest.mp3", methods=["GET", "POST"])
@guard
def selftest():
    log.info("selftest via %s, mode=%s", request.method,
             "buffered" if buffered_enabled() else "streamed")
    if buffered_enabled():
        return transcode_and_send(lambda out: selftest_argv(out), 100, 64)
    return stream_argv(selftest_argv(None), 100, 64)


@app.post("/transcode")
@guard
def transcode():
    return stream(validate(request.get_json(silent=True)))



if __name__ == "__main__":
    # Local development only. Cloud Run runs this under gunicorn.
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8080)))
