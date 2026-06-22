#!/bin/sh
# ==========================================================
# NetBird Installer для Keenetic v6.0
# ==========================================================
# Чистая установка NetBird на Keenetic (Entware)
# Без меню, без запроса имени

set -e

VERSION="6.0"
LOG_DIR="/opt/var/log/netbird"
BACKUP_DIR="/opt/backups/netbird"
CONFIG_DIR="/opt/etc/netbird"
DRY_RUN=false
DEBUG=false
QUIET=false

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

# --- Основные функции установки ---

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
    
    cat << EOF > "$CONFIG_DIR/config.json"
{
  "WgIface": "wt0",
  "WgPort": 51825,
  "DisableFirewall": true,
  "IFaceDiscover": false,
  "WgMTU": 1420
}
EOF
    
    log_info "✓ Конфигурация создана (MTU: 1420)"
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
            
            $PROG $ARGS &
            sleep 3
            
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

setup_control_script() {
    log_info "Установка скрипта управления 'netbird-ctl'..."
    [ "$DRY_RUN" = true ] && return 0
    
    cat << 'EOF' > /opt/bin/netbird-ctl
#!/bin/sh
# ==========================================================
# NetBird Control Script v1.0
# ==========================================================

CONFIG_DIR="/opt/etc/netbird"
LOG_DIR="/opt/var/log/netbird"

print_header() {
    echo ""
    echo "======================================================="
    echo "  $1"
    echo "======================================================="
    echo ""
}

show_status() {
    print_header "Статус NetBird"
    if [ -f "$CONFIG_DIR/status.sh" ]; then
        "$CONFIG_DIR/status.sh"
    else
        echo "Скрипт статуса не найден"
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

full_restart() {
    print_header "Полный перезапуск всех сервисов"
    echo "Остановка..."
    [ -f /opt/etc/init.d/S99netbird ] && /opt/etc/init.d/S99netbird stop
    sleep 2
    echo "Запуск..."
    [ -f /opt/etc/init.d/S99netbird ] && /opt/etc/init.d/S99netbird start
    [ -f /opt/etc/ndm/netfilter.d/netbird.sh ] && {
        table=filter /opt/etc/ndm/netfilter.d/netbird.sh
        table=nat /opt/etc/ndm/netfilter.d/netbird.sh
    }
    echo "✅ Все сервисы перезапущены!"
}

show_menu() {
    while true; do
        print_header "Меню управления NetBird"
        echo "Доступные опции:"
        echo "  1) Показать статус"
        echo "  2) Показать логи"
        echo "  3) Перезапустить демон"
        echo "  4) Полный перезапуск всех сервисов"
        echo "  5) Показать конфигурацию"
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
                echo "Перезапуск демона NetBird..."
                /opt/etc/init.d/S99netbird restart
                echo "✅ Демон перезапущен"
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
                print_header "Конфигурация NetBird"
                cat /opt/etc/netbird/config.json 2>/dev/null || echo "Конфиг не найден"
                echo ""
                printf "Нажмите Enter для продолжения..."
                read dummy
                ;;
            0)
                echo "Выход из меню"
                break
                ;;
            *)
                echo "Неверный выбор"
                sleep 1
                ;;
        esac
    done
}

case "$1" in
    status)
        show_status
        ;;
    logs)
        show_logs "${2:-50}"
        ;;
    restart)
        /opt/etc/init.d/S99netbird restart
        ;;
    fullrestart)
        full_restart
        ;;
    menu)
        show_menu
        ;;
    *)
        echo "NetBird Control Script"
        echo ""
        echo "Использование: netbird-ctl {menu|status|logs|restart|fullrestart}"
        echo ""
        echo "  menu        - открыть интерактивное меню"
        echo "  status      - показать статус"
        echo "  logs [N]    - показать последние N строк логов (по умолчанию 50)"
        echo "  restart     - перезапустить демон NetBird"
        echo "  fullrestart - полный перезапуск всех сервисов"
        echo ""
        ;;
esac
EOF
    chmod +x /opt/bin/netbird-ctl
    
    # Создаем симлинк для удобства
    ln -sf /opt/bin/netbird-ctl /usr/bin/netbird-ctl 2>/dev/null || true
    
    log_info "✓ Скрипт управления установлен в /opt/bin/netbird-ctl"
    log_info "  Используйте: netbird-ctl menu"
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
    setup_control_script || return 1
    
    if [ "$DRY_RUN" = false ]; then
        sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
        table=filter /opt/etc/ndm/netfilter.d/netbird.sh
        table=nat /opt/etc/ndm/netfilter.d/netbird.sh
        log_info "Запуск демона NetBird..."
        /opt/etc/init.d/S99netbird start
        sleep 3
    fi
    
    log_info "✅ Установка завершена успешно!"
    return 0
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
    rm -f /opt/bin/netbird-ctl
    rm -f /usr/bin/netbird-ctl 2>/dev/null || true
    sed -i '\#netbird#d' /opt/etc/crontab 2>/dev/null
    log_info "✅ NetBird полностью удален"
}

usage() {
    echo "NetBird Installer для Keenetic v$VERSION"
    echo ""
    echo "Использование: netbird-install [install|uninstall|help]"
    echo ""
    echo "  install   - установка NetBird"
    echo "  uninstall - полное удаление"
    echo "  help      - эта справка"
    echo ""
    echo "После установки используйте: netbird-ctl menu"
}

# ==========================================================
# ГЛАВНАЯ ФУНКЦИЯ
# ==========================================================
main() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "Скрипт должен быть запущен от root"
        exit 1
    fi
    
    case "$1" in
        install|"")
            main_install
            print_header "УСТАНОВКА ЗАВЕРШЕНА!"
            echo ""
            echo "Для управления используйте:"
            echo "  netbird-ctl menu     - открыть меню управления"
            echo "  netbird-ctl status   - показать статус"
            echo "  netbird-ctl logs     - показать логи"
            echo "  netbird-ctl restart  - перезапустить демон"
            echo ""
            echo "Для авторизации выполните:"
            echo "  netbird up --management-url https://ваш-сервер --setup-key ВАШ-КЛЮЧ"
            echo ""
            ;;
        uninstall)
            uninstall
            ;;
        help|*)
            usage
            ;;
    esac
}

main "$@"
exit 0
