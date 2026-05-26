# Скрипт автоматической установки NetBird c поддержкой маршрутизации

Скрипт предназначен для быстрой настройки и развертывания клиента NetBird. Автоматически включает форвардинг пакетов на уровне ядра и применяет правила сетевого экрана (firewall).

## Быстрая установка одной командой

Для запуска процесса установки и автоматической настройки выполните следующую команду в терминале вашего устройства:

```
curl -sSL https://raw.githubusercontent.com/Leaflet1337/netbird-install-script-opkg/main/netbird-install-script-opkg.sh | tr -d '\r' > /tmp/nb.sh && sh /tmp/nb.sh && rm -f /tmp/nb.sh
```

## Эта техническая инструкция предназначена для ручного развертывания клиента NetBird на роутерах Keenetic (архитектура MIPS/MIPSLE/AARCH64, среда Entware).

В ней учтены все архитектурные конфликты KeeneticOS с фаерволом NetBird, особенности асимметричной маршрутизации (`rp_filter`), защита от зацикливания NDM и специфика синтаксиса встроенного пакета `xtables-multi` в Entware.

### Предварительные требования (Prerequisites)

Перед началом настройки на роутере должны быть выполнены следующие действия:

1. Установлена и настроена среда **Entware** (на USB-флешку или во внутреннюю память роутера).
2. В конфигах подразумевается стандартная сеть Netbird 100.64.0.0/10
3. В веб-интерфейсе Кинетика включен компонент **«WireGuard VPN»** (необходим для инициализации модуля `tun` в ядре).
> **Справочник архитектур для подбора бинарника NetBird:**
> 
> - **Архитектура `mipsel`** (использовать архив `mipsel-installer.tar.gz`):
>     
>     Keenetic 4G (KN-1212), Omni (KN-1410), Extra (KN-1710/1711/1713), Giga (KN-1010/1011), Ultra (KN-1810), Viva (KN-1910/1912/1913), Giant (KN-2610), Hero 4G (KN-2310/2311), Hopper (KN-3810). А также старые Zyxel Keenetic II / III, Extra / Extra II, Giga II / III, Omni / Omni II, Viva, Ultra / Ultra II.
>     
> - **Архитектура `mips`** (использовать архив `mips-installer.tar.gz`):
>     
>     Keenetic Ultra SE (KN-2510), Giga SE (KN-2410), DSL (KN-2010), Skipper DSL (KN-2112), Duo (KN-2110), Hopper DSL (KN-3610). А также Zyxel Keenetic DSL, LTE, VOX.
>     
> - **Архитектура `aarch64`** (использовать архив `aarch64-installer.tar.gz`):
>     
>     Keenetic Peak (KN-2710), Ultra (KN-1811), Ultra (NC-1812), Giga (KN-1012), Hopper (KN-3811), Hopper SE (KN-3812).

## Пошаговая инструкция по настройке

Все команды выполняются через SSH-сессию под пользователем `root`. Файлы создаются через конструкцию `cat << 'EOF'`, что позволяет копировать блоки кода в консоль целиком.

### Шаг 1. Полная зачистка старых состояний

Если на роутере ранее предпринимались попытки запуска NetBird, принудительно завершаем процессы и полностью очищаем кэш базы данных, который может содержать неверные параметры фаервола.


```
killall -9 netbird 2>/dev/null
rm -rf /opt/var/lib/netbird/*
rm -rf /opt/etc/netbird/*
# Если клиент не установлен - устанавливаем
opkg update && opkg install netbird
```

### Шаг 2. Установка iptables и создание «умного эмулятора»

**Проблема:** NetBird жестко заставляет ядро создавать свои цепочки правил. KeeneticOS блокирует это на уровне ядра, из-за чего демон падает, крашит сокет управления или уходит в `Segmentation fault`.
**Решение:** Мы устанавливаем системный `iptables` из Entware, переименовываем его в `iptables.real`, а на его место кладем скрипт-эмулятор. Он будет имитировать для NetBird «успех» (код `0`) на любые команды модификации сети, а на запросы проверки статуса — отдавать корректную структуру текста.

Выполните следующий блок команд целиком:


```
# 1. Обновляем репозиторий и устанавливаем пакет iptables
opkg update && opkg install iptables

# 2. Переименовываем реальный бинарник iptables в iptables.real
[ ! -f /opt/sbin/iptables.real ] && mv /opt/sbin/iptables /opt/sbin/iptables.real

# 3. Создаем эмулятор-заглубку для NetBird
cat << 'EOF' > /opt/sbin/iptables
#!/bin/sh
# Эмулятор iptables для корректной работы NetBird CLI и Daemon в KeeneticOS

case "$*" in
    *"-L"*|*"-S"*)
        # Имитируем структуру правил для утилиты статуса NetBird CLI
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
        # На все запросы создания/удаления цепочек симулируем успех
        exit 0
        ;;
esac

# Все остальные системные вызовы прозрачно пробрасываем в реальный бинарник
/opt/sbin/iptables.real "$@"
EOF

# 4. Назначаем права на исполнение
chmod +x /opt/sbin/iptables
```

### Шаг 3. Создание конфигурационного файла NetBird

Данная сборка ищет конфигурацию строго по пути `/opt/etc/netbird/config.json`. Прописываем туда приватный сервер управления и принудительно выставляем флаг отключения встроенного фаервола.


```
mkdir -p /opt/etc/netbird

cat << 'EOF' > /opt/etc/netbird/config.json
{
  "ManagementURL": {
    "Scheme": "https",
    "Host": "ваш.домен.ru:443"
  },
  "AdminURL": {
    "Scheme": "https",
    "Host": "app.netbird.io:443"
  },
  "WgIface": "wt0",
  "WgPort": 51825,
  "DisableFirewall": true,
  "IFaceDiscover": false
}
EOF
```

### Шаг 4. Настройка скрипта автозапуска сервиса

Редактируем системный скрипт инициализации Entware `/opt/etc/init.d/S99netbird`. Нам необходимо внедрить переменную окружения `NB_DISABLE_FIREWALL=true` прямо перед стартом бинарника. Это гарантирует отключение Firewall Manager на уровне Go-кода приложения.


```
cat << 'EOF' > /opt/etc/init.d/S99netbird
#!/bin/sh

ENABLED=yes
PROG=/opt/sbin/netbird
ARGS="service run --log-file /opt/var/log/netbird.log --log-level info --daemon-addr unix:///opt/var/run/netbird.sock"

case "$1" in
    start)
        if [ "$ENABLED" = "yes" ]; then
            mkdir -p /opt/var/run

            # Принудительное отключение управления фаерволом в памяти демона
            export NB_DISABLE_FIREWALL=true

            $PROG $ARGS &
        fi
        ;;
    stop)
        killall netbird 2>/dev/null
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
```

### Шаг 5. Настройка маршрутизации Keenetic (netfilter.d) c защитой от петли

**Проблема:** Так как NetBird больше не трогает фаервол роутера, пакеты до интерфейса `wt0` долетают, но ядро KeeneticOS их дропает из-за механизма защиты `rp_filter` (Reverse Path Filtering) и отсутствия разрешающих правил в реальном `iptables`. Более того, вызов `iptables` во время обработки сетевых событий вызывает рекурсию NDM и вешает CPU роутера на 100%.

**Решение:** Создаем хук-скрипт с защитой через `LOCKFILE`, который будет автоматически и безопасно отрабатывать при перезагрузках роутера и изменениях интерфейсов.


```
mkdir -p /opt/etc/ndm/netfilter.d

cat << 'EOF' > /opt/etc/ndm/netfilter.d/netbird.sh
#!/bin/sh

# Защита от рекурсивного зацикливания событий NDM Межсетевого экрана
LOCKFILE=/tmp/netbird_netfilter.lock
if [ -f "$LOCKFILE" ]; then
    exit 0
fi
touch "$LOCKFILE"

# Учитываем специфику синтаксиса xtables-multi в Entware (требуется субкоманда iptables)
IPT="/opt/sbin/iptables.real iptables"
NETBIRD_NET="100.64.0.0/10"

case "$table" in
  filter)
    # Разрешаем входящий трафик на сам роутер через интерфейс NetBird
    $IPT -C INPUT -i wt0 -j ACCEPT 2>/dev/null || \
      $IPT -I INPUT 1 -i wt0 -j ACCEPT

    # Разрешаем транзит (FORWARD) из NetBird в локальную сеть роутера (br0)
    $IPT -C FORWARD -i wt0 -o br0 -j ACCEPT 2>/dev/null || \
      $IPT -I FORWARD 1 -i wt0 -o br0 -j ACCEPT

    # Разрешаем прохождение установленных и связанных сессий
    $IPT -C FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
      $IPT -I FORWARD 1 -m state --state RELATED,ESTABLISHED -j ACCEPT
    ;;

  nat)
    # Включаем маскарадинг, чтобы устройства локальной сети знали, куда отвечать
    /opt/sbin/iptables.real iptables -t nat -C POSTROUTING -s $NETBIRD_NET -o br0 -j MASQUERADE 2>/dev/null || \
      /opt/sbin/iptables.real iptables -t nat -I POSTROUTING 1 -s $NETBIRD_NET -o br0 -j MASQUERADE
    ;;
esac

# КРИТИЧЕСКИ ВАЖНО: Отключаем rp_filter, блокирующий входящие пакеты wt0
for f in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > "$f"; done

# Снимаем блокировку
rm -f "$LOCKFILE"

exit 0
EOF

chmod +x /opt/etc/ndm/netfilter.d/netbird.sh
```

### Шаг 6. Первый запуск и авторизация

Устанавливаем зависимости ядра, применяем правила фаервола в реальном времени и запускаем службу демона.



```
# 1. Включаем форвардинг пакетов на уровне ядра роутера
sysctl -w net.ipv4.ip_forward=1

# 2. Безопасно применяем созданные правила прямо сейчас через скрипт
table=filter /opt/etc/ndm/netfilter.d/netbird.sh
table=nat /opt/etc/ndm/netfilter.d/netbird.sh

# 3. Устанавливаем и запускаем службу NetBird
opkg install netbird
/opt/etc/init.d/S99netbird start
```

Подождите 10 секунд для инициализации gRPC-сокета службой и выполните команду подключения роутера к вашей сети NetBird:



```
netbird up --setup-key ВАШ_КЛЮЧ_ИЗ_ПАНЕЛИ_NETBIRD
```

## Проверка успешности установки

Необходимо выполнить проверку двух статусов:

1. **Статус интерфейса в ОС:**
    
    ```
    ip addr show wt0
    ```
    
    *Ожидаемый результат:* Наличие интерфейса `wt0`, флаги `<POINTOPOINT,NOARP,UP,LOWER_UP>`, состояние `UP`, и присвоенный IP-адрес из диапазона `100.x.x.x/10`.
    
2. **Статус подключения клиента к сети:**
    
    ```
    netbird status
    ```
    
    *Ожидаемый результат:* Чистый вывод утилиты. Строки `Management: Connected` и `Signal: Connected`. Количество подключенных пиров (`Peers count`) должно быть больше 0.
    

## Настройка в Веб-интерфейсе Keenetic (Финальный штрих)

Чтобы встроенный Межсетевой экран KeeneticOS на верхнем уровне NDM не препятствовал прохождению трафика из туннеля в локальные сегменты:

1. Откройте Web-интерфейс роутера -> **Сетевые правила** -> **Межсетевой экран**.
2. Вкладка **Правила для сегментов** -> Выберите сегмент **«Домашняя сеть»** (или тот сегмент, куда настраивается доступ).
3. Нажмите **Добавить правило**:
    - *Действие:* Разрешить
    - *Источник:* Любой (или подсеть `100.64.0.0` маска `255.192.0.0`)
    - *Назначение:* Любое
    - *Протокол:* Любой (IP)
4. Нажмите **Сохранить**. Настройка завершена.

## Проблема с отключением 

Демон NetBird написан на языке Go, который очень требователен к оперативной памяти. В моменты пиковой нагрузки, смены маршрутов или при интенсивном обмене трафиком встроенный в ядро Keenetic механизм защиты OOM Killer (Out of Memory) или краш самого процесса могут тихо завершить службу.

Поскольку в среде Entware нет полноценного systemd, который мог бы автоматически поднимать упавшие процессы с помощью директивы Restart=always, нам нужно реализовать этот функционал доступными средствами.

Есть два лучших способа решить эту проблему. Вы можете выбрать один из них или применить оба сразу для максимальной отказоустойчивости.

**Способ 1.**
Апгрейд скрипта автозапуска S99netbird 
Мы можем изменить логику самого стартового скрипта /opt/etc/init.d/S99netbird, запустив внутри него бесконечный цикл-страж (watchdog). Если бинарник NetBird завершит работу с любой ошибкой или упадет, цикл мгновенно запустит его снова.

Для этого выполните на роутере команду, которая перезапишет внутренности службы автозапуска на отказоустойчивую версию:

```
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
                    # Проверяем, запущен ли уже демон
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
        # Сначала убиваем фоновый цикл-страж, чтобы он не воскресил процесс
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
```

Теперь при вызове команды start скрипт запускает невидимый фоновый процесс, который каждые 3 секунды проверяет наличие NetBird в памяти роутера через pidof. Если процесс исчез — он запускает его заново, а факт падения фиксирует в лог /opt/var/log/netbird_watchdog.log.

Примените изменения, перезапустив службу:

```
/opt/etc/init.d/S99netbird restart
```

**Способ 2.**
Проверка доступности сети через Cron (Каждые 5 минут)
Иногда бывает так, что сам демон "висит" в памяти, но сокет заклинило, или Wireguard-сессия внутри него зависла, из-за чего пиры отключаются, хотя процесс формально жив.

Для отлавливания таких ситуаций идеально подходит системный планировщик cron, встроенный в Entware. Мы напишем скрипт, который будет пинговать, например, IP-адрес самого Management-сервера внутри вашей сети NetBird (или любой другой железно доступный пир в вашей mesh-сети). Если пинга нет — скрипт жестко перезапускает службу.

Установите cron, если он еще не установлен (в базовом Entware он обычно есть):

```
opkg install cron
```

Создайте скрипт проверки:

```
cat << 'EOF' > /opt/etc/netbird/check_tunnel.sh
#!/bin/sh

# Укажите IP-адрес из вашей сети NetBird, который ДОЛЖЕН всегда пинговаться
# Например, IP вашего управляющего сервера или соседнего всегда включенного пира
TARGET_IP="100.64.0.1" 

# Делаем 3 попытки пинга с тайм-аутом в 2 секунды
if ! ping -c 3 -W 2 $TARGET_IP > /dev/null 2>&1; then
    echo "$(date): Tunnel to $TARGET_IP is down! Restarting NetBird..." >> /opt/var/log/netbird_cron.log
    /opt/etc/init.d/S99netbird restart
fi
EOF
chmod +x /opt/etc/netbird/check_tunnel.sh
```
(Обязательно откройте этот файл или отредактируйте переменную TARGET_IP="100.64.0.1", указав туда реальный IP-адрес из вашей подсети NetBird, по которому можно судить, работает связь или нет).

Добавьте задачу в планировщик cron. Откройте файл заданий:

```
echo "*/5 * * * * /opt/etc/netbird/check_tunnel.sh" >> /opt/etc/crontab
```
Перезапустите службу cron, чтобы она подхватила задание:

```
/opt/etc/init.d/S10cron restart
```
теперь каждые 5 минут роутер будет проверять, идет ли трафик через туннель NetBird. Если связь пропала (из-за падения демона, сбоя интерфейса wt0 или блокировки сокета) — скрипт сам выполнит чистый /opt/etc/init.d/S99netbird restart, поднимет интерфейсы и восстановит mesh-сеть без вашего участия.
