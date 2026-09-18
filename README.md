# HA Backup to TrueNAS

![Shellcheck](https://github.com/Maotsk/ha-backup/actions/workflows/shellcheck.yml/badge.svg)
![License](https://img.shields.io/github/license/Maotsk/ha-backup)
![Last commit](https://img.shields.io/github/last-commit/Maotsk/ha-backup)
![Version](https://img.shields.io/github/v/tag/Maotsk/ha-backup?label=version)

Скрипт автоматического бэкапа Home Assistant и сопутствующих конфигов с Armbian-хоста на сетевую шару TrueNAS через CIFS/SMB.

Проект рассчитан на слабые SBC (Orange Pi, NanoPi, Rock Pi и т.п.), работает через `rsync`, поддерживает Telegram-уведомления через SOCKS5 и автоматически очищает старые логи.

## Возможности

- **Ежедневный автобэкап** через `systemd timer` (по умолчанию в 04:00).
- **Инкрементальный rsync** — копируются только изменения, первый запуск полный.
- **Защита от записи на локальный диск** — перед началом проверяется, что точка монтирования действительно имеет файловую систему `cifs`.
- **Защита от `rsync --delete` на пустом источнике** — если источник внезапно стал пустым, задача с `--delete` не запускается.
- **Блокировка параллельного запуска** через `flock`.
- **Ограничение скорости rsync** через `BW_LIMIT`.
- **Статистика backup** — количество обработанных задач, файлов и объём данных.
- **Уведомления в Telegram**:
  - тихое сообщение при успешном завершении;
  - уведомление об ошибке;
  - поддержка SOCKS5-прокси;
  - HTML-разметка;
  - понятное описание ошибки.
- **Ротация логов** — старые логи автоматически удаляются.
- **Единый конфиг** `.ha-backup.conf`.
- **Гибкий список задач** — можно добавлять файлы и каталоги, исключения и режим `--delete`.
- **Автоопределение версии** при установке через GitHub API.
- **Работа через зеркала GitHub**, если прямой доступ заблокирован.
- **systemd service + timer** — запуск без необходимости держать терминал открытым.

## Что бэкапится по умолчанию

| Источник | Итоговый путь на шаре | `--delete` |
|---|---|---|
| `/ha/` | `backup/ha/` | yes |
| `/root/docker-compose.yaml` | `backup/docker-config/` | no |
| `<директория install.sh>/ha-backup.sh` | `backup/scripts/` | no |
| `<директория install.sh>/.ha-backup.conf` | `backup/scripts/` | no |
| `/etc/fstab` | `backup/system/` | no |

Пути к `ha-backup.sh` и `.ha-backup.conf` подставляются автоматически при установке — в зависимости от того, где лежит `install.sh`.

Список задач можно изменить в конфиге (см. раздел «Конфигурация»).

> **Безопасность:** файл `.ha-backup.conf` может содержать секреты, например Telegram Bot Token. Поэтому резервная копия `backup/scripts/.ha-backup.conf` должна храниться на защищённой SMB-шаре с ограниченным доступом.
>
> Файл `.smbcredentials` намеренно **не включён** в список резервного копирования.

## Стек

- Bash 5+
- `rsync`
- `cifs-utils`
- `systemd` (`service` + `timer`)
- `curl`
- `findutils`
- `util-linux`
- `coreutils`
- Telegram Bot API
- CIFS/SMB

## Требования

- Armbian или любой Debian-based Linux.
- Root-доступ.
- Сетевая шара CIFS/SMB на TrueNAS или другом сервере.
- Пользователь SMB с правами на шару.
- `systemd`.
- Для Telegram-уведомлений — Telegram-бот.
- SOCKS5-прокси — опционально.
- Доступ к `api.github.com` и `raw.githubusercontent.com` или зеркалу GitHub.

Установщик автоматически устанавливает необходимые пакеты:

- `rsync`
- `cifs-utils`
- `curl`
- `findutils`
- `util-linux`
- `coreutils`

## Установка

### 1. Монтирование шары

Создать файл с SMB credentials:

```bash
sudo nano /root/.smbcredentials
```

Содержимое:

```text
username=ВАШ_ЛОГИН
password=ВАШ_ПАРОЛЬ
```

Установить права:

```bash
sudo chmod 600 /root/.smbcredentials
```

Добавить шару в `/etc/fstab`:

```text
//192.168.68.200/ha /mnt/ha-dataset cifs credentials=/root/.smbcredentials,iocharset=utf8,uid=0,gid=0,file_mode=0700,dir_mode=0700,_netdev,nofail 0 0
```

Создать точку монтирования:

```bash
sudo mkdir -p /mnt/ha-dataset
```

Перечитать конфигурацию systemd:

```bash
sudo systemctl daemon-reload
```

Смонтировать шару:

```bash
sudo mount /mnt/ha-dataset
```

Проверить тип файловой системы:

```bash
findmnt -n -o FSTYPE --target /mnt/ha-dataset | tail -1
```

Должно быть:

```text
cifs
```

Проверить свободное место:

```bash
df -hT /mnt/ha-dataset
```

> **Важно:** опция `x-systemd.automount` не требуется. Скрипт самостоятельно проверяет, что `/mnt/ha-dataset` действительно смонтирован как `cifs`.

### 2. Установить HA Backup

Установщик ставит файлы **в ту же директорию, где лежит сам `install.sh`**. Логи всегда пишутся в `/var/log.hdd/ha`.

Версия определяется автоматически через `api.github.com` (или через зеркало, если GitHub заблокирован).

**Установка в `/root` (традиционно):**

```bash
cd /root
curl -fsSL https://raw.githubusercontent.com/Maotsk/ha-backup/main/install.sh -o install.sh
sudo bash install.sh
```

**Установка в `/opt/ha-backup`:**

```bash
sudo mkdir -p /opt/ha-backup
cd /opt/ha-backup
curl -fsSL https://raw.githubusercontent.com/Maotsk/ha-backup/main/install.sh -o install.sh
sudo bash install.sh
```

Установщик покажет итоговые пути и спросит подтверждение `[y/N]`. Если пути не подходят — прервите установку (`Ctrl+C`) и положите `install.sh` в другую директорию.

**Установить конкретную версию:**

```bash
HA_BACKUP_REF=1.0.2 sudo -E bash install.sh
```

**Установить последнюю из ветки `main`:**

```bash
HA_BACKUP_REF=main sudo -E bash install.sh
```

Установщик:

- устанавливает необходимые пакеты;
- определяет последнюю версию через `api.github.com`;
- выбирает рабочее зеркало GitHub, если прямой доступ заблокирован;
- ставит `ha-backup.sh` рядом с собой;
- создаёт `.ha-backup.conf` (если его ещё нет);
- сохраняет существующий `.ha-backup.conf`;
- настраивает `ha-backup.service` под реальные пути;
- устанавливает `ha-backup.timer` (ежедневно в 04:00);
- создаёт `/var/log.hdd/ha`;
- включает timer.

> **Важно:** не запускайте `install.sh` из `/tmp` — там файлы могут быть удалены при перезагрузке. Скачивайте его сразу в целевую директорию.

#### Если GitHub заблокирован

Установщик **сам пробует зеркала** по очереди, если прямой доступ к `github.com` или `api.github.com` не работает:

```
[3/7] Проверка доступности GitHub...
  пробую: https://raw.githubusercontent.com
  ✗ не отвечает
  пробую: https://gh-proxy.com/https://raw.githubusercontent.com
  ✅ доступно
```

Можно задать своё зеркало вручную:

```bash
HA_BACKUP_MIRROR="https://gh-proxy.com/https://raw.githubusercontent.com" \
    sudo -E bash install.sh
```

Или использовать SOCKS5-прокси:

```bash
export https_proxy="socks5h://127.0.0.1:1080"
sudo -E bash install.sh
```

### 3. Настроить конфигурацию

```bash
sudo nano /root/.ha-backup.conf
```

Если ставили в другую директорию — путь будет `<директория установки>/.ha-backup.conf`.

Что нужно заполнить:

| Параметр | Зачем |
|---|---|
| `DEST` | Куда на шаре складывать бэкапы (обычно менять не нужно) |
| `MOUNTPOINT` | Точка монтирования шары (должна совпадать с `/etc/fstab`) |
| `TG_TOKEN` | Токен Telegram-бота (если нужны уведомления) |
| `TG_CHAT_ID` | ID чата |

Остальное (структура папок на шаре, `JOBS`, `LOGDIR`) — уже настроено.

После изменения:

```bash
sudo chmod 600 /root/.ha-backup.conf
```

### 4. Проверить timer

```bash
systemctl list-timers ha-backup.timer --no-pager
```

Должен отображаться следующий запуск.

### 5. Выполнить первый запуск вручную

```bash
sudo systemctl start ha-backup.service
```

Проверить результат:

```bash
sudo systemctl status ha-backup.service --no-pager
```

Посмотреть лог:

```bash
sudo tail -30 /var/log.hdd/ha/ha-backup-$(date +%F).log
```

## Конфигурация

Основной конфигурационный файл:

```text
<директория установки>/.ha-backup.conf
```

Обычно `/root/.ha-backup.conf`. Если ставили в `/opt/ha-backup` — `/opt/ha-backup/.ha-backup.conf`.

Пример:

```bash
# ---------- Куда бэкапить ----------
DEST="/mnt/ha-dataset/backup/"
MOUNTPOINT="/mnt/ha-dataset"
LOGDIR="/var/log.hdd/ha"

# ---------- Ограничение скорости rsync (КБ/с) ----------
# 0 = без ограничения
BW_LIMIT="5000"

# ---------- Сколько дней хранить логи ----------
LOG_RETENTION_DAYS="7"

# ---------- Telegram ----------
TG_TOKEN=""
TG_CHAT_ID=""
TG_PROXY="socks5h://127.0.0.1:1080"

# Уведомления
TG_NOTIFY_SUCCESS="true"
TG_NOTIFY_ERROR="true"

# Тихий режим
TG_SILENT_SUCCESS="true"
TG_SILENT_ERROR="false"

# ---------- Что бэкапить ----------
JOBS=(
    "/ha/|ha/|*.log|yes"
    "/root/docker-compose.yaml|docker-config/||no"
    "INSTALL_PATH|scripts/||no"
    "CONF_PATH|scripts/||no"
    "/etc/fstab|system/||no"
)
```

### Параметры

| Параметр | Описание |
|---|---|
| `DEST` | Основной каталог backup на SMB-шаре |
| `MOUNTPOINT` | Точка монтирования SMB-шары |
| `LOGDIR` | Каталог для логов |
| `BW_LIMIT` | Ограничение скорости `rsync` в КБ/с |
| `LOG_RETENTION_DAYS` | Сколько дней хранить логи |
| `TG_TOKEN` | Telegram Bot Token |
| `TG_CHAT_ID` | ID Telegram-чата |
| `TG_PROXY` | SOCKS5-прокси |
| `TG_NOTIFY_SUCCESS` | Отправлять уведомление при успехе |
| `TG_NOTIFY_ERROR` | Отправлять уведомление при ошибке |
| `TG_SILENT_SUCCESS` | Успешное сообщение без звука |
| `TG_SILENT_ERROR` | Ошибка без звука |
| `JOBS` | Список задач резервного копирования |

### Telegram

Если Telegram не нужен, можно оставить:

```bash
TG_TOKEN=""
TG_CHAT_ID=""
```

Для работы через SOCKS5:

```bash
TG_PROXY="socks5h://127.0.0.1:1080"
```

Без прокси:

```bash
TG_PROXY=""
```

### Формат `JOBS`

Каждая задача имеет четыре поля:

```text
ИСТОЧНИК|ПОДПАПКА_НА_ШАРЕ|ИСКЛЮЧЕНИЯ|--delete?
```

Например:

```bash
"/ha/|ha/|*.log|yes"
```

Расшифровка:

- `/ha/` — источник;
- `ha/` — каталог назначения относительно `DEST` (итог: `/mnt/ha-dataset/backup/ha/`);
- `*.log` — исключение;
- `yes` — использовать `--delete`.

Специальные значения в поле «ИСТОЧНИК»:

- `INSTALL_PATH` — путь к `ha-backup.sh`, подставляется установщиком.
- `CONF_PATH` — путь к `.ha-backup.conf`, подставляется установщиком.

Эти два значения не нужно менять — они уже правильные после установки.

### Важный момент для каталогов

Для каталогов рекомендуется использовать завершающий `/`.

Правильно:

```bash
"/ha/|ha/||yes"
```

Без завершающего `/` поведение `rsync` при копировании структуры каталогов будет другим.

### `--delete`

```text
yes
```

означает, что файлы, удалённые из источника, будут удаляться и из backup.

```text
no
```

означает, что существующие файлы на backup не удаляются.

> **Защита:** перед выполнением задачи с `--delete` скрипт проверяет, что источник не является внезапно пустым. Это предотвращает удаление всего backup при аварийной ситуации с источником.

### Примеры

Добавить backup systemd-юнитов:

```bash
"/etc/systemd/system/|systemd/||no"
```

Добавить backup сетевых подключений:

```bash
"/etc/NetworkManager/system-connections/|network/||no"
```

Исключить несколько типов файлов:

```bash
"/ha/|ha/|*.log,*.db-wal,*.db-shm|yes"
```

Отключить ограничение скорости:

```bash
BW_LIMIT="0"
```

Отключить все Telegram-уведомления:

```bash
TG_NOTIFY_SUCCESS="false"
TG_NOTIFY_ERROR="false"
```

## Использование

### Запуск вручную через systemd

```bash
sudo systemctl start ha-backup.service
```

Проверить статус:

```bash
sudo systemctl status ha-backup.service --no-pager
```

### Запуск напрямую

```bash
sudo <директория установки>/ha-backup.sh
```

### Смотреть лог в реальном времени

```bash
sudo tail -f /var/log.hdd/ha/ha-backup-$(date +%F).log
```

### Следующий автоматический запуск

```bash
systemctl list-timers ha-backup.timer --no-pager
```

### Отключить автоматический backup

```bash
sudo systemctl disable --now ha-backup.timer
```

### Включить автоматический backup

```bash
sudo systemctl enable --now ha-backup.timer
```

### История запусков

```bash
journalctl -u ha-backup.service --no-pager | tail -50
```

## Systemd

Установщик создаёт:

```text
/etc/systemd/system/ha-backup.service
/etc/systemd/system/ha-backup.timer
```

### Service

Сервис запускается как `root` и выполняет backup один раз:

```ini
[Unit]
Description=Home Assistant Backup to TrueNAS
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=HA_BACKUP_CONF=<директория установки>/.ha-backup.conf
Environment=HA_BACKUP_LOG_DIR=/var/log.hdd/ha
ExecStart=<директория установки>/ha-backup.sh
User=root
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=6
```

`Environment=HA_BACKUP_CONF` и `ExecStart` подставляются установщиком автоматически.

### Timer

По умолчанию backup запускается ежедневно около 04:00:

```ini
[Timer]
OnCalendar=*-*-* 04:00:00
Persistent=true
RandomizedDelaySec=5m
Unit=ha-backup.service
```

`RandomizedDelaySec=5m` означает, что фактический запуск может быть немного сдвинут относительно 04:00.

`Persistent=true` позволяет systemd выполнить пропущенный запуск после того, как система снова включилась.

## Защита от параллельного запуска

Скрипт использует:

```text
/run/ha-backup.lock
```

и `flock`.

Это предотвращает одновременный запуск нескольких экземпляров backup.

Например, если предыдущий backup ещё выполняется, второй запуск не начнёт копирование параллельно.

## Восстановление

Восстановление **не зависит** от того, куда был установлен скрипт раньше. Вы ставите HA Backup заново в удобное место, а из бэкапа берёте данные и настройки.

Структура на шаре всегда одинаковая:

```text
/mnt/ha-dataset/backup/
├── ha/                     ← данные Home Assistant
├── docker-config/
│   └── docker-compose.yaml
├── scripts/
│   ├── ha-backup.sh
│   └── .ha-backup.conf
└── system/
    └── fstab
```

### Порядок восстановления

#### 1. Установить Armbian

#### 2. Установить пакеты

```bash
sudo apt update
sudo apt install -y rsync cifs-utils curl docker.io docker-compose-plugin
```

#### 3. Смонтировать шару

Создать `/root/.smbcredentials`:

```text
username=ВАШ_ЛОГИН
password=ВАШ_ПАРОЛЬ
```

```bash
sudo chmod 600 /root/.smbcredentials
```

Добавить в `/etc/fstab`:

```text
//192.168.68.200/ha /mnt/ha-dataset cifs credentials=/root/.smbcredentials,iocharset=utf8,uid=0,gid=0,file_mode=0700,dir_mode=0700,_netdev,nofail 0 0
```

```bash
sudo mkdir -p /mnt/ha-dataset
sudo systemctl daemon-reload
sudo mount /mnt/ha-dataset
findmnt -n -o FSTYPE --target /mnt/ha-dataset | tail -1
# должно быть: cifs
```

#### 4. Установить HA Backup

```bash
cd /root
curl -fsSL https://raw.githubusercontent.com/Maotsk/ha-backup/main/install.sh -o install.sh
sudo bash install.sh
```

#### 5. Настроить конфиг

Взять настройки из старого конфига на шаре:

```bash
sudo cat /mnt/ha-dataset/backup/scripts/.ha-backup.conf
```

Скопировать оттуда в свежий конфиг:

- `DEST`
- `MOUNTPOINT`
- `TG_TOKEN`
- `TG_CHAT_ID`
- `TG_PROXY`
- `BW_LIMIT`
- `LOG_RETENTION_DAYS`

`JOBS` и `LOGDIR` **оставить как есть** — установщик уже подставил правильные пути.

После правки:

```bash
sudo chmod 600 /root/.ha-backup.conf
```

#### 6. Восстановить Home Assistant

```bash
sudo mkdir -p /ha
sudo rsync -a /mnt/ha-dataset/backup/ha/ /ha/
```

#### 7. Восстановить Docker Compose

```bash
sudo cp /mnt/ha-dataset/backup/docker-config/docker-compose.yaml /root/
cd /root
sudo docker compose up -d
```

#### 8. Проверить бэкап

```bash
sudo systemctl start ha-backup.service
sudo systemctl status ha-backup.service --no-pager
sudo tail -30 /var/log.hdd/ha/ha-backup-$(date +%F).log
```

Если в логе `=== Бэкап успешно завершён ===` — всё работает.

## Troubleshooting

### Шара не смонтирована

Проверить связь:

```bash
ping -c 3 192.168.68.200
```

Проверить файловую систему:

```bash
findmnt -n -o FSTYPE --target /mnt/ha-dataset | tail -1
```

Должно быть:

```text
cifs
```

Если вывод пустой или указан другой тип файловой системы, шара не смонтирована.

Попробовать:

```bash
sudo systemctl daemon-reload
sudo umount /mnt/ha-dataset 2>/dev/null
sudo mount /mnt/ha-dataset
```

После этого снова проверить:

```bash
findmnt -n -o FSTYPE --target /mnt/ha-dataset | tail -1
```

### Telegram-сообщение не приходит

Проверить конфигурацию (путь к конфигу — там, где у вас установлен HA Backup):

```bash
sudo bash -c 'source /root/.ha-backup.conf; echo "[$TG_TOKEN] [$TG_CHAT_ID]"'
```

> Не публикуйте результат этой команды, если в нём присутствует настоящий Telegram Bot Token.

Проверить соединение через прокси:

```bash
sudo bash -c 'source /root/.ha-backup.conf; curl -s -x "$TG_PROXY" https://api.telegram.org | head -c 200'
```

Посмотреть Telegram-строки в логе:

```bash
sudo grep 'TG:' /var/log.hdd/ha/ha-backup-$(date +%F).log
```

Если Telegram API ответил успешно, в ответе должно присутствовать:

```text
"ok":true
```

Если:

```text
"ok":false
```

ищите причину в поле `description`.

### `rsync` завершился с ошибкой

Посмотреть лог:

```bash
sudo tail -100 /var/log.hdd/ha/ha-backup-$(date +%F).log
```

Проверить состояние SMB-шары:

```bash
findmnt -n -o FSTYPE --target /mnt/ha-dataset
```

Проверить доступность TrueNAS:

```bash
ping -c 3 192.168.68.200
```

Если соединение с SMB-шарой было потеряно во время копирования, следующий запуск повторит синхронизацию.

### `rsync` завершился с кодом 23

Код 23 означает частичную передачу — обычно из-за попытки сменить владельца или группу файлов на CIFS-шаре. Начиная с версии 1.0.1 скрипт использует флаги `--no-owner --no-group`, что решает проблему.

Проверить, что флаги применены:

```bash
sudo grep -A 6 'RSYNC_OPTS=(' /root/ha-backup.sh
```

Должно быть:

```bash
RSYNC_OPTS=(
    -rlptDv
    --stats
    --no-owner
    --no-group
)
```

Если флагов нет — обновите скрипт через `install.sh`.

### `rsync --delete` не запускается

Если появляется сообщение о пустом источнике, сначала проверить источник:

```bash
ls -la /ha/
```

Защита предназначена для ситуации, когда источник внезапно стал пустым из-за проблемы с монтированием, контейнером или файловой системой.

Не следует отключать эту защиту без понимания причины.

### autofs / `x-systemd.automount` работает нестабильно

Для проекта `x-systemd.automount` не требуется.

Если используется такая настройка и появляется проблема с зависшим mount-unit, убрать `x-systemd.automount` из `/etc/fstab`.

После изменения:

```bash
sudo systemctl daemon-reload
```

Затем:

```bash
sudo umount /mnt/ha-dataset 2>/dev/null
sudo mount /mnt/ha-dataset
```

### Логи не удаляются

Проверить параметр (путь к конфигу — там, где у вас установлен HA Backup):

```bash
sudo grep '^LOG_RETENTION_DAYS' /root/.ha-backup.conf
```

Проверить наличие функции очистки:

```bash
sudo grep -n 'cleanup_old_logs' /root/ha-backup.sh
```

Проверить каталог:

```bash
ls -lah /var/log.hdd/ha/
```

### Проверка синтаксиса скрипта

Перед запуском можно проверить Bash-синтаксис (путь к скрипту — там, где установлен HA Backup):

```bash
sudo bash -n /root/ha-backup.sh
```

Если команда ничего не вывела и вернула код `0`, синтаксис корректен.

### Установщик не может достучаться до GitHub

Если видите:

```text
ВНИМАНИЕ: не удалось определить последнюю версию.
Использую fallback: v1.0.0
...
ОШИБКА: версия v1.0.0 недоступна
```

или

```text
ОШИБКА: не удалось найти рабочее зеркало.
```

Проверьте доступ к `api.github.com` и `raw.githubusercontent.com`:

```bash
curl -fsSL -o /dev/null -w '%{http_code}\n' --max-time 10 \
    "https://api.github.com/repos/Maotsk/ha-backup/releases/latest"

curl -fsSL -o /dev/null -w '%{http_code}\n' --max-time 10 \
    "https://raw.githubusercontent.com/Maotsk/ha-backup/main/README.md"
```

Должно быть `200` в обоих случаях. Если один из них не отвечает — используйте зеркало:

```bash
HA_BACKUP_MIRROR="https://gh-proxy.com/https://raw.githubusercontent.com" \
    sudo -E bash install.sh
```

Или SOCKS5-прокси:

```bash
export https_proxy="socks5h://127.0.0.1:1080"
sudo -E bash install.sh
```

Популярные зеркала (установщик пробует их автоматически):

| Зеркало | Формат URL |
|---|---|
| `https://raw.githubusercontent.com` | прямой |
| `https://gh-proxy.com/https://raw.githubusercontent.com` | префикс |
| `https://ghproxy.net/https://raw.githubusercontent.com` | префикс |
| `https://cdn.jsdelivr.net/gh` | CDN |

## Обновление

Скачать свежий `install.sh` в директорию, где уже стоит HA Backup, и запустить:

```bash
cd /root   # или /opt/ha-backup, где у вас установлено
curl -fsSL https://raw.githubusercontent.com/Maotsk/ha-backup/main/install.sh -o install.sh
sudo bash install.sh
```

Существующий `.ha-backup.conf` **не перезаписывается**. Обновляется только `ha-backup.sh`, `ha-backup.service` и `ha-backup.timer`.

Установщик автоматически определит последнюю версию и скачает её. Чтобы установить конкретную:

```bash
HA_BACKUP_REF=1.0.2 sudo -E bash install.sh
```

Если GitHub заблокирован:

```bash
HA_BACKUP_MIRROR="https://gh-proxy.com/https://raw.githubusercontent.com" \
    sudo -E bash install.sh
```

## Версии

Проект использует Semantic Versioning:

- `1.0.0` — первый стабильный релиз.
- `1.0.1` — упрощённая установка, фикс `rsync code 23`.
- `1.0.2` — автоопределение версии через API, зеркала GitHub.
- `1.1.0` — новые возможности без нарушения совместимости.
- `2.0.0` — изменения, нарушающие совместимость.

## Лицензия

MIT — используйте, модифицируйте и распространяйте свободно.
