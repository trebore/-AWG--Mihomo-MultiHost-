#!/bin/bash

# ============================================================
# Добавление нового AmneziaWG клиента
# Использование: ./awg-add-client.sh <имя_клиента>
# ============================================================

if [ -z "$1" ]; then
    echo "Использование: $0 <имя_клиента>"
    exit 1
fi

CLIENT_NAME="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLIENTS_DIR="$SCRIPT_DIR/clients-awg"
AWG_CONF="/etc/amnezia/amneziawg/awg0.conf"

AWG_PORT=$(grep "^ListenPort" "$AWG_CONF" | awk '{print $3}')

# Читаем IP сервера из server.env (сохраняется при установке)
AWG_CONF_DIR=$(dirname "$AWG_CONF")
if [ -f "$AWG_CONF_DIR/server.env" ]; then
    source "$AWG_CONF_DIR/server.env"
else
    echo "Файл server.env не найден. Введите внешний IP сервера:"
    read -r SERVER_PUBLIC_IP
fi
SERVER_PUBKEY=$(cat /etc/amnezia/amneziawg/server_public.key)

# Параметры обфускации — берём из серверного конфига
JC=$(grep "^Jc" "$AWG_CONF" | head -1 | awk '{print $3}')
JMIN=$(grep "^Jmin" "$AWG_CONF" | head -1 | awk '{print $3}')
JMAX=$(grep "^Jmax" "$AWG_CONF" | head -1 | awk '{print $3}')
S1=$(grep "^S1" "$AWG_CONF" | head -1 | awk '{print $3}')
S2=$(grep "^S2" "$AWG_CONF" | head -1 | awk '{print $3}')
H1=$(grep "^H1" "$AWG_CONF" | head -1 | awk '{print $3}')
H2=$(grep "^H2" "$AWG_CONF" | head -1 | awk '{print $3}')
H3=$(grep "^H3" "$AWG_CONF" | head -1 | awk '{print $3}')
H4=$(grep "^H4" "$AWG_CONF" | head -1 | awk '{print $3}')

echo "Добавляю клиента: $CLIENT_NAME"

# Определяем следующий IP — считаем количество [Peer] секций + 1
PEER_COUNT=$(grep -c '^\[Peer\]' "$AWG_CONF")
NEXT_IP=$((PEER_COUNT + 2))
CLIENT_IP="10.10.0.$NEXT_IP"

echo "IP клиента: $CLIENT_IP"
echo "Сервер: $SERVER_PUBLIC_IP:$AWG_PORT"

# Генерация ключей
mkdir -p "$CLIENTS_DIR"
PRIVKEY=$(awg genkey)
PUBKEY=$(echo "$PRIVKEY" | awg pubkey)

echo "Ключи сгенерированы"

# Добавляем пир в серверный конфиг
cat >> "$AWG_CONF" << EOF

[Peer]
# $CLIENT_NAME
PublicKey = $PUBKEY
AllowedIPs = $CLIENT_IP/32
EOF

echo "Пир добавлен в awg0.conf"

# Применяем конфиг без перезапуска
awg set awg0 peer "$PUBKEY" allowed-ips "$CLIENT_IP/32"

echo "Пир активирован в AmneziaWG"

# Генерируем клиентский конфиг
cat > "$CLIENTS_DIR/${CLIENT_NAME}.conf" << EOF
[Interface]
PrivateKey = $PRIVKEY
Address = $CLIENT_IP/32
DNS = 10.10.0.1

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

echo ""
echo "========================================"
echo "Клиент '$CLIENT_NAME' добавлен!"
echo "IP: $CLIENT_IP"
echo "Конфиг: $CLIENTS_DIR/${CLIENT_NAME}.conf"
echo "========================================"
echo ""
echo "Импорт конфига:"
echo "  Keenetic:      Интернет → Другие подключения → WireGuard → Загрузить"
echo "  Android/iOS:   AmneziaVPN → импорт .conf"
echo "  Windows/macOS: AmneziaVPN → импорт .conf"
echo ""
cat "$CLIENTS_DIR/${CLIENT_NAME}.conf"
