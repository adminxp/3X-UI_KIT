#!/usr/bin/env bash
# kit – управление сервером 3X-UI KIT: пользователи, обновление, резервная копия.
# https://github.com
#
#   kit user add имя [--gb 50] [--days 30] [--devices 3]
#   kit user list | link имя | limit имя [--gb N] [--days N] | off имя | on имя | del имя
#   kit update [--auto | --manual] | kit backup | kit check | kit fix | kit version

# Запуск через sh (dash) ломается на непонятной ошибке синтаксиса – подскажем сразу.
[ -n "${BASH_VERSION:-}" ] || { echo "Запустите через bash, а не через sh." >&2; exit 1; }

set -Eeuo pipefail
export LC_ALL=C.UTF-8  # ширина колонок по символам, а не байтам

KIT_VERSION="1.2.1"
KIT_RAW="https://githubusercontent.com"
# Файлы новой версии берём из её тега, а не из меняющейся ветки main.
kit_ref_raw() { echo "https://githubusercontent.com"; }

XUI_ENV=/etc/x-ui/install-result.env
KIT_ENV=/etc/kit/kit.env
KIT_LATEST=/etc/kit/latest-version

# Проверенные версии: kit panel update ставит именно их, kit check предупреждает о других.
# Суммы архива панели и x-ui.sh сверяет tools/release.sh с официальными (перед каждым выпуском).
XUI_PIN="v3.9.0"
XRAY_PIN="v26.6.27"
declare -A XUI_TARBALL_SHA256=(
  [amd64]=d7cbe0bf6358ee0d2117c24fd2efb483502e411d38e2ea59bd0bf5e7a3e39390
  [arm64]=9a2e43c976a2e71618a30d8f38b52476b25ed363c6989599e2f625cc52f51a81
)
XUI_SH_SHA256=d28959cb5da86c8ddaf2199e5c32dd1ea5dc0a87fcc53f900dd39b133070898a

if [[ -t 1 ]]; then
  G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; B=$'\e[1m'; D=$'\e[2m'; N=$'\e[0m'
else
  G=; Y=; R=; B=; D=; N=
fi
say()  { printf '%s\n' "${G}==>${N} $*"; }
warn() { spin_stop; printf '%s\n' "${Y}!${N}  $*" >&2; }
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

# A-записи домена. Сначала публичный DNS (DoH): локальный резолвер сервера может помнить «записи нет» с тех пор, как её не было,
# и kit тогда спорит с тем, что вы видите у регистратора. Нет ответа от публичного DNS – берём системный.
dns_a() { # домен → IPv4 по одному в строке
  local r
  r=$(curl -fsS -m 6 -H 'accept: application/dns-json' "https://1.1.1" 2>/dev/null \

      | grep -oE '"data":"[0-9]{1,3}(\.[0-9]{1,3}){3}"' | cut -d'"' -f4 | sort -u || true)
  [[ -n $r ]] || r=$(getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u || true)
  printf '%s' "$r"
}

[[ $EUID -eq 0 ]] || die "Запустите от root: sudo -i, затем команду ещё раз."
[[ -f $XUI_ENV && -f $KIT_ENV ]] || die "Не найдена установка – сначала поставьте сервер скриптом 3x-ui.sh."
# shellcheck disable=SC1090
. "$XUI_ENV"; . "$KIT_ENV"

API=""; API_OK=no
for scheme in https http; do
  API="$scheme://127.0.0.1:$XUI_PANEL_PORT/$XUI_WEB_BASE_PATH/panel/api"
  if curl -fsk -m 5 -o /dev/null -H @<(printf 'Authorization: Bearer %s\n' "$XUI_API_TOKEN") "$API/server/getNewUUID" 2>/dev/null; then API_OK=yes; break; fi
done
if [[ $API_OK == no && -x /usr/local/x-ui/x-ui ]]; then
  # Токен из файла не подошёл (после обновления с 1.0, смены токена, переустановки панели). Токены хранятся хэшами, прочитать
  # нельзя, но команда панели выпускает отдельный токен «cli-fallback», не трогая остальные: берём его и сохраняем в файл.
  new_token=$(/usr/local/x-ui/x-ui setting -getApiToken 2>/dev/null | sed -n 's/^apiToken: *//p' | tail -1 | tr -d '[:space:]' || true)
  if [[ $new_token =~ ^[A-Za-z0-9_-]{16,128}$ ]]; then
    for scheme in https http; do
      API="$scheme://127.0.0.1:$XUI_PANEL_PORT/$XUI_WEB_BASE_PATH/panel/api"
      if curl -fsk -m 5 -o /dev/null -H @<(printf 'Authorization: Bearer %s\n' "$new_token") "$API/server/getNewUUID" 2>/dev/null; then API_OK=yes; break; fi
    done
    if [[ $API_OK == yes ]]; then
      XUI_API_TOKEN=$new_token
      env_tmp=$(mktemp); { grep -av '^XUI_API_TOKEN=' "$XUI_ENV" || true; printf 'XUI_API_TOKEN=%q\n' "$new_token"; } >"$env_tmp"
      install -m 600 "$env_tmp" "$XUI_ENV"; rm -f "$env_tmp"
      warn "Токен API панели в $XUI_ENV не подошёл – выпустил новый и сохранил (старый остаётся в панели, его можно отозвать: Настройки – API-токены)."
    fi
  fi
  unset new_token env_tmp
fi
if [[ $API_OK == no ]]; then
  # Токен не подошёл ни по https, ни по http. Схему выбираем по тому, говорит ли порт панели по TLS:
  # иначе запрос по http к TLS-порту даёт невнятное «Unsupported HTTP version in response».
  if [[ $(curl -sk -m 5 -o /dev/null -w '%{http_code}' "https://127.0.0.1:$XUI_PANEL_PORT/" 2>/dev/null || true) =~ ^[1-5] ]]; then scheme=https; else scheme=http; fi
  API="$scheme://127.0.0.1:$XUI_PANEL_PORT/$XUI_WEB_BASE_PATH/panel/api"
fi

api() { # METHOD path [json]
  local out code
  if [[ $1 == GET ]]; then
    out=$(curl -sSk -m 20 -w $'\n%{http_code}' -H @<(printf 'Authorization: Bearer %s\n' "$XUI_API_TOKEN") "$API/$2" || true)
  else
    out=$(curl -sSk -m 20 -w $'\n%{http_code}' -H @<(printf 'Authorization: Bearer %s\n' "$XUI_API_TOKEN") -H 'Content-Type: application/json' -X "$1" --data-binary @<(printf '%s' "${3:-{\}}") "$API/$2" || true)
  fi
  code=${out##*$'\n'}; out=${out%$'\n'*}
  if [[ $(jq -r '.success' <<<"$out" 2>/dev/null) != true ]]; then
    if [[ -z $out || $out != "{"* ]]; then
      die "Панель не приняла запрос (HTTP ${code:-нет ответа}). Частая причина: токен API в $XUI_ENV устарел или не подходит к этой панели. Проверьте: kit → Проверка сервера → Быстрая проверка"
    fi
    die "Панель ответила ошибкой: $(jq -r '.msg // .' <<<"$out" 2>/dev/null | head -c 300)"
  fi
  jq -c '.obj' <<<"$out"
}

# В 3X-UI 3.x у клиента одна запись и в ней одна пара ключей WireGuard и один адрес. Если
# клиент подключён к двум AmneziaWG, в подписку для обоих уходят ключ и адрес одного из них,
# и второй сервер клиента не узнаёт (проверено 2026-09-27). Поэтому к первому AmneziaWG
# подключаем основную запись, а ко второму – запись-«двойник» «имя-awg» с подпиской «<id>-awg»
# (subId в 3X-UI обязан быть уникальным) и теми же лимитами; kit-sub подмешивает её в Clash.
awg_ids() { api GET inbounds/list | jq -r '[.[] | select(.protocol == "amneziawg") | .id] | sort | .[]'; }
non_awg_ids() { api GET inbounds/list | jq -c '[.[] | select(.protocol != "amneziawg") | .id]'; }

awg_attach() { # имя subId [лимит-байт] [срок-мс] [устройств]
  local name=$1 sid=$2 total=${3:-0} exp=${4:-0} lim=${5:-0} n=1 id email have
  have=$(api GET clients/list | jq -c 'if type == "array" then . else .clients end')
  for id in $(awg_ids); do
    local esid=$sid
    if ((n == 1)); then email=$name
    elif ((n == 2)); then email="$name-awg"; esid="$sid-awg"
    else email="$name-awg$n"; esid="$sid-awg$n"; fi
    n=$((n + 1))
    if jq -e --arg e "$email" --argjson i "$id" 'any(.[]; .email == $e and ((.inboundIds // []) | index($i)))' <<<"$have" >/dev/null; then
      continue
    elif jq -e --arg e "$email" 'any(.[]; .email == $e)' <<<"$have" >/dev/null; then
      api POST "clients/$email/attach" "$(jq -nc --argjson i "$id" '{inboundIds: [$i]}')" >/dev/null
    else
      api POST clients/add "$(jq -nc --arg e "$email" --arg s "$esid" --argjson t "$total" --argjson x "$exp" --argjson l "$lim" --argjson i "$id" \
        '{client: {email: $e, subId: $s, totalGB: $t, expiryTime: $x, limitIp: $l, enable: true, comment: "kit"}, inboundIds: [$i]}')" >/dev/null
    fi
  done
}

clients() { api GET clients/list | jq -c 'if type == "array" then . else .clients end'; }
client() { clients | jq -c --arg e "$1" 'map(select(.email == $e))[0] // empty'; }
# Все записи пользователя: основная и «двойники» для AmneziaWG («имя-awgN»).
emails_of() { clients | jq -r --arg e "$1" '.[] | select(.email == $e or ((.email | startswith($e + "-awg")) and (.email[($e | length) + 4:] | test("^[0-9]*$")))) | .email'; }
# Имя из одних точек («.», «..») не годится: оно уходит в путь запроса к панели (clients/update/имя).
valid_name() { [[ $1 =~ ^[A-Za-z0-9_.-]{1,32}$ && $1 =~ [^.] ]] || die "Имя: латиница, цифры, _ . - (до 32 символов, не только точки)."; }
rand_id() { openssl rand -base64 48 | tr -dc 'a-z0-9' | head -c 16; }

# Числа из командной строки: «08» не должно читаться как восьмеричное, а 30 цифр – переполнять счёт.
