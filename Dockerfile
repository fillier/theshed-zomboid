FROM cm2network/steamcmd:root

# PZ dedicated server requires 32-bit libraries and curl/jq for mod management
RUN dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        lib32gcc-s1 \
        lib32stdc++6 \
        curl \
        jq \
        ca-certificates \
        tini \
    && rm -rf /var/lib/apt/lists/*

# Copy management scripts
COPY scripts/ /app/scripts/
RUN chmod +x /app/scripts/*.sh

# /server = PZ dedicated server installation (large, ~3GB)
# /data   = PZ configdir: saves, server config, logs
VOLUME ["/server", "/data"]

WORKDIR /server

# Primary game port (UDP), secondary game port (UDP = primary+1), RCON (TCP)
EXPOSE 16261/udp
EXPOSE 16262/udp
EXPOSE 27015/tcp

# tini as init to handle signals and zombie processes properly
ENTRYPOINT ["/usr/bin/tini", "--", "/app/scripts/entrypoint.sh"]
