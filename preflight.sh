#!/bin/bash
# Checks the host and the stack for every problem hit while setting this project up,
# and prints the exact fix for each one. Read-only: it changes nothing.
# Usage: ./preflight.sh      (uses sudo for docker if your user can't talk to it)
cd "$(dirname "$0")"

fail=0
ok()   { printf '  [ ok ] %s\n' "$1"; }
bad()  { printf '  [FAIL] %s\n         fix: %s\n' "$1" "$2"; fail=1; }
warn() { printf '  [warn] %s\n         %s\n' "$1" "$2"; }

DOCKER="docker"
docker info >/dev/null 2>&1 || DOCKER="sudo docker"
COMPOSE="$DOCKER compose"

echo "Virtual camera"
if [ -e /dev/video0 ]; then
  ok "/dev/video0 exists"
  [ -r /dev/video0 ] && [ -w /dev/video0 ] \
    && ok "readable and writable" \
    || bad "/dev/video0 is not readable/writable" "sudo chmod 666 /dev/video0"
  caps="$(v4l2-ctl -d /dev/video0 --all 2>/dev/null)"
  if echo "$caps" | grep -q "Video Capture" && echo "$caps" | grep -q "Video Output"; then
    ok "advertises Video Capture + Output (exclusive_caps=0)"
  else
    bad "camera does not advertise both Capture and Output (needs exclusive_caps=0)" \
        "$COMPOSE stop kasmvnc; sudo modprobe -r v4l2loopback; sudo modprobe v4l2loopback devices=1 video_nr=0 card_label=\"Virtual Cam\" exclusive_caps=0; sudo chmod 666 /dev/video0"
  fi
else
  bad "/dev/video0 is missing" \
      "sudo modprobe v4l2loopback devices=1 video_nr=0 card_label=\"Virtual Cam\" exclusive_caps=0 && sudo chmod 666 /dev/video0   (see SETUP.md step 1)"
fi
grep -qs "exclusive_caps=0" /etc/modprobe.d/v4l2loopback.conf \
  && ok "survives reboot (/etc/modprobe.d/v4l2loopback.conf)" \
  || warn "reboot persistence not set" "echo 'options v4l2loopback devices=1 video_nr=0 card_label=\"Virtual Cam\" exclusive_caps=0' | sudo tee /etc/modprobe.d/v4l2loopback.conf"

echo "Files"
[ -f .env ] && ok ".env present" || bad ".env is missing" "create it from the template in SETUP.md step 3"
if [ -d data ]; then
  # The container's dockeruser is uid 1000; anything else in data/ breaks vncserver.
  wrong="$(find data -maxdepth 2 ! -uid 1000 2>/dev/null | head -1)"
  [ -z "$wrong" ] \
    && ok "data/ owned by uid 1000 (dockeruser)" \
    || bad "data/ has files not owned by uid 1000 (e.g. $wrong)" \
           "$COMPOSE stop kasmvnc; sudo chown -R 1000:1000 data; sudo rm -f data/.vnc/*.pid data/.vnc/*.log data/.vnc/.de-was-selected data/.kasmpasswd data/.Xauthority"
fi

echo "Firewall"
if command -v ufw >/dev/null 2>&1 && sudo -n ufw status 2>/dev/null | grep -q "Status: active"; then
  sudo -n ufw status | grep -q "8445/tcp" && ok "8445/tcp allowed" || bad "8445/tcp not allowed" "sudo ufw allow 8445/tcp"
  sudo -n ufw status | grep -q "50000:50009/udp" && ok "50000:50009/udp allowed" || bad "50000:50009/udp not allowed" "sudo ufw allow 50000:50009/udp"
else
  warn "could not check ufw" "make sure TCP 8445 and UDP 50000-50009 are open to your clients"
fi

echo "Containers"
for svc in kasmvnc auth-proxy; do
  state="$($COMPOSE ps --format '{{.State}}' "$svc" 2>/dev/null)"
  [ "$state" = "running" ] \
    && ok "$svc running" \
    || bad "$svc is '${state:-not created}'" "$COMPOSE up -d --build ; $COMPOSE logs --tail=40 $svc"
done
if [ "$($COMPOSE ps --format '{{.State}}' kasmvnc 2>/dev/null)" = "running" ]; then
  $COMPOSE exec -T -u dockeruser kasmvnc env EXPOSE_PATH=/home/dockeruser/workspace \
      bash -c 'echo | /usr/local/bin/jailed-shell.sh >/dev/null 2>&1' \
    && ok "terminal sandbox (bwrap) starts" \
    || bad "terminal sandbox fails to start" "check security_opt in docker-compose.yml (apparmor/seccomp/systempaths unconfined), then rebuild"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "All checks passed. Open https://$(hostname -I | awk '{print $1}'):${KASM_PORT:-8445}"
else
  echo "Some checks failed. Apply the fixes above, then run ./preflight.sh again."
  exit 1
fi
