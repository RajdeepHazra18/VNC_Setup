import asyncio
import os

import httpx
import websockets
from fastapi import Request, WebSocket
from fastapi.responses import Response
from starlette.websockets import WebSocketDisconnect, WebSocketState

KASMVNC_URL = os.environ.get("KASMVNC_URL", "http://kasmvnc:8444")
KASMVNC_WS_URL = KASMVNC_URL.replace("http://", "ws://", 1).replace("https://", "wss://", 1)

_HOP_BY_HOP_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
    "content-length",
    "host",
}

_client = httpx.AsyncClient(base_url=KASMVNC_URL, timeout=30.0)


async def proxy_http(request: Request, path: str) -> Response:
    url = httpx.URL(path=f"/{path}", query=request.url.query.encode("utf-8"))
    headers = {
        k: v for k, v in request.headers.items() if k.lower() not in _HOP_BY_HOP_HEADERS
    }
    body = await request.body()

    upstream_request = _client.build_request(
        request.method, url, headers=headers, content=body
    )
    upstream_response = await _client.send(upstream_request, stream=True)

    response_headers = {
        k: v
        for k, v in upstream_response.headers.items()
        if k.lower() not in _HOP_BY_HOP_HEADERS
    }

    return Response(
        content=await upstream_response.aread(),
        status_code=upstream_response.status_code,
        headers=response_headers,
    )


async def proxy_websocket(client_ws: WebSocket, path: str) -> None:
    target = f"{KASMVNC_WS_URL}/{path}"
    if client_ws.url.query:
        target = f"{target}?{client_ws.url.query}"

    requested_protocols = [
        p.strip()
        for p in client_ws.headers.get("sec-websocket-protocol", "").split(",")
        if p.strip()
    ]
    # KasmVNC requires an Origin header on the upgrade request (404s without one);
    # the `websockets` client doesn't send one unless told to, so forward the
    # browser's actual Origin through.
    origin = client_ws.headers.get("origin")

    try:
        # ping_interval=None: this connection already carries a continuous stream of
        # real desktop frames, so it doesn't need a synthetic liveness check on top —
        # the library's default 20s ping/pong was killing otherwise-healthy sessions
        # on any brief internal-network hiccup.
        upstream_ws = await websockets.connect(
            target, subprotocols=requested_protocols or None, origin=origin, ping_interval=None
        )
    except Exception:
        await client_ws.close(code=1011)  # internal error
        return

    await client_ws.accept(subprotocol=upstream_ws.subprotocol)

    try:

        async def client_to_upstream():
            try:
                while True:
                    message = await client_ws.receive()
                    if message["type"] == "websocket.disconnect":
                        return
                    if "bytes" in message and message["bytes"] is not None:
                        await upstream_ws.send(message["bytes"])
                    elif "text" in message and message["text"] is not None:
                        await upstream_ws.send(message["text"])
            except WebSocketDisconnect:
                pass

        async def upstream_to_client():
            async for message in upstream_ws:
                if client_ws.client_state != WebSocketState.CONNECTED:
                    return
                if isinstance(message, bytes):
                    await client_ws.send_bytes(message)
                else:
                    await client_ws.send_text(message)

        done, pending = await asyncio.wait(
            [asyncio.create_task(client_to_upstream()), asyncio.create_task(upstream_to_client())],
            return_when=asyncio.FIRST_COMPLETED,
        )
        for task in pending:
            task.cancel()
    finally:
        await upstream_ws.close()
        if client_ws.client_state == WebSocketState.CONNECTED:
            await client_ws.close()
