#!/bin/bash
# Optimized GRE tunnel (based on vatanhost/gre): survives reboots, forwards
# only the ports you choose, MSS clamping, self-repairing watchdog.
set -u
GRE_VERSION=2.2.0
[ "$(id -u)" = 0 ] || { echo "Run as root"; exit 1; }
if ! command -v ping >/dev/null && command -v apt-get >/dev/null; then
  echo "[*] installing iputils-ping"; apt-get install -y -qq iputils-ping >/dev/null 2>&1
fi
for c in ip iptables systemctl ping; do command -v $c >/dev/null || { echo "missing: $c"; exit 1; }; done

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

install_files() {
  mkdir -p /etc/gre-tunnel
  cat > /usr/local/sbin/gre-tunnel <<'RUNTIME'
#!/bin/bash
# GRE tunnel runtime. Usage: gre-tunnel up|down|check|diag|watchdog <N>
# Settings for tunnel N live in /etc/gre-tunnel/<N>.conf
set -u
VERSION=2.2.0
CMD=${1:-}; N=${2:-}
if [ "$CMD" = version ]; then echo "gre-tunnel $VERSION"; exit 0; fi
CONF=/etc/gre-tunnel/$N.conf
if [ -z "$N" ] || [ ! -f "$CONF" ]; then echo "usage: gre-tunnel up|down|check|diag|watchdog <N>  (missing $CONF)"; exit 1; fi
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
  if [ "$ROLE" = iran ]; then tune_conntrack; fi
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
    if tcp_probe 9 || tcp_probe 22; then tcp=ok; echo "tcp to $PEER_TIP: ok (the other server only ignores ping)"
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
check() {
  ping -c 3 -W 2 -q "$PEER_TIP" >/dev/null 2>&1 && return 0
  tcp_probe 9 || tcp_probe 22
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
  echo
  if [ "$ROLE" = iran ]; then
    echo "Done. Iran tunnel IP 10.200.$n.2, foreign 10.200.$n.1, forwarding: $ports (SSH kept: $ssh)"
  else
    echo "Done. Foreign tunnel IP 10.200.$n.1, Iran 10.200.$n.2, accepting from tunnel: $ports"
  fi
  sleep 2; /usr/local/sbin/gre-tunnel check "$n" || echo "(normal if the other side is not installed yet)"
}

do_remove() {
  local n; n=$(ask "Tunnel number to remove" 1)
  systemctl disable --now "gre-watchdog@$n.timer" 2>/dev/null
  systemctl stop "gre-watchdog@$n.service" 2>/dev/null
  systemctl disable --now "gre-tunnel@$n" 2>/dev/null
  rm -f "/etc/gre-tunnel/$n.conf"
  echo "Tunnel $n removed"
}

# new scripts, same settings; applied in place so no user is disconnected
do_update() {
  local f n
  install_files
  for f in /etc/gre-tunnel/*.conf; do
    [ -e "$f" ] || { echo "no tunnels installed; choose 1 to install"; return; }
    n=$(basename "$f" .conf)
    /usr/local/sbin/gre-tunnel up "$n"
    systemctl enable -q "gre-tunnel@$n" "gre-watchdog@$n.timer" 2>/dev/null
  done
  echo "Updated to v$GRE_VERSION (settings kept, connections not interrupted)"
}

do_diag() {
  local f n
  for f in /etc/gre-tunnel/*.conf; do
    [ -e "$f" ] || { echo "no tunnels"; return; }
    n=$(basename "$f" .conf)
    echo "================ tunnel $n ================"
    /usr/local/sbin/gre-tunnel diag "$n"
  done
}

do_status() {
  local f n
  for f in /etc/gre-tunnel/*.conf; do
    [ -e "$f" ] || { echo "no tunnels"; return; }
    n=$(basename "$f" .conf)
    /usr/local/sbin/gre-tunnel check "$n"
  done
  journalctl -t gre-watchdog -n 10 --no-pager 2>/dev/null
}

echo "===================================="
echo "   GRE Tunnel (optimized) Setup v$GRE_VERSION"
echo "===================================="
echo "1 - Install / update tunnel"
echo "2 - Remove tunnel"
echo "3 - Status"
echo "4 - Diagnose (why a tunnel does not work)"
echo "5 - Update scripts only (keep settings, no disconnect)"
case "$(ask "Choose" 1)" in
  1) do_install ;; 2) do_remove ;; 3) do_status ;; 4) do_diag ;; 5) do_update ;; *) echo "invalid" ;;
esac
