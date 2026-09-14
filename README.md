# HA Backup to TrueNAS

![Shellcheck](https://github.com/Maotsk/ha-backup/actions/workflows/check.yml/badge.svg)
![License](https://img.shields.io/github/license/Maotsk/ha-backup)
![Last commit](https://img.shields.io/github/last-commit/Maotsk/ha-backup)

Скрипт автоматического бэкапа Home Assistant (и сопутствующих конфигов) с Armbian-хоста на сетевую шару TrueNAS через CIFS/SMB.

Работает на слабых SBC (Orange Pi, NanoPi, Rock Pi и т.п.), устойчив к обрывам сети, уведомляет в Telegram через SOCKS5-прокси и сам чистит старые логи.

## Возможности

- **Ежедневный автобэкап** через `systemd timer` (по умолчанию в 04:00).
- **Инкрементальный rsync** — копируются только изменения, первый прогон полный.
- **Защита от записи на eMMC**: перед стартом проверяется, что шара действительно смонтирована как `cifs`. Если шара отвалилась — скрипт прерывается, а не забивает локальный диск.
- **Проверка непустого источника** — `rsync --delete` не снесёт бэкап, если источник внезапно пуст.
- **Уведомления в Telegram**:
  - тихое сообщение при успехе (без звука, видно утром),
  - громкое при ошибке (разбудит ночью),
  - поддержка SOCKS5-прокси,
  - HTML-разметка, человекочитаемый текст («Что случилось / Последствия / Что делать»).
- **Ротация логов** — логи старше N дней (по умолчанию 7) удаляются автоматически.
- **Единый конфиг** `/root/.ha-backup.conf` — все пути, Telegram, список задач в одном файле.
- **Гибкий список задач**: легко добавить/убрать папки и файлы, задать исключения и `--delete`.

## Что бэкапится по умолчанию

| Источник | Назначение на шаре | `--delete` |
|---|---|---|
| `/ha/` | `backup/ha/` | yes |
| `/root/docker-compose.yaml` | `backup/docker-config/` | no |
| `/root/ha-backup.sh` | `backup/scripts/` | no |
| `/root/.ha-backup.conf` | `backup/scripts/` | no |
| `/root/.smbcredentials` | `backup/scripts/` | no |
| `/etc/fstab` | `backup/system/` | no |

Список легко расширяется — см. раздел «Конфигурация».

## Стек

- Bash 5+
- `rsync`
- `cifs-utils`
- `systemd` (timer + service)
- `curl` (для Telegram, с поддержкой SOCKS5)

## Требования

- Armbian (или любой Debian-based Linux) на SBC.
- Установленные пакеты:
  ```bash
  sudo apt update
  sudo apt install -y rsync cifs-utils curl
  ```
- Сетевая шара CIFS/SMB на TrueNAS (или другом сервере).
- Пользователь SMB с правами на шару.
- (Опционально) Telegram-бот и SOCKS5-прокси.

## Установка

### 1. Монтирование шары

Создать файл с кредами:

```bash
sudo nano /root/.smbcredentials
```

Содержимое:

```
username=ВАШ_ЛОГИН
password=ВАШ_ПАРОЛЬ
```

Права:

```bash
sudo chmod 600 /root/.smbcredentials
```

Добавить в `/etc/fstab`:

```
//192.168.68.200/ha /mnt/ha-dataset cifs credentials=/root/.smbcredentials,iocharset=utf8,uid=0,gid=0,file_mode=0700,dir_mode=0700,_netdev,nofail 0 0
```

> **Важно:** опция `x-systemd.automount` **не рекомендуется** — autofs-юнит часто «залипает» после ручных `umount`. Скрипт сам проверяет `findmnt = cifs`, так что защита сохраняется и без autofs.

Смонтировать:

```bash
sudo mkdir -p /mnt/ha-dataset
sudo systemctl daemon-reload
sudo mount /mnt/ha-dataset
```

Проверить:

```bash
findmnt -n -o FSTYPE --target /mnt/ha-dataset | tail -1
# должно быть: cifs
df -hT /mnt/ha-dataset
```

### 2. Создать конфиг

```bash
sudo nano /root/.ha-backup.conf
```

Вставить содержимое (см. раздел «Конфигурация»), заполнить `TG_TOKEN`, `TG_CHAT_ID`, `TG_PROXY`.

Права:

```bash
sudo chmod 600 /root/.ha-backup.conf
```

### 3. Установить скрипт

```bash
sudo nano /root/ha-backup.sh
```

Вставить содержимое скрипта (см. файл `ha-backup.sh` в репозитории).

```bash
sudo chmod +x /root/ha-backup.sh
sudo bash -n /root/ha-backup.sh && echo "синтаксис OK"
```

### 4. Установить systemd timer

`/etc/systemd/system/ha-backup.service`:

```ini
[Unit]
Description=Home Assistant Backup to TrueNAS
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/root/ha-backup.sh
User=root
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=6
```

`/etc/systemd/system/ha-backup.timer`:

```ini
[Unit]
Description=Run HA Backup daily at 04:00
Requires=ha-backup.service

[Timer]
OnCalendar=*-*-* 04:00:00
Persistent=true
RandomizedDelaySec=5m
Unit=ha-backup.service

[Install]
WantedBy=timers.target
```

Активировать:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now ha-backup.timer
systemctl list-timers ha-backup.timer --no-pager
```

### 5. Проверить

```bash
sudo systemctl start ha-backup.service
sudo systemctl status ha-backup.service --no-pager
sudo tail -30 /var/log.hdd/ha/ha-backup-$(date +%F).log
```

## Конфигурация

Файл `/root/.ha-backup.conf` — единственное место, где настраивается всё.

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

# Что отправлять
TG_NOTIFY_SUCCESS="true"
TG_NOTIFY_ERROR="true"

# Тихий режим (без звука/вибрации)
TG_SILENT_SUCCESS="true"
TG_SILENT_ERROR="false"

# ---------- Что бэкапить ----------
# Формат: "ИСТОЧНИК|ПОДПАПКА_НА_ШАРЕ|ИСКЛЮЧЕНИЯ|--delete?"
JOBS=(
    "/ha/|backup/ha/|*.log|yes"
    "/root/docker-compose.yaml|backup/docker-config/||no"
    "/root/ha-backup.sh|backup/scripts/||no"
    "/root/.ha-backup.conf|backup/scripts/||no"
    "/root/.smbcredentials|backup/scripts/||no"
    "/etc/fstab|backup/system/||no"
)
```

### Параметры

| Параметр | Описание |
|---|---|
| `DEST` | Куда на шаре складывать бэкапы |
| `MOUNTPOINT` | Точка монтирования шары (проверяется) |
| `LOGDIR` | Где хранить логи |
| `BW_LIMIT` | Ограничение скорости rsync (КБ/с). `0` — без лимита |
| `LOG_RETENTION_DAYS` | Сколько дней хранить логи |
| `TG_TOKEN` | Токен Telegram-бота от `@BotFather` |
| `TG_CHAT_ID` | ID чата (узнать через `getUpdates`) |
| `TG_PROXY` | SOCKS5-прокси. Пусто = без прокси |
| `TG_NOTIFY_SUCCESS` | Отправлять сообщение при успехе |
| `TG_NOTIFY_ERROR` | Отправлять сообщение при ошибке |
| `TG_SILENT_SUCCESS` | Успех — без звука (`true`) или со звуком (`false`) |
| `TG_SILENT_ERROR` | Ошибка — без звука (`true`) или со звуком (`false`) |
| `JOBS` | Массив задач: что, куда, исключения, `--delete` |

### Формат `JOBS`

Каждая задача — строка из 4 полей, разделённых `|`:

```
"ИСТОЧНИК|ПОДПАПКА_НА_ШАРЕ|ИСКЛЮЧЕНИЯ|--delete?"
```

- **ИСТОЧНИК** — что копируем. Для папок — обязательно со слешем на конце (`/ha/`, а не `/ha`), иначе `rsync` создаст вложенную папку с именем источника.
- **ПОДПАПКА_НА_ШАРЕ** — путь относительно `DEST`.
- **ИСКЛЮЧЕНИЯ** — маски через запятую (`*.log,*.tmp`), либо пусто.
- **--delete?** — `yes` = удалять на шаре то, чего нет в источнике. `no` = только добавлять/обновлять.

### Примеры

**Добавить бэкап systemd-юнитов:**

```bash
"/etc/systemd/system/|backup/systemd/||no"
```

**Исключить БД и кэш из `/ha`:**

```bash
"/ha/|backup/ha/|*.log,*.db-wal,*.db-shm|yes"
```

**Без ограничения скорости:**

```bash
BW_LIMIT="0"
```

**Полная тишина (только логи):**

```bash
TG_NOTIFY_SUCCESS="false"
TG_NOTIFY_ERROR="false"
```

## Использование

### Запуск вручную

```bash
sudo systemctl start ha-backup.service
sudo systemctl status ha-backup.service --no-pager
```

Или напрямую:

```bash
sudo /root/ha-backup.sh
```

### Смотреть лог в реальном времени

```bash
sudo tail -f /var/log.hdd/ha/ha-backup-$(date +%F).log
```

### Следующий автозапуск

```bash
systemctl list-timers ha-backup.timer --no-pager
```

### Отключить / включить автозапуск

```bash
sudo systemctl disable --now ha-backup.timer   # выключить
sudo systemctl enable --now ha-backup.timer    # включить
```

### История всех запусков

```bash
journalctl -u ha-backup.service --no-pager | tail -50
```

## Восстановление

Все нужные для восстановления файлы лежат на шаре:

```
/mnt/ha-dataset/backup/
├── ha/                 # данные Home Assistant
├── docker-config/      # docker-compose.yaml
├── scripts/            # ha-backup.sh, .ha-backup.conf, .smbcredentials
└── system/             # fstab
```

### Порядок восстановления на новом хосте

1. Установить Armbian, обновить систему.
2. Установить пакеты:
   ```bash
   sudo apt install -y rsync cifs-utils curl docker.io docker-compose-plugin
   ```
3. Смонтировать шару (см. раздел «Установка»).
4. Скопировать конфиги обратно:
   ```bash
   sudo cp /mnt/ha-dataset/backup/scripts/.smbcredentials /root/
   sudo cp /mnt/ha-dataset/backup/scripts/.ha-backup.conf /root/
   sudo cp /mnt/ha-dataset/backup/scripts/ha-backup.sh /root/
   sudo cp /mnt/ha-dataset/backup/system/fstab /etc/fstab
   sudo chmod 600 /root/.smbcredentials /root/.ha-backup.conf
   sudo chmod +x /root/ha-backup.sh
   ```
5. Восстановить данные HA:
   ```bash
   sudo rsync -a /mnt/ha-dataset/backup/ha/ /ha/
   ```
6. Восстановить Docker Compose:
   ```bash
   sudo cp /mnt/ha-dataset/backup/docker-config/docker-compose.yaml /root/
   cd /root && sudo docker compose up -d
   ```
7. Настроить timer (см. раздел «Установка»).

## Troubleshooting

### Сообщение «не смонтирован» или «тип ФС ext4»

Шара отвалилась или не смонтирована. Проверить:

```bash
ping -c 3 192.168.68.200
findmnt -n -o FSTYPE --target /mnt/ha-dataset | tail -1
```

Если `ext4` или пусто — шара не смонтирована. Перемонтировать:

```bash
sudo systemctl daemon-reload
sudo umount /mnt/ha-dataset 2>/dev/null
sudo mount /mnt/ha-dataset
```

### Сообщение в Telegram не приходит

1. Проверить, что токен и chat_id заполнены:
   ```bash
   sudo bash -c 'source /root/.ha-backup.conf; echo "[$TG_TOKEN] [$TG_CHAT_ID]"'
   ```
2. Проверить прокси:
   ```bash
   sudo bash -c 'source /root/.ha-backup.conf; curl -s -x "$TG_PROXY" https://api.telegram.org | head -c 200'
   ```
3. Посмотреть лог скрипта — там есть строка `TG: silent=... resp=...`:
   ```bash
   sudo grep 'TG:' /var/log.hdd/ha/ha-backup-$(date +%F).log
   ```
   - `"ok":true` — сообщение ушло.
   - `"ok":false,"description":"..."` — Telegram отклонил, причина в `description`.
   - Пусто — curl не подключился (прокси/сеть).

### Скрипт падает с «rsync код 20»

`Broken pipe` — шара отвалилась во время копирования. Проверить связь с TrueNAS, следующий запуск продолжит с места остановки.

### autofs-юнит «залипает»

Если используете `x-systemd.automount` и он падает с `Failed with result 'unmounted'` — уберите эту опцию из `/etc/fstab`. Скрипт всё равно проверяет `findmnt = cifs`.

### Логи не удаляются

Проверить, что `cleanup_old_logs` в скрипте вызывается до `START_TS`:

```bash
sudo grep -n 'cleanup_old_logs' /root/ha-backup.sh
# должно быть 2: определение и вызов
```

И что `LOG_RETENTION_DAYS` в конфиге:

```bash
sudo grep '^LOG_RETENTION_DAYS' /root/.ha-backup.conf
```

## Лицензия

MIT — используйте, модифицируйте, распространяйте свободно.
