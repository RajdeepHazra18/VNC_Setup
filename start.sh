#!/bin/bash
set -e

if [ -z "$VNC_PASSWORD" ]; then
    echo "ERROR: VNC_PASSWORD environment variable must be set." >&2
    exit 1
fi

VNC_USERNAME="${VNC_USERNAME:-dockeruser}"

# (Re)write per-user config into the bind-mounted home directory on every start, since
# anything baked into the image at this path is shadowed by the ./data volume mount.
mkdir -p "$HOME/.vnc"
# require_ssl: false — this container is no longer reachable from outside the Docker
# network directly; the auth-proxy service terminates TLS and does its own login,
# then forwards here over plain HTTP.
printf 'user_session:\n  session_type: shared\nnetwork:\n  ssl:\n    require_ssl: false\n' > "$HOME/.vnc/kasmvnc.yaml"
mkdir -p "$HOME/.config/xfce4"
printf 'WebBrowser=firefox\n' > "$HOME/.config/xfce4/helpers.rc"

# workspace-agent: land every new interactive shell inside the active project.
# workspace-agent-entrypoint.sh (running as root, before this script) already
# mount --bind'd the active project onto $EXPOSE_PATH; this is what makes new
# xfce4-terminal tabs open there by default instead of $HOME. Idempotent (checked via
# WORKSPACE_MARKER) so repeated container restarts don't pile up entries.
WORKSPACE_MARKER='# workspace-agent: land new shells in the active project'
if ! grep -qF "$WORKSPACE_MARKER" "$HOME/.bashrc" 2>/dev/null; then
  printf '\n%s\ncd "%s" 2>/dev/null\n' \
    "$WORKSPACE_MARKER" "${EXPOSE_PATH:-$HOME/workspace}" >> "$HOME/.bashrc"
fi

# Non-interactively (re)set the KasmVNC login: password, verify, then blank line
# answers the "read-only password?" prompt (no).
printf "%s\n%s\n\n" "$VNC_PASSWORD" "$VNC_PASSWORD" | vncpasswd -u "$VNC_USERNAME" -w -o

# -disableBasicAuth: skip KasmVNC's own HTTP Basic Auth prompt. auth-proxy is the
# only way in from outside the Docker network and handles login itself.
vncserver "$DISPLAY" -select-de XFCE -geometry "$RESOLUTION" -depth 24 -disableBasicAuth

# Webcam ingest: auth-proxy pushes the browser's WebRTC video to :9000 as raw frames,
# ffmpeg writes it into the v4l2loopback virtual camera; :9001 reads the camera back out as
# MJPEG for the "Received by server" preview. Skipped when the host has no /dev/video0.
if [ -e /dev/video0 ]; then
    # A fresh v4l2loopback device has no format yet, and ffmpeg's v4l2 output starts by
    # reading it (VIDIOC_G_FMT), which fails with "Invalid argument". Set one first.
    WEBCAM_SIZE="${WEBCAM_SIZE:-640x480}"
    v4l2-ctl -d /dev/video0 \
        --set-fmt-video-out=width="${WEBCAM_SIZE%x*}",height="${WEBCAM_SIZE#*x}",pixelformat=YU12 \
        || echo "webcam: could not preset the camera format" >&2
    # socat treats ":" as an address separator, so these commands must not contain
    # one (hence "-i -" rather than "pipe:0", and "-qscale" rather than "-q:v").
    # :9000 receives raw yuv420p frames from auth-proxy (decoded from WebRTC there),
    # already at WEBCAM_SIZE, so ffmpeg only has to copy them into the camera device.
    socat TCP-LISTEN:9000,reuseaddr,fork \
        EXEC:"ffmpeg -loglevel warning -fflags nobuffer -use_wallclock_as_timestamps 1 -f rawvideo -pix_fmt yuv420p -video_size ${WEBCAM_SIZE:-640x480} -framerate 30 -i - -pix_fmt yuv420p -vsync passthrough -f v4l2 /dev/video0" &
    socat TCP-LISTEN:9001,reuseaddr,fork \
        EXEC:"ffmpeg -loglevel warning -fflags nobuffer -flags low_delay -f v4l2 -i /dev/video0 -r 15 -qscale 6 -flush_packets 1 -f mpjpeg -" &
else
    echo "webcam: /dev/video0 not present, webcam ingest disabled" >&2
fi

trap 'vncserver -kill "$DISPLAY"; kill $(jobs -p) 2>/dev/null; exit 0' TERM INT

tail -f /dev/null &
wait $!
