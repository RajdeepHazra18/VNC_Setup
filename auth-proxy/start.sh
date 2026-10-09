#!/bin/bash
set -e

for var in AUTH_USERNAME AUTH_PASSWORD; do
    if [ -z "${!var}" ]; then
        echo "ERROR: $var environment variable must be set." >&2
        exit 1
    fi
done

CERT_DIR=/etc/auth-proxy/tls
mkdir -p "$CERT_DIR"

# Self-signed cert, generated once and kept for the life of the container (not the
# bind-mounted host data) — same trust model as KasmVNC's own default cert.
if [ ! -f "$CERT_DIR/cert.pem" ] || [ ! -f "$CERT_DIR/key.pem" ]; then
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$CERT_DIR/key.pem" -out "$CERT_DIR/cert.pem" \
        -days 365 -subj "/CN=localhost"
fi

# --loop asyncio: the WebRTC code pins aiortc's UDP ports by wrapping the event
# loop's create_datagram_endpoint, which uvloop (the default) does not allow.
exec uvicorn app.main:app \
    --loop asyncio \
    --host 0.0.0.0 --port 8444 \
    --ssl-certfile "$CERT_DIR/cert.pem" --ssl-keyfile "$CERT_DIR/key.pem"
