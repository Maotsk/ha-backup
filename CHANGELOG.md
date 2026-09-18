# Changelog

Все значимые изменения проекта документируются в этом файле.

Формат основан на [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/),
проект придерживается [Semantic Versioning](https://semver.org/lang/ru/).

## [Unreleased]

Изменения, которые ещё не попали в релиз.

## [1.0.2] - 2026-09-18

### Added

- `install.sh`: встроенный выбор зеркал GitHub — если прямой доступ к `raw.githubusercontent.com` заблокирован, скрипт пробует `gh-proxy.com`, `ghproxy.net`, `cdn.jsdelivr.net`.
- `install.sh`: переменная `HA_BACKUP_MIRROR` для ручного выбора зеркала.
- `install.sh`: определение версии через `api.github.com` (надёжнее, чем через редирект `github.com`).
- `README.md`: раздел «Если GitHub заблокирован».
- `README.md`: troubleshooting для случая недоступности GitHub.

### Changed

- `install.sh`: определение версии и скачивание файлов разделены — версия через API, скачивание через raw или зеркало.
- `install.sh`: показ используемого зеркала в выводе.
- `install.sh`: добавлен `--max-time` на все сетевые запросы.
- `README.md`: раздел «Обновление» — упомянуто автоопределение версии.

### Fixed

- `install.sh`: корректная обработка сетей, где `github.com` заблокирован, но `raw.githubusercontent.com` доступен.
- `install.sh`: `RAW_BASE` формируется правильно для prefix- и replace-зеркал.

## [1.0.1] - 2026-09-18

### Added

- `install.sh`: подтверждение установки `[y/N]` с показом итоговых путей.
- `.ha-backup.conf.example`: специальные значения `INSTALL_PATH` и `CONF_PATH` в `JOBS`, подставляемые установщиком автоматически.
- `ha-backup.sh`: флаги `--no-owner` и `--no-group` в `rsync` — устраняют ошибку `code 23` на CIFS-шарах.
- `ha-backup.sh`: поддержка `HA_BACKUP_CONF` и `HA_BACKUP_LOG_DIR` из переменных окружения.
- `README.md`: раздел о фиксированной структуре бэкапа на шаре.
- `README.md`: пометки в Troubleshooting о зависимости путей от директории установки.

### Changed

- **Установка рядом с `install.sh`.** Раньше файлы ставились в `/root` независимо от расположения установщика. Теперь `ha-backup.sh` и `.ha-backup.conf` ставятся в директорию, где лежит `install.sh`.
- **Фиксированная структура на шаре.** `backup/ha/`, `backup/docker-config/`, `backup/scripts/`, `backup/system/` — всегда одинаковые.
- **Логи всегда в `/var/log.hdd/ha`.** Не настраивается через аргументы или переменные.
- `README.md`: раздел «Установка» переписан — объяснение про директорию `install.sh`.
- `README.md`: раздел «Восстановление» переписан — больше не зависит от того, куда была установка раньше.
- `README.md`: раздел «Обновление» — скачивать `install.sh` в директорию установки, а не в `/tmp`.

### Removed

- `install.sh`: аргументы `--dir`, `--conf-dir`, `--log-dir`.
- `install.sh`: переменные окружения `HA_BACKUP_DIR`, `HA_BACKUP_CONF_DIR`, `HA_BACKUP_LOG_DIR`.
- `install.sh`: интерактивный ввод путей установки.

### Fixed

- `README.md`: пример `JOBS` согласован с `DEST` — устранён двойной `backup/`.
- `README.md`: в Troubleshooting пути `/root/...` заменены на пометки про директорию установки.
- `install.sh`: `systemctl status` без указания юнита заменён на `systemctl status ha-backup.service`.
- `install.sh`: порядок проверок (root → пакеты → версия).

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
- `ha-backup.timer`: systemd timer — ежедневно в 04:
