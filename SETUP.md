# Setup Checklist

Step-by-step instructions to get this running on a fresh Linux server, from nothing to
a working desktop with webcam passthrough. For *why* each piece exists, see
[README.md](README.md); this file is just the steps, in order.

Run everything below **on the Linux server** unless marked otherwise.

---

## 0. Prerequisites

- A Linux server with Docker and the Docker Compose plugin installed
  (`docker compose version` should work).
- Root/sudo access.
- The project files copied onto the server (e.g. via `scp`, `git clone`, or a zip).

---

## 1. Create the virtual camera (v4l2loopback)

This **must** be done before the first `docker compose up`, or Docker refuses to start
`kasmvnc` (the compose file maps `/dev/video0` into the container, and mapping a device
that doesn't exist yet fails).

```bash
sudo apt update
sudo apt install -y v4l2loopback-dkms v4l2loopback-utils linux-headers-$(uname -r)

sudo modprobe v4l2loopback devices=1 video_nr=0 card_label="Virtual Cam" exclusive_caps=0

sudo chmod 666 /dev/video0

# confirm it exists
ls -l /dev/video0
v4l2-ctl --list-devices
```
You should see `/dev/video0` and a device named "Virtual Cam".

### 1a. Make it survive a reboot

Without this, the module has to be reloaded by hand (step 1) after every server reboot —
this is the single most common reason the stack breaks after time passes.

```bash
echo v4l2loopback | sudo tee /etc/modules-load.d/v4l2loopback.conf

echo 'options v4l2loopback devices=1 video_nr=0 card_label="Virtual Cam" exclusive_caps=0' \
  | sudo tee /etc/modprobe.d/v4l2loopback.conf

echo 'KERNEL=="video0", SUBSYSTEM=="video4linux", MODE="0666"' \
  | sudo tee /etc/udev/rules.d/99-v4l2loopback.rules

sudo udevadm control --reload-rules
sudo udevadm trigger
```

> If the server is a cloud/VPS instance whose kernel doesn't allow loading modules,
> `modprobe` will fail and this feature cannot work there — see README section 12.

---

## 2. Open the firewall

Two different ports need to be reachable from client machines:

| Port | Protocol | Purpose |
|---|---|---|
| `8445` | TCP | The login page and remote desktop (HTTPS) |
| `50000-50009` | UDP | Webcam video (WebRTC media) |

```bash
# if you use ufw:
sudo ufw allow 8445/tcp
sudo ufw allow 50000:50009/udp
sudo ufw enable      # only if ufw was not already active — check `sudo ufw status` first
```

If the server sits behind a cloud security group, VLAN ACL, or a separate network
firewall appliance, open the same two ports there too — a local `ufw` rule alone won't
help if something upstream is also blocking them.

---

## 3. Configure `.env`

```bash
cp .env .env.bak     # keep a copy of the template
nano .env             # or any editor
```

Set at minimum:
```
VNC_USERNAME=dockeruser
VNC_PASSWORD=<a real password>
AUTH_USERNAME=<a real username>
AUTH_PASSWORD=<a real password>
KASM_PORT=8445
```
Leave everything else at its default unless you have a specific reason to change it
(see README section 11 for the full reference).

---

## 4. Build and start

```bash
sudo docker compose up -d --build
sudo docker compose ps
```
Both `kasmvnc` and `auth-proxy` should show `Up`. If either is missing or restarting,
see the Troubleshooting section below before continuing.

---

## 5. Find the server's real IP address

**Do not use any `172.x.x.x` address** — those are Docker's own internal networks and
are not reachable from any other machine. Find the real one:

```bash
hostname -I
```
Pick the address on your actual LAN (commonly `10.x.x.x` or `192.168.x.x`). If you're
unsure which one, use the same address you normally SSH into the server with.

---

## 6. Connect

From **any machine on the network** (the server itself, or another PC):

- Remote desktop: `https://<server-ip>:8445`
- Webcam page (open from the machine that has the webcam): `https://<server-ip>:8445/webcam`

Accept the self-signed certificate warning the first time (Advanced → Accept the Risk
and Continue). **Always use `https://`** — plain `http://` returns an empty page,
because auth-proxy only speaks TLS.

---

## Quick reference: full command sequence

For a server that already has Docker installed, here is everything from steps 1–4 as one
block:

```bash
sudo apt update
sudo apt install -y v4l2loopback-dkms v4l2loopback-utils linux-headers-$(uname -r)
sudo modprobe v4l2loopback devices=1 video_nr=0 card_label="Virtual Cam" exclusive_caps=0
sudo chmod 666 /dev/video0

echo v4l2loopback | sudo tee /etc/modules-load.d/v4l2loopback.conf
echo 'options v4l2loopback devices=1 video_nr=0 card_label="Virtual Cam" exclusive_caps=0' | sudo tee /etc/modprobe.d/v4l2loopback.conf
echo 'KERNEL=="video0", SUBSYSTEM=="video4linux", MODE="0666"' | sudo tee /etc/udev/rules.d/99-v4l2loopback.rules
sudo udevadm control --reload-rules && sudo udevadm trigger

sudo ufw allow 8445/tcp
sudo ufw allow 50000:50009/udp

# edit .env with real credentials before this line
sudo docker compose up -d --build
sudo docker compose ps
hostname -I
```

---

## After a server reboot

`v4l2loopback` reloads automatically if you did step 1a. Otherwise, redo step 1's
`modprobe`/`chmod` lines, then:
```bash
sudo docker compose up -d
```

---

## Troubleshooting quick reference

Run `./preflight.sh` first. It checks the camera device, `data/` ownership, the
firewall and both containers, and prints the exact fix for anything wrong.

| Symptom | Fix |
|---|---|
| `error gathering device information ... /dev/video0: no such file or directory` | Redo step 1 — the module isn't loaded |
| `Permission denied` opening `/dev/video0` | `sudo chmod 666 /dev/video0` (or redo the udev rule in step 1a) |
| `Bind for ...:8445 failed: port is already allocated` | Something else already holds the port — `sudo docker compose ps -a` / `sudo ss -ltnp \| grep 8445`, remove the conflicting container or change `KASM_PORT` |
| Browser shows an empty page / `NS_ERROR_NET_EMPTY_RESPONSE` | You used `http://` instead of `https://` |
| Page loads on the server but not from another machine | You're using a `172.x` Docker-internal address — use the real LAN IP from step 5; also check the firewall (step 2) |
| `kasmvnc` stuck restarting, log says `/tmp/.X1-lock ... already taken` | Stale lock from an earlier crash — `sudo docker compose up -d --force-recreate kasmvnc` |
| `mkdir: cannot create directory '/etc/auth-proxy'` in the kasmvnc log | The two `start.sh` files got mixed up when copying files — restore the one at the project root (kasmvnc's), not `auth-proxy/start.sh` |
| `docker: permission denied ... docker.sock` | Use `sudo docker ...`, or `sudo usermod -aG docker $USER` and log back in |
| Old `vnc-desktop` container restarting endlessly | Leftover from an earlier version of the project — `sudo docker rm -f vnc-desktop` (does not touch `./data`) |
| `mount: /mnt/agent/ws: bind ... failed` in the kasmvnc log | Docker's AppArmor profile blocks mount — `docker-compose.yml` needs `security_opt: apparmor:unconfined` (already set) |
| `bwrap: pivot_root: Operation not permitted` when opening a terminal | `docker-compose.yml` needs `seccomp=unconfined` and `systempaths=unconfined` in `security_opt` (already set); rebuild/recreate |
| `chmod ... xstartup: Operation not permitted`, `Permission denied` on `.vnc/xstartup` or `.Xauthority`, or the "create a KasmVNC user" prompt looping | `data/` has files not owned by uid 1000 (the container's `dockeruser`) — `sudo docker compose stop kasmvnc && sudo chown -R 1000:1000 data && sudo rm -f data/.vnc/*.pid data/.vnc/*.log data/.vnc/.de-was-selected data/.kasmpasswd data/.Xauthority`, then start. Never chown `data/` to your own uid. |
| `Not a video capture device` from ffplay/ffmpeg, `VIDIOC_G_FMT: Invalid argument` from v4l2-ctl | v4l2loopback loaded with `exclusive_caps=1`, which misbehaves on some kernels — reload with `exclusive_caps=0` (step 1). Also, the camera is only readable while the `/webcam` page is streaming. |
| `ffplay: ... libblas.so.3: cannot open shared object file` | Image is missing `libblas3`/`liblapack3` (now in the Dockerfile) — rebuild with `--build` |
| Auth-proxy logs `Temporary failure in name resolution` / `All connection attempts failed` | The `kasmvnc` container is stopped or crash-looping — `sudo docker compose logs kasmvnc` |
| ffmpeg: `ioctl(VIDIOC_G_FMT): Invalid argument` in the kasmvnc log | Reset the module: `sudo docker compose stop kasmvnc && sudo modprobe -r v4l2loopback && sudo modprobe v4l2loopback devices=1 video_nr=0 card_label="Virtual Cam" exclusive_caps=0 && sudo chmod 666 /dev/video0 && sudo docker compose up -d` |

For anything not listed here, see README.md section 9 (testing) and section 10 (full
problem log).
