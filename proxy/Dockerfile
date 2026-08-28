FROM python:3.12-slim

# ffmpeg is the entire point of this image.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

ENV PYTHONUNBUFFERED=1

# ffmpeg parses wholly attacker-influenced media here - the episode comes from
# a podcast feed, not from us - and is one of the larger memory-unsafe parsing
# surfaces in common use. Cloud Run's gVisor sandbox is the real boundary;
# this is defence in depth behind it. Nothing is written to disk by design, so
# an unprivileged user costs nothing.
#
# NOT named "proxy": Debian ships one at uid 13, so useradd exits 9 and the
# Cloud Build step fails with "user 'proxy' already exists".
RUN useradd -r -u 10001 pcproxy
USER pcproxy

# --timeout 0 disables gunicorn's worker timeout. A request here is held open
# for the whole download - eight minutes on watch battery, longer on a poor
# link - and the 30 s default would kill it mid-episode.
#
# --threads 8 so several downloads can overlap; the work is a subprocess and
# a socket, so threads are the right shape and one worker is plenty.
CMD exec gunicorn --bind :$PORT --workers 1 --threads 8 --timeout 0 main:app
