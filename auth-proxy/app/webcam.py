import asyncio
import ipaddress
import os
import random

from aiortc import RTCConfiguration, RTCPeerConnection, RTCSessionDescription
from aiortc.mediastreams import MediaStreamError
from fastapi.responses import StreamingResponse

WEBCAM_HOST = os.environ.get("WEBCAM_INGEST_HOST", "kasmvnc")
WEBCAM_PORT = int(os.environ.get("WEBCAM_INGEST_PORT", "9000"))
WEBCAM_PREVIEW_PORT = int(os.environ.get("WEBCAM_PREVIEW_PORT", "9001"))

# Frames are scaled to this fixed size and sent to ffmpeg as raw yuv420p, so the
# same value must reach the kasmvnc container (both read it from .env).
_WIDTH, _HEIGHT = (int(v) for v in os.environ.get("WEBCAM_SIZE", "640x480").split("x"))

# UDP ports aiortc may use for WebRTC media; docker-compose publishes this same range.
ICE_PORT_MIN = int(os.environ.get("WEBCAM_ICE_PORT_MIN", "50000"))
ICE_PORT_MAX = int(os.environ.get("WEBCAM_ICE_PORT_MAX", "50009"))

_current_pc: RTCPeerConnection | None = None
_ports_restricted = False


def _restrict_udp_ports(loop: asyncio.AbstractEventLoop) -> None:
    """aiortc binds its media sockets to random ephemeral UDP ports; pin them to the
    published range instead so Docker can forward them. (Needs the plain asyncio
    loop, not uvloop: uvloop's Loop doesn't allow replacing methods.)"""
    global _ports_restricted
    if _ports_restricted:
        return
    original = loop.create_datagram_endpoint

    async def create_datagram_endpoint(protocol_factory, local_addr=None, **kwargs):
        if local_addr and local_addr[1] == 0:
            ports = list(range(ICE_PORT_MIN, ICE_PORT_MAX + 1))
            random.shuffle(ports)
            for port in ports:
                try:
                    return await original(
                        protocol_factory, local_addr=(local_addr[0], port), **kwargs
                    )
                except OSError:
                    continue
            raise OSError("no free UDP port in the WebRTC range")
        return await original(protocol_factory, local_addr=local_addr, **kwargs)

    loop.create_datagram_endpoint = create_datagram_endpoint
    _ports_restricted = True


def _advertise_address(sdp: str, public_host: str | None) -> str:
    """The answer lists the container's Docker-internal IP as its candidate address,
    which the browser can't reach. Swap in the address the browser used to reach us."""
    address = os.environ.get("WEBCAM_PUBLIC_IP") or public_host
    try:
        ipaddress.IPv4Address(address)
    except (ValueError, TypeError):
        return sdp  # hostname like "localhost": leave candidates untouched

    lines = []
    for line in sdp.split("\r\n"):
        if line.startswith("a=candidate:"):
            parts = line.split(" ")
            if len(parts) > 7 and parts[7] == "host" and ":" not in parts[4]:
                parts[4] = address
                line = " ".join(parts)
        lines.append(line)
    return "\r\n".join(lines)


async def _pump_video(track, pc: RTCPeerConnection) -> None:
    """Send every decoded frame to kasmvnc's ffmpeg as raw yuv420p."""
    writer = None
    frames = 0
    try:
        _, writer = await asyncio.open_connection(WEBCAM_HOST, WEBCAM_PORT)
        while True:
            frame = await track.recv()
            frame = frame.reformat(width=_WIDTH, height=_HEIGHT, format="yuv420p")
            writer.write(frame.to_ndarray().tobytes())
            await writer.drain()
            frames += 1
    except (MediaStreamError, ConnectionError, RuntimeError, OSError):
        pass
    finally:
        print(f"webcam: stream ended after {frames} frames", flush=True)
        if writer is not None:
            writer.close()
        await pc.close()


async def handle_offer(sdp: str, sdp_type: str, public_host: str | None) -> dict:
    """WebRTC signalling: take the browser's offer, return our answer. The video then
    flows browser -> auth-proxy directly over UDP, not through this HTTP request."""
    global _current_pc
    _restrict_udp_ports(asyncio.get_running_loop())

    # One virtual camera, so a new session replaces the previous one.
    if _current_pc is not None:
        await _current_pc.close()

    # No STUN servers: everything is on a private network, and the default Google
    # STUN server would stall ICE gathering on a machine without internet access.
    pc = RTCPeerConnection(RTCConfiguration(iceServers=[]))
    _current_pc = pc

    @pc.on("track")
    def on_track(track):
        if track.kind == "video":
            asyncio.ensure_future(_pump_video(track, pc))

    @pc.on("connectionstatechange")
    async def on_state_change():
        print(f"webcam: WebRTC connection {pc.connectionState}", flush=True)
        if pc.connectionState in ("failed", "closed"):
            await pc.close()

    await pc.setRemoteDescription(RTCSessionDescription(sdp=sdp, type=sdp_type))
    await pc.setLocalDescription(await pc.createAnswer())
    return {
        "sdp": _advertise_address(pc.localDescription.sdp, public_host),
        "type": pc.localDescription.type,
    }


async def stream_preview() -> StreamingResponse:
    """Stream the virtual camera back as MJPEG so the browser can show what the server received."""
    try:
        reader, writer = await asyncio.open_connection(WEBCAM_HOST, WEBCAM_PREVIEW_PORT)
    except OSError:
        return StreamingResponse(iter(()), status_code=503)

    async def chunks():
        try:
            while True:
                data = await reader.read(65536)
                if not data:
                    return
                yield data
        finally:
            writer.close()

    return StreamingResponse(
        chunks(), media_type="multipart/x-mixed-replace;boundary=ffmpeg"
    )
