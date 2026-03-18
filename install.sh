#!/bin/bash
set -e

# ============================================================
# Mihomo + AmneziaWG установка на Ubuntu
# ============================================================

# --- НАСТРОЙКИ (измени перед запуском) ---
MIHOMO_SECRET=$(openssl rand -hex 32)   # Генерируется автоматически
AWG_PORT=443
AWG_SUBNET="10.10.0.0/24"
AWG_SERVER_IP="10.10.0.1"
AWG_CLIENT_IP="10.10.0.2"
CLIENT_DNS="10.10.0.1"
MIHOMO_DIR="/etc/mihomo"
AWG_CONF_DIR="/etc/amnezia/amneziawg"

# Параметры обфускации AmneziaWG (генерируются случайно при каждой установке)
JC=$((RANDOM % 9 + 4))          # 4-12
JMIN=$((RANDOM % 21 + 40))      # 40-60
JMAX=$((RANDOM % 51 + 70))      # 70-120
S1=$((RANDOM % 136 + 15))       # 15-150
S2=$((RANDOM % 136 + 15))       # 15-150
H1=$(shuf -i 100000000-2000000000 -n 1)
H2=$(shuf -i 100000000-2000000000 -n 1)
H3=$(shuf -i 100000000-2000000000 -n 1)
H4=$(shuf -i 100000000-2000000000 -n 1)

MAIN_IFACE=$(ip route show default | awk '{print $5}' | head -1)

echo "========================================"
echo " Mihomo + AmneziaWG Installer"
echo "========================================"
echo ""
read -p "Введите внешний IP сервера: " SERVER_PUBLIC_IP
if [ -z "$SERVER_PUBLIC_IP" ]; then
    echo "IP не может быть пустым"
    exit 1
fi

read -p "Введите URL подписки на прокси: " SUBSCRIPTION_URL
if [ -z "$SUBSCRIPTION_URL" ]; then
    echo "URL подписки не может быть пустым"
    exit 1
fi
echo ""
echo "Внешний IP:     $SERVER_PUBLIC_IP"
echo "Интерфейс:      $MAIN_IFACE"
echo "AWG подсеть:    $AWG_SUBNET"
echo "AWG порт:       $AWG_PORT"
echo "Mihomo secret:  $MIHOMO_SECRET"
echo "========================================"

# ============================================================
# Очистка предыдущей установки (если есть)
# ============================================================
REINSTALL=false

if systemctl is-active --quiet awg-quick@awg0 2>/dev/null || \
   systemctl is-active --quiet wg-quick@wg0 2>/dev/null || \
   systemctl is-active --quiet mihomo 2>/dev/null || \
   [ -f "$AWG_CONF_DIR/awg0.conf" ] || \
   [ -f "/etc/wireguard/wg0.conf" ] || \
   [ -f "$MIHOMO_DIR/config.yaml" ]; then
    echo ""
    echo "Обнаружена предыдущая установка!"
    echo "Переустановка полностью удалит старые конфиги и ключи."
    read -p "Переустановить? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then exit 0; fi
    REINSTALL=true

    echo ""
    echo "Очистка предыдущей установки..."

    # Останавливаем сервисы
    systemctl stop awg-quick@awg0 2>/dev/null || true
    systemctl disable awg-quick@awg0 2>/dev/null || true
    systemctl stop wg-quick@wg0 2>/dev/null || true
    systemctl disable wg-quick@wg0 2>/dev/null || true
    systemctl stop mihomo 2>/dev/null || true
    systemctl disable mihomo 2>/dev/null || true

    # Убираем интерфейсы если остались
    ip link del awg0 2>/dev/null || true
    ip link del wg0 2>/dev/null || true

    # Чистим iptables правила
    iptables -t mangle -F PREROUTING 2>/dev/null || true
    iptables -t nat -F PREROUTING 2>/dev/null || true
    iptables -t nat -F POSTROUTING 2>/dev/null || true
    ip rule del fwmark 1 table 100 2>/dev/null || true
    ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null || true

    # Бэкапим старые конфиги
    BACKUP_DIR="/root/backup-vpn-$(date +%Y%m%d%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    [ -d "$AWG_CONF_DIR" ] && cp -r "$AWG_CONF_DIR" "$BACKUP_DIR/amneziawg" 2>/dev/null || true
    [ -d "/etc/wireguard" ] && cp -r /etc/wireguard "$BACKUP_DIR/wireguard" 2>/dev/null || true
    [ -d "$MIHOMO_DIR" ] && cp -r "$MIHOMO_DIR" "$BACKUP_DIR/mihomo" 2>/dev/null || true
    [ -d "$(dirname "$0")/clients-awg" ] && cp -r "$(dirname "$0")/clients-awg" "$BACKUP_DIR/clients-awg" 2>/dev/null || true
    echo "  Бэкап: $BACKUP_DIR"

    # Удаляем старые конфиги
    rm -rf "$AWG_CONF_DIR"
    rm -rf "$MIHOMO_DIR"
    rm -rf "$(dirname "$0")/clients-awg"
    rm -f /etc/systemd/system/mihomo.service
    systemctl daemon-reload

    echo "  Очистка завершена"
else
    read -p "Продолжить? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then exit 1; fi
fi

# ============================================================
# 1. Обновление системы и установка зависимостей
# ============================================================
echo "[1/8] Обновление системы..."
apt update && apt upgrade -y
apt install -y curl wget unzip iptables jq software-properties-common

# ============================================================
# 2. Установка mihomo
# ============================================================
echo "[2/8] Установка mihomo..."
ARCH=$(uname -m)
case $ARCH in
    x86_64)  MIHOMO_ARCH="amd64" ;;
    aarch64) MIHOMO_ARCH="arm64" ;;
    armv7l)  MIHOMO_ARCH="armv7" ;;
    *) echo "Неподдерживаемая архитектура: $ARCH"; exit 1 ;;
esac

MIHOMO_URL=$(curl -s https://api.github.com/repos/MetaCubeX/mihomo/releases/latest \
    | jq -r ".assets[] | select(.name | test(\"mihomo-linux-${MIHOMO_ARCH}-v\")) | select(.name | test(\"gz$\")) | .browser_download_url" \
    | head -1)

if [ -z "$MIHOMO_URL" ]; then
    MIHOMO_URL=$(curl -s https://api.github.com/repos/MetaCubeX/mihomo/releases/latest \
        | jq -r ".assets[] | select(.name | test(\"mihomo-linux-${MIHOMO_ARCH}\")) | select(.name | test(\"gz$\")) | .browser_download_url" \
        | head -1)
fi

echo "Скачиваю: $MIHOMO_URL"
wget -O /tmp/mihomo.gz "$MIHOMO_URL"
gunzip -f /tmp/mihomo.gz
mv /tmp/mihomo /usr/local/bin/mihomo
chmod +x /usr/local/bin/mihomo

echo "Mihomo версия: $(mihomo -v 2>&1 | head -1)"

# ============================================================
# 3. Настройка конфига mihomo
# ============================================================
echo "[3/8] Настройка mihomo..."
mkdir -p "$MIHOMO_DIR"

# config.yaml лежит рядом с install.sh или в родительской папке
if [ -f "$(dirname "$0")/config.yaml" ]; then
    cp "$(dirname "$0")/config.yaml" "$MIHOMO_DIR/config.yaml"
elif [ -f "$(dirname "$0")/../config.yaml" ]; then
    cp "$(dirname "$0")/../config.yaml" "$MIHOMO_DIR/config.yaml"
else
    echo "config.yaml не найден рядом с install.sh"
    exit 1
fi

# Подставляем сгенерированный секрет и URL подписки
sed -i "s|^secret: .*|secret: \"$MIHOMO_SECRET\"|" "$MIHOMO_DIR/config.yaml"
sed -i "s|url: .*# <-- Подставляется автоматически при установке|url: \"$SUBSCRIPTION_URL\"|" "$MIHOMO_DIR/config.yaml"

# Добавляем tun секцию
if ! grep -q "^tun:" "$MIHOMO_DIR/config.yaml"; then
    cat >> "$MIHOMO_DIR/config.yaml" << 'TUNEOF'

# --- TUN РЕЖИМ (для маршрутизации AWG трафика) ---
tun:
  enable: true
  stack: system
  dns-hijack:
    - any:53
  auto-route: false
  auto-detect-interface: true
TUNEOF
    echo "TUN секция добавлена"
fi

# DNS listen уже 1053 в config.yaml (не конфликтует с systemd-resolved)

# ============================================================
# 4. Systemd сервис для mihomo
# ============================================================
echo "[4/8] Создание systemd сервиса mihomo..."
cat > /etc/systemd/system/mihomo.service << EOF
[Unit]
Description=Mihomo Proxy
After=network.target NetworkManager.service systemd-networkd.service

[Service]
Type=simple
ExecStart=/usr/local/bin/mihomo -d $MIHOMO_DIR
Restart=always
RestartSec=3
LimitNOFILE=1048576
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mihomo

# ============================================================
# 5. Установка AmneziaWG
# ============================================================
echo "[5/8] Установка AmneziaWG..."

# Включаем deb-src если нет (нужно для DKMS)
if [ -f /etc/apt/sources.list ] && ! grep -q "^deb-src" /etc/apt/sources.list 2>/dev/null; then
    cp /etc/apt/sources.list /etc/apt/sources.list.bak
    sed -i "s/^# deb-src/deb-src/" /etc/apt/sources.list
fi

apt-get install -y linux-headers-$(uname -r)
add-apt-repository -y ppa:amnezia/ppa
apt-get update
apt-get install -y amneziawg amneziawg-tools

modprobe amneziawg
echo "AmneziaWG установлен"

# ============================================================
# 6. Настройка AmneziaWG
# ============================================================
echo "[6/8] Настройка AmneziaWG..."

mkdir -p "$AWG_CONF_DIR"
mkdir -p "$(dirname "$0")/clients-awg"

# Сохраняем IP сервера для awg-add-client.sh
echo "SERVER_PUBLIC_IP=$SERVER_PUBLIC_IP" > "$AWG_CONF_DIR/server.env"

# Генерация ключей сервера
SERVER_PRIVKEY=$(awg genkey)
SERVER_PUBKEY=$(echo "$SERVER_PRIVKEY" | awg pubkey)
echo "$SERVER_PUBKEY" > "$AWG_CONF_DIR/server_public.key"

# Генерация ключей первого клиента
CLIENT1_PRIVKEY=$(awg genkey)
CLIENT1_PUBKEY=$(echo "$CLIENT1_PRIVKEY" | awg pubkey)

# Конфиг сервера AmneziaWG
cat > "$AWG_CONF_DIR/awg0.conf" << EOF
[Interface]
Address = $AWG_SERVER_IP/24
ListenPort = $AWG_PORT
PrivateKey = $SERVER_PRIVKEY

Jc = $JC
Jmin = $JMIN
Jmax = $JMAX
S1 = $S1
S2 = $S2
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4

PostUp = $AWG_CONF_DIR/postup.sh
PostDown = $AWG_CONF_DIR/postdown.sh

[Peer]
# client1
PublicKey = $CLIENT1_PUBKEY
AllowedIPs = $AWG_CLIENT_IP/32
EOF

# ============================================================
# 7. Скрипты маршрутизации (awg0 → mihomo TPROXY)
# ============================================================
echo "[7/8] Настройка маршрутизации..."

cat > "$AWG_CONF_DIR/postup.sh" << 'POSTUP'
#!/bin/bash
sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv4.conf.all.route_localnet=1 >/dev/null

MAIN_IFACE=$(ip route show default | awk '{print $5}' | head -1)

# NAT для трафика, который mihomo отправляет напрямую (DIRECT)
iptables -t nat -A POSTROUTING -o $MAIN_IFACE -j MASQUERADE

# Таблица маршрутизации для помеченных пакетов (TPROXY)
ip rule add fwmark 1 table 100 2>/dev/null || true
ip route add local 0.0.0.0/0 dev lo table 100 2>/dev/null || true

# TPROXY: перехватываем TCP/UDP от AWG клиентов → mihomo
iptables -t mangle -A PREROUTING -i awg0 -p tcp -j TPROXY --on-port 1181 --tproxy-mark 1
iptables -t mangle -A PREROUTING -i awg0 -p udp ! --dport 53 -j TPROXY --on-port 1181 --tproxy-mark 1

# DNS от AWG клиентов → mihomo DNS (порт 1053, т.к. 53 занят systemd-resolved)
iptables -t nat -A PREROUTING -i awg0 -p udp --dport 53 -j REDIRECT --to-port 1053
iptables -t nat -A PREROUTING -i awg0 -p tcp --dport 53 -j REDIRECT --to-port 1053
POSTUP

cat > "$AWG_CONF_DIR/postdown.sh" << 'POSTDOWN'
#!/bin/bash
MAIN_IFACE=$(ip route show default | awk '{print $5}' | head -1)

iptables -t nat -D POSTROUTING -o $MAIN_IFACE -j MASQUERADE 2>/dev/null
iptables -t mangle -D PREROUTING -i awg0 -p tcp -j TPROXY --on-port 1181 --tproxy-mark 1 2>/dev/null
iptables -t mangle -D PREROUTING -i awg0 -p udp ! --dport 53 -j TPROXY --on-port 1181 --tproxy-mark 1 2>/dev/null
iptables -t nat -D PREROUTING -i awg0 -p udp --dport 53 -j REDIRECT --to-port 1053 2>/dev/null
iptables -t nat -D PREROUTING -i awg0 -p tcp --dport 53 -j REDIRECT --to-port 1053 2>/dev/null

ip rule del fwmark 1 table 100 2>/dev/null
ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null
POSTDOWN

chmod +x "$AWG_CONF_DIR/postup.sh" "$AWG_CONF_DIR/postdown.sh"

# Включаем ip_forward на постоянной основе
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-amneziawg.conf
echo "net.ipv4.conf.all.route_localnet = 1" >> /etc/sysctl.d/99-amneziawg.conf
sysctl -p /etc/sysctl.d/99-amneziawg.conf

# ============================================================
# 8. Конфиг клиента и запуск
# ============================================================
echo "[8/8] Генерация клиентского конфига и запуск..."

cat > "$(dirname "$0")/clients-awg/client1.conf" << EOF
[Interface]
PrivateKey = $CLIENT1_PRIVKEY
Address = $AWG_CLIENT_IP/32
DNS = $CLIENT_DNS

Jc = $JC
Jmin = $JMIN
Jmax = $JMAX
S1 = $S1
S2 = $S2
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4

[Peer]
PublicKey = $SERVER_PUBKEY
Endpoint = $SERVER_PUBLIC_IP:$AWG_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

# Запуск сервисов: сначала mihomo, потом AWG (через systemd)
systemctl start mihomo
sleep 2
systemctl enable --now awg-quick@awg0

echo ""
echo "========================================"
echo " УСТАНОВКА ЗАВЕРШЕНА!"
echo "========================================"
echo ""
echo "Mihomo UI:  http://$SERVER_PUBLIC_IP:1995/ui"
echo "Secret:     $MIHOMO_SECRET"
echo ""
echo "AmneziaWG Endpoint: $SERVER_PUBLIC_IP:$AWG_PORT"
echo "Обфускация: Jc=$JC S1=$S1 S2=$S2"
echo ""
echo "Конфиг клиента: $(dirname "$0")/clients-awg/client1.conf"
echo ""
echo "Для добавления новых клиентов:"
echo "  ./awg-add-client.sh client2"
echo ""
echo "Настройка клиентов:"
echo "  Keenetic:      Импорт .conf (Интернет → Другие подключения → WireGuard)"
echo "  Android/iOS:   AmneziaVPN → импорт .conf"
echo "  Windows/macOS: AmneziaVPN → импорт .conf"
echo ""
echo "Диагностика:"
echo "  ./diagnose.sh"
echo "========================================"
