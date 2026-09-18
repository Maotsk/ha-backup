# Changelog

Все значимые изменения проекта документируются в этом файле.

Формат основан на [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/),
проект придерживается [Semantic Versioning](https://semver.org/lang/ru/).

## [Unreleased]

Изменения, которые ещё не попали в релиз.

## [1.0.1] - 2026-09-18

### Added

- `install.sh`: подтверждение установки `[y/N]` с показом итоговых путей.
- `install.sh`: встроенный выбор зеркал GitHub — если прямой доступ к `raw.githubusercontent.com` заблокирован, скрипт пробует `gh-proxy.com`, `ghproxy.net`, `cdn.jsdelivr.net`.
- `install.sh`: переменная `HA_BACKUP_MIRROR` для ручного выбора зеркала.
- `install.sh`: определение версии через `api.github.com` (надёжнее, чем через редирект `github.com`).
- `ha-backup.sh`: флаги `--no-owner` и `--no-group` в `rsync` — устраняют ошибку `code 23` на CIFS-шарах.
- `ha-backup.sh`: поддержка `HA_BACKUP_CONF` и `HA_BACKUP_LOG_DIR` из переменных окружения.
- `.ha-backup.conf.example`: специальные значения `INSTALL_PATH` и `CONF_PATH` в `JOBS`, подставляемые установщиком автоматически.
- `README.md`: раздел «Если GitHub заблокирован».
- `README.md`: раздел о фиксированной структуре бэкапа на шаре.
- `README.md`: troubleshooting для случая недоступности GitHub.
- `README.md`: troubleshooting для `rsync code 23`.

### Changed

- **Установка рядом с `install.sh`.** Раньше файлы ставились в `/root` независимо от расположения установщика. Теперь `ha-backup.sh` и `.ha-backup.conf` ставятся в директорию, где лежит `install.sh`.
- **Фиксированная структура на шаре.** `backup/ha/`, `backup/docker-config/`, `backup/scripts/`, `backup/system/` — всегда одинаковые.
- **Логи всегда в `/var/log.hdd/ha`.** Не настраивается через аргументы или переменные.
- `install.sh`: определение версии и скачивание файлов разделены — версия через API, скачивание через raw или зеркало.
- `install.sh`: показ используемого зеркала в выводе.
- `install.sh`: добавлен `--max-time` на все сетевые запросы.
- `README.md`: раздел «Установка» переписан — объяснение про директорию `install.sh`.
- `README.md`: раздел «Восстановление» переписан — больше не зависит от того, куда была установка раньше.
- `README.md`: раздел «Обновление» — скачивать `install.sh` в директорию установки, а не в `/tmp`, и упомянуто автоопределение версии.

### Removed

- `install.sh`: аргументы `--dir`, `--conf-dir`, `--log-dir`.
- `install.sh`: переменные окружения `HA_BACKUP_DIR`, `HA_BACKUP_CONF_DIR`, `HA_BACKUP_LOG_DIR`.
- `install.sh`: интерактивный ввод путей установки.

### Fixed

- `install.sh`: корректная обработка сетей, где `github.com` заблокирован, но `raw.githubusercontent.com` доступен.
- `install.sh`: `RAW_BASE` формируется правильно для prefix- и replace-зеркал.
- `install.sh`: `systemctl status` без указания юнита заменён на `systemctl status ha-backup.service`.
- `install.sh`: порядок проверок (root → пакеты → версия).
- `README.md`: пример `JOBS` согласован с `DEST` — устранён двойной `backup/`.
- `README.md`: в Troubleshooting пути `/root/...` заменены на пометки про директорию установки.

### Breaking changes

Раньше установщик ставил файлы в `/root` независимо от того, откуда запускался. Теперь он ставит их **в директорию, где лежит `install.sh`**.

**Если вы ставили из `/tmp` или другой временной директории** — при обновлении положите `install.sh` в ту директорию, где уже установлен `ha-backup.sh`, и запустите оттуда.

Проверить, где установлен скрипт:

```bash
systemctl cat ha-backup.service | grep ExecStart
```

## [1.0.0] - 2026-09-14

Первый стабильный релиз.

### Added

- `ha-backup.sh`: основной скрипт бэкапа.
- `install.sh`: установщик с автоопределением последней версии через GitHub Releases.
- `.ha-backup.conf.example`: пример конфигурации.
- `.smbcredentials.example`: пример файла с SMB-кредами.
- `ha-backup.service`: systemd unit для запуска бэкапа.
- `ha-backup.timer`: systemd timer — ежедневно в 04:00.
- `LICENSE`: MIT.
- `README.md`: полная документация.
- `.github/workflows/shellcheck.yml`: CI-проверка через ShellCheck.
- `.gitignore`: исключены `.smbcredentials`, `.ha-backup.conf`, логи.

### Возможности

- **Ежедневный автобэкап** через systemd timer.
- **Инкрементальный rsync** — копируются только изменения.
- **Защита от записи на локальный диск** — проверка, что точка монтирования имеет тип `cifs`.
- **Защита от `rsync --delete` на пустом источнике** — если источник внезапно пуст, задача пропускается.
- **Блокировка параллельного запуска** через `flock`.
- **Ограничение скорости rsync** через `BW_LIMIT`.
- **Статистика backup** — количество задач, файлов, объём данных.
- **Уведомления в Telegram**:
  - тихое сообщение при успехе;
  - уведомление об ошибке;
  - поддержка SOCKS5-прокси;
  - HTML-разметка.
- **Ротация логов** — старые логи удаляются автоматически.
- **Единый конфиг** `.ha-backup.conf`.
- **Гибкий список задач** — добавление файлов, каталогов, исключений, режим `--delete`.

[Unreleased]: https://github.com/Maotsk/ha-backup/compare/v1.0.1...HEAD
[v1.0.1]: https://github.com/Maotsk/ha-backup/compare/v1.0.0...v1.0.1
[v1.0.0]: https://github.com/Maotsk/ha-backup/releases/tag/v1.0.0
