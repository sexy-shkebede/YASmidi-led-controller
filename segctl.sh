#!/bin/sh
# segctl.sh — живое управление дисплеем Яндекс Станции Миди, только в памяти
#
# Поднимает на колонке маленький веб-сервер (busybox inetd + sh) с редактором
# дисплея. Открываешь http://IP-колонки:8080 и зажигаешь любой из 45
# светодиодов с любой яркостью: сегменты цифр, точки p1–p5/q1–q5, полоски
# h1 h2 m1 m2 l1 l2 и градус. Анимации играются на самой колонке.
#
#   sh /tmp/segctl.sh            запустить (порт 8080)
#   sh /tmp/segctl.sh start 8090 запустить на другом порту
#   sh /tmp/segctl.sh status     работает ли
#   sh /tmp/segctl.sh check      проверить совместимость с колонкой, ничего не запуская
#   sh /tmp/segctl.sh stop       вернуть дисплей Алисе и всё убрать
#
# Ничего не меняет надолго: всё лежит в /tmp/segctl (оперативная память),
# пишет только в /sys/class/leds/cucumber:white:clock-*/brightness. Настройки
# Алисы, системные файлы и автозапуск не трогает, Алису не перезапускает.
# После перезагрузки колонки не остаётся ничего.

D=${SEGCTL_DIR:-/tmp/segctl}
P=${SEGCTL_LEDS:-/sys/class/leds/cucumber:white:clock-}
PATH=/bin:/sbin:/usr/bin:/usr/sbin:$PATH

say() { printf '%s\n' "$*"; }
die() { printf 'segctl: %s\n' "$*" >&2; exit 1; }
ip_addr() {
  a=$(ip -4 addr 2>/dev/null | grep -o 'inet [0-9.]*' | grep -v 127.0.0.1 | head -1 | cut -d' ' -f2)
  [ -n "$a" ] || a=$(ifconfig 2>/dev/null | grep -o 'inet addr:[0-9.]*' | grep -v 127.0.0.1 | head -1 | cut -d: -f2)
  echo "${a:-IP-колонки}"
}
alive() { [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null; }
stop_pid() {
  [ -f "$1" ] || return 0
  p=$(cat "$1" 2>/dev/null); rm -f "$1"
  case $p in ''|*[!0-9]*) return 0 ;; esac
  kill -TERM -"$p" 2>/dev/null; kill -TERM "$p" 2>/dev/null; return 0
}

# ---- проверка совместимости ----
ALLSEG="a1 b1 c1 d1 e1 f1 g1 p1 q1 a2 b2 c2 d2 e2 f2 g2 p2 q2 a3 b3 c3 d3 e3 f3 g3 p4 q4 a4 b4 c4 d4 e4 f4 g4 p5 q5 deg p3 q3 h1 h2 m1 m2 l1 l2"
CFG=/system/vendor/quasar/quasar.cfg
RING_BASE=${SEGCTL_RING:-}   # можно переопределить вручную
FAIL=0; WARN=0

# Поиск RGB-кольца. На части прошивок это sysfs-светодиоды
# cucumber:red:ring0..  / :green: / :blue:, на других — framebuffer fb0,
# куда из шелла безопасно писать нельзя. Возвращаем число найденных пикселей.
ring_detect() {
  # Кольцо и логотип: cucumber:{red,green,blue}:ring0.. и :logo0..
  # Префикс берём из того же каталога, где лежат clock-светодиоды.
  RING_N=0; LOGO_N=0; RING_PFX=; LOGO_PFX=
  ld=$(dirname "${P}x")
  # ищем любой *:red:ring0, чтобы узнать префикс (обычно cucumber:)
  for f in "$ld"/*:red:ring0; do
    [ -e "$f/brightness" ] || continue
    RING_PFX=${f%red:ring0}
    i=0; while [ -e "${RING_PFX}red:ring$i/brightness" ]; do i=$((i + 1)); done
    RING_N=$i; break
  done
  for f in "$ld"/*:red:logo0; do
    [ -e "$f/brightness" ] || continue
    LOGO_PFX=${f%red:logo0}
    i=0; while [ -e "${LOGO_PFX}red:logo$i/brightness" ]; do i=$((i + 1)); done
    LOGO_N=$i; break
  done
}
ok()   { printf '  [ OK ]  %s\n' "$*"; }
bad()  { printf '  [FAIL]  %s\n' "$*"; FAIL=$((FAIL + 1)); }
warn() { printf '  [ ?  ]  %s\n' "$*"; WARN=$((WARN + 1)); }

check_compat() {
  say "== проверка совместимости segctl =="

  # 1. root
  if [ "$(id -u)" = 0 ]; then ok "root есть"; else bad "нет root (id=$(id -u)) — живое управление не выйдет"; fi

  # 2. /tmp в памяти
  if grep -q ' /tmp tmpfs' /proc/mounts 2>/dev/null; then ok "/tmp — tmpfs (всё в памяти, после перезагрузки чисто)"
  else warn "/tmp не tmpfs — файлы segctl переживут перезагрузку (убери через stop)"; fi

  # 3. каталог светодиодов + их число и имена
  base=$(dirname "${P}x")
  if [ -d "$base" ]; then
    n=0; miss=
    for s in $ALLSEG; do [ -e "$P$s/brightness" ] && n=$((n + 1)) || miss="$miss $s"; done
    if [ "$n" = 45 ]; then ok "светодиоды: 45 из 45, имена совпадают"
    elif [ "$n" -gt 0 ]; then bad "светодиодов $n из 45, не хватает:$miss — раскладка дисплея другая"
    else bad "нет ни одного светодиода ${P}* — это точно Станция Миди?"; fi
  else bad "нет каталога $base — не похоже на Станцию Миди (cucumber)"; fi

  # 4. запись и чтение яркости (неразрушительно: сохраняем и возвращаем)
  tf="${P}deg/brightness"
  if [ -w "$tf" ]; then
    old=; read -r old < "$tf" 2>/dev/null
    if echo 3 > "$tf" 2>/dev/null; then
      got=; read -r got < "$tf" 2>/dev/null
      [ -n "$old" ] && echo "$old" > "$tf" 2>/dev/null
      if [ "$got" = 3 ]; then ok "яркость пишется и читается обратно точно (сторож сработает)"
      elif [ -n "$got" ]; then warn "записал 3, прочитал '$got' — драйвер округляет, сторож будет менее точным"
      else warn "яркость записалась, но не читается — сторож не увидит перерисовку Алисы"; fi
    else bad "не могу писать в $tf"; fi
  else bad "нет доступа на запись к $tf"; fi

  # 5. максимум яркости
  mx=; read -r mx < "${P}a1/max_brightness" 2>/dev/null
  case $mx in
    255) ok "максимальная яркость 255 (как ждёт редактор)" ;;
    '') warn "не прочитал max_brightness — редактор будет слать 0–255" ;;
    *) warn "максимальная яркость $mx, не 255 — 100% в редакторе даст $mx; поправлю, если нужно" ;;
  esac

  # 6. нужные утилиты
  for t in inetd usleep setsid dd sh kill; do
    command -v "$t" >/dev/null 2>&1 && ok "есть $t" || bad "нет $t — без него не работает"
  done

  # 7. dd с нужными флагами (чтение тела запроса)
  if [ "$(printf abcd | dd bs=4096 count=2 iflag=count_bytes,fullblock 2>/dev/null)" = ab ]; then
    ok "dd понимает count_bytes/fullblock (чтение запросов)"
  else warn "dd не понял count_bytes/fullblock — приём данных от редактора под вопросом"; fi

  # 8. остановка процесса по группе — ровно как гасятся плеер и сторож
  setsid sh -c 'sleep 9' >/dev/null 2>&1 &
  cp=$!
  sleep 1
  if kill -0 "$cp" 2>/dev/null; then
    kill -TERM -"$cp" 2>/dev/null; sleep 1
    if kill -0 "$cp" 2>/dev/null; then kill -TERM "$cp" 2>/dev/null; warn "стоп по группе (kill -TERM -pid) не сработал — плеер и сторож придётся гасить командой stop"
    else ok "стоп фоновых задач по группе работает"; fi
  else kill "$cp" 2>/dev/null; warn "тестовая задача через setsid не удержалась — проверь плеер вручную"; fi

  # 9. порт
  port=${1:-8080}
  if netstat -tln 2>/dev/null | grep -q ":$port "; then bad "порт $port занят — запусти на другом: start <порт>"
  else ok "порт $port свободен"; fi

  # 10. файрвол: блокировки входящих
  if command -v iptables >/dev/null 2>&1; then
    blk=$(iptables -S 2>/dev/null | grep -cE 'DROP|REJECT')
    if [ "${blk:-0}" = 0 ]; then ok "iptables: правил DROP/REJECT нет"
    else warn "iptables: есть правила DROP/REJECT ($blk) — если страница не откроется, дело в них"; fi
  else warn "нет iptables — проверить файрвол не могу"; fi

  # 11. раскладка байтов для файлов .binscled (на живое управление не влияет)
  if [ -r "$CFG" ]; then
    parts=$(tr -d ' \n' < "$CFG" | grep -o '"digitParts":\[[^]]*\]' | head -1)
    deg=$(tr -d ' \n' < "$CFG" | grep -o '"degreeLocation":{"part":"[^"]*"' | head -1)
    if [ "$parts" = '"digitParts":["a","b","c","d","e","f","g","p","q"]' ] && [ "$deg" = '"degreeLocation":{"part":"deg"' ]; then
      ok "раскладка .binscled совпадает с редактором (карта байтов верна)"
    else warn "раскладка в $CFG отличается — живое управление ОК, но сохранённые .binscled могут лечь иначе; пришли мне frameBuilder из конфига"
    fi
  else warn "нет доступа к $CFG — карту байтов для .binscled не сверить (на живой режим не влияет)"; fi

  # 12. RGB-кольцо и логотип (опционально; на сегментный дисплей не влияют)
  ring_detect
  if [ "$RING_N" -gt 0 ]; then
    rt="${RING_PFX}red:ring0/brightness"
    if [ -w "$rt" ]; then
      rold=; read -r rold < "$rt" 2>/dev/null
      if echo 1 > "$rt" 2>/dev/null; then [ -n "$rold" ] && echo "$rold" > "$rt" 2>/dev/null
        ok "RGB-кольцо: $RING_N пикселей, запись работает — управление доступно"
      else warn "кольцо найдено ($RING_N px), но запись не прошла — управления не будет"; fi
    else warn "кольцо найдено ($RING_N px), нет доступа на запись"; fi
  else warn "RGB-кольцо не найдено (сегментный дисплей работает)"; fi
  if [ "$LOGO_N" -gt 0 ]; then ok "RGB-логотип: $LOGO_N пикселей — управление доступно"
  else warn "RGB-логотип не найден"; fi

  say ""
  if [ "$FAIL" = 0 ] && [ "$WARN" = 0 ]; then say "Итог: полностью совместимо."
  elif [ "$FAIL" = 0 ]; then say "Итог: совместимо. Замечаний (?): $WARN — живому режиму не мешают, см. выше."
  else say "Итог: несовместимо. Ошибок: $FAIL, замечаний: $WARN. Запуск не даст результата, пока ошибки не устранены."; fi
  return $FAIL
}
# ---- /проверка ----



rgb_blank() { # $1=префикс $2=элемент $3=число
  [ "$3" -gt 0 ] || return 0
  i=0; while [ "$i" -lt "$3" ]; do
    for c in red green blue; do echo 0 > "$1$c:$2$i/brightness"; done
    i=$((i + 1))
  done 2>/dev/null
}
ring_count() { # ставит RN/LN/RING/LOGO
  RN=0; LN=0; RING=; LOGO=; ld=$(dirname "${P}x")
  for f in "$ld"/*:red:ring0; do [ -e "$f/brightness" ] || continue; RING=${f%red:ring0}
    i=0; while [ -e "${RING}red:ring$i/brightness" ]; do i=$((i+1)); done; RN=$i; break; done
  for f in "$ld"/*:red:logo0; do [ -e "$f/brightness" ] || continue; LOGO=${f%red:logo0}
    i=0; while [ -e "${LOGO}red:logo$i/brightness" ]; do i=$((i+1)); done; LN=$i; break; done
}
do_stop() {
  stop_pid "$D/player.pid"; stop_pid "$D/keeper.pid"
  if [ -f "$D/snap" ]; then
    for kv in $(cat "$D/snap"); do echo "${kv#*=}" > "$P${kv%%=*}/brightness"; done 2>/dev/null
    say "  дисплей возвращён Алисе"
  fi
  if [ -f "$D/ring_touched" ] || [ -f "$D/logo_touched" ]; then
    ring_count
    [ -f "$D/ring_touched" ] && rgb_blank "$RING" ring "$RN"
    [ -f "$D/logo_touched" ] && rgb_blank "$LOGO" logo "$LN"
    say "  кольцо и логотип погашены (были изменены)"
  fi
  stop_pid "$D/inetd.pid"
  rm -rf "$D"
  say "segctl остановлен, в памяти ничего не осталось."
}

unpack() {
  mkdir -p "$D/www" || die "не могу создать $D"
  cat > "$D/http.sh" <<'__SEG_HTTP__'
#!/bin/sh
# segctl live: обработчик HTTP для busybox inetd (stdin/stdout = сокет)
# Ничего не пишет за пределы /tmp/segctl и файлов яркости светодиодов дисплея.
PATH=/bin:/sbin:/usr/bin:/usr/sbin:$PATH
D=${SEGCTL_DIR:-/tmp/segctl}
P=${SEGCTL_LEDS:-/sys/class/leds/cucumber:white:clock-}
W=$D/want
RING=${SEGCTL_RING:-}
ALL="a1 b1 c1 d1 e1 f1 g1 p1 q1 a2 b2 c2 d2 e2 f2 g2 p2 q2 a3 b3 c3 d3 e3 f3 g3 p4 q4 a4 b4 c4 d4 e4 f4 g4 p5 q5 deg p3 q3 h1 h2 m1 m2 l1 l2"
CR=$(printf '\r')

hdr() { printf 'HTTP/1.0 %s\r\nContent-Type: %s\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n' "$1" "$2"; }
json() { hdr "200 OK" "application/json; charset=utf-8"; printf '%s' "$1"; }
alive() { [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null; }
stop_pid() { # $1 = pid-файл; процесс запущен через setsid, гасим всю группу
  [ -f "$1" ] || return 0
  p=$(cat "$1" 2>/dev/null); rm -f "$1"
  case $p in ''|*[!0-9]*) return 0 ;; esac
  kill -TERM -"$p" 2>/dev/null; kill -TERM "$p" 2>/dev/null; return 0
}
take() { # забрать дисплей: запомнить кадр Алисы и поставить сторожа
  if [ ! -f "$D/snap" ]; then
    mkdir -p "$W"
    out=; for s in $ALL; do v=0; { read -r v < "$P$s/brightness"; } 2>/dev/null; out="$out $s=$v"; echo "$v" > "$W/$s"; done
    echo "${out# }" > "$D/snap"
  fi
  alive "$D/keeper.pid" || setsid sh "$D/keeper.sh" </dev/null >/dev/null 2>&1 &
  # если крутится цикл YANDEX_Customizer, он будет драться за экран
  if [ -f /data/yse/clock.pid ]; then kill "$(cat /data/yse/clock.pid)" 2>/dev/null; fi
  return 0
}
rgb_blank() { # $1=префикс $2=элемент $3=число — гасим все пиксели
  [ "$3" -gt 0 ] || return 0
  i=0; while [ "$i" -lt "$3" ]; do
    for c in red green blue; do echo 0 > "$1$c:$2$i/brightness"; done
    i=$((i + 1))
  done 2>/dev/null
}
give() { # отдать дисплей Алисе: вернуть её кадр часов и погасить то, что мы зажигали
  stop_pid "$D/player.pid"; stop_pid "$D/keeper.pid"
  if [ -f "$D/snap" ]; then
    for kv in $(cat "$D/snap"); do echo "${kv#*=}" > "$P${kv%%=*}/brightness"; done 2>/dev/null
  fi
  ring_detect
  [ -f "$D/ring_touched" ] && rgb_blank "$RING" ring "$RN"
  [ -f "$D/logo_touched" ] && rgb_blank "$LOGO" logo "$LN"
  rm -rf "$W" "$D/snap" "$D/anim.txt" "$D/ring_touched" "$D/logo_touched"
}
apply() {
  for kv in $1; do
    n=${kv%%=*}; v=${kv#*=}
    case $n in ''|*[!a-z0-9]*) continue ;; esac
    case $v in ''|*[!0-9]*) continue ;; esac
    [ -e "$P$n/brightness" ] || continue
    echo "$v" > "$W/$n"; echo "$v" > "$P$n/brightness"
  done 2>/dev/null
}

ring_detect() {   # RING/RN для кольца, LOGO/LN для логотипа
  RN=0; LN=0
  ld=$(dirname "${P}x")
  if [ -n "$RING" ]; then i=0; while [ -e "${RING}red:ring$i/brightness" ]; do i=$((i+1)); done; RN=$i; fi
  if [ "$RN" = 0 ]; then
    for f in "$ld"/*:red:ring0; do
      [ -e "$f/brightness" ] || continue
      RING=${f%red:ring0}
      i=0; while [ -e "${RING}red:ring$i/brightness" ]; do i=$((i+1)); done; RN=$i; break
    done
  fi
  for f in "$ld"/*:red:logo0; do
    [ -e "$f/brightness" ] || continue
    LOGO=${f%red:logo0}
    i=0; while [ -e "${LOGO}red:logo$i/brightness" ]; do i=$((i+1)); done; LN=$i; break
  done
}
rgb_apply() {   # $1=префикс  $2=элемент(ring|logo)  $3=число  $4="i=RRGGBB ..."
  pfx=$1; el=$2; cnt=$3
  [ "$cnt" -gt 0 ] || return 0
  for kv in $4; do
    idx=${kv%%=*}; hex=${kv#*=}
    case $idx in ''|*[!0-9]*) continue ;; esac
    [ "$idx" -lt "$cnt" ] || continue
    case $hex in ''|*[!0-9a-fA-F]*) continue ;; esac
    [ ${#hex} = 6 ] || continue
    r=$(printf '%d' "0x$(printf %s "$hex" | cut -c1-2)")
    g=$(printf '%d' "0x$(printf %s "$hex" | cut -c3-4)")
    b=$(printf '%d' "0x$(printf %s "$hex" | cut -c5-6)")
    echo "$r" > "${pfx}red:$el$idx/brightness"
    echo "$g" > "${pfx}green:$el$idx/brightness"
    echo "$b" > "${pfx}blue:$el$idx/brightness"
  done 2>/dev/null
}

read -r method target proto || exit 0
target=${target%%\?*}
clen=0
while read -r line; do
  line=${line%"$CR"}
  [ -z "$line" ] && break
  case $line in [Cc][Oo][Nn][Tt][Ee][Nn][Tt]-[Ll][Ee][Nn][Gg][Tt][Hh]:*) clen=${line#*:}; clen=${clen# } ;; esac
done
case $clen in ''|*[!0-9]*) clen=0 ;; esac
body() { [ "$clen" -gt 0 ] && dd bs=4096 count="$clen" iflag=count_bytes,fullblock 2>/dev/null; }

case "$method $target" in
  "GET /"|"GET /index.html")
    hdr "200 OK" "text/html; charset=utf-8"; cat "$D/www/index.html" ;;
  "GET /api/info")
    n=0; for s in $ALL; do [ -e "$P$s/brightness" ] && n=$((n + 1)); done
    max=255; { read -r max < "${P}a1/max_brightness"; } 2>/dev/null
    case $max in ''|*[!0-9]*) max=255 ;; esac
    pl=false; alive "$D/player.pid" && pl=true
    tk=false; [ -f "$D/snap" ] && tk=true
    ring_detect
    json "{\"ok\":true,\"app\":\"segctl\",\"mode\":\"live\",\"version\":3,\"leds\":$n,\"ring\":$RN,\"logo\":$LN,\"max\":$max,\"player\":$pl,\"takeover\":$tk}" ;;
  "GET /api/ring")
    ring_detect
    hdr "200 OK" "application/json; charset=utf-8"; printf '{"ok":true,"ring":%s,"logo":%s}' "$RN" "$LN" ;;
  "POST /api/ring/set")
    b=$(body); ring_detect; stop_pid "$D/player.pid"; rgb_apply "$RING" ring "$RN" "$b"; : > "$D/ring_touched"; json '{"ok":true}' ;;
  "POST /api/logo/set")
    b=$(body); ring_detect; stop_pid "$D/player.pid"; rgb_apply "$LOGO" logo "$LN" "$b"; : > "$D/logo_touched"; json '{"ok":true}' ;;
  "GET /api/state")
    out=; for s in $ALL; do v=0; { read -r v < "$P$s/brightness"; } 2>/dev/null; out="$out $s=$v"; done
    hdr "200 OK" "text/plain; charset=utf-8"; printf '%s' "${out# }" ;;
  "POST /api/set")
    b=$(body); stop_pid "$D/player.pid"; take; apply "$b"; json '{"ok":true}' ;;
  "POST /api/play")
    stop_pid "$D/player.pid"; take; body > "$D/anim.txt"
    setsid sh "$D/player.sh" </dev/null >/dev/null 2>&1 &
    json '{"ok":true}' ;;
  "POST /api/stop")
    body >/dev/null; stop_pid "$D/player.pid"; json '{"ok":true}' ;;
  "POST /api/release")
    body >/dev/null; give; json '{"ok":true}' ;;
  *) hdr "404 Not Found" "application/json; charset=utf-8"; printf '{"ok":false}' ;;
esac
exit 0
__SEG_HTTP__
  cat > "$D/keeper.sh" <<'__SEG_KEEPER__'
#!/bin/sh
# segctl live: сторож. Раз в TICK мс сверяет дисплей с желаемым кадром (want/).
# Если кто-то (Алиса) перерисовал экран и это держится две проверки подряд,
# запоминает её кадр (вернём при отдаче) и восстанавливает твой.
PATH=/bin:/sbin:/usr/bin:/usr/sbin:$PATH
D=${SEGCTL_DIR:-/tmp/segctl}
P=${SEGCTL_LEDS:-/sys/class/leds/cucumber:white:clock-}
W=$D/want
TICK=${SEGCTL_TICK:-150}
ALL="a1 b1 c1 d1 e1 f1 g1 p1 q1 a2 b2 c2 d2 e2 f2 g2 p2 q2 a3 b3 c3 d3 e3 f3 g3 p4 q4 a4 b4 c4 d4 e4 f4 g4 p5 q5 deg p3 q3 h1 h2 m1 m2 l1 l2"
echo $$ > "$D/keeper.pid"
exec 2>/dev/null
prev=; lastfix=
while [ -d "$W" ]; do
  usleep $((TICK * 1000))
  diff=; snap=
  for s in $ALL; do
    a=; w=
    read -r a < "$P$s/brightness"
    read -r w < "$W/$s"
    snap="$snap $s=$a"
    [ -n "$w" ] && [ "$a" != "$w" ] && diff="$diff $s=$a"
  done
  if [ -z "$diff" ]; then prev=; lastfix=; continue; fi
  if [ "$diff" = "$prev" ] && [ "$diff" != "$lastfix" ]; then
    echo "${snap# }" > "$D/snap"
    for kv in $diff; do s=${kv%%=*}; read -r w < "$W/$s"; echo "$w" > "$P$s/brightness"; done
    lastfix=$diff; prev=
  else
    prev=$diff
  fi
done
rm -f "$D/keeper.pid"
__SEG_KEEPER__
  cat > "$D/player.sh" <<'__SEG_PLAYER__'
#!/bin/sh
# segctl live: проигрыватель анимации в памяти колонки
# anim.txt: первая строка "loop N" (N = кадр начала повтора, -1 = один раз),
# дальше по кадру на строку: "мс имя=яркость ..." (только изменения;
# первый кадр и кадр начала повтора — полные)
PATH=/bin:/sbin:/usr/bin:/usr/sbin:$PATH
D=${SEGCTL_DIR:-/tmp/segctl}
P=${SEGCTL_LEDS:-/sys/class/leds/cucumber:white:clock-}
W=$D/want
F=$D/anim.txt
echo $$ > "$D/player.pid"
exec 2>/dev/null
mkdir -p "$W"
LOOP=-1
{ read -r _ LOOP; } < "$F"
case $LOOP in ''|*[!0-9-]*) LOOP=-1 ;; esac
run() {
  n=0
  { read -r _
    while read -r d rest || [ -n "$d" ]; do
      if [ "$n" -ge "$1" ]; then
        for kv in $rest; do echo "${kv#*=}" > "$W/${kv%%=*}"; echo "${kv#*=}" > "$P${kv%%=*}/brightness"; done
        case $d in ''|*[!0-9]*) d=20 ;; esac
        usleep $((d * 1000))
      fi
      n=$((n + 1))
    done
  } < "$F"
}
run 0
if [ "$LOOP" -ge 0 ]; then while :; do run "$LOOP"; done; fi
rm -f "$D/player.pid"
__SEG_PLAYER__
  cat > "$D/www/index.html" <<'__SEG_HTML__'
<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Редактор дисплея Станции</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Onest:wght@400;500;600;700&family=Unbounded:wght@500;600&display=swap" rel="stylesheet">
<style>
:root{
  color-scheme: light;
  --bg:#e8ebf0; --card:#ffffff; --card-2:#f2f4f7; --line:#d5d9e1; --text:#14161b; --text-2:#596071;
  --chip:#e2e6ed; --chip-hover:#d7dce5; --accent:#f3c64f; --accent-ink:#2a1f03; --accent-text:#8a5e00;
  --danger:#c0392b; --warn:#b7791f; --focus:#2f6fde;
  box-sizing:border-box;
  padding-top:env(safe-area-inset-top,0px);
  padding-bottom:env(safe-area-inset-bottom,0px);
}
@media (prefers-color-scheme: dark){
  :root:not([data-theme="light"]){
    color-scheme: dark;
    --bg:#121419; --card:#1a1d24; --card-2:#22262e; --line:#2c303a; --text:#e8eaef; --text-2:#9aa1ae;
    --chip:#272b34; --chip-hover:#30353f; --accent-text:#f3c64f; --danger:#ff7b6c; --warn:#f0b54a; --focus:#8fb4ff;
  }
}
:root[data-theme="dark"]{
  color-scheme: dark;
  --bg:#121419; --card:#1a1d24; --card-2:#22262e; --line:#2c303a; --text:#e8eaef; --text-2:#9aa1ae;
  --chip:#272b34; --chip-hover:#30353f; --accent-text:#f3c64f; --danger:#ff7b6c; --warn:#f0b54a; --focus:#8fb4ff;
}
*,*::before,*::after{box-sizing:border-box}
[hidden]{display:none!important}
html{scroll-padding-top:env(safe-area-inset-top,0px)}
body{margin:0;background:var(--bg);color:var(--text);font:15px/1.45 Onest,system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;-webkit-tap-highlight-color:transparent}
button,input,select,textarea{font:inherit;color:inherit}
:focus-visible{outline:2px solid var(--focus);outline-offset:2px}

.app{max-width:1260px;margin:0 auto;padding:16px 12px 88px;display:grid;grid-template-columns:minmax(0,1fr);gap:14px}
@media (min-width:1060px){
  .app{grid-template-columns:minmax(0,1fr) 390px;align-items:start;padding:24px 24px 64px;gap:18px}
  .side{position:sticky;top:18px}
}
.top{grid-column:1/-1;display:flex;align-items:center;justify-content:space-between;gap:12px}
.top h1{font:600 19px/1.15 Unbounded,Onest,system-ui,sans-serif;letter-spacing:-.01em;margin:0}
.top .fname{color:var(--text-2);font-size:13px;margin-top:3px;word-break:break-all}
.main,.side{display:grid;grid-template-columns:minmax(0,1fr);gap:14px;min-width:0}

/* buttons */
.btn{display:inline-flex;align-items:center;justify-content:center;gap:8px;height:40px;padding:0 16px;border:0;border-radius:20px;background:var(--chip);font-weight:600;font-size:14px;cursor:pointer;white-space:nowrap;transition:border-radius .18s ease,background-color .15s}
.btn:hover{background:var(--chip-hover)}
.btn:active{border-radius:12px}
.btn.primary{background:var(--accent);color:var(--accent-ink)}
.btn.primary:hover{background:#f7d067}
.btn svg{width:20px;height:20px;fill:currentColor;flex:none}
.btn:disabled{opacity:.45;cursor:default}
.ibtn{width:44px;height:44px;padding:0;border-radius:14px}
.ibtn:active{border-radius:22px}
.ibtn.on{background:var(--accent);color:var(--accent-ink)}
.row{display:flex;flex-wrap:wrap;align-items:center;gap:8px}

/* device */
.device-wrap{background:#15171c;border:1px solid #262a32;border-radius:28px;padding:10px}
.device{background:#0b0c0f;border:1px solid #2a2e38;border-radius:18px;padding:4px 2px}
.disp{display:block;width:100%;height:auto;touch-action:none;user-select:none;-webkit-user-select:none}
.disp .vis{stroke-width:1.6;stroke-linejoin:round}
.disp circle.vis{stroke-width:2.4}
.disp .hit{fill:transparent;stroke:transparent;stroke-width:14;stroke-linejoin:round;pointer-events:all}
.disp circle.hit{stroke-width:0}
.disp [data-el]{cursor:pointer}
.disp .lbl{font:500 19px Onest,system-ui,sans-serif;text-anchor:middle;dominant-baseline:central;pointer-events:none}
.disp .tile{cursor:pointer}
.disp .tile rect{fill:#262a34;transition:fill .12s}
.disp .tile:hover rect{fill:#2f3441}
.disp .tile:active rect{fill:#3a404e}
.disp .tile path{fill:#e8ecf5;stroke:#e8ecf5;stroke-width:3;stroke-linejoin:round}
.disp .tile:focus-visible{outline:none}
.disp .tile:focus-visible rect{stroke:#8fb4ff;stroke-width:3}
.disp g.hl .vis{stroke:#7fb2ff;stroke-width:4}
.hint{color:var(--text-2);font-size:13px;margin:0}
.ledstage{background:#0b0c0f;border:1px solid #23262e;border-radius:18px;padding:10px}
.perim{display:block;width:100%;max-width:300px;margin:0 auto;height:auto;touch-action:none;user-select:none;-webkit-user-select:none}
.perim .body{fill:#15171c;stroke:#2a2e38;stroke-width:2}
.perim .px{stroke:#0b0c0f;stroke-width:1.5;cursor:pointer;transition:none}
.perim .px.on{stroke:#e8ecf5}
.perim .hit{fill:transparent;stroke:transparent;cursor:pointer}
.logobar{display:flex;gap:8px;justify-content:center;background:#0b0c0f;border:1px solid #23262e;border-radius:14px;padding:12px}
.logobar .lpx{flex:1 1 0;max-width:56px;aspect-ratio:1;border-radius:10px;border:1px solid #23262e;cursor:pointer}
.cpick{display:flex;flex-wrap:wrap;gap:7px;align-items:center}
.cpick .sw{width:30px;height:30px;border-radius:9px;border:2px solid transparent;cursor:pointer;padding:0;box-shadow:inset 0 0 0 1px rgba(0,0,0,.25)}
.cpick .sw.on{border-color:var(--text);box-shadow:inset 0 0 0 1px rgba(0,0,0,.25),0 0 0 2px var(--accent)}
.cpick .custom{width:34px;height:30px;position:relative;border-radius:9px;overflow:hidden;border:1px solid var(--line);cursor:pointer}
.cpick .custom input{position:absolute;inset:-4px;width:calc(100% + 8px);height:calc(100% + 8px);border:0;padding:0;cursor:pointer}
.cpick .custom span{position:absolute;right:2px;bottom:1px;font-size:10px;color:#fff;text-shadow:0 0 2px #000;pointer-events:none}

/* cards */
.card{background:var(--card);border:1px solid var(--line);border-radius:24px;padding:14px 16px}
.card h2{font-size:15px;font-weight:600;margin:0}
.brush{display:grid;grid-template-columns:auto 1fr auto;align-items:center;gap:10px 12px}
.brush label{font-weight:600;font-size:14px}
.brush input[type=range]{width:100%;accent-color:var(--accent)}
.brush output{font-variant-numeric:tabular-nums;min-width:3ch;text-align:right;font-weight:600}
.swatch{width:18px;height:18px;border-radius:50%;display:inline-block;vertical-align:-3px;margin-right:6px;border:1.5px solid #e2b13c}
.chips{grid-column:1/-1;display:flex;flex-wrap:wrap;gap:6px}
.chip{height:34px;padding:0 14px;border-radius:17px;border:1px solid var(--line);background:transparent;font-size:13px;font-weight:600;cursor:pointer}
.chip.on{background:var(--accent);border-color:var(--accent);color:var(--accent-ink)}
.tools-row{display:flex;flex-wrap:wrap;gap:8px}
.sep{flex:1}

/* timeline */
.tl-head{display:flex;align-items:baseline;justify-content:space-between;gap:10px;margin-bottom:10px}
.tl-head .meta{color:var(--text-2);font-size:13px;font-variant-numeric:tabular-nums}
.strip{display:flex;gap:8px;overflow-x:auto;padding:2px 2px 10px;scroll-snap-type:x proximity;overscroll-behavior-x:contain}
.thumb{flex:0 0 auto;width:108px;border:2px solid #23262e;background:#0b0c0f;border-radius:14px;padding:6px 6px 4px;cursor:pointer;scroll-snap-align:start;text-align:left}
.thumb svg{display:block;width:100%;height:auto}
.thumb .cap{display:flex;justify-content:space-between;gap:4px;font-size:11px;margin-top:4px;color:#8f95a2;font-variant-numeric:tabular-nums}
.thumb .cap b{color:#d9dce3;font-weight:600}
.thumb .cap .lp{color:#7fb2ff;font-weight:700}
.thumb .cap i{font-style:normal;color:#f3c64f;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.thumb.cur{border-color:#f3c64f}
.thumb.playing{border-color:#7fb2ff}
.tl-ctrl{display:flex;flex-wrap:nowrap;gap:6px;align-items:center;margin-top:4px}
.tl-ctrl .ibtn{flex:1 1 0;width:auto;min-width:0;max-width:52px}
@media (max-width:420px){.ibtn{width:40px;height:40px}}
.dur{display:flex;align-items:center;gap:8px;flex-wrap:wrap}
.dur input[type=number]{width:96px}

/* fields */
.field{display:grid;grid-template-columns:minmax(0,1fr);gap:6px}
.field>span{font-size:13px;color:var(--text-2)}
input[type=text],input[type=number],select,textarea{height:40px;border-radius:12px;border:1px solid var(--line);background:var(--card-2);padding:0 12px;width:100%;min-width:0}
textarea{height:auto;padding:10px 12px;resize:vertical;font:12px/1.4 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;word-break:break-all}
.grid2{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);gap:10px;align-items:end}
.grid2 .btn{width:100%}
.check{display:flex;align-items:center;gap:10px;font-size:14px;cursor:pointer}
.check input{width:18px;height:18px;accent-color:var(--accent);margin:0}

/* accordions */
details.tool{background:var(--card);border:1px solid var(--line);border-radius:22px}
details.tool>summary{list-style:none;cursor:pointer;padding:15px 18px;font-weight:600;display:flex;align-items:center;justify-content:space-between;gap:12px;border-radius:22px}
details.tool>summary::-webkit-details-marker{display:none}
details.tool>summary::after{content:"";width:9px;height:9px;border-right:2px solid currentColor;border-bottom:2px solid currentColor;transform:rotate(45deg) translate(-2px,-2px);opacity:.55;transition:transform .2s ease;flex:none}
details.tool[open]>summary::after{transform:rotate(-135deg) translate(-2px,-2px)}
details.tool>summary small{font-weight:400;color:var(--text-2);font-size:13px;margin-left:auto}
.tool-body{padding:0 18px 18px;display:grid;grid-template-columns:minmax(0,1fr);gap:12px}
.tool-body p{margin:0;font-size:14px;color:var(--text-2)}
.tool-body p b{color:var(--text);font-weight:600}

/* byte map */
.mgroup{border:0;margin:0;padding:0;display:grid;gap:6px}
.mgroup legend{font-size:13px;font-weight:600;padding:0;margin-bottom:6px}
.mgrid{display:grid;grid-template-columns:repeat(auto-fill,minmax(52px,1fr));gap:6px}
.mcell{display:grid;gap:3px;font-size:12px;color:var(--text-2);text-align:center}
.mcell input[type=number]{height:36px;text-align:center;padding:0 2px;font-variant-numeric:tabular-nums;-moz-appearance:textfield;appearance:textfield}
.mcell input::-webkit-inner-spin-button,.mcell input::-webkit-outer-spin-button{-webkit-appearance:none;margin:0}
.mcell input.dup{border-color:var(--warn);color:var(--warn)}
.mcell input.bad{border-color:var(--danger);color:var(--danger)}
.mapwarn{font-size:13px;color:var(--warn);margin:0}

/* hex */
.hexgrid{display:grid;grid-template-columns:repeat(8,minmax(0,1fr));gap:4px;font:12px/1 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
.hx{display:grid;gap:3px;justify-items:center;padding:6px 0 7px;border-radius:9px;border:1px solid var(--line);background:var(--card-2);cursor:pointer;font:inherit}
.hx small{font-size:9.5px;color:var(--text-2)}
.hx.on{background:#3a3220;border-color:#6b5a2a;color:#fff3c4}
.hx.free{border-style:dashed}
.hx.warn{border:1.5px solid var(--warn);border-style:solid}
.hx.ro{cursor:default;opacity:.7}
.legend{display:flex;flex-wrap:wrap;gap:6px 14px;font-size:12px;color:var(--text-2)}

/* toast */
.stchip{display:inline-flex;align-items:center;gap:6px;font-size:12px;font-weight:600;color:var(--accent-text);margin-left:8px}
.stchip::before{content:"";width:8px;height:8px;border-radius:50%;background:#3ccf7a;box-shadow:0 0 0 3px rgba(60,207,122,.2)}
.stchip.err{color:var(--danger)}
.stchip.err::before{background:var(--danger);box-shadow:none}
.toast{position:fixed;left:50%;bottom:calc(18px + env(safe-area-inset-bottom,0px));transform:translate(-50%,8px);background:#2b2f39;color:#f1f2f5;padding:12px 18px;border-radius:16px;width:max-content;max-width:min(92vw,560px);font-size:14px;box-shadow:0 8px 28px rgba(0,0,0,.35);opacity:0;pointer-events:none;transition:opacity .18s,transform .18s;z-index:20}
.toast.show{opacity:1;transform:translate(-50%,0)}
@media (prefers-reduced-motion: reduce){*{transition:none!important}}
.sr{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0)}
</style>
</head>
<body>
<div class="app">
  <header class="top">
    <div>
      <h1>Дисплей Станции</h1>
      <div class="fname"><span id="fnameTop">animation.binscled.zst</span><span class="stchip" id="stChip" hidden>Станция</span></div>
    </div>
    <button class="btn primary" id="btnDownload" type="button">
      <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 20h14v-2H5v2zM19 9h-4V3H9v6H5l7 7 7-7z"/></svg>
      Скачать
    </button>
  </header>

  <main class="main">
    <section class="device-wrap" aria-label="Дисплей">
      <div class="device" id="device"></div>
    </section>

    <section class="card" aria-label="Кисть">
      <div class="brush">
        <label for="brush"><span class="swatch" id="swatch"></span>Яркость</label>
        <input type="range" id="brush" min="0" max="255" step="1" value="255">
        <output id="brushOut" for="brush">255</output>
        <div class="chips" id="brushChips">
          <button class="chip" type="button" data-b="0">Ластик</button>
          <button class="chip" type="button" data-b="32">12%</button>
          <button class="chip" type="button" data-b="128">50%</button>
          <button class="chip" type="button" data-b="255">100%</button>
        </div>
      </div>
      <p class="hint" style="margin-top:10px">Нажми на сегмент, точку или полоску, чтобы зажечь её текущей яркостью. Повторное нажатие гасит. Можно вести пальцем по нескольким. Стрелки листают символы в цифре.</p>
      <div class="tools-row" style="margin-top:12px">
        <button class="btn" type="button" id="btnClear">Очистить</button>
        <button class="btn" type="button" id="btnFill">Зажечь всё</button>
        <button class="btn" type="button" id="btnInvert">Инвертировать</button>
        <span class="sep"></span>
        <button class="btn ibtn" type="button" id="btnUndo" aria-label="Отменить" title="Отменить (Ctrl+Z)"><svg viewBox="0 0 24 24"><path d="M12.5 8c-2.65 0-5.05.99-6.9 2.6L2 7v9h9l-3.62-3.62c1.39-1.16 3.16-1.88 5.12-1.88 3.54 0 6.55 2.31 7.6 5.5l2.37-.78C21.08 11.03 17.15 8 12.5 8z"/></svg></button>
        <button class="btn ibtn" type="button" id="btnRedo" aria-label="Вернуть" title="Вернуть (Ctrl+Shift+Z)"><svg viewBox="0 0 24 24"><path d="M18.4 10.6C16.55 8.99 14.15 8 11.5 8c-4.65 0-8.58 3.03-9.96 7.22L3.9 16c1.05-3.19 4.05-5.5 7.6-5.5 1.95 0 3.73.72 5.12 1.88L13 16h9V7l-3.6 3.6z"/></svg></button>
      </div>
    </section>

    <section class="card" aria-label="Кадры">
      <div class="tl-head">
        <h2>Кадры</h2>
        <span class="meta" id="tlMeta"></span>
      </div>
      <div class="strip" id="strip" role="listbox" aria-label="Список кадров"></div>
      <div class="tl-ctrl">
        <button class="btn ibtn" type="button" id="btnPlay" aria-label="Воспроизвести" title="Воспроизвести (пробел)"><svg viewBox="0 0 24 24"><path id="playIcon" d="M8 5v14l11-7z"/></svg></button>
        <button class="btn ibtn on" type="button" id="btnLoop" aria-pressed="true" aria-label="Повтор анимации" title="Повтор анимации (записывается в файл)"><svg viewBox="0 0 24 24"><path d="M7 7h10v3l4-4-4-4v3H5v6h2V7zm10 10H7v-3l-4 4 4 4v-3h12v-6h-2v4z"/></svg></button>
        <button class="btn ibtn" type="button" id="btnLoopHere" aria-label="Повтор с этого кадра" title="Повтор с этого кадра"><svg viewBox="0 0 24 24"><path d="M14.4 6 14 4H5v17h2v-7h5.6l.4 2h7V6z"/></svg></button>
        <button class="btn ibtn" type="button" id="btnAdd" aria-label="Новый пустой кадр" title="Новый пустой кадр"><svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg></button>
        <button class="btn ibtn" type="button" id="btnDup" aria-label="Дублировать кадр" title="Дублировать кадр"><svg viewBox="0 0 24 24"><path d="M16 1H4c-1.1 0-2 .9-2 2v14h2V3h12V1zm3 4H8c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h11c1.1 0 2-.9 2-2V7c0-1.1-.9-2-2-2zm0 16H8V7h11v14z"/></svg></button>
        <button class="btn ibtn" type="button" id="btnDel" aria-label="Удалить кадр" title="Удалить кадр"><svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg></button>
        <button class="btn ibtn" type="button" id="btnLeft" aria-label="Сдвинуть кадр влево" title="Сдвинуть влево"><svg viewBox="0 0 24 24"><path d="M15.41 7.41 14 6l-6 6 6 6 1.41-1.41L10.83 12z"/></svg></button>
        <button class="btn ibtn" type="button" id="btnRight" aria-label="Сдвинуть кадр вправо" title="Сдвинуть вправо"><svg viewBox="0 0 24 24"><path d="M10 6 8.59 7.41 13.17 12l-4.58 4.59L10 18l6-6z"/></svg></button>
      </div>
      <div class="dur" style="margin-top:12px">
        <label for="durIn" style="font-size:14px;font-weight:600">Длительность кадра</label>
        <input type="number" id="durIn" min="1" max="65535" step="1" inputmode="numeric">
        <span style="color:var(--text-2);font-size:14px">мс</span>
        <button class="btn" type="button" id="btnDurAll">Ко всем кадрам</button>
      </div>
      <p class="hint" style="margin-top:8px">Длительность кадра — от 1 до 65535 мс, пишется в байты 46–47.</p>
    </section>
  </main>

  <aside class="side">
    <details class="tool" id="dStation">
      <summary>Станция <small id="stBadge">не подключена</small></summary>
      <div class="tool-body">
        <div id="stOff" style="display:grid;gap:10px">
          <p>Живое управление работает, когда этот редактор открыт с самой колонки. Запусти на Станции Миди <b>segctl.sh</b>: он поднимет страницу по адресу <b>http://IP-колонки:8080</b>, и там каждая точка, полоска и сегмент будут загораться сразу, с любой яркостью. Всё живёт в оперативной памяти колонки и исчезает после перезагрузки.</p>
        </div>
        <div id="stOn" hidden style="display:grid;gap:12px">
          <p id="stStatus"></p>
          <label class="check"><input type="checkbox" id="stLive" checked> Живой режим: правки сразу на дисплее</label>
          <div class="row">
            <button class="btn primary" type="button" id="stPlay">Играть на станции</button>
            <button class="btn" type="button" id="stShow">Показать кадр</button>
            <button class="btn" type="button" id="stStop">Стоп</button>
          </div>
          <div class="row">
            <button class="btn" type="button" id="stRelease">Отдать дисплей Алисе</button>
          </div>
          <p class="hint">Ничего не сохраняется и не подменяется, часы Алисы не выключаются. Если она перерисует экран (обычно раз в минуту), твой кадр вернётся сам за доли секунды. «Отдать дисплей» сразу вернёт на экран её последний кадр.</p>
        </div>
      </div>
    </details>
    <details class="tool" id="dRing">
      <summary>Кольцо (RGB) <small id="ringBadge"></small></summary>
      <div class="tool-body">
        <div id="ringOff"><p id="ringOffMsg">Подсветка-кольцо появится здесь, когда редактор открыт с колонки и она сообщит, что кольцом можно управлять. Проверь командой <b>sh /tmp/segctl.sh check</b>.</p></div>
        <div id="ringOn" hidden style="display:grid;gap:12px">
          <p id="ringStatus"></p>
          <div class="cpick" data-for="ring"></div>
          <div class="ledstage"><svg id="ringSvg" class="perim" viewBox="0 0 320 320" role="group" aria-label="Кольцо: светодиоды по периметру колонки"></svg></div>
          <div class="row"><button class="btn" type="button" id="ringAll">Залить всё</button><button class="btn" type="button" id="ringOffBtn">Погасить</button></div>
          <p class="hint">Колонка показана сверху. Нажми на светодиод по периметру, чтобы покрасить его выбранным цветом. Веди пальцем, чтобы красить несколько подряд.</p>
        </div>
      </div>
    </details>
    <details class="tool" id="dLogo">
      <summary>Логотип (RGB) <small id="logoBadge"></small></summary>
      <div class="tool-body">
        <div id="logoOff"><p>Логотип появится здесь, когда колонка сообщит, что им можно управлять. Проверь командой <b>sh /tmp/segctl.sh check</b>.</p></div>
        <div id="logoOn" hidden style="display:grid;gap:12px">
          <p id="logoStatus"></p>
          <div class="cpick" data-for="logo"></div>
          <div id="logoDots" class="logobar"></div>
          <div class="row"><button class="btn" type="button" id="logoAll">Залить всё</button><button class="btn" type="button" id="logoOffBtn">Погасить</button></div>
          <p class="hint">6 пикселей логотипа Яндекса. Красятся сразу на колонке, независимо от кольца и дисплея.</p>
        </div>
      </div>
    </details>
    <details class="tool" id="dFile" open>
      <summary>Файл</summary>
      <div class="tool-body">
        <label class="field"><span>Имя анимации</span><input type="text" id="nameIn" autocomplete="off" spellcheck="false"></label>
        <div class="row">
          <button class="btn primary" type="button" id="btnDownload2">Скачать .binscled.zst</button>
          <button class="btn" type="button" id="btnRaw">Несжатый .binscled</button>
          <button class="btn" type="button" id="btnOpen">Открыть файл</button>
          <input type="file" id="fileIn" class="sr" tabindex="-1">
        </div>
        <p id="fileStat"></p>
        <p>В окне Claude файл скачивается внутри .zip, потому что сам .zst сюда не пускают. Распакуй архив, внутри лежит готовый <b id="zipInner">animation.binscled.zst</b>. Несжатый вариант нужен для встроенного плеера <b>clock_led_util</b>.</p>
        <label class="field"><span>Примеры</span>
          <select id="presetSel">
            <option value="">Выбери пример…</option>
            <option value="ringing">Будильник, ringing (оригинал)</option>
            <option value="update">Установка обновления, update_applying (оригинал)</option>
            <option value="clock">Часы 08:24 с мигающим двоеточием</option>
            <option value="wave">Волна по всем сегментам</option>
            <option value="scan">Сканер байтов для проверки карты</option>
            <option value="blank">Пустой проект</option>
          </select>
        </label>
        <div class="row">
          <button class="btn" type="button" id="btnB64">Показать как base64</button>
        </div>
        <div id="b64Box" hidden class="field">
          <span>Команда для adb shell: собирает тот же файл из текста</span>
          <textarea id="b64Out" rows="5" readonly></textarea>
          <div class="row"><button class="btn" type="button" id="btnCopy">Скопировать</button></div>
        </div>
      </div>
    </details>

    <details class="tool" id="dText">
      <summary>Текст и бегущая строка</summary>
      <div class="tool-body">
        <p>Четыре символа на цифры. Если третий символ <b>:</b>, <b>-</b>, <b>=</b>, <b>.</b> или пробел, он уходит в центральную колонку: например, «08:24» или «12-30».</p>
        <div class="grid2">
          <label class="field"><span>Текст</span><input type="text" id="txtIn" value="08:24" maxlength="8" autocomplete="off" spellcheck="false"></label>
          <button class="btn" type="button" id="btnText">Написать в кадр</button>
        </div>
        <label class="field"><span>Бегущая строка</span><input type="text" id="mqIn" value="ПРИВЕТ 2026" autocomplete="off" spellcheck="false"></label>
        <div class="grid2">
          <label class="field"><span>Шаг, мс</span><input type="number" id="mqStep" value="220" min="1" max="65535" inputmode="numeric"></label>
          <button class="btn" type="button" id="btnMq">Добавить кадры</button>
        </div>
        <label class="check"><input type="checkbox" id="mqReplace"> Заменить все кадры</label>
      </div>
    </details>

    <details class="tool" id="dFx">
      <summary>Переходы</summary>
      <div class="tool-body">
        <div class="grid2">
          <label class="field"><span>Промежуточных кадров</span><input type="number" id="fxN" value="16" min="1" max="200" inputmode="numeric"></label>
          <label class="field"><span>Кривая</span>
            <select id="fxCurve"><option value="sine">Плавная</option><option value="linear">Линейная</option></select>
          </label>
        </div>
        <div class="row">
          <button class="btn" type="button" id="btnTween">Переход к следующему</button>
          <button class="btn" type="button" id="btnFadeIn">Появление</button>
          <button class="btn" type="button" id="btnFadeOut">Затухание</button>
          <button class="btn" type="button" id="btnMerge">Склеить одинаковые</button>
        </div>
        <p>Переход вставляет кадры между текущим и следующим. Появление начинается с тёмного экрана перед текущим кадром, затухание гасит его до темноты. «Склеить» объединяет одинаковые соседние кадры и складывает их длительности.</p>
      </div>
    </details>

    <details class="tool" id="dMap">
      <summary>Карта байтов <small id="mapState"></small></summary>
      <div class="tool-body">
        <p>Кадр занимает 48 байт: байт 0 — метка начала повтора (ставится кнопкой с флажком у кадров), байты 1–45 — яркости светодиодов (0–255), байты 46–47 — длительность кадра (16 бит). Раскладка взята из прошивки станции (quasar.cfg): цифры a b c d e f g p q (байты 1–36), точка-градус (байт 37), центр p3 q3 h1 h2 m1 m2 l1 l2 (байты 38–45). Если что-то не сходится, проверь сканером и поправь.</p>
        <div id="mapGrid" style="display:grid;gap:14px"></div>
        <p class="mapwarn" id="mapWarn" hidden></p>
        <div class="row">
          <button class="btn" type="button" id="btnMapReset">Сбросить карту</button>
        </div>
        <div class="grid2">
          <label class="field"><span>Проверить один байт</span><input type="number" id="probeIn" value="45" min="1" max="45" inputmode="numeric"></label>
          <button class="btn" type="button" id="btnProbe">Вставить кадр</button>
        </div>
      </div>
    </details>

    <details class="tool" id="dHex">
      <summary>Байты кадра</summary>
      <div class="tool-body">
        <div class="hexgrid" id="hex"></div>
        <div class="legend"><span>Пунктир: байт не назначен</span><span>Рыжая рамка: горит, но не назначен</span></div>
        <p>Нажатие на байт зажигает или гасит его текущей яркостью, даже если он не привязан к элементу.</p>
      </div>
    </details>
  </aside>
</div>
<div class="toast" id="toast" role="status" aria-live="polite"></div>

<script>
(() => {
'use strict';
const $ = (s, r = document) => r.querySelector(s);
const NSLOT = 46, FRAME = 48, LEDS = 45;
const SEGS = ['a','b','c','d','e','f','g'];
const DIGITS = [{n:1,x:47},{n:2,x:165},{n:4,x:426},{n:5,x:545}];
const DY = 88, MX = 352.5;
const SEGP = {
  a:[[10,0],[103,0],[90,20],[23,20]],
  b:[[113,7],[113,100],[93,89],[93,20]],
  c:[[113,107],[113,200],[93,187],[93,118]],
  d:[[23,187],[90,187],[103,207],[10,207]],
  e:[[0,107],[20,118],[20,187],[0,200]],
  f:[[0,7],[20,20],[20,89],[0,100]],
  g:[[8,103.5],[22,93.5],[91,93.5],[105,103.5],[91,113.5],[22,113.5]]
};

/* ---------- geometry & elements ---------- */
const GEO = [];
for (const d of DIGITS) {
  for (const s of SEGS) GEO.push({id:`d${d.n}${s}`, t:'p', p:SEGP[s].map(([x,y]) => `${x+d.x},${y+DY}`).join(' ')});
  const cx = d.x + 56.5;
  GEO.push({id:`p${d.n}`, t:'c', cx, cy:143, r:20, lbl:`p${d.n}`});
  GEO.push({id:`q${d.n}`, t:'c', cx, cy:239, r:20, lbl:`q${d.n}`});
}
for (const [k, cy] of [['h',98],['m',191],['l',284.5]]) {
  GEO.push({id:k+'1', t:'p', p:`285,${cy} 296,${cy-11} ${MX-1},${cy-11} ${MX-1},${cy+11} 296,${cy+11}`, lbl:k+'1', lx:322, ly:cy});
  GEO.push({id:k+'2', t:'p', p:`${MX+1},${cy-11} 409,${cy-11} 420,${cy} 409,${cy+11} ${MX+1},${cy+11}`, lbl:k+'2', lx:383, ly:cy});
}
GEO.push({id:'p3', t:'c', cx:MX, cy:143, r:20, lbl:'p3'});
GEO.push({id:'q3', t:'c', cx:MX, cy:239, r:20, lbl:'q3'});
GEO.push({id:'dot', t:'c', cx:678, cy:104, r:13.5});

const ELEMS = [];
for (const d of DIGITS) {
  for (const s of SEGS) ELEMS.push({id:`d${d.n}${s}`, g:`d${d.n}`, short:s, name:`цифра ${d.n}, сегмент ${s}`});
  ELEMS.push({id:`p${d.n}`, g:`d${d.n}`, short:`p${d.n}`, name:`цифра ${d.n}, точка p${d.n}`});
  ELEMS.push({id:`q${d.n}`, g:`d${d.n}`, short:`q${d.n}`, name:`цифра ${d.n}, точка q${d.n}`});
}
ELEMS.push({id:'dot', g:'dot', short:'°', name:'точка справа (градус)'});
for (const id of ['p3','q3','h1','h2','m1','m2','l1','l2']) ELEMS.push({id, g:'mid', short:id, name:`центр, ${id}`});
const EL = Object.fromEntries(ELEMS.map(e => [e.id, e]));
const GROUPS = [['d1','Цифра 1'],['d2','Цифра 2'],['mid','Центр (3)'],['d4','Цифра 4'],['d5','Цифра 5'],['dot','Точка']];
const MID_IDS = ['h1','h2','m1','m2','l1','l2','p3','q3'];
function defaultMap() { const m = {}; ELEMS.forEach((e, i) => m[e.id] = i + 1); return m; }

/* ---------- glyphs ---------- */
const GLYPH = {'0':'abcdef','1':'bc','2':'abdeg','3':'abcdg','4':'bcfg','5':'acdfg','6':'acdefg','7':'abc','8':'abcdefg','9':'abcdfg',
  'A':'abcefg','b':'cdefg','C':'adef','c':'deg','d':'bcdeg','E':'adefg','F':'aefg','G':'acdef','H':'bcefg','h':'cefg','I':'ef','i':'c',
  'J':'bcde','L':'def','l':'ef','n':'ceg','o':'cdeg','O':'abcdef','P':'abefg','q':'abcfg','r':'eg','S':'acdfg','t':'defg','U':'bcdef',
  'u':'cde','y':'bcdfg','-':'g','_':'d','°':'abfg','=':'dg',' ':'',
  'А':'abcefg','Б':'acdefg','В':'abcdefg','Г':'aef','Е':'adefg','Ё':'adefg','З':'abcdg','И':'bcdef','Н':'bcefg','О':'abcdef','П':'abcef',
  'Р':'abefg','С':'adef','Т':'defg','У':'bcdfg','Ч':'bcfg','Ь':'cdefg','Ы':'cdefg','Э':'abcdg','Я':'abcefg','Ц':'bcdef','Ш':'bcdef','Л':'abcef','Д':'abcdeg','К':'bcefg','М':'abcef','Х':'bcefg','Ю':'bcdef','Й':'bcdef','Ж':'bcefg','Ф':'abcdefg'};
const CYCLE = [' ','0','1','2','3','4','5','6','7','8','9','A','b','C','c','d','E','F','G','H','h','J','L','n','o','P','q','r','t','U','u','y','-','_','°','='];
function glyphFor(ch) {
  if (ch in GLYPH) return GLYPH[ch];
  const u = ch.toUpperCase(), l = ch.toLowerCase();
  if (u in GLYPH) return GLYPH[u];
  if (l in GLYPH) return GLYPH[l];
  return null;
}

/* ---------- colors ---------- */
const ON = [255,243,196], ONS = [226,177,60];
const OFF = [37,42,53], OFFS = [52,58,71], OFFC = [30,34,43], OFFCS = [54,60,73];
const tOf = v => v <= 0 ? 0 : Math.pow(Math.min(255, v) / 255, 0.55);
const mix = (a, b, t) => `rgb(${Math.round(a[0]+(b[0]-a[0])*t)},${Math.round(a[1]+(b[1]-a[1])*t)},${Math.round(a[2]+(b[2]-a[2])*t)})`;

/* ---------- state ---------- */
const STORE = 'binscled-editor-v3', STORE_OLD = ['binscled-editor-v2', 'binscled-editor-v1'];
const blankB = () => new Array(NSLOT).fill(0);
const clamp8 = v => Math.max(0, Math.min(255, Math.round(+v || 0)));
function freshState() { return {name:'animation', frames:[{b:blankB(), d:20}], cur:0, map:defaultMap(), brush:255, loopFrom:0}; }
function sanitizeState(o) {
  const s = freshState();
  if (!o || typeof o !== 'object') return s;
  if (Array.isArray(o.frames) && o.frames.length) {
    s.frames = o.frames.map(f => ({b: Array.from({length:NSLOT}, (_, i) => clamp8(f && f.b ? f.b[i] : 0)), d: Math.max(1, Math.min(65535, Math.round(+(f && f.d) || 20))), ...(f && f.n ? {n:String(f.n).slice(0,24)} : {})}));
  }
  if (o.map && typeof o.map === 'object') for (const e of ELEMS) { const v = o.map[e.id]; if (Number.isInteger(v) && v >= 0 && v < NSLOT) s.map[e.id] = v; }
  if (Number.isInteger(o.loopFrom)) s.loopFrom = Math.max(-1, Math.min(s.frames.length - 1, o.loopFrom));
  else if (o.loop === false) s.loopFrom = -1;
  if (Number.isFinite(o.brush)) s.brush = clamp8(o.brush);
  if (typeof o.name === 'string' && o.name.trim()) s.name = o.name.slice(0, 64);
  s.cur = Math.max(0, Math.min(s.frames.length - 1, o.cur | 0));
  return s;
}
let S;
try {
  const cur2 = JSON.parse(localStorage.getItem(STORE) || 'null');
  if (cur2) S = sanitizeState(cur2);
  else {
    let old = null; for (const k of STORE_OLD) { old = JSON.parse(localStorage.getItem(k) || 'null'); if (old) break; }
    if (old) { delete old.map; old.frames = (old.frames || []).map(f => ({...f, b: (f.b || []).slice(0, NSLOT).map((v, i) => i === 0 ? 0 : v)})); }
    S = sanitizeState(old);
  }
} catch (e) { S = freshState(); }
let saveT = 0;
function save() { clearTimeout(saveT); saveT = setTimeout(() => { try { localStorage.setItem(STORE, JSON.stringify(S)); } catch (e) {} }, 300); }
const cur = () => S.frames[S.cur];
const cloneF = f => ({b: f.b.slice(), d: f.d, ...(f.n ? {n:f.n} : {})});

const ledOK = s => s >= 1 && s <= LEDS;
function valOf(f, id) { const s = S.map[id]; return ledOK(s) ? (f.b[s] | 0) : 0; }
function setVal(f, id, v) { const s = S.map[id]; if (ledOK(s)) f.b[s] = clamp8(v); }
const onV = () => S.brush > 0 ? S.brush : 255;

/* ---------- undo ---------- */
const undoS = [], redoS = [];
const snap = () => JSON.stringify({frames:S.frames, cur:S.cur, loopFrom:S.loopFrom});
function pushUndo() { undoS.push(snap()); if (undoS.length > 120) undoS.shift(); redoS.length = 0; }
function restore(str) { const o = JSON.parse(str); S.frames = o.frames; S.cur = Math.min(o.cur, S.frames.length - 1); S.loopFrom = Number.isInteger(o.loopFrom) ? o.loopFrom : S.loopFrom; }
function doUndo() { if (!undoS.length) return; stopPlay(); redoS.push(snap()); restore(undoS.pop()); refresh(true); }
function doRedo() { if (!redoS.length) return; stopPlay(); undoS.push(snap()); restore(redoS.pop()); refresh(true); }

/* ---------- display ---------- */
const nodes = {};
function buildDisplay() {
  let s = '';
  for (const d of DIGITS) {
    const cx = d.x + 56.5;
    s += `<g class="tile" data-arrow="${d.n}:1" role="button" tabindex="0" aria-label="Цифра ${d.n}: следующий символ"><rect x="${cx-31}" y="12" width="62" height="56" rx="13"/><path d="M${cx-9} 47L${cx+9} 47L${cx} 32Z"/></g>`;
    s += `<g class="tile" data-arrow="${d.n}:-1" role="button" tabindex="0" aria-label="Цифра ${d.n}: предыдущий символ"><rect x="${cx-31}" y="314" width="62" height="56" rx="13"/><path d="M${cx-9} 335L${cx+9} 335L${cx} 350Z"/></g>`;
  }
  for (const e of GEO) {
    const lbl = e.lbl ? `<text class="lbl" x="${e.t === 'c' ? e.cx : e.lx}" y="${e.t === 'c' ? e.cy : e.ly}">${e.lbl}</text>` : '';
    if (e.t === 'p') s += `<g data-el="${e.id}"><title></title><polygon class="vis" points="${e.p}"/>${lbl}<polygon class="hit" points="${e.p}"/></g>`;
    else s += `<g data-el="${e.id}"><title></title><circle class="vis" cx="${e.cx}" cy="${e.cy}" r="${e.r}"/>${lbl}<circle class="hit" cx="${e.cx}" cy="${e.cy}" r="${e.r + 8}"/></g>`;
  }
  $('#device').innerHTML = `<svg class="disp" id="disp" viewBox="37 2 666 378" role="group" aria-label="Семисегментный дисплей: 4 цифры, центральная колонка, точки">${s}</svg>`;
  for (const e of GEO) {
    const g = $(`[data-el="${e.id}"]`);
    nodes[e.id] = {g, vis: g.querySelector('.vis'), lbl: g.querySelector('.lbl'), title: g.querySelector('title'), c: e.t === 'c'};
  }
}
function renderDisplay(f = cur()) {
  for (const e of GEO) {
    const n = nodes[e.id], v = valOf(f, e.id), t = tOf(v);
    n.vis.setAttribute('fill', mix(n.c ? OFFC : OFF, ON, t));
    n.vis.setAttribute('stroke', mix(n.c ? OFFCS : OFFS, ONS, t));
    if (n.lbl) n.lbl.setAttribute('fill', t > 0.5 ? '#3a2f12' : '#8b919d');
  }
  if (f === cur() && !play) livePush();
}
function renderTitles() {
  for (const e of GEO) {
    const s = S.map[e.id];
    nodes[e.id].title.textContent = `${EL[e.id].name[0].toUpperCase() + EL[e.id].name.slice(1)}: байт ${s}`;
  }
}

/* ---------- thumbnails ---------- */
function miniSvg(f) {
  let s = '<svg viewBox="42 82 656 220" aria-hidden="true">';
  for (const e of GEO) {
    const v = valOf(f, e.id), fill = v ? mix(OFF, ON, tOf(v)) : (e.t === 'c' ? '#1b1f27' : '#21252e');
    s += e.t === 'p' ? `<polygon points="${e.p}" fill="${fill}"/>` : `<circle cx="${e.cx}" cy="${e.cy}" r="${e.r}" fill="${fill}"/>`;
  }
  return s + '</svg>';
}
const esc = s => String(s).replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
function thumbHTML(f, i) {
  return `<button type="button" class="thumb${i === S.cur ? ' cur' : ''}" data-i="${i}" role="option" aria-selected="${i === S.cur}" aria-label="Кадр ${i+1}, ${f.d} мс">${miniSvg(f)}<span class="cap"><b>${i+1}${i === S.loopFrom ? ' <span class="lp" title="Начало повтора">↻</span>' : ''}</b>${f.n ? `<i>${esc(f.n)}</i>` : ''}<span>${f.d}&nbsp;мс</span></span></button>`;
}
function renderStrip() {
  $('#strip').innerHTML = S.frames.map(thumbHTML).join('');
  scrollToCur();
}
function updateThumb(i = S.cur) {
  const t = $(`.thumb[data-i="${i}"]`);
  if (t) t.outerHTML = thumbHTML(S.frames[i], i);
}
function scrollToCur() {
  const t = $(`.thumb[data-i="${S.cur}"]`);
  if (t) { const st = $('#strip'); const l = t.offsetLeft - st.offsetLeft, r = l + t.offsetWidth; if (l < st.scrollLeft) st.scrollLeft = l - 8; else if (r > st.scrollLeft + st.clientWidth) st.scrollLeft = r - st.clientWidth + 8; }
}
function selectFrame(i) {
  stopPlay();
  i = Math.max(0, Math.min(S.frames.length - 1, i));
  const prev = $(`.thumb.cur`);
  if (prev) { prev.classList.remove('cur'); prev.setAttribute('aria-selected', 'false'); }
  S.cur = i;
  const t = $(`.thumb[data-i="${i}"]`);
  if (t) { t.classList.add('cur'); t.setAttribute('aria-selected', 'true'); }
  scrollToCur(); renderDisplay(); renderMeta(); renderHex(); save();
}

/* ---------- meta & refresh ---------- */
const plural = (n, a, b, c) => { const m10 = n % 10, m100 = n % 100; return m10 === 1 && m100 !== 11 ? a : (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14) ? b : c); };
const nf = n => n.toLocaleString('ru-RU');
function renderMeta() {
  const n = S.frames.length, total = S.frames.reduce((a, f) => a + f.d, 0);
  if (S.loopFrom >= n) S.loopFrom = n - 1;
  $('#tlMeta').textContent = `${n} ${plural(n, 'кадр', 'кадра', 'кадров')}, ${(total / 1000).toLocaleString('ru-RU', {maximumFractionDigits:2})} с, ` + (S.loopFrom < 0 ? 'без повтора' : `повтор с ${S.loopFrom + 1}`);
  $('#btnLoop').classList.toggle('on', S.loopFrom >= 0); $('#btnLoop').setAttribute('aria-pressed', String(S.loopFrom >= 0));
  $('#btnLoopHere').classList.toggle('on', S.loopFrom === S.cur);
  if (document.activeElement !== $('#durIn')) $('#durIn').value = cur().d;
  $('#btnUndo').disabled = !undoS.length; $('#btnRedo').disabled = !redoS.length;
  $('#btnDel').disabled = n < 2; $('#btnLeft').disabled = S.cur === 0; $('#btnRight').disabled = S.cur === n - 1;
  const fn = fileBase() + '.binscled.zst';
  $('#fnameTop').textContent = fn; $('#zipInner').textContent = fn;
  const raw = buildRaw();
  $('#fileStat').innerHTML = `${nf(raw.length / FRAME)} ${plural(raw.length / FRAME, 'кадр', 'кадра', 'кадров')} по 48 байт: несжатый файл <b>${nf(raw.length)}</b> байт, .zst <b>${nf(raw.length + 6 + 3 * Math.ceil(raw.length / 131072))}</b> байт.`;
  if (!$('#b64Box').hidden) fillB64();
}
function refresh(full) {
  renderDisplay(); renderMeta(); renderHex();
  if (full) renderStrip(); else updateThumb();
  save();
}

/* ---------- painting ---------- */
let paint = null;
function hitId(target) { const g = target && target.closest ? target.closest('[data-el]') : null; return g ? g.dataset.el : null; }
function applyPaint(id) {
  if (!paint || paint.done.has(id)) return;
  paint.done.add(id);
  if (valOf(cur(), id) !== paint.v) { setVal(cur(), id, paint.v); paint.changed = true; renderDisplay(); renderHex(); }
}
function bindDisplay() {
  const svg = $('#disp');
  svg.addEventListener('pointerdown', e => {
    const id = hitId(e.target);
    if (!id) return;
    e.preventDefault(); stopPlay();
    const s = S.map[id];
    if (!ledOK(s)) { toast('Этот элемент привязан к байту вне диапазона светодиодов (1–45). Поменяй карту байтов.'); return; }
    pushUndo();
    const v = valOf(cur(), id);
    paint = {v: S.brush === 0 ? 0 : (v === S.brush ? 0 : S.brush), done: new Set(), changed: false};
    applyPaint(id);
    try { svg.setPointerCapture(e.pointerId); } catch (err) {}
  });
  svg.addEventListener('pointermove', e => {
    if (!paint) return;
    const id = hitId(document.elementFromPoint(e.clientX, e.clientY));
    if (id) applyPaint(id);
  });
  const end = () => { if (!paint) return; if (!paint.changed) undoS.pop(); paint = null; updateThumb(); renderMeta(); save(); };
  svg.addEventListener('pointerup', end); svg.addEventListener('pointercancel', end); svg.addEventListener('lostpointercapture', end);
  svg.addEventListener('click', e => { const t = e.target.closest('[data-arrow]'); if (t) arrow(t.dataset.arrow); });
  svg.addEventListener('keydown', e => { const t = e.target.closest('[data-arrow]'); if (t && (e.key === 'Enter' || e.key === ' ')) { e.preventDefault(); arrow(t.dataset.arrow); } });
}
function arrow(spec) {
  stopPlay();
  const [n, dir] = spec.split(':').map(Number);
  const f = cur();
  const bits = SEGS.filter(s => valOf(f, `d${n}${s}`) > 0).join('');
  let idx = CYCLE.findIndex(ch => GLYPH[ch] === bits);
  idx = idx < 0 ? (dir > 0 ? 1 : 10) : (idx + dir + CYCLE.length) % CYCLE.length;
  const lit = SEGS.map(s => valOf(f, `d${n}${s}`)).filter(v => v > 0);
  const v = lit.length ? Math.max(...lit) : onV();
  pushUndo();
  setDigit(f, n, GLYPH[CYCLE[idx]], v);
  refresh(false);
}
function setDigit(f, n, bits, v) { for (const s of SEGS) setVal(f, `d${n}${s}`, bits.includes(s) ? v : 0); }
const MIDMAP = {':':['p3','q3'], '.':['q3'], "'":['p3'], '-':['m1','m2'], '=':['h1','h2','l1','l2'], '≡':['h1','h2','m1','m2','l1','l2'], ' ':[]};
function setMid(f, ch, v) { const on = MIDMAP[ch] || []; for (const id of MID_IDS) setVal(f, id, on.includes(id) ? v : 0); }
function applyText(f, str, v) {
  const chars = [...str];
  let mid = null;
  if (chars.length >= 5 && chars[2] in MIDMAP) { mid = chars[2]; chars.splice(2, 1); }
  const four = chars.slice(0, 4); while (four.length < 4) four.push(' ');
  const bad = [];
  DIGITS.forEach((d, i) => { const g = glyphFor(four[i]); if (g === null) bad.push(four[i]); setDigit(f, d.n, g || '', v); });
  if (mid !== null) setMid(f, mid, v);
  return bad;
}

/* ---------- frame ops ---------- */
function insertFrames(at, list) { S.frames.splice(at, 0, ...list); if (S.loopFrom >= at) S.loopFrom += list.length; }
function opClear() { stopPlay(); pushUndo(); cur().b = blankB(); refresh(false); }
function opFill() { stopPlay(); pushUndo(); for (const e of ELEMS) setVal(cur(), e.id, onV()); refresh(false); }
function opInvert() { stopPlay(); pushUndo(); const f = cur(); for (const e of ELEMS) setVal(f, e.id, valOf(f, e.id) > 0 ? 0 : onV()); refresh(false); }
function opAdd() { stopPlay(); pushUndo(); insertFrames(S.cur + 1, [{b:blankB(), d:cur().d}]); S.cur++; refresh(true); }
function opDup() { stopPlay(); pushUndo(); const c = cloneF(cur()); delete c.n; insertFrames(S.cur + 1, [c]); S.cur++; refresh(true); }
function opDel() { if (S.frames.length < 2) return; stopPlay(); pushUndo(); S.frames.splice(S.cur, 1); if (S.loopFrom > S.cur) S.loopFrom--; S.loopFrom = Math.min(S.loopFrom, S.frames.length - 1); S.cur = Math.min(S.cur, S.frames.length - 1); refresh(true); }
function opMove(dir) {
  const j = S.cur + dir; if (j < 0 || j >= S.frames.length) return;
  stopPlay(); pushUndo(); [S.frames[S.cur], S.frames[j]] = [S.frames[j], S.frames[S.cur]]; if (S.loopFrom === S.cur) S.loopFrom = j; else if (S.loopFrom === j) S.loopFrom = S.cur; S.cur = j; refresh(true);
}
const ease = (t, c) => c === 'sine' ? 0.5 - 0.5 * Math.cos(Math.PI * t) : t;
const lerpB = (a, b, t) => a.map((v, i) => Math.round(v + (b[i] - v) * t));
function fxParams() { return {n: Math.max(1, Math.min(200, parseInt($('#fxN').value, 10) || 16)), c: $('#fxCurve').value}; }
function opTween() {
  const {n, c} = fxParams();
  let j = S.cur + 1;
  if (j >= S.frames.length) { if (S.frames.length < 2) { toast('Нужен хотя бы ещё один кадр, к которому делать переход.'); return; } j = 0; }
  stopPlay(); pushUndo();
  const a = cur(), b = S.frames[j], list = [];
  for (let k = 1; k <= n; k++) list.push({b: lerpB(a.b, b.b, ease(k / (n + 1), c)), d: a.d});
  insertFrames(S.cur + 1, list);
  refresh(true); toast(`Добавлено ${n} ${plural(n, 'кадр', 'кадра', 'кадров')} перехода.`);
}
function opFade(inward) {
  const {n, c} = fxParams();
  stopPlay(); pushUndo();
  const a = cur(), z = blankB(), list = [];
  if (inward) { for (let k = 0; k < n; k++) list.push({b: lerpB(z, a.b, ease(k / n, c)), d: a.d}); insertFrames(S.cur, list); S.cur += n; }
  else { for (let k = 1; k <= n; k++) list.push({b: lerpB(a.b, z, ease(k / n, c)), d: a.d}); insertFrames(S.cur + 1, list); }
  refresh(true);
}
function opMerge() {
  stopPlay(); pushUndo();
  const out = []; let lf = -1;
  S.frames.forEach((f, i) => {
    const p = out[out.length - 1];
    if (p && i !== S.loopFrom && p.b.every((v, k) => v === f.b[k]) && p.d + f.d <= 65535) { p.d += f.d; }
    else out.push(cloneF(f));
    if (i === S.loopFrom) lf = out.length - 1;
  });
  S.loopFrom = S.loopFrom < 0 ? -1 : lf;
  const removed = S.frames.length - out.length;
  S.frames = out; S.cur = Math.min(S.cur, out.length - 1);
  refresh(true); toast(removed ? `Склеено, кадров стало меньше на ${removed}.` : 'Одинаковых соседних кадров нет.');
}

/* ---------- playback ---------- */
let play = null;
function startPlay() {
  if (play) return;
  const cum = []; let acc = 0;
  for (const f of S.frames) { acc += Math.max(1, f.d); cum.push(acc); }
  const total = acc, t0 = performance.now(), lf = S.loopFrom, lt = lf > 0 ? cum[lf - 1] : 0;
  play = {raf: 0, idx: -1};
  const step = now => {
    if (!play) return;
    let el = now - t0;
    if (el >= total) { if (lf < 0) { stopPlay(); return; } el = lt + (el - total) % (total - lt); }
    let i = 0; while (i < cum.length - 1 && cum[i] <= el) i++;
    if (i !== play.idx) {
      const old = $(`.thumb[data-i="${play.idx}"]`); if (old) old.classList.remove('playing');
      play.idx = i;
      const t = $(`.thumb[data-i="${i}"]`); if (t) t.classList.add('playing');
      renderDisplay(S.frames[i]); renderHex(S.frames[i], i);
    }
    play.raf = requestAnimationFrame(step);
  };
  play.raf = requestAnimationFrame(step);
  $('#playIcon').setAttribute('d', 'M7 7h10v10H7z');
  $('#btnPlay').setAttribute('aria-label', 'Стоп');
}
function stopPlay() {
  if (!play) return;
  cancelAnimationFrame(play.raf);
  const old = $(`.thumb[data-i="${play.idx}"]`); if (old) old.classList.remove('playing');
  play = null;
  $('#playIcon').setAttribute('d', 'M8 5v14l11-7z');
  $('#btnPlay').setAttribute('aria-label', 'Воспроизвести');
  renderDisplay(); renderHex();
}

/* ---------- byte map ---------- */
function slotOwners() { const o = {}; for (const e of ELEMS) { const s = S.map[e.id]; if (!ledOK(s)) continue; (o[s] = o[s] || []).push(e.id); } return o; }
function buildMapUI() {
  let h = '';
  for (const [g, name] of GROUPS) {
    h += `<fieldset class="mgroup"><legend>${name}</legend><div class="mgrid">`;
    for (const e of ELEMS.filter(x => x.g === g)) h += `<label class="mcell"><span>${e.short}</span><input type="number" inputmode="numeric" min="1" max="45" data-map="${e.id}" aria-label="Байт для: ${e.name}"></label>`;
    h += '</div></fieldset>';
  }
  $('#mapGrid').innerHTML = h;
  syncMapUI();
}
function syncMapUI() {
  for (const inp of document.querySelectorAll('[data-map]')) if (document.activeElement !== inp) inp.value = S.map[inp.dataset.map];
  validateMap();
}
function validateMap() {
  const count = {};
  for (const e of ELEMS) count[S.map[e.id]] = (count[S.map[e.id]] || 0) + 1;
  let dups = 0, bad = 0;
  for (const inp of document.querySelectorAll('[data-map]')) {
    const s = S.map[inp.dataset.map];
    const isBad = !ledOK(s), isDup = count[s] > 1;
    inp.classList.toggle('bad', isBad); inp.classList.toggle('dup', !isBad && isDup);
    if (isBad) bad++; else if (isDup) dups++;
  }
  const w = $('#mapWarn'), msg = [];
  if (bad) msg.push(`${bad} ${plural(bad, 'элемент привязан', 'элемента привязаны', 'элементов привязаны')} к байту 0, пока он служебный.`);
  if (dups) msg.push(`${dups} ${plural(dups, 'элемент делит', 'элемента делят', 'элементов делят')} байт с другими, они будут гореть вместе.`);
  w.hidden = !msg.length; w.textContent = msg.join(' ');
  const isDefault = ELEMS.every((e, i) => S.map[e.id] === i + 1);
  $('#mapState').textContent = isDefault ? 'по умолчанию' : 'изменена';
  renderTitles();
}
function highlight(id, on) { if (nodes[id]) nodes[id].g.classList.toggle('hl', on); }

/* ---------- hex view ---------- */
const hex2 = v => v.toString(16).padStart(2, '0');
function renderHex(f = cur(), idx = S.frames.indexOf(f)) {
  if (!$('#dHex').open) return;
  const own = slotOwners();
  let h = '';
  const dur = Math.max(1, Math.min(65535, f.d | 0));
  for (let i = 0; i < FRAME; i++) {
    let v, cls = 'hx', title, ro = false;
    if (i === 46) { v = (dur >> 8) & 0xff; cls += ' ro'; ro = true; title = `Байт 46: длительность, старший байт (${dur} мс)`; }
    else if (i === 47) { v = dur & 0xff; cls += ' ro'; ro = true; title = `Байт 47: длительность, младший байт (${dur} мс)`; }
    else if (i === 0) { v = idx === S.loopFrom ? 1 : 0; cls += ' ro'; ro = true; title = 'Байт 0: метка начала повтора'; }
    else {
      v = f.b[i] | 0; const o = own[i];
      if (!o) cls += ' free'; if (!o && v) cls += ' warn'; if (v) cls += ' on';
      title = `Байт ${i}: ${o ? o.map(id => EL[id].name).join(', ') : 'не назначен'}`;
    }
    h += `<button type="button" class="${cls}" data-slot="${i}" title="${esc(title)}" aria-label="${esc(title)}, значение ${v}"${ro ? ' disabled' : ''}><small>${i}</small>${hex2(v)}</button>`;
  }
  $('#hex').innerHTML = h;
}

/* ---------- binary ---------- */
function fileBase() { return (S.name || 'animation').trim().replace(/\.binscled(\.zst)?$/i, '').replace(/[^A-Za-z0-9_.-]+/g, '_').replace(/^_+|_+$/g, '') || 'animation'; }
function buildRaw() {
  const out = new Uint8Array(S.frames.length * FRAME);
  S.frames.forEach((f, k) => {
    const o = k * FRAME, d = Math.max(1, Math.min(65535, Math.round(f.d || 1)));
    for (let i = 1; i <= LEDS; i++) out[o + i] = clamp8(f.b[i]);
    out[o] = k === S.loopFrom ? 1 : 0;
    out[o + 46] = (d >> 8) & 0xff;   // duration big-endian high
    out[o + 47] = d & 0xff;          // duration low
  });
  return out;
}
/* zstd frame made of raw blocks: valid for any zstd decoder, header mirrors the original files */
function zstdEncode(src) {
  const MAXB = 131072, nb = Math.max(1, Math.ceil(src.length / MAXB));
  const out = new Uint8Array(6 + nb * 3 + src.length);
  out.set([0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x88]);
  let o = 6;
  for (let i = 0; i < nb; i++) {
    const chunk = src.subarray(i * MAXB, Math.min(src.length, (i + 1) * MAXB));
    const h = (i === nb - 1 ? 1 : 0) | (chunk.length << 3);
    out[o++] = h & 255; out[o++] = (h >>> 8) & 255; out[o++] = (h >>> 16) & 255;
    out.set(chunk, o); o += chunk.length;
  }
  return out;
}
function concatU8(list) { const n = list.reduce((a, b) => a + b.length, 0), out = new Uint8Array(n); let o = 0; for (const p of list) { out.set(p, o); o += p.length; } return out; }
/* ---- compact zstd decoder (RFC 8878), no dictionaries ---- */
const ZD = (() => {
  const hb = x => 31 - Math.clz32(x);
  const LL_BASE = [0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,18,20,22,24,28,32,40,48,64,128,256,512,1024,2048,4096,8192,16384,32768,65536];
  const LL_BITS = [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,1,1,1,2,2,3,3,4,6,7,8,9,10,11,12,13,14,15,16];
  const ML_BASE = [3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,37,39,41,43,47,51,59,67,83,99,131,259,515,1027,2051,4099,8195,16387,32771,65539];
  const ML_BITS = [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,1,1,1,2,2,3,3,4,4,5,7,8,9,10,11,12,13,14,15,16];
  const LL_DEF = [4,3,2,2,2,2,2,2,2,2,2,2,2,1,1,1,2,2,2,2,2,2,2,2,2,3,2,1,1,1,1,1,-1,-1,-1,-1];
  const ML_DEF = [1,4,3,2,2,2,2,2,2,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,-1,-1,-1,-1,-1,-1,-1];
  const OF_DEF = [1,1,1,1,1,1,2,2,2,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,-1,-1,-1,-1,-1];
  const fail = m => { throw new Error('zstd: ' + m); };

  class Back {
    constructor(src, s, e) {
      if (e <= s) fail('empty bitstream');
      const last = src[e - 1]; if (!last) fail('bad bitstream end');
      this.src = src; this.s = s; this.pos = (e - 1 - s) * 8 + hb(last);
    }
    read(n) {
      let v = 0;
      for (let k = n - 1; k >= 0; k--) { const i = this.pos - n + k; v = v * 2 + (i < 0 ? 0 : (this.src[this.s + (i >> 3)] >> (i & 7)) & 1); }
      this.pos -= n; return v;
    }
    peek(n) { const p = this.pos, v = this.read(n); this.pos = p; return v; }
    over() { return this.pos < 0; }
  }
  function readNCount(src, start, maxSym, maxAL) {
    let bp = start * 8;
    const peek = n => { let v = 0; for (let k = 0; k < n; k++) { const i = bp + k; v |= ((src[i >> 3] >> (i & 7)) & 1) << k; } return v; };
    const rd = n => { const v = peek(n); bp += n; return v; };
    const AL = rd(4) + 5; if (AL > maxAL) fail('accuracy too high');
    let remaining = (1 << AL) + 1, threshold = 1 << AL, nb = AL + 1, sym = 0;
    const norm = [];
    while (remaining > 1 && sym <= maxSym) {
      const max = (2 * threshold - 1) - remaining;
      let count;
      const low = peek(nb - 1) ;
      if (low < max) { count = low; bp += nb - 1; }
      else { count = peek(nb); bp += nb; if (count >= threshold) count -= max; }
      count--;
      remaining -= count < 0 ? -count : count;
      norm[sym++] = count;
      if (count === 0) { for (;;) { const r = rd(2); for (let k = 0; k < r; k++) norm[sym++] = 0; if (r !== 3) break; } }
      while (remaining < threshold) { nb--; threshold >>= 1; }
    }
    if (remaining !== 1) fail('bad table description');
    return {AL, norm, size: ((bp + 7) >> 3) - start};
  }
  function buildFse(norm, AL) {
    const size = 1 << AL, sym = new Uint8Array(size), base = new Int32Array(size), nbt = new Uint8Array(size), next = [];
    let high = size - 1;
    for (let s = 0; s < norm.length; s++) { const c = norm[s] | 0; if (c === -1) { sym[high--] = s; next[s] = 1; } else next[s] = c; }
    const step = (size >> 1) + (size >> 3) + 3, mask = size - 1; let pos = 0;
    for (let s = 0; s < norm.length; s++) for (let i = 0; i < (norm[s] | 0); i++) { sym[pos] = s; do { pos = (pos + step) & mask; } while (pos > high); }
    for (let u = 0; u < size; u++) { const s = sym[u], x = next[s]++, b = AL - hb(x); nbt[u] = b; base[u] = (x << b) - size; }
    return {al: AL, sym, base, nb: nbt};
  }
  const DEF = {};
  function getTable(mode, src, p, key, def, defAL, maxSym, maxAL, prev) {
    if (mode === 0) return [DEF[key] || (DEF[key] = buildFse(def, defAL)), p];
    if (mode === 1) return [{al: 0, sym: new Uint8Array([src[p]]), base: new Int32Array(1), nb: new Uint8Array(1)}, p + 1];
    if (mode === 2) { const r = readNCount(src, p, maxSym, maxAL); return [buildFse(r.norm, r.AL), p + r.size]; }
    if (!prev) fail('repeat table without previous');
    return [prev, p];
  }
  function readHuff(src, p) {
    const h = src[p], w = [];
    let q;
    if (h < 128) {
      const s = p + 1, r = readNCount(src, s, 255, 6), t = buildFse(r.norm, r.AL), br = new Back(src, s + r.size, s + h);
      let s1 = br.read(r.AL), s2 = br.read(r.AL);
      for (;;) {
        w.push(t.sym[s1]); s1 = t.base[s1] + br.read(t.nb[s1]);
        if (br.over()) { w.push(t.sym[s2]); break; }
        w.push(t.sym[s2]); s2 = t.base[s2] + br.read(t.nb[s2]);
        if (br.over()) { w.push(t.sym[s1]); break; }
        if (w.length > 255) fail('too many weights');
      }
      q = s + h;
    } else {
      const n = h - 127;
      for (let i = 0; i < n; i++) { const b = src[p + 1 + (i >> 1)]; w.push(i & 1 ? b & 15 : b >> 4); }
      q = p + 1 + ((n + 1) >> 1);
    }
    let sum = 0; for (const x of w) if (x) sum += 1 << (x - 1);
    if (!sum) fail('empty huffman');
    const maxBits = hb(sum) + 1, rest = (1 << maxBits) - sum;
    if (rest & (rest - 1)) fail('bad huffman weights');
    w.push(hb(rest) + 1);
    const cnt = new Array(maxBits + 2).fill(0); for (const x of w) if (x) cnt[x]++;
    const start = []; let nx = 0; for (let x = 1; x <= maxBits; x++) { start[x] = nx; nx += cnt[x] << (x - 1); }
    const size = 1 << maxBits, sym = new Uint8Array(size), nbt = new Uint8Array(size);
    for (let n = 0; n < w.length; n++) { const x = w[n]; if (!x) continue; const len = (1 << x) >> 1; for (let i = start[x]; i < start[x] + len; i++) { sym[i] = n; nbt[i] = maxBits + 1 - x; } start[x] += len; }
    return {table: {maxBits, sym, nb: nbt}, end: q};
  }
  function huffStream(src, s, e, out, o0, o1, t) {
    const br = new Back(src, s, e);
    for (let i = o0; i < o1; i++) { const idx = br.peek(t.maxBits); out[i] = t.sym[idx]; br.pos -= t.nb[idx]; }
  }
  class Out {
    constructor() { this.buf = new Uint8Array(1 << 15); this.n = 0; }
    ensure(k) { if (this.n + k > this.buf.length) { let s = this.buf.length; while (s < this.n + k) s *= 2; const b = new Uint8Array(s); b.set(this.buf.subarray(0, this.n)); this.buf = b; } }
    push(a) { this.ensure(a.length); this.buf.set(a, this.n); this.n += a.length; }
    fill(v, k) { this.ensure(k); this.buf.fill(v, this.n, this.n + k); this.n += k; }
    match(off, len) { if (off <= 0 || off > this.n) fail('bad offset'); this.ensure(len); const b = this.buf; let s = this.n - off; for (let i = 0; i < len; i++) b[this.n++] = b[s++]; }
  }
  function block(src, p, end, out, st) {
    const b0 = src[p], lt = b0 & 3, sf = (b0 >> 2) & 3;
    let regen, csize = 0, hs, streams = 1;
    if (lt < 2) {
      if ((sf & 1) === 0) { regen = b0 >> 3; hs = 1; }
      else if (sf === 1) { regen = (b0 >> 4) | (src[p + 1] << 4); hs = 2; }
      else { regen = (b0 >> 4) | (src[p + 1] << 4) | (src[p + 2] << 12); hs = 3; }
    } else if (sf < 2) { const v = b0 | (src[p + 1] << 8) | (src[p + 2] << 16); regen = (v >> 4) & 0x3FF; csize = (v >> 14) & 0x3FF; streams = sf === 0 ? 1 : 4; hs = 3; }
    else if (sf === 2) { const v = (b0 | (src[p + 1] << 8) | (src[p + 2] << 16) | (src[p + 3] << 24)) >>> 0; regen = (v >>> 4) & 0x3FFF; csize = (v >>> 18) & 0x3FFF; streams = 4; hs = 4; }
    else { const v = (b0 | (src[p + 1] << 8) | (src[p + 2] << 16) | (src[p + 3] << 24)) >>> 0; regen = (v >>> 4) & 0x3FFFF; csize = ((v >>> 22) | (src[p + 4] << 10)) & 0x3FFFF; streams = 4; hs = 5; }
    p += hs;
    let lits;
    if (lt === 0) { lits = src.subarray(p, p + regen); p += regen; }
    else if (lt === 1) { lits = new Uint8Array(regen).fill(src[p]); p += 1; }
    else {
      let q = p; const ce = p + csize;
      if (lt === 2) { const r = readHuff(src, q); st.huf = r.table; q = r.end; } else if (!st.huf) fail('treeless literals without table');
      lits = new Uint8Array(regen);
      if (streams === 1) huffStream(src, q, ce, lits, 0, regen, st.huf);
      else {
        const l1 = src[q] | (src[q + 1] << 8), l2 = src[q + 2] | (src[q + 3] << 8), l3 = src[q + 4] | (src[q + 5] << 8), seg = Math.floor((regen + 3) / 4);
        let a = q + 6;
        huffStream(src, a, a + l1, lits, 0, seg, st.huf); a += l1;
        huffStream(src, a, a + l2, lits, seg, 2 * seg, st.huf); a += l2;
        huffStream(src, a, a + l3, lits, 2 * seg, 3 * seg, st.huf); a += l3;
        huffStream(src, a, ce, lits, 3 * seg, regen, st.huf);
      }
      p = ce;
    }
    let ns; const s0 = src[p++];
    if (s0 < 128) ns = s0; else if (s0 < 255) ns = ((s0 - 128) << 8) + src[p++]; else { ns = src[p] + (src[p + 1] << 8) + 0x7F00; p += 2; }
    if (!ns) { out.push(lits); return; }
    const m = src[p++];
    [st.ll, p] = getTable(m >> 6, src, p, 'll', LL_DEF, 6, 35, 9, st.ll);
    [st.of, p] = getTable((m >> 4) & 3, src, p, 'of', OF_DEF, 5, 31, 8, st.of);
    [st.ml, p] = getTable((m >> 2) & 3, src, p, 'ml', ML_DEF, 6, 52, 9, st.ml);
    const br = new Back(src, p, end), LL = st.ll, OF = st.of, ML = st.ml;
    let sl = br.read(LL.al), so = br.read(OF.al), sm = br.read(ML.al), lp = 0;
    const rep = st.rep;
    for (let i = 0; i < ns; i++) {
      const oc = OF.sym[so], lc = LL.sym[sl], mc = ML.sym[sm];
      const ov = Math.pow(2, oc) + br.read(oc);
      const ml = ML_BASE[mc] + br.read(ML_BITS[mc]);
      const ll = LL_BASE[lc] + br.read(LL_BITS[lc]);
      let off;
      if (ov > 3) { off = ov - 3; rep[2] = rep[1]; rep[1] = rep[0]; rep[0] = off; }
      else {
        const idx = ov - 1 + (ll === 0 ? 1 : 0);
        if (idx === 0) off = rep[0];
        else {
          off = idx === 3 ? rep[0] - 1 : rep[idx];
          if (idx !== 1) rep[2] = rep[1];
          rep[1] = rep[0]; rep[0] = off;
        }
      }
      if (lp + ll > lits.length) fail('literals overrun');
      out.push(lits.subarray(lp, lp + ll)); lp += ll;
      out.match(off, ml);
      if (i < ns - 1) { sl = LL.base[sl] + br.read(LL.nb[sl]); sm = ML.base[sm] + br.read(ML.nb[sm]); so = OF.base[so] + br.read(OF.nb[so]); }
    }
    out.push(lits.subarray(lp));
  }
  function decompress(src) {
    const out = new Out(); let p = 0;
    const u32 = i => (src[i] | (src[i + 1] << 8) | (src[i + 2] << 16) | (src[i + 3] << 24)) >>> 0;
    while (p + 4 <= src.length) {
      const mg = u32(p);
      if (((mg & 0xFFFFFFF0) >>> 0) === 0x184D2A50) { p += 8 + u32(p + 4); continue; }
      if (mg !== 0xFD2FB528) fail('not a zstd frame');
      p += 4;
      const fhd = src[p++], fcs = fhd >> 6, single = (fhd >> 5) & 1, cs = (fhd >> 2) & 1, did = fhd & 3;
      if (!single) p++;
      let dict = 0; for (let k = 0; k < [0, 1, 2, 4][did]; k++) dict |= src[p + k] << (8 * k);
      if (dict) fail('dictionaries are not supported');
      p += [0, 1, 2, 4][did];
      p += fcs === 0 ? (single ? 1 : 0) : [0, 2, 4, 8][fcs];
      const st = {rep: [1, 4, 8], huf: null, ll: null, of: null, ml: null};
      for (;;) {
        if (p + 3 > src.length) fail('truncated');
        const h = src[p] | (src[p + 1] << 8) | (src[p + 2] << 16); p += 3;
        const last = h & 1, type = (h >> 1) & 3, size = h >>> 3;
        if (type === 0) { out.push(src.subarray(p, p + size)); p += size; }
        else if (type === 1) { out.fill(src[p], size); p += 1; }
        else if (type === 2) { block(src, p, p + size, out, st); p += size; }
        else fail('reserved block type');
        if (last) break;
      }
      if (cs) p += 4;
    }
    return out.buf.slice(0, out.n);
  }
  return {decompress};
})();
async function streamThrough(u8, fmt) {
  const ds = new DecompressionStream(fmt);
  return new Uint8Array(await new Response(new Blob([u8]).stream().pipeThrough(ds)).arrayBuffer());
}
function zstdDecompress(u8) {
  try { return ZD.decompress(u8); }
  catch (e) { throw new Error('Файл .zst не распаковался: ' + e.message.replace(/^zstd: /, '') + '.'); }
}
const CRC = (() => { const t = new Uint32Array(256); for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1; t[n] = c >>> 0; } return t; })();
function crc32(u8) { let c = 0xFFFFFFFF; for (let i = 0; i < u8.length; i++) c = CRC[(c ^ u8[i]) & 255] ^ (c >>> 8); return (c ^ 0xFFFFFFFF) >>> 0; }
function makeZip(name, data) {
  const nm = new TextEncoder().encode(name), crc = crc32(data), d = new Date();
  const time = (d.getHours() << 11) | (d.getMinutes() << 5) | (d.getSeconds() >> 1);
  const date = ((d.getFullYear() - 1980) << 9) | ((d.getMonth() + 1) << 5) | d.getDate();
  const lh = new DataView(new ArrayBuffer(30)), ch = new DataView(new ArrayBuffer(46)), eo = new DataView(new ArrayBuffer(22));
  lh.setUint32(0, 0x04034b50, true); lh.setUint16(4, 20, true); lh.setUint16(6, 0x0800, true); lh.setUint16(8, 0, true);
  lh.setUint16(10, time, true); lh.setUint16(12, date, true); lh.setUint32(14, crc, true); lh.setUint32(18, data.length, true); lh.setUint32(22, data.length, true);
  lh.setUint16(26, nm.length, true); lh.setUint16(28, 0, true);
  ch.setUint32(0, 0x02014b50, true); ch.setUint16(4, 20, true); ch.setUint16(6, 20, true); ch.setUint16(8, 0x0800, true); ch.setUint16(10, 0, true);
  ch.setUint16(12, time, true); ch.setUint16(14, date, true); ch.setUint32(16, crc, true); ch.setUint32(20, data.length, true); ch.setUint32(24, data.length, true);
  ch.setUint16(28, nm.length, true); ch.setUint32(42, 0, true);
  const cdOff = 30 + nm.length + data.length, cdSize = 46 + nm.length;
  eo.setUint32(0, 0x06054b50, true); eo.setUint16(8, 1, true); eo.setUint16(10, 1, true); eo.setUint32(12, cdSize, true); eo.setUint32(16, cdOff, true);
  return concatU8([new Uint8Array(lh.buffer), nm, data, new Uint8Array(ch.buffer), nm, new Uint8Array(eo.buffer)]);
}
async function unzipFirst(u8) {
  const dv = new DataView(u8.buffer, u8.byteOffset, u8.byteLength);
  let e = -1;
  for (let i = u8.length - 22; i >= Math.max(0, u8.length - 65557); i--) if (dv.getUint32(i, true) === 0x06054b50) { e = i; break; }
  if (e < 0) throw new Error('Архив повреждён.');
  const cnt = dv.getUint16(e + 10, true); let p = dv.getUint32(e + 16, true);
  const ents = [];
  for (let k = 0; k < cnt; k++) {
    if (dv.getUint32(p, true) !== 0x02014b50) break;
    const method = dv.getUint16(p + 10, true), csize = dv.getUint32(p + 20, true), nl = dv.getUint16(p + 28, true), xl = dv.getUint16(p + 30, true), cl = dv.getUint16(p + 32, true), off = dv.getUint32(p + 42, true);
    ents.push({name: new TextDecoder().decode(u8.subarray(p + 46, p + 46 + nl)), method, csize, off});
    p += 46 + nl + xl + cl;
  }
  const ent = ents.find(x => /\.(zst|binscled)$/i.test(x.name)) || ents.find(x => !x.name.endsWith('/'));
  if (!ent) throw new Error('В архиве нет файлов.');
  const ds = ent.off + 30 + dv.getUint16(ent.off + 26, true) + dv.getUint16(ent.off + 28, true);
  const body = u8.subarray(ds, ds + ent.csize);
  if (ent.method === 0) return {name: ent.name, data: body};
  if (ent.method === 8) return {name: ent.name, data: await streamThrough(body, 'deflate-raw')};
  throw new Error('Неизвестный способ сжатия в архиве.');
}
function parseRaw(u8) {
  if (u8.length < FRAME) throw new Error(`Файл короче одного кадра (${u8.length} байт из 48).`);
  const n = Math.floor(u8.length / FRAME);
  let loopFrom = -1, badKey = 0;
  for (let k = 0; k < n; k++) { const key = u8[k * FRAME]; if (key === 1) loopFrom = k; else if (key !== 0) badKey++; }
  const frames = [];
  for (let k = 0; k < n; k++) {
    const o = k * FRAME, b = new Array(NSLOT).fill(0);
    for (let i = 1; i <= LEDS; i++) b[i] = u8[o + i];
    const d = (u8[o + 46] << 8) | u8[o + 47];
    frames.push({b, d: d || 1});
  }
  return {frames, loopFrom, badKey, extra: u8.length % FRAME};
}
function b64ToU8(s) { const bin = atob(s); const u = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i); return u; }
function u8ToB64(u8) { let s = ''; for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000)); return btoa(s); }

/* ---------- load / import ---------- */
function loadProject(frames, name, loopFrom) {
  stopPlay(); pushUndo();
  S.frames = frames; S.cur = 0;
  if (name) { S.name = name; $('#nameIn').value = name; }
  S.loopFrom = Number.isInteger(loopFrom) ? Math.min(loopFrom, frames.length - 1) : 0;
  refresh(true);
}
async function importFile(file) {
  try {
    let u8 = new Uint8Array(await file.arrayBuffer());
    let name = file.name;
    if (u8[0] === 0x50 && u8[1] === 0x4B) { const z = await unzipFirst(u8); u8 = z.data; name = z.name; }
    if (u8.length >= 4 && u8[0] === 0x28 && u8[1] === 0xB5 && u8[2] === 0x2F && u8[3] === 0xFD) u8 = zstdDecompress(u8);
    const r = parseRaw(u8);
    const base = name.split('/').pop().replace(/(\.zip)?$/i, '').replace(/[._]binscled([._]zst)?$/i, '').replace(/\.zst$/i, '');
    loadProject(r.frames, base, r.loopFrom);
    let msg = `Открыто: ${r.frames.length} ${plural(r.frames.length, 'кадр', 'кадра', 'кадров')}.`;
    msg += r.loopFrom < 0 ? ' Без повтора: проиграется один раз.' : ` Повтор с кадра ${r.loopFrom + 1}.`;
    if (r.badKey) msg += ` В ${r.badKey} ${plural(r.badKey, 'кадре', 'кадрах', 'кадрах')} байт 0 не 0 и не 1, станция такой файл не примет.`;
    if (r.extra) msg += ` Лишние ${r.extra} байт в конце отброшены.`;
    toast(msg);
  } catch (e) { toast(e.message || 'Файл не прочитался.'); }
}
const RINGING_B64 = 'AQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUAAAAAAAAAAAAAAAFBQAAAAAAAAAAAAAFBQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUAAAAAAAAAAAAAAAUFAAAAAAAAAAAAAAUFAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUAAAAAAAAAAAAAAAoKAAAAAAAAAAAAAAoKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUAAAAAAAAAAAAAABAQAAAAAAAAAAAAABAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUAAAAAAAAAAAAAABXVwAAAAAAAAAAAABXVwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUAAAAAAAAAAAAAABsbAAAAAAAAAAAAABsbAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUAAAAAAAAAAAAAAB6egAAAAAAAAAAAAB6egAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUAAAAAAAAAAAAAACAgAAAAAAAAAAAAACAgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUAAAAAAAAAAAAAACFhQAFBQAAAAAFBQCFhQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUAAAAAAAAAAAAAACTkwAUFAAAAAAUFACTkwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUAAAAAAAAAAAAAACoqAAoKAAAAAAoKACoqAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUAAAAAAAAAAAAAAC/vwBAQAAAAABAQAC/vwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUAAAAAAAAAAAAAADX1wBXVwAAAABXVwDX1wAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUAAAAAAAAAAAAAADr6wBsbAAAAABsbADr6wAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUAAAAAAAAAAAAAAD6+gB6egAAAAB6egD6+gAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUAAAAAAAAAAAAAAD//wCAgAAAAACAgAD//wAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUAAAFBQAAAAAAAAD//wCFhQAAAACFhQD//wAAAAAAAAAFBQAAAAAAAAAAAAAAAAAUAAAUFAAAAAAAAAD//wCTkwAAAACTkwD//wAAAAAAAAAUFAAAAAAAAAAAAAAAAAAUAAAoKAAAAAAAAAD//wCoqAAAAACoqAD//wAAAAAAAAAoKAAAAAAAAAAAAAAAAAAUAABAQAAAAAAAAAD//wC/vwAAAAC/vwD//wAAAAAAAABAQAAAAAAAAAAAAAAAAAAUAABXVwAAAAAAAAD//wDX1wAAAADX1wD//wAAAAAAAABXVwAAAAAAAAAAAAAAAAAUAABsbAAAAAAAAAD//wDr6wAAAADr6wD//wAAAAAAAABsbAAAAAAAAAAAAAAAAAAUAAB6egAAAAAAAAD//wD6+gAAAAD6+gD//wAAAAAAAAB6egAAAAAAAAAAAAAAAAAUAACAgAAAAAAAAAD//wD//wAAAAD//wD//wAAAAAAAACAgAAAAAAAAAAAAAAAAAAUAACFhQAFBQAAAAD6+gD//wAAAAD//wD6+gAAAAAFBQCFhQAAAAAAAAAAAAAAAAAUAACTkwAUFAAAAADr6wD//wAAAAD//wDr6wAAAAAUFACTkwAAAAAAAAAAAAAAAAAUAACoqAAoKAAAAADX1wD//wAAAAD//wDX1wAAAAAoKACoqAAAAAAAAAAAAAAAAAAUAAC/vwBAQAAAAAC/vwD//wAAAAD//wC/vwAAAABAQAC/vwAAAAAAAAAAAAAAAAAUAADX1wBXVwAAAACoqAD//wAAAAD//wCoqAAAAABXVwDX1wAAAAAAAAAAAAAAAAAUAADr6wBsbAAAAACTkwD//wAAAAD//wCTkwAAAABsbADr6wAAAAAAAAAAAAAAAAAUAAD6+gB6egAAAACFhQD//wAAAAD//wCFhQAAAAB6egD6+gAAAAAAAAAAAAAAAAAUAAD//wCAgAAAAACAgAD//wAAAAD//wCAgAAAAACAgAD//wAAAAAAAAAAAAAAAAAUAAD//wCFhQAAAAB6egD6+gAAAAD6+gB6egAAAACFhQD//wAAAAAAAAAAAAAAAAAUAAD//wCTkwAAAABsbADr6wAAAADr6wBsbAAAAACTkwD//wAAAAAAAAAAAAAAAAAUAAD//wCoqAAAAABXVwDX1wAAAADX1wBXVwAAAACoqAD//wAAAAAAAAAAAAAAAAAUAAD//wC/vwAAAABAQAC/vwAAAAC/vwBAQAAAAAC/vwD//wAAAAAAAAAAAAAAAAAUAAD//wDX1wAAAAAoKACoqAAAAACoqAAoKAAAAADX1wD//wAAAAAAAAAAAAAAAAAUAAD//wDr6wAAAAAUFACTkwAAAACTkwAUFAAAAADr6wD//wAAAAAAAAAAAAAAAAAUAAD//wD6+gAAAAAFBQCFhQAAAACFhQAFBQAAAAD6+gD//wAAAAAAAAAAAAAAAAAUAAD//wD//wAAAAAAAACAgAAAAACAgAAAAAAAAAD//wD//wAAAAAAAAAAAAAAAAAUAAD6+gD//wAAAAAAAAB6egAAAAB6egAAAAAAAAD//wD6+gAAAAAAAAAAAAAAAAAUAADr6wD//wAAAAAAAABsbAAAAABsbAAAAAAAAAD//wDr6wAAAAAAAAAAAAAAAAAUAADX1wD//wAAAAAAAABXVwAAAABXVwAAAAAAAAD//wDX1wAAAAAAAAAAAAAAAAAUAAC/vwD//wAAAAAAAABAQAAAAABAQAAAAAAAAAD//wC/vwAAAAAAAAAAAAAAAAAUAACoqAD//wAAAAAAAAAoKAAAAAAoKAAAAAAAAAD//wCoqAAAAAAAAAAAAAAAAAAUAACTkwD//wAAAAAAAAAUFAAAAAAUFAAAAAAAAAD//wCTkwAAAAAAAAAAAAAAAAAUAACFhQD//wAAAAAAAAAFBQAAAAAFBQAAAAAAAAD//wCFhQAAAAAAAAAAAAAAAAAUAACAgAD//wAAAAAAAAAAAAAAAAAAAAAAAAAAAAD//wCAgAAAAAAAAAAAAAAAAAAUAAB6egD6+gAAAAAAAAAAAAAAAAAAAAAAAAAAAAD6+gB6egAAAAAAAAAAAAAAAAAUAABsbADr6wAAAAAAAAAAAAAAAAAAAAAAAAAAAADr6wBsbAAAAAAAAAAAAAAAAAAUAABXVwDX1wAAAAAAAAAAAAAAAAAAAAAAAAAAAADX1wBXVwAAAAAAAAAAAAAAAAAUAABAQAC/vwAAAAAAAAAAAAAAAAAAAAAAAAAAAAC/vwBAQAAAAAAAAAAAAAAAAAAUAAAoKACoqAAAAAAAAAAAAAAAAAAAAAAAAAAAAACoqAAoKAAAAAAAAAAAAAAAAAAUAAAUFACTkwAAAAAAAAAAAAAAAAAAAAAAAAAAAACTkwAUFAAAAAAAAAAAAAAAAAAUAAAFBQCFhQAAAAAAAAAAAAAAAAAAAAAAAAAAAACFhQAFBQAAAAAAAAAAAAAAAAAUAAAAAACAgAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAgAAAAAAAAAAAAAAAAAAAAAAUAAAAAAB6egAAAAAAAAAAAAAAAAAAAAAAAAAAAAB6egAAAAAAAAAAAAAAAAAAAAAUAAAAAABsbAAAAAAAAAAAAAAAAAAAAAAAAAAAAABsbAAAAAAAAAAAAAAAAAAAAAAUAAAAAABXVwAAAAAAAAAAAAAAAAAAAAAAAAAAAABXVwAAAAAAAAAAAAAAAAAAAAAUAAAAAABAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAQAAAAAAAAAAAAAAAAAAAAAAUAAAAAAAoKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAoKAAAAAAAAAAAAAAAAAAAAAAUAAAAAAAUFAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUFAAAAAAAAAAAAAAAAAAAAAAUAAAAAAAFBQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFBQAAAAAAAAAAAAAAAAAAAAAUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAU';
function presetFrames(key) {
  if (key === 'ringing') return {...parseRaw(b64ToU8(RINGING_B64)), name:'ringing'};
  if (key === 'update') { const u = new Uint8Array(48); u[0] = 1; u[47] = 20; return {...parseRaw(u), name:'update_applying'}; }
  const loopFrom = 0;
  if (key === 'clock') {
    const a = {b: blankB(), d: 500}, b = {b: blankB(), d: 500};
    applyText(a, '08:24', 255); applyText(b, '08 24', 255); setVal(a, 'dot', 255); setVal(b, 'dot', 255);
    return {frames:[a, b], loopFrom, name:'clock'};
  }
  if (key === 'wave') {
    const frames = [], order = ['d1','d2','mid','d4','d5','dot'];
    for (let step = 0; step < order.length + 3; step++) {
      const f = {b: blankB(), d: 90};
      order.forEach((g, i) => { const dist = step - i; const v = dist === 0 ? 255 : dist === 1 ? 110 : dist === 2 ? 30 : 0; for (const e of ELEMS) if (e.g === g) setVal(f, e.id, v); });
      frames.push(f);
    }
    return {frames, loopFrom, name:'wave'};
  }
  if (key === 'scan') {
    const all = blankB(); for (let i = 1; i <= LEDS; i++) all[i] = 255;
    const frames = [{b: all, d: 800, n:'всё'}, {b: blankB(), d: 500}];
    for (let s = 1; s <= LEDS; s++) { const b = blankB(); b[s] = 255; frames.push({b, d: 450, n:`байт ${s}`}); frames.push({b: blankB(), d: 150}); }
    return {frames, loopFrom, name:'scan'};
  }
  return {frames:[{b: blankB(), d: 20}], loopFrom, name:'animation'};
}

/* ---------- download ---------- */
let dlCap = null;
const hasUse = !!(window.claude && typeof window.claude.use === 'function');
if (hasUse) window.claude.use('downloads').then(d => { dlCap = d; }).catch(() => {});
async function download(raw) {
  stopPlay();
  const zst = raw ? buildRaw() : zstdEncode(buildRaw()), fname = fileBase() + (raw ? '.binscled' : '.binscled.zst');
  if (dlCap) {
    try {
      await dlCap.save({filename: fname + '.zip', data: new Blob([makeZip(fname, zst)])});
      toast(`Сохранено: ${fname}.zip`);
    } catch (e) {
      const code = e && e.code;
      if (code === 'declined') toast('Скачивание отменено.');
      else if (code === 'rate_limited') toast('Окно сохранения уже открыто. Подожди пару секунд.');
      else { toast('Скачать здесь не получилось. Возьми файл как base64 в разделе «Файл».'); showB64(); }
    }
    return;
  }
  if (hasUse) { toast('Скачивание тут недоступно. Возьми файл как base64 в разделе «Файл».'); showB64(); return; }
  const url = URL.createObjectURL(new Blob([zst], {type: 'application/octet-stream'}));
  const a = document.createElement('a'); a.href = url; a.download = fname; document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 4000);
  toast(`Сохранено: ${fname}`);
}
function fillB64() {
  const fname = fileBase() + '.binscled.zst';
  $('#b64Out').value = `printf '%s' '${u8ToB64(zstdEncode(buildRaw()))}' | base64 -d > ${fname}`;
}
function showB64() { $('#dFile').open = true; $('#b64Box').hidden = false; fillB64(); $('#b64Box').scrollIntoView({block: 'nearest', behavior: 'smooth'}); }

/* ---------- toast ---------- */
let toastT = 0;
function toast(msg) { const t = $('#toast'); t.textContent = msg; t.classList.add('show'); clearTimeout(toastT); toastT = setTimeout(() => t.classList.remove('show'), 3800); }

/* ---------- wiring ---------- */
function setBrush(v) {
  S.brush = clamp8(v);
  $('#brush').value = S.brush; $('#brushOut').textContent = S.brush;
  $('#swatch').style.background = S.brush ? mix(OFF, ON, tOf(S.brush)) : 'transparent';
  $('#swatch').style.borderColor = S.brush ? '#e2b13c' : 'var(--text-2)';
  for (const c of document.querySelectorAll('#brushChips .chip')) c.classList.toggle('on', +c.dataset.b === S.brush);
  save();
}
function init() {
  buildDisplay(); bindDisplay(); buildMapUI();
  $('#nameIn').value = S.name;
  setBrush(S.brush);
  refresh(true);

  $('#brush').addEventListener('input', e => setBrush(e.target.value));
  $('#brushChips').addEventListener('click', e => { const c = e.target.closest('.chip'); if (c) setBrush(c.dataset.b); });
  $('#btnClear').onclick = opClear; $('#btnFill').onclick = opFill; $('#btnInvert').onclick = opInvert;
  $('#btnUndo').onclick = doUndo; $('#btnRedo').onclick = doRedo;
  $('#btnAdd').onclick = opAdd; $('#btnDup').onclick = opDup; $('#btnDel').onclick = opDel;
  $('#btnLeft').onclick = () => opMove(-1); $('#btnRight').onclick = () => opMove(1);
  $('#btnPlay').onclick = () => play ? stopPlay() : startPlay();
  let lastLoop = Math.max(0, S.loopFrom);
  $('#btnLoop').onclick = () => { stopPlay(); pushUndo(); if (S.loopFrom >= 0) { lastLoop = S.loopFrom; S.loopFrom = -1; toast('Без повтора: анимация проиграется один раз и погаснет.'); } else { S.loopFrom = Math.min(lastLoop, S.frames.length - 1); toast(`Повтор с кадра ${S.loopFrom + 1}.`); } refresh(true); };
  $('#btnLoopHere').onclick = () => { stopPlay(); pushUndo(); S.loopFrom = S.cur; lastLoop = S.cur; refresh(true); toast(`Повтор с кадра ${S.cur + 1}: после последнего кадра анимация вернётся сюда.`); };
  $('#btnRaw').onclick = () => download(true);
  $('#strip').addEventListener('click', e => { const t = e.target.closest('.thumb'); if (t) selectFrame(+t.dataset.i); });
  $('#durIn').addEventListener('change', e => { const v = Math.max(1, Math.min(65535, parseInt(e.target.value, 10) || 1)); stopPlay(); pushUndo(); cur().d = v; e.target.value = v; refresh(false); });
  $('#btnDurAll').onclick = () => { const v = Math.max(1, Math.min(65535, parseInt($('#durIn').value, 10) || 1)); stopPlay(); pushUndo(); S.frames.forEach(f => f.d = v); refresh(true); toast(`У всех кадров теперь ${v} мс.`); };

  $('#nameIn').addEventListener('input', e => { S.name = e.target.value; renderMeta(); save(); });
  $('#btnDownload').onclick = () => download(false); $('#btnDownload2').onclick = () => download(false);
  $('#btnOpen').onclick = () => $('#fileIn').click();
  $('#fileIn').addEventListener('change', e => { const f = e.target.files[0]; if (f) importFile(f); e.target.value = ''; });
  document.addEventListener('dragover', e => e.preventDefault());
  document.addEventListener('drop', e => { e.preventDefault(); const f = e.dataTransfer && e.dataTransfer.files[0]; if (f) importFile(f); });
  $('#presetSel').addEventListener('change', e => {
    const k = e.target.value; if (!k) return;
    const p = presetFrames(k); loadProject(p.frames, p.name, p.loopFrom); e.target.value = '';
    toast(`Загружен пример: ${p.name}. Отменить можно кнопкой «Отменить».`);
  });
  $('#btnB64').onclick = () => { if ($('#b64Box').hidden) showB64(); else $('#b64Box').hidden = true; };
  $('#btnCopy').onclick = async () => {
    const ta = $('#b64Out');
    try { await navigator.clipboard.writeText(ta.value); toast('Скопировано.'); }
    catch (e) { ta.focus(); ta.select(); try { document.execCommand('copy'); toast('Скопировано.'); } catch (e2) { toast('Выдели текст и скопируй вручную.'); } }
  };

  $('#btnText').onclick = () => { stopPlay(); pushUndo(); const bad = applyText(cur(), $('#txtIn').value, onV()); refresh(false); if (bad.length) toast(`Нет символа для: ${[...new Set(bad)].join(' ')}. Там пусто.`); };
  $('#btnMq').onclick = () => {
    const txt = $('#mqIn').value; if (!txt.trim()) { toast('Впиши текст для бегущей строки.'); return; }
    const step = Math.max(1, Math.min(65535, parseInt($('#mqStep').value, 10) || 220));
    const chars = [...'    ' + txt + '    '], base = cur(), list = [], v = onV();
    for (let i = 0; i + 4 <= chars.length; i++) { const f = cloneF(base); delete f.n; f.d = step; DIGITS.forEach((d, k) => setDigit(f, d.n, glyphFor(chars[i + k]) || '', v)); list.push(f); }
    stopPlay(); pushUndo();
    if ($('#mqReplace').checked) { S.frames = list; S.cur = 0; S.loopFrom = S.loopFrom < 0 ? -1 : 0; } else { insertFrames(S.cur + 1, list); S.cur++; }
    refresh(true); toast(`Добавлено ${list.length} ${plural(list.length, 'кадр', 'кадра', 'кадров')}.`);
  };
  $('#btnTween').onclick = opTween; $('#btnFadeIn').onclick = () => opFade(true); $('#btnFadeOut').onclick = () => opFade(false); $('#btnMerge').onclick = opMerge;

  $('#mapGrid').addEventListener('change', e => {
    const inp = e.target.closest('[data-map]'); if (!inp) return;
    const v = parseInt(inp.value, 10);
    if (!Number.isInteger(v) || !ledOK(v)) { inp.value = S.map[inp.dataset.map]; toast('Номер байта от 1 до 45.'); return; }
    stopPlay(); S.map[inp.dataset.map] = v; validateMap(); refresh(true);
  });
  $('#mapGrid').addEventListener('focusin', e => { const i = e.target.closest('[data-map]'); if (i) highlight(i.dataset.map, true); });
  $('#mapGrid').addEventListener('focusout', e => { const i = e.target.closest('[data-map]'); if (i) highlight(i.dataset.map, false); });
  $('#btnMapReset').onclick = () => { S.map = defaultMap(); syncMapUI(); refresh(true); toast('Карта байтов сброшена.'); };
  $('#btnProbe').onclick = () => {
    const s = parseInt($('#probeIn').value, 10);
    if (!Number.isInteger(s) || s < 1 || s > LEDS) { toast('Номер байта от 1 до 45.'); return; }
    stopPlay(); pushUndo(); const b = blankB(); b[s] = 255; insertFrames(S.cur + 1, [{b, d: 1000, n: `байт ${s}`}]); S.cur++; refresh(true);
  };

  $('#dHex').addEventListener('toggle', () => renderHex());
  $('#hex').addEventListener('click', e => {
    const c = e.target.closest('.hx'); if (!c || c.disabled) return;
    const s = +c.dataset.slot; stopPlay(); pushUndo();
    const f = cur(); f.b[s] = S.brush === 0 ? 0 : (f.b[s] === S.brush ? 0 : S.brush); refresh(false);
  });
  $('#hex').addEventListener('pointerover', e => { const c = e.target.closest('.hx'); if (!c) return; const own = slotOwners()[+c.dataset.slot] || []; own.forEach(id => highlight(id, true)); });
  $('#hex').addEventListener('pointerout', e => { const c = e.target.closest('.hx'); if (!c) return; const own = slotOwners()[+c.dataset.slot] || []; own.forEach(id => highlight(id, false)); });

  document.addEventListener('keydown', e => {
    const tag = (e.target.tagName || '').toLowerCase();
    if (tag === 'input' || tag === 'textarea' || tag === 'select') return;
    const mod = e.ctrlKey || e.metaKey;
    if (mod && e.key.toLowerCase() === 'z') { e.preventDefault(); e.shiftKey ? doRedo() : doUndo(); }
    else if (mod && e.key.toLowerCase() === 'y') { e.preventDefault(); doRedo(); }
    else if (e.key === ' ' && !e.target.closest('[data-arrow]') && tag !== 'button') { e.preventDefault(); play ? stopPlay() : startPlay(); }
    else if (e.key === 'ArrowLeft' && tag !== 'button') selectFrame(S.cur - 1);
    else if (e.key === 'ArrowRight' && tag !== 'button') selectFrame(S.cur + 1);
  });
}
/* ---------- station (segctl on the speaker) ---------- */
const LOC = {};
for (const d of DIGITS) {
  const pos = {1: 1, 2: 2, 4: 3, 5: 4}[d.n];
  for (const s of SEGS) LOC[`d${d.n}${s}`] = s + pos;
  LOC[`p${d.n}`] = 'p' + d.n; LOC[`q${d.n}`] = 'q' + d.n;
}
for (const id of MID_IDS) LOC[id] = id;
LOC.dot = 'deg';
const ST = {on: false, ok: false, armed: false, info: null, max: 255, live: true, sent: {}, busy: false, pending: false};
const RING = {n: 0, colors: [], busy: false, pending: false};
const LOGO = {n: 0, colors: [], busy: false, pending: false};
const scaleV = v => ST.max === 255 ? v : Math.round(v * ST.max / 255);
async function api(path, body) {
  const opt = body === undefined ? {cache: 'no-store'} : {method: 'POST', body, headers: {'Content-Type': 'text/plain'}, cache: 'no-store'};
  const r = await fetch(path, opt);
  if (!r.ok) throw new Error('HTTP ' + r.status);
  const t = await r.text();
  try { return JSON.parse(t); } catch (e) { return t; }
}
function frameKV(f) { const o = {}; for (const e of ELEMS) o[LOC[e.id]] = scaleV(valOf(f, e.id)); return o; }
function livePush(force) {
  if (!ST.on || !ST.ok || (!force && (!ST.live || !ST.armed))) return;
  if (ST.busy) { ST.pending = true; return; }
  const want = frameKV(cur()), diff = [];
  for (const k in want) if (ST.sent[k] !== want[k]) diff.push(k + '=' + want[k]);
  if (!diff.length) return;
  ST.busy = true;
  api('/api/set', diff.join(' '))
    .then(() => { Object.assign(ST.sent, want); if (ST.info) { ST.info.takeover = true; ST.info.player = false; } })
    .catch(() => { ST.ok = false; })
    .finally(() => { ST.busy = false; renderStation(); if (ST.pending) { ST.pending = false; livePush(); } });
}
function animText() {
  const lines = [`loop ${S.loopFrom}`]; let prev = null;
  S.frames.forEach((f, k) => {
    const kv = frameKV(f), out = [];
    for (const n in kv) if (k === 0 || k === S.loopFrom || prev[n] !== kv[n]) out.push(n + '=' + kv[n]);
    lines.push(Math.max(1, Math.min(65535, f.d | 0)) + (out.length ? ' ' + out.join(' ') : ''));
    prev = kv;
  });
  return lines.join('\n') + '\n';
}
function renderStation() {
  $('#stOff').hidden = ST.on; $('#stOn').hidden = !ST.on;
  const chip = $('#stChip'); chip.hidden = !ST.on; chip.classList.toggle('err', ST.on && !ST.ok);
  chip.textContent = ST.ok ? 'Станция' : 'нет связи';
  if (!ST.on) { $('#stBadge').textContent = 'не подключена'; return; }
  const i = ST.info || {};
  $('#stBadge').textContent = ST.ok ? (i.player ? 'играет' : 'на связи') : 'нет связи';
  $('#stStatus').innerHTML = ST.ok
    ? `Светодиодов найдено: <b>${i.leds}</b> из 45. Плеер: <b>${i.player ? 'играет анимацию' : 'стоит'}</b>. Дисплей: <b>${i.takeover ? 'у тебя' : 'у Алисы'}</b>.` + (i.takeover ? '' : ' Перейдёт к тебе с первой правки.')
    : 'Колонка не отвечает. Проверь, что она в сети и segctl запущен.';
  for (const id of ['stPlay', 'stShow', 'stStop', 'stRelease']) $('#' + id).disabled = !ST.ok;
  renderRing(); renderLogo();
}
const PALETTE = ['#ff3b30','#ff9500','#ffcc00','#34c759','#00c7be','#30b0ff','#007aff','#5e5ce6','#af52de','#ff2d95','#ffffff','#000000'];
const PICK = {ring: '#30b0ff', logo: '#ff9500'};
function buildPickers() {
  for (const el of document.querySelectorAll('.cpick')) {
    if (el.dataset.built) continue; el.dataset.built = '1';
    const who = el.dataset.for;
    let h = '';
    for (const c of PALETTE) h += `<button type="button" class="sw" data-c="${c}" title="${c}" style="background:${c}"></button>`;
    h += `<label class="custom" title="Свой цвет"><input type="color" value="${PICK[who]}"><span>+</span></label>`;
    el.innerHTML = h;
    const paint = el.querySelector('.custom').style;
    el.addEventListener('click', e => { const b = e.target.closest('.sw'); if (b) setPick(who, b.dataset.c); });
    el.querySelector('input').addEventListener('input', e => setPick(who, e.target.value));
    markPick(who);
  }
}
function setPick(who, c) { PICK[who] = c.toLowerCase(); markPick(who); }
function markPick(who) {
  const el = document.querySelector(`.cpick[data-for="${who}"]`); if (!el) return;
  for (const b of el.querySelectorAll('.sw')) b.classList.toggle('on', b.dataset.c.toLowerCase() === PICK[who]);
  el.querySelector('.custom').style.background = PICK[who];
}
// перегородки колонки: светодиоды по периметру квадрата со скруглёнными углами
function perimPoints(n, S, pad, r) {
  // длина периметра скруглённого квадрата
  const side = S - 2 * pad - 2 * r, arc = Math.PI * r / 2, per = 4 * side + 4 * arc;
  const pts = [];
  for (let i = 0; i < n; i++) {
    let d = (i + 0.5) / n * per, x, y;
    // стороны по часовой от верхнего-левого скругления, начиная сверху
    const seg = [side, arc, side, arc, side, arc, side, arc];
    let k = 0; while (d > seg[k]) { d -= seg[k]; k++; }
    const t = d;
    if (k === 0) { x = pad + r + t; y = pad; }
    else if (k === 1) { const a = -Math.PI/2 + t/r; x = S-pad-r + r*Math.cos(a); y = pad+r + r*Math.sin(a); }
    else if (k === 2) { x = S-pad; y = pad + r + t; }
    else if (k === 3) { const a = 0 + t/r; x = S-pad-r + r*Math.cos(a); y = S-pad-r + r*Math.sin(a); }
    else if (k === 4) { x = S-pad-r - t; y = S-pad; }
    else if (k === 5) { const a = Math.PI/2 + t/r; x = pad+r + r*Math.cos(a); y = S-pad-r + r*Math.sin(a); }
    else if (k === 6) { x = pad; y = S-pad-r - t; }
    else { const a = Math.PI + t/r; x = pad+r + r*Math.cos(a); y = pad+r + r*Math.sin(a); }
    pts.push([x, y]);
  }
  return pts;
}
function renderRing() {
  const have = ST.on && ST.ok && RING.n > 0;
  $('#ringOff').hidden = have; $('#ringOn').hidden = !have;
  $('#ringBadge').textContent = !ST.on ? '' : (RING.n > 0 ? RING.n + ' px' : 'нет');
  if (!have) return;
  buildPickers();
  $('#ringStatus').innerHTML = `Светодиодов по периметру: <b>${RING.n}</b>. Цвет пишется сразу на колонку.`;
  const svg = $('#ringSvg'), S = 320, pad = 26, r = 46;
  if (svg.dataset.n !== String(RING.n)) {
    svg.dataset.n = RING.n;
    const pts = perimPoints(RING.n, S, pad, r);
    let h = `<rect class="body" x="${pad-14}" y="${pad-14}" width="${S-2*pad+28}" height="${S-2*pad+28}" rx="40"/>`;
    pts.forEach(([x,y],i) => { h += `<circle class="px" data-i="${i}" cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="8"/><circle class="hit" data-i="${i}" cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="15"/>`; });
    svg.innerHTML = h;
    svg._px = svg.querySelectorAll('.px');
  }
  for (let i = 0; i < RING.n; i++) {
    const c = RING.colors[i] || '#000000', lit = c !== '#000000' && c !== '#000';
    const n = svg._px[i]; n.setAttribute('fill', lit ? c : '#1b1f27'); n.classList.toggle('on', lit);
  }
}
function hex6(c) { return (c || '#000000').replace('#', '').slice(0, 6).padStart(6, '0'); }
function ringPush(list) {
  if (!ST.on || !ST.ok || RING.n === 0) return;
  if (RING.busy) { RING.pending = true; return; }
  RING.busy = true;
  api('/api/ring/set', list.map(([i, c]) => i + '=' + hex6(c)).join(' '))
    .catch(() => { ST.ok = false; })
    .finally(() => { RING.busy = false; if (RING.pending) { RING.pending = false; ringFlush(); } });
}
let ringDirty = {};
function ringSet(i, color) { RING.colors[i] = color; ringDirty[i] = color; renderRing(); ringFlush(); }
function ringFlush() { const d = ringDirty; ringDirty = {}; const list = Object.keys(d).map(i => [+i, d[i]]); if (list.length) ringPush(list); }
function renderLogo() {
  const have = ST.on && ST.ok && LOGO.n > 0;
  $('#logoOff').hidden = have; $('#logoOn').hidden = !have;
  const badge = $('#logoBadge');
  badge.textContent = !ST.on ? '' : (LOGO.n > 0 ? LOGO.n + ' px' : 'нет');
  if (!have) return;
  $('#logoStatus').innerHTML = `Пикселей логотипа: <b>${LOGO.n}</b>.`;
  buildPickers();
  const box = $('#logoDots');
  if (box.children.length !== LOGO.n) {
    let h = '';
    for (let i = 0; i < LOGO.n; i++) h += `<button type="button" class="lpx" data-i="${i}" title="Пиксель ${i}"></button>`;
    box.innerHTML = h;
  }
  for (let i = 0; i < LOGO.n; i++) box.children[i].style.background = LOGO.colors[i] || '#1b1f27';
}
function logoPush(list) {
  if (!ST.on || !ST.ok || LOGO.n === 0) return;
  if (LOGO.busy) { LOGO.pending = true; return; }
  LOGO.busy = true;
  api('/api/logo/set', list.map(([i, c]) => i + '=' + hex6(c)).join(' '))
    .catch(() => { ST.ok = false; })
    .finally(() => { LOGO.busy = false; if (LOGO.pending) { LOGO.pending = false; logoFlush(); } });
}
let logoDirty = {};
function logoSet(i, color) { LOGO.colors[i] = color; logoDirty[i] = color; renderLogo(); logoFlush(); }
function logoFlush() { const d = logoDirty; logoDirty = {}; const list = Object.keys(d).map(i => [+i, d[i]]); if (list.length) logoPush(list); }
const SERVED = location.protocol === 'http:' || location.protocol === 'https:';
async function stationPoll(first) {
  if (!SERVED) { renderStation(); return; }
  try {
    const ctrl = new AbortController(), tm = setTimeout(() => ctrl.abort(), 2500);
    const r = await fetch('/api/info', {cache: 'no-store', signal: ctrl.signal}); clearTimeout(tm);
    const j = await r.json();
    if (j && j.app === 'segctl') {
      const was = ST.ok; ST.on = true; ST.ok = true; ST.info = j; ST.max = j.max || 255;
      if (typeof j.ring === 'number' && j.ring !== RING.n) { RING.n = j.ring; if (RING.colors.length !== RING.n) RING.colors = new Array(RING.n).fill('#000000'); }
      if (typeof j.logo === 'number' && j.logo !== LOGO.n) { LOGO.n = j.logo; if (LOGO.colors.length !== LOGO.n) LOGO.colors = new Array(LOGO.n).fill('#000000'); }
      if (first) { $('#dStation').open = true; toast('Колонка на связи: правки идут сразу на дисплей.'); }
      if (!was) { ST.sent = {}; if (!j.player) livePush(); }
    }
  } catch (e) { if (ST.on) ST.ok = false; }
  renderStation();
}
async function stationAction(path, body, okMsg, after) {
  try { await api(path, body); if (after) after(); toast(okMsg); }
  catch (e) { ST.ok = false; toast('Колонка не ответила.'); }
  stationPoll();
}
function initStation() {
  renderStation();
  const arm = () => { ST.armed = true; };
  document.addEventListener('pointerdown', arm, {capture: true, once: true});
  document.addEventListener('keydown', arm, {capture: true, once: true});
  if (SERVED) { stationPoll(true); setInterval(() => { if (ST.on && document.visibilityState === 'visible') stationPoll(); }, 5000); }
  else renderStation();
  $('#stLive').addEventListener('change', e => { ST.live = e.target.checked; if (ST.live) livePush(); });
  $('#stShow').onclick = () => { ST.sent = {}; livePush(true); toast('Кадр на дисплее.'); };
  $('#stPlay').onclick = () => { stopPlay(); stationAction('/api/play', animText(), `Играет на станции: ${S.frames.length} ${plural(S.frames.length, 'кадр', 'кадра', 'кадров')}` + (S.loopFrom < 0 ? ', один раз.' : ', по кругу.'), () => { ST.sent = {}; if (ST.info) ST.info.player = true; }); };
  $('#stStop').onclick = () => stationAction('/api/stop', '', 'Анимация остановлена.', () => { ST.sent = {}; });
  $('#stRelease').onclick = () => stationAction('/api/release', '', 'Дисплей отдан Алисе.', () => { ST.sent = {}; ST.armed = false; const arm = () => { ST.armed = true; }; document.addEventListener('pointerdown', arm, {capture: true, once: true}); document.addEventListener('keydown', arm, {capture: true, once: true}); });
  (() => {
    const svg = $('#ringSvg'); let rp = null;
    const idAt = t => { const n = t && t.closest ? t.closest('[data-i]') : null; return n ? +n.dataset.i : -1; };
    svg.addEventListener('pointerdown', e => { const i = idAt(e.target); if (i < 0) return; e.preventDefault(); rp = new Set(); paintRing(i); try { svg.setPointerCapture(e.pointerId); } catch (err) {} });
    svg.addEventListener('pointermove', e => { if (!rp) return; const i = idAt(document.elementFromPoint(e.clientX, e.clientY)); if (i >= 0) paintRing(i); });
    const end = () => { rp = null; };
    svg.addEventListener('pointerup', end); svg.addEventListener('pointercancel', end); svg.addEventListener('lostpointercapture', end);
    function paintRing(i) { if (rp.has(i)) return; rp.add(i); ringSet(i, PICK.ring); }
  })();
  $('#ringAll').onclick = () => { for (let i = 0; i < RING.n; i++) { RING.colors[i] = PICK.ring; ringDirty[i] = PICK.ring; } renderRing(); ringFlush(); };
  $('#ringOffBtn').onclick = () => { for (let i = 0; i < RING.n; i++) { RING.colors[i] = '#000000'; ringDirty[i] = '#000000'; } renderRing(); ringFlush(); };
  $('#logoDots').addEventListener('click', e => { const d = e.target.closest('.lpx'); if (d) logoSet(+d.dataset.i, PICK.logo); });
  $('#logoAll').onclick = () => { for (let i = 0; i < LOGO.n; i++) { LOGO.colors[i] = PICK.logo; logoDirty[i] = PICK.logo; } renderLogo(); logoFlush(); };
  $('#logoOffBtn').onclick = () => { for (let i = 0; i < LOGO.n; i++) { LOGO.colors[i] = '#000000'; logoDirty[i] = '#000000'; } renderLogo(); logoFlush(); };
}
initStation();

window.BSE = {animText, frameKV, LOC, buildRaw, zstdEncode, zstdDecompress, parseRaw, makeZip, get state() { return S; }, presetFrames, loadProject, importFile};
init();
})();
</script>
</body>
</html>
__SEG_HTML__
  chmod 0755 "$D/http.sh" "$D/keeper.sh" "$D/player.sh"
}

do_start() {
  port=${1:-8080}
  case $port in ''|*[!0-9]*) die "порт должен быть числом" ;; esac
  if alive "$D/inetd.pid"; then say "segctl уже работает: http://$(ip_addr):$(cat "$D/port")"; exit 0; fi
  if [ "${SEGCTL_SKIP_CHECK:-0}" = 1 ]; then
    say "проверка совместимости пропущена (SEGCTL_SKIP_CHECK=1)"; say ""
  else
    check_compat "$port"
    rc=$?
    say ""
    [ "$rc" = 0 ] || die "запуск отменён: сначала устрани ошибки (проверка выше). Если уверен, запусти с SEGCTL_SKIP_CHECK=1"
  fi
  rm -rf "$D"; unpack
  echo "$port" > "$D/port"
  printf '%s stream tcp nowait root %s/http.sh http.sh\n' "$port" "$D" > "$D/inetd.conf"
  setsid inetd -f "$D/inetd.conf" </dev/null >/dev/null 2>&1 &
  echo $! > "$D/inetd.pid"
  sleep 1
  alive "$D/inetd.pid" || { rm -rf "$D"; die "inetd не запустился (порт $port занят?)"; }
  say "segctl работает: открой http://$(ip_addr):$port"
  say "Дисплей остаётся у Алисы, пока ты ничего не изменишь в редакторе."
  say "Остановить и всё убрать: sh $0 stop"
}

case "${1:-start}" in
  start) do_start "${2:-8080}" ;;
  check) check_compat "${2:-8080}" ;;
  stop) do_stop ;;
  status) if alive "$D/inetd.pid"; then say "работает: http://$(ip_addr):$(cat "$D/port")$( [ -f "$D/snap" ] && echo ', дисплей у тебя')"; else say "не запущен"; fi ;;
  -h|--help|help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "не понял: $1 (start|stop|status|check)" ;;
esac
