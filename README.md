<p align="center">
  <img src="https://img.shields.io/badge/AmneziaWG-obfuscated%20VPN-blueviolet?style=for-the-badge" alt="AmneziaWG"/>
  <img src="https://img.shields.io/badge/Mihomo-smart%20routing-blue?style=for-the-badge" alt="Mihomo"/>
  <img src="https://img.shields.io/badge/Ubuntu-22.04%20%7C%2024.04-orange?style=for-the-badge" alt="Ubuntu"/>
</p>

# AWG + Mihomo MultiHost

VPN-сервер с обфускацией и умной маршрутизацией трафика по сервисам.

- **AmneziaWG** — обфусцированный WireGuard, обходит блокировки DPI
- **Mihomo** — прокси-ядро с правилами: YouTube через один прокси, Telegram через другой, RU-трафик напрямую и т.д.
- **Один скрипт** — полная установка за 2-5 минут, переустановка с бэкапом, диагностика

> Проект полезен? Внизу есть [крипто-кошельки](#-поддержать-проект) — буду рад кофе :)

---

# Быстрый старт

Для тех, кто хочет просто поставить и не вникать.

## Что нужно заранее

- Сервер с Ubuntu 22.04 или 24.04 (чистый, root доступ)
- Открытый порт **UDP/443** в файрволе провайдера / security group
- URL подписки на прокси (получаете у провайдера прокси)
- Внешний IP адрес сервера

## Шаг 1. Подключиться к серверу

```bash
ssh root@IP_ВАШЕГО_СЕРВЕРА
```

## Шаг 2. Скачать файлы

```bash
git clone https://github.com/trebore/-AWG--Mihomo-MultiHost-.git /root/awg-mihomo
cd /root/awg-mihomo
chmod +x install.sh awg-add-client.sh diagnose.sh
```

## Шаг 3. Запустить установку

```bash
./install.sh
```

Скрипт спросит:
1. **Внешний IP сервера** — тот IP, по которому вы подключались через SSH
2. **URL подписки на прокси** — ссылка от провайдера прокси

Дальше всё автоматически. Установка занимает 2-5 минут.

## Шаг 4. Забрать конфиг клиента

После установки скрипт покажет путь к файлу. Посмотреть его:

```bash
cat clients-awg/client1.conf
```

Скопируйте содержимое или скачайте файл на своё устройство.

## Шаг 5. Подключить устройство

**Телефон (Android / iOS):**
1. Установить [AmneziaVPN](https://amnezia.org) из магазина приложений
2. Нажать **+** → **Из файла** → выбрать скачанный `.conf`
3. Включить VPN

**Роутер Keenetic (прошивка 4.3.4+):**
1. Открыть веб-интерфейс роутера
2. **Интернет → Другие подключения → WireGuard**
3. **Загрузить из файла** → выбрать `.conf`
4. Включить подключение

**Компьютер (Windows / macOS):**
1. Скачать [AmneziaVPN](https://amnezia.org)
2. Импортировать `.conf` файл
3. Подключиться

## Шаг 6. Добавить ещё клиентов

```bash
./awg-add-client.sh имя_клиента
```

Каждый клиент получает свой конфиг в `clients-awg/имя_клиента.conf`.

## Шаг 7. Проверить что всё работает

```bash
./diagnose.sh
```

Все пункты должны быть зелёные.

## Управление через браузер

Mihomo имеет веб-интерфейс для управления правилами и мониторинга:

```
http://IP_СЕРВЕРА:1995/ui
```

Секрет для входа выводится при установке.

---

# Подробная документация

Для тех, кто хочет понимать как всё устроено.

## Схема работы

```
Клиент (телефон/ПК/Keenetic)
    │
    ▼ AmneziaWG (UDP :443, обфускация)
    │
    ▼ awg0 (10.10.0.0/24)
    │
    ├─► iptables TPROXY → mihomo (:1181) — весь TCP/UDP трафик
    └─► iptables REDIRECT → mihomo (:1053) — DNS запросы
    │
    ▼ mihomo применяет правила из config.yaml
    │
    ▼ Интернет (DIRECT / через прокси из подписки)
```

Клиент подключается к серверу по AmneziaWG (выглядит как обычный QUIC/HTTP3
трафик на порту 443). Весь трафик клиента перехватывается через iptables TPROXY
и отправляется в mihomo. Mihomo решает по правилам из `config.yaml` — отправить
трафик напрямую, через прокси, или заблокировать (реклама).

DNS запросы клиентов перенаправляются на порт 1053 (mihomo DNS) вместо
стандартного 53, т.к. на Ubuntu порт 53 занят systemd-resolved.

## Что делает install.sh

1. Обновляет систему и ставит зависимости
2. Скачивает и устанавливает mihomo (последняя версия с GitHub)
3. Копирует `config.yaml` → `/etc/mihomo/config.yaml`
4. Подставляет сгенерированный секрет и URL подписки в конфиг
5. Добавляет TUN-секцию для перехвата DNS
6. Создаёт systemd сервис для mihomo
7. Устанавливает AmneziaWG (PPA + DKMS модуль ядра)
8. Генерирует случайные параметры обфускации (уникальные для сервера)
9. Генерирует ключи сервера и первого клиента
10. Создаёт postup.sh/postdown.sh с правилами iptables
11. Включает ip_forward и route_localnet (переживает ребут)
12. Запускает mihomo и awg0, включает автозапуск

При повторном запуске скрипт обнаружит предыдущую установку, предложит
переустановку, сделает бэкап в `/root/backup-vpn-ДАТА/` и поставит всё заново.

## Файлы на сервере после установки

```
/etc/amnezia/amneziawg/
├── awg0.conf          — конфиг сервера AWG (ключи, пиры, обфускация)
├── postup.sh          — iptables правила при поднятии awg0
├── postdown.sh        — очистка iptables при остановке awg0
├── server_public.key  — публичный ключ сервера
└── server.env         — внешний IP сервера

/etc/mihomo/
├── config.yaml        — конфиг mihomo (правила, DNS, прокси-группы)
└── proxy-providers/
    └── subscription.yaml  — прокси из подписки (скачивается автоматически)

/etc/sysctl.d/
└── 99-amneziawg.conf  — ip_forward и route_localnet

/etc/systemd/system/
└── mihomo.service     — systemd сервис mihomo
```

## Порты

| Порт | Протокол | Назначение | Открывать наружу? |
|------|----------|------------|-------------------|
| 443  | UDP      | AmneziaWG (VPN)          | Да |
| 1995 | TCP      | Mihomo UI (zashboard)    | По желанию |
| 1053 | UDP      | Mihomo DNS (fake-ip)     | Нет |
| 1181 | TCP/UDP  | Mihomo TPROXY            | Нет |
| 7890 | TCP      | Mihomo HTTP proxy        | Нет |
| 7891 | TCP/UDP  | Mihomo SOCKS5 proxy      | Нет |
| 1080 | TCP/UDP  | Mihomo mixed port        | Нет |

## Параметры обфускации

Генерируются случайно при каждой установке. Попадают в конфиги сервера
и всех клиентов автоматически.

```
Jc      — количество мусорных пакетов при хендшейке (4-12)
Jmin    — мин. размер мусорного пакета в байтах (40-60)
Jmax    — макс. размер мусорного пакета в байтах (70-120)
S1      — padding init-пакета хендшейка (15-150)
S2      — padding response-пакета хендшейка (15-150)
H1-H4   — подмена заголовков типов пакетов (рандомные большие числа)
```

**S1, S2, H1-H4 должны совпадать** на сервере и всех клиентах.
Jc, Jmin, Jmax могут отличаться.

H1-H4 — главная защита от DPI. Стандартный WireGuard использует
фиксированные заголовки (1, 2, 3, 4), которые легко детектить.
AWG заменяет их на случайные значения, уникальные для каждого сервера.

## Управление сервисами

```bash
# Статус
systemctl status mihomo
systemctl status awg-quick@awg0

# Перезапуск
systemctl restart mihomo
systemctl restart awg-quick@awg0

# Логи
journalctl -u mihomo -f
journalctl -u awg-quick@awg0 -f

# Показать подключённых клиентов и трафик
awg show awg0
```

## Диагностика

```bash
./diagnose.sh
```

Проверяет 11 пунктов:
1. Сервисы (mihomo, awg-quick@awg0) и автозапуск
2. Интерфейсы (awg0, Meta TUN)
3. Пиры — кто онлайн, кто нет
4. Порты mihomo
5. Системные параметры (ip_forward, route_localnet, sysctl файл)
6. iptables правила (TPROXY, DNS REDIRECT, MASQUERADE)
7. Таблица маршрутизации TPROXY (fwmark, table 100)
8. DNS резолвинг через mihomo
9. Конфиг mihomo и подписка
10. Счётчики трафика iptables
11. Ошибки в логах mihomo

---

# Решение проблем

## Сайты не открываются, но Telegram/Instagram работают

Проблема в DNS. Telegram подключается по IP, а сайтам нужен DNS.

```bash
# Mihomo слушает DNS?
ss -ulnp | grep :1053

# iptables REDIRECT на месте?
iptables -t nat -L PREROUTING -n -v | grep 1053
```

Почему порт 1053, а не 53: на Ubuntu systemd-resolved занимает порт 53.
Mihomo слушает DNS на 1053, iptables перенаправляет DNS клиентов
с порта 53 на 1053. Клиенты об этом не знают — у них DNS = 10.10.0.1
(стандартный порт 53).

## Клиент не подключается (нет handshake)

```bash
awg show awg0
```

Если у клиента нет `latest handshake` — пакеты не доходят до сервера.

Проверить:
- Открыт ли UDP/443 на файрволе сервера
- Правильный ли Endpoint и PublicKey в клиентском конфиге
- Совпадают ли параметры обфускации (S1, S2, H1-H4) с сервером
- Если провайдер клиента блокирует **весь UDP** — AmneziaWG не поможет,
  нужен TCP-туннель (wstunnel)

## После ребута сервера не работает

```bash
./diagnose.sh
```

Скрипт покажет что именно сломалось. Типичные причины:

**Сервисы не в автозапуске:**
```bash
systemctl enable mihomo
systemctl enable awg-quick@awg0
```

**ip_forward сбросился** (нет sysctl файла):
```bash
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-amneziawg.conf
echo "net.ipv4.conf.all.route_localnet = 1" >> /etc/sysctl.d/99-amneziawg.conf
sysctl -p /etc/sysctl.d/99-amneziawg.conf
```

## apt update не работает на сервере

Mihomo TUN перехватывает трафик сервера и DNS резолвит в fake-ip.
Временно остановите mihomo:

```bash
systemctl stop mihomo
apt update && apt upgrade -y
systemctl start mihomo
```

## Нужно переустановить с нуля

Просто запустите `install.sh` повторно. Скрипт обнаружит старую установку,
предложит переустановку, сделает бэкап и поставит всё заново с новыми ключами
и параметрами обфускации.

## Нужно сменить IP сервера (без переустановки)

```bash
echo "SERVER_PUBLIC_IP=НОВЫЙ_IP" > /etc/amnezia/amneziawg/server.env
```

После этого пересоздайте конфиги клиентов через `awg-add-client.sh`.

---

## Файлы репозитория

```
config.yaml          — конфиг mihomo (правила маршрутизации, DNS, прокси-группы)
install.sh           — установка с нуля (mihomo + AmneziaWG)
awg-add-client.sh    — добавление нового клиента
diagnose.sh          — диагностика сервера (11 проверок)
README.md            — эта документация
```

---

<p align="center">
  <br>
<a id="-поддержать-проект"></a>
  Если проект оказался полезен — можете угостить меня кофе :)
  <br><br>
</p>

<table align="center">
  <tr>
    <th>Сеть</th>
    <th>Адрес</th>
  </tr>
  <tr>
    <td><b>BTC</b> (Bitcoin)</td>
    <td><code>1EynujGimMJY7WWhY85z1YGHEAgNKxweph</code></td>
  </tr>
  <tr>
    <td><b>ETH</b> (Ethereum)</td>
    <td rowspan="5"><code>0x184c22edd42b295e338e093787c3267599e7d144</code></td>
  </tr>
  <tr>
    <td><b>USDT</b> (ERC-20)</td>
  </tr>
  <tr>
    <td><b>USDT</b> (Polygon)</td>
  </tr>
  <tr>
    <td><b>USDT</b> (BSC / BEP-20)</td>
  </tr>
  <tr>
    <td><b>POL</b> (Polygon)</td>
  </tr>
  <tr>
    <td><b>SOL</b> (Solana)</td>
    <td><code>9GBnTDz2huTXRjvTEVfLsnsVVVST8w2trBUy6EVziMwd</code></td>
  </tr>
  <tr>
    <td><b>TON</b> (Toncoin)</td>
    <td><code>UQAF4g2t3tWhVH25YTzAEoUrFqgQqrugXjs5J4Y8p4planBa</code></td>
  </tr>
  <tr>
    <td><b>USDT</b> (TRC-20 / Tron)</td>
    <td><code>TFZ15F2LkPp8MqJqQHNGEVRTehgDGXJ4gV</code></td>
  </tr>
</table>

<p align="center">
  <br>
  <sub>Спасибо за поддержку!</sub>
</p>
