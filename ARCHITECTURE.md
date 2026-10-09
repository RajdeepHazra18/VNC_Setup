# Webcam-to-VNC: Architecture Diagrams

How a webcam on one machine (node B) ends up on the remote desktop hosted on another
(node A), and how anyone viewing that desktop can see it. The diagrams are Mermaid, so
they render on GitHub, in VS Code (Markdown preview with a Mermaid extension) and in most
Markdown viewers. Code references: `auth-proxy/app/webcam.py`, `auth-proxy/app/main.py`,
`start.sh`, `jailed-shell.sh`.

- [Flow chart: the path of one video frame](#flow-chart-the-path-of-one-video-frame)
- [Sequence diagram](#sequence-diagram)
- [How it works, step by step](#how-it-works-step-by-step)
- [Conditions and gotchas](#conditions-and-gotchas)

---

## Flow chart: the path of one video frame

```mermaid
flowchart LR
  subgraph B["Node B (sender)"]
    CAM[Webcam] --> BR[Browser /webcam page<br/>getUserMedia + WebRTC]
  end
  subgraph A["Node A (server)"]
    subgraph AP["auth-proxy container :8444"]
      SIG["/api/webcam/offer<br/>(signalling, HTTPS, JWT cookie)"]
      RTC["aiortc<br/>UDP 50000-50009"]
      PUMP["_pump_video<br/>scale to 640x480 yuv420p"]
      PRV["/api/webcam/preview"]
      PX["HTTP + WebSocket<br/>reverse proxy"]
    end
    subgraph KV["kasmvnc container"]
      S9000["socat :9000"] --> FF1["ffmpeg (writer)"] --> DEV[("/dev/video0<br/>v4l2loopback")]
      DEV --> FF2["ffmpeg (MJPEG reader)"] --> S9001["socat :9001"]
      DEV --> FP["ffplay in VNC terminal<br/>(bwrap jail)"]
      FP --> X["X display :1"] --> KS["KasmVNC server :8444"]
    end
  end
  VIEW["Any VNC viewer<br/>(browser, node A or B)"]

  BR -- "1. offer/answer" --> SIG
  BR == "2. video, UDP" ==> RTC
  RTC --> PUMP -- "3. raw frames, TCP" --> S9000
  S9001 --> PRV -- "preview in /webcam" --> BR
  KS <--> PX <-- "HTTPS + WebSocket" --> VIEW
```

---

## Sequence diagram

```mermaid
sequenceDiagram
  autonumber
  participant B as Node B browser (/webcam)
  participant AP as auth-proxy (node A)
  participant K as kasmvnc: socat + ffmpeg
  participant D as /dev/video0
  participant FP as ffplay (VNC terminal)
  participant V as VNC viewer

  B->>AP: POST /api/login, receive auth_session cookie
  B->>B: getUserMedia(), create WebRTC offer
  B->>AP: POST /api/webcam/offer (SDP)
  AP->>AP: close old session, new RTCPeerConnection (no STUN)
  AP->>AP: rewrite host ICE candidate to node A's IP
  AP-->>B: SDP answer
  B->>AP: ICE + DTLS + SRTP video over UDP 50000-50009
  loop every frame
    AP->>AP: decode, scale to 640x480, yuv420p
    AP->>K: raw frame over TCP :9000
    K->>D: ffmpeg writes frame
  end
  V->>AP: login, then open desktop (HTTPS + WebSocket, proxied)
  V->>FP: types: ffplay -f v4l2 /dev/video0
  FP->>D: read frames
  FP->>V: window drawn on X display, KasmVNC sends screen over WebSocket
  B->>AP: GET /api/webcam/preview
  AP->>K: connect :9001 (ffmpeg re-reads /dev/video0 as MJPEG)
  AP-->>B: MJPEG "Received by server" panel
```

---

## How it works, step by step

1. **Login.** Node B logs in to `auth-proxy` on node A and gets a signed session cookie.
   Every webcam route checks it.
2. **Signalling.** The `/webcam` page grabs the camera and sends a WebRTC offer to
   `/api/webcam/offer`. `handle_offer` closes any earlier sender (there is only one
   virtual camera), creates the receiver, returns an answer, and rewrites the address in
   it to node A's real IP, because the container's own address is unreachable from node B.
3. **Media.** The video does not go through the HTTPS port. It flows from node B directly
   to `aiortc` over UDP 50000-50009. That range must be open in the firewall and published
   by Docker.
4. **Into the camera.** `_pump_video` scales each frame to 640x480 raw `yuv420p` and sends
   it over TCP to the `kasmvnc` container's port 9000. `socat` starts an `ffmpeg` per
   connection, which writes the frames into `/dev/video0`. The camera is readable only
   while this writer is running.
5. **Watching it.** `ffplay` run in a VNC terminal reads `/dev/video0` and draws its window
   on the container's X display. KasmVNC turns that display into screen updates and sends
   them over a WebSocket through `auth-proxy` to every viewer. So it appears for anyone
   viewing the desktop, whether on node A or node B, because the session is `shared`.
6. **Preview.** The "Received by server" panel is a second `ffmpeg` that reads
   `/dev/video0` back as MJPEG on port 9001 and streams it to the page, showing what node A
   actually received.

---

## Conditions and gotchas

- Run `ffplay -f v4l2 /dev/video0` in the terminal **inside the VNC desktop**. Run on node
  A's own host terminal, it draws on node A's physical screen, not in VNC.
- The camera is only readable while node B's `/webcam` page is streaming. Otherwise
  `ffplay` reports `Not a video capture device`.
- v4l2loopback must be loaded with `exclusive_caps=0` (see `SETUP.md`).
- Node B must reach node A on TCP 8445 and UDP 50000-50009. Use node A's real LAN IP (not
  a `172.x` Docker address); set `WEBCAM_PUBLIC_IP` in `.env` if the ICE candidates are
  wrong.
- Only one sender at a time: a new session replaces the previous one.
- The terminal sandbox (`jailed-shell.sh`) is given `/dev/video0`, the X socket and
  `.Xauthority` so `ffplay` works. That lets programs in the terminal see the whole
  desktop; remove those binds if you do not want that.
