#!/bin/sh
# Автоматический скрипт комплексного развертывания NetBird для Keenetic (Entware)
# Включает: установку, фиксы фаервола, фоновый вачдог демона и пинг-проверку в cron

# Завершение при критических ошибках
set -e

echo ""
echo "======================================================="
echo "  Автоматическая установка NetBird на Keenetic (Entware)"
echo "======================================================="
echo ""

# Шаг 1. Очистка старых сессий
echo "[1/8] Проверка и очистка старых конфигураций..."
killall -9 netbird 2>/dev/null || true
rm -rf /opt/var/lib/netbird/*
rm -rf /opt/etc/netbird/*

# Шаг 2. Установка пакетов
echo "[2/8] Обновление репозиториев и установка iptables, netbird..."
opkg update
opkg install iptables netbird

# Шаг 3. Создание умного эмулятора iptables
echo "[3/8] Конфигурация эмулятора iptables (обход конфликтов ядра)..."
if [ ! -f /opt/sbin/iptables.real ]; then
    if [ -f /opt/sbin/iptables ]; then
        mv /opt/sbin/iptables /opt/sbin/iptables.real
    else
        echo "Критическая ошибка: оригинальный бинарник /opt/sbin/iptables не найден!"
        exit 1
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

# Шаг 4. Создание базового config.json
echo "[4/8] Генерация эталонного файла конфигурации config.json..."
mkdir -p /opt/etc/netbird
cat << 'EOF' > /opt/etc/netbird/config.json
{
  "WgIface": "wt0",
  "WgPort": 51825,
  "DisableFirewall": true,
  "IFaceDiscover": false
}
EOF

# Шаг 5. Создание демона автозапуска с фоновым Watchdog-процессом
echo "[5/8] Установка модифицированного скрипта инициализации S99netbird..."
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
                while true; do
                    # Проверяем, запущен ли демон в данный момент
                    if ! pidof netbird >/dev/null; then
                        echo "$(date): NetBird daemon stopped. Restarting..." >> /opt/var/log/netbird_watchdog.log
                        $PROG $ARGS >/dev/null 2>&1
                    fi
                    sleep 3
                done
            ) &
            echo "NetBird watchdog service started."
        fi
        ;;
    stop)
        # Сначала уничтожаем цикл-страж, чтобы он не перезапустил процесс принудительно
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

# Шаг 6. Настройка хука NDM netfilter.d с защитой от зацикливания
echo "[6/8] Создание хука маршрутизации Keenetic с Lock-защитой..."
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

# Шаг 7. Запуск служб и применение правил в реальном времени
echo "[7/8] Включение форвардинга пакетов и запуск демона..."
sysctl -w net.ipv4.ip_forward=1
table=filter /opt/etc/ndm/netfilter.d/netbird.sh
table=nat /opt/etc/ndm/netfilter.d/netbird.sh
/opt/etc/init.d/S99netbird start

echo ""
echo "======================================================="
echo "  Базовая настройка завершена! Демон успешно запущен."
echo "  Ожидаем 5 секунд инициализации управляющего сокета..."
echo "======================================================="
sleep 5
echo ""

# Шаг 8. Интерактивная настройка пинг-контроля туннеля через Cron
echo "[8/8] Интерактивная настройка планировщика cron..."
DEFAULT_IP="100.64.0.1"
printf "Введите IP-адрес пира NetBird для проверки доступности [По умолчанию: %s]: " "$DEFAULT_IP"
read user_ip

if [ -z "$user_ip" ]; then
    TARGET_IP="$DEFAULT_IP"
else
    TARGET_IP="$user_ip"
fi

# Проверка и доустановка cron
if ! opkg list-installed | grep -q '^cron\s'; then
    echo "Пакет cron не найден. Доустанавливаем..."
    opkg install cron
fi

# Генерируем скрипт проверки туннеля с подставленным IP (экранируем внутренние переменные)
cat << EOF > /opt/etc/netbird/check_tunnel.sh
#!/bin/sh
# Скрипт автоматической проверки туннеля NetBird
TARGET_IP="$TARGET_IP"

if ! ping -c 3 -W 2 \$TARGET_IP > /dev/null 2>&1; then
    echo "\$(date): Tunnel to \$TARGET_IP is down! Restarting NetBird..." >> /opt/var/log/netbird_cron.log
    /opt/etc/init.d/S99netbird restart
fi
EOF
chmod +x /opt/etc/netbird/check_tunnel.sh

# Запись в crontab без дублирования
CRON_JOB="*/5 * * * * /opt/etc/netbird/check_tunnel.sh"
if [ -f /opt/etc/crontab ] && grep -q "/opt/etc/netbird/check_tunnel.sh" /opt/etc/crontab; then
    sed -i '\#netbird/check_tunnel.sh#d' /opt/etc/crontab
fi
mkdir -p /opt/etc
echo "$CRON_JOB" >> /opt/etc/crontab

# Перезапуск cron службы
if [ -f /opt/etc/init.d/S10cron ]; then
    /opt/etc/init.d/S10cron restart
fi
echo "Проверка доступности туннеля ($TARGET_IP) активирована через cron."
echo ""

# Интерактивная часть для авторизации в сети
printf "Хотите выполнить привязку к серверу прямо сейчас? [y/n]: "
read run_auth

case "$run_auth" in
    [Yy]*)
        printf "Введите Management URL [По умолчанию: https://netbird.um-ural.ru]: "
        read user_url
        if [ -z "$user_url" ]; then
            user_url="https://netbird.um-ural.ru"
        fi
        
        printf "Введите ваш Setup Key: "
        read user_key
        if [ -z "$user_key" ]; then
            echo "Ключ пустой. Авторизация пропущена."
            echo "Вы можете выполнить подключение позже вручную."
        else
            echo "Выполняется подключение к mesh-сети..."
            netbird up --management-url "$user_url" --setup-key "$user_key"
        fi
        ;;
    *)
        echo "Вы отказались от немедленной авторизации."
        echo "Для завершения настройки выполните команду вручную в любое время:"
        echo "netbird up --management-url https://netbird.um-ural.ru --setup-key ВАШ_КЛЮЧ"
        ;;
esac

echo ""
echo "Настройка полностью завершена! Проверьте статус через: netbird status"
