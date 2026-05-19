#!/bin/sh
# Копирует sh-скрипты из /opt/scripts (volume) в /opt/bin (с executable)
# Xray stub в /opt/bin/xray уже есть в образе — не перезаписываем

for f in /opt/scripts/*.sh; do
    [ -f "$f" ] || continue
    name=$(basename "$f")
    cp "$f" "/opt/bin/$name"
    chmod +x "/opt/bin/$name"
done

# Переименовываем системный ip в ip.real чтобы наш stub мог его вызвать
if [ -f /sbin/ip ] && [ ! -f /usr/local/bin/ip.real ]; then
    cp /sbin/ip /usr/local/bin/ip.real
fi

exec "$@"
