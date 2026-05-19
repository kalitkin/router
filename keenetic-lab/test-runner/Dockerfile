FROM alpine:3.19

# Базовые инструменты
RUN apk add --no-cache \
    bash curl wget \
    grep sed gawk \
    coreutils util-linux \
    procps psmisc \
    iproute2 \
    jq

# Необходимые директории (Entware-style layout)
RUN mkdir -p \
    /opt/bin \
    /opt/sbin \
    /opt/etc/vpn \
    /opt/etc/xray \
    /opt/etc/init.d \
    /opt/var/log \
    /opt/var/run \
    /opt/scripts

# Стаб-команды: опережают системные (PATH начинается с /usr/local/bin)
COPY stubs/opkg     /usr/local/bin/opkg
COPY stubs/iptables /usr/local/bin/iptables
COPY stubs/ip       /usr/local/bin/ip
COPY stubs/modprobe /usr/local/bin/modprobe
RUN chmod +x \
    /usr/local/bin/opkg \
    /usr/local/bin/iptables \
    /usr/local/bin/ip \
    /usr/local/bin/modprobe

# Xray stub в /opt/bin (реальные скрипты монтируются в /opt/scripts и копируются entrypoint-ом)
COPY stubs/xray /opt/bin/xray
RUN chmod +x /opt/bin/xray

# Entrypoint копирует *.sh из /opt/scripts → /opt/bin
COPY entrypoint.sh /entrypoint.sh
COPY test.sh       /test.sh
RUN chmod +x /entrypoint.sh /test.sh

# Реальный ip переименовываем чтобы наш stub мог его вызвать
RUN cp /sbin/ip /usr/local/bin/ip.real 2>/dev/null || true

ENV PATH="/opt/bin:/usr/local/bin:/usr/bin:/bin"

ENTRYPOINT ["/entrypoint.sh"]
CMD ["/test.sh"]
