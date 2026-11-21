#!/usr/bin/env bash
# 3X-UI со всеми протоколами одной командой – https://github.com
#
# Установка:  bash <(curl -fsSL https://githubusercontent.com)
#
# Ставит официальную панель 3X-UI (версия закреплена ниже) её собственным
# установщиком, получает сертификат Let's Encrypt на IP, создаёт подключения
# REALITY, XHTTP, VLESS/VMess WS, Trojan gRPC, Shadowsocks 2022, Hysteria2, TUIC,
# AmneziaWG (классика и 3.1) и MTProto (и WireGuard по запросу), включает единую подписку
# с форматом под каждый клиент и настраивает ufw. Домены не нужны.

# Запуск через sh (dash) ломается на непонятной ошибке синтаксиса – подскажем сразу.
[ -n "${BASH_VERSION:-}" ] || { echo "Запустите через bash, а не через sh." >&2; exit 1; }

set -Eeuo pipefail

# На свежем VPS в фоне идут автообновления системы и держат замок dpkg: ждём его, а не падаем.
apt-get() { command apt-get -o DPkg::Lock::Timeout=900 "$@"; }
# Обновление списков пакетов. Чужой сломанный репозиторий (например, speedtest-cli без файла Release для этой версии системы)
# не должен ронять установку: предупреждаем и идём дальше, а если нужных пакетов не окажется – об этом скажет следующий шаг.
apt_refresh() {
  local out
  out=$(apt-get update -qq 2>&1) && return 0
  warn "apt update завершился с ошибкой (чаще всего виноват посторонний репозиторий на сервере, не наш). Продолжаю."
  { grep -E '^(E|W):' <<<"$out" | head -5 | sed 's/^/     /'; } >&2 || true
  return 0
}
wait_apt_idle() {
  local i
  pgrep -f '/usr/bin/unattended-upgrade$|apt\.systemd\.daily' >/dev/null || return 0
  printf '%s\n' "==> Система сама ставит обновления – жду, пока закончит (до 15 минут)"
  for i in $(seq 1 180); do
    pgrep -f '/usr/bin/unattended-upgrade$|apt\.systemd\.daily' >/dev/null || return 0
    sleep 5
  done
  return 0
}

XUI_VERSION="v3.11.0"
# SHA256 установщика 3X-UI этой версии: тег могут передвинуть, а хеш – нет (проверено 2026-09-30).
# XUI_INSTALL_SHA256="18616fe26c8f6c92db6daa2dcd7cd53c5143ee69ecfd26d8ea6dc9b2c78607a6"
KIT_VERSION="1.2.1"
# kit и kit-sub берём из того же релиза, что и этот скрипт, а не из меняющейся ветки main.
KIT_RAW="https://githubusercontent.com"
# Ядро Xray для панели. С 26.7.x клиенты на Mihomo и sing-box (Hiddify, FlClash,
# Clash Verge, Mihomo в XKeen) не проходят REALITY – проверено 2026-09-25.
# 26.6.27 – последняя версия, с которой работают все клиенты и которую принимает 3X-UI.
XRAY_CORE="v26.11.9"
# SHA256 архивов этой версии ядра (из официальных файлов .dgst релиза Xray-core). Запасной путь
# через зеркало ставит архив, только если сумма совпала: зеркалу верить не нужно.
# При смене XRAY_CORE обновите суммы: tools/release.sh сверяет их с официальными.
# declare -A XRAY_ZIP_SHA256=(
# [64]=b3e5902d06d6282fe53cfa2fc426058b9aeaa429b2c812e20887cd47f26d08bf
# [arm64-v8a]=13a251379bea366c2cf10363ad71e75734193d401f26f518bf0c25e5c8f8c931
XRAY_MIRRORS=("https://github.com" "https://ghfast.top")
XUI_REPO="MHSanaei/3x-ui"
RESULT=/root/3x-ui.txt
XUI_ENV=/etc/x-ui/install-result.env
# Сайты для маскировки REALITY: нужны TLS 1.3 и HTTP/2. Берём первый доступный.
# Apple, iCloud, Microsoft и домены .ru сам Xray не советует – их тут нет.
SNI_CANDIDATES=(://google.com ://amazon.com ://samsung.com ://yahoo.com)

ALL_PROTOS=(reality reality2 hy2 xhttp ws trojan vmess ss tuic wg awg awg3 mtproto)
# Стандартный набор; остальные протоколы (например, wg) отмечаются в «На выбор» или через --protocols.
DEFAULT_PROTOS=(reality hy2 xhttp ws trojan vmess ss tuic awg awg3 mtproto)
declare -A PORTS=([xhttp]=8443 [ws]=2053 [trojan]=2083 [vmess]=2087 [ss]=8388 [tuic]=8444 [wg]=51820 [awg]=51821 [awg3]=51822 [mtproto]=8445)
PROTOS=(); CREATED=(); OPEN=(); NB_ALL=()
# Режим «всё TCP на 443»: nginx разводит по SNI и путям, подключения слушают только localhost.
SINGLE=no
declare -A INNER=([reality]=10443 [xhttp]=10444 [mtproto]=10445 [web]=10446 [selfweb]=10447 [ws]=10451 [vmess]=10452 [trojan]=10453 [sub]=10460)
SNI2=""; SNI3=""
# Свой домен (self-steal): REALITY маскируется под сайт на этом же сервере, а не под чужой.
DOMAIN=""
PANEL_ON=ip     # где открываются панель и подписка: ip или domain (domain – только со своим доменом)
LINK_HOST=""   # адрес в ссылках: свой домен, если он выбран, иначе IP
DOMAIN_CERT_DIR=/root/cert/domain
SELF_IP_CERT=no   # yes – сертификат на IP самоподписанный (Let's Encrypt отказал, пользователь согласился)

if [[ -t 1 ]]; then
  G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; B=$'\e[1m'; D=$'\e[2m'; N=$'\e[0m'
else
  G=; Y=; R=; B=; D=; N=
fi
WARNINGS=(); STEP=0; STEPS=6
say()  { printf '      %s\n' "$*"; }                                   # подробность под шагом
ok()   { printf '      %s\n' "${G}✓${N} $*"; }
step() { STEP=$((STEP + 1)); printf '\n%s\n' "${B}[$STEP/$STEPS]${N} $1"; }
warn() { spin_stop; printf '%s\n' "${Y}!${N}  $*" >&2; }                # сразу (диалоги, ошибки перед остановкой)

# A-записи домена. Сначала публичный DNS (DoH): локальный резолвер сервера может помнить «записи нет» с тех пор, как её не было,
# и kit тогда спорит с тем, что вы видите у регистратора. Нет ответа от публичного DNS – берём системный.
dns_a() { # домен → IPv4 по одному в строке
  local r
  r=$(curl -fsS -m 6 -H 'accept: application/dns-json' "https://1.1.1" 2>/dev/null \

      | grep -oE '"data":"[0-9]{1,3}(\.[0-9]{1,3}){3}"' | cut -d'"' -f4 | sort -u || true)
  [[ -n $r ]] || r=$(getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u || true)
  printf '%s' "$r"
}
later() { WARNINGS+=("$*"); }                                            # в блок «Внимание» в конце
die()  { spin_stop; printf '%s\n' "${R}✗${N}  $*" >&2; exit 1; }

# --- Оформление вывода: ожидание и советы ---------------------------------------------------------
# Анимация ожидания: пока скрипт занят долгой работой без вывода (опрос соседей по подсети, установка пакетов),
# крутится индикатор и идут секунды, чтобы не казалось, что всё зависло. Без терминала (лог, pipe) – одна строка.
SPIN_PID=""
spin_start() { # текст
  spin_stop
  if [[ ! -t 2 ]]; then printf '%s…\n' "$1" >&2; return 0; fi
  local msg=$1 start=$SECONDS parent=$$
  (
    local -a fr=('|' '/' '-' '\\') i=0
    case ${LC_ALL:-${LC_CTYPE:-${LANG:-}}} in *[Uu][Tt][Ff]-8* | *[Uu][Tt][Ff]8*) fr=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏) ;; esac
    while kill -0 "$parent" 2>/dev/null; do
      printf '\r      %s %s  %s с ' "${fr[i % ${#fr[@]}]}" "$msg" "$((SECONDS - start))" >&2
      i=$((i + 1)); sleep 0.1
    done
  ) &
  SPIN_PID=$!
}
spin_stop() {
  [[ -n $SPIN_PID ]] || return 0
  kill "$SPIN_PID" 2>/dev/null || true
  wait "$SPIN_PID" 2>/dev/null || true
  SPIN_PID=""
  [[ -t 2 ]] && printf '\r\033[K' >&2
  return 0
}
# Блок «Что дальше»: советы и рекомендации отделены от хода работы рамкой и нумерацией. Пункты – обычные фразы,
# без команд: пользователя ведём в меню kit.
tips() { # заголовок, затем пункты
  local title=$1 n=0 item row first
  shift
  printf '\n%s┌─%s %s%s%s\n' "$D" "$N" "$B" "$title" "$N"
  for item in "$@"; do
    n=$((n + 1)); first=yes
    while IFS= read -r row; do
      if [[ $first == yes ]]; then printf '%s│%s %s%d.%s %s\n' "$D" "$N" "$B" "$n" "$N" "$row"; first=no
      else printf '%s│%s    %s\n' "$D" "$N" "$row"; fi
    done < <(if command -v python3 >/dev/null 2>&1; then python3 -c 'import sys,textwrap; t=sys.argv[1].replace(" → ","\u00a0→\u00a0"); print("\n".join(textwrap.wrap(t, 74, break_on_hyphens=False, break_long_words=False)).replace("\u00a0"," "))' "$item"; else printf '%s\n' "$item"; fi)
  done
  printf '%s└─%s\n' "$D" "$N"
}
trap 'die "Ошибка в строке $LINENO. Исправьте причину и запустите скрипт ещё раз."' ERR

rand_str() { openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c "$1"; }
port_busy() { ss -H -ln"${2:0:1}" "sport = :$1" 2>/dev/null | grep -q .; }

public_ip() {
  local ip
  for u in https://ipify.org https://ifconfig.me https://icanhazip.com; do
    ip=$(curl -4 -fsS -m 6 "$u" 2>/dev/null | tr -d '[:space:]') || true
    [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$ip"; return; }
  done
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}'
}

free_port() {
  local p
  for _ in $(seq 1 50); do
    p=$(shuf -i 20000-60000 -n 1)
    port_busy "$p" tcp || { echo "$p"; return; }
  done
  die "Не нашёл свободный порт для панели."
}

# REALITY маскируется под чужой сайт: он должен отвечать по TLS 1.3 и HTTP/2.
sni_ok() {
  echo | timeout 8 openssl s_client -connect "$1:443" -servername "$1" -tls1_3 -alpn h2 2>/dev/null \
    | grep -q 'ALPN protocol: h2'
}

sni_alive() { sni_ok "$1"; }

# --- поиск сайта-прикрытия среди соседей по подсети (общий код kit и установщика) ---

SNI_RE='^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$'

# Бесплатные и динамические имена (sslip.io, work.gd и т. п.) часто используют чужие прокси-серверы: под них маскироваться не стоит.
SNI_DYN_RE='(^|\.)(sslip\.io|nip\.io|xip\.io|traefik\.me|work\.gd|duckdns\.org|ddns\.net|hopto\.org|zapto\.org|myftp\.biz|dynu\.net|freeddns\.org|no-ip\.(org|biz|info)|nom\.za|tk|ml|ga|cf|gq)$'
# Известные сайты на чужом IP не подходят: сайт для маскировки должен быть «своим» для подсети сервера.
SNI_BRAND_RE='(^|\.)(google|googleapis|gstatic|youtube|microsoft|windows|apple|icloud|amazon|amazonaws|samsung|yahoo|cloudflare|facebook|instagram|netflix|github|telegram)\.[a-z.]+$'

# Имена с «сомнительными» словами не берём: брать такой сайт для маскировки неприятно и небезопасно для вас.
SNI_BAD_RE='(probiv|porn|xxx|sex|adult|casino|bet|vpn|proxy|torrent|crack|hack|warez|drug|weapon|leak|escort|gambl|poker)'

# У сайта настоящий сертификат: цепочка проходит проверку, имя совпадает.
sni_trusted() {
  echo | timeout 8 openssl s_client -connect "$1:443" -servername "$1" -verify_hostname "$1" -verify_return_error 2>/dev/null | grep -q 'Verification: OK'
}

