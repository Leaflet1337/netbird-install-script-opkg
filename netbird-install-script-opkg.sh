#!/bin/sh
# ==========================================================
# NetBird Installer для Keenetic v4.6 (Финальная рабочая)
# ==========================================================

set -e

VERSION="4.6"
LOG_DIR="/opt/var/log/netbird"
BACKUP_DIR="/opt/backups/netbird"
CONFIG_DIR="/opt/etc/netbird"
DRY_RUN=false
AUTO_MODE=false
DEBUG=false
QUIET=false

SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null || echo "/opt/bin/netbird")

# --- Цвета ---
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

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

sanitize_device_name() {
    echo "$1" | tr -cd 'A-Za-z0-9-_.' | tr ' ' '_'
}

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

install_base_packages() {
    log_info "Обновление репозиториев и установка пакетов..."
    [ "$DRY_RUN" = true ] && { log_info "[DRY-RUN] Установка пакетов"; return 0; }
    
    opkg update || { log_error "Не удалось обновить репозитории"; return 1; }
    opkg install iptables netbird cron || {
        log_error "Не удалось установить пакеты"
        return 1
    }
    log_info "✓ Пакеты установлены"
    return 0
}

setup_iptables() {
    log_info "Настройка эмулятора iptables..."
    [ "$DRY_RUN" = true ] && return 0
    
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
        SANITIZED_NAME=$(sanitize_device_name "$DEVICE_NAME")
        echo "  ,\"Name\": \"$SANITIZED_NAME\"" >> "$CONFIG_DIR/config.json"
    fi
    
    if [ -n "$MTU_VALUE" ]; then
        echo "  ,\"WgMTU\": $MTU_VALUE" >> "$CONFIG_DIR/config.json"
    fi
    
    echo "}" >> "$CONFIG_DIR/config.json"
    log_info "✓ Конфигурация создана"
    return 0
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
            mkdir -p /opt/var/run /opt/var/log
            export NB_DISABLE_FIREWALL=true
            
            # Запускаем демон
            $PROG $ARGS &
            sleep 3
            
            # Запускаем бесконечный цикл-страж в фоновом режиме
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
                        $PROG $ARGS >/dev/null 2>&1 &
                        sleep 3
                    fi
                    sleep 5
                done
            ) &
            echo "NetBird watchdog service started."
        fi
        ;;
    stop)
        PID=$(pgrep -f "while true; do if ! pidof netbird")
        [ -n "$PID" ] && kill -9 $PID 2>/dev/null
        killall netbird 2>/dev/null || true
        rm -f /opt/var/run/netbird.sock
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
    return 0
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
new_name=$(echo "$new_name" | tr -cd 'A-Za-z0-9-_.' | tr ' ' '_')
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
/opt/etc/init.d/S99netbird restart
echo "Обновление завершено"
EOF
    
    chmod +x "$CONFIG_DIR/"change_name.sh "$CONFIG_DIR/"update.sh
    log_info "✓ Дополнительные инструменты настроены"
    return 0
}

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
            DEVICE_NAME=$(sanitize_device_name "$DEVICE_NAME")
            log_info "✓ Имя устройства: $DEVICE_NAME"
            ;;
        2)
            DEVICE_NAME=$(sanitize_device_name "$(hostname)")
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
    
    if [ "$DRY_RUN" = false ]; then
        sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
        table=filter /opt/etc/ndm/netfilter.d/netbird.sh
        table=nat /opt/etc/ndm/netfilter.d/netbird.sh
    fi
    
    log_info "✅ Установка завершена успешно!"
    return 0
}

full_restart() {
    print_header "Полный перезапуск всех сервисов"
    log_info "Остановка..."
    [ -f /opt/etc/init.d/S99netbird ] && /opt/etc/init.d/S99netbird stop
    sleep 2
    log_info "Запуск..."
    [ -f /opt/etc/init.d/S99netbird ] && /opt/etc/init.d/S99netbird start
    [ -f /opt/etc/ndm/netfilter.d/netbird.sh ] && {
        table=filter /opt/etc/ndm/netfilter.d/netbird.sh
        table=nat /opt/etc/ndm/netfilter.d/netbird.sh
    }
    log_info "✅ Все сервисы перезапущены!"
}

show_status() {
    print_header "Статус NetBird"
    if [ -f "$CONFIG_DIR/status.sh" ]; then
        "$CONFIG_DIR/status.sh"
    else
        netbird status 2>/dev/null || echo "NetBird не запущен"
        ip addr show wt0 2>/dev/null
    fi
}

show_logs() {
    local lines="${1:-50}"
    print_header "Последние $lines строк логов"
    echo "=== netbird.log ==="
    tail -n "$lines" /opt/var/log/netbird.log 2>/dev/null || echo "Лог не найден"
    echo ""
    echo "=== netbird_watchdog.log ==="
    tail -n "$lines" /opt/var/log/netbird_watchdog.log 2>/dev/null || echo "Лог не найден"
}

stop_service() { [ "$DRY_RUN" = false ] && /opt/etc/init.d/S99netbird stop 2>/dev/null; }
start_service() { [ "$DRY_RUN" = false ] && /opt/etc/init.d/S99netbird start 2>/dev/null; }
restart_service() { stop_service; sleep 2; start_service; }

update_script() {
    print_header "Обновление"
    [ -f "$CONFIG_DIR/update.sh" ] && "$CONFIG_DIR/update.sh" || {
        opkg update && opkg upgrade netbird
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
    [ -f /opt/etc/init.d/S99netbird ] && /opt/etc/init.d/S99netbird stop 2>/dev/null || true
    opkg remove netbird 2>/dev/null || true
    rm -rf "$CONFIG_DIR"
    rm -rf /opt/var/lib/netbird
    if [ -f /opt/sbin/iptables.real ]; then
        mv /opt/sbin/iptables.real /opt/sbin/iptables
    fi
    rm -f /opt/etc/init.d/S99netbird
    rm -f /opt/etc/ndm/netfilter.d/netbird.sh
    [ -L /opt/bin/netbird ] && rm -f /opt/bin/netbird
    sed -i '\#netbird#d' /opt/etc/crontab 2>/dev/null
    log_info "✅ NetBird полностью удален"
}

post_install_menu() {
    while true; do
        print_header "Меню управления NetBird"
        echo "Доступные опции:"
        echo "  1) Показать статус"
        echo "  2) Показать логи"
        echo "  3) Изменить имя устройства"
        echo "  4) Полный перезапуск всех сервисов"
        echo "  5) Обновить скрипт"
        echo "  0) Выход"
        echo ""
        printf "Выберите опцию [0-5]: "
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

setup_netbird_command() {
    log_info "Настройка команды 'netbird'..."
    [ "$DRY_RUN" = true ] && { log_info "[DRY-RUN] Создание симлинка"; return 0; }
    
    local script_path=$(readlink -f "$0" 2>/dev/null || echo "/opt/bin/netbird")
    
    mkdir -p /opt/bin
    [ -L /opt/bin/netbird ] && rm -f /opt/bin/netbird
    
    if [ -f /opt/bin/netbird ] && [ ! -L /opt/bin/netbird ]; then
        log_warn "Файл /opt/bin/netbird уже существует. Перемещаем в /opt/bin/netbird.bin"
        mv /opt/bin/netbird /opt/bin/netbird.bin
    fi
    
    ln -sf "$script_path" /opt/bin/netbird
    
    if ! echo "$PATH" | grep -q "/opt/bin"; then
        log_warn "/opt/bin не найден в PATH. Добавляем..."
        export PATH="/opt/bin:$PATH"
        mkdir -p /opt/etc
        echo 'export PATH="/opt/bin:$PATH"' >> /opt/etc/profile
        log_info "✓ /opt/bin добавлен в PATH"
    fi
    
    log_info "✓ Команда 'netbird' настроена в /opt/bin/netbird"
    log_info "  Теперь можно использовать:"
    log_info "    netbird menu     - открыть меню"
    log_info "    netbird status   - показать статус"
    log_info "    netbird restart  - перезапустить сервис"
    log_info "    netbird install  - установка"
}

usage() {
    echo "NetBird Installer для Keenetic v$VERSION"
    echo ""
    echo "Команды: install|start|stop|restart|fullrestart|status|logs|menu|update|uninstall|help"
    echo "Опции:"
    echo "  --dry-run    - Режим тестирования"
    echo "  --auto       - Автоматический режим"
    echo "  --debug      - Включить отладку"
    echo "  --quiet      - Минимальный вывод"
    echo "  --name NAME  - Имя устройства"
    echo "  --mtu MTU    - MTU интерфейса"
    echo "  --url URL    - Management URL"
    echo "  --key KEY    - Setup Key"
    echo ""
    echo "Пример: netbird install --auto --name '10-Antipino' --url 'https://netbird.um-ural.ru' --key 'ВАШ-КЛЮЧ'"
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
            --name) 
                DEVICE_NAME=$(sanitize_device_name "$2")
                shift 2 ;;
            --mtu) MTU_VALUE="$2"; shift 2 ;;
            --url) MANAGEMENT_URL="$2"; shift 2 ;;
            --key) SETUP_KEY="$2"; shift 2 ;;
            *) log_error "Неизвестный аргумент: $1"; usage; exit 1 ;;
        esac
    done
}

# ==========================================================
# ГЛАВНАЯ ФУНКЦИЯ
# ==========================================================
main() {
    [ "$DEBUG" = true ] && set -x
    if [ "$(id -u)" -ne 0 ] && [ "$COMMAND" != "status" ] && [ "$COMMAND" != "logs" ] && [ "$COMMAND" != "help" ] && [ "$COMMAND" != "menu" ]; then
        log_error "Скрипт должен быть запущен от root"
        exit 1
    fi
    
    case "$COMMAND" in
        install)
            if [ "$AUTO_MODE" = false ] && [ -z "$DEVICE_NAME" ]; then
                interactive_name
                interactive_mtu
            fi
            
            # Установка
            main_install
            setup_netbird_command
            
            # ЗАПУСКАЕМ ДЕМОН
            if [ "$DRY_RUN" = false ]; then
                log_info "Запуск демона NetBird..."
                /opt/etc/init.d/S99netbird start
                sleep 5
                
                # Проверяем, что сокет создался
                if [ ! -S "/opt/var/run/netbird.sock" ]; then
                    log_error "Сокет не создался! Пробуем запустить вручную..."
                    /opt/sbin/netbird service run --log-file /opt/var/log/netbird.log --log-level info --daemon-addr unix:///opt/var/run/netbird.sock &
                    sleep 5
                fi
                
                if [ -S "/opt/var/run/netbird.sock" ]; then
                    log_info "✓ Демон NetBird запущен"
                else
                    log_error "❌ Не удалось запустить демон NetBird!"
                    log_info "Попробуйте вручную: /opt/sbin/netbird service run &"
                fi
            fi
            
            if [ "$AUTO_MODE" = false ] && [ "$DRY_RUN" = false ]; then
                print_header "Авторизация в сети"
                
                # Проверяем наличие ключей
                if [ -z "$MANAGEMENT_URL" ] || [ -z "$SETUP_KEY" ]; then
                    printf "Введите Management URL [По умолчанию: https://netbird.io]: "
                    read MANAGEMENT_URL </dev/tty
                    [ -z "$MANAGEMENT_URL" ] && MANAGEMENT_URL="https://netbird.io"
                    MANAGEMENT_URL=$(echo "$MANAGEMENT_URL" | tr -d ' ')
                    
                    echo ""
                    printf "Введите Setup Key: "
                    read SETUP_KEY </dev/tty
                    SETUP_KEY=$(echo "$SETUP_KEY" | tr -d ' ' | tr -d '\r' | tr -d '\n')
                fi
                
                echo ""
                if [ -n "$SETUP_KEY" ]; then
                    AUTH_ARGS="--management-url \"$MANAGEMENT_URL\" --setup-key \"$SETUP_KEY\""
                    
                    if [ -n "$DEVICE_NAME" ]; then
                        if netbird up --help 2>&1 | grep -q -- "--hostname"; then
                            AUTH_ARGS="$AUTH_ARGS --hostname \"$DEVICE_NAME\""
                            log_info "Использую --hostname для имени устройства: $DEVICE_NAME"
                        else
                            log_info "Имя будет взято из config.json"
                        fi
                    fi
                    
                    log_info "Подключение к management серверу: $MANAGEMENT_URL"
                    log_info "Setup Key: ${SETUP_KEY:0:8}... (скрыто)"
                    echo ""
                    
                    # Пытаемся авторизоваться
                    eval "netbird up $AUTH_ARGS --timeout 120" || {
                        log_error "❌ Ошибка подключения!"
                        echo ""
                        log_info "Попробуйте вручную:"
                        echo "  netbird up --management-url \"$MANAGEMENT_URL\" --setup-key \"$SETUP_KEY\""
                        if [ -n "$DEVICE_NAME" ]; then
                            echo "  c именем: netbird up --management-url \"$MANAGEMENT_URL\" --setup-key \"$SETUP_KEY\" --hostname \"$DEVICE_NAME\""
                        fi
                    }
                else
                    log_warn "Ключ не введен. Авторизация пропущена."
                    log_info "Выполните позже: netbird up --management-url \"$MANAGEMENT_URL\" --setup-key \"ВАШ-КЛЮЧ\""
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
        uninstall) 
            uninstall
            [ -L /opt/bin/netbird ] && rm -f /opt/bin/netbird
            ;;
        help|*) usage ;;
    esac
}

SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null || echo "/opt/bin/netbird")

parse_args "$@"
main
exit 0
