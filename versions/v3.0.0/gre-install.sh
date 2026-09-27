#!/bin/bash
# Optimized GRE tunnel (based on vatanhost/gre): survives reboots, forwards
# only the ports you choose, MSS clamping, self-repairing watchdog.
# The whole installer is kept in GRE_SELF, so it can save an exact copy of itself
# as /usr/local/sbin/gre-install: the menu then works without GitHub.
IFS= read -r -d '' GRE_SELF <<'GRE_SELF_END'
set -u
GRE_VERSION=3.0.0
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
# on the server without GitHub: run gre-install
save_self() {
  local f=/usr/local/sbin/gre-install
  [ -n "${GRE_SELF:-}" ] || return 0
  {
    printf '%s\n' '#!/bin/bash' \
      '# Optimized GRE tunnel (based on vatanhost/gre): survives reboots, forwards' \
      '# only the ports you choose, MSS clamping, self-repairing watchdog.' \
      '# The whole installer is kept in GRE_SELF, so it can save an exact copy of itself' \
      '# as /usr/local/sbin/gre-install: the menu then works without GitHub.' \
      "IFS= read -r -d '' GRE_SELF <<'GRE_SELF_END'"
    printf '%s' "$GRE_SELF"
    # shellcheck disable=SC2016
    printf '%s\n' 'GRE_SELF_END' 'eval "$GRE_SELF"'
  } > "$f.tmp" && chmod 755 "$f.tmp" && mv -f "$f.tmp" "$f"
}

install_files() {
  mkdir -p /etc/gre-tunnel
  save_self
  cat > /usr/local/sbin/gre-tunnel <<'RUNTIME'
#!/bin/bash
# GRE tunnel runtime. Usage: gre-tunnel up|down|check|diag|watchdog <N>
# Settings for tunnel N live in /etc/gre-tunnel/<N>.conf
set -u
VERSION=3.0.0
CMD=${1:-}; N=${2:-}
if [ "$CMD" = version ]; then echo "gre-tunnel $VERSION"; exit 0; fi
CONF=/etc/gre-tunnel/$N.conf
if [ -z "$N" ] || [ ! -f "$CONF" ]; then echo "usage: gre-tunnel up|down|check|diag|watchdog <N>  (missing $CONF; menu: gre-install)"; exit 1; fi
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
ipt_add() { local t=$1 op=$2; shift 2
  iptables -w -t "$t" -C "$@" 2>/dev/null && return 0
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
        $f nat -I PREROUTING ! -i vgre+ -m addrtype --dst-type LOCAL -p tcp -m multiport --dports "$c" -j DNAT --to-destination "$PEER_TIP"
        $f nat -I PREROUTING ! -i vgre+ -m addrtype --dst-type LOCAL -p udp -m multiport --dports "$c" -j DNAT --to-destination "$PEER_TIP"
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
      echo "tunnel '$other' already uses $LOCAL_IP -> $REMOTE_IP; remove it first (ip link del $other)" >&2
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

do_install() {
  echo "Select server location:"; echo "1 - IRAN"; echo "2 - FOREIGN"
  local loc ROLE; loc=$(ask "Enter 1 or 2")
  case "$loc" in 1) ROLE=iran ;; 2) ROLE=foreign ;; *) echo "invalid"; exit 1 ;; esac
  local n; n=$(ask "Tunnel number (1 = first foreign server, 2 = second, ...; same number on both sides)" 1)
  [[ $n =~ ^[1-9]$ ]] || { echo "tunnel number must be 1-9"; exit 1; }
  local myip iran foreign
  myip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
  if [ "$ROLE" = iran ]; then
    iran=$(ask "Enter IRAN server IP" "$myip"); foreign=$(ask "Enter FOREIGN server IP")
  else
    iran=$(ask "Enter IRAN server IP"); foreign=$(ask "Enter FOREIGN server IP" "$myip")
  fi
  valid_ip "$iran" && valid_ip "$foreign" || { echo "invalid IP"; exit 1; }

  local ports ssh f o bad
  ssh=$(ssh_ports); ssh=${ssh:-22}
  if [ "$ROLE" = iran ]; then
    echo "Ports on this Iran server to send to this foreign server (the same port is used there)."
    ports=$(ask "Comma separated, ranges as 20000:20100 (e.g. 8388,2053), or 'all' = every port except SSH")
  else
    ports=$(ask "Ports the Iran server forwards to this server (same list as on Iran), or 'all'")
  fi
  ports=${ports// /}
  [ "$ports" = all ] || valid_ports "$ports" || { echo "invalid ports: $ports"; exit 1; }
  if [ "$ROLE" = iran ] && [ "$ports" != all ]; then
    bad=$(port_overlap "$ports" "$ssh") && { echo "port $bad is SSH on this server; not forwarding it"; exit 1; }
  fi
  if [ "$ROLE" = iran ]; then
    for f in /etc/gre-tunnel/*.conf; do
      [ -e "$f" ] && [ "$f" != "/etc/gre-tunnel/$n.conf" ] || continue
      # shellcheck source=/dev/null
      o=$(ROLE=; PORTS=; . "$f"; [ "$ROLE" = iran ] && echo "$PORTS")
      [ -n "$o" ] || continue
      if [ "$o" = all ] || [ "$ports" = all ]; then
        echo "'all' cannot be used together with another tunnel ($f); list the ports of each server"; exit 1; fi
      bad=$(port_overlap "$ports" "$o") && { echo "port $bad is already sent by $f"; exit 1; }
    done
    LOCAL_IP=$iran; REMOTE_IP=$foreign
  else
    LOCAL_IP=$foreign; REMOTE_IP=$iran
  fi

  save_orig_sysctl
  # stop with the old runtime first, so it removes exactly the rules it added
  systemctl stop "gre-tunnel@$n" 2>/dev/null
  remove_old_vatan
  install_files
  cat > "/etc/gre-tunnel/$n.conf" <<CONF
ROLE=$ROLE
LOCAL_IP=$LOCAL_IP
REMOTE_IP=$REMOTE_IP
PORTS=$ports
SSH_PORTS=$ssh
MTU=1420
CONF
  if ! systemctl enable --now "gre-tunnel@$n" "gre-watchdog@$n.timer"; then
    echo "[!] tunnel $n failed to start:"; journalctl -u "gre-tunnel@$n" -n 15 --no-pager; exit 1
  fi
  xt_reapply
  echo
  if [ "$ROLE" = iran ]; then
    echo "Done. Iran tunnel IP 10.200.$n.2, foreign 10.200.$n.1, forwarding: $ports (SSH kept: $ssh)"
  else
    echo "Done. Foreign tunnel IP 10.200.$n.1, Iran 10.200.$n.2, accepting from tunnel: $ports"
  fi
  sleep 2; /usr/local/sbin/gre-tunnel check "$n" || echo "(normal if the other side is not installed yet)"
  echo "This menu is also saved on the server: run gre-install (works without GitHub)"
}

do_remove() {
  local n; n=$(ask "Tunnel number to remove" 1)
  systemctl disable --now "gre-watchdog@$n.timer" 2>/dev/null
  systemctl stop "gre-watchdog@$n.service" 2>/dev/null
  systemctl disable --now "gre-tunnel@$n" 2>/dev/null
  rm -f "/etc/gre-tunnel/$n.conf"
  echo "Tunnel $n removed"
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
    [ -z "$(xt_instances)" ] && [ ! -e "$XT_DIR" ] && [ ! -e /usr/local/sbin/xray-tunnel ]; then
    left=$(list_leftovers)
    if [ -z "$left" ]; then echo "Nothing of this script is installed on this server."; return; fi
    echo "Nothing of this script is installed, but these tunnel rules/interfaces are left over:"; echo "$left"
  fi
  echo "This removes ALL tunnels made by this script and everything it installed:"
  echo "GRE and encrypted tunnels, services, firewall rules, tunnel interfaces and settings."
  echo "Users on the tunnels are disconnected."
  echo "x-ui, SSH and other services are not touched."
  grep -qs '^ROLE=foreign' "$XT_DIR"/*.conf &&
    echo "On a foreign server: ports that Iran has on the encrypted tunnel stop working; move them back to GRE on Iran first (option 8 there)."
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
  rm -f /usr/local/sbin/gre-tunnel /usr/local/sbin/gre-install /etc/modules-load.d/gre-tunnel.conf /run/gre-watchdog.* \
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

# new scripts, same settings; applied in place so no user is disconnected
do_update() {
  local f n
  if ! ls /etc/gre-tunnel/*.conf >/dev/null 2>&1 && [ -z "$(xt_confs)" ]; then
    echo "no tunnels installed; choose 1 to install"; return; fi
  ls /etc/gre-tunnel/*.conf >/dev/null 2>&1 && install_files
  for f in /etc/gre-tunnel/*.conf; do
    [ -e "$f" ] || continue
    n=$(basename "$f" .conf)
    /usr/local/sbin/gre-tunnel up "$n"
    systemctl enable -q "gre-tunnel@$n" "gre-watchdog@$n.timer" 2>/dev/null
  done
  xt_update
  echo "Updated to v$GRE_VERSION (settings kept, connections not interrupted)"
  echo "This menu is also saved on the server: run gre-install (works without GitHub)"
}

do_diag() {
  local f n
  for f in /etc/gre-tunnel/*.conf; do
    [ -e "$f" ] || { [ -n "$(xt_confs)" ] || echo "no tunnels"; break; }
    n=$(basename "$f" .conf)
    echo "================ tunnel $n ================"
    /usr/local/sbin/gre-tunnel diag "$n"
  done
  xt_diag
}

do_status() {
  local f n
  for f in /etc/gre-tunnel/*.conf; do
    [ -e "$f" ] || { [ -n "$(xt_confs)" ] || echo "no tunnels"; break; }
    n=$(basename "$f" .conf)
    /usr/local/sbin/gre-tunnel check "$n"
  done
  ls /etc/gre-tunnel/*.conf >/dev/null 2>&1 && journalctl -t gre-watchdog -n 10 --no-pager 2>/dev/null
  xt_status
}

# ---------- encrypted tunnel (VLESS + WebSocket + TLS) next to GRE: menu 7-9 ----------
# Iran opens one TLS connection to the foreign server per user connection. Ports
# are moved onto it and back to GRE only by hand (option 8 / xray-tunnel on|off).
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
VERSION=3.0.0
CMD=${1:-}; N=${2:-}; ARG=${3:-}
DIR=/etc/xray-tunnel
BIN=/usr/local/lib/xray-tunnel/xray
if [ "$CMD" = version ]; then echo "xray-tunnel $VERSION"; exit 0; fi
CONF=$DIR/$N.conf
if ! [[ $N =~ ^[1-9]$ ]] || [ ! -f "$CONF" ]; then
  echo "usage: xray-tunnel check|on|off|up|down|keep <N> [port]  (missing $CONF; menu: gre-install)"; exit 1; fi
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
keep() { local st
  up >/dev/null 2>&1
  [ "$ROLE" = iran ] || return 0
  if ! systemctl -q is-active "xray-tunnel@$N"; then st=stopped
  elif probe; then st=ok; else st=fail; fi
  if [ "$st" != "$(cat "$STATE" 2>/dev/null || echo ok)" ]; then
    case $st in
      fail) log "no answer from $REMOTE_IP through the tunnel; users of ports ${ON:-none} cannot connect. Move a port back to GRE: xray-tunnel off $N PORT" ;;
      stopped) log "service xray-tunnel@$N is not running; users of ports ${ON:-none} cannot connect (journalctl -u xray-tunnel@$N)" ;;
      ok) log "tunnel to $REMOTE_IP answers again" ;;
    esac
  fi
  echo "$st" > "$STATE"
}

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
  prestart) up; [ -f "$JSON" ] && cp -f "$JSON" "$RUNNING" ;;
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
      echo "port $ARG: new connections use GRE again; open tunnel connections continue until they end"; fi ;;
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
in_csv() { [[ ,$2, == *,$1,* ]]; }
xt_rand() { head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }

# single ports (no ranges), comma separated, at most 14; prints them without leading zeros
xt_ports() { local IFS=, p out="" c=0
  [[ $1 =~ ^[0-9]{1,5}(,[0-9]{1,5})*$ ]] || return 1
  for p in $1; do
    p=$((10#$p)); [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || return 1
    in_csv "$p" "$out" || { out+="${out:+,}$p"; c=$((c + 1)); }
  done
  [ "$c" -le 14 ] && echo "$out"; }

xt_listening() { ss -Htuln 2>/dev/null | awk '{ n = split($5, a, ":"); print a[n] }' | sort -un; }
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
    else one=$(grep -m1 -E '^[0-9.]+$' <<< "$a"); fi
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

xt_install_foreign() {
  local n=$1 c=$XT_DIR/$1.conf g=/etc/gre-tunnel/$1.conf iran ports dest tport sni me hport uuid wspath pin cn p o
  local o_ip o_ports o_tport o_sni o_hport o_uuid o_ws o_me o_dest
  o_dest=$(xt_get DEST "$c"); o_me=$(xt_get PUBLIC_IP "$c"); o_ip=$(xt_get REMOTE_IP "$c"); o_ports=$(xt_get PORTS "$c"); o_tport=$(xt_get TPORT "$c")
  o_sni=$(xt_get SNI "$c"); o_hport=$(xt_get HPORT "$c"); o_uuid=$(xt_get UUID "$c"); o_ws=$(xt_get WSPATH "$c")
  [ -n "$o_ip" ] || { [ "$(xt_get ROLE "$g")" = foreign ] && o_ip=$(xt_get REMOTE_IP "$g"); }
  [ -n "$o_ports" ] || { p=$(xt_get PORTS "$g"); xt_ports "$p" >/dev/null && o_ports=$p; }
  iran=$(ask "Enter IRAN server IP" "$o_ip"); valid_ip "$iran" || { echo "invalid IP"; exit 1; }
  echo "Ports of your services on this server that the Iran server sends through the tunnel."
  p=$(ask "Comma separated, no ranges (e.g. 43773,443)" "$o_ports")
  ports=$(xt_ports "${p// /}") || { echo "invalid ports (single ports, comma separated, at most 14): $p"; exit 1; }
  dest=$(xt_dest "$ports") || exit 1
  tport=$(ask "Port of the encrypted tunnel on this server (only the Iran server can connect to it)" "${o_tport:-2083}")
  [[ $tport =~ ^[0-9]{1,5}$ ]] && [ "$tport" -ge 1 ] && [ "$tport" -le 65535 ] || { echo "invalid port"; exit 1; }
  in_csv "$tport" "$ports" && { echo "port $tport is one of the service ports; choose another"; exit 1; }
  if [ "$tport" != "$o_tport" ] && xt_listening | grep -qx "$tport"; then
    echo "port $tport is already used on this server; choose another"; exit 1; fi
  for o in $(xt_confs); do
    [ "$o" = "$n" ] || [ "$(xt_get TPORT "$XT_DIR/$o.conf")" != "$tport" ] || { echo "port $tport is used by encrypted tunnel $o"; exit 1; }
  done
  sni=$(ask "Domain name shown in the TLS handshake (optional, e.g. your own domain)" "$o_sni")
  [[ $sni =~ ^([A-Za-z0-9-]+\.)*[A-Za-z0-9-]+$ ]] || [ -z "$sni" ] || { echo "invalid domain name"; exit 1; }
  me=${o_me:-$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')}
  me=$(ask "This server's IP (the Iran server connects to it)" "$me"); valid_ip "$me" || { echo "invalid IP"; exit 1; }
  command -v openssl >/dev/null || { echo "openssl is missing (apt install openssl)"; exit 1; }
  xt_install_files
  xt_bin || exit 1
  hport=$o_hport; [ -n "$hport" ] || hport=$(xt_free_port 62001 "$ports,$tport")
  # the same keys when installing again, so the Iran side keeps working
  uuid=${o_uuid:-$(cat /proc/sys/kernel/random/uuid)}
  wspath=${o_ws:-/$(xt_rand 6)}
  # made once and kept: Iran accepts only this certificate (the name in it does not matter)
  if [ ! -s "$XT_DIR/$n.crt" ] || [ ! -s "$XT_DIR/$n.key" ]; then
    cn=${sni:-tunnel-$n.local}
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -sha256 -days 3650 \
      -subj "/CN=$cn" -addext "subjectAltName=DNS:$cn" -keyout "$XT_DIR/$n.key.tmp" -out "$XT_DIR/$n.crt.tmp" >/dev/null 2>&1 ||
      { echo "[!] could not make the TLS certificate"; rm -f "$XT_DIR/$n".*.tmp; exit 1; }
    chmod 600 "$XT_DIR/$n.key.tmp"
    mv -f "$XT_DIR/$n.key.tmp" "$XT_DIR/$n.key"; mv -f "$XT_DIR/$n.crt.tmp" "$XT_DIR/$n.crt"
  fi
  pin=$(openssl x509 -in "$XT_DIR/$n.crt" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d : | tr A-F a-f)
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
  xt_commit "$n" || exit 1
  sleep 1
  /usr/local/sbin/xray-tunnel check "$n"
  echo
  if [ -n "$o_uuid" ] && { [ "$tport" != "$o_tport" ] || [ "$ports" != "$o_ports" ] || [ "$dest" != "$o_dest" ] || [ "$me" != "$o_me" ]; }; then
    echo "[!!] The tunnel port, the ports, or this server's IP changed: pair the Iran server again NOW with the new"
    echo "     code below (option 7 there). Until then, ports that Iran has on this tunnel may not work."
    echo
  fi
  echo "Now on the IRAN server: gre-install, option 7, IRAN, tunnel $n, and paste this code (keep it private):"
  echo
  printf 'V=1\nFOREIGN_IP=%s\nTPORT=%s\nUUID=%s\nWSPATH=%s\nSNI=%s\nPIN=%s\nPORTS=%s\nHPORT=%s\nDEST=%s\n' \
    "$me" "$tport" "$uuid" "$wspath" "$sni" "$pin" "$ports" "$hport" "$dest" | base64 -w0 | sed 's/^/XT1-/'
  echo; echo
  echo "(the same code is printed again if you run option 7 here again)"
}

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

xt_install_iran() {
  local n=$1 c=$XT_DIR/$1.conf g=/etc/gre-tunnel/$1.conf code foreign ssh bad o p lp used="" lports="" lhport on="" gp f
  local o_lports o_lhport o_on
  echo "First run option 7 on the FOREIGN server (choose FOREIGN there); it prints a code starting with XT1-"
  code=$(ask "Paste that code here")
  xt_parse_code "$code" || { echo "invalid code (copy the whole line that starts with XT1-)"; exit 1; }
  foreign=$(ask "Foreign server IP" "$P_FOREIGN"); valid_ip "$foreign" || { echo "invalid IP"; exit 1; }
  ssh=$(ssh_ports); ssh=${ssh:-22}
  bad=$(port_overlap "$P_PORTS" "$ssh") && { echo "port $bad is SSH on this server; not moving it"; exit 1; }
  for o in $(xt_confs); do
    [ "$o" = "$n" ] && continue
    bad=$(port_overlap "$P_PORTS" "$(xt_get PORTS "$XT_DIR/$o.conf")") && { echo "port $bad is already in encrypted tunnel $o"; exit 1; }
    used+="${used:+,}$(xt_get LPORTS "$XT_DIR/$o.conf" | sed -E 's/[0-9]+=//g'),$(xt_get LHPORT "$XT_DIR/$o.conf")"
  done
  gp=$(xt_get PORTS "$g")
  if [ "$(xt_get ROLE "$g")" = iran ] && [ -n "$gp" ] && [ "$gp" != all ]; then
    local IFS=,
    for p in $P_PORTS; do port_overlap "$p" "$gp" >/dev/null ||
      echo "[i] GRE tunnel $n does not send port $p: while it is not on the encrypted tunnel, it is not forwarded"; done
    unset IFS
  elif [ "$(xt_get ROLE "$g")" != iran ]; then
    echo "[i] there is no GRE tunnel $n on this server: ports not moved to the encrypted tunnel are not forwarded"
  fi
  # local ports are not taken from the ports GRE forwards
  gp=""
  for f in /etc/gre-tunnel/*.conf; do p=$(xt_get PORTS "$f"); valid_ports "$p" && gp+="${gp:+,}$p"; done
  xt_install_files iran
  xt_bin || exit 1
  # the same local ports as before for ports that stay, so open connections keep working
  o_lports=$(xt_get LPORTS "$c"); o_lhport=$(xt_get LHPORT "$c"); o_on=$(xt_get ON "$c")
  used+=",$(sed -E 's/[0-9]+=//g' <<< "$o_lports"),$o_lhport"
  local IFS=,
  for p in $P_PORTS; do
    lp=""
    for o in $o_lports; do [ "${o%%=*}" = "$p" ] && lp=${o#*=}; done
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
  unset IFS
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
  xt_commit "$n" || exit 1
  sleep 2
  echo
  if /usr/local/sbin/xray-tunnel check "$n"; then :
  else
    echo "(check that option 7 ran on $foreign and its port $P_TPORT is open in any cloud firewall)"
    if [ -n "$on" ] && [ "$(ask "Ports $on are on the encrypted tunnel, which does not answer. Type yes to move them back to GRE")" = yes ]; then
      for p in ${on//,/ }; do /usr/local/sbin/xray-tunnel off "$n" "$p" >/dev/null; done
      on=""; echo "[*] moved back to GRE"
    fi
  fi
  echo
  if [ -n "$on" ]; then echo "Ports on the encrypted tunnel: $on (the others stay on GRE)"
  else echo "No port uses the encrypted tunnel yet: move one with option 8 (or: xray-tunnel on $n PORT)"; fi
}

xt_install() {
  local loc role n c
  echo "Encrypted tunnel (VLESS + WebSocket + TLS) next to GRE, for ports that GRE loses."
  echo "Install it on the FOREIGN server first, then on IRAN with the code it prints."
  echo "Select server location:"; echo "1 - IRAN"; echo "2 - FOREIGN"
  loc=$(ask "Enter 1 or 2")
  case "$loc" in 1) role=iran ;; 2) role=foreign ;; *) echo "invalid"; exit 1 ;; esac
  n=$(ask "Tunnel number (use the number of the GRE tunnel to the same foreign server)" 1)
  [[ $n =~ ^[1-9]$ ]] || { echo "tunnel number must be 1-9"; exit 1; }
  c=$XT_DIR/$n.conf
  if [ -f "$c" ] && [ "$(xt_get ROLE "$c")" != "$role" ]; then
    echo "encrypted tunnel $n on this server is the $(xt_get ROLE "$c") side; remove it first (option 9)"; exit 1; fi
  command -v ss >/dev/null && command -v base64 >/dev/null || { echo "missing: ss or base64"; exit 1; }
  if [ "$role" = iran ]; then xt_install_iran "$n"; else xt_install_foreign "$n"; fi
  echo "This menu is also saved on the server: run gre-install (works without GitHub)"
}

# asks which encrypted tunnel, when there is more than one
xt_pick() { local l; l=$(xt_confs)
  [ -n "$l" ] || { echo "no encrypted tunnel on this server (option 7 installs one)" >&2; return 1; }
  if [ "$(wc -l <<< "$l")" = 1 ]; then echo "$l"; return 0; fi
  l=$(ask "Encrypted tunnel number ($(paste -sd' ' <<< "$l"))")
  [[ $l =~ ^[1-9]$ ]] && [ -f "$XT_DIR/$l.conf" ] || { echo "no encrypted tunnel $l" >&2; return 1; }
  echo "$l"; }

xt_move() { local n c p on
  n=$(xt_pick) || return; c=$XT_DIR/$n.conf
  [ "$(xt_get ROLE "$c")" = iran ] || { echo "ports are moved on the Iran server"; return; }
  on=$(xt_get ON "$c")
  echo "Encrypted tunnel $n to $(xt_get REMOTE_IP "$c"): ports $(xt_get PORTS "$c")"
  echo "On the encrypted tunnel now: ${on:-none}"
  echo "1 - move a port to the encrypted tunnel"; echo "2 - move a port back to GRE"
  case "$(ask "Enter 1 or 2")" in
    1) p=$(ask "Port"); /usr/local/sbin/xray-tunnel on "$n" "$p" ;;
    2) p=$(ask "Port" "${on%%,*}"); /usr/local/sbin/xray-tunnel off "$n" "$p" ;;
    *) echo "invalid" ;;
  esac
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

xt_remove() { local n c on p cn
  n=$(xt_pick) || return; c=$XT_DIR/$n.conf
  on=$(xt_get ON "$c")
  if [ "$(xt_get ROLE "$c")" = iran ] && [ -n "$on" ]; then
    echo "[*] moving ports $on back to GRE first"
    local IFS=,; for p in $on; do /usr/local/sbin/xray-tunnel off "$n" "$p" >/dev/null; done; unset IFS
  fi
  cn=$(xt_conns "$n")
  if [ "$(xt_get ROLE "$c")" = foreign ]; then
    echo "Ports that the Iran server has on this tunnel stop working when it is removed: move them back"
    echo "to GRE on Iran first (option 8 there). $cn connections use it now."
    [ "$(ask "Type yes to remove it now")" = yes ] || { echo "not removed"; return; }
  elif [ "$cn" -gt 0 ]; then
    echo "$cn connections still use encrypted tunnel $n; removing it now cuts them (new connections already use GRE on Iran)."
    [ "$(ask "Type yes to remove it now, or anything else to wait")" = yes ] || { echo "not removed; run option 9 again later"; return; }
  fi
  xt_drop "$n"
  echo "Encrypted tunnel $n removed"
}

xt_status() { local n
  for n in $(xt_confs); do echo; /usr/local/sbin/xray-tunnel check "$n"; done
  [ -z "$(xt_confs)" ] || journalctl -t xray-tunnel -n 5 --no-pager 2>/dev/null
}

xt_diag() { local n
  for n in $(xt_confs); do
    echo "================ encrypted tunnel $n ================"
    /usr/local/sbin/xray-tunnel check "$n"
    "$XT_BIN" version 2>/dev/null | head -1
    journalctl -u "xray-tunnel@$n" -n 15 --no-pager 2>/dev/null
    journalctl -t xray-tunnel -n 10 --no-pager 2>/dev/null
  done
}

# new runtime, same settings; xray is restarted only if its settings changed (asked)
xt_update() { local n
  [ -n "$(xt_confs)" ] || return 0
  xt_install_files
  xt_bin || return 1
  for n in $(xt_confs); do xt_start "$n"; done
}

echo "===================================="
echo "   GRE Tunnel (optimized) Setup v$GRE_VERSION"
echo "===================================="
echo "1 - Install / update tunnel"
echo "2 - Remove tunnel"
echo "3 - Status"
echo "4 - Diagnose (why a tunnel does not work)"
echo "5 - Update scripts only (keep settings, no disconnect)"
echo "6 - Uninstall everything (remove all tunnels, restore the server)"
echo "7 - Encrypted tunnel (VLESS + WS + TLS): install or pair"
echo "8 - Encrypted tunnel: move a port to it, or back to GRE"
echo "9 - Encrypted tunnel: remove"
case "$(ask "Choose" 1)" in
  1) do_install ;; 2) do_remove ;; 3) do_status ;; 4) do_diag ;; 5) do_update ;; 6) do_uninstall ;;
  7) xt_install ;; 8) xt_move ;; 9) xt_remove ;; *) echo "invalid" ;;
esac
GRE_SELF_END
eval "$GRE_SELF"
