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

# Восстановление из резервной копии
restore_backup() {
    local backup_path="$1"
    if [ ! -d "$backup_path" ]; then
        log_error "Резервная копия не найдена: $backup_path"
        return 1
    fi
    
    log_info "Восстановление из резервной копии: $backup_path"
    
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Восстановление конфигов"
        return 0
    fi
    
    # Останавливаем NetBird
    /opt/etc/init.d/S99netbird stop 2>/dev/null || true
    
    # Восстанавливаем конфиги
    if [ -d "$backup_path/netbird" ]; then
        rm -rf "$CONFIG_DIR"
        cp -r "$backup_path/netbird" "$CONFIG_DIR"
    fi
    
    # Восстанавливаем iptables
    if [ -f "$backup_path/iptables" ]; then
        cp "$backup_path/iptables" "/opt/sbin/iptables"
    fi
    
    # Восстанавливаем init-скрипт
    if [ -f "$backup_path/S99netbird" ]; then
        cp "$backup_path/S99netbird" "/opt/etc/init.d/S99netbird"
        chmod +x "/opt/etc/init.d/S99netbird"
    fi
    
    log_info "✓ Восстановление завершено"
    return 0
}

# Проверка целостности бинарника
verify_binary() {
    local binary="$1"
    local expected_sha="$2"
    
    if [ ! -f "$binary" ]; then
        log_error "Бинарник не найден: $binary"
        return 1
    fi
    
    if [ -z "$expected_sha" ]; then
        log_debug "Контрольная сумма не указана, пропускаем проверку"
        return 0
    fi
    
    log_debug "Проверка целостности: $binary"
    local actual_sha=$(sha256sum "$binary" | cut -d' ' -f1)
    
    if [ "$actual_sha" != "$expected_sha" ]; then
        log_error "Контрольная сумма не совпадает!"
        log_error "  Ожидалось: $expected_sha"
        log_error "  Получено: $actual_sha"
        return 1
    fi
    
    log_info "✓ Контрольная сумма совпадает"
    return 0
}

# Проверка уникальности IP
check_ip_uniqueness() {
    local ip_to_check="$1"
    
    log_debug "Проверка уникальности IP: $ip_to_check"
    
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Проверка IP $ip_to_check"
        return 0
    fi
    
    if command -v netbird >/dev/null 2>&1; then
        local peers=$(netbird status --json 2>/dev/null | grep -o '"ip":"[^"]*"' | cut -d'"' -f4 | grep -v "^$")
        for peer_ip in $peers; do
            if [ "$peer_ip" = "$ip_to_check" ]; then
                log_warn "⚠ IP $ip_to_check уже используется другим узлом!"
                return 1
            fi
        done
        log_info "✓ IP свободен"
        return 0
    else
        log_debug "netbird не доступен, пропускаем проверку уникальности"
        return 0
    fi
}

# Автоматический подбор свободного IP
find_free_ip() {
    local base_ip="${1:-100.64.0.1}"
    local start_num=$(echo "$base_ip" | cut -d'.' -f4)
    local base_prefix=$(echo "$base_ip" | cut -d'.' -f1-3)
    
    if [ -z "$start_num" ] || [ -z "$base_prefix" ]; then
        base_prefix="100.64.0"
        start_num=1
    fi
    
    log_info "Поиск свободного IP в подсети ${base_prefix}.0/24..."
    
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Найден свободный IP: ${base_prefix}.${start_num}"
        echo "${base_prefix}.${start_num}"
        return 0
    fi
    
    for i in $(seq "$start_num" 254); do
        local test_ip="${base_prefix}.${i}"
        if ! ping -c 1 -W 1 "$test_ip" >/dev/null 2>&1; then
            log_info "✓ Найден свободный IP: $test_ip"
            echo "$test_ip"
            return 0
        fi
    done
    
    log_warn "Не найден свободный IP, использую ${base_prefix}.254"
    echo "${base_prefix}.254"
    return 0
}

# --- 3. Основные функции установки ---

# Функция установки пакетов
install_packages() {
    log_info "Обновление репозиториев и установка пакетов..."
    
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Будет выполнено: opkg update && opkg install iptables netbird cron"
        return 0
    fi
    
    opkg update || {
        log_error "Не удалось обновить репозитории"
        return 1
    }
    
    opkg install iptables netbird cron || {
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
    
    # Добавляем статический IP, если задан
    if [ -n "$STATIC_IP" ]; then
        cat << EOF >> "$CONFIG_DIR/config.json"
  ,"Address": "$STATIC_IP"
EOF
    fi
    
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
    
    # Добавляем DNS, если задан
    if [ -n "$DNS_SERVER" ]; then
        cat << EOF >> "$CONFIG_DIR/config.json"
  ,"DnsPrimary": "$DNS_SERVER"
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
echo "=== Интерфейс $NETBIRD_IFACE ==="
ip addr show "$NETBIRD_IFACE" 2>/dev/null || echo "Интерфейс не найден"
echo ""
echo "=== Статистика интерфейса ==="
ip -s link show "$NETBIRD_IFACE" 2>/dev/null | tail -n 4 || echo "N/A"
echo ""
echo "=== Активные маршруты ==="
ip route | grep "$NETBIRD_IFACE" || echo "Маршрутов нет"
echo ""
echo "=== Текущий конфиг ==="
cat /opt/etc/netbird/config.json 2>/dev/null | head -20
echo ""
echo "=== Последние логи (10 строк) ==="
tail -n 10 /opt/var/log/netbird.log 2>/dev/null || echo "Лог не найден"
EOF
    chmod +x "$CONFIG_DIR/status.sh"
    
    # Экспорт метрик для мониторинга
    cat << 'EOF' > "$CONFIG_DIR/metrics.sh"
#!/bin/sh
# Экспорт метрик для Prometheus/Node Exporter
OUTPUT=""

# Статус подключения
if pidof netbird >/dev/null; then
    OUTPUT="$OUTPUT\nnetbird_status 1"
else
    OUTPUT="$OUTPUT\nnetbird_status 0"
fi

# Uptime (в секундах)
if [ -f /var/run/netbird.pid ]; then
    PID=$(cat /var/run/netbird.pid 2>/dev/null)
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        UPTIME=$(ps -o etimes= -p "$PID" 2>/dev/null | tr -d ' ')
        [ -n "$UPTIME" ] && OUTPUT="$OUTPUT\nnetbird_uptime_seconds $UPTIME"
    fi
fi

# Трафик интерфейса
if [ -f "/sys/class/net/wt0/statistics/rx_bytes" ]; then
    RX=$(cat /sys/class/net/wt0/statistics/rx_bytes 2>/dev/null)
    TX=$(cat /sys/class/net/wt0/statistics/tx_bytes 2>/dev/null)
    [ -n "$RX" ] && OUTPUT="$OUTPUT\nnetbird_rx_bytes $RX"
    [ -n "$TX" ] && OUTPUT="$OUTPUT\nnetbird_tx_bytes $TX"
fi

echo -e "$OUTPUT" | grep -v '^$'
EOF
    chmod +x "$CONFIG_DIR/metrics.sh"
    
    # Настройка ротации логов
    cat << 'EOF' >> /opt/etc/crontab
# Ротация логов NetBird
0 0 * * * find /opt/var/log/ -name "netbird*.log" -size +10M -exec mv {} {}.old \; -exec gzip {} \;
EOF
    
    log_info "✓ Мониторинг настроен"
    return 0
}

# Функция настройки веб-интерфейса
setup_web_interface() {
    log_info "Настройка веб-интерфейса..."
    
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Создание веб-интерфейса"
        return 0
    fi
    
    # Проверяем наличие веб-сервера
    if [ ! -d "/www" ]; then
        log_warn "Директория /www не найдена. Веб-интерфейс не будет настроен."
        return 0
    fi
    
    cat << 'EOF' > /www/netbird_status.html
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>NetBird Status</title>
    <style>
        body { font-family: monospace; background: #1e1e1e; color: #d4d4d4; padding: 20px; }
        pre { background: #2d2d2d; padding: 15px; border-radius: 5px; overflow: auto; }
        .status-ok { color: #4ec9b0; }
        .status-error { color: #f44747; }
        h1 { color: #569cd6; }
    </style>
</head>
<body>
    <h1>🔵 NetBird Status</h1>
    <pre id="status">Загрузка...</pre>
    <script>
        setInterval(() => {
            fetch('/cgi-bin/netbird_status.sh')
                .then(r => r.text())
                .then(data => {
                    document.getElementById('status').textContent = data;
                })
                .catch(err => {
                    document.getElementById('status').textContent = 'Ошибка загрузки: ' + err;
                });
        }, 5000);
        // Первая загрузка
        fetch('/cgi-bin/netbird_status.sh')
            .then(r => r.text())
            .then(data => {
                document.getElementById('status').textContent = data;
            });
    </script>
</body>
</html>
EOF
    
    # CGI скрипт для статуса
    mkdir -p /www/cgi-bin
    cat << 'EOF' > /www/cgi-bin/netbird_status.sh
#!/bin/sh
echo "Content-Type: text/plain"
echo ""
/opt/etc/netbird/status.sh 2>&1
EOF
    chmod +x /www/cgi-bin/netbird_status.sh
    
    log_info "✓ Веб-интерфейс доступен по адресу: http://$(hostname)/netbird_status.html"
    return 0
}

# Функция настройки хуков
setup_hooks() {
    log_info "Настройка системы хуков..."
    
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Создание директории hooks"
        return 0
    fi
    
    mkdir -p "$CONFIG_DIR/hooks"
    
    # Примеры хуков
    cat << 'EOF' > "$CONFIG_DIR/hooks/pre_install.sh"
#!/bin/sh
# Хук: Выполняется ДО установки
echo "Выполняется pre_install hook..."
exit 0
EOF
    
    cat << 'EOF' > "$CONFIG_DIR/hooks/post_install.sh"
#!/bin/sh
# Хук: Выполняется ПОСЛЕ установки
echo "Выполняется post_install hook..."
# Пример: настройка дополнительных маршрутов
# ip route add 10.0.0.0/8 via 100.64.0.1 dev wt0
exit 0
EOF
    
    cat << 'EOF' > "$CONFIG_DIR/hooks/pre_start.sh"
#!/bin/sh
# Хук: Выполняется ПЕРЕД запуском демона
echo "Выполняется pre_start hook..."
exit 0
EOF
    
    cat << 'EOF' > "$CONFIG_DIR/hooks/post_stop.sh"
#!/bin/sh
# Хук: Выполняется ПОСЛЕ остановки демона
echo "Выполняется post_stop hook..."
exit 0
EOF
    
    chmod +x "$CONFIG_DIR/hooks/"*.sh
    
    log_info "✓ Хуки настроены"
    return 0
}

# Функция выполнения хуков
run_hook() {
    local hook_name="$1"
    local hook_path="$CONFIG_DIR/hooks/$hook_name.sh"
    
    if [ -f "$hook_path" ] && [ -x "$hook_path" ]; then
        log_info "Выполнение хука: $hook_name"
        if [ "$DRY_RUN" = true ]; then
            log_info "[DRY-RUN] Будет выполнен хук: $hook_name"
        else
            "$hook_path"
            local result=$?
            if [ $result -ne 0 ]; then
                log_warn "Хук $hook_name завершился с кодом $result"
            fi
        fi
    else
        log_debug "Хук $hook_name не найден или не исполняемый"
    fi
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
    
    # Скрипт изменения IP
    cat << 'EOF' > "$CONFIG_DIR/change_ip.sh"
#!/bin/sh
echo "=== Изменение статического IP NetBird ==="
echo ""

if pidof netbird >/dev/null; then
    /opt/etc/init.d/S99netbird stop
    sleep 2
fi

printf "Введите новый статический IP (например, 100.64.0.10): "
read new_ip

if [ -z "$new_ip" ]; then
    echo "IP не введен. Операция отменена."
    exit 1
fi

if ! echo "$new_ip" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
    echo "❌ Неверный формат IP!"
    exit 1
fi

CONFIG_FILE="/opt/etc/netbird/config.json"
cp "$CONFIG_FILE" "$CONFIG_FILE.bak.$(date +%Y%m%d_%H%M%S)"

if grep -q '"Address"' "$CONFIG_FILE"; then
    sed -i "s/\"Address\": \"[0-9.]*\"/\"Address\": \"$new_ip\"/g" "$CONFIG_FILE"
else
    sed -i "s/}/,\"Address\": \"$new_ip\"\n}/g" "$CONFIG_FILE"
fi

echo "✓ Конфигурация обновлена"

/opt/etc/init.d/S99netbird start
echo "Проверьте статус: netbird status"
EOF
    
    # Скрипт обновления
    cat << 'EOF' > "$CONFIG_DIR/update.sh"
#!/bin/sh
echo "=== Обновление NetBird и скриптов ==="
echo ""

echo "Обновление пакетов..."
opkg update && opkg upgrade netbird

echo "Обновление скрипта..."
SCRIPT_URL="https://raw.githubusercontent.com/your-repo/netbird-install-script-opkg/main/netbird-install-script-opkg.sh"
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
    
    chmod +x "$CONFIG_DIR/"change_name.sh "$CONFIG_DIR/"change_ip.sh "$CONFIG_DIR/"update.sh
    
    log_info "✓ Дополнительные инструменты настроены"
    return 0
}

# --- 4. Интерактивные блоки ---

# Интерактивная настройка имени устройства
interactive_name() {
    print_header "Настройка имени устройства"
    
    echo "Варианты действий:"
    echo "  1) Выбрать из списка известных устройств"
    echo "  2) Ввести имя вручную"
    echo "  3) Использовать имя хоста (текущее: $(hostname))"
    echo "  4) Пропустить (авто-генерация NetBird)"
    printf "Выберите вариант [1-4]: "
    read name_option
    
    case "$name_option" in
        1)
            echo ""
            echo "Известные устройства:"
            echo "  1) 10-Antipino"
            echo "  2) 00-Druzhby"
            echo "  3) 04-kurgan"
            echo "  4) DESKTOP-04097GC"
            echo "  5) 24-talica"
            echo "  6) Ввести вручную"
            printf "Выберите номер [1-6]: "
            read device_num
            
            case "$device_num" in
                1) DEVICE_NAME="10-Antipino" ;;
                2) DEVICE_NAME="00-Druzhby" ;;
                3) DEVICE_NAME="04-kurgan" ;;
                4) DEVICE_NAME="DESKTOP-04097GC" ;;
                5) DEVICE_NAME="24-talica" ;;
                6) 
                    printf "Введите имя: "
                    read DEVICE_NAME
                    ;;
                *) 
                    DEVICE_NAME=$(hostname)
                    log_warn "Неверный выбор, использую имя хоста"
                    ;;
            esac
            ;;
        2)
            printf "Введите имя устройства: "
            read DEVICE_NAME
            ;;
        3)
            DEVICE_NAME=$(hostname)
            log_info "Использую имя хоста: $DEVICE_NAME"
            ;;
        *)
            DEVICE_NAME=""
            log_info "Имя не задано (будет сгенерировано автоматически)"
            ;;
    esac
    
    [ -n "$DEVICE_NAME" ] && log_info "✓ Имя устройства: $DEVICE_NAME"
}

# Интерактивная настройка статического IP
interactive_ip() {
    print_header "Настройка статического IP"
    
    printf "Хотите назначить статический IP? [y/n]: "
    read assign_ip
    
    if [ "$assign_ip" = "y" ] || [ "$assign_ip" = "Y" ]; then
        printf "Введите IP адрес (например, 100.64.0.10) [Enter для автоподбора]: "
        read STATIC_IP
        
        if [ -z "$STATIC_IP" ]; then
            STATIC_IP=$(find_free_ip)
        elif ! echo "$STATIC_IP" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
            log_error "Неверный формат IP, выполняю автоподбор..."
            STATIC_IP=$(find_free_ip)
        else
            # Проверка уникальности
            if ! check_ip_uniqueness "$STATIC_IP"; then
                log_warn "IP занят, выполняю автоподбор..."
                STATIC_IP=$(find_free_ip)
            fi
        fi
        
        log_info "✓ Статический IP: $STATIC_IP"
    else
        STATIC_IP=""
        log_info "Статический IP не назначен"
    fi
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

# Интерактивная настройка дополнительных пакетов
interactive_packages() {
    print_header "Дополнительные пакеты"
    
    echo "Доступные дополнительные пакеты:"
    echo "  1) tcpdump - диагностика сети"
    echo "  2) nano - текстовый редактор"
    echo "  3) htop - мониторинг процессов"
    echo "  4) mtr - трассировка маршрута"
    echo "  5) установить все"
    echo "  6) пропустить"
    printf "Выберите вариант [1-6]: "
    read pkg_choice
    
    local pkgs=""
    case "$pkg_choice" in
        1) pkgs="tcpdump" ;;
        2) pkgs="nano" ;;
        3) pkgs="htop" ;;
        4) pkgs="mtr" ;;
        5) pkgs="tcpdump nano htop mtr" ;;
        *) log_info "Дополнительные пакеты не будут установлены"; return 0 ;;
    esac
    
    if [ -n "$pkgs" ]; then
        log_info "Установка пакетов: $pkgs"
        if [ "$DRY_RUN" = false ]; then
            opkg install $pkgs || log_warn "Некоторые пакеты не установлены"
        else
            log_info "[DRY-RUN] Установка: $pkgs"
        fi
    fi
}

# --- 5. Функции управления ---

# Основная установка
main_install() {
    log_info "Начало установки NetBird v$VERSION"
    
    # Выполняем хуки
    run_hook "pre_install"
    
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
    
    # Настраиваем хуки
    setup_hooks || return 1
    
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
    
    # Выполняем хуки
    run_hook "post_install"
    
    log_info "✅ Установка завершена успешно!"
    return 0
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
    
    run_hook "pre_stop"
    /opt/etc/init.d/S99netbird stop 2>/dev/null || {
        log_warn "Не удалось остановить сервис"
    }
    run_hook "post_stop"
}

# Запуск сервиса
start_service() {
    log_info "Запуск NetBird..."
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Запуск сервиса"
        return 0
    fi
    
    run_hook "pre_start"
    /opt/etc/init.d/S99netbird start 2>/dev/null || {
        log_error "Не удалось запустить сервис"
        return 1
    }
    run_hook "post_start"
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
    
    # Останавливаем сервис
    /opt/etc/init.d/S99netbird stop 2>/dev/null || true
    
    # Удаляем пакеты
    opkg remove netbird 2>/dev/null || true
    
    # Удаляем конфиги
    rm -rf "$CONFIG_DIR"
    rm -rf /opt/var/lib/netbird
    
    # Восстанавливаем iptables
    if [ -f /opt/sbin/iptables.real ]; then
        mv /opt/sbin/iptables.real /opt/sbin/iptables
    fi
    
    # Удаляем init-скрипт
    rm -f /opt/etc/init.d/S99netbird
    
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
    print_header "Дополнительные настройки"
    
    while true; do
        echo "Доступные опции:"
        echo "  1) Показать статус"
        echo "  2) Показать логи"
        echo "  3) Изменить имя устройства"
        echo "  4) Изменить статический IP"
        echo "  5) Обновить скрипт"
        echo "  6) Настроить ротацию логов"
        echo "  7) Установить дополнительные пакеты"
        echo "  8) Экспорт метрик для мониторинга"
        echo "  9) Веб-интерфейс"
        echo "  10) Выход"
        printf "Выберите опцию [1-10]: "
        read menu_choice
        
        case "$menu_choice" in
            1) show_status ;;
            2) show_logs ;;
            3) 
                if [ -f "$CONFIG_DIR/change_name.sh" ]; then
                    "$CONFIG_DIR/change_name.sh"
                else
                    log_error "Скрипт изменения имени не найден"
                fi
                ;;
            4)
                if [ -f "$CONFIG_DIR/change_ip.sh" ]; then
                    "$CONFIG_DIR/change_ip.sh"
                else
                    log_error "Скрипт изменения IP не найден"
                fi
                ;;
            5) update_script ;;
            6)
                if [ "$DRY_RUN" = false ]; then
                    echo "Настройка ротации логов..."
                    echo "0 0 * * * find /opt/var/log/ -name 'netbird*.log' -size +10M -exec mv {} {}.old \; -exec gzip {} \;" >> /opt/etc/crontab
                    /opt/etc/init.d/S10cron restart 2>/dev/null || true
                    log_info "✓ Ротация логов настроена"
                else
                    log_info "[DRY-RUN] Настройка ротации логов"
                fi
                ;;
            7) interactive_packages ;;
            8)
                if [ -f "$CONFIG_DIR/metrics.sh" ]; then
                    echo "=== Метрики NetBird ==="
                    "$CONFIG_DIR/metrics.sh"
                    echo ""
                    echo "Для интеграции с Prometheus добавьте в node_exporter:"
                    echo "  --collector.textfile.directory=/opt/etc/netbird"
                    echo "И создайте cron-задание для сохранения метрик:"
                    echo "  */5 * * * * /opt/etc/netbird/metrics.sh > /opt/etc/netbird/metrics.prom"
                fi
                ;;
            9)
                if [ -f "/www/netbird_status.html" ]; then
                    echo "Веб-интерфейс доступен по адресу:"
                    echo "  http://$(hostname)/netbird_status.html"
                else
                    log_warn "Веб-интерфейс не настроен"
                fi
                ;;
            10)
                log_info "Выход из меню"
                break
                ;;
            *)
                log_error "Неверный выбор"
                ;;
        esac
        echo ""
    done
}

# --- 7. Обработка аргументов командной строки ---

usage() {
    echo "NetBird Installer для Keenetic v$VERSION"
    echo ""
    echo "Использование:"
    echo "  $0 [COMMAND] [OPTIONS]"
    echo ""
    echo "Команды:"
    echo "  install      - Установка NetBird (по умолчанию)"
    echo "  start        - Запустить сервис"
    echo "  stop         - Остановить сервис"
    echo "  restart      - Перезапустить сервис"
    echo "  status       - Показать статус"
    echo "  logs         - Показать логи"
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
    echo "  --ip IP      - Статический IP"
    echo "  --mtu MTU    - MTU интерфейса"
    echo "  --url URL    - Management URL"
    echo "  --key KEY    - Setup Key"
    echo ""
    echo "Примеры:"
    echo "  $0 install --auto --name '10-Antipino' --ip 100.64.0.10"
    echo "  $0 status"
    echo "  $0 --dry-run install"
}

parse_args() {
    COMMAND="install"
    
    while [ $# -gt 0 ]; do
        case "$1" in
            install|start|stop|restart|status|logs|update|uninstall|help)
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
            --ip)
                STATIC_IP="$2"
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
    if [ "$(id -u)" -ne 0 ] && [ "$COMMAND" != "status" ] && [ "$COMMAND" != "logs" ] && [ "$COMMAND" != "help" ]; then
        log_error "Скрипт должен быть запущен от root для выполнения команд, кроме status/logs"
        exit 1
    fi
    
    # Выполняем команду
# --- Блок авторизации (исправленный) ---
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
        # Базовые аргументы
        AUTH_ARGS="--management-url \"$MANAGEMENT_URL\" --setup-key \"$SETUP_KEY\""
        
        # Проверяем, как задавать имя устройства
        if [ -n "$DEVICE_NAME" ]; then
            # Проверяем поддержку --hostname (новый синтаксис)
            if netbird up --help 2>&1 | grep -q -- "--hostname"; then
                AUTH_ARGS="$AUTH_ARGS --hostname \"$DEVICE_NAME\""
                log_info "Использую --hostname для имени устройства"
            else
                # Имя уже в config.json, ничего не делаем
                log_info "Имя устройства будет взято из config.json"
            fi
        fi
        
        # Выполняем подключение
        log_info "Подключение к management серверу..."
        eval "netbird up $AUTH_ARGS"
        
        # Проверяем статус
        if [ $? -eq 0 ]; then
            log_info "✅ Подключение успешно!"
            log_info "Проверьте статус: netbird status"
        else
            log_error "❌ Ошибка подключения!"
            log_info "Попробуйте подключиться вручную:"
            if [ -n "$DEVICE_NAME" ]; then
                echo "  netbird up --management-url \"$MANAGEMENT_URL\" --setup-key \"$SETUP_KEY\" --hostname \"$DEVICE_NAME\""
            else
                echo "  netbird up --management-url \"$MANAGEMENT_URL\" --setup-key \"$SETUP_KEY\""
            fi
        fi
    else
        log_warn "Ключ не введен. Авторизация пропущена."
        log_info "Выполните позже:"
        if [ -n "$DEVICE_NAME" ]; then
            echo "  netbird up --management-url \"$MANAGEMENT_URL\" --setup-key YOUR_KEY --hostname \"$DEVICE_NAME\""
        else
            echo "  netbird up --management-url \"$MANAGEMENT_URL\" --setup-key YOUR_KEY"
        fi
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
        status)
            show_status
            ;;
        logs)
            show_logs 100
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
