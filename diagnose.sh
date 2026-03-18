#!/bin/bash

# ============================================================
# Диагностика AmneziaWG + Mihomo (только чтение, без изменений)
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
BOLD='\033[1m'

ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; }
warn() { echo -e "  ${YELLOW}!${NC} $1"; }
header() { echo -e "\n${BOLD}=== $1 ===${NC}"; }

ERRORS=0
WARNINGS=0

# ----------------------------------------------------------
header "1. Сервисы"
# ----------------------------------------------------------

for SVC in mihomo awg-quick@awg0; do
    if systemctl is-active --quiet "$SVC"; then
        ok "$SVC активен"
    else
        fail "$SVC не запущен"
        ((ERRORS++))
    fi
done

# Автозапуск
for SVC in mihomo awg-quick@awg0; do
    if systemctl is-enabled --quiet "$SVC" 2>/dev/null; then
        ok "$SVC в автозапуске"
    else
        fail "$SVC НЕ в автозапуске (не переживёт ребут)"
        ((ERRORS++))
    fi
done

# ----------------------------------------------------------
header "2. Интерфейсы"
# ----------------------------------------------------------

# awg0
if ip link show awg0 &>/dev/null; then
    AWG_IP=$(ip -4 addr show awg0 | grep -oP 'inet \K[0-9.]+')
    ok "awg0: $AWG_IP"
else
    fail "Интерфейс awg0 не найден"
    ((ERRORS++))
fi

# TUN Meta (mihomo)
if ip link show Meta &>/dev/null; then
    ok "Meta (TUN mihomo) активен"
else
    fail "Meta (TUN mihomo) не найден"
    ((ERRORS++))
fi

# ----------------------------------------------------------
header "3. Пиры AmneziaWG"
# ----------------------------------------------------------

PEER_DATA=$(awg show awg0 2>/dev/null)
if [ -z "$PEER_DATA" ]; then
    fail "Не удалось получить данные awg show"
    ((ERRORS++))
else
    PEER_COUNT=$(echo "$PEER_DATA" | grep -c "^peer:")
    ok "Пиров: $PEER_COUNT"

    ONLINE=0
    OFFLINE=0

    # Собираем данные по пирам
    CURRENT_KEY=""
    CURRENT_HS=""
    CURRENT_ALLOWED=""

    while IFS= read -r line; do
        if echo "$line" | grep -q "^peer:"; then
            # Обрабатываем предыдущего пира
            if [ -n "$CURRENT_KEY" ]; then
                SHORT="${CURRENT_KEY:0:12}..."
                if [ -n "$CURRENT_HS" ]; then
                    if echo "$CURRENT_HS" | grep -qE "second|minute"; then
                        echo -e "  ${GREEN}✓${NC} $SHORT ($CURRENT_ALLOWED) — $CURRENT_HS"
                        ((ONLINE++))
                    else
                        echo -e "  ${YELLOW}!${NC} $SHORT ($CURRENT_ALLOWED) — $CURRENT_HS"
                        ((ONLINE++))
                    fi
                else
                    echo -e "  ${RED}✗${NC} $SHORT ($CURRENT_ALLOWED) — нет handshake"
                    ((OFFLINE++))
                fi
            fi
            CURRENT_KEY=$(echo "$line" | awk '{print $2}')
            CURRENT_HS=""
            CURRENT_ALLOWED=""
        fi
        if echo "$line" | grep -q "latest handshake:"; then
            CURRENT_HS=$(echo "$line" | sed 's/.*latest handshake: //')
        fi
        if echo "$line" | grep -q "allowed ips:"; then
            CURRENT_ALLOWED=$(echo "$line" | sed 's/.*allowed ips: //' | sed 's|/32||')
        fi
    done <<< "$PEER_DATA"

    # Последний пир
    if [ -n "$CURRENT_KEY" ]; then
        SHORT="${CURRENT_KEY:0:12}..."
        if [ -n "$CURRENT_HS" ]; then
            if echo "$CURRENT_HS" | grep -qE "second|minute"; then
                echo -e "  ${GREEN}✓${NC} $SHORT ($CURRENT_ALLOWED) — $CURRENT_HS"
                ((ONLINE++))
            else
                echo -e "  ${YELLOW}!${NC} $SHORT ($CURRENT_ALLOWED) — $CURRENT_HS"
                ((ONLINE++))
            fi
        else
            echo -e "  ${RED}✗${NC} $SHORT ($CURRENT_ALLOWED) — нет handshake"
            ((OFFLINE++))
        fi
    fi

    echo -e "  Онлайн: $ONLINE, оффлайн: $OFFLINE"
    if [ "$OFFLINE" -gt 0 ]; then
        ((WARNINGS++))
    fi
fi

# ----------------------------------------------------------
header "4. Порты mihomo"
# ----------------------------------------------------------

declare -A EXPECTED_PORTS=(
    [1053]="DNS"
    [1181]="TPROXY"
    [1995]="UI (external-controller)"
    [7890]="HTTP proxy"
    [7891]="SOCKS5 proxy"
    [1080]="Mixed port"
)

for PORT in 1053 1181 1995 7890 7891 1080; do
    DESC="${EXPECTED_PORTS[$PORT]}"
    if ss -tlnp 2>/dev/null | grep -q ":${PORT} " || ss -ulnp 2>/dev/null | grep -q ":${PORT} "; then
        ok "$PORT ($DESC)"
    else
        fail "$PORT ($DESC) — не слушает"
        ((ERRORS++))
    fi
done

# ----------------------------------------------------------
header "5. Системные параметры"
# ----------------------------------------------------------

FWD=$(sysctl -n net.ipv4.ip_forward 2>/dev/null)
if [ "$FWD" = "1" ]; then
    ok "ip_forward = 1"
else
    fail "ip_forward = $FWD"
    ((ERRORS++))
fi

ROUTE_LOCAL=$(sysctl -n net.ipv4.conf.all.route_localnet 2>/dev/null)
if [ "$ROUTE_LOCAL" = "1" ]; then
    ok "route_localnet = 1"
else
    fail "route_localnet = $ROUTE_LOCAL"
    ((ERRORS++))
fi

# Проверяем что настройки переживут ребут
if [ -f /etc/sysctl.d/99-amneziawg.conf ]; then
    ok "sysctl.d/99-amneziawg.conf существует"
else
    fail "sysctl.d/99-amneziawg.conf не найден (настройки не переживут ребут)"
    ((ERRORS++))
fi

# ----------------------------------------------------------
header "6. iptables правила"
# ----------------------------------------------------------

# TPROXY TCP
if iptables -t mangle -C PREROUTING -i awg0 -p tcp -j TPROXY --on-port 1181 --tproxy-mark 1 2>/dev/null; then
    ok "TPROXY TCP awg0 → 1181"
else
    fail "Нет TPROXY TCP"
    ((ERRORS++))
fi

# TPROXY UDP
if iptables -t mangle -C PREROUTING -i awg0 -p udp ! --dport 53 -j TPROXY --on-port 1181 --tproxy-mark 1 2>/dev/null; then
    ok "TPROXY UDP awg0 → 1181"
else
    fail "Нет TPROXY UDP"
    ((ERRORS++))
fi

# DNS REDIRECT
if iptables -t nat -C PREROUTING -i awg0 -p udp --dport 53 -j REDIRECT --to-port 1053 2>/dev/null; then
    ok "DNS REDIRECT UDP → 1053"
else
    fail "Нет DNS REDIRECT UDP → 1053"
    ((ERRORS++))
fi

if iptables -t nat -C PREROUTING -i awg0 -p tcp --dport 53 -j REDIRECT --to-port 1053 2>/dev/null; then
    ok "DNS REDIRECT TCP → 1053"
else
    fail "Нет DNS REDIRECT TCP → 1053"
    ((ERRORS++))
fi

# MASQUERADE
MAIN_IFACE=$(ip route show default | awk '{print $5}' | head -1)
if iptables -t nat -C POSTROUTING -o "$MAIN_IFACE" -j MASQUERADE 2>/dev/null; then
    ok "MASQUERADE на $MAIN_IFACE"
else
    fail "Нет MASQUERADE на $MAIN_IFACE"
    ((ERRORS++))
fi

# ----------------------------------------------------------
header "7. Таблица маршрутизации TPROXY"
# ----------------------------------------------------------

if ip rule show | grep -q "fwmark 0x1 lookup 100"; then
    ok "ip rule fwmark 1 → table 100"
else
    fail "Нет ip rule для fwmark 1"
    ((ERRORS++))
fi

TABLE100=$(ip route show table 100 2>/dev/null)
if echo "$TABLE100" | grep -qE "local (default|0\.0\.0\.0/0) dev lo"; then
    ok "table 100: local default dev lo"
else
    fail "Нет маршрута в table 100"
    ((ERRORS++))
fi

# ----------------------------------------------------------
header "8. DNS"
# ----------------------------------------------------------

# Проверяем что mihomo DNS резолвит
DNS_TEST=$(dig +short +timeout=3 google.com -p 1053 @127.0.0.1 2>/dev/null | head -1)
if [ -n "$DNS_TEST" ]; then
    ok "mihomo DNS (1053): google.com → $DNS_TEST"
else
    fail "mihomo DNS (1053) не отвечает"
    ((ERRORS++))
fi

# ----------------------------------------------------------
header "9. Mihomo конфиг"
# ----------------------------------------------------------

CONF="/etc/mihomo/config.yaml"
if [ -f "$CONF" ]; then
    ok "Конфиг: $CONF"
    # Проверяем DNS порт в конфиге
    DNS_PORT=$(grep "listen:" "$CONF" | grep -oP ':\K[0-9]+')
    if [ "$DNS_PORT" = "1053" ]; then
        ok "DNS listen порт: 1053"
    else
        fail "DNS listen порт: $DNS_PORT (должен быть 1053)"
        ((ERRORS++))
    fi
else
    fail "Конфиг не найден: $CONF"
    ((ERRORS++))
fi

if [ -f "/etc/mihomo/proxy-providers/subscription.yaml" ]; then
    PROXY_COUNT=$(grep -c "name:" /etc/mihomo/proxy-providers/subscription.yaml 2>/dev/null || echo 0)
    ok "Подписка: $PROXY_COUNT прокси"
else
    warn "Файл подписки не найден"
    ((WARNINGS++))
fi

# ----------------------------------------------------------
header "10. Счётчики трафика"
# ----------------------------------------------------------

echo -e "  ${BOLD}TPROXY (mangle):${NC}"
iptables -t mangle -L PREROUTING -n -v 2>/dev/null | grep awg0 | while IFS= read -r line; do
    PKTS=$(echo "$line" | awk '{print $1}')
    BYTES=$(echo "$line" | awk '{print $2}')
    PROTO=$(echo "$line" | awk '{print $4}')
    echo -e "    $PROTO: $PKTS пакетов / $BYTES байт"
done

echo -e "  ${BOLD}DNS REDIRECT (nat):${NC}"
iptables -t nat -L PREROUTING -n -v 2>/dev/null | grep awg0 | while IFS= read -r line; do
    PKTS=$(echo "$line" | awk '{print $1}')
    BYTES=$(echo "$line" | awk '{print $2}')
    PROTO=$(echo "$line" | awk '{print $4}')
    echo -e "    $PROTO: $PKTS пакетов / $BYTES байт"
done

# ----------------------------------------------------------
header "11. Логи mihomo"
# ----------------------------------------------------------

MIHOMO_ERRORS=$(journalctl -u mihomo --no-pager -n 100 --since "1 hour ago" 2>/dev/null | grep -iE "error|fatal|panic|fail" | tail -5)
if [ -n "$MIHOMO_ERRORS" ]; then
    warn "Ошибки за последний час:"
    echo "$MIHOMO_ERRORS" | while IFS= read -r line; do
        echo -e "    $line"
    done
    ((WARNINGS++))
else
    ok "Ошибок нет (последний час)"
fi

# ----------------------------------------------------------
header "ИТОГО"
# ----------------------------------------------------------

if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    echo -e "\n  ${GREEN}Всё в порядке${NC}\n"
elif [ $ERRORS -eq 0 ]; then
    echo -e "\n  ${YELLOW}Предупреждений: $WARNINGS${NC}\n"
else
    echo -e "\n  ${RED}Ошибок: $ERRORS${NC}, предупреждений: $WARNINGS\n"
fi
