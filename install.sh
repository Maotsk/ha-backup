#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== HA Backup to TrueNAS — установка ==="

# 1. Проверка root
if [ "$EUID" -ne 0 ]; then
    echo "Запустите от root: sudo $0"
    exit 1
fi

# 2. Пакеты
echo "--- Установка пакетов ---"
apt update
apt install -y rsync cifs-utils curl

# 3. Копирование файлов
echo "--- Копирование файлов ---"
install -m 755 "$REPO_DIR/ha-backup.sh" /root/ha-backup.sh

if [ ! -f /root/.ha-backup.conf ]; then
    install -m 600 "$REPO_DIR/.ha-backup.conf.example" /root/.ha-backup.conf
    echo "Создан /root/.ha-backup.conf — отредактируйте его и заполните TG_TOKEN, TG_CHAT_ID, TG_PROXY"
else
    echo "/root/.ha-backup.conf уже существует — не перезаписываю"
fi

if [ ! -f /root/.smbcredentials ]; then
    install -m 600 "$REPO_DIR/.smbcredentials.example" /root/.smbcredentials
    echo "Создан /root/.smbcredentials — впишите логин и пароль SMB"
fi

# 4. systemd
echo "--- Установка systemd unit ---"
install -m 644 "$REPO_DIR/ha-backup.service" /etc/systemd/system/ha-backup.service
install -m 644 "$REPO_DIR/ha-backup.timer"   /etc/systemd/system/ha-backup.timer

systemctl daemon-reload
systemctl enable --now ha-backup.timer

# 5. Проверка
echo ""
echo "=== Установка завершена ==="
echo ""
echo "Что дальше:"
echo "  1. Впишите SMB-креды:       sudo nano /root/.smbcredentials"
echo "  2. Настройте конфиг:        sudo nano /root/.ha-backup.conf"
echo "  3. Проверьте монтирование:  sudo mount /mnt/ha-dataset"
echo "  4. Запустите тест:          sudo /root/ha-backup.sh"
echo ""
systemctl list-timers ha-backup.timer --no-pager || true
