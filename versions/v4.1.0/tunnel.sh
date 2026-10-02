#!/bin/bash
# Tunnel: a GRE tunnel and an encrypted tunnel (VLESS + WebSocket + TLS) between an
# Iran server and foreign servers, installed together; ports switch between them.
# The whole installer is kept in GRE_SELF, so it can save an exact copy of itself
# as /usr/local/sbin/tunnel: the menu then works without GitHub.
IFS= read -r -d '' GRE_SELF <<'GRE_SELF_END'
set -u
GRE_VERSION=4.1.0
[ "$(id -u)" = 0 ] || { echo "Run as root"; exit 1; }
# ping is optional (checks fall back to TCP), so a server without internet can still install
if ! command -v ping >/dev/null && command -v apt-get >/dev/null; then
  # only the download has a time limit: killing apt while dpkg runs would break dpkg
  echo "[*] installing iputils-ping"
  timeout 30 apt-get install -y -qq --download-only iputils-ping >/dev/null 2>&1 &&
    apt-get install -y -qq --no-download iputils-ping >/dev/null 2>&1
fi
for c in ip iptables systemctl; do command -v $c >/dev/null || { echo "missing: $c"; exit 1; }; done

valid_ip() { [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
# (what is left of a pasted code, its END line or a last short line, is not an answer;
# the code itself here means it was pasted after an empty line: said, and it fails)
ask() { local p=$1 d=${2:-} v; read -r -p "$p${d:+ [$d]}: " v
  while [[ ${v//[[:space:]]/} == -----END* || ${v//[[:space:]]/} =~ ^[A-Za-z0-9+/]+=+$ ]]; do
    v=""; read -r -p "$p${d:+ [$d]}: " v || break; done
  case ${v//[[:space:]]/} in -----BEGIN*|RX1-*|XT1-*)
    echo "[!] that is the tunnel code, pasted after an empty line: run option 1 again and paste it from its BEGIN line" >&2
    # the rest of the code is read here, not left for the shell (and its history)
    while IFS= read -r -t 1 v; do [[ ${v//[[:space:]]/} == *-----END* ]] && break; done; v=invalid ;;
  esac
  echo "${v:-$d}"; }
ipt_rm() { local t=$1; shift; while iptables -w -t "$t" -C "$@" 2>/dev/null; do iptables -w -t "$t" -D "$@"; done; }

# items are N or N:M, comma separated
valid_ports() { local IFS=, p lo hi
  [ -n "$1" ] || return 1
  for p in $1; do
    [[ $p =~ ^[0-9]{1,5}(:[0-9]{1,5})?$ ]] || return 1
    lo=$((10#${p%%:*})); hi=$((10#${p##*:}))
    [ "$lo" -ge 1 ] && [ "$hi" -le 65535 ] && [ "$lo" -le "$hi" ] || return 1
  done; }
# prints the first item of $1 that overlaps any item of $2
port_overlap() { local IFS=, a b a1 a2 b1 b2
  # all = every port
  if [ "$1" = all ] || [ "$2" = all ]; then [ -n "$1" ] && [ -n "$2" ] || return 1; echo "${1%%,*}"; return 0; fi
  for a in $1; do for b in $2; do
    a1=$((10#${a%%:*})); a2=$((10#${a##*:})); b1=$((10#${b%%:*})); b2=$((10#${b##*:}))
    if [ "$a1" -le "$b2" ] && [ "$b1" -le "$a2" ]; then echo "$a"; return 0; fi
  done; done; return 1; }

# every port sshd may be listening on, so SSH is never forwarded away
ssh_ports() {
  { sshd -T 2>/dev/null | awk '$1=="port"{print $2} $1=="listenaddress"{n=split($2,a,":"); print a[n]}'
    [ -n "${SSH_CONNECTION:-}" ] && echo "${SSH_CONNECTION##* }"
    systemctl show -p Listen ssh.socket 2>/dev/null | grep -oE ':[0-9]+ ' | tr -d ': '
    ss -Htlnp 2>/dev/null | awk '/"sshd"/{n=split($4,a,":"); print a[n]}'
  } | grep -E '^[0-9]+$' | sort -un | head -15 | paste -sd, -
}

remove_old_vatan() {
  # live rules and interface created by the original vatanhost/gre script
  ipt_rm nat PREROUTING -p tcp --dport 22 -j DNAT --to-destination 132.168.30.2
  ipt_rm nat PREROUTING -j DNAT --to-destination 132.168.30.1
  ipt_rm nat POSTROUTING -j MASQUERADE
  ipt_rm filter INPUT -p icmp -j DROP
  ip link del vatan-m2 2>/dev/null && echo "[*] removed old vatan-m2 tunnel"
  # copies saved to run at boot would bring the old tunnel back
  local f
  for f in /etc/rc.local /etc/crontab /etc/cron.d/* /var/spool/cron/crontabs/root /etc/iptables/rules.v4; do
    [ -f "$f" ] && grep -qE 'vatan-m2|132\.168\.30\.' "$f" || continue
    sed -i.bak -E '/vatan-m2|132\.168\.30\./d; /^-A POSTROUTING -j MASQUERADE$/d' "$f"
    echo "[*] removed old vatan lines from $f (backup: $f.bak)"
  done
  true
}

# exact copy of this installer (same text as downloaded), so the menu works
# on the server without GitHub: run tunnel (gre-install, its old name, also works)
save_self() {
  local f=/usr/local/sbin/tunnel
  [ -n "${GRE_SELF:-}" ] || return 0
  {
    printf '%s\n' '#!/bin/bash' \
      '# Tunnel: a GRE tunnel and an encrypted tunnel (VLESS + WebSocket + TLS) between an' \
      '# Iran server and foreign servers, installed together; ports switch between them.' \
      '# The whole installer is kept in GRE_SELF, so it can save an exact copy of itself' \
      '# as /usr/local/sbin/tunnel: the menu then works without GitHub.' \
      "IFS= read -r -d '' GRE_SELF <<'GRE_SELF_END'"
    printf '%s' "$GRE_SELF"
    # shellcheck disable=SC2016
    printf '%s\n' 'GRE_SELF_END' 'eval "$GRE_SELF"'
  } > "$f.tmp" && chmod 755 "$f.tmp" && mv -f "$f.tmp" "$f" && ln -sfn tunnel /usr/local/sbin/gre-install
}

install_files() {
  mkdir -p /etc/gre-tunnel
  save_self
  cat > /usr/local/sbin/gre-tunnel <<'RUNTIME'
#!/bin/bash
# GRE tunnel runtime. Usage: gre-tunnel up|down|check|diag|watchdog <N>
# Settings for tunnel N live in /etc/gre-tunnel/<N>.conf
set -u
VERSION=4.1.0
CMD=${1:-}; N=${2:-}
if [ "$CMD" = version ]; then echo "gre-tunnel $VERSION"; exit 0; fi
CONF=/etc/gre-tunnel/$N.conf
if [ -z "$N" ] || [ ! -f "$CONF" ]; then echo "usage: gre-tunnel up|down|check|diag|watchdog <N>  (missing $CONF; menu: tunnel)"; exit 1; fi
MTU=1420
# shellcheck source=/dev/null
. "$CONF"   # ROLE LOCAL_IP REMOTE_IP PORTS SSH_PORTS [MTU]
SSH_PORTS=${SSH_PORTS:-${SSH_PORT:-22}}

IF=vgre$N
IRAN_TIP=10.200.$N.2
FOREIGN_TIP=10.200.$N.1
if [ "$ROLE" = iran ]; then MY_TIP=$IRAN_TIP; PEER_TIP=$FOREIGN_TIP
else MY_TIP=$FOREIGN_TIP; PEER_TIP=$IRAN_TIP; fi

FAIL=0; MISSING=0
ipt_add() { local t=$1 op=$2 pos; shift 2
  iptables -w -t "$t" -C "$@" 2>/dev/null && return 0
  # -Ibelow: first, but below the encrypted tunnels' jumps (xray-tunnel), so their
  # ports never go to GRE for a moment while this tunnel starts
  if [ "$op" = -Ibelow ]; then
    pos=$(iptables -w -t "$t" -S "$1" 2>/dev/null | awk 'NR == 1 { next } / -j XTUN[1-9]$/ { n++; next } { exit } END { print n + 1 }')
    set -- "$1" "$pos" "${@:2}"; op=-I
  fi
  iptables -w -t "$t" "$op" "$@" || { echo "iptables failed: -t $t $op $*" >&2; FAIL=1; }; }
ipt_del() { local t=$1; shift 2
  while iptables -w -t "$t" -C "$@" 2>/dev/null; do iptables -w -t "$t" -D "$@"; done; }
ipt_chk() { local t=$1; shift 2
  iptables -w -t "$t" -C "$@" 2>/dev/null || MISSING=1; }

# multiport takes at most 15 ports (a range counts as 2), so split the list
chunks() { local IFS=, p out="" i=0
  for p in $1; do
    out+="${out:+,}$p"; i=$((i + 1))
    if [ "$i" -eq 7 ]; then echo "$out"; out=""; i=0; fi
  done
  if [ -n "$out" ]; then echo "$out"; fi; }

# Every rule this tunnel uses, applied with ipt_add, ipt_del or ipt_chk
rules() { local f=$1 c
  $f filter -I INPUT -p gre -s "$REMOTE_IP" -j ACCEPT
  if [ "$ROLE" = iran ]; then
    $f filter -I INPUT -i "$IF" -p icmp -j ACCEPT
    $f filter -I FORWARD -i "$IF" -j ACCEPT
    $f filter -I FORWARD -o "$IF" -j ACCEPT
    if iptables -w -n -L DOCKER-USER >/dev/null 2>&1; then
      $f filter -I DOCKER-USER -i "$IF" -j ACCEPT
      $f filter -I DOCKER-USER -o "$IF" -j ACCEPT
    fi
    $f mangle -A FORWARD -o "$IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $((MTU - 40))
    $f mangle -A FORWARD -i "$IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $((MTU - 40))
    if [ "$PORTS" = all ]; then
      # everything except SSH; GRE, ICMP and traffic from the tunnels are never matched
      $f nat -A PREROUTING ! -i vgre+ -m addrtype --dst-type LOCAL -p tcp -m multiport ! --dports "$SSH_PORTS" -j DNAT --to-destination "$PEER_TIP"
      $f nat -A PREROUTING ! -i vgre+ -m addrtype --dst-type LOCAL -p udp -j DNAT --to-destination "$PEER_TIP"
    else
      # port rules go first (-I) so they always win over an 'all' rule
      while read -r c; do
        $f nat -Ibelow PREROUTING ! -i vgre+ -m addrtype --dst-type LOCAL -p tcp -m multiport --dports "$c" -j DNAT --to-destination "$PEER_TIP"
        $f nat -Ibelow PREROUTING ! -i vgre+ -m addrtype --dst-type LOCAL -p udp -m multiport --dports "$c" -j DNAT --to-destination "$PEER_TIP"
      done < <(chunks "$PORTS")
    fi
    $f nat -A POSTROUTING -o "$IF" -j MASQUERADE
  else
    # foreign: from the tunnel accept only the forwarded ports, not every service
    $f filter -I INPUT -i "$IF" -p icmp -j ACCEPT
    $f filter -I INPUT -i "$IF" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    if [ "$PORTS" = all ]; then
      $f filter -I INPUT -i "$IF" -j ACCEPT
    else
      while read -r c; do
        $f filter -I INPUT -i "$IF" -p tcp -m multiport --dports "$c" -j ACCEPT
        $f filter -I INPUT -i "$IF" -p udp -m multiport --dports "$c" -j ACCEPT
      done < <(chunks "$PORTS")
    fi
    # hide from ping scans on the public IP (only echo-request; PMTU ICMP
    # still works, and the server can still ping its own addresses)
    $f filter -I INPUT ! -i vgre+ -m addrtype ! --src-type LOCAL -p icmp --icmp-type echo-request -j DROP
  fi
}

tune_conntrack() {
  local d=/proc/sys/net/netfilter
  if [ -w $d/nf_conntrack_max ] && [ "$(cat $d/nf_conntrack_max)" -lt 262144 ]; then
    echo 262144 > $d/nf_conntrack_max; fi
  if [ -w $d/nf_conntrack_tcp_timeout_established ] && [ "$(cat $d/nf_conntrack_tcp_timeout_established)" -gt 7440 ]; then
    echo 7440 > $d/nf_conntrack_tcp_timeout_established; fi
}

# the encrypted tunnels' jumps (xray-tunnel) must stay above the port rules
# just inserted at the top, or their ports would go back to GRE
xt_above() { local f
  [ -x /usr/local/sbin/xray-tunnel ] || return 0
  for f in /etc/xray-tunnel/*.conf; do
    [ -e "$f" ] && /usr/local/sbin/xray-tunnel up "$(basename "$f" .conf)" >/dev/null 2>&1
  done; true; }

# rules written by older versions of this script
legacy_cleanup() {
  ipt_del filter -I INPUT ! -i vgre+ -p icmp --icmp-type echo-request -j DROP   # v2.0.x
}

up() {
  modprobe ip_gre 2>/dev/null
  ip link del vatan-m2 2>/dev/null   # old vatanhost tunnel, same endpoints
  if ! ip link show "$IF" >/dev/null 2>&1; then
    local other
    other=$(ip tunnel show 2>/dev/null | awk -v me="$IF:" -v r="remote $REMOTE_IP " -v l="local $LOCAL_IP " \
      'index($0" ", r) && index($0" ", l) && $1 != me { sub(":", "", $1); print $1 }')
    if [ -n "$other" ]; then
      if [[ $other == vgre[1-9] ]] && [ -f "/etc/gre-tunnel/${other#vgre}.conf" ]; then
        echo "tunnel ${other#vgre} of this script already connects $LOCAL_IP and $REMOTE_IP: use tunnel number ${other#vgre} (menu: tunnel)" >&2
      else echo "tunnel '$other' already uses $LOCAL_IP -> $REMOTE_IP; remove it first (ip link del $other)" >&2; fi
      logger -t gre-tunnel "$IF: tunnel $other already uses $LOCAL_IP -> $REMOTE_IP"
      exit 1
    fi
    ip tunnel add "$IF" mode gre local "$LOCAL_IP" remote "$REMOTE_IP" ttl 255 || exit 1
  fi
  ip link set "$IF" mtu "$MTU" up
  ip addr replace "$MY_TIP/30" dev "$IF"
  if [ "$ROLE" = iran ]; then sysctl -qw net.ipv4.ip_forward=1; fi
  FAIL=0; rules ipt_add
  legacy_cleanup
  if [ "$ROLE" = iran ]; then tune_conntrack; xt_above; fi
  [ "$FAIL" = 0 ] || exit 1
  echo "$IF up: $MY_TIP <-> $PEER_TIP (mtu $MTU)"
}

down() {
  rules ipt_del
  legacy_cleanup
  ip link del "$IF" 2>/dev/null
  rm -f "/run/gre-watchdog.$N" "/run/gre-watchdog.$N.rx"
  true
}

# Prints what is wrong with tunnel N, if anything
diag() {
  local wan dev src other rx0 tx0 rx1 tx1 cap="" nout=0 nin=0 pr tcp=""
  echo "gre-tunnel $VERSION | tunnel $N | role $ROLE | $LOCAL_IP -> $REMOTE_IP | ports $PORTS | mtu $MTU"
  wan=$(ip -4 -o addr show | awk -v ip="$LOCAL_IP" 'index($4, ip "/") == 1 { print $2; exit }')
  if [ -n "$wan" ]; then echo "[ok] $LOCAL_IP is on $wan"
  else echo "[!!] $LOCAL_IP is not on any interface of this server (NAT?). GRE must use the interface address:"
       ip -4 -o addr show scope global | awk '{ print "     " $2 " " $4 }'; fi
  read -r dev src < <(ip -4 route get "$REMOTE_IP" 2>/dev/null | awk '{ for (i = 1; i < NF; i++) { if ($i == "dev") d = $(i + 1); if ($i == "src") s = $(i + 1) } } END { print d, s }')
  if [ -z "$dev" ]; then
    echo "[!!] no route to $REMOTE_IP"
  elif [ -n "$wan" ] && [ "$dev" != "$wan" ]; then
    echo "[!!] packets to $REMOTE_IP leave via $dev, not $wan (WARP or another VPN is routing them). GRE cannot work like this."
  else echo "[ok] route to $REMOTE_IP via $dev (src $src)"; fi
  if ip link show "$IF" >/dev/null 2>&1; then echo "[ok] $IF exists (mtu $(cat "/sys/class/net/$IF/mtu"))"
  else echo "[!!] $IF does not exist: systemctl restart gre-tunnel@$N; journalctl -u gre-tunnel@$N -n 20"; fi
  other=$(ip tunnel show 2>/dev/null | awk -v me="$IF:" -v r="remote $REMOTE_IP " 'index($0 " ", r) && $1 != me { sub(":", "", $1); print $1 }')
  [ -n "$other" ] && echo "[!!] another tunnel to $REMOTE_IP exists: $other (old vatan-m2? remove: ip link del $other)"
  MISSING=0; rules ipt_chk
  if [ "$MISSING" = 0 ]; then echo "[ok] firewall rules in place"; else echo "[!!] some firewall rules are missing (the watchdog re-adds them within 30s)"; fi
  if iptables -w -t nat -S PREROUTING 2>/dev/null | grep -- '-j DNAT' | grep -qvE -- '-p (tcp|udp)'; then
    echo "[!!] a catch-all DNAT rule is in nat PREROUTING (old vatan script?), it also captures GRE:"
    iptables -w -t nat -S PREROUTING | grep -- '-j DNAT' | grep -vE -- '-p (tcp|udp)' | sed 's/^/     /'; fi
  rx0=$(cat "/sys/class/net/$IF/statistics/rx_packets" 2>/dev/null || echo 0)
  tx0=$(cat "/sys/class/net/$IF/statistics/tx_packets" 2>/dev/null || echo 0)
  if command -v tcpdump >/dev/null && [ -n "$wan" ]; then
    cap=$(mktemp)
    timeout 9 tcpdump -lni "$wan" -c 60 "ip proto 47 and host $REMOTE_IP" > "$cap" 2>/dev/null &
    sleep 1
  fi
  if ping -c 4 -W 2 -q "$PEER_TIP" >/dev/null 2>&1; then pr=ok; else pr=FAILED; fi
  rx1=$(cat "/sys/class/net/$IF/statistics/rx_packets" 2>/dev/null || echo 0)
  tx1=$(cat "/sys/class/net/$IF/statistics/tx_packets" 2>/dev/null || echo 0)
  echo "ping $PEER_TIP: $pr ($IF sent $((tx1 - tx0)), received $((rx1 - rx0)) packets)"
  if [ "$pr" != ok ]; then
    if tcp_check; then tcp=ok; echo "tcp to $PEER_TIP: ok (the other server only ignores ping)"
    else tcp=FAILED; echo "tcp to $PEER_TIP: FAILED"; fi
  fi
  if [ -n "$cap" ]; then
    wait
    nout=$(grep -cF "IP $LOCAL_IP > $REMOTE_IP:" "$cap"); nin=$(grep -cF "IP $REMOTE_IP > $LOCAL_IP:" "$cap"); rm -f "$cap"
    echo "GRE packets on $wan: $nout sent to $REMOTE_IP, $nin received from $REMOTE_IP"
  fi
  echo
  if [ "$pr" = ok ] || [ "$tcp" = ok ]; then echo "RESULT: tunnel works."
  elif [ -z "$cap" ]; then
    echo "RESULT: tunnel does not answer. For a clearer answer install tcpdump (apt install -y tcpdump) and run diag again, on both servers."
  elif [ "$nout" -gt 0 ] && [ "$nin" -eq 0 ]; then
    echo "RESULT: GRE leaves this server but nothing comes back from $REMOTE_IP."
    echo "        Either the other server is not installed / uses another tunnel number, its firewall drops GRE,"
    echo "        or GRE is blocked between the two servers. Run 'gre-tunnel diag $N' on $REMOTE_IP too."
  elif [ "$nin" -gt 0 ]; then
    echo "RESULT: GRE from $REMOTE_IP arrives, but the ping still fails. Check that both sides use the same"
    echo "        tunnel number and each other's IPs, and look at the [!!] lines above (on both servers)."
  else
    echo "RESULT: no GRE packets were sent. Look at the [!!] lines above."
  fi
}

# The other server may ignore ping, so a TCP answer through the tunnel counts
# too: even "connection refused" proves packets went there and came back.
tcp_probe() { local out rc
  out=$(timeout 4 bash -c "exec 3<>/dev/tcp/$PEER_TIP/$1" 2>&1); rc=$?
  [ "$rc" = 0 ] || [[ $out == *refused* ]]; }
# On Iran, the first forwarded port is the best probe: the foreign server serves
# it and accepts it from the tunnel. Ports 9 and 22 are fallbacks.
tcp_check() { local p
  if [ "$ROLE" = iran ] && [ "$PORTS" != all ]; then tcp_probe "${PORTS%%[,:]*}" && return 0; fi
  for p in 9 22; do tcp_probe "$p" && return 0; done
  return 1; }
check() {
  ping -c 3 -W 2 -q "$PEER_TIP" >/dev/null 2>&1 && return 0
  tcp_check
}

# Runs every 30s: repairs local state (link, rules, forwarding) if anything
# removed it, and logs when the peer stops answering. It never restarts a
# working tunnel, because that would drop every user's connection.
watchdog() {
  local s=/run/gre-watchdog.$N rx prev n
  systemctl -q is-active "gre-tunnel@$N" || exit 0
  MISSING=0; rules ipt_chk
  ip link show "$IF" >/dev/null 2>&1 || MISSING=1
  if [ "$ROLE" = iran ] && [ "$(cat /proc/sys/net/ipv4/ip_forward)" != 1 ]; then MISSING=1; fi
  if [ "$MISSING" = 1 ]; then
    logger -t gre-watchdog "tunnel $N: local config was removed, re-applying"
    up >/dev/null 2>&1
  fi
  rx=$(cat "/sys/class/net/$IF/statistics/rx_packets" 2>/dev/null || echo 0)
  prev=$(cat "$s.rx" 2>/dev/null || echo -1); echo "$rx" > "$s.rx"
  if { [ "$prev" != -1 ] && [ "$rx" != "$prev" ]; } || check; then
    if [ "$(cat "$s" 2>/dev/null || echo 0)" -ge 3 ]; then
      logger -t gre-watchdog "tunnel $N: $PEER_TIP is reachable again"; fi
    rm -f "$s"; exit 0
  fi
  n=$(( $(cat "$s" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$s"
  if [ "$n" -eq 3 ]; then
    logger -t gre-watchdog "tunnel $N: no traffic from $PEER_TIP for 90s (peer down, or GRE blocked on the path)"
  fi
}

case "$CMD" in
  up) up ;; down) down ;; watchdog) watchdog ;; diag) diag ;;
  check) if check; then echo "tunnel $N OK ($PEER_TIP reachable)"; else echo "tunnel $N DOWN ($PEER_TIP not reachable)"; exit 1; fi ;;
  *) echo "usage: gre-tunnel up|down|check|diag|watchdog <N> | version"; exit 1 ;;
esac
RUNTIME
  chmod +x /usr/local/sbin/gre-tunnel

  cat > /etc/systemd/system/gre-tunnel@.service <<'UNIT'
[Unit]
Description=GRE tunnel %i
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/gre-tunnel up %i
ExecStop=/usr/local/sbin/gre-tunnel down %i
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
  # systemd older than 244 refuses Restart= on oneshot units; the watchdog covers it
  local v; v=$(systemctl --version | awk 'NR==1{print $2}')
  if [ "${v%%.*}" -lt 244 ] 2>/dev/null; then sed -i '/^Restart/d' /etc/systemd/system/gre-tunnel@.service; fi

  cat > /etc/systemd/system/gre-watchdog@.service <<'UNIT'
[Unit]
Description=GRE tunnel %i health check

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/gre-tunnel watchdog %i
UNIT

  cat > /etc/systemd/system/gre-watchdog@.timer <<'UNIT'
[Unit]
Description=GRE tunnel %i health check every 30s

[Timer]
OnBootSec=1min
OnUnitActiveSec=30s
AccuracySec=5s

[Install]
WantedBy=timers.target
UNIT

  cat > /etc/sysctl.d/99-gre-tunnel.conf <<'SYS'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
SYS
  sysctl -q -p /etc/sysctl.d/99-gre-tunnel.conf 2>/dev/null
  echo ip_gre > /etc/modules-load.d/gre-tunnel.conf
  modprobe ip_gre
  systemctl daemon-reload
}

# kernel settings written to /etc/sysctl.d/99-gre-tunnel.conf; their values
# from before the first install are kept so option 6 can put them back
SYSCTL_KEYS="net.core.default_qdisc net.ipv4.tcp_congestion_control"
SYSCTL_OURS=" net.core.default_qdisc=fq net.ipv4.tcp_congestion_control=bbr "
SYSCTL_ORIG=/etc/gre-tunnel/sysctl.orig

# value of a key in the server's own sysctl files (not ours), if set there
sysctl_conf_value() {
  local f
  for f in /usr/lib/sysctl.d/*.conf /lib/sysctl.d/*.conf /run/sysctl.d/*.conf /etc/sysctl.d/*.conf /etc/sysctl.conf; do
    [ -f "$f" ] && [ "$f" != /etc/sysctl.d/99-gre-tunnel.conf ] || continue
    awk -F= -v k="$1" '{ gsub(/[ \t]/, "", $1); sub(/^-/, "", $1); gsub(/^[ \t]+|[ \t\r]+$/, "", $2) } $1 == k && $2 != "" { v = $2 } END { if (v != "") print v }' "$f"
  done | tail -1
}

save_orig_sysctl() {
  local k v
  [ -f "$SYSCTL_ORIG" ] && return
  # our bbr/fq may already be live (older version, a removed tunnel, no reboot since option 6)
  [ -e /etc/sysctl.d/99-gre-tunnel.conf ] && return
  ls /etc/gre-tunnel/*.conf >/dev/null 2>&1 && return
  mkdir -p /etc/gre-tunnel
  for k in $SYSCTL_KEYS; do
    v=$(sysctl -n "$k" 2>/dev/null) || continue
    [[ $SYSCTL_OURS == *" $k=$v "* ]] && [ "$(sysctl_conf_value "$k")" != "$v" ] && continue
    echo "$k=$v"
  done > "$SYSCTL_ORIG"
}

# puts back qdisc/congestion control: the server's own sysctl files win (that is
# what the next boot applies), else the value saved before the first install
restore_sysctl() {
  local k v kept=""
  for k in $SYSCTL_KEYS; do
    v=$(sysctl_conf_value "$k")
    [ -n "$v" ] || { [ -f "$SYSCTL_ORIG" ] && v=$(awk -v k="$k=" 'index($0, k) == 1 { print substr($0, length(k) + 1) }' "$SYSCTL_ORIG"); }
    if [ -z "$v" ]; then kept+=" $k"
    elif [ "$(sysctl -n "$k" 2>/dev/null)" = "$v" ]; then echo "[*] $k = $v"
    elif sysctl -qw "$k=$v" 2>/dev/null; then echo "[*] $k = $v"
    else kept+=" $k"; fi
  done
  [ -z "$kept" ] || echo "[i] unchanged until the next reboot (value before install unknown):$kept"
}

# every tunnel number known to the files or to systemd
gre_instances() {
  local f
  { for f in /etc/gre-tunnel/*.conf; do [ -e "$f" ] && basename "$f" .conf; done
    systemctl list-units --all --plain --no-legend 'gre-tunnel@*' 'gre-watchdog@*' 2>/dev/null | awk '{ print $1 }'
    ls /etc/systemd/system/*.wants/ 2>/dev/null
  } | sed -E 's/^gre-(tunnel|watchdog)@([^.]+)\..*/\2/' | grep -E '^[0-9]+$' | sort -un
}

# GRE rules, and the encrypted tunnel's (its chains XTUN<N>, its rules tagged xray-tunnel-<N>)
LEFTOVER_RE='^-A .*(vgre|--to-destination 10\.200\.[1-9]\.[12]( |$)|-j XTUN[1-9]$|--comment xray-tunnel-[1-9] )|^-A XTUN[1-9] '
SAVED_RULES="/etc/iptables/rules.v4 /etc/sysconfig/iptables /etc/iptables.rules /etc/iptables.up.rules"
vgre_links() { ip -o link show 2>/dev/null | awk -F': ' '{ sub(/@.*/, "", $2); print $2 }' | grep -E '^vgre[0-9]+$'; }

# what sweep_leftovers would remove
list_leftovers() {
  local t
  for t in filter nat mangle; do
    iptables -w -t "$t" -S 2>/dev/null | grep -E -- "$LEFTOVER_RE|^-N XTUN[1-9]$" | sed "s/^/  -t $t /"
  done
  vgre_links | sed 's/^/  link /'
}

# rules and vgre interfaces left without a .conf (e.g. a conf deleted by hand)
sweep_leftovers() {
  local t r remote
  for t in filter nat mangle; do
    iptables -w -t "$t" -S 2>/dev/null | grep -E -- "$LEFTOVER_RE" |
      while read -r -a r; do iptables -w -t "$t" -D "${r[@]:1}" 2>/dev/null; done
    iptables -w -t "$t" -S 2>/dev/null | sed -n -E 's/^-N (XTUN[1-9])$/\1/p' |
      while read -r r; do iptables -w -t "$t" -F "$r"; iptables -w -t "$t" -X "$r"; done
  done
  for r in $(vgre_links); do
    remote=$(ip -o tunnel show "$r" 2>/dev/null | grep -oE 'remote [0-9.]+' | cut -d' ' -f2)
    [ -n "$remote" ] && ipt_rm filter INPUT -p gre -s "$remote" -j ACCEPT
    ip link del "$r" 2>/dev/null
  done
}

# a copy saved while a tunnel was up (netfilter-persistent save, iptables-save >
# rules.v4) would bring our rules back at the next boot; $1 = remote IPs
unsave_rules() {
  local f r re="$LEFTOVER_RE|^:XTUN[1-9] "
  for r in $1; do re+="|^-A INPUT -s ${r//./\\.}/32 -p gre -j ACCEPT\$"; done
  for f in $SAVED_RULES; do
    [ -f "$f" ] && grep -qE -- "$re" "$f" || continue
    sed -i.gre-bak -E "\#$re#d" "$f"
    echo "[*] removed saved tunnel rules from $f (backup: $f.gre-bak)"
  done
}

# removes every tunnel and everything this script installed
do_uninstall() {
  local n iran=0 remotes left
  if [ -z "$(gre_instances)" ] && [ ! -e /etc/gre-tunnel ] && [ ! -e /usr/local/sbin/gre-tunnel ] && [ ! -e /usr/local/sbin/gre-install ] && [ ! -e /etc/sysctl.d/99-gre-tunnel.conf ] &&
    [ -z "$(xt_instances)" ] && [ ! -e "$XT_DIR" ] && [ ! -e /usr/local/sbin/xray-tunnel ] && [ ! -e /usr/local/sbin/tunnel ]; then
    left=$(list_leftovers)
    if [ -z "$left" ]; then echo "Nothing of this script is installed on this server."; return; fi
    echo "Nothing of this script is installed, but these tunnel rules/interfaces are left over:"; echo "$left"
  fi
  echo "This removes ALL tunnels made by this script and everything it installed:"
  echo "GRE and encrypted tunnels, services, firewall rules, tunnel interfaces and settings."
  echo "Users on the tunnels are disconnected."
  echo "x-ui, SSH and other services are not touched."
  grep -qs '^ROLE=foreign' "$XT_DIR"/*.conf &&
    echo "On a foreign server: the Iran server's ports on these tunnels stop working."
  [ "$(ask "Type yes to continue")" = yes ] || { echo "cancelled"; return; }
  grep -qs '^ROLE=iran' /etc/gre-tunnel/*.conf && iran=1
  remotes=$( { sed -n 's/^REMOTE_IP=//p' /etc/gre-tunnel/*.conf 2>/dev/null
    for n in $(vgre_links); do ip -o tunnel show "$n" 2>/dev/null | grep -oE 'remote [0-9.]+' | cut -d' ' -f2; done
  } | grep -E '^[0-9.]+$' | sort -u)
  remotes+=$'\n'$(sed -n 's/^REMOTE_IP=//p' "$XT_DIR"/*.conf 2>/dev/null)
  for n in $(xt_instances); do xt_drop "$n"; echo "[*] encrypted tunnel $n removed"; done
  # also when only the program files are left
  xt_purge
  for n in $(gre_instances); do
    # stop even if disable fails (unit file already gone); timer first so it cannot re-add rules
    systemctl stop "gre-watchdog@$n.timer" "gre-watchdog@$n.service" 2>/dev/null
    systemctl stop "gre-tunnel@$n.service" 2>/dev/null
    systemctl disable "gre-watchdog@$n.timer" "gre-tunnel@$n.service" 2>/dev/null
    # also when the service was not running but its rules are still there
    if [ -f "/etc/gre-tunnel/$n.conf" ] && [ -x /usr/local/sbin/gre-tunnel ]; then
      /usr/local/sbin/gre-tunnel down "$n" >/dev/null 2>&1; fi
    echo "[*] tunnel $n removed"
  done
  sweep_leftovers
  unsave_rules "$remotes"
  if [ -e /etc/sysctl.d/99-gre-tunnel.conf ] || [ -f "$SYSCTL_ORIG" ]; then
    rm -f /etc/sysctl.d/99-gre-tunnel.conf
    restore_sysctl
  fi
  # ip_gre stays loaded: unloading it would also delete other tools' GRE tunnels;
  # without our modules-load file it is not loaded at the next boot
  rm -f /usr/local/sbin/gre-tunnel /usr/local/sbin/gre-install /usr/local/sbin/tunnel /etc/modules-load.d/gre-tunnel.conf /run/gre-watchdog.* \
    /etc/systemd/system/gre-tunnel@.service /etc/systemd/system/gre-watchdog@.service /etc/systemd/system/gre-watchdog@.timer \
    /etc/systemd/system/*.wants/gre-tunnel@*.service /etc/systemd/system/*.wants/gre-watchdog@*.timer
  rm -rf /etc/gre-tunnel
  systemctl daemon-reload
  systemctl reset-failed 'gre-tunnel@*' 'gre-watchdog@*' 2>/dev/null
  if [ "$iran" = 1 ]; then
    echo "[i] ip_forward and the conntrack size stay as they are until the next reboot (turning them off now could cut other services)"
  fi
  echo "Done: all tunnels and files of this script are removed."
}


# ---------- encrypted tunnel next to GRE ----------
# One TLS connection per user connection. Two kinds: forward (Iran connects to the
# foreign server, VLESS + WebSocket + TLS with xray) and reverse (the foreign server
# connects to Iran, frp). Ports are moved onto it and back to GRE only by hand
# (option 7 / tunnel switch).
XT_DIR=/etc/xray-tunnel
XT_LIB=/usr/local/lib/xray-tunnel
XT_BIN=$XT_LIB/xray

xt_install_files() {
  mkdir -p "$XT_DIR" "$XT_LIB"; chmod 700 "$XT_DIR"
  save_self
  # conntrack moves UDP users back to GRE right away when a tunnel is removed
  if { [ "${1:-}" = iran ] || grep -qs '^ROLE=iran' "$XT_DIR"/*.conf; } &&
    ! command -v conntrack >/dev/null && command -v apt-get >/dev/null; then
    echo "[*] installing conntrack"
    timeout 60 apt-get install -y -qq --download-only conntrack >/dev/null 2>&1 &&
      apt-get install -y -qq --no-download conntrack >/dev/null 2>&1
  fi
  # written next to it and renamed, so a copy that is running is not changed under it
  cat > /usr/local/sbin/xray-tunnel.tmp <<'XRUNTIME'
#!/bin/bash
# Encrypted tunnel runtime: one encrypted connection per user connection, next to
# the GRE tunnel with the same number; ports are moved onto it and back to GRE only
# by hand (on/off). Two kinds (MODE in the settings):
#   forward: Iran opens VLESS + WebSocket + TLS connections to the foreign server (xray)
#   reverse: the foreign server opens the TLS connections to Iran (frp, no multiplexing:
#            one connection per user connection), for when Iran's connections to it are blocked
# Usage: xray-tunnel check|on|off <N> [port]   (up|down|keep|prestart|run|current: used by the services)
# Settings for tunnel N live in /etc/xray-tunnel/<N>.conf
set -u
VERSION=4.1.0
CMD=${1:-}; N=${2:-}; ARG=${3:-}
DIR=/etc/xray-tunnel
LIB=/usr/local/lib/xray-tunnel
BIN=$LIB/xray
if [ "$CMD" = version ]; then echo "xray-tunnel $VERSION"; exit 0; fi
CONF=$DIR/$N.conf
if ! [[ $N =~ ^[1-9]$ ]] || [ ! -f "$CONF" ]; then
  echo "usage: xray-tunnel check|on|off|up|down|keep <N> [port]  (missing $CONF; menu: tunnel)"; exit 1; fi
# one change at a time: the 30 s timer, on/off and the installer
case "$CMD" in up|down|keep|on|off|prestart)
  if command -v flock >/dev/null; then
    exec 9> "/run/xray-tunnel.$N.lock"; flock -w 30 9 || { echo "tunnel $N is busy, try again"; exit 1; }
  fi ;;
esac
ON=""; PIN=""; LPORTS=""; LHPORT=""; SNI=""; DEST=127.0.0.1; MODE=forward; TOKEN=""; HPASS=""; POOL=50
ULBASE=""; UDPK=8; PUBLIC_IP=""; APORT=""
# shellcheck source=/dev/null
. "$CONF"   # ROLE REMOTE_IP TPORT SNI PORTS DEST; forward: UUID WSPATH HPORT, iran: PIN;
            # reverse: MODE TOKEN HPASS LPORTS LHPORT ULBASE UDPK, foreign: POOL APORT; iran: LPORTS LHPORT ON
if [ "$MODE" = reverse ]; then
  EXT=toml; OTHER=json
  if [ "$ROLE" = iran ]; then BIN=$LIB/frps; else BIN=$LIB/frpc; fi
else EXT=json; OTHER=toml; fi
CFG=$DIR/$N.$EXT
NEWCFG=$DIR/$N.new.$EXT   # xray and frp read the format from the file ending
CHAIN=XTUN$N
STATE=/run/xray-tunnel.$N
# copy of the settings the running program was started with
RUNNING=/run/xray-tunnel.$N.$EXT
# kind, tunnel port and peer of the running program (its firewall stays until it restarts)
FWRUN=/run/xray-tunnel.$N.fw
JUMP=(PREROUTING ! -i vgre+ -m addrtype --dst-type LOCAL -j "$CHAIN")
TAG=(-m comment --comment "xray-tunnel-$N")

log() { logger -t xray-tunnel "tunnel $N: $*"; }
ipt_add() { local t=$1 op=$2; shift 2
  iptables -w -t "$t" -C "$@" 2>/dev/null || iptables -w -t "$t" "$op" "$@"; }
ipt_del() { local t=$1; shift
  while iptables -w -t "$t" -C "$@" 2>/dev/null; do iptables -w -t "$t" -D "$@"; done; }

# local listener of a user port, from LPORTS="443=61001,43773=61002"
lport() { local IFS=, m
  for m in $LPORTS; do [ "${m%%=*}" = "$1" ] && { echo "${m#*=}"; return 0; }; done; return 1; }
lport_list() { local IFS=, m out=""
  for m in $LPORTS; do out+="${out:+,}${m#*=}"; done; echo "$out"; }
in_list() { [[ ,$2, == *,"$1",* ]]; }

# reverse: the UDP of user port $1 is spread over UDPK local ports (one frp
# connection each; conntrack keeps every user flow on one of them), a block from
# ULBASE in the order of PORTS. Prints "first-last" (one port alone, as iptables
# lists it); nothing without ULBASE
urange() { local IFS=, p i=0 a
  [ "$MODE" = reverse ] && [ -n "$ULBASE" ] || return 1
  for p in $PORTS; do
    a=$((ULBASE + i * UDPK))
    [ "$p" = "$1" ] && { if [ "$UDPK" -gt 1 ]; then echo "$a-$((a + UDPK - 1))"; else echo "$a"; fi; return 0; }
    i=$((i + 1)); done; return 1; }
# the whole block, as first:last
ublock() { local n
  [ "$MODE" = reverse ] && [ -n "$ULBASE" ] || return 1
  n=$(tr , '\n' <<< "$PORTS" | grep -c .)
  if [ $((n * UDPK)) -gt 1 ]; then echo "$ULBASE:$((ULBASE + n * UDPK - 1))"; else echo "$ULBASE"; fi; }
# local UDP ports of user port $1, one per line
uports() { local r; r=$(urange "$1") && seq "${r%-*}" "${r#*-}" || lport "$1"; }

# reverse, Iran: the program listens on the tunnel's local ports only while the
# foreign server is connected; the health port is one of them there
gports() { if [ "$MODE" = reverse ]; then echo "$(lport_list),$LHPORT"; else lport_list; fi; }
# reverse: the name the foreign server checks in the certificate. Without a name
# it connects to the Iran IP, so no name is sent in the TLS handshake
sname() { echo "${SNI:-$REMOTE_IP}"; }
# the certificate the program uses: foreign reverse trusts Iran's ($N.ca.crt), the
# others serve their own ($N.crt)
cafile() { if [ "$MODE" = reverse ] && [ "$ROLE" != iran ]; then echo "$DIR/$N.ca.crt"; else echo "$DIR/$N.crt"; fi; }
certfp() { openssl x509 -in "$(cafile)" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 | tr -d :; }

sockopt='"sockopt": {"tcpKeepAliveIdle": 30, "tcpKeepAliveInterval": 10, "tcpUserTimeout": 30000}'
policy='"policy": {"levels": {"0": {"handshake": 8, "connIdle": 300, "uplinkOnly": 2, "downlinkOnly": 5}}}'

gen_json() {
  local IFS=, p tags="" ins="" sni=""
  if [ "$ROLE" = iran ]; then
    for p in $PORTS; do
      ins+="    {\"tag\": \"p$p\", \"listen\": \"0.0.0.0\", \"port\": $(lport "$p"), \"protocol\": \"dokodemo-door\",
     \"settings\": {\"address\": \"$DEST\", \"port\": $p, \"network\": \"tcp,udp\"}},
"
      tags+="\"p$p\", "
    done
    [ -n "$SNI" ] && sni="\"serverName\": \"$SNI\", "
    cat <<JSON
{
  "log": {"loglevel": "warning", "access": "none"},
  $policy,
  "inbounds": [
$ins    {"tag": "health", "listen": "127.0.0.1", "port": $LHPORT, "protocol": "dokodemo-door",
     "settings": {"address": "127.0.0.1", "port": $HPORT, "network": "tcp"}}
  ],
  "routing": {"rules": [{"inboundTag": [${tags}"health"], "outboundTag": "tunnel"}]},
  "outbounds": [
    {"tag": "block", "protocol": "blackhole"},
    {"tag": "tunnel", "protocol": "vless",
     "settings": {"address": "$REMOTE_IP", "port": $TPORT, "id": "$UUID", "encryption": "none"},
     "streamSettings": {"network": "ws", "security": "tls",
       "tlsSettings": {${sni}"fingerprint": "chrome", "alpn": ["http/1.1"], "pinnedPeerCertSha256": "$PIN"},
       "wsSettings": {"path": "$WSPATH?ed=2560"},
       $sockopt}}
  ]
}
JSON
  else
    cat <<JSON
{
  "log": {"loglevel": "warning", "access": "none"},
  $policy,
  "inbounds": [
    {"tag": "tunnel-in", "listen": "0.0.0.0", "port": $TPORT, "protocol": "vless",
     "settings": {"decryption": "none", "clients": [{"id": "$UUID", "email": "iran"}]},
     "streamSettings": {"network": "ws", "security": "tls",
       "tlsSettings": {"minVersion": "1.3", "alpn": ["http/1.1"],
         "certificates": [{"certificateFile": "$DIR/$N.crt", "keyFile": "$DIR/$N.key"}]},
       "wsSettings": {"path": "$WSPATH"},
       $sockopt}},
    {"tag": "health", "listen": "127.0.0.1", "port": $HPORT, "protocol": "socks",
     "settings": {"auth": "noauth", "udp": false}}
  ],
  "routing": {"rules": [
    {"inboundTag": ["tunnel-in"], "ip": ["$DEST"], "port": "$PORTS", "outboundTag": "local"},
    {"inboundTag": ["tunnel-in"], "ip": ["127.0.0.1"], "port": "$HPORT", "outboundTag": "local"}]},
  "outbounds": [
    {"tag": "block", "protocol": "blackhole"},
    {"tag": "local", "protocol": "freedom",
     "settings": {"finalRules": [
       {"action": "allow", "network": "tcp,udp", "ip": ["$DEST"], "port": "$PORTS"},
       {"action": "allow", "network": "tcp", "ip": ["127.0.0.1"], "port": "$HPORT"},
       {"action": "block"}]}}
  ]
}
JSON
  fi
}

# reverse: frps on Iran (the foreign server logs in and opens the local ports), frpc
# on the foreign server. No multiplexing: every user connection gets its own TLS
# connection, taken from a pool the foreign server keeps open to Iran
gen_toml() {
  local IFS=, p allow="" u k
  if [ "$ROLE" = iran ]; then
    for p in $(gports); do allow+="${allow:+, }{ single = $p }"; done
    u=$(ublock) && allow+=", { start = ${u%:*}, end = ${u#*:} }"
    # a new certificate is new settings: the program restarts to use it
    cat <<TOML
# certificate $(certfp)
bindAddr = "0.0.0.0"
bindPort = $TPORT
proxyBindAddr = "0.0.0.0"
allowPorts = [ $allow ]
userConnTimeout = 10
udpPacketSize = 7000
detailedErrorsToClient = false
auth.method = "token"
auth.token = "$TOKEN"
# the token also signs heartbeats and each new work connection, so a work connection
# cannot be offered by someone who knows only the run ID frp logs
auth.additionalScopes = ["HeartBeats", "NewWorkConns"]
transport.tcpMux = false
transport.maxPoolCount = 200
transport.tcpKeepalive = 30
transport.heartbeatTimeout = 45
transport.tls.force = true
transport.tls.certFile = "$DIR/$N.crt"
transport.tls.keyFile = "$DIR/$N.key"
log.to = "console"
log.level = "warn"
TOML
  else
    cat <<TOML
# certificate $(certfp)
serverAddr = "$REMOTE_IP"
serverPort = $TPORT
loginFailExit = false
udpPacketSize = 7000
auth.method = "token"
auth.token = "$TOKEN"
auth.additionalScopes = ["HeartBeats", "NewWorkConns"]
transport.protocol = "tcp"
transport.tcpMux = false
transport.poolCount = $POOL
transport.dialServerTimeout = 10
transport.dialServerKeepalive = 30
# frequent heartbeats: a lost request for work connections (frp issue 5549) is found soon
transport.heartbeatInterval = 10
transport.heartbeatTimeout = 45
transport.tls.enable = true
transport.tls.serverName = "$(sname)"
transport.tls.trustedCaFile = "$(cafile)"
log.to = "console"
log.level = "warn"
TOML
    # from the IP Iran accepts (a server with several IPs would use its main one)
    ip -o -4 addr show 2>/dev/null | grep -qF " $PUBLIC_IP/" && echo "transport.connectServerLocalIP = \"$PUBLIC_IP\""
    # status page on this server's loopback: it shows whether frpc is logged in to Iran
    aport_ok && printf 'webServer.addr = "127.0.0.1"\nwebServer.port = %s\nwebServer.user = "health"\nwebServer.password = "%s"\n' "$APORT" "$HPASS"
    for p in $PORTS; do
      printf '\n[[proxies]]\nname = "t%s-tcp-%s"\ntype = "tcp"\nlocalIP = "%s"\nlocalPort = %s\nremotePort = %s\n' "$N" "$p" "$DEST" "$p" "$(lport "$p")"
      k=0
      for u in $(uports "$p" | paste -sd, -); do
        k=$((k + 1))
        printf '\n[[proxies]]\nname = "t%s-udp-%s-%s"\ntype = "udp"\nlocalIP = "%s"\nlocalPort = %s\nremotePort = %s\n' "$N" "$p" "$k" "$DEST" "$p" "$u"
      done
    done
    # Iran checks the tunnel with an HTTP request to this port, answered here by a
    # password-protected web server of an empty folder: it connects nowhere
    printf '\n[[proxies]]\nname = "t%s-health"\ntype = "tcp"\nremotePort = %s\n[proxies.plugin]\ntype = "static_file"\nlocalPath = "%s"\nhttpUser = "health"\nhttpPassword = "%s"\n' "$N" "$LHPORT" "$LIB/empty" "$HPASS"
  fi
}
gen_cfg() { if [ "$MODE" = reverse ]; then gen_toml; else gen_json; fi; }
# settings the program rejects are not saved
cfg_ok() { [ -x "$BIN" ] || return 0
  if [ "$MODE" = reverse ]; then "$BIN" verify -c "$1"; else "$BIN" run -test -c "$1"; fi; }

# Iran: users of the ports in ON are redirected to the local listener, which
# sends them through the tunnel. Only the jump into the chain is switched on and
# off; that affects new connections only, open ones keep their path.
sync_chain() { local IFS=, p lp want="" r u
  iptables -w -t nat -N "$CHAIN" 2>/dev/null
  for p in $ON; do
    lp=$(lport "$p") || continue
    ipt_add nat -A "$CHAIN" -p tcp --dport "$p" -j REDIRECT --to-ports "$lp"
    want+="-A $CHAIN -p tcp -m tcp --dport $p -j REDIRECT --to-ports $lp"$'\n'
    if u=$(urange "$p"); then
      ipt_add nat -A "$CHAIN" -p udp --dport "$p" -j REDIRECT --to-ports "$u" --random
      want+="-A $CHAIN -p udp -m udp --dport $p -j REDIRECT --to-ports $u --random"$'\n'
    else
      ipt_add nat -A "$CHAIN" -p udp --dport "$p" -j REDIRECT --to-ports "$lp"
      want+="-A $CHAIN -p udp -m udp --dport $p -j REDIRECT --to-ports $lp"$'\n'
    fi
  done
  iptables -w -t nat -S "$CHAIN" 2>/dev/null | grep -- "^-A $CHAIN " | while IFS= read -r r; do
    grep -qxF -- "$r" <<< "$want" && continue
    IFS=' ' read -r -a a <<< "${r#-A }"
    iptables -w -t nat -D "${a[@]}"
    # the UDP of a port now goes to other local ports (the kind changed): its users
    # keep the old ones while they send, where nothing listens any more
    if [[ $r =~ -p\ udp\ .*--dport\ ([0-9]+)\ -j\ REDIRECT\ --to-ports\ ([0-9]+)(-([0-9]+))? ]] &&
       grep -q -- "-p udp -m udp --dport ${BASH_REMATCH[1]} " <<< "$want" && command -v conntrack >/dev/null; then
      p=${BASH_REMATCH[1]}
      for u in $(seq -s, "${BASH_REMATCH[2]}" "${BASH_REMATCH[4]:-${BASH_REMATCH[2]}}"); do
        conntrack -D -p udp --orig-port-dst "$p" --reply-port-src "$u" >/dev/null 2>&1; done
    fi
  done
}
# Iran: the listeners take redirected users (also when INPUT drops by default, e.g. ufw)
# and local programs, never direct connections
guard() { local lps r u; lps=$(gports)
  for r in tcp udp; do
    ipt_add filter -I INPUT ! -i lo -p "$r" -m multiport --dports "$lps" -m conntrack ! --ctstate DNAT "${TAG[@]}" -j DROP
    ipt_add filter -I INPUT ! -i lo -p "$r" -m multiport --dports "$lps" -m conntrack --ctstate DNAT "${TAG[@]}" -j ACCEPT
  done
  if u=$(ublock); then
    ipt_add filter -I INPUT ! -i lo -p udp --dport "$u" -m conntrack ! --ctstate DNAT "${TAG[@]}" -j DROP
    ipt_add filter -I INPUT ! -i lo -p udp --dport "$u" -m conntrack --ctstate DNAT "${TAG[@]}" -j ACCEPT
  fi; }
# does a program of kind $2 listen on the tunnel port on a server of role $1
# (forward: the foreign server, reverse: the Iran server)
listens() { if [ "$1" = iran ]; then [ "$2" = reverse ]; else [ "$2" != reverse ]; fi; }
is_current() { [ -f "$RUNNING" ] && [ "$(cat "$RUNNING")" = "$(cat "$CFG" 2>/dev/null)" ]; }
# "PORT IP": tunnel ports here that answer only that IP. Those of the settings, and
# until it restarts, the one of the program still running with older settings
fw_pairs() { local m t ip
  listens "$ROLE" "$MODE" && echo "$TPORT $REMOTE_IP"
  if [ -f "$FWRUN" ] && ! is_current; then
    read -r m t ip < "$FWRUN"
    if [ -n "$t" ] && listens "$ROLE" "$m" && { ! listens "$ROLE" "$MODE" || [ "$t" != "$TPORT" ]; }; then echo "$t $ip"; fi
  fi; true; }
fw_in() { local t ip
  while read -r t ip; do
    [ -n "$t" ] || continue
    ipt_add filter -I INPUT -p tcp --dport "$t" ! -s "$ip" "${TAG[@]}" -j DROP
    ipt_add filter -I INPUT -p tcp --dport "$t" -s "$ip" "${TAG[@]}" -j ACCEPT
  done <<< "$(fw_pairs)"; }
# deletes this tunnel's filter rules (they are tagged); with $1 = old, only the
# ones left from older settings (other listener ports, tunnel port or peer IP)
unfw() { local r a lps u pairs keep t ip; lps=$(gports); u=$(ublock) || u=""; pairs=$(fw_pairs)
  iptables -w -S 2>/dev/null | grep -F -- "--comment xray-tunnel-$N " | while IFS= read -r r; do
    if [ "${1:-}" = old ]; then
      keep=0
      if [ "$ROLE" = iran ]; then
        [[ $r == *" --dports $lps "* ]] && keep=1
        [ -n "$u" ] && [[ $r == *" --dport $u "* ]] && keep=1
      fi
      while read -r t ip; do
        [ -n "$t" ] && [[ $r == *" -s $ip/32 "* && $r == *" --dport $t "* ]] && keep=1
      done <<< "$pairs"
      [ "$keep" = 1 ] && continue
    fi
    IFS=' ' read -r -a a <<< "${r#-A }"; iptables -w -D "${a[@]}"; done; }
# IPv6: the programs listen on all addresses, IPv6 too, but the tunnel uses only
# IPv4: its ports are closed there. $1 = all: removes these rules
fw6() { local w="" r a lps u t ip
  command -v ip6tables >/dev/null && ip6tables -w -S INPUT >/dev/null 2>&1 || return 0
  if [ "${1:-}" != all ]; then
    if [ "$ROLE" = iran ]; then lps=$(gports)
      for r in tcp udp; do w+="-A INPUT ! -i lo -p $r -m multiport --dports $lps -m comment --comment xray-tunnel-$N -j DROP"$'\n'; done
      u=$(ublock) && w+="-A INPUT ! -i lo -p udp -m udp --dport $u -m comment --comment xray-tunnel-$N -j DROP"$'\n'
    fi
    while read -r t ip; do
      [ -n "$t" ] && w+="-A INPUT ! -i lo -p tcp -m tcp --dport $t -m comment --comment xray-tunnel-$N -j DROP"$'\n'
    done <<< "$(fw_pairs)"
  fi
  ip6tables -w -S INPUT 2>/dev/null | grep -F -- "--comment xray-tunnel-$N " | while IFS= read -r r; do
    grep -qxF -- "$r" <<< "$w" && continue
    IFS=' ' read -r -a a <<< "${r#-A }"; ip6tables -w -D "${a[@]}"; done
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    IFS=' ' read -r -a a <<< "${r#-A INPUT }"
    ip6tables -w -C INPUT "${a[@]}" 2>/dev/null || ip6tables -w -I INPUT "${a[@]}"
  done <<< "$w"; }

# Iran: the kernel must not give the listener ports to outgoing connections (a
# widened ip_local_port_range can include them), or xray could not listen on them
RES=/proc/sys/net/ipv4/ip_local_reserved_ports
in_ranges() { awk -v p="$1" -v l="$2" 'BEGIN { n = split(l, t, ",")
  for (i = 1; i <= n; i++) { k = split(t[i], r, "-"); if (t[i] != "" && p >= r[1] + 0 && p <= (k > 1 ? r[2] : r[1]) + 0) exit 0 }
  exit 1 }'; }
# reverse: the port the foreign server connects to, too
res_list() { local l u; l="$(lport_list),$LHPORT"
  [ "$MODE" = reverse ] && l+=",$TPORT"
  u=$(ublock) && l+=",$(seq "${u%:*}" "${u#*:}" | paste -sd, -)"
  echo "$l"; }
# the list is shared by all tunnels: one change at a time
res_lock() { command -v flock >/dev/null || return 0; exec 8> /run/xray-tunnel.reserved.lock; flock -w 10 8; }
# the ports this tunnel reserved last, so a port it no longer uses (another kind or
# other settings) is given back
RESLAST=/run/xray-tunnel.$N.res
res_remove() { local cur
  cur=$(cat "$RES")
  awk -v l="$cur" -v d="$1" 'BEGIN { n = split(d, x, ","); for (i = 1; i <= n; i++) if (x[i] != "") D[x[i] + 0] = 1
    m = split(l, t, ","); out = ""
    for (i = 1; i <= m; i++) { if (t[i] == "") continue
      k = split(t[i], r, "-"); a = r[1] + 0; b = (k > 1 ? r[2] : r[1]) + 0; s = a
      for (p = a; p <= b + 1; p++) if (p > b || (p in D)) {
        if (s <= p - 1) out = out (out == "" ? "" : ",") (s == p - 1 ? s : s "-" (p - 1)); s = p + 1 } }
    print out }' > "$RES"; }
reserve() { local IFS=, cur p add="" want gone=""
  [ -w "$RES" ] || return 0
  res_lock; want=$(res_list)
  for p in $(cat "$RESLAST" 2>/dev/null); do in_list "$p" "$want" || gone+=",$p"; done
  [ -z "$gone" ] || res_remove "$gone"
  cur=$(cat "$RES")
  for p in $want; do in_ranges "$p" "$cur" || add+=",$p"; done
  [ -z "$add" ] || echo "${cur}${add}" | sed 's/^,//' > "$RES"
  echo "$want" > "$RESLAST"; }
unreserve() {
  [ -w "$RES" ] || return 0
  res_lock; res_remove "$(res_list),$(cat "$RESLAST" 2>/dev/null)"; rm -f "$RESLAST"; }

# our jump must come before every PREROUTING rule except other tunnels' jumps
# (GRE's DNAT for the same ports is below it, and is used again once it is gone)
jump_first() { local IFS=' '
  iptables -w -t nat -S PREROUTING 2>/dev/null | awk -v want="-A ${JUMP[*]}" '
    /^-A / { if ($0 == want) { ok = 1; exit } if ($0 !~ / -j XTUN[1-9]$/) exit }
    END { exit !ok }'; }
jump_on() {
  jump_first && return 0
  ipt_del nat "${JUMP[@]}"
  iptables -w -t nat -I "${JUMP[@]:0:1}" 1 "${JUMP[@]:1}"; }
release() { ipt_del nat "${JUMP[@]}"; }

up() {
  local new rc=0; new=$(gen_cfg)
  if [ ! -f "$CFG" ] || [ "$(cat "$CFG")" != "$new" ]; then
    (umask 077; printf '%s\n' "$new" > "$NEWCFG")
    # settings the program rejects are not saved: the running ones and the next start keep working
    if ! cfg_ok "$NEWCFG" >/dev/null 2>&1; then
      echo "[!] $(basename "$BIN") rejects the new settings of tunnel $N:" >&2
      cfg_ok "$NEWCFG" 2>&1 | tail -5 >&2
      log "new settings rejected by $(basename "$BIN"), not saved"; rc=1
    else mv -f "$NEWCFG" "$CFG"; fi
    rm -f "$NEWCFG"
  fi
  # settings of the other kind, from before a change of kind
  rm -f "$DIR/$N.$OTHER"
  # the running copy holds the key too: only root reads it
  [ -f "$RUNNING" ] && chmod 600 "$RUNNING"
  unfw old
  if [ "$ROLE" = iran ]; then
    reserve; sync_chain; guard; fw_in
    if [ -n "$ON" ]; then jump_on; else release; fi
  else fw_in; fi
  fw6
  return $rc
}
down() {
  local IFS=, lp all u
  if [ "$ROLE" = iran ]; then
    release
    iptables -w -t nat -F "$CHAIN" 2>/dev/null; iptables -w -t nat -X "$CHAIN" 2>/dev/null
    # UDP users keep their redirect while they send, even with nothing listening
    # any more; without it their next packet goes to GRE
    if command -v conntrack >/dev/null; then
      all=$(lport_list); u=$(ublock) && all+=",$(seq "${u%:*}" "${u#*:}" | paste -sd, -)"
      for lp in $all; do conntrack -D -p udp --reply-port-src "$lp" >/dev/null 2>&1; done; fi
    unreserve
  fi
  unfw; fw6 all
  rm -f "$STATE" "$STATE.miss" "$FWRUN" "/run/xray-tunnel.$N.conf" "/run/xray-tunnel.$N.json" "/run/xray-tunnel.$N.toml"; true
}

# Iran: a SOCKS greeting to the foreign server's health listener, sent through
# the tunnel, must come back as 05 00 (reverse: asks for a password, 05 02)
# Iran, reverse: listeners of frps running as root. ss shows the uid of other users'
# sockets: their program could take a local port while frps has it closed
frps_socks() { ss -Hlnpe "$@" 2>/dev/null | grep '"frps"' | grep -v ' uid:'; }
probe() { local r
  if [ "$MODE" = reverse ]; then
    # the health port must be frps (not another program that took the port)
    frps_socks -t "( sport = :$LHPORT )" | grep -q . || return 1
    r=$(timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/$LHPORT || exit 1; printf 'GET / HTTP/1.0\r\n\r\n' >&3; head -c 5 <&3" 2>/dev/null)
    [ "$r" = HTTP/ ]; return; fi
  r=$(timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/$LHPORT || exit 1; printf '\x05\x01\x00' >&3; head -c 2 <&3 | od -An -tx1" 2>/dev/null | tr -d ' \n')
  [ "$r" = 0500 ]; }

# are the local listeners of user port $1 there (reverse: frps opens them only while
# the foreign server sends that port, TCP and every UDP port of its block)
port_ok() { local u want
  [ "$MODE" = reverse ] || { ss -Hltn "( sport = :$(lport "$1") )" 2>/dev/null | grep -q .; return; }
  # frps itself, not another program that took the port while the foreign server was away
  frps_socks -t "( sport = :$(lport "$1") )" | grep -q . || return 1
  u=$(urange "$1") || u="$(lport "$1")-$(lport "$1")"
  want=$(( ${u#*-} - ${u%-*} + 1 ))
  [ "$(frps_socks -u "( sport ge :${u%-*} and sport le :${u#*-} )" | wc -l)" -ge "$want" ]; }
# ports of ON whose listeners are missing
missing() { local IFS=, p out=""
  for p in $ON; do port_ok "$p" || out+="${out:+,}$p"; done; echo "$out"; }
# foreign, reverse: connections to the Iran server (the control connection, the pool
# and the users' connections)
rx_conns() { ss -Htn state established dst "$REMOTE_IP" "( dport = :$TPORT )" 2>/dev/null | wc -l; }
# foreign, reverse: users' connections frpc has open to the services here (its idle pool
# connections to Iran are not users)
rx_users() { local IFS=, p f=""
  for p in $PORTS; do f+="${f:+ or }dport = :$p"; done
  [ -n "$f" ] || { echo 0; return; }
  ss -Htn state established "( ( $f ) and dst $DEST )" 2>/dev/null | wc -l; }
# foreign, reverse: the port of frpc's status page is free for it (frpc does not start
# when its port is taken, so a port another program took is left out)
aport_ok() { [ "$MODE" = reverse ] && [ "$ROLE" != iran ] && [[ $APORT =~ ^[0-9]+$ ]] || return 1
  ! ss -Hltnp "( sport = :$APORT )" 2>/dev/null | grep -v '"frpc"' | grep -q .; }
# foreign, reverse: is frpc logged in to the Iran server: its status page shows the
# health proxy running. Users' connections that stay open after the login was lost
# do not count
rx_up() { local p w
  p=$(sed -n 's/^webServer.port = //p' "$RUNNING" 2>/dev/null)
  w=$(sed -n 's/^webServer.password = "\(.*\)"$/\1/p' "$RUNNING" 2>/dev/null)
  if [[ $p =~ ^[0-9]+$ ]]; then
    printf 'GET /api/status HTTP/1.0\r\nAuthorization: Basic %s\r\n\r\n' "$(printf 'health:%s' "$w" | base64 -w0)" |
      timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/$p || exit 1; cat >&3; cat <&3" 2>/dev/null |
      grep -o "\"name\":\"t$N-health\"[^}]*" | grep -q '"status":"running"'
    return
  fi
  # a program started without the status page: the control connection alone is a
  # login that did not finish
  [ "$(rx_conns)" -ge 2 ]; }

# Runs every 30 s: puts back rules that something removed (iptables -F, a GRE
# tunnel restart that inserted its rules above ours) and logs when the tunnel
# stops or starts answering. It never moves a port: only on/off does that.
keep() { local st prev k miss c
  up >/dev/null 2>&1
  if [ "$ROLE" != iran ]; then
    [ "$MODE" = reverse ] && systemctl -q is-active "xray-tunnel@$N" || return 0
    # frpc has no time limit for the TLS handshake and login: when one hangs (a
    # path that drops the connection after its first packets), it would wait many
    # minutes. Not logged in for 90 s: restart it. Users' connections opened before
    # can still work (a path that stops only new connections), and a restart cuts
    # them, so while any is open it waits 10 minutes first
    k=$(cat "$STATE" 2>/dev/null); [[ $k =~ ^[0-9]+$ ]] || k=0
    if rx_up; then
      [ "$k" -ge 3 ] && log "connected to the Iran server $REMOTE_IP:$TPORT again"
      echo 0 > "$STATE"; return 0
    fi
    k=$((k + 1)); c=$(rx_users)
    if [ "$k" = 3 ]; then
      if [ "$c" -ge 1 ]; then
        log "not logged in to the Iran server $REMOTE_IP:$TPORT for 90 s; $c users' connections opened before are still open, so it restarts only after 10 minutes (systemctl restart xray-tunnel@$N does it now and cuts them)"
      else log "not connected to the Iran server $REMOTE_IP:$TPORT for 90 s: restarting it every 90 s until it connects"; fi
    fi
    if [ $((k % 3)) = 0 ] && { [ "$c" = 0 ] || [ "$k" -ge 20 ]; }; then
      systemctl restart --no-block "xray-tunnel@$N" 9>&-   # (not holding our lock)
    fi
    echo "$k" > "$STATE"; return 0
  fi
  prev=$(cat "$STATE" 2>/dev/null || echo ok)
  if ! systemctl -q is-active "xray-tunnel@$N"; then st=stopped
  elif probe; then st=ok; else st=fail; fi
  [ "$st" != ok ] && [ "$prev" != ok ] && unstick
  if [ "$st" != "$prev" ]; then
    case $st in
      fail) log "no answer from $REMOTE_IP through the tunnel; users of ports ${ON:-none} cannot connect. Move its ports to GRE: tunnel switch $N gre" ;;
      stopped) log "service xray-tunnel@$N is not running; users of ports ${ON:-none} cannot connect (journalctl -u xray-tunnel@$N)" ;;
      ok) log "tunnel to $REMOTE_IP answers again" ;;
    esac
  fi
  echo "$st" > "$STATE"
  # reverse: one port can be missing while the tunnel answers (its local port was taken)
  if [ "$st" = ok ] && [ "$MODE" = reverse ]; then
    miss=$(missing)
    if [ "$miss" != "$(cat "$STATE.miss" 2>/dev/null)" ]; then
      if [ -n "$miss" ]; then log "the foreign server does not send ports $miss now: their users cannot connect (xray-tunnel check $N)"
      else log "all ports on the tunnel work again"; fi
      echo "$miss" > "$STATE.miss"
    fi
  fi
}

flush_udp() { local IFS=$' \t\n' u
  command -v conntrack >/dev/null || return 0
  for u in $(uports "$1"); do conntrack -D -p udp --reply-port-src "$u" >/dev/null 2>&1; done; true; }
# ports already moved back to GRE by hand: UDP users who still send to the dead
# tunnel (their redirect stays while they send) go to GRE once it is dead for 30 s
unstick() { local IFS=, p
  command -v conntrack >/dev/null || return 0
  for p in $PORTS; do in_list "$p" "$ON" || flush_udp "$p"; done; }

set_on() { local IFS=, p out=""
  for p in $ON; do [ "$p" = "$ARG" ] || out+="${out:+,}$p"; done
  [ "$1" = add ] && out+="${out:+,}$ARG"
  ON=$out
  if grep -q '^ON=' "$CONF"; then sed -i "s/^ON=.*/ON=$ON/" "$CONF"; else echo "ON=$ON" >> "$CONF"; fi
  sync_chain
  if [ -n "$ON" ]; then jump_on; else release; fi; }

check() { local st c miss
  if [ "$MODE" = reverse ] && [ "$ROLE" = iran ]; then
    echo "xray-tunnel $VERSION | tunnel $N | role iran | reverse: $REMOTE_IP connects to port $TPORT here | ports $PORTS${ON:+ | on the tunnel: $ON}"
  elif [ "$MODE" = reverse ]; then echo "xray-tunnel $VERSION | tunnel $N | role foreign | reverse: connects to $REMOTE_IP:$TPORT | ports $PORTS"
  else echo "xray-tunnel $VERSION | tunnel $N | role $ROLE | peer $REMOTE_IP:$TPORT | ports $PORTS${ON:+ | on the tunnel: $ON}"; fi
  if systemctl -q is-active "xray-tunnel@$N"; then echo "[ok] service xray-tunnel@$N is running"
  else echo "[!!] service xray-tunnel@$N is not running: journalctl -u xray-tunnel@$N -n 20"; fi
  if [ -f "$RUNNING" ] && [ "$(cat "$RUNNING")" != "$(cat "$CFG" 2>/dev/null)" ]; then
    echo "[i] new settings are saved but used only after: systemctl restart xray-tunnel@$N (cuts open tunnel connections)"
  elif [ ! -f "$RUNNING" ] && [ -f "/run/xray-tunnel.$N.$OTHER" ] && systemctl -q is-active "xray-tunnel@$N"; then
    echo "[!!] the service still runs the $([ "$MODE" = reverse ] && echo forward || echo reverse) kind of this tunnel; the new kind"
    echo "     starts with: systemctl restart xray-tunnel@$N (cuts open tunnel connections)"; fi
  if [ "$ROLE" = iran ]; then
    if [ "$MODE" = reverse ]; then c=$(ss -Htn state established src ":$TPORT" dst "$REMOTE_IP" 2>/dev/null | wc -l)
    else c=$(ss -Htn state established dst "$REMOTE_IP" "( dport = :$TPORT )" 2>/dev/null | wc -l); fi
    if probe; then echo "[ok] the foreign server answers through the tunnel ($c open tunnel connections)"; st=0
    elif [ "$MODE" = reverse ]; then
      echo "[!!] no answer through the tunnel: $REMOTE_IP is not connected to port $TPORT here ($c connections)"
      echo "     (run 'xray-tunnel check $N' on $REMOTE_IP; if its IP changed, run option 1 here with the new IP)"; st=1
    else echo "[!!] no answer through the tunnel (run 'xray-tunnel check $N' on $REMOTE_IP too)"; st=1; fi
    if [ -z "$ON" ]; then echo "[i] no port uses the tunnel yet (move one: xray-tunnel on $N PORT)"
    elif jump_first; then
      echo "[ok] ports $ON use the tunnel (new connections)"
    else echo "[!!] ports $ON should use the tunnel but its rule is not first (fixed within 30 s, or run: xray-tunnel up $N)"; fi
    if [ "$st" = 0 ] && [ "$MODE" = reverse ]; then
      miss=$(missing)
      [ -z "$miss" ] || { echo "[!!] the foreign server does not send ports $miss now: their users cannot connect"
        echo "     (run option 1 on $REMOTE_IP with the latest code; journalctl -u xray-tunnel@$N -n 20 here)"; st=1; }
    fi
    return $st
  fi
  if [ "$MODE" = reverse ]; then
    c=$(rx_conns)
    if rx_up; then echo "[ok] connected to the Iran server $REMOTE_IP:$TPORT ($c connections)"; return 0; fi
    echo "[!!] not connected to the Iran server $REMOTE_IP:$TPORT (journalctl -u xray-tunnel@$N -n 20)."
    echo "     If this server's IP changed, run option 1 on the Iran server with the new IP."
    return 1
  fi
  c=$(ss -Htn state established src ":$TPORT" dst "$REMOTE_IP" 2>/dev/null | wc -l)
  if ss -Hltn "( sport = :$TPORT )" 2>/dev/null | grep -q .; then echo "[ok] listening on port $TPORT ($c connections from $REMOTE_IP)"
  else echo "[!!] nothing listens on port $TPORT"; return 1; fi
}

# the installer is changing the settings of this tunnel and may still ask before they
# apply: the timers do not apply them meanwhile (a marker older than 15 minutes is left over)
busy() { [ -z "${XT_INSTALLER:-}" ] && [ -n "$(find "/run/xray-tunnel.$N.busy" -mmin -15 2>/dev/null)" ]; }
case "$CMD" in
  up) busy || up ;; down) down ;; keep) busy || keep ;;
  # the service starts the program with the settings on disk now
  prestart) up; rm -f "/run/xray-tunnel.$N.$OTHER"
    # the files of the other kind are not used any more (they were kept until now for
    # the program that ran before)
    if [ "$MODE" = reverse ] && [ "$ROLE" != iran ]; then rm -f "$DIR/$N.crt" "$DIR/$N.key"; mkdir -p "$LIB/empty"
    elif [ "$MODE" = reverse ]; then :
    elif [ "$ROLE" = iran ]; then rm -f "$DIR/$N.crt" "$DIR/$N.key"
    else rm -f "$DIR/$N.ca.crt"; fi
    [ -f "$CFG" ] && install -m 600 "$CFG" "$RUNNING"
    # foreign, reverse: the count of keep checks without a login starts again
    [ "$MODE" = reverse ] && [ "$ROLE" != iran ] && echo 0 > "$STATE"
    echo "$MODE $TPORT $REMOTE_IP" > "$FWRUN"
    # the installer counts the users of the running program with these settings
    install -m 600 "$CONF" "/run/xray-tunnel.$N.conf"
    # the filter of the settings the program ran with before is not needed any more
    up >/dev/null 2>&1 ;;
  run) if [ "$MODE" = reverse ]; then exec "$BIN" -c "$CFG"; else exec "$BIN" run -c "$CFG"; fi ;;
  # is the program running with the settings on disk
  current) is_current ;;
  check) check ;;
  on|off)
    [ "$ROLE" = iran ] || { echo "run this on the Iran server"; exit 1; }
    [[ $ARG =~ ^[0-9]+$ ]] && in_list "$ARG" "$PORTS" || { echo "port '$ARG' is not one of this tunnel's ports ($PORTS)"; exit 1; }
    if [ "$CMD" = on ]; then
      probe || { echo "[!!] the tunnel does not answer (xray-tunnel check $N); port $ARG stays on GRE"; exit 1; }
      port_ok "$ARG" || {
        if [ "$MODE" = reverse ]; then echo "[!!] the foreign server does not send port $ARG yet: run option 1 there with the latest code; port $ARG stays on GRE"
        else echo "[!!] xray does not listen for port $ARG yet: it needs systemctl restart xray-tunnel@$N (cuts open tunnel connections); port $ARG stays on GRE"; fi
        exit 1; }
      set_on add; log "port $ARG moved to the tunnel"
      echo "port $ARG: new connections use the encrypted tunnel; open ones stay on GRE until they end"
      # UDP users keep their GRE path while they send: on a GRE tunnel that does not
      # answer they would stay cut, so they are moved now
      if command -v conntrack >/dev/null && [ -f "/etc/gre-tunnel/$N.conf" ] &&
         ! timeout 20 /usr/local/sbin/gre-tunnel check "$N" >/dev/null 2>&1; then
        conntrack -D -p udp --orig-port-dst "$ARG" --reply-src "10.200.$N.1" >/dev/null 2>&1
        echo "GRE tunnel $N does not answer: UDP users of port $ARG were moved to the encrypted tunnel too"; fi
    else set_on del; log "port $ARG moved back to GRE"
      echo "port $ARG: new connections use GRE again; open tunnel connections continue until they end"
      # UDP users keep their redirect while they send. When the tunnel is dead (the
      # 30 s check found it dead and it still does not answer) they would stay cut,
      # so they are moved to GRE now; on a working tunnel they stay, like TCP users
      if command -v conntrack >/dev/null && [ "$(cat "$STATE" 2>/dev/null || echo ok)" != ok ] && ! probe; then
        flush_udp "$ARG"
        echo "the tunnel does not answer: UDP users of port $ARG were moved to GRE too"; fi
    fi ;;
  *) echo "usage: xray-tunnel check|on|off|up|down|keep|run <N> [port] | version"; exit 1 ;;
esac
XRUNTIME
  chmod 755 /usr/local/sbin/xray-tunnel.tmp && mv -f /usr/local/sbin/xray-tunnel.tmp /usr/local/sbin/xray-tunnel

  cat > /etc/systemd/system/xray-tunnel@.service <<'UNIT'
[Unit]
Description=Encrypted tunnel %i
After=network-online.target gre-tunnel@%i.service
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
# Go's MPTCP listeners ignore the TCP user timeout
# (the program and its settings file depend on the kind: xray-tunnel run picks them)
Environment=GODEBUG=multipathtcp=0
ExecStartPre=/usr/local/sbin/xray-tunnel prestart %i
ExecStart=/usr/local/sbin/xray-tunnel run %i
Restart=always
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
UNIT

  cat > /etc/systemd/system/xray-tunnel-keep@.service <<'UNIT'
[Unit]
Description=Encrypted tunnel %i: keep its firewall rules in place

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/xray-tunnel keep %i
UNIT

  cat > /etc/systemd/system/xray-tunnel-keep@.timer <<'UNIT'
[Unit]
Description=Encrypted tunnel %i: keep its firewall rules in place every 30s

[Timer]
OnBootSec=1min
OnUnitActiveSec=30s
AccuracySec=5s

[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload
}

xt_get() { sed -n "s/^$1=//p" "$2" 2>/dev/null | tail -1; }
xt_confs() { local f; for f in "$XT_DIR"/*.conf; do [ -e "$f" ] && basename "$f" .conf; done; }
# every encrypted tunnel number known to the files or to systemd
xt_instances() {
  { xt_confs
    systemctl list-units --all --plain --no-legend 'xray-tunnel@*' 'xray-tunnel-keep@*' 2>/dev/null | awk '{ print $1 }'
    ls /etc/systemd/system/*.wants/ 2>/dev/null
  } | sed -E 's/^xray-tunnel(-keep)?@([^.]+)\..*/\2/' | grep -E '^[0-9]+$' | sort -un
}
in_csv() { [[ ,$2, == *,"$1",* ]]; }
xt_rand() { head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }

# single ports (no ranges), comma separated, at most 14; prints them without leading zeros
xt_ports() { local IFS=, p out="" c=0
  [[ $1 =~ ^[0-9]{1,5}(,[0-9]{1,5})*$ ]] || return 1
  for p in $1; do
    p=$((10#$p)); [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || return 1
    in_csv "$p" "$out" || { out+="${out:+,}$p"; c=$((c + 1)); }
  done
  [ "$c" -le 14 ] && echo "$out"; }

# ports in use in any state: a port an open connection uses cannot be listened on
xt_listening() { ss -Htuan 2>/dev/null | awk '{ n = split($5, a, ":"); print a[n] }' | sort -un; }
# first port from $1 up that nothing listens on and is not in the list $2
xt_free_port() { local p=$1 used; used=$(xt_listening)
  while grep -qx "$p" <<< "$used" || in_csv "$p" "$2"; do p=$((p + 1)); done
  echo "$p"; }

# open user connections of tunnel $1 (reverse: the idle pool the foreign server
# keeps open is not counted)
xt_conns() { local c=$XT_DIR/$1.conf r t f="" p m run=""
  # the settings the program runs with (another kind, other ports) until it restarts;
  # a program started by v4.0 left no copy of them: then the settings before this change
  if [ -f "/run/xray-tunnel.$1.conf" ]; then c=/run/xray-tunnel.$1.conf
  else
    [ -f "/run/xray-tunnel.$1.json" ] && run=forward; [ -f "/run/xray-tunnel.$1.toml" ] && run=reverse
    m=$(xt_get MODE "$c"); [ "$m" = reverse ] || m=forward
    [ -n "$run" ] && [ "$run" != "$m" ] && [ -f "$c.prev" ] && c=$c.prev
  fi
  r=$(xt_get REMOTE_IP "$c"); t=$(xt_get TPORT "$c")
  if [ "$(xt_get MODE "$c")" = reverse ]; then
    if [ "$(xt_get ROLE "$c")" = iran ]; then
      for m in $(tr , ' ' <<< "$(xt_get LPORTS "$c")"); do f+="${f:+ or }sport = :${m#*=}"; done
    else
      for p in $(tr , ' ' <<< "$(xt_get PORTS "$c")"); do f+="${f:+ or }dport = :$p"; done
      f="( $f ) and dst $(xt_get DEST "$c")"
    fi
    [ -n "$f" ] || { echo 0; return; }
    ss -Htn state established "( $f )" 2>/dev/null | wc -l
  elif [ "$(xt_get ROLE "$c")" = iran ]; then ss -Htn state established dst "$r:$t" 2>/dev/null | wc -l
  else ss -Htn state established src ":$t" dst "$r" 2>/dev/null | wc -l; fi; }

# the xray program: a copy of the one x-ui uses, so x-ui updates do not change it
xt_find_xray() { local b
  for b in /usr/local/x-ui/bin/xray-linux-* /usr/local/bin/xray /usr/bin/xray; do
    case $b in *.bak*|*.old|*.orig) continue ;; esac
    [ -f "$b" ] && [ -x "$b" ] && "$b" version >/dev/null 2>&1 && { echo "$b"; return 0; }
  done; return 1; }
xt_bin() { local src
  [ -x "$XT_BIN" ] && "$XT_BIN" version >/dev/null 2>&1 && return 0
  src=$(xt_find_xray) || { echo "[!] xray not found on this server (x-ui keeps it in /usr/local/x-ui/bin/). Install x-ui, or copy an xray program to $XT_BIN"; return 1; }
  mkdir -p "$XT_LIB"
  cp -f "$src" "$XT_BIN.tmp" && chmod 755 "$XT_BIN.tmp" && mv -f "$XT_BIN.tmp" "$XT_BIN" || return 1
  echo "[*] using a copy of $src ($("$XT_BIN" version 2>/dev/null | head -1 | awk '{ print $1, $2 }'))"
}

# where the services of these ports listen on the foreign server: 127.0.0.1 reaches
# the ones on all addresses; ones bound to a single address need that address
xt_dest() { local IFS=, p a d="" one
  for p in $1; do
    a=$(ss -Htln "( sport = :$p )" 2>/dev/null | awk '{ print $4 }' | sed -E 's/:[0-9]+$//' | sort -u)
    [ -n "$a" ] || { echo "[!] nothing listens on TCP port $p here yet (it works once your service does)" >&2; continue; }
    if grep -qE '^(\*|0\.0\.0\.0|\[::\]|127\.0\.0\.1)$' <<< "$a"; then one=127.0.0.1
    else one=$(grep -m1 -Fxf <(ip -o -4 addr show | awk '{ sub(/\/.*/, "", $4); print $4 }') <<< "$a")
      [ -n "$one" ] || one=$(grep -m1 -E '^[0-9.]+$' <<< "$a"); fi
    [ -n "$one" ] || { echo "[!] port $p listens only on $a; cannot reach it" >&2; return 1; }
    [ -z "$d" ] || [ "$d" = "$one" ] || { echo "[!] the ports listen on different addresses ($d, $one); use one encrypted tunnel per address" >&2; return 1; }
    d=$one
  done
  echo "${d:-127.0.0.1}"; }

# starts tunnel $1 or applies its new settings; restarting a running tunnel cuts
# its open connections for a moment, so that is asked first when it has any
# the kind of the program tunnel $1 runs now (nothing when it does not run)
xt_run_kind() { local n=$1
  systemctl -q is-active "xray-tunnel@$n" || return 0
  if [ -f "/run/xray-tunnel.$n.conf" ]; then
    if [ "$(xt_get MODE "/run/xray-tunnel.$n.conf")" = reverse ]; then echo reverse; else echo forward; fi
  elif [ -f "/run/xray-tunnel.$n.toml" ]; then echo reverse
  elif [ -f "/run/xray-tunnel.$n.json" ]; then echo forward; fi; }
# Iran, reverse: first local UDP port of port $2 in settings $1
xt_ubase() { local b k p i=0
  b=$(xt_get ULBASE "$1"); k=$(xt_get UDPK "$1")
  [[ $b =~ ^[0-9]+$ ]] && [[ $k =~ ^[0-9]+$ ]] || return 0
  for p in $(tr , ' ' <<< "$(xt_get PORTS "$1")"); do
    [ "$p" = "$2" ] && { echo $((b + i * k)); return 0; }; i=$((i + 1)); done; }
# Iran, reverse: ports on the tunnel in the new settings $2 whose UDP goes to other
# local ports than in the settings $1 the program runs with
xt_umoved() { local a=$1 b=$2 p x y out=""
  [ "$(xt_get ROLE "$b")" = iran ] && [ "$(xt_get MODE "$a")" = reverse ] && [ "$(xt_get MODE "$b")" = reverse ] || return 0
  for p in $(tr , ' ' <<< "$(xt_get ON "$b")"); do
    x=$(xt_ubase "$a" "$p"); y=$(xt_ubase "$b" "$p")
    [ -n "$x" ] && [ -n "$y" ] && [ "$x" != "$y" ] && out+=",$p"; done
  echo "${out#,}"; }
xt_start() { local n=$1 c k r q m="" go=""
  k=$(xt_get MODE "$XT_DIR/$n.conf"); [ "$k" = reverse ] || k=forward
  r=$(xt_run_kind "$n")
  # asked before anything is applied, so without yes the running tunnel stays as it was
  if [ -n "$r" ]; then
    [ "$r" != "$k" ] || [ ! -f "/run/xray-tunnel.$n.conf" ] || m=$(xt_umoved "/run/xray-tunnel.$n.conf" "$XT_DIR/$n.conf")
    if [ "$r" != "$k" ] || [ -n "$m" ]; then
      go=1; c=$(xt_conns "$n")
      if [ "$r" != "$k" ]; then
        q="Tunnel $n becomes a $k tunnel: its program restarts, which cuts its $c open connections. Type yes to go on (anything else changes nothing)"
      else
        q="UDP of ports $m moves to other local ports: tunnel $n restarts, which cuts its $c open connections, and their UDP works again once the foreign server has the new code. Type yes to go on (anything else changes nothing)"
      fi
      if [ "$c" -gt 0 ] && [ "$(ask "$q")" != yes ]; then
        echo "[i] cancelled: tunnel $n stays as it was"; return 1; fi
    fi
  fi
  # checks the settings with the program first; rejected ones are not saved
  /usr/local/sbin/xray-tunnel up "$n" || { echo "[!] could not apply tunnel $n"; return 1; }
  systemctl enable -q "xray-tunnel@$n" "xray-tunnel-keep@$n.timer"
  if ! systemctl -q is-active "xray-tunnel@$n"; then
    systemctl start "xray-tunnel@$n" || { journalctl -u "xray-tunnel@$n" -n 15 --no-pager; return 1; }
  elif ! /usr/local/sbin/xray-tunnel current "$n"; then
    if [ -n "$go" ]; then systemctl restart "xray-tunnel@$n"
    else
      c=$(xt_conns "$n")
      if [ "$c" -gt 0 ] && [ "$(ask "The new settings need a restart of tunnel $n, which cuts its $c open connections for a moment. Type yes to restart now")" != yes ]; then
        echo "[i] not restarted: the new settings apply at the next restart (systemctl restart xray-tunnel@$n)"
      else systemctl restart "xray-tunnel@$n"; fi
    fi
  fi
  systemctl start "xray-tunnel-keep@$n.timer"
}

# the settings, certificate and key of tunnel $1 are kept as .prev until xt_commit
# worked, and put back if it did not
xt_backup() { local n=$1 f
  # the timers leave the tunnel alone until xt_commit (the runtime's busy)
  : > "/run/xray-tunnel.$n.busy"; XT_BUSY+=" $n"
  for f in conf crt key ca.crt; do
    rm -f "$XT_DIR/$n.$f.prev"; [ -f "$XT_DIR/$n.$f" ] && cp -p "$XT_DIR/$n.$f" "$XT_DIR/$n.$f.prev"
  done; true; }
# writes the settings of tunnel $1 from stdin
xt_write_conf() { local c=$XT_DIR/$1.conf
  [ -f "$c.prev" ] || [ ! -f "$c" ] || cp -p "$c" "$c.prev"
  cat > "$c.tmp" && chmod 600 "$c.tmp" && mv -f "$c.tmp" "$c"; }
xt_commit() { local n=$1 c=$XT_DIR/$1.conf f
  if xt_start "$n"; then rm -f "$XT_DIR/$n".*.prev "/run/xray-tunnel.$n.busy"; return 0; fi
  if [ -f "$c.prev" ]; then
    for f in crt key ca.crt; do
      if [ -f "$XT_DIR/$n.$f.prev" ]; then mv -f "$XT_DIR/$n.$f.prev" "$XT_DIR/$n.$f"; else rm -f "$XT_DIR/$n.$f"; fi
    done
    mv -f "$c.prev" "$c"; /usr/local/sbin/xray-tunnel up "$n" >/dev/null 2>&1
    echo "[!] the old settings of tunnel $n are kept"
  fi
  rm -f "$XT_DIR/$n".*.prev "/run/xray-tunnel.$n.busy"
  return 1; }

# puts the encrypted tunnels' rules back above GRE's (after GRE re-added its own)
xt_reapply() { local n
  [ -x /usr/local/sbin/xray-tunnel ] || return 0
  for n in $(xt_confs); do /usr/local/sbin/xray-tunnel up "$n" >/dev/null 2>&1; done; }

# reads the code printed by the foreign server into P_* variables
xt_parse_code() { local code=${1//[[:space:]]/} txt k v l
  [[ $code == XT1-* ]] || return 1
  txt=$(printf '%s' "${code#XT1-}" | base64 -d 2>/dev/null) || return 1
  # the code ends with a line break: a code cut after its last value is not whole
  [ "$(printf '%s' "${code#XT1-}" | base64 -d 2>/dev/null | tail -c 1 | od -An -tx1 | tr -d ' \n')" = 0a ] || return 1
  P_FOREIGN=""; P_TPORT=""; P_UUID=""; P_WSPATH=""; P_SNI=""; P_PIN=""; P_PORTS=""; P_HPORT=""; P_DEST=""
  while IFS= read -r l; do
    k=${l%%=*}; v=${l#*=}
    case $k in
      FOREIGN_IP) valid_ip "$v" && P_FOREIGN=$v ;;
      TPORT) [[ $v =~ ^[0-9]{1,5}$ ]] && P_TPORT=$v ;;
      UUID) [[ $v =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] && P_UUID=$v ;;
      WSPATH) [[ $v =~ ^/[A-Za-z0-9._/-]*$ ]] && P_WSPATH=$v ;;
      SNI) [[ $v =~ ^[A-Za-z0-9.-]*$ ]] && P_SNI=$v ;;
      PIN) [[ $v =~ ^[0-9a-f]{64}$ ]] && P_PIN=$v ;;
      PORTS) P_PORTS=$(xt_ports "$v") || P_PORTS="" ;;
      HPORT) [[ $v =~ ^[0-9]{1,5}$ ]] && P_HPORT=$v ;;
      DEST) valid_ip "$v" && P_DEST=$v ;;
    esac
  done <<< "$txt"
  [ -n "$P_FOREIGN" ] && [ -n "$P_TPORT" ] && [ -n "$P_UUID" ] && [ -n "$P_WSPATH" ] && [ -n "$P_PIN" ] &&
    [ -n "$P_PORTS" ] && [ -n "$P_HPORT" ] && [ -n "$P_DEST" ]; }

# sets up the foreign side of encrypted tunnel $1 (Iran $2, this server $3, ports $4,
# tunnel port $5, name $6, services on address $7). Keys and certificate are made
# once and kept, so the Iran side keeps working when this runs again
xt_setup_foreign() {
  local n=$1 iran=$2 me=$3 ports=$4 tport=$5 sni=$6 dest=$7 c=$XT_DIR/$1.conf hport uuid wspath cn
  xt_install_files
  xt_bin || return 1
  xt_backup "$n"
  hport=$(xt_get HPORT "$c"); [ -n "$hport" ] || hport=$(xt_free_port 62001 "$ports,$tport")
  uuid=$(xt_get UUID "$c"); [ -n "$uuid" ] || uuid=$(cat /proc/sys/kernel/random/uuid)
  wspath=$(xt_get WSPATH "$c"); [ -n "$wspath" ] || wspath=/$(xt_rand 6)
  # Iran accepts only this certificate (the name in it does not matter)
  if [ ! -s "$XT_DIR/$n.crt" ] || [ ! -s "$XT_DIR/$n.key" ]; then
    cn=${sni:-tunnel-$n.local}
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -sha256 -days 3650 \
      -subj "/CN=$cn" -addext "subjectAltName=DNS:$cn" -keyout "$XT_DIR/$n.key.tmp" -out "$XT_DIR/$n.crt.tmp" >/dev/null 2>&1 ||
      { echo "[!] could not make the TLS certificate"; rm -f "$XT_DIR/$n".*.tmp; return 1; }
    chmod 600 "$XT_DIR/$n.key.tmp"
    mv -f "$XT_DIR/$n.key.tmp" "$XT_DIR/$n.key"; mv -f "$XT_DIR/$n.crt.tmp" "$XT_DIR/$n.crt"
  fi
  xt_write_conf "$n" <<CONF
ROLE=foreign
REMOTE_IP=$iran
PUBLIC_IP=$me
TPORT=$tport
UUID=$uuid
WSPATH=$wspath
SNI=$sni
PORTS=$ports
HPORT=$hport
DEST=$dest
CONF
  xt_commit "$n"
}

# the pairing code of foreign tunnel $1: everything the Iran side needs
xt_code() { local c=$XT_DIR/$1.conf pin
  pin=$(openssl x509 -in "$XT_DIR/$1.crt" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d : | tr A-F a-f)
  printf 'V=1\nFOREIGN_IP=%s\nTPORT=%s\nUUID=%s\nWSPATH=%s\nSNI=%s\nPIN=%s\nPORTS=%s\nHPORT=%s\nDEST=%s\n' \
    "$(xt_get PUBLIC_IP "$c")" "$(xt_get TPORT "$c")" "$(xt_get UUID "$c")" "$(xt_get WSPATH "$c")" "$(xt_get SNI "$c")" \
    "$pin" "$(xt_get PORTS "$c")" "$(xt_get HPORT "$c")" "$(xt_get DEST "$c")" | base64 -w0 | sed 's/^/XT1-/'; }

# local ports on the Iran server for ports $2 of tunnel $1 (never ports $3), into
# A_LPORTS ("443=61001,...") and A_LHPORT (the health port). A port keeps its local port and its current way
# (A_ON), so open connections keep working; they are never taken from the ports
# that GRE or other tunnels use
xt_alloc() {
  local n=$1 ports=$2 c=$XT_DIR/$1.conf o p lp used=${3:-} gp="" f o_lports o_on
  for o in $(xt_confs); do
    [ "$o" = "$n" ] && continue
    used+=",$(xt_get LPORTS "$XT_DIR/$o.conf" | sed -E 's/[0-9]+=//g'),$(xt_get LHPORT "$XT_DIR/$o.conf"),$(xt_get TPORT "$XT_DIR/$o.conf")"
    used+="$(rx_ublock "$XT_DIR/$o.conf")"
  done
  for f in /etc/gre-tunnel/*.conf; do p=$(xt_get PORTS "$f"); valid_ports "$p" && gp+="${gp:+,}$p"; done
  o_lports=$(xt_get LPORTS "$c"); o_on=$(xt_get ON "$c")
  A_LHPORT=$(xt_get LHPORT "$c")
  used+=",$(sed -E 's/[0-9]+=//g' <<< "$o_lports"),$A_LHPORT"
  A_LPORTS=""; A_ON=""
  for p in ${ports//,/ }; do
    lp=""
    for o in ${o_lports//,/ }; do [ "${o%%=*}" = "$p" ] && lp=${o#*=}; done
    if [ -z "$lp" ]; then
      lp=61001
      while :; do
        lp=$(xt_free_port "$lp" "$used,$ports")
        [ -n "$gp" ] && port_overlap "$lp" "$gp" >/dev/null || break
        lp=$((lp + 1))
      done
    fi
    used+=",$lp"; A_LPORTS+="${A_LPORTS:+,}$p=$lp"
    in_csv "$p" "$o_on" && A_ON+="${A_ON:+,}$p"
  done
  if [ -z "$A_LHPORT" ]; then
    A_LHPORT=61901
    while :; do
      A_LHPORT=$(xt_free_port "$A_LHPORT" "$used,$ports")
      [ -n "$gp" ] && port_overlap "$A_LHPORT" "$gp" >/dev/null || break
      A_LHPORT=$((A_LHPORT + 1))
    done
  fi
  used+=",$A_LHPORT"
  # reverse: the UDP of each port is spread over UDPK local ports (one block in the
  # order of the ports), so one busy work connection does not carry all of it
  A_ULBASE=""
  [ "${4:-}" = reverse ] || return 0
  if [ "$(xt_get MODE "$c")" = reverse ] && [ "$(xt_get PORTS "$c")" = "$ports" ] &&
    [ "$(xt_get UDPK "$c")" = "$RX_UDPK" ] && [[ $(xt_get ULBASE "$c") =~ ^[0-9]+$ ]]; then
    A_ULBASE=$(xt_get ULBASE "$c"); return 0; fi
  local len q b=61101 l ob
  # this tunnel's own block is not taken (its frps listens there): with a port added
  # at the end, the block keeps its start and the ports it had keep their UDP ports
  len=$(( $(tr , '\n' <<< "$ports" | grep -c .) * RX_UDPK ))
  l=$(xt_listening | grep -vxF -f <(tr , '\n' <<< "$(rx_ublock "$c")" | grep .))
  ob=$(xt_get ULBASE "$c")
  if [ "$(xt_get MODE "$c")" = reverse ] && [[ $ob =~ ^[0-9]+$ ]] && [ $((ob + len - 1)) -le 65535 ]; then
    q=$ob
    while [ "$q" -lt $((ob + len)) ]; do
      grep -qx "$q" <<< "$l" || in_csv "$q" "$used,$ports" || { [ -n "$gp" ] && port_overlap "$q" "$gp" >/dev/null; } && break
      q=$((q + 1))
    done
    [ "$q" = $((ob + len)) ] && { A_ULBASE=$ob; return 0; }
  fi
  while [ $((b + len - 1)) -le 65535 ]; do
    q=$b
    while [ "$q" -lt $((b + len)) ]; do
      grep -qx "$q" <<< "$l" || in_csv "$q" "$used,$ports" || { [ -n "$gp" ] && port_overlap "$q" "$gp" >/dev/null; } && break
      q=$((q + 1))
    done
    [ "$q" = $((b + len)) ] && { A_ULBASE=$b; return 0; }
    b=$((q + 1))
  done
  echo "[!] no free block of $len local ports for UDP"; return 1; }
# the UDP block of the reverse tunnel with settings file $1, as ,port,port,...
rx_ublock() { local b k p
  [ "$(xt_get MODE "$1")" = reverse ] || return 0
  b=$(xt_get ULBASE "$1"); k=$(xt_get UDPK "$1"); p=$(xt_get PORTS "$1")
  [[ $b =~ ^[0-9]+$ ]] && [[ $k =~ ^[0-9]+$ ]] && [ -n "$p" ] || return 0
  seq "$b" $((b + $(tr , '\n' <<< "$p" | grep -c .) * k - 1)) | sed 's/^/,/' | tr -d '\n'; }

# sets up the Iran side of encrypted tunnel $1 to foreign server $2 from the pasted
# code (P_*)
xt_setup_iran() {
  local n=$1 foreign=$2 c=$XT_DIR/$1.conf
  xt_install_files iran
  xt_bin || return 1
  xt_alloc "$n" "$P_PORTS"
  xt_backup "$n"
  # (a reverse tunnel's certificate is removed when the forward program starts)
  xt_write_conf "$n" <<CONF
ROLE=iran
REMOTE_IP=$foreign
TPORT=$P_TPORT
UUID=$P_UUID
WSPATH=$P_WSPATH
SNI=$P_SNI
PIN=$P_PIN
PORTS=$P_PORTS
HPORT=$P_HPORT
DEST=$P_DEST
LPORTS=$A_LPORTS
LHPORT=$A_LHPORT
ON=$A_ON
CONF
  xt_commit "$n"
}

# ---------- reverse kind (frp): the foreign server connects to the Iran server ----------
RX_FRP=0.71.0
RX_UDPK=8
# sha256 of the official release files (github.com/fatedier/frp/releases)
rx_sum() { case $1 in
  amd64) echo 84f27e39f11169f7adcef8e8b70c9329de17747b1f14dad9fb95eef5682ea716 ;;
  arm64) echo f33c293c275d8fc68c654b6fba8f10b2551d6463d09a9fc9cffb7227eae82266 ;;
  *) return 1 ;; esac; }
rx_have() { [ -x "$XT_LIB/frps" ] && [ -x "$XT_LIB/frpc" ] && [ "$("$XT_LIB/frpc" -v 2>/dev/null)" = "$RX_FRP" ]; }
# frps and frpc from the official frp release, checked against the known sha256; a
# copy of the release file in /root is used when GitHub cannot be reached
rx_bin() { local arch f sum tmp url o
  rx_have && return 0
  case $(uname -m) in x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;;
    *) echo "[!] the reverse tunnel supports x86_64 and arm64 servers only (this one: $(uname -m))"; return 1 ;; esac
  sum=$(rx_sum "$arch"); f=frp_${RX_FRP}_linux_$arch.tar.gz
  url=https://github.com/fatedier/frp/releases/download/v$RX_FRP/$f
  for o in tar sha256sum; do command -v $o >/dev/null || { echo "[!] missing: $o"; return 1; }; done
  tmp=$(mktemp -d) || return 1
  if [ -s "/root/$f" ]; then cp "/root/$f" "$tmp/$f"
  else
    echo "[*] downloading frp $RX_FRP ($arch) from GitHub"
    if command -v curl >/dev/null; then curl -fsSL --connect-timeout 15 --retry 2 --max-time 120 -o "$tmp/$f" "$url"
    else wget -q --tries=2 --timeout=30 -O "$tmp/$f" "$url"; fi
  fi
  if [ ! -s "$tmp/$f" ] || [ "$(sha256sum "$tmp/$f" | awk '{ print $1 }')" != "$sum" ]; then
    rm -rf "$tmp"
    echo "[!] could not get frp $RX_FRP (no download, or the file is not the official one). Download"
    echo "    $url on another computer and copy it to /root/$f on this server, then run this again."
    return 1
  fi
  tar -xzf "$tmp/$f" -C "$tmp" "frp_${RX_FRP}_linux_$arch/frps" "frp_${RX_FRP}_linux_$arch/frpc" || { rm -rf "$tmp"; return 1; }
  mkdir -p "$XT_LIB"
  for o in frps frpc; do
    install -m 755 "$tmp/frp_${RX_FRP}_linux_$arch/$o" "$XT_LIB/$o.tmp" && mv -f "$XT_LIB/$o.tmp" "$XT_LIB/$o" || { rm -rf "$tmp"; return 1; }
  done
  rm -rf "$tmp"
  rx_have || { echo "[!] frp $RX_FRP does not run on this server"; return 1; }
  echo "[*] frp $RX_FRP installed in $XT_LIB"; }

# sets up the Iran side of reverse tunnel $1: the foreign server $2 connects to this
# server ($3) on port $5 and brings ports $4; TLS name $6. The certificate, token and
# password are made once and kept, so the foreign side keeps working when this runs
# again (a new foreign IP needs nothing there)
# makes the key $1.key and self-signed certificate $1.crt for name $2 (DNS:... or
# IP:...); valid from two days ago, so a foreign server whose clock is behind accepts it
rx_cert() { local o=$1 san=$2 d
  d=$(mktemp -d) || return 1
  openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -sha256 -subj "/CN=${san#*:}" \
    -keyout "$o.key.tmp" -out "$d/csr" >/dev/null 2>&1 || { rm -rf "$d" "$o.key.tmp"; return 1; }
  : > "$d/index"; echo 01 > "$d/serial"
  printf '[ca]\ndefault_ca=d\n[d]\ndir=%s\ndatabase=$dir/index\nnew_certs_dir=$dir\nserial=$dir/serial\ndefault_md=sha256\npolicy=p\nunique_subject=no\n[p]\ncommonName=supplied\n[e]\nsubjectAltName=%s\nbasicConstraints=critical,CA:TRUE\nsubjectKeyIdentifier=hash\n' "$d" "$san" > "$d/cnf"
  openssl ca -batch -notext -selfsign -config "$d/cnf" -keyfile "$o.key.tmp" -in "$d/csr" -extensions e \
    -startdate "$(date -u -d '-2 days' +%Y%m%d%H%M%SZ)" -days 3650 -out "$o.crt.tmp" >/dev/null 2>&1 ||
    openssl req -x509 -key "$o.key.tmp" -in "$d/csr" -days 3650 -sha256 -addext "subjectAltName=$san" \
      -out "$o.crt.tmp" >/dev/null 2>&1 || { rm -rf "$d" "$o.key.tmp" "$o.crt.tmp"; return 1; }
  rm -rf "$d"
  chmod 600 "$o.key.tmp"; mv -f "$o.key.tmp" "$o.key"; mv -f "$o.crt.tmp" "$o.crt"; }
rx_setup_iran() {
  local n=$1 foreign=$2 me=$3 ports=$4 tport=$5 sni=$6 c=$XT_DIR/$1.conf token="" hpass="" chk
  xt_install_files iran
  rx_bin || return 1
  xt_alloc "$n" "$ports" "$tport" reverse || return 1
  xt_backup "$n"
  if [ "$(xt_get MODE "$c")" = reverse ]; then token=$(xt_get TOKEN "$c"); hpass=$(xt_get HPASS "$c"); fi
  [ -n "$token" ] || token=$(xt_rand 24)
  [ -n "$hpass" ] || hpass=$(xt_rand 12)
  # the foreign server accepts only this certificate, for this name (without a name:
  # for the Iran IP, and no name is sent in the TLS handshake)
  if [ -n "$sni" ]; then chk=(-checkhost "$sni"); else chk=(-checkip "$me"); fi
  if [ "$(xt_get MODE "$c")" != reverse ] || [ ! -s "$XT_DIR/$n.crt" ] || [ ! -s "$XT_DIR/$n.key" ] ||
    ! openssl x509 -in "$XT_DIR/$n.crt" -noout "${chk[@]}" 2>/dev/null | grep -q 'does match'; then
    rx_cert "$XT_DIR/$n" "$([ -n "$sni" ] && echo "DNS:$sni" || echo "IP:$me")" ||
      { echo "[!] could not make the TLS certificate"; rm -f "$XT_DIR/$n".*.prev; return 1; }
  fi
  xt_write_conf "$n" <<CONF
ROLE=iran
MODE=reverse
REMOTE_IP=$foreign
PUBLIC_IP=$me
TPORT=$tport
TOKEN=$token
HPASS=$hpass
SNI=$sni
PORTS=$ports
LPORTS=$A_LPORTS
LHPORT=$A_LHPORT
ULBASE=$A_ULBASE
UDPK=$RX_UDPK
ON=$A_ON
CONF
  xt_commit "$n"
}

# the pairing code of reverse tunnel $1: everything the foreign side needs. On Iran
# from its settings; on the foreign server ($2 = saved) the same code from the saved
# settings. The END line shows that the code was copied to its end
rx_code() { local c=$XT_DIR/$1.conf ip crt=$XT_DIR/$1.crt
  ip=$(xt_get PUBLIC_IP "$c")
  [ "${2:-}" = saved ] && { ip=$(xt_get REMOTE_IP "$c"); crt=$XT_DIR/$1.ca.crt; }
  printf 'V=1\nIRAN_IP=%s\nTPORT=%s\nTOKEN=%s\nHPASS=%s\nSNI=%s\nCERT=%s\nPORTS=%s\nLPORTS=%s\nLHPORT=%s\nULBASE=%s\nUDPK=%s\nEND=1\n' \
    "$ip" "$(xt_get TPORT "$c")" "$(xt_get TOKEN "$c")" "$(xt_get HPASS "$c")" "$(xt_get SNI "$c")" \
    "$(openssl x509 -in "$crt" -outform DER | base64 -w0)" \
    "$(xt_get PORTS "$c")" "$(xt_get LPORTS "$c")" "$(xt_get LHPORT "$c")" "$(xt_get ULBASE "$c")" "$(xt_get UDPK "$c")" |
    base64 -w0 | sed 's/^/RX1-/'; }

# reads the code printed by the Iran server into R_* variables
# a port number 1-65535
rx_port() { [[ $1 =~ ^[0-9]{1,5}$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
rx_parse_code() { local code=${1//[[:space:]]/} txt k v m p l e=""
  [[ $code == RX1-* ]] || return 1
  txt=$(printf '%s' "${code#RX1-}" | base64 -d 2>/dev/null) || return 1
  R_IRAN=""; R_TPORT=""; R_TOKEN=""; R_HPASS=""; R_SNI=""; R_CERT=""; R_PORTS=""; R_LPORTS=""; R_LHPORT=""
  R_ULBASE=""; R_UDPK=""
  while IFS= read -r l; do
    k=${l%%=*}; v=${l#*=}
    case $k in
      END) e=$v ;;
      IRAN_IP) valid_ip "$v" && R_IRAN=$v ;;
      TPORT) rx_port "$v" && R_TPORT=$v ;;
      TOKEN) [[ $v =~ ^[0-9a-f]{48}$ ]] && R_TOKEN=$v ;;
      HPASS) [[ $v =~ ^[0-9a-f]{24}$ ]] && R_HPASS=$v ;;
      SNI) [[ $v =~ ^[A-Za-z0-9.-]*$ ]] && ! [[ $v =~ ^[0-9.]+$ ]] && R_SNI=$v ;;
      CERT) [[ $v =~ ^[A-Za-z0-9+/]+=*$ ]] && R_CERT=$v ;;
      PORTS) R_PORTS=$(xt_ports "$v") || R_PORTS="" ;;
      LPORTS) [[ $v =~ ^[0-9]{1,5}=[0-9]{1,5}(,[0-9]{1,5}=[0-9]{1,5})*$ ]] && R_LPORTS=$v ;;
      LHPORT) rx_port "$v" && R_LHPORT=$v ;;
      ULBASE) rx_port "$v" && R_ULBASE=$v ;;
      UDPK) [[ $v =~ ^[0-9]{1,2}$ ]] && [ "$v" -ge 1 ] && [ "$v" -le 16 ] && R_UDPK=$v ;;
    esac
  done <<< "$txt"
  [ "$e" = 1 ] && [ -n "$R_IRAN" ] && [ -n "$R_TPORT" ] && [ -n "$R_TOKEN" ] && [ -n "$R_HPASS" ] && [ -n "$R_CERT" ] &&
    [ -n "$R_PORTS" ] && [ -n "$R_LPORTS" ] && [ -n "$R_LHPORT" ] && [ -n "$R_ULBASE" ] && [ -n "$R_UDPK" ] || return 1
  [ $((R_ULBASE + $(tr , '\n' <<< "$R_PORTS" | grep -c .) * R_UDPK - 1)) -le 65535 ] || return 1
  # every port has its local port (1-65535) on the Iran server
  for p in ${R_PORTS//,/ }; do
    m=0; for k in ${R_LPORTS//,/ }; do [ "${k%%=*}" = "$p" ] && rx_port "${k#*=}" && m=1; done
    [ "$m" = 1 ] || return 1
  done; }

# sets up the foreign side of reverse tunnel $1 from the pasted code (R_*): this
# server ($2) connects to the Iran server and brings its services on address $3
rx_setup_foreign() {
  local n=$1 me=$2 dest=$3 c=$XT_DIR/$1.conf ap used="" o
  # frpc's status page on this server's loopback (shows whether it is logged in)
  ap=$(xt_get APORT "$c")
  if ! [[ $ap =~ ^[0-9]+$ ]]; then
    for o in $(xt_confs); do [ "$o" = "$n" ] || used+=",$(xt_get APORT "$XT_DIR/$o.conf"),$(xt_get HPORT "$XT_DIR/$o.conf")"; done
    ap=$(xt_free_port 62101 "$R_PORTS$used")
  fi
  xt_install_files
  rx_bin || return 1
  xt_backup "$n"
  printf '%s' "$R_CERT" | base64 -d 2>/dev/null | openssl x509 -inform DER -out "$XT_DIR/$n.ca.crt.tmp" 2>/dev/null ||
    { echo "[!] the certificate in the code is damaged (copy the whole code again)"; rm -f "$XT_DIR/$n".*.tmp "$XT_DIR/$n".*.prev; return 1; }
  mv -f "$XT_DIR/$n.ca.crt.tmp" "$XT_DIR/$n.ca.crt"
  # (the certificate and key of a forward tunnel are removed when the reverse program starts)
  xt_write_conf "$n" <<CONF
ROLE=foreign
MODE=reverse
REMOTE_IP=$R_IRAN
PUBLIC_IP=$me
TPORT=$R_TPORT
TOKEN=$R_TOKEN
HPASS=$R_HPASS
SNI=$R_SNI
PORTS=$R_PORTS
LPORTS=$R_LPORTS
LHPORT=$R_LHPORT
ULBASE=$R_ULBASE
UDPK=$R_UDPK
DEST=$dest
POOL=50
APORT=$ap
CONF
  xt_commit "$n"
}

# stops and deletes encrypted tunnel $1; the last one also takes the program files
xt_drop() { local n=$1
  systemctl stop "xray-tunnel-keep@$n.timer" "xray-tunnel-keep@$n.service" 2>/dev/null
  systemctl stop "xray-tunnel@$n.service" 2>/dev/null
  systemctl disable "xray-tunnel-keep@$n.timer" "xray-tunnel@$n.service" 2>/dev/null
  if [ -f "$XT_DIR/$n.conf" ] && [ -x /usr/local/sbin/xray-tunnel ]; then
    /usr/local/sbin/xray-tunnel down "$n" >/dev/null 2>&1; fi
  rm -f "$XT_DIR/$n".* "/run/xray-tunnel.$n" "/run/xray-tunnel.$n".*
  [ -n "$(xt_confs)" ] || xt_purge; }
xt_purge() {
  rm -f /usr/local/sbin/xray-tunnel /etc/systemd/system/xray-tunnel@.service \
    /etc/systemd/system/xray-tunnel-keep@.service /etc/systemd/system/xray-tunnel-keep@.timer \
    /etc/systemd/system/*.wants/xray-tunnel@*.service /etc/systemd/system/*.wants/xray-tunnel-keep@*.timer
  rm -rf "$XT_DIR" "$XT_LIB"
  systemctl daemon-reload
  systemctl reset-failed 'xray-tunnel@*' 'xray-tunnel-keep@*' 2>/dev/null
}

# new runtime, same settings; xray is restarted only if its settings changed (asked)
xt_update() { local n rc=0
  [ -n "$(xt_confs)" ] || return 0
  xt_install_files
  for n in $(xt_confs); do
    if [ "$(xt_get MODE "$XT_DIR/$n.conf")" = reverse ]; then rx_bin || { rc=1; continue; }
    else xt_bin || { rc=1; continue; }; fi
    xt_start "$n" || rc=1
  done
  return $rc
}


# ---------- one menu for both: every tunnel N is a GRE tunnel and an encrypted tunnel ----------
# Both are installed together (option 1); on the Iran server each port of a tunnel
# uses one of them for new connections, switched only by hand (option 7).

# every tunnel number on this server
tunnel_nums() { local f
  for f in /etc/gre-tunnel/*.conf "$XT_DIR"/*.conf; do [ -e "$f" ] && basename "$f" .conf; done | grep -E '^[1-9]$' | sort -un; }
role_of() { local r; r=$(xt_get ROLE "/etc/gre-tunnel/$1.conf"); echo "${r:-$(xt_get ROLE "$XT_DIR/$1.conf")}"; }
xt_have_xray() { { [ -x "$XT_BIN" ] && "$XT_BIN" version >/dev/null 2>&1; } || xt_find_xray >/dev/null; }
sort_ports() { tr , '\n' <<< "$1" | sort -t: -k1,1n | paste -sd, -; }
src_ip() { ip -4 route get "$1" 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit } }'; }

# reads a pasted code ($1 = question, $2 = its parser). A terminal can break the long
# line: the lines up to the END line, an empty line, or a line that completes the code
# are joined. Anything else on the first line (Enter, a word) comes back as it is
ask_code() { local l acc="" m=0 b
  read -r -p "$1: " l || { echo; return; }
  l=${l//[[:space:]]/}
  case $l in RX1-*|XT1-*|-----*) ;; *) echo "$l"; return ;; esac
  while :; do
    # a messenger or console can join the lines: the markers may share a line with the code
    b=0; case $l in -----BEGIN*) m=1; b=1; l=${l#-----BEGINTUNNELCODE-----} ;; esac
    if [[ $l == *-----END* ]]; then acc+=${l%%-----END*}; break; fi
    case $l in
      -----*) m=1 ;;
      # an empty line ends it (after only the BEGIN line: an invalid code, not Enter);
      # the BEGIN line itself is not one
      "") if [ "$b" = 0 ] && { [ -n "$acc" ] || [ "$m" = 1 ]; }; then
            # on a terminal, a paste with CR LF line ends has an empty line after each
            # line: the rest of the paste follows at once, an Enter typed after it does not
            if [ -t 0 ] && IFS= read -r -t 0.3 l; then l=${l//[[:space:]]/}; continue; fi
            break
          fi ;;
      *) acc+=$l ;;
    esac
    # with the marker lines: up to the END line, so none of them is left for the next question
    [ "$m" = 0 ] && [ -n "$acc" ] && "$2" "$acc" >/dev/null 2>&1 && break
    IFS= read -r l || break
    l=${l//[[:space:]]/}
  done
  # on a terminal, what is left of the paste (empty lines, the END line) does not answer
  # the next question
  if [ -t 0 ]; then
    while IFS= read -r -t 0.3 l; do l=${l//[[:space:]]/}; case $l in ""|-----END*) ;; *) break ;; esac; done
  fi
  echo "${acc:--}"; }
# prints the code of reverse tunnel $1 in short lines between two marker lines
print_rx_code() {
  echo "-----BEGIN TUNNEL CODE-----"
  printf '%s\n' "$(rx_code "$@")" | fold -w 76
  echo "-----END TUNNEL CODE-----"; }

# asks which tunnel, when there is more than one; $1 = iran: only ones whose ports switch here
pick_tunnel() { local l n
  l=$(tunnel_nums)
  if [ "${1:-}" = iran ]; then
    l=$(for n in $l; do [ "$(xt_get ROLE "$XT_DIR/$n.conf")" = iran ] && echo "$n"; done)
    [ -n "$l" ] || { echo "no encrypted tunnel on this Iran server: ports are switched on the Iran server, after option 1" >&2; return 1; }
  fi
  [ -n "$l" ] || { echo "no tunnels on this server (option 1 installs one)" >&2; return 1; }
  if [ "$(wc -l <<< "$l")" = 1 ]; then echo "$l"; return 0; fi
  n=$(ask "Tunnel number ($(paste -sd' ' <<< "$l"))" "$(head -1 <<< "$l")")
  grep -qx "$n" <<< "$l" || { echo "no tunnel $n" >&2; return 1; }
  echo "$n"; }

# does GRE tunnel $1 forward port $2 on this Iran server right now
gre_carries() { local g=/etc/gre-tunnel/$1.conf p
  [ "$(xt_get ROLE "$g")" = iran ] && systemctl -q is-active "gre-tunnel@$1" || return 1
  p=$(xt_get PORTS "$g"); [ "$p" = all ] || port_overlap "$2" "$p" >/dev/null; }

# which way new connections of each port of tunnel $1 take (Iran)
show_paths() { local n=$1 g=/etc/gre-tunnel/$1.conf c=$XT_DIR/$1.conf p on gp
  gp=$(xt_get PORTS "$g"); on=$(xt_get ON "$c")
  for p in $(tr , '\n' <<< "$(xt_get PORTS "$c"),$gp" | grep -E '^[0-9]' | awk '!s[$0]++'); do
    if in_csv "$p" "$on"; then echo "  port $p: encrypted tunnel$([ "$(xt_get MODE "$c")" = reverse ] && echo " (reverse)")"
    elif gre_carries "$n" "$p"; then echo "  port $p: GRE"
    elif [ -n "$gp" ] && port_overlap "$p" "$gp" >/dev/null; then echo "  port $p: GRE (but GRE tunnel $n is not running)"
    else echo "  port $p: not forwarded (not in GRE tunnel $n)"; fi
  done
  [ "$gp" != all ] || echo "  every other port except SSH: GRE"; }

# moves ports $3 (comma separated, or all) of tunnel $1 to $2 (tls or gre); only
# new connections change their way, open ones finish on the way they started
switch_ports() { local n=$1 to=$2 list=$3 c=$XT_DIR/$1.conf p rc=0
  [ "$(xt_get ROLE "$c")" = iran ] || { echo "tunnel $n has no encrypted part on this Iran server (ports are switched on the Iran server)"; return 1; }
  [ "$list" = all ] && list=$(xt_get PORTS "$c")
  for p in ${list//,/ }; do
    in_csv "$p" "$(xt_get PORTS "$c")" || { echo "port $p is not one of tunnel $n's ports ($(xt_get PORTS "$c"))"; rc=1; continue; }
    if [ "$to" = tls ]; then
      if in_csv "$p" "$(xt_get ON "$c")"; then echo "port $p: already on the encrypted tunnel"
      else /usr/local/sbin/xray-tunnel on "$n" "$p" || rc=1; fi
    elif ! in_csv "$p" "$(xt_get ON "$c")"; then echo "port $p: already on GRE"
    # without GRE its users would not be forwarded at all
    elif ! gre_carries "$n" "$p"; then
      echo "[!!] GRE tunnel $n is not running or does not forward port $p; port $p stays on the encrypted tunnel"; rc=1
    else /usr/local/sbin/xray-tunnel off "$n" "$p" || rc=1; fi
  done
  return $rc; }

# tunnel $1 between this server ($2) and $3: not another tunnel number for the same
# two servers, and moving tunnel $1 to another server is asked first
check_ends() { local n=$1 lip=$2 rip=$3 f o
  for f in /etc/gre-tunnel/*.conf; do
    [ -e "$f" ] && [ "$f" != "/etc/gre-tunnel/$n.conf" ] || continue
    if [ "$(xt_get LOCAL_IP "$f")" = "$lip" ] && [ "$(xt_get REMOTE_IP "$f")" = "$rip" ]; then
      echo "tunnel $(basename "$f" .conf) already connects this server and $rip: use tunnel number $(basename "$f" .conf)"; return 1; fi
  done
  o=$(xt_get REMOTE_IP "/etc/gre-tunnel/$n.conf"); [ -n "$o" ] || o=$(xt_get REMOTE_IP "$XT_DIR/$n.conf")
  if [ -n "$o" ] && [ "$o" != "$rip" ]; then
    echo "[!!] tunnel $n now connects to $o; this makes it connect to $rip instead. That is right if the"
    echo "     other server's IP changed. For another server, use a free tunnel number instead."
    [ "$(ask "Type yes to connect tunnel $n to $rip")" = yes ] || { echo "cancelled, nothing was changed"; return 1; }
  fi; }

# does the GRE device of tunnel $1 use this server's IP $2 and the other server's IP $3
# (the settings file can be edited by hand without a restart); no GRE device: nothing to compare
gre_live_same() { local s
  s=$(ip tunnel show "vgre$1" 2>/dev/null)
  [[ $s == *" remote "* ]] || return 0
  awk -v r="remote $3 " -v l="local $2 " 'index($0" ", r) && index($0" ", l) { f = 1 } END { exit !f }' <<< "$s"; }
# makes GRE tunnel $1 ($2 = iran or foreign, this server's IP $3, the other server $4,
# ports $5). Same settings: applied in place, nobody is disconnected. Other settings:
# the tunnel restarts, which cuts the connections that use GRE for a few seconds
gre_apply() { local n=$1 role=$2 lip=$3 rip=$4 ports=$5 c=/etc/gre-tunnel/$1.conf ssh mtu op old p gone=""
  ssh=$(ssh_ports); ssh=${ssh:-22}
  op=$(xt_get PORTS "$c"); mtu=$(xt_get MTU "$c"); mtu=${mtu:-1420}
  # the same ports in another order are the same settings
  [ -n "$op" ] && [ "$(sort_ports "$op")" = "$(sort_ports "$ports")" ] && ports=$op
  save_orig_sysctl
  if [ -f "$c" ] && [ "$(xt_get ROLE "$c")" = "$role" ] && [ "$(xt_get LOCAL_IP "$c")" = "$lip" ] &&
    [ "$(xt_get REMOTE_IP "$c")" = "$rip" ] && [ "$op" = "$ports" ] &&
    { [ "$ports" != all ] || [ "$(xt_get SSH_PORTS "$c")" = "$ssh" ]; } && systemctl -q is-active "gre-tunnel@$n" &&
    gre_live_same "$n" "$lip" "$rip"; then
    install_files
    /usr/local/sbin/gre-tunnel up "$n" >/dev/null || { echo "[!] GRE tunnel $n: could not apply its rules"; return 1; }
    systemctl enable -q "gre-tunnel@$n" "gre-watchdog@$n.timer"; systemctl start "gre-watchdog@$n.timer"
    echo "[ok] GRE tunnel $n: settings unchanged, nobody was disconnected"
    return 0
  fi
  # ports GRE forwards now and would not forward any more
  if [ "$op" = all ] && [ "$ports" != all ]; then gone="every port except $ports"
  else for p in ${op//,/ }; do port_overlap "$p" "$ports" >/dev/null || gone+="${gone:+,}$p"; done; fi
  [ -z "$gone" ] || echo "[!!] GRE tunnel $n then no longer forwards ports $gone: their users are not forwarded at all."
  if systemctl -q is-active "gre-tunnel@$n"; then
    echo "The GRE settings of tunnel $n change, so GRE tunnel $n restarts: connections that use GRE"
    echo "are cut for a few seconds (ports on the encrypted tunnel are not affected)."
    [ "$(ask "Type yes to continue")" = yes ] || { echo "cancelled, nothing was changed"; return 1; }
  fi
  old=$(cat "$c" 2>/dev/null)
  # stop with the old runtime first, so it removes exactly the rules it added
  systemctl stop "gre-tunnel@$n" 2>/dev/null
  remove_old_vatan
  install_files
  cat > "$c" <<CONF
ROLE=$role
LOCAL_IP=$lip
REMOTE_IP=$rip
PORTS=$ports
SSH_PORTS=$ssh
MTU=$mtu
CONF
  if ! systemctl enable --now "gre-tunnel@$n" "gre-watchdog@$n.timer"; then
    echo "[!] GRE tunnel $n failed to start:"; journalctl -u "gre-tunnel@$n" -n 15 --no-pager
    # not left retrying: a new tunnel is taken away again, a changed one gets its old settings back
    systemctl stop "gre-tunnel@$n" 2>/dev/null
    if [ -z "$old" ]; then
      systemctl disable -q "gre-tunnel@$n" "gre-watchdog@$n.timer" 2>/dev/null; systemctl stop "gre-watchdog@$n.timer" 2>/dev/null
      rm -f "$c"
    else
      printf '%s\n' "$old" > "$c"
      systemctl start "gre-tunnel@$n" && echo "[*] GRE tunnel $n runs again with its old settings"; xt_reapply
    fi
    return 1
  fi
  xt_reapply
  echo "[ok] GRE tunnel $n: $lip <-> $rip, ports $ports"
}

# is $1 an address of this server
is_local_ip() { ip -o -4 addr show 2>/dev/null | awk '{ sub(/\/.*/, "", $4); print $4 }' | grep -qxF "$1"; }
is_private_ip() { [[ $1 =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.) ]]; }
# this server's IP towards $1: the saved one ($2) while it is still on this server
# (or the server is behind NAT), else the one the kernel uses now (the IP changed)
my_ip() { local s; s=$(src_ip "$1")
  if [ -n "${2:-}" ] && { is_local_ip "$2" || [ -z "$s" ] || is_private_ip "$s"; }; then echo "$2"; else echo "${s:-${2:-}}"; fi; }

# ports that GRE tunnels of this Iran server forward (single ports and ranges), not
# counting tunnel $1 (its GRE ports are about to be set)
gre_iran_ports() { local f p out=""
  for f in /etc/gre-tunnel/*.conf; do
    [ -e "$f" ] && [ "$(xt_get ROLE "$f")" = iran ] && [ "$f" != "/etc/gre-tunnel/${1:-}.conf" ] || continue
    p=$(xt_get PORTS "$f"); out+="${out:+,}$p"; done
  echo "$out"; }
# can reverse tunnel $1 on this Iran server listen on port $2 (its service ports $3)
# ports x-ui has on this server, also inbounds that are switched off (they would not
# start when frps holds their port); nothing without sqlite3
xui_ports() { command -v sqlite3 >/dev/null && [ -f /etc/x-ui/x-ui.db ] || return 0
  sqlite3 -readonly /etc/x-ui/x-ui.db "select port from inbounds; select value from settings where key in ('webPort','subPort');" 2>/dev/null |
    grep -E '^[0-9]+$' | paste -sd, -; }
rx_port_ok() { local n=$1 t=$2 ports=$3 o g ssh
  [[ $t =~ ^[0-9]{1,5}$ ]] && [ "$t" -ge 1 ] && [ "$t" -le 65535 ] || { echo "invalid port"; return 1; }
  in_csv "$t" "$ports" && { echo "port $t is one of the ports sent to the foreign server; choose another"; return 1; }
  ssh=$(ssh_ports)
  port_overlap "$t" "${ssh:-22}" >/dev/null && { echo "port $t is SSH on this server; choose another"; return 1; }
  g=$(gre_iran_ports "$n")
  [ -n "$g" ] && port_overlap "$t" "$g" >/dev/null && { echo "GRE sends port $t to a foreign server; choose another"; return 1; }
  for o in $(xt_confs); do
    [ "$o" = "$n" ] && continue
    in_csv "$t" "$(xt_get TPORT "$XT_DIR/$o.conf"),$(xt_get LHPORT "$XT_DIR/$o.conf"),$(xt_get LPORTS "$XT_DIR/$o.conf" | sed -E 's/[0-9]+=//g')$(rx_ublock "$XT_DIR/$o.conf")" &&
      { echo "port $t is used by encrypted tunnel $o; choose another"; return 1; }
  done
  in_csv "$t" "$(xt_get LHPORT "$XT_DIR/$n.conf"),$(xt_get LPORTS "$XT_DIR/$n.conf" | sed -E 's/[0-9]+=//g')$(rx_ublock "$XT_DIR/$n.conf")" &&
    { echo "port $t is a local port of tunnel $n; choose another"; return 1; }
  in_csv "$t" "$(xui_ports)" && { echo "port $t is an x-ui port on this server (an inbound, also one that is off, or the panel); choose another"; return 1; }
  if xt_listening | grep -qx "$t" && ! { [ "$(xt_get MODE "$XT_DIR/$n.conf")" = reverse ] && [ "$(xt_get TPORT "$XT_DIR/$n.conf")" = "$t" ]; }; then
    echo "port $t is already used on this server; choose another"; return 1; fi; }

install_foreign() {
  local n=$1 g=/etc/gre-tunnel/$1.conf c=$XT_DIR/$1.conf xr=1 iran me p ports tport="" sni="" dest="" o code bad
  local o_tport o_ports o_me o_dest o_mode had=0
  [ -f "$c" ] && had=1
  o_tport=$(xt_get TPORT "$c"); o_ports=$(xt_get PORTS "$c"); o_me=$(xt_get PUBLIC_IP "$c"); o_dest=$(xt_get DEST "$c")
  o_mode=$(xt_get MODE "$c"); o_mode=${o_mode:-forward}
  if [ "$o_mode" = reverse ]; then
    echo "Tunnel $n is a reverse tunnel (this server connects to Iran). Paste a new code from option 1"
    echo "on the IRAN server (all lines, BEGIN to END), press Enter to keep the saved one, or type"
    echo "forward to make it a forward tunnel (Iran connects here)."
    code=$(ask_code "Code, Enter, or forward" rx_parse_code)
    if [ -z "$code" ]; then code=$(rx_code "$n" saved) || { echo "the saved settings of tunnel $n are damaged: paste the code from the Iran server"; exit 1; }
    elif [ "$code" = forward ]; then
      xt_have_xray || { echo "a forward tunnel needs xray (x-ui) on this server; nothing was changed"; exit 1; }
      [ "$(ask "Type yes to turn reverse tunnel $n into a forward tunnel (it stops working until Iran gets the new code)")" = yes ] ||
        { echo "cancelled, nothing was changed"; exit 1; }
      code=""
    fi
  else
    echo "Reverse tunnel (this server connects to Iran): paste the code printed by option 1 on the"
    echo "IRAN server (all lines, BEGIN to END). Forward tunnel (Iran connects here): press Enter."
    code=$(ask_code "Code, or Enter for forward" rx_parse_code)
  fi
  if [ -n "$code" ]; then
    rx_parse_code "$code" || { echo "invalid code (copy all its lines, from BEGIN to END)"; exit 1; }
    for o in openssl ss base64; do command -v $o >/dev/null || { echo "missing: $o (apt install openssl iproute2 coreutils)"; exit 1; }; done
    # the program first: without it nothing below is changed
    rx_bin || exit 1
    iran=$R_IRAN; ports=$R_PORTS
    echo "Iran server $iran, ports $ports (from the code)"
    o=$(ssh_ports); bad=$(port_overlap "$ports" "${o:-22}") &&
      { echo "port $bad is SSH on this server; not sending it (choose other ports on the Iran server)"; exit 1; }
    me=$o_me; [ -n "$me" ] || me=$(xt_get LOCAL_IP "$g")
    me=$(ask "This server's IP (the one it connects to Iran from)" "$(my_ip "$iran" "$me")"); valid_ip "$me" || { echo "invalid IP"; exit 1; }
    dest=$(xt_dest "$ports") || exit 1
    check_ends "$n" "$me" "$iran" || exit 1
    gre_apply "$n" foreign "$me" "$iran" "$ports" || exit 1
    rx_setup_foreign "$n" "$me" "$dest" || exit 1
    echo
    sleep 2; /usr/local/sbin/gre-tunnel check "$n" || echo "(GRE: normal if the Iran server cannot reach this server)"
    echo
    sleep 3; /usr/local/sbin/xray-tunnel check "$n" ||
      echo "(if it stays like this: the Iran server's port $R_TPORT must be open for this server's IP $me)"
    echo
    echo "Now on the IRAN server: tunnel status shows the tunnel, and tunnel switch $n tls (or option 7)"
    echo "moves the ports onto it."
    return
  fi
  xt_have_xray || { xr=0; echo "[i] xray (x-ui) is not on this server: only the GRE tunnel is installed, no encrypted tunnel"; }
  iran=$(xt_get REMOTE_IP "$c"); [ -n "$iran" ] || iran=$(xt_get REMOTE_IP "$g")
  iran=$(ask "Enter IRAN server IP" "$iran"); valid_ip "$iran" || { echo "invalid IP"; exit 1; }
  me=$o_me; [ -n "$me" ] || me=$(xt_get LOCAL_IP "$g")
  me=$(ask "This server's IP (the Iran server connects to it)" "$(my_ip "$iran" "$me")"); valid_ip "$me" || { echo "invalid IP"; exit 1; }
  p=$o_ports; [ -n "$p" ] || p=$(xt_get PORTS "$g")
  echo "Ports of your services on this server that the Iran server sends here (the same port is used on Iran)."
  if [ "$xr" = 1 ]; then
    xt_ports "$p" >/dev/null || p=""
    p=$(ask "Comma separated, no ranges, at most 14 (e.g. 43773,443)" "$p")
    ports=$(xt_ports "${p// /}") || { echo "invalid ports (single ports, comma separated, at most 14): $p"; exit 1; }
    # the same ports in another order: kept as they are, so nothing changes
    [ -n "$o_ports" ] && [ "$(sort_ports "$o_ports")" = "$(sort_ports "$ports")" ] && ports=$o_ports
    dest=$(xt_dest "$ports") || exit 1
    [ "$o_mode" = reverse ] && o_tport=""
    tport=$(ask "Port of the encrypted tunnel on this server (only the Iran server can connect to it)" "${o_tport:-2083}")
    [[ $tport =~ ^[0-9]{1,5}$ ]] && [ "$tport" -ge 1 ] && [ "$tport" -le 65535 ] || { echo "invalid port"; exit 1; }
    in_csv "$tport" "$ports" && { echo "port $tport is one of the service ports; choose another"; exit 1; }
    if [ "$tport" != "$o_tport" ] && xt_listening | grep -qx "$tport"; then
      echo "port $tport is already used on this server; choose another"; exit 1; fi
    for o in $(xt_confs); do
      [ "$o" = "$n" ] || [ "$(xt_get TPORT "$XT_DIR/$o.conf")" != "$tport" ] || { echo "port $tport is used by encrypted tunnel $o"; exit 1; }
    done
    # the name of the other kind was chosen for the other direction: not offered here
    sni=$(ask "Domain name shown in the TLS handshake (optional, e.g. your own domain; - for none)" "$([ "$o_mode" = reverse ] || xt_get SNI "$c")")
    [ "$sni" = - ] && sni=""
    [ -z "$sni" ] || { [[ $sni =~ ^([A-Za-z0-9-]+\.)*[A-Za-z0-9-]+$ ]] && ! [[ $sni =~ ^[0-9.]+$ ]]; } ||
      { echo "invalid domain name (a name, not an IP; leave it empty for none)"; exit 1; }
    for o in openssl ss base64; do command -v $o >/dev/null || { echo "missing: $o (apt install openssl iproute2 coreutils)"; exit 1; }; done
  else
    p=$(ask "Comma separated, ranges as 20000:20100, or 'all'" "$p"); ports=${p// /}
    [ "$ports" = all ] || valid_ports "$ports" || { echo "invalid ports: $ports"; exit 1; }
  fi
  check_ends "$n" "$me" "$iran" || exit 1
  gre_apply "$n" foreign "$me" "$iran" "$ports" || exit 1
  if [ "$xr" = 1 ]; then xt_setup_foreign "$n" "$iran" "$me" "$ports" "$tport" "$sni" "$dest" || exit 1; fi
  echo
  sleep 2; /usr/local/sbin/gre-tunnel check "$n" || echo "(normal if the Iran side is not installed yet)"
  if [ "$xr" = 0 ]; then
    echo; echo "Now on the IRAN server: tunnel, option 1, IRAN, tunnel $n, 3 (GRE only),"
    echo "then this server's IP and the same ports."
    return
  fi
  /usr/local/sbin/xray-tunnel check "$n"
  echo
  if [ "$had" = 1 ] && { [ "$o_mode" = reverse ] || [ "$tport" != "$o_tport" ] || [ "$(sort_ports "$ports")" != "$(sort_ports "$o_ports")" ] ||
    [ "$me" != "$o_me" ] || [ "$dest" != "$o_dest" ]; }; then
    echo "[!!] The tunnel port, the ports, or this server's IP changed: set up the Iran server again NOW with the"
    echo "     new code below. Until then, ports that Iran has on the encrypted tunnel may not work."
    echo
  fi
  echo "Now on the IRAN server: tunnel, option 1, IRAN, tunnel $n, 2 (forward), and paste this code"
  echo "(keep it private: it is the key of the encrypted tunnel):"
  echo
  xt_code "$n"
  echo; echo
  echo "(the same code is printed again if you run option 1 here again)"
  if [ "$tport" != "$o_tport" ]; then
    echo "If this server has a cloud firewall (e.g. Hetzner Firewall), open TCP port $tport there for $iran."; fi
}

# after the encrypted tunnel $1 of this Iran server was set up: which way new
# connections of its ports take ($2 = 1: the tunnel is new here)
iran_paths() { local n=$1 live=$2 c=$XT_DIR/$1.conf on way ports
  on=$(xt_get ON "$c"); ports=$(xt_get PORTS "$c")
  if ! /usr/local/sbin/xray-tunnel check "$n"; then
    if [ "$(xt_get MODE "$c")" = reverse ]; then
      echo "(normal until option 1 ran on $(xt_get REMOTE_IP "$c") with the code above)"
    else echo "(check that option 1 ran on $(xt_get REMOTE_IP "$c") and its port $(xt_get TPORT "$c") is open in any cloud firewall)"; fi
    if [ -n "$on" ]; then
      echo "[!!] Ports $on are on the encrypted tunnel, which does not answer: their users cannot connect until it does."
      if [ "$(ask "Type yes to move them to GRE until then (move them back later with option 7)")" = yes ]; then
        switch_ports "$n" gre "$on"; fi
    fi
    echo; echo "Ports now (new connections):"; show_paths "$n"
    if [ "$(xt_get ON "$c")" = "$ports" ] || [ "$(sort_ports "$(xt_get ON "$c")")" = "$(sort_ports "$ports")" ]; then
      echo "Ports $ports are on the encrypted tunnel: their users connect once it answers."
    else echo "Move ports onto the encrypted tunnel once it answers: tunnel switch $n tls (or option 7)"; fi
    return
  fi
  echo
  echo "Which way should new connections of ports $ports take?"
  echo "1 - encrypted tunnel"
  echo "2 - GRE"
  echo "3 - keep as now (on the encrypted tunnel now: ${on:-none})"
  if [ "$live" = 1 ]; then way=$(ask "Enter 1, 2 or 3" 3); else way=$(ask "Enter 1, 2 or 3" 1); fi
  case "$way" in
    1) switch_ports "$n" tls all ;;
    2) switch_ports "$n" gre all ;;
    3) ;;
    *) echo "invalid; nothing switched" ;;
  esac
  echo; echo "Ports now (new connections; open ones finish on the way they started):"; show_paths "$n"
  echo "Switch later: tunnel, option 7 (or: tunnel switch $n tls|gre [PORT])"
}

install_iran() {
  local n=$1 g=/etc/gre-tunnel/$1.conf c=$XT_DIR/$1.conf code="" foreign lip ports ssh bad f o kind mode had=0 live=0 oldcode=""
  local tport sni p pub r
  [ -f "$c" ] && had=1
  { [ "$had" = 1 ] || systemctl -q is-active "gre-tunnel@$n"; } && live=1
  mode=$(xt_get MODE "$c"); mode=${mode:-forward}
  echo "Encrypted tunnel of tunnel $n:"
  echo "1 - reverse: the foreign server connects to this server (use it when this server cannot"
  echo "    reach the foreign server, e.g. its IP is filtered from Iran). Set up here first."
  echo "2 - forward: this server connects to the foreign server. Set up the foreign server first."
  echo "3 - none: GRE only"
  if [ "$had" = 1 ] && [ "$mode" != reverse ]; then kind=$(ask "Enter 1, 2 or 3" 2)
  elif [ "$had" = 0 ] && [ -f "$g" ]; then kind=$(ask "Enter 1, 2 or 3" 3)   # GRE only so far
  else kind=$(ask "Enter 1, 2 or 3" 1); fi
  case "$kind" in
    1) kind=reverse ;;
    2) kind=forward
       echo "Run option 1 on the FOREIGN server first (Enter at its code question; if it says the tunnel is"
       echo "reverse, type forward there): it prints a code that starts with XT1-."
       code=$(ask_code "Paste that code here" xt_parse_code)
       xt_parse_code "$code" || { echo "invalid code (copy the whole line that starts with XT1-)"; exit 1; }
       xt_have_xray || { echo "[!] xray not found on this server (x-ui keeps it in /usr/local/x-ui/bin/); the forward tunnel needs it"; exit 1; } ;;
    3) kind=none
       [ "$had" = 0 ] || { echo "tunnel $n has an encrypted part on this server: remove that part first with option 2"; exit 1; } ;;
    *) echo "invalid"; exit 1 ;;
  esac
  [ "$kind" = none ] || for o in openssl ss base64; do command -v $o >/dev/null || { echo "missing: $o (apt install openssl iproute2 coreutils)"; exit 1; }; done
  # the program first: without it nothing below is changed
  [ "$kind" = reverse ] && { rx_bin || exit 1; }
  if [ "$kind" = forward ]; then foreign=$(ask "Foreign server IP" "$P_FOREIGN"); ports=$P_PORTS
  else
    foreign=$(xt_get REMOTE_IP "$c"); [ -n "$foreign" ] || foreign=$(xt_get REMOTE_IP "$g")
    foreign=$(ask "Enter FOREIGN server IP (a new IP of that server goes here)" "$foreign")
  fi
  valid_ip "$foreign" || { echo "invalid IP"; exit 1; }
  lip=$(xt_get LOCAL_IP "$g"); [ -n "$lip" ] || lip=$(xt_get PUBLIC_IP "$c")
  lip=$(ask "This Iran server's IP" "$(my_ip "$foreign" "$lip")"); valid_ip "$lip" || { echo "invalid IP"; exit 1; }
  pub=$lip
  if [ "$kind" = reverse ] && is_private_ip "$lip"; then
    # behind NAT: GRE uses the address on this server, the foreign server dials the public one
    pub=$(xt_get PUBLIC_IP "$c"); is_private_ip "$pub" && pub=""
    pub=$(ask "$lip is a private address. The public IP of this server (the foreign server connects to it)" "$pub")
    valid_ip "$pub" || { echo "invalid IP"; exit 1; }
  fi
  if [ "$kind" = reverse ]; then
    p=$(xt_get PORTS "$c"); [ -n "$p" ] || p=$(xt_get PORTS "$g"); xt_ports "$p" >/dev/null || p=""
    p=$(ask "Ports to send to the foreign server: comma separated, no ranges, at most 14 (e.g. 443,43773)" "$p")
    ports=$(xt_ports "${p// /}") || { echo "invalid ports (single ports, comma separated, at most 14): $p"; exit 1; }
    o=$(xt_get PORTS "$c"); [ -n "$o" ] && [ "$(sort_ports "$o")" = "$(sort_ports "$ports")" ] && ports=$o
  elif [ "$kind" = none ]; then
    ports=$(ask "Ports to send to this foreign server: comma separated, ranges as 20000:20100, or 'all' (every port except SSH)" "$(xt_get PORTS "$g")")
    ports=${ports// /}
    [ "$ports" = all ] || valid_ports "$ports" || { echo "invalid ports: $ports"; exit 1; }
  fi
  ssh=$(ssh_ports); ssh=${ssh:-22}
  if [ "$ports" != all ]; then
    bad=$(port_overlap "$ports" "$ssh") && { echo "port $bad is SSH on this server; not forwarding it"; exit 1; }; fi
  for f in /etc/gre-tunnel/*.conf; do
    [ -e "$f" ] && [ "$f" != "$g" ] && [ "$(xt_get ROLE "$f")" = iran ] || continue
    o=$(xt_get PORTS "$f")
    if [ "$o" = all ] || [ "$ports" = all ]; then
      echo "'all' cannot be used together with another tunnel ($f); list the ports of each server"; exit 1; fi
    bad=$(port_overlap "$ports" "$o") && { echo "port $bad is already sent by tunnel $(basename "$f" .conf)"; exit 1; }
  done
  for o in $(xt_confs); do
    [ "$o" = "$n" ] && continue
    bad=$(port_overlap "$ports" "$(xt_get PORTS "$XT_DIR/$o.conf")") && { echo "port $bad is already in tunnel $o"; exit 1; }
    # the ports that tunnel itself listens on here (its tunnel port, local ports, UDP block)
    r=$(xt_get LPORTS "$XT_DIR/$o.conf" | sed -E 's/[0-9]+=//g'),$(xt_get LHPORT "$XT_DIR/$o.conf")
    [ "$(xt_get MODE "$XT_DIR/$o.conf")" = reverse ] && r+=",$(xt_get TPORT "$XT_DIR/$o.conf")$(rx_ublock "$XT_DIR/$o.conf")"
    r=$(tr , '\n' <<< "$r" | grep -E '^[0-9]+$' | paste -sd, -)
    if [ -n "$r" ]; then
      if [ "$ports" = all ]; then echo "'all' would also send the ports encrypted tunnel $o uses on this server; list the ports"; exit 1; fi
      bad=$(port_overlap "$ports" "$r") && { echo "port $bad is used by encrypted tunnel $o on this server; choose other ports"; exit 1; }
    fi
  done
  if [ "$kind" = reverse ]; then
    tport=""; [ "$mode" = reverse ] && tport=$(xt_get TPORT "$c")
    if [ -z "$tport" ]; then
      # not 2053 and the like: x-ui panels and inbounds often use them
      tport=24053; while [ "$tport" -le 65535 ] && ! rx_port_ok "$n" "$tport" "$ports" >/dev/null; do tport=$((tport + 1)); done
      [ "$tport" -le 65535 ] || tport=""; fi
    tport=$(ask "Port on this server that the foreign server connects to (only it can connect)" "$tport")
    rx_port_ok "$n" "$tport" "$ports" || exit 1
    # the name of the forward kind was chosen for the other direction: not offered here
    sni=$(ask "Domain name shown in the TLS handshake (optional, e.g. your own domain; - for none)" "$([ "$mode" = reverse ] && xt_get SNI "$c")")
    [ "$sni" = - ] && sni=""
    [ -z "$sni" ] || { [[ $sni =~ ^([A-Za-z0-9-]+\.)*[A-Za-z0-9-]+$ ]] && ! [[ $sni =~ ^[0-9.]+$ ]]; } ||
      { echo "invalid domain name (a name, not an IP; leave it empty for none)"; exit 1; }
  fi
  check_ends "$n" "$lip" "$foreign" || exit 1
  gre_apply "$n" iran "$lip" "$foreign" "$ports" || exit 1
  case $kind in
    forward) xt_setup_iran "$n" "$foreign" || exit 1 ;;
    reverse) [ "$(xt_get MODE "$c")" = reverse ] && oldcode=$(rx_code "$n" 2>/dev/null)
      rx_setup_iran "$n" "$foreign" "$pub" "$ports" "$tport" "$sni" || exit 1 ;;
  esac
  echo
  sleep 2; /usr/local/sbin/gre-tunnel check "$n" || echo "(normal if the foreign side is not installed yet, or GRE is blocked)"
  if [ "$kind" = none ]; then echo; echo "GRE tunnel $n forwards ports $ports to $foreign"; return; fi
  if [ "$kind" = reverse ]; then
    echo
    echo "Now on the FOREIGN server ($foreign): tunnel, option 1, FOREIGN, tunnel $n, and paste this"
    echo "code, all its lines from BEGIN to END (keep it private: it is the key of the encrypted tunnel)."
    echo "That server needs this script v$GRE_VERSION or newer (tunnel version); if older, run it from GitHub:"
    echo "bash <(curl -sSL https://raw.githubusercontent.com/tradeahadi-cmyk/gre-tunnel/main/tunnel.sh)"
    echo
    print_rx_code "$n"
    echo
    if [ -n "$oldcode" ] && [ "$oldcode" != "$(rx_code "$n")" ]; then
      echo "[!!] this code is NEW (the ports, port, name or this server's IP changed): until it is pasted"
      echo "     on $foreign, the tunnel does not work, or not for every port"
    else
      echo "(the same code is printed again if you run option 1 here again; a new foreign IP needs"
      echo " only option 1 here, not a new code there)"
    fi
    echo "If this server has a firewall in front of it, open TCP port $tport there for $foreign."
    sleep 1
  fi
  echo
  iran_paths "$n" "$live"
}

do_install() {
  local loc role n r
  echo "Installs (or changes) tunnel N: a GRE tunnel and an encrypted tunnel together."
  echo "Reverse (the foreign server connects to Iran): run it on the IRAN server first."
  echo "Forward (Iran connects to the foreign server): run it on the FOREIGN server first."
  echo "The first one prints a code for the other."
  echo "Select server location:"; echo "1 - IRAN"; echo "2 - FOREIGN"
  loc=$(ask "Enter 1 or 2")
  case "$loc" in 1) role=iran ;; 2) role=foreign ;; *) echo "invalid"; exit 1 ;; esac
  n=$(tunnel_nums); [ "$(wc -l <<< "$n")" = 1 ] && [ -n "$n" ] || n=1
  n=$(ask "Tunnel number (1 = first foreign server, 2 = second, ...; same number on both sides)" "$n")
  [[ $n =~ ^[1-9]$ ]] || { echo "tunnel number must be 1-9"; exit 1; }
  for r in "/etc/gre-tunnel/$n.conf" "$XT_DIR/$n.conf"; do
    if [ -f "$r" ] && [ "$(xt_get ROLE "$r")" != "$role" ]; then
      echo "tunnel $n on this server is the $(xt_get ROLE "$r") side; remove it first (option 2)"; exit 1; fi
  done
  if [ "$role" = foreign ]; then install_foreign "$n"; else install_iran "$n"; fi
  echo "The menu is saved on this server: run tunnel (works without GitHub)"
}

gre_drop() { local n=$1
  systemctl disable --now "gre-watchdog@$n.timer" 2>/dev/null
  systemctl stop "gre-watchdog@$n.service" 2>/dev/null
  systemctl disable --now "gre-tunnel@$n" 2>/dev/null
  rm -f "/etc/gre-tunnel/$n.conf"; }

do_remove() {
  local n g c what role on p cn gre_ports=""
  n=$(pick_tunnel) || return
  g=/etc/gre-tunnel/$n.conf; c=$XT_DIR/$n.conf; role=$(role_of "$n")
  if [ -f "$g" ] && [ -f "$c" ]; then
    echo "Remove from tunnel $n:"; echo "1 - both (GRE and encrypted)"; echo "2 - only the encrypted tunnel"; echo "3 - only GRE"
    case "$(ask "Enter 1, 2 or 3")" in 1) what=both ;; 2) what=xt ;; 3) what=gre ;; *) echo "invalid"; return ;; esac
  elif [ -f "$c" ]; then what=xt; else what=gre; fi
  on=$(xt_get ON "$c")
  if [ "$role" = foreign ]; then
    case $what in both) echo "Tunnel $n is removed: every port the Iran server sends here stops working." ;;
      xt) echo "The encrypted tunnel $n is removed: ports the Iran server has on it stop working until it"
          echo "moves them to GRE (option 7 there). $(xt_conns "$n") connections use it now." ;;
      gre) echo "GRE tunnel $n is removed: ports the Iran server sends through GRE stop working." ;; esac
    [ "$(ask "Type yes to remove it now")" = yes ] || { echo "not removed"; return; }
  elif [ "$what" = xt ]; then
    for p in ${on//,/ }; do gre_carries "$n" "$p" || gre_ports+="${gre_ports:+,}$p"; done
    if [ -n "$gre_ports" ]; then
      echo "[!!] GRE does not forward ports $gre_ports now: after the removal they are not forwarded at all."
      [ "$(ask "Type yes to remove the encrypted tunnel anyway")" = yes ] || { echo "not removed"; return; }
    fi
    if [ -n "$on" ]; then echo "[*] moving ports $on to GRE first"; switch_ports "$n" gre "$on" >/dev/null; fi
    cn=$(xt_conns "$n")
    if [ "$cn" -gt 0 ]; then
      echo "$cn connections still use encrypted tunnel $n; removing it now cuts them (new connections already use GRE)."
      [ "$(ask "Type yes to remove it now, or anything else to wait")" = yes ] || { echo "not removed; run option 2 again later"; return; }
    fi
  else
    if [ "$what" = both ]; then echo "Tunnel $n is removed: all its users are disconnected."
    else
      for p in $(tr , '\n' <<< "$(xt_get PORTS "$g")"); do in_csv "$p" "$on" || gre_ports+="${gre_ports:+,}$p"; done
      echo "GRE tunnel $n is removed: ports ${gre_ports:-none} use GRE now and are not forwarded after it"
      echo "(move them to the encrypted tunnel first with option 7). Connections on GRE are cut."
    fi
    [ "$(ask "Type yes to remove it now")" = yes ] || { echo "not removed"; return; }
  fi
  if [ "$what" != gre ]; then xt_drop "$n"; echo "[*] encrypted tunnel $n removed"; fi
  if [ "$what" != xt ]; then gre_drop "$n"; echo "[*] GRE tunnel $n removed"; fi
}

do_status() { local n
  [ -n "$(tunnel_nums)" ] || { echo "no tunnels on this server (option 1 installs one)"; return; }
  for n in $(tunnel_nums); do
    echo "================ tunnel $n ($(role_of "$n") side) ================"
    if [ -f "/etc/gre-tunnel/$n.conf" ]; then /usr/local/sbin/gre-tunnel check "$n"; else echo "GRE: not installed"; fi
    if [ -f "$XT_DIR/$n.conf" ]; then /usr/local/sbin/xray-tunnel check "$n"; else echo "encrypted tunnel: not installed"; fi
    if [ "$(role_of "$n")" = iran ]; then echo "Ports (new connections):"; show_paths "$n"; fi
    echo
  done
  journalctl -t gre-watchdog -t xray-tunnel -n 10 --no-pager 2>/dev/null
}

do_diag() { local n
  [ -n "$(tunnel_nums)" ] || { echo "no tunnels on this server"; return; }
  for n in $(tunnel_nums); do
    echo "================ tunnel $n: GRE ================"
    if [ -f "/etc/gre-tunnel/$n.conf" ]; then /usr/local/sbin/gre-tunnel diag "$n"; else echo "not installed"; fi
    [ -f "$XT_DIR/$n.conf" ] || continue
    echo "================ tunnel $n: encrypted ================"
    /usr/local/sbin/xray-tunnel check "$n"
    if [ "$(xt_get MODE "$XT_DIR/$n.conf")" = reverse ]; then echo "frp $("$XT_LIB/frpc" -v 2>/dev/null)"
    else "$XT_BIN" version 2>/dev/null | head -1; fi
    journalctl -u "xray-tunnel@$n" -n 15 --no-pager 2>/dev/null
    journalctl -t xray-tunnel -n 10 --no-pager 2>/dev/null
  done
}

# new scripts, same settings; applied in place so no user is disconnected
do_update() { local f n
  [ -n "$(tunnel_nums)" ] || { echo "no tunnels installed; choose 1 to install"; return; }
  if ls /etc/gre-tunnel/*.conf >/dev/null 2>&1; then
    install_files
    for f in /etc/gre-tunnel/*.conf; do
      n=$(basename "$f" .conf)
      /usr/local/sbin/gre-tunnel up "$n"
      systemctl enable -q "gre-tunnel@$n" "gre-watchdog@$n.timer" 2>/dev/null
    done
  fi
  if xt_update; then echo "Updated to v$GRE_VERSION (settings kept, connections not interrupted)"
  else echo "[!] v$GRE_VERSION is installed, but updating an encrypted tunnel failed (see above)"; fi
  echo "The menu is saved on this server: run tunnel (works without GitHub)"
}

do_switch() { local n c p
  n=$(pick_tunnel iran) || return; c=$XT_DIR/$n.conf
  echo "Tunnel $n to $(xt_get REMOTE_IP "$c"), new connections of each port:"; show_paths "$n"
  echo "Only new connections switch; open ones finish on the way they started, so nobody is cut."
  echo "1 - all ports to the encrypted tunnel"
  echo "2 - all ports to GRE"
  echo "3 - one port to the encrypted tunnel"
  echo "4 - one port to GRE"
  case "$(ask "Enter 1-4")" in
    1) switch_ports "$n" tls all ;;
    2) switch_ports "$n" gre all ;;
    3) p=$(ask "Port"); switch_ports "$n" tls "$p" ;;
    4) p=$(ask "Port" "$(xt_get ON "$c" | cut -d, -f1)"); switch_ports "$n" gre "$p" ;;
    *) echo "invalid"; return ;;
  esac
  echo; echo "Now:"; show_paths "$n"
}

usage() {
  echo "usage: tunnel                           the menu"
  echo "       tunnel status                    state of every tunnel and the way of each port"
  echo "       tunnel switch N tls|gre [PORT]   new connections of PORT (default: every port) of tunnel N"
  echo "                                        use the encrypted tunnel (tls) or GRE (Iran server)"
  echo "       tunnel version"
}

# the runtime's own timers wait while this changes a tunnel (xt_backup)
export XT_INSTALLER=1; XT_BUSY=""
trap 'for b in $XT_BUSY; do rm -f "/run/xray-tunnel.$b.busy"; done' EXIT
case "${1:-}" in
  "") ;;
  status) do_status; exit 0 ;;
  version|-v|--version) echo "tunnel $GRE_VERSION"; exit 0 ;;
  switch)
    [[ ${2:-} =~ ^[1-9]$ ]] && [[ ${3:-} =~ ^(tls|gre)$ ]] || { usage; exit 1; }
    switch_ports "$2" "$3" "${4:-all}"; rc=$?; show_paths "$2"; exit $rc ;;
  *) usage; exit 1 ;;
esac

echo "===================================="
echo "   Tunnel v$GRE_VERSION (GRE + encrypted tunnel)"
echo "===================================="
echo "1 - Install / change a tunnel (GRE and encrypted together)"
echo "2 - Remove a tunnel"
echo "3 - Status"
echo "4 - Diagnose (why a tunnel does not work)"
echo "5 - Update scripts only (keep settings, no disconnect)"
echo "6 - Uninstall everything (remove all tunnels, restore the server)"
echo "7 - Switch ports between GRE and the encrypted tunnel"
case "$(ask "Choose" 3)" in
  1) do_install ;; 2) do_remove ;; 3) do_status ;; 4) do_diag ;; 5) do_update ;; 6) do_uninstall ;;
  7) do_switch ;; *) echo "invalid" ;;
esac
GRE_SELF_END
eval "$GRE_SELF"
