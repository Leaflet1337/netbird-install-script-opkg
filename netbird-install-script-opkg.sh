#!/bin/sh
# ==========================================================
# NetBird Installer для Keenetic v3.0 (Расширенная версия)
# ==========================================================
# Автоматический скрипт комплексного развертывания NetBird 
# для Keenetic (Entware) с расширенными функциями

set -e

# --- 1. Базовые настройки и переменные ---
VERSION="3.0"
SCRIPT_NAME="netbird-install.sh"
LOG_DIR="/opt/var/log/netbird"
BACKUP_DIR="/opt/backups/netbird"
CONFIG_DIR="/opt/etc/netbird"
NETBIRD_IFACE="${NETBIRD_IFACE:-wt0}"
NETBIRD_NET="${NETBIRD_NET:-100.64.0.0/10}"
WEB_PORT="${WEB_PORT:-8989}"
DRY_RUN=false
AUTO_MODE=false
DEBUG=false
QUIET=false

# Цвета для вывода (если терминал поддерживает)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

# --- 2. Вспомогательные функции ---
log() {
    [ "$QUIET" = true ] && return 0
    local level="$1"
    local msg="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    case "$level" in
        "INFO")  echo -e "${GREEN}[INFO]${NC} $msg" ;;
        "WARN")  echo -e "${YELLOW}[WARN]${NC} $msg" ;;
        "ERROR") echo -e "${RED}[ERROR]${NC} $msg" ;;
        "DEBUG") [ "$DEBUG" = true ] && echo -e "${BLUE}[DEBUG]${NC} $msg" ;;
        *)       echo "$msg" ;;
    esac
    [ -n "$LOG_FILE" ] && echo "[$timestamp] [$level] $msg" >> "$LOG_FILE"
}

log_debug() { log "DEBUG" "$1"; }
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

# Проверка зависимостей
check_dependencies() {
    log_debug "Проверка зависимостей..."
    local missing=""
    for cmd in opkg grep sed awk cut cat mkdir rm mv cp chmod; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing="$missing $cmd"
        fi
    done
    if [ -n "$missing" ]; then
        log_error "Отсутствуют необходимые команды:$missing"
        return 1
    fi
    return 0
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

# Валидация конфигурации
validate_config() {
    local config_file="$1"
    if [ ! -f "$config_file" ]; then
        log_error "Файл конфигурации не найден: $config_file"
        return 1
    fi
    
    log_debug "Проверка валидности конфигурации..."
    if command -v json_verify >/dev/null 2>&1; then
        if json_verify < "$config_file" 2>/dev/null; then
            log_info "✓ Конфигурация валидна"
            return 0
        else
            log_error "❌ Невалидный JSON в конфигурации!"
            return 1
        fi
    else
        log_warn "json_verify не установлен, пропускаем проверку"
        return 0
    fi
}

# Создание резервной копии
create_backup() {
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local backup_path="${BACKUP_DIR}/backup_${timestamp}"
    
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Создание резервной копии в $backup_path"
        return 0
    fi
    
    log_info "Создание резервной копии..."
    mkdir -p "$backup_path"
    
    # Бэкапим конфиги
    if [ -d "$CONFIG_DIR" ]; then
        cp -r "$CONFIG_DIR" "$backup_path/" 2>/dev/null || true
    fi
    
    # Бэкапим оригинальный iptables
    if [ -f "/opt/sbin/iptables" ]; then
        cp "/opt/sbin/iptables" "$backup_path/iptables" 2>/dev/null || true
    fi
    
    # Бэкапим init-скрипт
    if [ -f "/opt/etc/init.d/S99netbird" ]; then
        cp "/opt/etc/init.d/S99netbird" "$backup_path/S99netbird" 2>/dev/null || true
    fi
    
    log_info "✓ Резервная копия создана: $backup_path"
    echo "$backup_path" > /tmp/netbird_backup_path
    return 0
}

# --- 3. Основные функции установки ---

# Функция установки пакетов
install_packages() {
    log_info "Обновление репозиториев и установка пакетов..."
    
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Будет выполнено: opkg update && opkg install iptables netbird cron uhttpd"
        return 0
    fi
    
    opkg update || {
        log_error "Не удалось обновить репозитории"
        return 1
    }
    
    opkg install iptables netbird cron uhttpd || {
        log_error "Не удалось установить пакеты"
        return 1
    }
    
    log_info "✓ Пакеты установлены"
    return 0
}

# Функция настройки эмулятора iptables
setup_iptables() {
    log_info "Настройка эмулятора iptables..."
    
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Создание эмулятора iptables"
        return 0
    fi
    
    if [ ! -f /opt/sbin/iptables.real ]; then
        if [ -f /opt/sbin/iptables ]; then
            mv /opt/sbin/iptables /opt/sbin/iptables.real
        else
            log_error "Оригинальный бинарник /opt/sbin/iptables не найден!"
            return 1
        fi
    fi
    
    cat << 'EOF' > /opt/sbin/iptables
#!/bin/sh
# Умная заглушка-эмулятор iptables для предотвращения краша демона NetBird
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
    return 0
}

# Функция настройки NetBird
configure_netbird() {
    log_info "Настройка NetBird..."
    
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Создание config.json с параметрами"
        return 0
    fi
    
    mkdir -p "$CONFIG_DIR"
    
    # Базовый конфиг
    cat << 'EOF' > "$CONFIG_DIR/config.json"
{
  "WgIface": "wt0",
  "WgPort": 51825,
  "DisableFirewall": true,
  "IFaceDiscover": false
EOF
    
    # Добавляем имя устройства, если задано
    if [ -n "$DEVICE_NAME" ]; then
        cat << EOF >> "$CONFIG_DIR/config.json"
  ,"Name": "$DEVICE_NAME"
EOF
    fi
    
    # Добавляем MTU, если задан
    if [ -n "$MTU_VALUE" ]; then
        cat << EOF >> "$CONFIG_DIR/config.json"
  ,"WgMTU": $MTU_VALUE
EOF
    fi
    
    # Закрываем JSON
    echo "}" >> "$CONFIG_DIR/config.json"
    
    # Валидация конфига
    validate_config "$CONFIG_DIR/config.json" || {
        log_error "Ошибка валидации конфигурации"
        return 1
    }
    
    log_info "✓ Конфигурация создана"
    return 0
}

# Функция настройки Watchdog
setup_watchdog() {
    log_info "Настройка Watchdog демона..."
    
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Создание S99netbird с watchdog"
        return 0
    fi
    
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
            
            # Запускаем бесконечный цикл-страж в фоновом режиме
            (
                RESTART_COUNT_FILE="/tmp/netbird_restart_count"
                RESTART_LIMIT=5
                TIME_WINDOW=300
                LAST_RESET=$(date +%s)
                
                while true; do
                    # Проверяем, запущен ли демон
                    if ! pidof netbird >/dev/null; then
                        CURRENT_TIME=$(date +%s)
                        
                        # Сбрасываем счетчик после временного окна
                        if [ $((CURRENT_TIME - LAST_RESET)) -gt $TIME_WINDOW ]; then
                            echo 0 > "$RESTART_COUNT_FILE"
                            LAST_RESET=$CURRENT_TIME
                        fi
                        
                        # Читаем счетчик
                        if [ -f "$RESTART_COUNT_FILE" ]; then
                            COUNT=$(cat "$RESTART_COUNT_FILE")
                        else
                            COUNT=0
                        fi
                        
                        # Проверяем лимит
                        if [ $COUNT -ge $RESTART_LIMIT ]; then
                            echo "$(date): ВНИМАНИЕ! Слишком много перезапусков ($COUNT). Отключаем watchdog..." >> /opt/var/log/netbird_watchdog.log
                            exit 1
                        fi
                        
                        # Перезапускаем
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
        # Уничтожаем цикл-страж
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
    return 0
}

# Функция настройки правил фаервола
setup_firewall() {
    log_info "Настройка правил фаервола..."
    
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Создание хука netfilter.d"
        return 0
    fi
    
    mkdir -p /opt/etc/ndm/netfilter.d
    
    cat << 'EOF' > /opt/etc/ndm/netfilter.d/netbird.sh
#!/bin/sh
# Защитный Lock-файл от рекурсивного вызова событий фаервола NDM Keenetic
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
    
    # QoS: Приоритизация VPN трафика (DSCP 46)
    $IPT -t mangle -C OUTPUT -o wt0 -j DSCP --set-dscp 46 2>/dev/null || \
      $IPT -t mangle -I OUTPUT -o wt0 -j DSCP --set-dscp 46
    $IPT -t mangle -C FORWARD -i wt0 -j DSCP --set-dscp 46 2>/dev/null || \
      $IPT -t mangle -I FORWARD -i wt0 -j DSCP --set-dscp 46
    ;;
  nat)
    /opt/sbin/iptables.real iptables -t nat -C POSTROUTING -s $NETBIRD_NET -o br0 -j MASQUERADE 2>/dev/null || \
      /opt/sbin/iptables.real iptables -t nat -I POSTROUTING 1 -s $NETBIRD_NET -o br0 -j MASQUERADE
    ;;
esac

# Отключаем rp_filter для входящего трафика mesh-сети
for f in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > "$f"; done

rm -f "$LOCKFILE"
exit 0
EOF
    chmod +x /opt/etc/ndm/netfilter.d/netbird.sh
    
    log_info "✓ Правила фаервола настроены"
    return 0
}

# Функция настройки веб-интерфейса
setup_web_interface() {
    log_info "Настройка веб-интерфейса на порту $WEB_PORT..."
    
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Создание веб-интерфейса"
        return 0
    fi
    
    # Создаем директорию для веб-файлов
    mkdir -p /opt/www/netbird
    
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
        .status-warning { color: #dcdcaa; }
        .info { color: #9cdcfe; }
        .label { color: #c586c0; }
        pre { background: #2d2d2d; padding: 15px; border-radius: 5px; overflow: auto; border-left: 3px solid #569cd6; }
        .footer { margin-top: 30px; color: #6a6a6a; font-size: 12px; text-align: center; }
        .badge { display: inline-block; padding: 3px 8px; border-radius: 3px; font-size: 12px; }
        .badge-ok { background: #4ec9b0; color: #1e1e1e; }
        .badge-error { background: #f44747; color: #1e1e1e; }
        .badge-warning { background: #dcdcaa; color: #1e1e1e; }
    </style>
</head>
<body>
    <div class="container">
        <h1>🔵 NetBird Status Monitor</h1>
        <div id="status">
            <p><span class="label">⏳ Загрузка...</span></p>
        </div>
        <div class="footer">
            Обновляется каждые 10 секунд | NetBird Installer v3.0
        </div>
    </div>
    <script>
        function loadStatus() {
            fetch('/status')
                .then(r => r.text())
                .then(data => {
                    const lines = data.split('\n');
                    let html = '<pre>';
                    let statusClass = 'status-ok';
                    
                    lines.forEach(line => {
                        if (line.includes('Статус:') && line.includes('Connected')) {
                            html += '<span class="status-ok">' + line + '</span>\n';
                            statusClass = 'status-ok';
                        } else if (line.includes('Статус:') && line.includes('Disconnected')) {
                            html += '<span class="status-error">' + line + '</span>\n';
                            statusClass = 'status-error';
                        } else if (line.includes('⚠')) {
                            html += '<span class="status-warning">' + line + '</span>\n';
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
                    
                    // Добавляем бейдж статуса
                    const badgeHtml = '<span class="badge badge-' + 
                        (statusClass === 'status-ok' ? 'ok' : 'error') + 
                        '">' + 
                        (statusClass === 'status-ok' ? '🟢 ONLINE' : '🔴 OFFLINE') + 
                        '</span>';
                    
                    document.getElementById('status').innerHTML = badgeHtml + html;
                })
                .catch(err => {
                    document.getElementById('status').innerHTML = '<p class="status-error">❌ Ошибка загрузки: ' + err + '</p>';
                });
        }
        
        // Загружаем сразу и каждые 10 секунд
        loadStatus();
        setInterval(loadStatus, 10000);
    </script>
</body>
</html>
EOF
    
    # Создаем CGI скрипт для статуса
    mkdir -p /opt/www/cgi-bin
    cat << 'EOF' > /opt/www/cgi-bin/status
#!/bin/sh
echo "Content-Type: text/plain"
echo ""
echo "=== NetBird Status ==="
/opt/etc/netbird/status.sh 2>&1
EOF
    chmod +x /opt/www/cgi-bin/status
    
    # Настраиваем uhttpd
    cat << EOF > /opt/etc/uhttpd.conf
# NetBird Status Server
list listen_http 0.0.0.0:$WEB_PORT
option home /opt/www
option cgi_prefix /cgi-bin
option index_page index.html
option no_daemon 0
option max_requests 3
option script_timeout 60
option network_timeout 30
option http_keepalive 20
option rfc1918_filter 0
option url_prefix /
EOF
    
    # Создаем init-скрипт для uhttpd
    cat << 'EOF' > /opt/etc/init.d/S80uhttpd
#!/bin/sh
ENABLED=yes
PROG=/opt/sbin/uhttpd
ARGS="-f /opt/etc/uhttpd.conf"

case "$1" in
    start)
        if [ "$ENABLED" = "yes" ]; then
            $PROG $ARGS &
            echo "uhttpd web server started on port $WEB_PORT"
        fi
        ;;
    stop)
        killall uhttpd 2>/dev/null || true
        echo "uhttpd web server stopped"
        ;;
    restart)
        $0 stop
        sleep 1
        $0 start
        ;;
    *)
        echo "Usage: $0 {start|stop|restart}"
        exit 1
        ;;
esac
EOF
    chmod +x /opt/etc/init.d/S80uhttpd
    
    # Запускаем веб-сервер
    /opt/etc/init.d/S80uhttpd start
    
    log_info "✓ Веб-интерфейс доступен по адресу: http://$(hostname):$WEB_PORT"
    return 0
}

# Функция настройки мониторинга
setup_monitoring() {
    log_info "Настройка мониторинга..."
    
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Создание скриптов мониторинга"
        return 0
    fi
    
    # Расширенный статус
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
    
    # Настройка ротации логов
    cat << 'EOF' >> /opt/etc/crontab
# Ротация логов NetBird
0 0 * * * find /opt/var/log/ -name "netbird*.log" -size +10M -exec mv {} {}.old \; -exec gzip {} \;
EOF
    
    log_info "✓ Мониторинг настроен"
    return 0
}

# Функция настройки дополнительных инструментов
setup_tools() {
    log_info "Настройка дополнительных инструментов..."
    
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Создание утилит управления"
        return 0
    fi
    
    # Скрипт изменения имени
    cat << 'EOF' > "$CONFIG_DIR/change_name.sh"
#!/bin/sh
echo "=== Изменение имени устройства NetBird ==="
echo ""

if ! pidof netbird >/dev/null; then
    echo "NetBird не запущен. Запустите его сначала."
    exit 1
fi

echo "Текущее имя: $(netbird status 2>/dev/null | grep "Name" | cut -d: -f2 | xargs || echo 'N/A')"
printf "Введите новое имя устройства: "
read new_name

if [ -z "$new_name" ]; then
    echo "Имя не может быть пустым!"
    exit 1
fi

echo "⚠️  Изменение имени потребует переподключения."
printf "Продолжить? [y/n]: "
read confirm

if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
    MGMT_URL=$(netbird status 2>/dev/null | grep "Management URL" | cut -d: -f2- | xargs)
    SETUP_KEY=$(netbird status 2>/dev/null | grep "Setup Key" | cut -d: -f2- | xargs)
    
    /opt/etc/init.d/S99netbird stop
    sleep 2
    netbird up --management-url "$MGMT_URL" --setup-key "$SETUP_KEY" --name "$new_name"
    
    echo "✓ Имя устройства изменено на: $new_name"
else
    echo "Операция отменена"
fi
EOF
    
    # Скрипт обновления
    cat << 'EOF' > "$CONFIG_DIR/update.sh"
#!/bin/sh
echo "=== Обновление NetBird и скриптов ==="
echo ""

echo "Обновление пакетов..."
opkg update && opkg upgrade netbird

echo "Обновление скрипта..."
SCRIPT_URL="https://raw.githubusercontent.com/Leaflet1337/netbird-install-script-opkg/main/netbird-install-script-opkg.sh"
wget -O "/tmp/script_new.sh" "$SCRIPT_URL" 2>/dev/null || curl -o "/tmp/script_new.sh" "$SCRIPT_URL"

if [ -f "/tmp/script_new.sh" ]; then
    chmod +x "/tmp/script_new.sh"
    mv "/tmp/script_new.sh" "/opt/bin/netbird-install.sh"
    echo "✓ Скрипт обновлен"
else
    echo "❌ Не удалось загрузить обновление"
fi

/opt/etc/init.d/S99netbird restart
echo "Обновление завершено"
EOF
    
    chmod +x "$CONFIG_DIR/"change_name.sh "$CONFIG_DIR/"update.sh
    
    log_info "✓ Дополнительные инструменты настроены"
    return 0
}

# --- 4. Интерактивные блоки ---

# Интерактивная настройка имени устройства
interactive_name() {
    print_header "Настройка имени устройства"
    
    echo "Варианты действий:"
    echo "  1) Ввести имя вручную"
    echo "  2) Использовать имя хоста (текущее: $(hostname))"
    echo "  3) Пропустить (авто-генерация NetBird)"
    printf "Выберите вариант [1-3]: "
    read name_option
    
    case "$name_option" in
        1)
            printf "Введите имя устройства: "
            read DEVICE_NAME
            if [ -z "$DEVICE_NAME" ]; then
                DEVICE_NAME=$(hostname)
                log_warn "Имя не введено, использую имя хоста"
            fi
            log_info "✓ Имя устройства: $DEVICE_NAME"
            ;;
        2)
            DEVICE_NAME=$(hostname)
            log_info "✓ Использую имя хоста: $DEVICE_NAME"
            ;;
        *)
            DEVICE_NAME=""
            log_info "Имя не задано (будет сгенерировано автоматически)"
            ;;
    esac
}

# Интерактивная настройка MTU
interactive_mtu() {
    print_header "Настройка MTU"
    
    printf "Хотите настроить MTU? [y/n]: "
    read set_mtu
    
    if [ "$set_mtu" = "y" ] || [ "$set_mtu" = "Y" ]; then
        printf "Введите MTU (по умолчанию 1420, рекомендуется 1500): "
        read MTU_VALUE
        
        if [ -z "$MTU_VALUE" ]; then
            MTU_VALUE=1420
            log_info "Использую MTU по умолчанию: 1420"
        elif ! echo "$MTU_VALUE" | grep -qE '^[0-9]+$' || [ "$MTU_VALUE" -lt 1280 ] || [ "$MTU_VALUE" -gt 1500 ]; then
            log_warn "Неверное значение, использую 1420"
            MTU_VALUE=1420
        fi
        
        log_info "✓ MTU: $MTU_VALUE"
    else
        MTU_VALUE=""
    fi
}

# --- 5. Функции управления ---

# Основная установка
main_install() {
    log_info "Начало установки NetBird v$VERSION"
    
    # Создаем бэкап
    create_backup || {
        log_error "Не удалось создать резервную копию"
        return 1
    }
    
    # Проверяем зависимости
    check_dependencies || {
        log_error "Ошибка проверки зависимостей"
        return 1
    }
    
    # Устанавливаем пакеты
    install_packages || return 1
    
    # Настраиваем iptables
    setup_iptables || return 1
    
    # Настраиваем конфигурацию
    configure_netbird || return 1
    
    # Настраиваем Watchdog
    setup_watchdog || return 1
    
    # Настраиваем фаервол
    setup_firewall || return 1
    
    # Настраиваем мониторинг
    setup_monitoring || return 1
    
    # Настраиваем веб-интерфейс
    setup_web_interface || return 1
    
    # Настраиваем дополнительные инструменты
    setup_tools || return 1
    
    # Запускаем сервис
    if [ "$DRY_RUN" = false ]; then
        sysctl -w net.ipv4.ip_forward=1
        table=filter /opt/etc/ndm/netfilter.d/netbird.sh
        table=nat /opt/etc/ndm/netfilter.d/netbird.sh
        /opt/etc/init.d/S99netbird start
    else
        log_info "[DRY-RUN] Запуск сервиса"
    fi
    
    log_info "✅ Установка завершена успешно!"
    return 0
}

# Полный перезапуск всех зависимостей
full_restart() {
    print_header "Полный перезапуск NetBird и зависимостей"
    
    log_info "Остановка всех сервисов..."
    
    # Останавливаем веб-сервер
    if [ -f /opt/etc/init.d/S80uhttpd ]; then
        /opt/etc/init.d/S80uhttpd stop
    fi
    
    # Останавливаем NetBird
    if [ -f /opt/etc/init.d/S99netbird ]; then
        /opt/etc/init.d/S99netbird stop
    fi
    
    sleep 2
    
    log_info "Запуск всех сервисов..."
    
    # Запускаем NetBird
    if [ -f /opt/etc/init.d/S99netbird ]; then
        /opt/etc/init.d/S99netbird start
    fi
    
    # Запускаем веб-сервер
    if [ -f /opt/etc/init.d/S80uhttpd ]; then
        /opt/etc/init.d/S80uhttpd start
    fi
    
    # Применяем правила фаервола
    if [ -f /opt/etc/ndm/netfilter.d/netbird.sh ]; then
        table=filter /opt/etc/ndm/netfilter.d/netbird.sh
        table=nat /opt/etc/ndm/netfilter.d/netbird.sh
    fi
    
    log_info "✅ Все сервисы перезапущены!"
    log_info "Проверьте статус: netbird status"
    log_info "Веб-интерфейс: http://$(hostname):$WEB_PORT"
}

# Показать статус
show_status() {
    print_header "Статус NetBird"
    
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Показ статуса"
        return 0
    fi
    
    if [ -f "$CONFIG_DIR/status.sh" ]; then
        "$CONFIG_DIR/status.sh"
    else
        log_warn "Скрипт статуса не найден. Использую базовый вывод."
        netbird status 2>/dev/null || echo "NetBird не запущен"
        ip addr show wt0 2>/dev/null || echo "Интерфейс wt0 не найден"
    fi
}

# Показать логи
show_logs() {
    local lines="${1:-50}"
    print_header "Последние $lines строк логов"
    
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Показ логов"
        return 0
    fi
    
    echo "=== netbird.log ==="
    tail -n "$lines" /opt/var/log/netbird.log 2>/dev/null || echo "Лог не найден"
    echo ""
    echo "=== netbird_watchdog.log ==="
    tail -n "$lines" /opt/var/log/netbird_watchdog.log 2>/dev/null || echo "Лог не найден"
    echo ""
    echo "=== netbird_cron.log ==="
    tail -n "$lines" /opt/var/log/netbird_cron.log 2>/dev/null || echo "Лог не найден"
}

# Остановка сервиса
stop_service() {
    log_info "Остановка NetBird..."
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Остановка сервиса"
        return 0
    fi
    
    /opt/etc/init.d/S99netbird stop 2>/dev/null || {
        log_warn "Не удалось остановить сервис"
    }
}

# Запуск сервиса
start_service() {
    log_info "Запуск NetBird..."
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Запуск сервиса"
        return 0
    fi
    
    /opt/etc/init.d/S99netbird start 2>/dev/null || {
        log_error "Не удалось запустить сервис"
        return 1
    }
}

# Перезапуск сервиса
restart_service() {
    log_info "Перезапуск NetBird..."
    stop_service
    sleep 2
    start_service
}

# Обновление скрипта
update_script() {
    print_header "Обновление скрипта"
    
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Обновление скрипта"
        return 0
    fi
    
    if [ -f "$CONFIG_DIR/update.sh" ]; then
        "$CONFIG_DIR/update.sh"
    else
        log_info "Скачивание последней версии скрипта..."
        SCRIPT_URL="https://raw.githubusercontent.com/Leaflet1337/netbird-install-script-opkg/main/netbird-install-script-opkg.sh"
        wget -O "/tmp/script_new.sh" "$SCRIPT_URL" 2>/dev/null || curl -o "/tmp/script_new.sh" "$SCRIPT_URL"
        if [ -f "/tmp/script_new.sh" ]; then
            chmod +x "/tmp/script_new.sh"
            mv "/tmp/script_new.sh" "/opt/bin/$SCRIPT_NAME"
            log_info "✓ Скрипт обновлен до версии $(grep VERSION= /opt/bin/$SCRIPT_NAME | head -1 | cut -d'"' -f2)"
        else
            log_error "Не удалось загрузить обновление"
            return 1
        fi
    fi
}

# Полное удаление
uninstall() {
    print_header "Полное удаление NetBird"
    
    echo "⚠️  ВНИМАНИЕ! Это удалит NetBird и все его конфигурации."
    printf "Продолжить? [y/N]: "
    read confirm
    
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        log_info "Удаление отменено"
        return 0
    fi
    
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Удаление NetBird"
        return 0
    fi
    
    # Создаем бэкап перед удалением
    create_backup
    
    # Останавливаем сервисы
    /opt/etc/init.d/S80uhttpd stop 2>/dev/null || true
    /opt/etc/init.d/S99netbird stop 2>/dev/null || true
    
    # Удаляем пакеты
    opkg remove netbird uhttpd 2>/dev/null || true
    
    # Удаляем конфиги
    rm -rf "$CONFIG_DIR"
    rm -rf /opt/var/lib/netbird
    rm -rf /opt/www/netbird
    
    # Восстанавливаем iptables
    if [ -f /opt/sbin/iptables.real ]; then
        mv /opt/sbin/iptables.real /opt/sbin/iptables
    fi
    
    # Удаляем init-скрипты
    rm -f /opt/etc/init.d/S99netbird
    rm -f /opt/etc/init.d/S80uhttpd
    
    # Удаляем хук
    rm -f /opt/etc/ndm/netfilter.d/netbird.sh
    
    # Удаляем задания из cron
    if [ -f /opt/etc/crontab ]; then
        sed -i '\#netbird#d' /opt/etc/crontab
    fi
    
    log_info "✅ NetBird полностью удален"
    return 0
}

# --- 6. Интерактивное меню после установки ---

post_install_menu() {
    while true; do
        print_header "Меню управления NetBird"
        
        echo "Доступные опции:"
        echo "  1) Показать статус"
        echo "  2) Показать логи"
        echo "  3) Изменить имя устройства"
        echo "  4) Полный перезапуск всех сервисов"
        echo "  5) Обновить скрипт"
        echo "  6) Перезапустить веб-интерфейс"
        echo "  7) Показать информацию о веб-интерфейсе"
        echo "  0) Выход"
        echo ""
        printf "Выберите опцию [0-7]: "
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
                if [ -f /opt/etc/init.d/S80uhttpd ]; then
                    /opt/etc/init.d/S80uhttpd restart
                    log_info "✓ Веб-интерфейс перезапущен"
                else
                    log_error "Веб-интерфейс не настроен"
                fi
                echo ""
                printf "Нажмите Enter для продолжения..."
                read dummy
                ;;
            7)
                echo "=== Информация о веб-интерфейсе ==="
                echo "URL: http://$(hostname):$WEB_PORT"
                echo "Порт: $WEB_PORT"
                echo "Статус: $(pidof uhttpd >/dev/null && echo '✅ Запущен' || echo '❌ Остановлен')"
                echo "Лог: /opt/var/log/uhttpd.log"
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

# --- 7. Обработка аргументов командной строки ---

usage() {
    echo "NetBird Installer для Keenetic v$VERSION"
    echo ""
    echo "Использование:"
    echo "  netbird [COMMAND] [OPTIONS]"
    echo ""
    echo "Команды:"
    echo "  install      - Установка NetBird (по умолчанию)"
    echo "  start        - Запустить сервис"
    echo "  stop         - Остановить сервис"
    echo "  restart      - Перезапустить сервис"
    echo "  fullrestart  - Полный перезапуск всех сервисов"
    echo "  status       - Показать статус"
    echo "  logs         - Показать логи"
    echo "  menu         - Показать интерактивное меню"
    echo "  update       - Обновить скрипт"
    echo "  uninstall    - Полное удаление"
    echo "  help         - Показать эту справку"
    echo ""
    echo "Опции:"
    echo "  --dry-run    - Режим тестирования (без изменений)"
    echo "  --auto       - Автоматический режим (без запросов)"
    echo "  --debug      - Включить отладку"
    echo "  --quiet      - Минимальный вывод"
    echo "  --name NAME  - Имя устройства"
    echo "  --mtu MTU    - MTU интерфейса"
    echo "  --url URL    - Management URL"
    echo "  --key KEY    - Setup Key"
    echo "  --port PORT  - Порт веб-интерфейса (по умолчанию: 8989)"
    echo ""
    echo "Примеры:"
    echo "  netbird install --auto --name '10-Antipino'"
    echo "  netbird status"
    echo "  netbird menu"
    echo "  netbird fullrestart"
    echo "  netbird --dry-run install"
}

parse_args() {
    COMMAND="install"
    
    while [ $# -gt 0 ]; do
        case "$1" in
            install|start|stop|restart|fullrestart|status|logs|menu|update|uninstall|help)
                COMMAND="$1"
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --auto)
                AUTO_MODE=true
                shift
                ;;
            --debug)
                DEBUG=true
                shift
                ;;
            --quiet)
                QUIET=true
                shift
                ;;
            --name)
                DEVICE_NAME="$2"
                shift 2
                ;;
            --mtu)
                MTU_VALUE="$2"
                shift 2
                ;;
            --url)
                MANAGEMENT_URL="$2"
                shift 2
                ;;
            --key)
                SETUP_KEY="$2"
                shift 2
                ;;
            --port)
                WEB_PORT="$2"
                shift 2
                ;;
            *)
                log_error "Неизвестный аргумент: $1"
                usage
                exit 1
                ;;
        esac
    done
}

# --- 8. Основная логика ---

main() {
    # Инициализация
    if [ "$DEBUG" = true ]; then
        set -x
    fi
    
    # Проверяем, запущен ли скрипт от root
    if [ "$(id -u)" -ne 0 ] && [ "$COMMAND" != "status" ] && [ "$COMMAND" != "logs" ] && [ "$COMMAND" != "help" ] && [ "$COMMAND" != "menu" ]; then
        log_error "Скрипт должен быть запущен от root для выполнения команд, кроме status/logs/menu"
        exit 1
    fi
    
    # Выполняем команду
    case "$COMMAND" in
        install)
            if [ "$AUTO_MODE" = false ] && [ -z "$DEVICE_NAME" ]; then
                interactive_name
                interactive_mtu
            fi
            
            # Проверяем management URL, если указан
            if [ -n "$MANAGEMENT_URL" ]; then
                check_management_url "$MANAGEMENT_URL"
            fi
            
            main_install
            
            if [ "$AUTO_MODE" = false ] && [ "$DRY_RUN" = false ]; then
                # Запрос на авторизацию
                print_header "Авторизация в сети"
                printf "Хотите выполнить привязку к серверу? [y/n]: "
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
                                log_info "Использую --hostname для имени устройства"
                            else
                                log_info "Имя устройства будет взято из config.json"
                            fi
                        fi
                        
                        log_info "Подключение к management серверу..."
                        eval "netbird up $AUTH_ARGS"
                        
                        if [ $? -eq 0 ]; then
                            log_info "✅ Подключение успешно!"
                            log_info "Проверьте статус: netbird status"
                        else
                            log_error "❌ Ошибка подключения!"
                        fi
                    else
                        log_warn "Ключ не введен. Авторизация пропущена."
                    fi
                fi
                
                post_install_menu
            fi
            ;;
        start)
            start_service
            ;;
        stop)
            stop_service
            ;;
        restart)
            restart_service
            ;;
        fullrestart)
            full_restart
            ;;
        status)
            show_status
            ;;
        logs)
            show_logs 100
            ;;
        menu)
            post_install_menu
            ;;
        update)
            update_script
            ;;
        uninstall)
            uninstall
            ;;
        help|*)
            usage
            ;;
    esac
}

# --- 9. Запуск ---

# Устанавливаем лог-файл
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/install_$(date +%Y%m%d_%H%M%S).log"

# Парсим аргументы и запускаем
parse_args "$@"
main

# Выход
exit 0
