# Скрипт автоматической установки NetBird c поддержкой маршрутизации

Скрипт предназначен для быстрой настройки и развертывания клиента NetBird. Автоматически включает форвардинг пакетов на уровне ядра и применяет правила сетевого экрана (firewall).

## Быстрая установка одной командой

Для запуска процесса установки и автоматической настройки выполните следующую команду в терминале вашего устройства:

```bash
curl -sSL https://raw.githubusercontent.com/Leaflet1337/netbird-install-script-opkg/main/netbird-install-script-opkg.sh | tr -d '\r' > /tmp/nb.sh && sh /tmp/nb.sh && rm -f /tmp/nb.sh
```

Эта техническая инструкция предназначена для ручного развертывания клиента NetBird на роутерах Keenetic (архитектура MIPS/MIPSLE/AARCH64, среда Entware).

В ней учтены все архитектурные конфликты KeeneticOS с фаерволом NetBird, особенности асимметричной маршрутизации (`rp_filter`), защита от зацикливания NDM и специфика синтаксиса встроенного пакета `xtables-multi` в Entware.

### Предварительные требования (Prerequisites)

Перед началом настройки на роутере должны быть выполнены следующие действия:

1. Установлена и настроена среда **Entware** (на USB-флешку или во внутреннюю память роутера).
2. В веб-интерфейсе Кинетика включен компонент **«WireGuard VPN»** (необходим для инициализации модуля `tun` в ядре).
> <summary>**Справочник архитектур для подбора бинарника NetBird:**</summary>
> </details>
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
>     </details>

## Пошаговая инструкция по настройке

Все команды выполняются через SSH-сессию под пользователем `root`. Файлы создаются через конструкцию `cat << 'EOF'`, что позволяет копировать блоки кода в консоль целиком.

### Шаг 1. Полная зачистка старых состояний

Если на роутере ранее предпринимались попытки запуска NetBird, принудительно завершаем процессы и полностью очищаем кэш базы данных, который может содержать неверные параметры фаервола.

Bash

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
Bash

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

Bash

```
mkdir -p /opt/etc/netbird

cat << 'EOF' > /opt/etc/netbird/config.json
{
  "ManagementURL": {
    "Scheme": "https",
    "Host": "netbird.um-ural.ru:443"
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

Bash

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

Bash

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

Bash

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

Bash

```
netbird up --setup-key ВАШ_КЛЮЧ_ИЗ_ПАНЕЛИ_NETBIRD
```

## Проверка успешности установки

Администратор должен выполнить проверку двух статусов:

1. **Статус интерфейса в ОС:**Bash
    
    ```
    ip addr show wt0
    ```
    
    *Ожидаемый результат:* Наличие интерфейса `wt0`, флаги `<POINTOPOINT,NOARP,UP,LOWER_UP>`, состояние `UP`, и присвоенный IP-адрес из диапазона `100.x.x.x`.
    
2. **Статус подключения клиента к сети:**Bash
    
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

В ней учтены все архитектурные конфликты KeeneticOS с фаерволом NetBird, особенности асимметричной маршрутизации (`rp_filter`) и специфика синтаксиса встроенного пакета `xtables-multi` в Entware.

## Предварительные требования (Prerequisites)

Перед началом настройки на роутере должны быть выполнены следующие действия:

1. Установлена и настроена среда **Entware** (на USB-флешку или внутреннюю память).
2. В веб-интерфейсе Кинетика включен компонент **«WireGuard VPN»** (он необходим, чтобы в ядре появился модуль `tun`).
3. Пакет `netbird` установлен через менеджер пакетов: `opkg update && opkg install netbird`.

**Note**

Для моделей Keenetic/Netcraze: 4G (KN-1212), Omni (KN-1410), Extra (KN-1710/1711/1713), Giga (KN-1010/1011), Ultra (KN-1810), Viva (KN-1910/1912/1913), Giant (KN-2610), Hero 4G (KN-2310/2311), Hopper (KN-3810) и Zyxel Keenetic II / III, Extra, Extra II, Giga II / III, Omni, Omni II, Viva, Ultra, Ultra II используйте для установки архив **mipsel** — [mipsel-installer.tar.gz](https://bin.entware.net/mipselsf-k3.4/installer/mipsel-installer.tar.gz)

Для моделей Keenetic/Netcraze: Ultra SE (KN-2510), Giga SE (KN-2410), DSL (KN-2010), Skipper DSL (KN-2112), Duo (KN-2110), Ultra SE (KN-2510), Hopper DSL (KN-3610) и Zyxel Keenetic DSL, LTE, VOX используйте для установки архив **mips** — [mips-installer.tar.gz](https://bin.entware.net/mipssf-k3.4/installer/mips-installer.tar.gz)

Для моделей Keenetic/Netcraze: Peak (KN-2710), Ultra (KN-1811), Ultra (NC-1812), Giga (KN-1012), Hopper (KN-3811) и Hopper SE (KN-3812) используйте архив **aarch64** — [aarch64-installer.tar.gz](https://bin.entware.net/aarch64-k3.10/installer/aarch64-installer.tar.gz)

## Пошаговая инструкция по настройке

Все команды выполняются через SSH-сессию под пользователем `root`. Для удобства файлы создаются через конструкцию `cat << 'EOF'`, что позволяет просто копировать блоки кода целиком.

### Шаг 1. Полная зачистка старых состояний

Если на роутере уже пытались запустить NetBird, необходимо принудительно завершить процессы и очистить кэш базы данных, который может содержать неверные настройки фаервола.

```
killall -9 netbird 2>/dev/null
rm -rf /opt/var/lib/netbird/*
rm -rf /opt/etc/netbird/*
```

### Шаг 2. Создание «умного эмулятора» iptables

Устанавливаем IPtables и сразу выполняем команды

```
opkg install iptables
/opt/sbin/iptables.real iptables -I INPUT 1 -i wt0 -j ACCEPT
/opt/sbin/iptables.real iptables -I FORWARD 1 -i wt0 -o br0 -j ACCEPT
/opt/sbin/iptables.real iptables -I FORWARD 1 -m state --state RELATED,ESTABLISHED -j ACCEPT
/opt/sbin/iptables.real iptables -t nat -I POSTROUTING 1 -s 100.64.0.0/10 -o br0 -j MASQUERADE
```

**Проблема:** NetBird жестко заставляет ядро создавать свои цепочки правил. KeeneticOS блокирует это, из-за чего демон падает или ломается gRPC-сокет управления.

**Решение:** Мы переименуем реальный `iptables` в `iptables.real`, а на его место положим скрипт-эмулятор. Он будет имитировать для NetBird «успех» на любые команды модификации сети, а на запросы проверки статуса отдавать корректную структуру текста.

Выполните следующий блок команд:

Bash

# 

```
# 1. Переименовываем реальный iptables (если это не было сделано ранее)
[ ! -f /opt/sbin/iptables.real ] && mv /opt/sbin/iptables /opt/sbin/iptables.real

# 2. Создаем эмулятор-заглушку
cat << 'EOF' > /opt/sbin/iptables
#!/bin/sh
# Эмулятор iptables для корректной работы NetBird CLI и Daemon в KeeneticOS

case "$*" in
    *"-L"*|*"-S"*)
        # Ответ для утилиты статуса NetBird, чтобы она не паниковала
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

# Все остальные системные вызовы пробрасываем в реальный бинарник
/opt/sbin/iptables.real "$@"
EOF

# 3. Назначаем права на исполнение
chmod +x /opt/sbin/iptables
```

### Шаг 3. Создание конфигурационного файла NetBird

Данная сборка Entware ищет конфигурацию строго по пути `/opt/etc/netbird/config.json`. Мы прописываем туда ваш приватный сервер управления и принудительно выставляем флаг отключения встроенного фаервола.

Bash

# 

```
mkdir -p /opt/etc/netbird

cat << 'EOF' > /opt/etc/netbird/config.json
{
  "ManagementURL": {
    "Scheme": "https",
    "Host": "netbird.um-ural.ru:443"
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

Редактируем системный скрипт инициализации Entware `/opt/etc/init.d/S99netbird`. Нам необходимо внедрить переменную окружения `NB_DISABLE_FIREWALL=true` прямо перед стартом бинарника. Это гарантирует отключение Firewall Manager на уровне кода Go.

Bash

# 

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

### Шаг 5. Настройка маршрутизации и безопасности Keenetic (`netfilter.d`)

**Проблема:** Так как Netbird больше не трогает фаервол роутера, пакеты до интерфейса `wt0` долетают, но ядро KeeneticOS их дропает из-за механизма защиты `rp_filter` (Reverse Path Filtering) и отсутствия разрешающих правил.

**Важно:** Утилита `iptables.real` в Entware является оберткой `xtables-multi`, поэтому она требует обязательного указания субкоманды `iptables` в аргументах.

Создаем хук-скрипт, который будет автоматически отрабатывать при любых изменениях сетевых интерфейсов Кинетика:

Bash

# 

```
mkdir -p /opt/etc/ndm/netfilter.d

cat << 'EOF' > /opt/etc/ndm/netfilter.d/netbird.sh
#!/bin/sh

# Учитываем специфику синтаксиса xtables-multi в Entware
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

exit 0
EOF

chmod +x /opt/etc/ndm/netfilter.d/netbird.sh
```

## Шаг 6. Первый запуск и авторизация

После того как все файлы созданы, выполняем запуск всей цепочки правил и службы:

Bash

# 

```
# 1. Включаем форвардинг пакетов на уровне ядра роутера
sysctl -w net.ipv4.ip_forward=1

# 2. Принудительно применяем правила фаервола прямо сейчас
table=filter /opt/etc/ndm/netfilter.d/netbird.sh
table=nat /opt/etc/ndm/netfilter.d/netbird.sh

# 3. Запускаем службу NetBird
/opt/etc/init.d/S99netbird start
```

Подождите 5–10 секунд для инициализации сокета и выполните команду подключения, подставив ваш токен:

Bash

# 

```
netbird up --setup-key ВАШ_КЛЮЧ_ИЗ_ПАНЕЛИ_NETBIRD
```

## Проверка успешности установки

Для контроля корректности работы администратор должен проверить два статуса:

1. **Статус интерфейса в ОС:**Bash
    
    # 
    
    ```
    ip addr show wt0
    ```
    
    *Ожидаемый результат:* Флаги `<POINTOPOINT,NOARP,UP,LOWER_UP>`, интерфейс в состоянии `UP`, присвоен IP-адрес из диапазона `100.x.x.x`.
    
2. **Статус подключения клиента:**Bash
    
    # 
    
    ```
    netbird status
    ```
    
    *Ожидаемый результат:* Стабильный вывод без ошибок. Строки `Management: Connected` и `Signal: Connected`. Количество подключенных пиров (`Peers count`) должно быть больше нуля (в зависимости от настроек ваших ACL-политик в панели NetBird).
    

## Настройка в Веб-интерфейсе Keenetic (Финальный штрих)

Чтобы Межсетевой экран самого Кинетика на верхнем уровне NDM не препятствовал прохождению трафика внутри домашних сегментов:

1. Откройте Web-интерфейс роутера -> **Сетевые правила** -> **Межсетевой экран**.
2. Вкладка **Правила для сегментов** -> Выберите **«Домашняя сеть»** (или тот сегмент, куда админы хотят получить доступ).
3. Нажмите **Добавить правило**:
    - *Действие:* Разрешить
    - *Источник:* Любой (или подсеть `100.64.0.0` маска `255.192.0.0`)
    - *Назначение:* Любое
    - *Протокол:* Любой (IP)
4. Сохраните изменения.
