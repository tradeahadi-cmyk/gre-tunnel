#!/bin/bash
# Tunnel: a GRE tunnel and an encrypted tunnel (VLESS + WebSocket + TLS) between an
# Iran server and foreign servers, installed together; ports switch between them.
# The whole installer is kept in GRE_SELF, so it can save an exact copy of itself
# as /usr/local/sbin/tunnel: the menu then works without GitHub.
IFS= read -r -d '' GRE_SELF <<'GRE_SELF_END'
set -u
GRE_VERSION=4.0.0
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
ask() { local p=$1 d=${2:-} v; read -r -p "$p${d:+ [$d]}: " v; echo "${v:-$d}"; }
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
VERSION=4.0.0
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


# ---------- encrypted tunnel (VLESS + WebSocket + TLS) next to GRE ----------
# Iran opens one TLS connection to the foreign server per user connection. Ports
# are moved onto it and back to GRE only by hand (option 7 / tunnel switch).
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
# Encrypted tunnel runtime: VLESS + WebSocket + TLS from Iran to a foreign server,
# one encrypted connection per user connection. Runs next to the GRE tunnel with
# the same number; ports are moved onto it and back to GRE only by hand (on/off).
# Usage: xray-tunnel check|on|off <N> [port]   (up|down|keep|prestart: used by the services)
# Settings for tunnel N live in /etc/xray-tunnel/<N>.conf
set -u
VERSION=4.0.0
CMD=${1:-}; N=${2:-}; ARG=${3:-}
DIR=/etc/xray-tunnel
BIN=/usr/local/lib/xray-tunnel/xray
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
ON=""; PIN=""; LPORTS=""; LHPORT=""; SNI=""; DEST=127.0.0.1
# shellcheck source=/dev/null
. "$CONF"   # ROLE REMOTE_IP TPORT UUID WSPATH SNI PORTS HPORT DEST; iran: PIN LPORTS LHPORT ON
JSON=$DIR/$N.json
NEWJSON=$DIR/$N.new.json   # xray reads the format from the .json ending
CHAIN=XTUN$N
STATE=/run/xray-tunnel.$N
# copy of the settings the running xray was started with
RUNNING=/run/xray-tunnel.$N.json
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

# Iran: users of the ports in ON are redirected to the local listener, which
# sends them through the tunnel. Only the jump into the chain is switched on and
# off; that affects new connections only, open ones keep their path.
sync_chain() { local IFS=, p lp want="" r
  iptables -w -t nat -N "$CHAIN" 2>/dev/null
  for p in $ON; do
    lp=$(lport "$p") || continue
    for r in tcp udp; do
      ipt_add nat -A "$CHAIN" -p "$r" --dport "$p" -j REDIRECT --to-ports "$lp"
      want+="-A $CHAIN -p $r -m $r --dport $p -j REDIRECT --to-ports $lp"$'\n'
    done
  done
  iptables -w -t nat -S "$CHAIN" 2>/dev/null | grep -- "^-A $CHAIN " | while IFS= read -r r; do
    grep -qxF -- "$r" <<< "$want" && continue
    IFS=' ' read -r -a a <<< "${r#-A }"
    iptables -w -t nat -D "${a[@]}"
  done
}
# Iran: the listeners take redirected users (also when INPUT drops by default, e.g. ufw)
# and local programs, never direct connections
guard() { local lps r; lps=$(lport_list)
  for r in tcp udp; do
    ipt_add filter -I INPUT ! -i lo -p "$r" -m multiport --dports "$lps" -m conntrack ! --ctstate DNAT "${TAG[@]}" -j DROP
    ipt_add filter -I INPUT ! -i lo -p "$r" -m multiport --dports "$lps" -m conntrack --ctstate DNAT "${TAG[@]}" -j ACCEPT
  done; }
# foreign: the tunnel port answers only the Iran server
fw_foreign() {
  ipt_add filter -I INPUT -p tcp --dport "$TPORT" ! -s "$REMOTE_IP" "${TAG[@]}" -j DROP
  ipt_add filter -I INPUT -p tcp --dport "$TPORT" -s "$REMOTE_IP" "${TAG[@]}" -j ACCEPT; }
# deletes this tunnel's filter rules (they are tagged); with $1 = old, only the
# ones left from older settings (other listener ports, tunnel port or Iran IP)
unfw() { local r a lps; lps=$(lport_list)
  iptables -w -S 2>/dev/null | grep -F -- "--comment xray-tunnel-$N " | while IFS= read -r r; do
    if [ "${1:-}" = old ]; then
      if [ "$ROLE" = iran ]; then [[ $r == *" --dports $lps "* ]] && continue
      else [[ $r == *" -s $REMOTE_IP/32 "* && $r == *" --dport $TPORT "* ]] && continue; fi
    fi
    IFS=' ' read -r -a a <<< "${r#-A }"; iptables -w -D "${a[@]}"; done; }

# Iran: the kernel must not give the listener ports to outgoing connections (a
# widened ip_local_port_range can include them), or xray could not listen on them
RES=/proc/sys/net/ipv4/ip_local_reserved_ports
in_ranges() { awk -v p="$1" -v l="$2" 'BEGIN { n = split(l, t, ",")
  for (i = 1; i <= n; i++) { k = split(t[i], r, "-"); if (t[i] != "" && p >= r[1] + 0 && p <= (k > 1 ? r[2] : r[1]) + 0) exit 0 }
  exit 1 }'; }
# the list is shared by all tunnels: one change at a time
res_lock() { command -v flock >/dev/null || return 0; exec 8> /run/xray-tunnel.reserved.lock; flock -w 10 8; }
reserve() { local IFS=, cur p add=""
  [ -w "$RES" ] || return 0
  res_lock; cur=$(cat "$RES")
  for p in $(lport_list),$LHPORT; do in_ranges "$p" "$cur" || add+=",$p"; done
  [ -z "$add" ] || echo "${cur}${add}" | sed 's/^,//' > "$RES"; }
unreserve() { local cur
  [ -w "$RES" ] || return 0
  res_lock; cur=$(cat "$RES")
  awk -v l="$cur" -v d="$(lport_list),$LHPORT" 'BEGIN { n = split(d, x, ","); for (i = 1; i <= n; i++) D[x[i] + 0] = 1
    m = split(l, t, ","); out = ""
    for (i = 1; i <= m; i++) { if (t[i] == "") continue
      k = split(t[i], r, "-"); a = r[1] + 0; b = (k > 1 ? r[2] : r[1]) + 0; s = a
      for (p = a; p <= b + 1; p++) if (p > b || (p in D)) {
        if (s <= p - 1) out = out (out == "" ? "" : ",") (s == p - 1 ? s : s "-" (p - 1)); s = p + 1 } }
    print out }' > "$RES"; }

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
  local new rc=0; new=$(gen_json)
  if [ ! -f "$JSON" ] || [ "$(cat "$JSON")" != "$new" ]; then
    printf '%s\n' "$new" > "$NEWJSON"
    # settings xray rejects are not saved: the running ones and the next start keep working
    if [ -x "$BIN" ] && ! "$BIN" run -test -c "$NEWJSON" >/dev/null 2>&1; then
      echo "[!] xray rejects the new settings of tunnel $N:" >&2
      "$BIN" run -test -c "$NEWJSON" 2>&1 | tail -5 >&2
      log "new settings rejected by xray, not saved"; rc=1
    else mv -f "$NEWJSON" "$JSON"; fi
    rm -f "$NEWJSON"
  fi
  # the running copy holds the key too: only root reads it
  [ -f "$RUNNING" ] && chmod 600 "$RUNNING"
  unfw old
  if [ "$ROLE" = iran ]; then
    reserve; sync_chain; guard
    if [ -n "$ON" ]; then jump_on; else release; fi
  else fw_foreign; fi
  return $rc
}
down() {
  local IFS=, lp
  if [ "$ROLE" = iran ]; then
    release
    iptables -w -t nat -F "$CHAIN" 2>/dev/null; iptables -w -t nat -X "$CHAIN" 2>/dev/null
    # UDP users keep their redirect while they send, even with nothing listening
    # any more; without it their next packet goes to GRE
    if command -v conntrack >/dev/null; then
      for lp in $(lport_list); do conntrack -D -p udp --reply-port-src "$lp" >/dev/null 2>&1; done; fi
    unreserve
  fi
  unfw
  rm -f "$STATE" "$RUNNING"; true
}

# Iran: a SOCKS greeting to the foreign server's health listener, sent through
# the tunnel, must come back as 05 00
probe() { local r
  r=$(timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/$LHPORT || exit 1; printf '\x05\x01\x00' >&3; head -c 2 <&3 | od -An -tx1" 2>/dev/null | tr -d ' \n')
  [ "$r" = 0500 ]; }

# Runs every 30 s: puts back rules that something removed (iptables -F, a GRE
# tunnel restart that inserted its rules above ours) and logs when the tunnel
# stops or starts answering. It never moves a port: only on/off does that.
keep() { local st prev
  up >/dev/null 2>&1
  [ "$ROLE" = iran ] || return 0
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
}

flush_udp() { conntrack -D -p udp --reply-port-src "$1" >/dev/null 2>&1; true; }
# ports already moved back to GRE by hand: UDP users who still send to the dead
# tunnel (their redirect stays while they send) go to GRE once it is dead for 30 s
unstick() { local IFS=, m
  command -v conntrack >/dev/null || return 0
  for m in $LPORTS; do in_list "${m%%=*}" "$ON" || flush_udp "${m#*=}"; done; }

set_on() { local IFS=, p out=""
  for p in $ON; do [ "$p" = "$ARG" ] || out+="${out:+,}$p"; done
  [ "$1" = add ] && out+="${out:+,}$ARG"
  ON=$out
  if grep -q '^ON=' "$CONF"; then sed -i "s/^ON=.*/ON=$ON/" "$CONF"; else echo "ON=$ON" >> "$CONF"; fi
  sync_chain
  if [ -n "$ON" ]; then jump_on; else release; fi; }

check() { local st c
  echo "xray-tunnel $VERSION | tunnel $N | role $ROLE | peer $REMOTE_IP:$TPORT | ports $PORTS${ON:+ | on the tunnel: $ON}"
  if systemctl -q is-active "xray-tunnel@$N"; then echo "[ok] service xray-tunnel@$N is running"
  else echo "[!!] service xray-tunnel@$N is not running: journalctl -u xray-tunnel@$N -n 20"; fi
  if [ -f "$RUNNING" ] && [ "$(cat "$RUNNING")" != "$(cat "$JSON" 2>/dev/null)" ]; then
    echo "[i] new settings are saved but used only after: systemctl restart xray-tunnel@$N (cuts open tunnel connections)"; fi
  if [ "$ROLE" = iran ]; then
    c=$(ss -Htn state established dst "$REMOTE_IP" "( dport = :$TPORT )" 2>/dev/null | wc -l)
    if probe; then echo "[ok] the foreign server answers through the tunnel ($c open tunnel connections)"; st=0
    else echo "[!!] no answer through the tunnel (run 'xray-tunnel check $N' on $REMOTE_IP too)"; st=1; fi
    if [ -z "$ON" ]; then echo "[i] no port uses the tunnel yet (move one: xray-tunnel on $N PORT)"
    elif jump_first; then
      echo "[ok] ports $ON use the tunnel (new connections)"
    else echo "[!!] ports $ON should use the tunnel but its rule is not first (fixed within 30 s, or run: xray-tunnel up $N)"; fi
    return $st
  fi
  c=$(ss -Htn state established src ":$TPORT" dst "$REMOTE_IP" 2>/dev/null | wc -l)
  if ss -Hltn "( sport = :$TPORT )" 2>/dev/null | grep -q .; then echo "[ok] listening on port $TPORT ($c connections from $REMOTE_IP)"
  else echo "[!!] nothing listens on port $TPORT"; return 1; fi
}

case "$CMD" in
  up) up ;; down) down ;; keep) keep ;;
  # the service starts xray with the settings on disk now
  prestart) up; [ -f "$JSON" ] && install -m 600 "$JSON" "$RUNNING" ;;
  check) check ;;
  on|off)
    [ "$ROLE" = iran ] || { echo "run this on the Iran server"; exit 1; }
    [[ $ARG =~ ^[0-9]+$ ]] && in_list "$ARG" "$PORTS" || { echo "port '$ARG' is not one of this tunnel's ports ($PORTS)"; exit 1; }
    if [ "$CMD" = on ]; then
      probe || { echo "[!!] the tunnel does not answer (xray-tunnel check $N); port $ARG stays on GRE"; exit 1; }
      ss -Hltn "( sport = :$(lport "$ARG") )" 2>/dev/null | grep -q . || {
        echo "[!!] xray does not listen for port $ARG yet: it needs systemctl restart xray-tunnel@$N (cuts open tunnel connections); port $ARG stays on GRE"; exit 1; }
      set_on add; log "port $ARG moved to the tunnel"
      echo "port $ARG: new connections use the encrypted tunnel; open ones stay on GRE until they end"
    else set_on del; log "port $ARG moved back to GRE"
      echo "port $ARG: new connections use GRE again; open tunnel connections continue until they end"
      # UDP users keep their redirect while they send. When the tunnel is dead (the
      # 30 s check found it dead and it still does not answer) they would stay cut,
      # so they are moved to GRE now; on a working tunnel they stay, like TCP users
      if command -v conntrack >/dev/null && [ "$(cat "$STATE" 2>/dev/null || echo ok)" != ok ] && ! probe; then
        flush_udp "$(lport "$ARG")"
        echo "the tunnel does not answer: UDP users of port $ARG were moved to GRE too"; fi
    fi ;;
  *) echo "usage: xray-tunnel check|on|off|up|down|keep <N> [port] | version"; exit 1 ;;
esac
XRUNTIME
  chmod 755 /usr/local/sbin/xray-tunnel.tmp && mv -f /usr/local/sbin/xray-tunnel.tmp /usr/local/sbin/xray-tunnel

  cat > /etc/systemd/system/xray-tunnel@.service <<'UNIT'
[Unit]
Description=Encrypted tunnel %i (VLESS + WebSocket + TLS)
After=network-online.target gre-tunnel@%i.service
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
# Go's MPTCP listeners ignore the TCP user timeout
Environment=GODEBUG=multipathtcp=0
ExecStartPre=/usr/local/sbin/xray-tunnel prestart %i
ExecStart=/usr/local/lib/xray-tunnel/xray run -c /etc/xray-tunnel/%i.json
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

# open tunnel connections of tunnel $1
xt_conns() { local c=$XT_DIR/$1.conf r t
  r=$(xt_get REMOTE_IP "$c"); t=$(xt_get TPORT "$c")
  if [ "$(xt_get ROLE "$c")" = iran ]; then ss -Htn state established dst "$r:$t" 2>/dev/null | wc -l
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
xt_start() { local n=$1 j=$XT_DIR/$1.json run=/run/xray-tunnel.$1.json c
  # checks the settings with xray first; rejected ones are not saved
  /usr/local/sbin/xray-tunnel up "$n" || { echo "[!] could not apply tunnel $n"; return 1; }
  systemctl enable -q "xray-tunnel@$n" "xray-tunnel-keep@$n.timer"
  if ! systemctl -q is-active "xray-tunnel@$n"; then
    systemctl start "xray-tunnel@$n" || { journalctl -u "xray-tunnel@$n" -n 15 --no-pager; return 1; }
  elif [ ! -f "$run" ] || [ "$(cat "$run")" != "$(cat "$j")" ]; then
    c=$(xt_conns "$n")
    if [ "$c" -gt 0 ] && [ "$(ask "The new settings need a restart of tunnel $n, which cuts its $c open connections for a moment. Type yes to restart now")" != yes ]; then
      echo "[i] not restarted: the new settings apply at the next restart (systemctl restart xray-tunnel@$n)"
    else systemctl restart "xray-tunnel@$n"; fi
  fi
  systemctl start "xray-tunnel-keep@$n.timer"
}

# writes the settings of tunnel $1 from stdin; the old ones are kept as .prev
# until xt_start worked, and put back if it did not
xt_write_conf() { local c=$XT_DIR/$1.conf
  rm -f "$c.prev"; [ -f "$c" ] && cp -p "$c" "$c.prev"
  cat > "$c.tmp" && chmod 600 "$c.tmp" && mv -f "$c.tmp" "$c"; }
xt_commit() { local n=$1 c=$XT_DIR/$1.conf
  if xt_start "$n"; then rm -f "$c.prev"; return 0; fi
  if [ -f "$c.prev" ]; then
    mv -f "$c.prev" "$c"; /usr/local/sbin/xray-tunnel up "$n" >/dev/null 2>&1
    echo "[!] the old settings of tunnel $n are kept"
  fi
  return 1; }

# puts the encrypted tunnels' rules back above GRE's (after GRE re-added its own)
xt_reapply() { local n
  [ -x /usr/local/sbin/xray-tunnel ] || return 0
  for n in $(xt_confs); do /usr/local/sbin/xray-tunnel up "$n" >/dev/null 2>&1; done; }

# reads the code printed by the foreign server into P_* variables
xt_parse_code() { local code=${1//[[:space:]]/} txt k v
  [[ $code == XT1-* ]] || return 1
  txt=$(printf '%s' "${code#XT1-}" | base64 -d 2>/dev/null) || return 1
  P_FOREIGN=""; P_TPORT=""; P_UUID=""; P_WSPATH=""; P_SNI=""; P_PIN=""; P_PORTS=""; P_HPORT=""; P_DEST=""
  while IFS='=' read -r k v; do
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

# sets up the Iran side of encrypted tunnel $1 to foreign server $2 from the pasted
# code (P_*). Ports keep their local port and their current way (ON), so open
# connections keep working
xt_setup_iran() {
  local n=$1 foreign=$2 c=$XT_DIR/$1.conf o p lp used="" lports="" lhport on="" gp="" f o_lports o_lhport o_on
  for o in $(xt_confs); do
    [ "$o" = "$n" ] && continue
    used+="${used:+,}$(xt_get LPORTS "$XT_DIR/$o.conf" | sed -E 's/[0-9]+=//g'),$(xt_get LHPORT "$XT_DIR/$o.conf")"
  done
  # local ports are not taken from the ports GRE forwards
  for f in /etc/gre-tunnel/*.conf; do p=$(xt_get PORTS "$f"); valid_ports "$p" && gp+="${gp:+,}$p"; done
  xt_install_files iran
  xt_bin || return 1
  o_lports=$(xt_get LPORTS "$c"); o_lhport=$(xt_get LHPORT "$c"); o_on=$(xt_get ON "$c")
  used+=",$(sed -E 's/[0-9]+=//g' <<< "$o_lports"),$o_lhport"
  for p in ${P_PORTS//,/ }; do
    lp=""
    for o in ${o_lports//,/ }; do [ "${o%%=*}" = "$p" ] && lp=${o#*=}; done
    if [ -z "$lp" ]; then
      lp=61001
      while :; do
        lp=$(xt_free_port "$lp" "$used,$P_PORTS")
        [ -n "$gp" ] && port_overlap "$lp" "$gp" >/dev/null || break
        lp=$((lp + 1))
      done
    fi
    used+=",$lp"; lports+="${lports:+,}$p=$lp"
    in_csv "$p" "$o_on" && on+="${on:+,}$p"
  done
  lhport=$o_lhport; [ -n "$lhport" ] || lhport=$(xt_free_port 61901 "$used,$P_PORTS")
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
LPORTS=$lports
LHPORT=$lhport
ON=$on
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
xt_update() { local n
  [ -n "$(xt_confs)" ] || return 0
  xt_install_files
  xt_bin || return 1
  for n in $(xt_confs); do xt_start "$n"; done
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
    if in_csv "$p" "$on"; then echo "  port $p: encrypted tunnel"
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
    { [ "$ports" != all ] || [ "$(xt_get SSH_PORTS "$c")" = "$ssh" ]; } && systemctl -q is-active "gre-tunnel@$n"; then
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

install_foreign() {
  local n=$1 g=/etc/gre-tunnel/$1.conf c=$XT_DIR/$1.conf xr=1 iran me p ports tport="" sni="" dest="" o
  local o_tport o_ports o_me o_dest had=0
  [ -f "$c" ] && had=1
  o_tport=$(xt_get TPORT "$c"); o_ports=$(xt_get PORTS "$c"); o_me=$(xt_get PUBLIC_IP "$c"); o_dest=$(xt_get DEST "$c")
  xt_have_xray || { xr=0; echo "[i] xray (x-ui) is not on this server: only the GRE tunnel is installed, no encrypted tunnel"; }
  iran=$(xt_get REMOTE_IP "$c"); [ -n "$iran" ] || iran=$(xt_get REMOTE_IP "$g")
  iran=$(ask "Enter IRAN server IP" "$iran"); valid_ip "$iran" || { echo "invalid IP"; exit 1; }
  me=$o_me; [ -n "$me" ] || me=$(xt_get LOCAL_IP "$g"); [ -n "$me" ] || me=$(src_ip 1.1.1.1)
  me=$(ask "This server's IP (the Iran server connects to it)" "$me"); valid_ip "$me" || { echo "invalid IP"; exit 1; }
  p=$o_ports; [ -n "$p" ] || p=$(xt_get PORTS "$g")
  echo "Ports of your services on this server that the Iran server sends here (the same port is used on Iran)."
  if [ "$xr" = 1 ]; then
    xt_ports "$p" >/dev/null || p=""
    p=$(ask "Comma separated, no ranges, at most 14 (e.g. 43773,443)" "$p")
    ports=$(xt_ports "${p// /}") || { echo "invalid ports (single ports, comma separated, at most 14): $p"; exit 1; }
    # the same ports in another order: kept as they are, so nothing changes
    [ -n "$o_ports" ] && [ "$(sort_ports "$o_ports")" = "$(sort_ports "$ports")" ] && ports=$o_ports
    dest=$(xt_dest "$ports") || exit 1
    tport=$(ask "Port of the encrypted tunnel on this server (only the Iran server can connect to it)" "${o_tport:-2083}")
    [[ $tport =~ ^[0-9]{1,5}$ ]] && [ "$tport" -ge 1 ] && [ "$tport" -le 65535 ] || { echo "invalid port"; exit 1; }
    in_csv "$tport" "$ports" && { echo "port $tport is one of the service ports; choose another"; exit 1; }
    if [ "$tport" != "$o_tport" ] && xt_listening | grep -qx "$tport"; then
      echo "port $tport is already used on this server; choose another"; exit 1; fi
    for o in $(xt_confs); do
      [ "$o" = "$n" ] || [ "$(xt_get TPORT "$XT_DIR/$o.conf")" != "$tport" ] || { echo "port $tport is used by encrypted tunnel $o"; exit 1; }
    done
    sni=$(ask "Domain name shown in the TLS handshake (optional, e.g. your own domain)" "$(xt_get SNI "$c")")
    [[ $sni =~ ^([A-Za-z0-9-]+\.)*[A-Za-z0-9-]+$ ]] || [ -z "$sni" ] || { echo "invalid domain name"; exit 1; }
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
    echo; echo "Now on the IRAN server: tunnel, option 1, IRAN, tunnel $n, press Enter at the code question"
    echo "(GRE only), then this server's IP and the same ports."
    return
  fi
  /usr/local/sbin/xray-tunnel check "$n"
  echo
  if [ "$had" = 1 ] && { [ "$tport" != "$o_tport" ] || [ "$(sort_ports "$ports")" != "$(sort_ports "$o_ports")" ] ||
    [ "$me" != "$o_me" ] || [ "$dest" != "$o_dest" ]; }; then
    echo "[!!] The tunnel port, the ports, or this server's IP changed: set up the Iran server again NOW with the"
    echo "     new code below. Until then, ports that Iran has on the encrypted tunnel may not work."
    echo
  fi
  echo "Now on the IRAN server: tunnel, option 1, IRAN, tunnel $n, and paste this code (keep it private:"
  echo "it is the key of the encrypted tunnel):"
  echo
  xt_code "$n"
  echo; echo
  echo "(the same code is printed again if you run option 1 here again)"
  if [ "$tport" != "$o_tport" ]; then
    echo "If this server has a cloud firewall (e.g. Hetzner Firewall), open TCP port $tport there for $iran."; fi
}

install_iran() {
  local n=$1 g=/etc/gre-tunnel/$1.conf c=$XT_DIR/$1.conf code="" foreign lip ports ssh bad f o way on had=0 live=0
  [ -f "$c" ] && had=1
  { [ "$had" = 1 ] || systemctl -q is-active "gre-tunnel@$n"; } && live=1
  echo "Run option 1 on the FOREIGN server first: it prints a code that starts with XT1-."
  code=$(ask "Paste that code here (or press Enter for a GRE-only tunnel)")
  if [ -n "$code" ]; then
    xt_parse_code "$code" || { echo "invalid code (copy the whole line that starts with XT1-)"; exit 1; }
    xt_have_xray || { echo "[!] xray not found on this server (x-ui keeps it in /usr/local/x-ui/bin/); the encrypted tunnel needs it"; exit 1; }
    for o in ss base64; do command -v $o >/dev/null || { echo "missing: $o"; exit 1; }; done
    foreign=$(ask "Foreign server IP" "$P_FOREIGN"); ports=$P_PORTS
  else
    [ "$had" = 0 ] || { echo "tunnel $n has an encrypted part on this server: paste the code (or remove that part first with option 2)"; exit 1; }
    foreign=$(ask "Enter FOREIGN server IP" "$(xt_get REMOTE_IP "$g")")
  fi
  valid_ip "$foreign" || { echo "invalid IP"; exit 1; }
  lip=$(xt_get LOCAL_IP "$g"); [ -n "$lip" ] || lip=$(src_ip "$foreign")
  lip=$(ask "This Iran server's IP" "$lip"); valid_ip "$lip" || { echo "invalid IP"; exit 1; }
  if [ -z "$code" ]; then
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
  done
  check_ends "$n" "$lip" "$foreign" || exit 1
  gre_apply "$n" iran "$lip" "$foreign" "$ports" || exit 1
  if [ -n "$code" ]; then xt_setup_iran "$n" "$foreign" || exit 1; fi
  echo
  sleep 2; /usr/local/sbin/gre-tunnel check "$n" || echo "(normal if the foreign side is not installed yet)"
  if [ -z "$code" ]; then echo; echo "GRE tunnel $n forwards ports $ports to $foreign"; return; fi
  echo
  on=$(xt_get ON "$c")
  if ! /usr/local/sbin/xray-tunnel check "$n"; then
    echo "(check that option 1 ran on $foreign and its port $P_TPORT is open in any cloud firewall)"
    if [ -n "$on" ] && [ "$(ask "Ports $on are on the encrypted tunnel, which does not answer. Type yes to move them to GRE")" = yes ]; then
      switch_ports "$n" gre "$on"; fi
    echo; echo "Ports now (new connections):"; show_paths "$n"
    return
  fi
  echo
  echo "Which way should new connections of ports $ports take?"
  echo "1 - encrypted tunnel (VLESS + WebSocket + TLS)"
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

do_install() {
  local loc role n r
  echo "Installs (or changes) tunnel N: a GRE tunnel and an encrypted tunnel (VLESS + WebSocket + TLS)"
  echo "together. Run it on the FOREIGN server first: it prints a code for the IRAN server."
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
    "$XT_BIN" version 2>/dev/null | head -1
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
  xt_update
  echo "Updated to v$GRE_VERSION (settings kept, connections not interrupted)"
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
echo "   Tunnel v$GRE_VERSION (GRE + VLESS/WS/TLS)"
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
