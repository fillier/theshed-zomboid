FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# PZ server requires 32-bit libs; curl/jq for mod management; tini for signal handling
RUN dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        lib32gcc-s1 \
        lib32stdc++6 \
        curl \
        jq \
        ca-certificates \
        wget \
        tini \
        gosu \
        python3-minimal \
    && rm -rf /var/lib/apt/lists/*

# Install SteamCMD and pre-initialise it (triggers self-update at build time,
# not at runtime — avoids any self-update restart issues during the app install)
RUN mkdir -p /opt/steamcmd && \
    wget -qO- https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz | \
    tar -xzf - -C /opt/steamcmd && \
    /opt/steamcmd/steamcmd.sh +quit || true

ENV STEAMCMDDIR=/opt/steamcmd

# Pre-create volume mount points owned by root
RUN mkdir -p /server /data

COPY scripts/ /app/scripts/
RUN chmod +x /app/scripts/*.sh /app/scripts/*.py

# /server = PZ dedicated server installation (~3GB)
# /data   = PZ configdir: saves, server config, logs
VOLUME ["/server", "/data"]

WORKDIR /server

EXPOSE 16261/udp
EXPOSE 16262/udp
EXPOSE 27015/tcp

ENTRYPOINT ["/usr/bin/tini", "--", "/app/scripts/entrypoint.sh"]
