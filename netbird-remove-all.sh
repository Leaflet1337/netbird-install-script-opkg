#!/bin/sh
# ==========================================================
# Полная очистка NetBird с Keenetic
# ==========================================================

echo "======================================================="
echo "  ПОЛНАЯ ОЧИСТКА NetBird"
echo "======================================================="
echo ""

echo "[1/10] Остановка сервисов..."
/opt/etc/init.d/S99netbird stop 2>/dev/null || true
/opt/etc/init.d/S80lighttpd stop 2>/dev/null || true

echo "[2/10] Удаление пакетов..."
opkg remove netbird lighttpd lighttpd-mod-cgi lighttpd-mod-fastcgi iptables cron 2>/dev/null || true

echo "[3/10] Удаление конфигураций..."
rm -rf /opt/etc/netbird
rm -rf /opt/var/lib/netbird
rm -rf /opt/var/log/netbird
rm -rf /opt/var/log/lighttpd
rm -rf /opt/www/netbird
rm -rf /opt/etc/lighttpd
rm -rf /opt/backups/netbird

echo "[4/10] Удаление init-скриптов..."
rm -f /opt/etc/init.d/S99netbird
rm -f /opt/etc/init.d/S80lighttpd

echo "[5/10] Удаление хука фаервола..."
rm -f /opt/etc/ndm/netfilter.d/netbird.sh

echo "[6/10] Восстановление iptables..."
if [ -f /opt/sbin/iptables.real ]; then
    mv /opt/sbin/iptables.real /opt/sbin/iptables
    echo "  ✓ iptables восстановлен"
fi

echo "[7/10] Удаление симлинков..."
rm -f /opt/bin/netbird
rm -f /usr/bin/netbird 2>/dev/null || true

echo "[8/10] Очистка crontab..."
if [ -f /opt/etc/crontab ]; then
    sed -i '\#netbird#d' /opt/etc/crontab
fi

echo "[9/10] Удаление временных файлов..."
rm -f /tmp/netbird_*
rm -f /tmp/nb.sh

echo "[10/10] Убийство процессов..."
killall netbird 2>/dev/null || true
killall lighttpd 2>/dev/null || true

echo ""
echo "======================================================="
echo "  ✅ ПОЛНАЯ ОЧИСТКА ЗАВЕРШЕНА!"
echo "======================================================="
echo ""
echo "Проверьте:"
echo "  opkg list-installed | grep -E 'netbird|lighttpd'"
echo "  ps aux | grep -E 'netbird|lighttpd' | grep -v grep"
