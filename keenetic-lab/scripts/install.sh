#!/bin/sh
# install.sh — установка VPN-агента на Keenetic через Entware
# Запускать с роутера:
#   wget -O - https://self-music.online/keenetic/install.sh | sh
# или:
#   curl -fsSL https://self-music.online/keenetic/install.sh | sh

set -e

BASE_URL="${VPN_BASE_URL:-https://self-music.online}"
SCRIPTS_URL="$BASE_URL/keenetic"
XRAY_URL="$BASE_URL/packages/latest"
DIR="/opt/etc/vpn"
BIN="/opt/bin"
INITD="/opt/etc/init.d"
LOG="/opt/var/log/vpn-install.log"

log()  { echo "$(date '+%Y-%m-%d %H:%M:%S') [install] $*" | tee -a "$LOG"; }
die()  { log "ERROR: $*"; exit 1; }
info() { log "INFO:  $*"; }

MANIFEST=""  # заполняется в fetch_manifest

# ── Проверки окружения ────────────────────────────────────────────────────────

check_entware() {
    [ -f /opt/etc/opkg.conf ] || die "Entware не установлен. Установите Entware сначала: https://help.keenetic.com/hc/ru/articles/360021214160"
    command -v opkg > /dev/null 2>&1 || die "opkg не найден"
    info "Entware найден: $(opkg --version 2>&1 | head -1)"
}

check_internet() {
    if ! curl -s -m 10 -o /dev/null "$BASE_URL"; then
        die "Нет доступа к $BASE_URL — проверьте интернет-соединение"
    fi
    info "Интернет: OK"
}

# ── Manifest ──────────────────────────────────────────────────────────────────

fetch_manifest() {
    MANIFEST=$(curl -fsSL -m 10 "$SCRIPTS_URL/manifest.txt" 2>/dev/null || true)
    if [ -n "$MANIFEST" ]; then
        count=$(printf '%s' "$MANIFEST" | grep -c '^[a-f0-9]' || echo 0)
        info "manifest.txt загружен ($count файлов)"
    else
        log "WARN: manifest.txt недоступен — пропускаем проверку целостности"
    fi
}

verify_sha256() {
    # $1 = путь к файлу, $2 = имя файла (как в manifest)
    [ -z "$MANIFEST" ] && return 0
    expected=$(printf '%s' "$MANIFEST" | awk -v f="$2" '$3==f {print $1}')
    [ -z "$expected" ] && return 0
    if ! command -v sha256sum > /dev/null 2>&1; then
        log "  WARN: sha256sum недоступен — пропускаем проверку $2"
        return 0
    fi
    actual=$(sha256sum "$1" | cut -d' ' -f1)
    if [ "$actual" != "$expected" ]; then
        die "Целостность нарушена: $2 (ожидался $expected, получен $actual)"
    fi
    info "  sha256 OK: $2"
}

# ── Архитектура ───────────────────────────────────────────────────────────────

detect_arch() {
    ARCH=""

    if command -v opkg > /dev/null 2>&1; then
        ARCH=$(opkg print-architecture 2>/dev/null | \
            awk '$1=="arch" && $3>=10 {print $2}' | \
            grep -v 'all\|noarch' | tail -1)
    fi

    if [ -z "$ARCH" ]; then
        case "$(uname -m)" in
            mips*)   ARCH="mipsel_24kc" ;;
            armv7*)  ARCH="arm_cortex-a7_neon-vfpv4" ;;
            aarch64) ARCH="aarch64_cortex-a53" ;;
            *)       die "Неизвестная архитектура: $(uname -m)" ;;
        esac
    fi

    info "Архитектура: $ARCH"
}

# ── Установка зависимостей ────────────────────────────────────────────────────

install_packages() {
    info "Обновляем списки пакетов..."
    opkg update 2>&1 | tail -3 | while read -r line; do log "  opkg: $line"; done || true

    for pkg in curl wget iptables kmod-ipt-tproxy ip-full; do
        if opkg list-installed 2>/dev/null | grep -q "^$pkg "; then
            info "  $pkg — уже установлен"
        else
            info "  Устанавливаем $pkg..."
            opkg install "$pkg" 2>&1 | tail -2 | while read -r line; do log "    $line"; done || \
                log "  WARN: $pkg установить не удалось (продолжаем)"
        fi
    done
}

# ── xray-core ─────────────────────────────────────────────────────────────────

install_xray() {
    XRAY_BIN="/opt/sbin/xray"

    # Уже установлен?
    if [ -f "$XRAY_BIN" ] && "$XRAY_BIN" version > /dev/null 2>&1; then
        info "xray уже установлен: $("$XRAY_BIN" version 2>&1 | head -1)"
        return 0
    fi

    # Пробуем opkg
    info "Устанавливаем xray-core через opkg..."
    if opkg install xray-core 2>&1 | grep -q "Installed\|already"; then
        info "xray-core установлен через opkg"
        XRAY_BIN=$(command -v xray || echo "/opt/sbin/xray")
        return 0
    fi

    # CDN fallback
    info "opkg не сработал — скачиваем xray с CDN ($ARCH)..."
    XRAY_CDN="$XRAY_URL/$ARCH/xray"
    TMP_XRAY="/tmp/xray.tmp"

    if ! curl -fsSL -m 60 -o "$TMP_XRAY" "$XRAY_CDN"; then
        die "Не удалось скачать xray с $XRAY_CDN"
    fi

    install -m 755 "$TMP_XRAY" "$XRAY_BIN"
    rm -f "$TMP_XRAY"

    if ! "$XRAY_BIN" version > /dev/null 2>&1; then
        die "xray скачан, но не запускается — несовместимая архитектура?"
    fi

    info "xray установлен с CDN: $("$XRAY_BIN" version 2>&1 | head -1)"
}

# ── Скрипты агента ────────────────────────────────────────────────────────────

install_scripts() {
    mkdir -p "$BIN" "$DIR" "$INITD" /opt/var/log /opt/var/run /opt/etc/xray

    for script in keenetic-agent.sh keenetic-apply.sh keenetic-connect.sh; do
        info "Скачиваем $script..."
        if ! curl -fsSL -m 30 -o "$BIN/$script.tmp" "$SCRIPTS_URL/$script"; then
            die "Не удалось скачать $script"
        fi
        verify_sha256 "$BIN/$script.tmp" "$script"
        mv "$BIN/$script.tmp" "$BIN/$script"
        chmod +x "$BIN/$script"
        info "  $BIN/$script — OK"
    done

    # bypass-листы
    for f in bypass_ips.txt bypass_domains.txt; do
        info "Скачиваем $f..."
        curl -fsSL -m 30 -o "$DIR/$f.tmp" "$BASE_URL/router/$f" 2>/dev/null && \
            mv "$DIR/$f.tmp" "$DIR/$f" || \
            log "  WARN: $f не скачан (продолжаем без него)"
    done

    # init.d
    info "Устанавливаем S99vpn-agent..."
    if ! curl -fsSL -m 30 -o "$INITD/S99vpn-agent.tmp" "$SCRIPTS_URL/S99vpn-agent"; then
        die "Не удалось скачать S99vpn-agent"
    fi
    verify_sha256 "$INITD/S99vpn-agent.tmp" "S99vpn-agent"
    mv "$INITD/S99vpn-agent.tmp" "$INITD/S99vpn-agent"
    chmod +x "$INITD/S99vpn-agent"
    info "  $INITD/S99vpn-agent — OK"
}

# ── kmod-ipt-tproxy ───────────────────────────────────────────────────────────

load_tproxy_module() {
    if lsmod 2>/dev/null | grep -q "xt_TPROXY"; then
        info "Модуль xt_TPROXY уже загружен"
        return 0
    fi

    info "Загружаем xt_TPROXY..."
    modprobe xt_TPROXY 2>/dev/null && info "  xt_TPROXY загружен" || \
        log "  WARN: modprobe xt_TPROXY не удался — TProxy может не работать до перезагрузки"

    # Автозагрузка
    MODULES_CONF="/opt/etc/modules.d/99-tproxy"
    if [ ! -f "$MODULES_CONF" ]; then
        echo "xt_TPROXY" > "$MODULES_CONF"
        info "  Добавлен автозапуск модуля"
    fi
}

# ── Проверка установки ────────────────────────────────────────────────────────

verify_install() {
    ok=1

    for f in "$BIN/keenetic-agent.sh" "$BIN/keenetic-apply.sh" "$BIN/keenetic-connect.sh" "$INITD/S99vpn-agent"; do
        if [ -f "$f" ] && [ -x "$f" ]; then
            info "  ✓ $f"
        else
            log "  ✗ $f — ОТСУТСТВУЕТ или не исполняемый"
            ok=0
        fi
    done

    XRAY_BIN=$(command -v xray 2>/dev/null || echo "/opt/sbin/xray")
    if [ -f "$XRAY_BIN" ] && "$XRAY_BIN" version > /dev/null 2>&1; then
        info "  ✓ xray: $("$XRAY_BIN" version 2>&1 | head -1)"
    else
        log "  ✗ xray — НЕ НАЙДЕН"
        ok=0
    fi

    [ "$ok" -eq 1 ] || die "Установка не завершена — проверьте лог: $LOG"
}

# ── MAIN ──────────────────────────────────────────────────────────────────────

mkdir -p /opt/var/log
log "=== Начало установки VPN-агента ==="
log "Дата: $(date)"
log "Модель: $(cat /proc/sys/keenetic/model 2>/dev/null || uname -a)"

check_entware
check_internet
fetch_manifest
detect_arch
install_packages
install_xray
install_scripts
load_tproxy_module
verify_install

log "=== Установка завершена ==="

echo ""
echo "Установка завершена!"
echo ""
echo "Для регистрации роутера запустите:"
echo "  sh /opt/bin/keenetic-connect.sh XXXXXX"
echo "  (XXXXXX — 6-значный код из Telegram)"
echo ""
echo "Лог установки: $LOG"
