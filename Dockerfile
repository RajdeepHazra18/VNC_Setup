FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    DISPLAY=:1 \
    HOME=/home/dockeruser \
    RESOLUTION=1280x800 \
    KASM_VERSION=1.5.0

# XFCE desktop plus dependencies needed to install/run KasmVNC and Firefox
RUN apt-get update && apt-get install -y --no-install-recommends \
        xfce4 \
        xfce4-terminal \
        dbus-x11 \
        xterm \
        sudo \
        gosu \
        bubblewrap \
        locales \
        wget \
        ca-certificates \
        xz-utils \
        libgtk-3-0 \
        libdbus-glib-1-2 \
        libx11-xcb1 \
        libasound2 \
        fonts-liberation \
        ffmpeg \
        libblas3 \
        liblapack3 \
        socat \
        v4l-utils \
    && locale-gen en_US.UTF-8 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8

# KasmVNC: combined virtual framebuffer + VNC server + built-in HTTPS/WebSocket web
# client — replaces the old Xvfb + x11vnc + noVNC + websockify stack (pinned to 1.5.0)
RUN wget -q -O /tmp/kasmvncserver.deb \
        "https://github.com/kasmtech/KasmVNC/releases/download/v${KASM_VERSION}/kasmvncserver_jammy_${KASM_VERSION}_amd64.deb" \
    && apt-get update && apt-get install -y /tmp/kasmvncserver.deb \
    && rm /tmp/kasmvncserver.deb \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Firefox via Mozilla's official tarball (Ubuntu 22.04's apt "firefox" package is a
# snap stub and won't run inside a container without snapd)
RUN wget -q -O /tmp/firefox.tar.xz "https://download.mozilla.org/?product=firefox-latest&os=linux64&lang=en-US" \
    && tar -xJf /tmp/firefox.tar.xz -C /opt/ \
    && rm /tmp/firefox.tar.xz \
    && ln -s /opt/firefox/firefox /usr/local/bin/firefox \
    && update-alternatives --install /usr/bin/x-www-browser x-www-browser /opt/firefox/firefox 200

RUN mkdir -p /usr/share/applications && \
    printf '[Desktop Entry]\nName=Firefox\nExec=/opt/firefox/firefox %%u\nTerminal=false\nType=Application\nIcon=/opt/firefox/browser/chrome/icons/default/default128.png\nCategories=Network;WebBrowser;\nMimeType=text/html;text/xml;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;\n' > /usr/share/applications/firefox.desktop \
    && mkdir -p /usr/share/xfce4/helpers && \
    printf '[Desktop Entry]\nVersion=1.0\nEncoding=UTF-8\nType=X-XFCE-Helper\nX-XFCE-Category=WebBrowser\nX-XFCE-CommandsWithParameter=/opt/firefox/firefox "%%s"\nX-XFCE-Commands=/opt/firefox/firefox\nIcon=firefox\nName=Firefox\n' > /usr/share/xfce4/helpers/firefox.desktop

# jailed-shell.sh: dockeruser's login shell. Every terminal opened inside the XFCE
# session (xfce4-terminal, xterm) resolves and execs this with no arguments, wrapping
# the real interactive shell in a bubblewrap sandbox pinned to the currently-exposed
# project directory ($EXPOSE_PATH) — so a terminal can't cd/sudo its way out to other
# projects or the rest of the home directory. Does not affect Firefox, which XFCE
# launches directly via its .desktop Exec= line, nor workspace-agent-entrypoint.sh's
# own direct exec of start.sh via gosu.
COPY jailed-shell.sh /usr/local/bin/jailed-shell.sh
COPY jail-guard.sh /usr/local/lib/jail-guard.sh
RUN chmod +x /usr/local/bin/jailed-shell.sh

# Non-root user to run the desktop session (XFCE refuses to run cleanly as root).
# Added to ssl-cert so KasmVNC's built-in HTTPS server can use its self-signed cert,
# and to video so it can write to the v4l2loopback virtual camera (/dev/video0).
# Per-user config files (.vnc/kasmvnc.yaml, .config/xfce4/helpers.rc) are written by
# start.sh at container startup, not here — /home/dockeruser is bind-mounted from the
# host, which would shadow anything baked in at this path during the image build.
# Shell is jailed-shell.sh, not /bin/bash directly, so every terminal is sandboxed —
# see the comment above. sudo stays installed/NOPASSWD for use outside a jailed
# terminal; bwrap's unconditional PR_SET_NO_NEW_PRIVS neutralizes it inside the jail
# regardless of sudoers content (sudo itself refuses to run once NNP is set).
RUN useradd -m -s /usr/local/bin/jailed-shell.sh dockeruser \
    && echo "dockeruser ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers \
    && usermod -aG ssl-cert,video dockeruser \
    && echo 'SHELL=/usr/local/bin/jailed-shell.sh' >> /etc/environment

COPY start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh

# workspace-agent: root-owned NFS/fixture mount + mount --bind of the active project into
# the desktop user's workspace, then privilege-drop to dockeruser. See
# workspace-agent/ for the shared mount/switch scripts.
COPY workspace-agent/lib/ /usr/local/lib/workspace-agent/
COPY workspace-agent/bin/workspace-agent-entrypoint.sh /usr/local/bin/workspace-agent-entrypoint.sh
COPY workspace-agent/bin/switch-project.sh /usr/local/bin/switch-project.sh
RUN chmod +x /usr/local/lib/workspace-agent/common.sh \
    /usr/local/bin/workspace-agent-entrypoint.sh \
    /usr/local/bin/switch-project.sh

# NOTE: no `USER dockeruser` here — the container must start as root so
# workspace-agent-entrypoint.sh can `mount --bind` (needs CAP_SYS_ADMIN). It drops
# privilege to dockeruser itself via `gosu` before exec'ing start.sh.
WORKDIR /home/dockeruser

EXPOSE 8444

ENTRYPOINT ["/usr/local/bin/workspace-agent-entrypoint.sh"]
CMD ["/usr/local/bin/start.sh"]
