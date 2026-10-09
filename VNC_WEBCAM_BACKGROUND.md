# VNC and Webcam Passthrough: Background

## 1. What VNC is

VNC lets you see and control another computer's desktop over a network. The server sends
**screen pixels**; the client sends **keyboard and mouse events**. Nothing else.

This project uses **KasmVNC**, which includes a web client, so the desktop opens in a
browser over HTTPS. It runs an XFCE desktop with Firefox in Docker. Several people can open
the same desktop at once.

**Custom login screen (POC).** For this proof of concept I designed my own sign-in screen
instead of using KasmVNC's built-in login. A small service called **auth-proxy** sits in
front of the desktop:

- It serves the custom login page, and checks the username and password.
- After a successful sign-in it issues a session cookie that ends when the browser closes.
- It forwards traffic to the desktop, and accepts the webcam stream, only for signed-in
  users.
- The KasmVNC desktop itself is not reachable from outside, so the login screen is the
  only way in.

```mermaid
flowchart LR
  V["VNC viewer<br/>(browser)"] -- "1. sign in" --> L["Custom login screen<br/>auth-proxy"]
  L -- "2. session cookie" --> V
  V -- "keyboard + mouse" --> L
  L -- "signed-in traffic only" --> S["KasmVNC server<br/>desktop"]
  S -- "screen pixels" --> L
  L --> V
  CAM["Webcam"] -. "no path" .-> S
  classDef client fill:#DBEAFE,stroke:#2563EB,color:#1E3A8A
  classDef gateway fill:#EDE9FE,stroke:#7C3AED,color:#4C1D95
  classDef desktop fill:#CCFBF1,stroke:#0D9488,color:#134E4A
  classDef camera fill:#DCFCE7,stroke:#16A34A,color:#14532D,stroke-width:2px
  classDef viewer fill:#FEF3C7,stroke:#D97706,color:#78350F
  classDef gap fill:#FEE2E2,stroke:#DC2626,color:#7F1D1D,stroke-dasharray:4 3
  class V viewer
  class L gateway
  class S desktop
  class CAM gap
  linkStyle default stroke:#6B7280
  linkStyle 6 stroke:#DC2626,stroke-dasharray:4 3
```

---

## 2. Why video input is hard

- **VNC has no camera channel.** It only carries pixels out and input in.
- **The camera is on another machine.** The desktop runs in a container with no camera, and
  only the browser on that machine can read the webcam.
- **Apps need a real camera device.** On Linux that is `/dev/video0`, which a container
  cannot create. It comes from a kernel module (`v4l2loopback`) on the host.
- **Normal web transport is a poor fit for live video.** TCP and WebSocket stall on a lost
  packet, so video lags.
- **Network details.** Real-time media uses UDP, and the server's address inside Docker is
  not the one the browser can reach.
- **The webcam path must stay behind the login.** Only signed-in users may send video, so
  the WebRTC setup goes through the same custom login as the desktop.
- **One virtual camera**, so only one sender at a time.

---

## 3. How WebRTC solves it here

**WebRTC** is the browser's built-in way to send live video over UDP. A late packet is
dropped instead of blocking the rest, so video stays smooth.

The browser sends the webcam to the server with WebRTC. The server converts it into raw
frames and writes them into the virtual camera `/dev/video0`. Any app in the desktop that
reads a webcam can then open it as a normal camera.

**Two machines are involved:**

- **Node B** is the client PC. It has the webcam, and its browser sends the video.
- **Node A** is the Linux server that runs Docker. It hosts the VNC desktop and the
  auth-proxy login service, each in its own container.

### Flow chart

```mermaid
flowchart TB
  subgraph NB["Node B: client PC with the webcam"]
    CAM["Webcam"] --> BR["Browser, /webcam page<br/>signed in, sends video with WebRTC"]
  end
  subgraph NA["Node A: Linux server running Docker"]
    subgraph C1["auth-proxy container"]
      AP["auth-proxy<br/>decodes video to 640x480 raw frames"]
    end
    subgraph C2["VNC desktop container"]
      FF["ffmpeg"] --> DEV[("/dev/video0<br/>virtual camera")]
      DEV --> APP["App in the desktop<br/>reads the camera"]
    end
  end
  BR -- "UDP 50000-50009" --> AP
  AP -- "TCP :9000" --> FF
  APP -- "screen updates" --> VIEW["Every VNC viewer"]
  classDef client fill:#DBEAFE,stroke:#2563EB,color:#1E3A8A
  classDef gateway fill:#EDE9FE,stroke:#7C3AED,color:#4C1D95
  classDef desktop fill:#CCFBF1,stroke:#0D9488,color:#134E4A
  classDef camera fill:#DCFCE7,stroke:#16A34A,color:#14532D,stroke-width:2px
  classDef viewer fill:#FEF3C7,stroke:#D97706,color:#78350F
  classDef gap fill:#FEE2E2,stroke:#DC2626,color:#7F1D1D,stroke-dasharray:4 3
  class CAM,BR client
  class AP gateway
  class FF desktop
  class DEV,APP camera
  class VIEW viewer
  style NB fill:#EFF6FF,stroke:#2563EB,stroke-dasharray:4 3,color:#1E3A8A
  style NA fill:#F3F4F6,stroke:#9CA3AF,color:#374151
  style C1 fill:#F5F3FF,stroke:#7C3AED,color:#4C1D95
  style C2 fill:#F0FDFA,stroke:#0D9488,color:#134E4A
  linkStyle default stroke:#6B7280
  linkStyle 1,3,4 stroke:#16A34A,stroke-width:3px
```

**Color key** (same in every diagram):
blue = client PC and browser · violet = auth-proxy and the login screen ·
teal = the VNC desktop and its processes · green = the virtual camera and the app that
reads it · amber = people viewing the desktop · red dashed = no path.

### Sequence diagram

```mermaid
sequenceDiagram
  autonumber
  box rgba(37, 99, 235, 0.15) Node B: client PC
    participant B as Browser<br/>(/webcam page)
  end
  box rgba(13, 148, 136, 0.15) Node A: Linux server running Docker
    participant AP as auth-proxy<br/>(container)
    participant K as ffmpeg<br/>(desktop container)
    participant D as /dev/video0<br/>(virtual camera)
    participant F as App in the<br/>VNC desktop
  end

  B->>AP: sign in on the custom login screen
  AP-->>B: session cookie
  B->>AP: WebRTC offer over HTTPS (signed-in only)
  AP-->>B: WebRTC answer
  rect rgba(22, 163, 74, 0.15)
    B->>AP: video over UDP
    loop every frame
      AP->>K: raw frame over TCP
      K->>D: write frame
    end
    F->>D: read frames
  end
```

---

## 4. Versions used

| Component | Version |
|---|---|
| Ubuntu (desktop container) | 22.04 |
| KasmVNC | 1.5.0 |
| Python (auth-proxy) | 3.12 |
| Node (frontend build) | 20 |
| aiortc (WebRTC) | 1.9.0 |
| FastAPI | 0.115.0 |
| Uvicorn | 0.30.6 |
| httpx | 0.27.2 |
| websockets | 13.1 |
| PyJWT | 2.9.0 |
| NumPy | 1.26.4 |
| React | ^18.3.1 |
| Vite | ^5.4.8 |
| ffmpeg | 4.4.2 |
| Docker (host) | 29.8.1 |
| Linux kernel (host) | 5.15.0-191 |

Firefox, XFCE, socat and the other system tools are not pinned. They install
the latest version available at build time.

---

## 5. Limits

- One sender at a time.
- The camera is readable only while the `/webcam` page is streaming.
- TCP 8445 and UDP 50000-50009 must be open between the two machines.
- `v4l2loopback` must be loaded with `exclusive_caps=0` on this server.
