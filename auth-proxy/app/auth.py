import os
import secrets
import time

import jwt

COOKIE_NAME = "auth_session"

AUTH_USERNAME = os.environ["AUTH_USERNAME"]
AUTH_PASSWORD = os.environ["AUTH_PASSWORD"]

# Generated fresh every time this process starts (never stored, never in .env) —
# since start.sh runs a single uvicorn process, this is one random key per
# container start. Restarting the stack invalidates every previously issued token.
JWT_SECRET = secrets.token_hex(32)
JWT_ALGORITHM = "HS256"

# Backstop only — the cookie itself is a browser-session cookie (no Max-Age), so
# closing the browser is what normally ends the session. This just caps how long a
# copied-out token could be replayed if it ever left the cookie jar.
_BACKSTOP_SECONDS = 24 * 60 * 60


def check_credentials(username: str, password: str) -> bool:
    return secrets.compare_digest(username, AUTH_USERNAME) and secrets.compare_digest(
        password, AUTH_PASSWORD
    )


def create_session_token() -> str:
    now = int(time.time())
    payload = {"user": AUTH_USERNAME, "iat": now, "exp": now + _BACKSTOP_SECONDS}
    return jwt.encode(payload, JWT_SECRET, algorithm=JWT_ALGORITHM)


def verify_session_token(token: str | None) -> bool:
    if not token:
        return False
    try:
        jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
    except jwt.PyJWTError:
        return False
    return True


def is_authenticated(request) -> bool:
    return verify_session_token(request.cookies.get(COOKIE_NAME))


def set_session_cookie(response) -> None:
    # No max_age/expires: a real browser-session cookie, cleared when the browser closes.
    response.set_cookie(
        COOKIE_NAME,
        create_session_token(),
        httponly=True,
        secure=True,
        samesite="lax",
        path="/",
    )


def clear_session_cookie(response) -> None:
    response.delete_cookie(COOKIE_NAME, path="/")
