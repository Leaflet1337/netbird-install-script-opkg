#!/bin/sh
# Автоматический скрипт развертывания NetBird для Keenetic (Entware)
# Скрипт полностью автономен, использует Base64 для обхода проблем с синтаксисом кавычек в sh

set -e

echo ""
echo "======================================================="
echo "  Автоматическая установка NetBird на Keenetic (Entware)"
echo "======================================================="
echo ""

# Шаг 1. Очистка старых сессий
echo "[1/7] Проверка и очистка старых конфигураций..."
killall -9 netbird 2>/dev/null || true
rm -rf /opt/var/lib/netbird/*
rm -rf /opt/etc/netbird/*

# Шаг 2. Установка пакетов
echo "[2/7] Обновление репозиториев и установка iptables, netbird..."
opkg update
opkg install iptables netbird

# Шаг 3. Создание умного эмулятора iptables
echo "[3/7] Конфигурация эмулятора iptables (обход конфликтов ядра)..."
if [ ! -f /opt/sbin/iptables.real ]; then
    if [ -f /opt/sbin/iptables ]; then
        mv /opt/sbin/iptables /opt/sbin/iptables.real
    else
        echo "Критическая ошибка: оригинальный бинарник /opt/sbin/iptables не найден!"
        exit 1
    fi
fi

# Декодируем эмулятор iptables из Base64 (защита от краша кавычек)
echo "IyEvYmluL3NoCiMgVW1uYXlhIHphZ2x1c2hrYS1lbXVsYXRvciBpcHRhYmxlcyBkbHlhIHByZWRvdHZyYXNoY2hlbml5YSBrcmFzaGEgZGVtb25hIE5ldEJpcmQKY2FzZSAiJCoiIGluCiAgICAqIi1MIip8KiItUyIqKQogICAgICAgIGVjaG8gIkNoYWluIElOUFVUIChwb2xpY3kgQUNDRVBUKSIKICAgICAgICBlY2hvICJDaGFpbiBGT1JXQVJEIChwb2xpY3kgQUNDRVBUKSIKICAgICAgICBlY2hvICJDaGFpbiBPVVRQVVQgKHBvbGljeSBBQ0NFUFQpIgogICAgICAgIGV4aXQgMAogICAgICAgIDs7CiAgICAqIi12IiopCiAgICAgICAgZWNobyAiaXB0YWJsZXMgdjEuNC4yMSIKICAgICAgICBleGl0IDAKICAgICAgICA7OwogICAgKiItTiIqfCoiLUYiKnwqIi1YIip8KiItQSIqfCoiLUkiKikKICAgICAgICBleGl0IDAKICAgICAgICA7Owplc2FjCi9vcHQvc2JpLmlwdGFibGVzLnJlYWwgIiRAIgo=" | base64 -d > /opt/sbin/iptables
chmod +x /opt/sbin/iptables

# Шаг 4. Создание базового config.json
echo "[4/7] Генерация эталонного файла конфигурации config.json..."
mkdir -p /opt/etc/netbird
echo "ewogICJXZ0lmYWNlIjogInd0MCIsCiAgIldnUG9ydCI6IDUxODI1LAogICJEaXNhYmxlRmlyZXdhbGwiOiB0cnVlLAogICJJRmFjZURpc2NvdmVyIjogZmFsc2UKfQo=" | base64 -d > /opt/etc/netbird/config.json

# Шаг 5. Создание демона автозапуска
echo "[5/7] Установка скрипта инициализации демона S99netbird..."
echo "IyEvYmluL3NoCkVOQUJMRUQ9eWVzClBST0c9L29wdC9zYmluL25ldGJpcmQKQVJHUz0ic2VydmljZSBydW4gLS1sb2ctZmlsZSAvb3B0L3Zhci9sb2cvbmV0YmlyZC5sb2cgLS1sb2ctbGV2ZWwgaW5mbyAtLWRhZW1vbi1hZGRyIHVuaXg6Ly8vb3B0L3Zhci9ydW4vbmV0YmlyZC5zb2NrIgoKY2FzZSAiJDEiIGluCiAgICBzdGFydCkKICAgICAgICBpZiBbICIkRU5BQkxFRCIgPSAieWVzIiBdOyB0aGVuCiAgICAgICAgICAgIG1rZGlyIC1wIC9vcHQvdmFyL3J1bgogICAgICAgICAgICBleHBvcnQgTkJfRElTQUJMRV9GSVJFV0FMTD10cnVlCiAgICAgICAgICAgICRQUk9HICRBUkdTIColorogICAgICAgIGZpCiAgICAgICAgOzsKICAgIHN0b3ApCiAgICAgICkga2lsbGFsbCAtOSBuZXRiaXJkIDI+L2Rldi9udWxsCiAgICAgICAgOzsKICAgIHJlc3RhcnQpCiAgICAgICAgJDAgc3RvcAogICAgICAgIHNsZWVwIDIKICAgICAgICAkMCBzdGFydAogICAgICAgIDs7CiAgICAqKQogICAgICAgIGVjaG8gIlVzYWdlOiAkMCB7c3RhcnR8c3RvcHxyZXN0YXJ0fSIKICAgICAgICBleGl0IDEKICAgICAgICA7Owplc2FjCg==" | base64 -d > /opt/etc/init.d/S99netbird
chmod +x /opt/etc/init.d/S99netbird

# Шаг 6. Настройка хука NDM netfilter.d с защитой от зацикливания
echo "[6/7] Создание хука маршрутизации Keenetic с Lock-защитой..."
mkdir -p /opt/etc/ndm/netfilter.d
echo "IyEvYmluL3NoCiMgWmFzaGNoaXRueXkgTG9jay1mYWlsIG90IHJla3Vyc2l2bm9nbyB2eXpvdmEgc29ieXRpeSBmYWVydm9sYSBORE0gS2VlbmV0aWMKTE9DS0ZJTEU9L3RtcC9uZXRiaXJkX25ldGZpbHRlci5sb2NrCmlmIFsgLWYgIiRMT0NLRklMRSIgXTsgdGhlbgogICAgZXhpdCAwCmZpCnRvdWNoICIkTE9DS0ZJTEUiCgpJUFQ9Ii9vcHQvc2JpLmlwdGFibGVzLnJlYWwgaXB0YWJsZXMiCk5FVEJJUkRfTkVUPSIxMDAuNjQuMC4wLzEwIgoKY2FzZSAiJHRhYmxlIiBpbgogIGZpbHRlcikKICAgICRJUFQgLUMgSU5QVVQgLWkgd3QwIC1qIEFDQ0VQVCAyPi9kZXYvbnVsbCB8fCAkSVBUIC1JIElOUFVUIDEgLWkgd3QwIC1qIEFDQ0VQVAogICAgJElQVCAtQyBGT1JXQVJEIC1pIHd0MCAtbyBicjAgLWogQUNDRVBUIDI+L2Rldi9udWxsIHx8ICRJUFQgLUkgRk9SV0FSRCAxIC1pIHd0MCAtbyBicjAgLWogQUNDRVBUCiAgICAkSVBUIC1DIEZPUldBUkQgLW0gc3RhdGUgLS1zdGF0ZSBSRUxBVEVELEVTVEFCTElTSEVEIC1qIENDQ0VQVCAyPi9kZXYvbnVsbCB8fCAkSVBUIC1JI0ZPUldBUkQgMSAtbSBzdGF0ZSAtLXN0YXRlIFJFTEFURUQsRVNUQUJMSVNIRUQgLWogQUNDRVBUCiAgICA7OwogIG5hdCkKICAgIC9vcHQvc2JpLmlwdGFibGVzLnJlYWwgaXB0YWJsZXMgLXQgbmF0IC1DIFBPU1RST1VUSU5HIC1zICRORVRCSVJEX05FVCAtbyBicjAgLWogTUFTUVVFUkFERSAyPi9kZXYvbnVsbCB8fCBcCiAgICAgIC9vcHQvc2JpLmlwdGFibGVzLnJlYWwgaXB0YWJsZXMgLXQgbmF0IC1JIFBPU1RST1VUSU5HIDEgLXMgJE5FVEJJUkRfTkVUIC1vIGJyMCAtaiBNQVNRVUVSQURFCiAgICA7Owplc2FjCgojIE90cGx5dWNoYWVtIHJwX2ZpbHRlciBkbHlhIHZraG9keWFzaGNoZWdvIHRyYWZpa2EgbWVzaC1zZXRpCmZvciBmIGluIC9wcm9jL3N5cy9uZXQvaXB2NC9jb25mLyovcnBfZmlsdGVyOyBkbyBlY2hvIDAgPiAiJGYiOyBkb25lCgpybSAtZiAiJExPQ0tGSUxFIgpleGl0IDAK" | base64 -d > /opt/etc/ndm/netfilter.d/netbird.sh
chmod +x /opt/etc/ndm/netfilter.d/netbird.sh

# Шаг 7. Запуск служб и применение правил в реальном времени
echo "[7/7] Включение форвардинга пакетов и запуск демона..."
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

# Интерактивная часть для авторизации
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
            echo "Ключ пустой. Настройка прервана."
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