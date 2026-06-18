#!/bin/sh
# ==========================================================
# NetBird Installer для Keenetic v3.2 (С гибкой настройкой веб-сервера)
# ==========================================================

set -e

# --- 1. Базовые настройки ---
VERSION="3.2"
SCRIPT_NAME="netbird-install.sh"
LOG_DIR="/opt/var/log/netbird"
BACKUP_DIR="/opt/backups/netbird"
CONFIG_DIR="/opt/etc/netbird"
NETBIRD_IFACE="${NETBIRD_IFACE:-wt0}"
WEB_PORT="${WEB_PORT:-8989}"
INSTALL_WEB="${INSTALL_WEB:-true}"  # По умолчанию устанавливаем веб-сервер
DRY_RUN=false
AUTO_MODE=false
DEBUG=false
QUIET=false

# --- Цвета ---
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

# --- Логирование ---
log() {
    [ "$QUIET" = true ] && return 0
    local level="$1"; local msg="$2"
    case "$level" in
        "INFO")  echo -e "${GREEN}[INFO]${NC} $msg" ;;
        "WARN")  echo -e "${YELLOW}[WARN]${NC} $msg" ;;
        "ERROR") echo -e "${RED}[ERROR]${NC} $msg" ;;
        "DEBUG") [ "$DEBUG" = true ] && echo -e "${BLUE}[DEBUG]${NC} $msg" ;;
        *)       echo "$msg" ;;
    esac
}
log_info() { log "INFO" "$1"; }
log_warn() { log "WARN" "$1"; }
log_error() { log "ERROR" "$1"; }

print_header() {
    echo ""
    echo "======================================================="
    echo "  $1"
    echo "======================================================="
    echo ""
}

# --- Вспомогательные функции ---
check_dependencies() {
    for cmd in opkg grep sed awk cat mkdir rm mv cp chmod; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_error "Отсутствует команда: $cmd"
            return 1
        fi
    done
    return 0
}

create_backup() {
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local backup_path="${BACKUP_DIR}/backup_${timestamp}"
    [ "$DRY_RUN" = true ] && return 0
    log_info "Создание резервной копии в $backup_path"
    mkdir -p "$backup_path"
    [ -d "$CONFIG_DIR" ] && cp -r "$CONFIG_DIR" "$backup_path/" 2>/dev/null || true
    [ -f "/opt/sbin/iptables" ] && cp "/opt/sbin/iptables" "$backup_path/iptables" 2>/dev/null || true
    [ -f "/opt/etc/init.d/S99netbird" ] && cp "/opt/etc/init.d/S99netbird" "$backup_path/S99netbird" 2>/dev/null || true
    log_info "✓ Резервная копия создана: $backup_path"
}

# Проверка доступности management сервера
check_management_url() {
    local url="$1"
    if [ -z "$url" ]; then
        log_debug "Management URL не указан, пропускаем проверку"
        return 0
    fi
    log_info "Проверка доступности management сервера: $url"
    if command -v curl >/dev/null 2>&1; then
        if curl -s -o /dev/null -w "%{http_code}" "$url" | grep -q "200\|301\|302"; then
            log_info "✓ Management сервер доступен"
            return 0
        else
            log_warn "⚠ Management сервер недоступен (но продолжаем)"
            return 0
        fi
    else
        log_warn "curl не установлен, пропускаем проверку"
        return 0
    fi
}

# --- Основные функции установки ---

install_base_packages() {
    log_info "Обновление репозиториев и установка базовых пакетов..."
    [ "$DRY_RUN" = true ] && { log_info "[DRY-RUN] Установка базовых пакетов"; return 0; }
    
    opkg update || { log_error "Не удалось обновить репозитории"; return 1; }
    
    local packages="iptables netbird cron"
    log_info "Установка пакетов: $packages"
    opkg install $packages || { 
        log_error "Не удалось установить базовые пакеты"
        log_info "Попробуйте установить вручную: opkg install $packages"
        return 1
    }
    
    log_info "✓ Базовые пакеты установлены"
    return 0
}

install_web_packages() {
    log_info "Установка пакетов для веб-сервера..."
    [ "$DRY_RUN" = true ] && { log_info "[DRY-RUN] Установка веб-пакетов"; return 0; }
    
    local packages="lighttpd lighttpd-mod-cgi lighttpd-mod-fastcgi"
    log_info "Установка пакетов: $packages"
    opkg install $packages || { 
        log_warn "Не удалось установить все веб-пакеты"
        log_info "Попробуйте установить вручную: opkg install $packages"
        return 1
    }
    
    log_info "✓ Веб-пакеты установлены"
    return 0
}

setup_iptables() {
    log_info "Настройка эмулятора iptables..."
    [ "$DRY_RUN" = true ] && return 0
    
    if [ ! -f /opt/sbin/iptables.real ]; then
        if [ -f /opt/sbin/iptables ]; then
            mv /opt/sbin/iptables /opt/sbin/iptables.real
        else
            log_error "Оригинальный /opt/sbin/iptables не найден!"
            return 1
        fi
    fi
    
    cat << 'EOF' > /opt/sbin/iptables
#!/bin/sh
case "$*" in
    *"-L"*|*"-S"*)
        echo "Chain INPUT (policy ACCEPT)"
        echo "Chain FORWARD (policy ACCEPT)"
        echo "Chain OUTPUT (policy ACCEPT)"
        exit 0
        ;;
    *"-v"*)
        echo "iptables v1.4.21"
        exit 0
        ;;
    *"-N"*|*"-F"*|*"-X"*|*"-A"*|*"-I"*)
        exit 0
        ;;
esac
/opt/sbin/iptables.real "$@"
EOF
    chmod +x /opt/sbin/iptables
    log_info "✓ Эмулятор iptables настроен"
}

configure_netbird() {
    log_info "Настройка NetBird..."
    [ "$DRY_RUN" = true ] && return 0
    
    mkdir -p "$CONFIG_DIR"
    cat << 'EOF' > "$CONFIG_DIR/config.json"
{
  "WgIface": "wt0",
  "WgPort": 51825,
  "DisableFirewall": true,
  "IFaceDiscover": false
EOF
    
    if [ -n "$DEVICE_NAME" ]; then
        echo "  ,\"Name\": \"$DEVICE_NAME\"" >> "$CONFIG_DIR/config.json"
    fi
    
    if [ -n "$MTU_VALUE" ]; then
        echo "  ,\"WgMTU\": $MTU_VALUE" >> "$CONFIG_DIR/config.json"
    fi
    
    echo "}" >> "$CONFIG_DIR/config.json"
    log_info "✓ Конфигурация создана"
}

setup_watchdog() {
    log_info "Настройка Watchdog демона..."
    [ "$DRY_RUN" = true ] && return 0
    
    cat << 'EOF' > /opt/etc/init.d/S99netbird
#!/bin/sh
ENABLED=yes
PROG=/opt/sbin/netbird
ARGS="service run --log-file /opt/var/log/netbird.log --log-level info --daemon-addr unix:///opt/var/run/netbird.sock"

case "$1" in
    start)
        if [ "$ENABLED" = "yes" ]; then
            mkdir -p /opt/var/run
            export NB_DISABLE_FIREWALL=true
            (
                RESTART_COUNT_FILE="/tmp/netbird_restart_count"
                RESTART_LIMIT=5
                TIME_WINDOW=300
                LAST_RESET=$(date +%s)
                while true; do
                    if ! pidof netbird >/dev/null; then
                        CURRENT_TIME=$(date +%s)
                        if [ $((CURRENT_TIME - LAST_RESET)) -gt $TIME_WINDOW ]; then
                            echo 0 > "$RESTART_COUNT_FILE"
                            LAST_RESET=$CURRENT_TIME
                        fi
                        if [ -f "$RESTART_COUNT_FILE" ]; then
                            COUNT=$(cat "$RESTART_COUNT_FILE")
                        else
                            COUNT=0
                        fi
                        if [ $COUNT -ge $RESTART_LIMIT ]; then
                            echo "$(date): ВНИМАНИЕ! Слишком много перезапусков ($COUNT). Отключаем watchdog..." >> /opt/var/log/netbird_watchdog.log
                            exit 1
                        fi
                        echo "$(date): NetBird daemon stopped. Restarting... (attempt $((COUNT+1)))" >> /opt/var/log/netbird_watchdog.log
                        echo $((COUNT+1)) > "$RESTART_COUNT_FILE"
                        $PROG $ARGS >/dev/null 2>&1
                    fi
                    sleep 3
                done
            ) &
            echo "NetBird watchdog service started."
        fi
        ;;
    stop)
        PID=$(pgrep -f "while true; do if ! pidof netbird")
        [ -n "$PID" ] && kill -9 $PID 2>/dev/null
        killall netbird 2>/dev/null || true
        echo "NetBird service stopped."
        ;;
    restart)
        $0 stop
        sleep 2
        $0 start
        ;;
    *)
        echo "Usage: $0 {start|stop|restart}"
        exit 1
        ;;
esac
EOF
    chmod +x /opt/etc/init.d/S99netbird
    log_info "✓ Watchdog настроен"
}

setup_firewall() {
    log_info "Настройка правил фаервола..."
    [ "$DRY_RUN" = true ] && return 0
    
    mkdir -p /opt/etc/ndm/netfilter.d
    cat << 'EOF' > /opt/etc/ndm/netfilter.d/netbird.sh
#!/bin/sh
LOCKFILE=/tmp/netbird_netfilter.lock
if [ -f "$LOCKFILE" ]; then
    exit 0
fi
touch "$LOCKFILE"

IPT="/opt/sbin/iptables.real iptables"
NETBIRD_NET="100.64.0.0/10"

case "$table" in
  filter)
    $IPT -C INPUT -i wt0 -j ACCEPT 2>/dev/null || $IPT -I INPUT 1 -i wt0 -j ACCEPT
    $IPT -C FORWARD -i wt0 -o br0 -j ACCEPT 2>/dev/null || $IPT -I FORWARD 1 -i wt0 -o br0 -j ACCEPT
    $IPT -C FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || $IPT -I FORWARD 1 -m state --state RELATED,ESTABLISHED -j ACCEPT
    $IPT -t mangle -C OUTPUT -o wt0 -j DSCP --set-dscp 46 2>/dev/null || $IPT -t mangle -I OUTPUT -o wt0 -j DSCP --set-dscp 46
    $IPT -t mangle -C FORWARD -i wt0 -j DSCP --set-dscp 46 2>/dev/null || $IPT -t mangle -I FORWARD -i wt0 -j DSCP --set-dscp 46
    ;;
  nat)
    /opt/sbin/iptables.real iptables -t nat -C POSTROUTING -s $NETBIRD_NET -o br0 -j MASQUERADE 2>/dev/null || \
      /opt/sbin/iptables.real iptables -t nat -I POSTROUTING 1 -s $NETBIRD_NET -o br0 -j MASQUERADE
    ;;
esac

for f in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > "$f"; done
rm -f "$LOCKFILE"
exit 0
EOF
    chmod +x /opt/etc/ndm/netfilter.d/netbird.sh
    log_info "✓ Правила фаервола настроены"
}

# --- Функция настройки веб-сервера lighttpd ---
setup_web_interface() {
    local web_port="${1:-$WEB_PORT}"
    log_info "Настройка веб-интерфейса (lighttpd) на порту $web_port..."
    [ "$DRY_RUN" = true ] && return 0
    
    # Устанавливаем веб-пакеты
    install_web_packages || return 1
    
    # Создаем директории
    mkdir -p /opt/www/netbird /opt/var/log/lighttpd
    
    # Создаем HTML страницу
    cat << 'EOF' > /opt/www/netbird/index.html
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta http-equiv="refresh" content="10">
    <title>NetBird Status</title>
    <style>
        body { font-family: 'Courier New', monospace; background: #1e1e1e; color: #d4d4d4; padding: 20px; margin: 0; }
        .container { max-width: 900px; margin: 0 auto; }
        h1 { color: #569cd6; border-bottom: 2px solid #569cd6; padding-bottom: 10px; }
        .status-ok { color: #4ec9b0; }
        .status-error { color: #f44747; }
        .info { color: #9cdcfe; }
        pre { background: #2d2d2d; padding: 15px; border-radius: 5px; overflow: auto; border-left: 3px solid #569cd6; }
        .footer { margin-top: 30px; color: #6a6a6a; font-size: 12px; text-align: center; }
    </style>
</head>
<body>
    <div class="container">
        <h1>🔵 NetBird Status Monitor</h1>
        <div id="status">
            <p><span class="info">⏳ Загрузка...</span></p>
        </div>
        <div class="footer">
            Обновляется каждые 10 секунд | NetBird Installer v3.2
        </div>
    </div>
    <script>
        function loadStatus() {
            fetch('/cgi-bin/status.sh')
                .then(r => r.text())
                .then(data => {
                    const lines = data.split('\n');
                    let html = '<pre>';
                    lines.forEach(line => {
                        if (line.includes('Статус:') && line.includes('Connected')) {
                            html += '<span class="status-ok">' + line + '</span>\n';
                        } else if (line.includes('Статус:') && line.includes('Disconnected')) {
                            html += '<span class="status-error">' + line + '</span>\n';
                        } else if (line.includes('✓') || line.includes('✅')) {
                            html += '<span class="status-ok">' + line + '</span>\n';
                        } else if (line.includes('❌') || line.includes('Ошибка')) {
                            html += '<span class="status-error">' + line + '</span>\n';
                        } else if (line.includes('IP:') || line.includes('Имя:')) {
                            html += '<span class="info">' + line + '</span>\n';
                        } else {
                            html += line + '\n';
                        }
                    });
                    html += '</pre>';
                    document.getElementById('status').innerHTML = html;
                })
                .catch(err => {
                    document.getElementById('status').innerHTML = '<p class="status-error">❌ Ошибка загрузки: ' + err + '</p>';
                });
        }
        loadStatus();
        setInterval(loadStatus, 10000);
    </script>
</body>
</html>
EOF
    
    # Создаем CGI скрипт для статуса
    mkdir -p /opt/www/netbird/cgi-bin
    cat << 'EOF' > /opt/www/netbird/cgi-bin/status.sh
#!/bin/sh
echo "Content-Type: text/plain"
echo ""
echo "=== NetBird Status ==="
/opt/etc/netbird/status.sh 2>&1
EOF
    chmod +x /opt/www/netbird/cgi-bin/status.sh
    
    # Настраиваем lighttpd
    cat << EOF > /opt/etc/lighttpd/lighttpd.conf
server.modules = (
    "mod_access",
    "mod_alias",
    "mod_cgi",
    "mod_accesslog"
)

server.document-root = "/opt/www/netbird"
server.port = $web_port
server.pid-file = "/var/run/lighttpd.pid"
server.errorlog = "/opt/var/log/lighttpd/error.log"
accesslog.filename = "/opt/var/log/lighttpd/access.log"

# Настройка CGI
cgi.assign = (
    ".sh" => "/bin/sh",
    ".cgi" => ""
)

# Директория для CGI
alias.url = (
    "/cgi-bin/" => "/opt/www/netbird/cgi-bin/"
)

# MIME типы
mimetype.assign = (
    ".html" => "text/html",
    ".txt" => "text/plain",
    ".css" => "text/css",
    ".js" => "application/javascript",
    ".json" => "application/json",
    ".png" => "image/png",
    ".jpg" => "image/jpeg"
)

# Безопасность
$HTTP["url"] =~ "^/cgi-bin/" {
    cgi.assign = ("" => "")
}
EOF
    
    # Создаем init-скрипт для lighttpd
    cat << EOF > /opt/etc/init.d/S80lighttpd
#!/bin/sh
ENABLED=yes
PROG=/opt/sbin/lighttpd
ARGS="-f /opt/etc/lighttpd/lighttpd.conf"
WEB_PORT=$web_port

case "\$1" in
    start)
        if [ "\$ENABLED" = "yes" ]; then
            mkdir -p /var/run /opt/var/log/lighttpd
            \$PROG \$ARGS
            echo "lighttpd web server started on port \$WEB_PORT"
        fi
        ;;
    stop)
        killall lighttpd 2>/dev/null || true
        echo "lighttpd web server stopped"
        ;;
    restart)
        \$0 stop
        sleep 1
        \$0 start
        ;;
    *)
        echo "Usage: \$0 {start|stop|restart}"
        exit 1
        ;;
esac
EOF
    chmod +x /opt/etc/init.d/S80lighttpd
    
    # Запускаем веб-сервер
    /opt/etc/init.d/S80lighttpd start 2>/dev/null || log_warn "Не удалось запустить lighttpd"
    
    log_info "✓ Веб-интерфейс доступен по адресу: http://$(hostname):$web_port"
    return 0
}

setup_monitoring() {
    log_info "Настройка мониторинга..."
    [ "$DRY_RUN" = true ] && return 0
    
    cat << 'EOF' > "$CONFIG_DIR/status.sh"
#!/bin/sh
echo "=== NetBird Status ==="
echo "Версия: $(netbird version 2>/dev/null || echo 'N/A')"
echo "Статус: $(netbird status 2>/dev/null | head -1 || echo 'N/A')"
echo ""
echo "=== Интерфейс wt0 ==="
ip addr show wt0 2>/dev/null || echo "Интерфейс не найден"
echo ""
echo "=== Статистика интерфейса ==="
ip -s link show wt0 2>/dev/null | tail -n 4 || echo "N/A"
echo ""
echo "=== Активные маршруты ==="
ip route | grep wt0 || echo "Маршрутов нет"
echo ""
echo "=== Текущий конфиг ==="
cat /opt/etc/netbird/config.json 2>/dev/null | head -20
echo ""
echo "=== Последние логи (10 строк) ==="
tail -n 10 /opt/var/log/netbird.log 2>/dev/null || echo "Лог не найден"
EOF
    chmod +x "$CONFIG_DIR/status.sh"
    
    echo "0 0 * * * find /opt/var/log/ -name 'netbird*.log' -size +10M -exec mv {} {}.old \; -exec gzip {} \;" >> /opt/etc/crontab
    log_info "✓ Мониторинг настроен"
}

setup_tools() {
    log_info "Настройка дополнительных инструментов..."
    [ "$DRY_RUN" = true ] && return 0
    
    cat << 'EOF' > "$CONFIG_DIR/change_name.sh"
#!/bin/sh
echo "=== Изменение имени устройства NetBird ==="
if ! pidof netbird >/dev/null; then
    echo "NetBird не запущен."
    exit 1
fi
echo "Текущее имя: $(netbird status 2>/dev/null | grep 'Name' | cut -d: -f2 | xargs || echo 'N/A')"
printf "Введите новое имя: "
read new_name
[ -z "$new_name" ] && { echo "Имя не может быть пустым!"; exit 1; }
printf "Продолжить? [y/n]: "
read confirm
if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
    MGMT_URL=$(netbird status 2>/dev/null | grep 'Management URL' | cut -d: -f2- | xargs)
    SETUP_KEY=$(netbird status 2>/dev/null | grep 'Setup Key' | cut -d: -f2- | xargs)
    /opt/etc/init.d/S99netbird stop
    sleep 2
    if netbird up --help 2>&1 | grep -q -- "--hostname"; then
        netbird up --management-url "$MGMT_URL" --setup-key "$SETUP_KEY" --hostname "$new_name"
    else
        netbird up --management-url "$MGMT_URL" --setup-key "$SETUP_KEY" --name "$new_name"
    fi
    echo "✓ Имя изменено на: $new_name"
else
    echo "Операция отменена"
fi
EOF
    
    cat << 'EOF' > "$CONFIG_DIR/update.sh"
#!/bin/sh
echo "=== Обновление NetBird ==="
opkg update && opkg upgrade netbird
if [ -f /opt/etc/init.d/S80lighttpd ]; then
    opkg upgrade lighttpd lighttpd-mod-cgi lighttpd-mod-fastcgi
fi
/opt/etc/init.d/S99netbird restart
echo "Обновление завершено"
EOF
    
    chmod +x "$CONFIG_DIR/"change_name.sh "$CONFIG_DIR/"update.sh
    log_info "✓ Дополнительные инструменты настроены"
}

# --- Интерактивные блоки ---
interactive_name() {
    print_header "Настройка имени устройства"
    echo "  1) Ввести имя вручную"
    echo "  2) Использовать имя хоста (текущее: $(hostname))"
    echo "  3) Пропустить"
    printf "Выберите вариант [1-3]: "
    read name_option
    case "$name_option" in
        1)
            printf "Введите имя устройства: "
            read DEVICE_NAME
            [ -z "$DEVICE_NAME" ] && DEVICE_NAME=$(hostname)
            log_info "✓ Имя устройства: $DEVICE_NAME"
            ;;
        2)
            DEVICE_NAME=$(hostname)
            log_info "✓ Использую имя хоста: $DEVICE_NAME"
            ;;
        *)
            DEVICE_NAME=""
            log_info "Имя не задано"
            ;;
    esac
}

interactive_mtu() {
    print_header "Настройка MTU"
    printf "Хотите настроить MTU? [y/n]: "
    read set_mtu
    if [ "$set_mtu" = "y" ] || [ "$set_mtu" = "Y" ]; then
        printf "Введите MTU (по умолчанию 1420): "
        read MTU_VALUE
        [ -z "$MTU_VALUE" ] && MTU_VALUE=1420
        log_info "✓ MTU: $MTU_VALUE"
    else
        MTU_VALUE=""
    fi
}

interactive_web_setup() {
    print_header "Настройка веб-интерфейса"
    
    printf "Установить веб-интерфейс для мониторинга? [Y/n]: "
    read install_web_choice
    if [ "$install_web_choice" = "n" ] || [ "$install_web_choice" = "N" ]; then
        INSTALL_WEB=false
        log_info "Веб-интерфейс не будет установлен"
        return 0
    fi
    
    INSTALL_WEB=true
    printf "Введите порт для веб-интерфейса [По умолчанию: 8989]: "
    read web_port_input
    if [ -n "$web_port_input" ] && echo "$web_port_input" | grep -qE '^[0-9]+$' && [ "$web_port_input" -ge 1 ] && [ "$web_port_input" -le 65535 ]; then
        WEB_PORT="$web_port_input"
        log_info "✓ Порт: $WEB_PORT"
    else
        WEB_PORT=8989
        log_info "✓ Использую порт по умолчанию: $WEB_PORT"
    fi
}

# --- Функции управления ---
main_install() {
    log_info "Начало установки NetBird v$VERSION"
    create_backup || return 1
    check_dependencies || return 1
    install_base_packages || return 1
    setup_iptables || return 1
    configure_netbird || return 1
    setup_watchdog || return 1
    setup_firewall || return 1
    setup_monitoring || return 1
    setup_tools || return 1
    
    # Устанавливаем веб-интерфейс, если нужно
    if [ "$INSTALL_WEB" = true ]; then
        setup_web_interface "$WEB_PORT" || log_warn "Веб-интерфейс не настроен"
    else
        log_info "Веб-интерфейс пропущен (можно установить позже через меню)"
    fi
    
    if [ "$DRY_RUN" = false ]; then
        sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
        table=filter /opt/etc/ndm/netfilter.d/netbird.sh
        table=nat /opt/etc/ndm/netfilter.d/netbird.sh
        /opt/etc/init.d/S99netbird start
    fi
    
    log_info "✅ Установка завершена успешно!"
    if [ "$INSTALL_WEB" = true ]; then
        log_info "Веб-интерфейс: http://$(hostname):$WEB_PORT"
    fi
    return 0
}

full_restart() {
    print_header "Полный перезапуск всех сервисов"
    log_info "Остановка..."
    [ -f /opt/etc/init.d/S80lighttpd ] && /opt/etc/init.d/S80lighttpd stop
    [ -f /opt/etc/init.d/S99netbird ] && /opt/etc/init.d/S99netbird stop
    sleep 2
    log_info "Запуск..."
    [ -f /opt/etc/init.d/S99netbird ] && /opt/etc/init.d/S99netbird start
    [ -f /opt/etc/init.d/S80lighttpd ] && /opt/etc/init.d/S80lighttpd start
    [ -f /opt/etc/ndm/netfilter.d/netbird.sh ] && {
        table=filter /opt/etc/ndm/netfilter.d/netbird.sh
        table=nat /opt/etc/ndm/netfilter.d/netbird.sh
    }
    log_info "✅ Все сервисы перезапущены!"
    if [ -f /opt/etc/init.d/S80lighttpd ]; then
        log_info "Веб-интерфейс: http://$(hostname):$WEB_PORT"
    fi
}

# Функция установки веб-интерфейса из меню
setup_web_from_menu() {
    print_header "Установка веб-интерфейса"
    
    # Проверяем, установлен ли уже веб-интерфейс
    if [ -f /opt/etc/init.d/S80lighttpd ]; then
        log_warn "Веб-интерфейс уже установлен!"
        printf "Переустановить с новыми настройками? [y/n]: "
        read reinstall_choice
        if [ "$reinstall_choice" != "y" ] && [ "$reinstall_choice" != "Y" ]; then
            log_info "Отмена"
            return 0
        fi
        # Останавливаем старый
        /opt/etc/init.d/S80lighttpd stop 2>/dev/null || true
    fi
    
    # Запрашиваем порт
    printf "Введите порт для веб-интерфейса [По умолчанию: 8989]: "
    read web_port_input
    if [ -n "$web_port_input" ] && echo "$web_port_input" | grep -qE '^[0-9]+$' && [ "$web_port_input" -ge 1 ] && [ "$web_port_input" -le 65535 ]; then
        local web_port="$web_port_input"
    else
        local web_port=8989
        log_info "✓ Использую порт по умолчанию: $web_port"
    fi
    
    # Устанавливаем
    setup_web_interface "$web_port"
    if [ $? -eq 0 ]; then
        log_info "✅ Веб-интерфейс успешно установлен на порту $web_port"
        log_info "URL: http://$(hostname):$web_port"
    else
        log_error "❌ Не удалось установить веб-интерфейс"
    fi
}

show_status() {
    print_header "Статус NetBird"
    [ -f "$CONFIG_DIR/status.sh" ] && "$CONFIG_DIR/status.sh" || {
        netbird status 2>/dev/null || echo "NetBird не запущен"
        ip addr show wt0 2>/dev/null
    }
}

show_logs() {
    local lines="${1:-50}"
    print_header "Последние $lines строк логов"
    echo "=== netbird.log ==="
    tail -n "$lines" /opt/var/log/netbird.log 2>/dev/null || echo "Лог не найден"
    echo ""
    echo "=== netbird_watchdog.log ==="
    tail -n "$lines" /opt/var/log/netbird_watchdog.log 2>/dev/null || echo "Лог не найден"
    if [ -f /opt/var/log/lighttpd/error.log ]; then
        echo ""
        echo "=== lighttpd error.log ==="
        tail -n "$lines" /opt/var/log/lighttpd/error.log 2>/dev/null || echo "Лог не найден"
    fi
}

stop_service() { [ "$DRY_RUN" = false ] && /opt/etc/init.d/S99netbird stop 2>/dev/null; }
start_service() { [ "$DRY_RUN" = false ] && /opt/etc/init.d/S99netbird start 2>/dev/null; }
restart_service() { stop_service; sleep 2; start_service; }

update_script() {
    print_header "Обновление"
    [ -f "$CONFIG_DIR/update.sh" ] && "$CONFIG_DIR/update.sh" || {
        opkg update && opkg upgrade netbird
        if [ -f /opt/etc/init.d/S80lighttpd ]; then
            opkg upgrade lighttpd lighttpd-mod-cgi lighttpd-mod-fastcgi
        fi
        /opt/etc/init.d/S99netbird restart
    }
}

uninstall() {
    print_header "Удаление NetBird"
    printf "Удалить все? [y/N]: "
    read confirm
    [ "$confirm" != "y" ] && [ "$confirm" != "Y" ] && { log_info "Отменено"; return 0; }
    [ "$DRY_RUN" = true ] && return 0
    create_backup
    [ -f /opt/etc/init.d/S80lighttpd ] && /opt/etc/init.d/S80lighttpd stop 2>/dev/null || true
    [ -f /opt/etc/init.d/S99netbird ] && /opt/etc/init.d/S99netbird stop 2>/dev/null || true
    opkg remove netbird lighttpd lighttpd-mod-cgi lighttpd-mod-fastcgi 2>/dev/null || true
    rm -rf "$CONFIG_DIR" /opt/var/lib/netbird /opt/www/netbird /opt/etc/lighttpd
    [ -f /opt/sbin/iptables.real ] && mv /opt/sbin/iptables.real /opt/sbin/iptables
    rm -f /opt/etc/init.d/S99netbird /opt/etc/init.d/S80lighttpd /opt/etc/ndm/netfilter.d/netbird.sh
    sed -i '\#netbird#d' /opt/etc/crontab 2>/dev/null
    log_info "✅ NetBird полностью удален"
}

# --- Меню ---
post_install_menu() {
    while true; do
        print_header "Меню управления NetBird"
        echo "Доступные опции:"
        echo "  1) Показать статус"
        echo "  2) Показать логи"
        echo "  3) Изменить имя устройства"
        echo "  4) Полный перезапуск всех сервисов"
        echo "  5) Обновить скрипт"
        echo "  6) Установить/Переустановить веб-интерфейс"
        echo "  7) Перезапустить веб-интерфейс"
        echo "  8) Информация о веб-интерфейсе"
        echo "  0) Выход"
        echo ""
        printf "Выберите опцию [0-8]: "
        read menu_choice
        
        case "$menu_choice" in
            1)
                show_status
                echo ""
                printf "Нажмите Enter для продолжения..."
                read dummy
                ;;
            2)
                show_logs 50
                echo ""
                printf "Нажмите Enter для продолжения..."
                read dummy
                ;;
            3)
                if [ -f "$CONFIG_DIR/change_name.sh" ]; then
                    "$CONFIG_DIR/change_name.sh"
                else
                    log_error "Скрипт изменения имени не найден"
                fi
                echo ""
                printf "Нажмите Enter для продолжения..."
                read dummy
                ;;
            4)
                full_restart
                echo ""
                printf "Нажмите Enter для продолжения..."
                read dummy
                ;;
            5)
                update_script
                echo ""
                printf "Нажмите Enter для продолжения..."
                read dummy
                ;;
            6)
                setup_web_from_menu
                echo ""
                printf "Нажмите Enter для продолжения..."
                read dummy
                ;;
            7)
                if [ -f /opt/etc/init.d/S80lighttpd ]; then
                    /opt/etc/init.d/S80lighttpd restart
                    log_info "✓ Веб-интерфейс перезапущен"
                else
                    log_error "Веб-интерфейс не установлен. Используйте опцию 6 для установки."
                fi
                echo ""
                printf "Нажмите Enter для продолжения..."
                read dummy
                ;;
            8)
                echo "=== Информация о веб-интерфейсе ==="
                if [ -f /opt/etc/init.d/S80lighttpd ]; then
                    local current_port=$(grep "server.port" /opt/etc/lighttpd/lighttpd.conf 2>/dev/null | cut -d'=' -f2 | tr -d ' ')
                    echo "URL: http://$(hostname):${current_port:-8989}"
                    echo "Порт: ${current_port:-8989}"
                    echo "Статус: $(pidof lighttpd >/dev/null && echo '✅ Запущен' || echo '❌ Остановлен')"
                    echo "Конфиг: /opt/etc/lighttpd/lighttpd.conf"
                    echo "Лог: /opt/var/log/lighttpd/error.log"
                    echo "Документы: /opt/www/netbird"
                else
                    echo "❌ Веб-интерфейс не установлен"
                    echo "Используйте опцию 6 для установки"
                fi
                echo ""
                printf "Нажмите Enter для продолжения..."
                read dummy
                ;;
            0)
                log_info "Выход из меню"
                break
                ;;
            *)
                log_error "Неверный выбор"
                sleep 1
                ;;
        esac
    done
}

# --- Аргументы ---
usage() {
    echo "NetBird Installer v$VERSION"
    echo ""
    echo "Команды: install|start|stop|restart|fullrestart|status|logs|menu|update|uninstall|help"
    echo "Опции:"
    echo "  --dry-run    - Режим тестирования"
    echo "  --auto       - Автоматический режим"
    echo "  --debug      - Режим отладки"
    echo "  --quiet      - Минимальный вывод"
    echo "  --name NAME  - Имя устройства"
    echo "  --mtu MTU    - MTU интерфейса"
    echo "  --url URL    - Management URL"
    echo "  --key KEY    - Setup Key"
    echo "  --port PORT  - Порт веб-интерфейса"
    echo "  --no-web     - Не устанавливать веб-интерфейс"
    echo ""
    echo "Пример: netbird install --auto --name '10-Antipino' --no-web"
}

parse_args() {
    COMMAND="install"
    while [ $# -gt 0 ]; do
        case "$1" in
            install|start|stop|restart|fullrestart|status|logs|menu|update|uninstall|help)
                COMMAND="$1"; shift ;;
            --dry-run) DRY_RUN=true; shift ;;
            --auto) AUTO_MODE=true; shift ;;
            --debug) DEBUG=true; shift ;;
            --quiet) QUIET=true; shift ;;
            --name) DEVICE_NAME="$2"; shift 2 ;;
            --mtu) MTU_VALUE="$2"; shift 2 ;;
            --url) MANAGEMENT_URL="$2"; shift 2 ;;
            --key) SETUP_KEY="$2"; shift 2 ;;
            --port) WEB_PORT="$2"; shift 2 ;;
            --no-web) INSTALL_WEB=false; shift ;;
            *) log_error "Неизвестный аргумент: $1"; usage; exit 1 ;;
        esac
    done
}

# --- Основной запуск ---
main() {
    [ "$DEBUG" = true ] && set -x
    if [ "$(id -u)" -ne 0 ] && [ "$COMMAND" != "status" ] && [ "$COMMAND" != "logs" ] && [ "$COMMAND" != "help" ] && [ "$COMMAND" != "menu" ]; then
        log_error "Требуются права root"
        exit 1
    fi
    
    case "$COMMAND" in
        install)
            [ "$AUTO_MODE" = false ] && { 
                interactive_name
                interactive_mtu
                interactive_web_setup
            }
            
            # Проверяем management URL, если указан
            if [ -n "$MANAGEMENT_URL" ]; then
                check_management_url "$MANAGEMENT_URL"
            fi
            
            main_install
            
            if [ "$AUTO_MODE" = false ] && [ "$DRY_RUN" = false ]; then
                print_header "Авторизация в сети"
                printf "Выполнить привязку к серверу? [y/n]: "
                read run_auth
                if [ "$run_auth" = "y" ] || [ "$run_auth" = "Y" ]; then
                    if [ -z "$MANAGEMENT_URL" ]; then
                        printf "Введите Management URL [По умолчанию: https://netbird.io]: "
                        read MANAGEMENT_URL
                        [ -z "$MANAGEMENT_URL" ] && MANAGEMENT_URL="https://netbird.io"
                    fi
                    if [ -z "$SETUP_KEY" ]; then
                        printf "Введите Setup Key: "
                        read SETUP_KEY
                    fi
                    if [ -n "$SETUP_KEY" ]; then
                        AUTH_ARGS="--management-url \"$MANAGEMENT_URL\" --setup-key \"$SETUP_KEY\""
                        if [ -n "$DEVICE_NAME" ]; then
                            if netbird up --help 2>&1 | grep -q -- "--hostname"; then
                                AUTH_ARGS="$AUTH_ARGS --hostname \"$DEVICE_NAME\""
                            else
                                log_info "Имя будет взято из config.json"
                            fi
                        fi
                        eval "netbird up $AUTH_ARGS" && log_info "✅ Подключено!" || log_error "❌ Ошибка подключения!"
                    fi
                fi
                post_install_menu
            fi
            ;;
        start) start_service ;;
        stop) stop_service ;;
        restart) restart_service ;;
        fullrestart) full_restart ;;
        status) show_status ;;
        logs) show_logs 100 ;;
        menu) post_install_menu ;;
        update) update_script ;;
        uninstall) uninstall ;;
        help|*) usage ;;
    esac
}

parse_args "$@"
main
exit 0
