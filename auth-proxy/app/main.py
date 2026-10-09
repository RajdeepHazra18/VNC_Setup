from pathlib import Path

from fastapi import FastAPI, Request, WebSocket
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from starlette.websockets import WebSocketDisconnect

from . import auth, proxy, webcam

FRONTEND_DIST = Path(__file__).resolve().parent.parent / "frontend" / "dist"

app = FastAPI()
# Namespaced under /_login/ so it can't collide with KasmVNC's own "/assets/*"
# paths, which flow through the catch-all proxy route below once authenticated.
app.mount(
    "/_login/assets",
    StaticFiles(directory=FRONTEND_DIST / "assets"),
    name="login-assets",
)


@app.get("/login")
async def login_page():
    return FileResponse(FRONTEND_DIST / "index.html")


@app.post("/api/login")
async def api_login(request: Request):
    body = await request.json()
    username = body.get("username", "")
    password = body.get("password", "")

    if not auth.check_credentials(username, password):
        return JSONResponse({"error": "Invalid username or password"}, status_code=401)

    response = JSONResponse({"ok": True})
    auth.set_session_cookie(response)
    return response


@app.post("/api/logout")
async def api_logout():
    response = JSONResponse({"ok": True})
    auth.clear_session_cookie(response)
    return response


# Webcam routes must be declared before the catch-all proxy routes below, or
# "/webcam" and "/api/webcam*" would be forwarded to KasmVNC instead.
@app.get("/webcam")
async def webcam_page(request: Request):
    if not auth.is_authenticated(request):
        return RedirectResponse(url="/login")
    return FileResponse(FRONTEND_DIST / "index.html")


@app.get("/api/webcam/preview")
async def webcam_preview(request: Request):
    if not auth.is_authenticated(request):
        return JSONResponse({"error": "Unauthorized"}, status_code=401)
    return await webcam.stream_preview()


@app.post("/api/webcam/offer")
async def webcam_offer(request: Request):
    # WebRTC signalling only; the video itself flows over UDP, not through this route.
    if not auth.is_authenticated(request):
        return JSONResponse({"error": "Unauthorized"}, status_code=401)
    body = await request.json()
    answer = await webcam.handle_offer(body["sdp"], body["type"], request.url.hostname)
    return JSONResponse(answer)


@app.api_route(
    "/{path:path}",
    methods=["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"],
)
async def proxied_http(request: Request, path: str):
    if not auth.is_authenticated(request):
        return RedirectResponse(url="/login")
    return await proxy.proxy_http(request, path)


@app.websocket("/{path:path}")
async def proxied_websocket(websocket: WebSocket, path: str):
    if not auth.is_authenticated(websocket):
        await websocket.close(code=1008)  # policy violation
        return
    try:
        await proxy.proxy_websocket(websocket, path)
    except WebSocketDisconnect:
        pass
