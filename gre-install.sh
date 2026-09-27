#!/bin/bash
# Optimized GRE tunnel (based on vatanhost/gre): survives reboots,
# forwards only what it should, MSS clamping, auto-recovery watchdog.
set -u
[ "$(id -u)" = 0 ] || { echo "Run as root"; exit 1; }
for c in ip iptables systemctl; do command -v $c >/dev/null || { echo "missing: $c"; exit 1; }; done

valid_ip() { [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
ask() { local p=$1 d=${2:-} v; read -r -p "$p${d:+ [$d]}: " v; echo "${v:-$d}"; }
ipt_rm() { local t=$1; shift; while iptables -w -t "$t" -C "$@" 2>/dev/null; do iptables -w -t "$t" -D "$@"; done; }

remove_old_vatan() {
  # rules and interface created by the original vatanhost/gre script
  ipt_rm nat PREROUTING -p tcp --dport 22 -j DNAT --to-destination 132.168.30.2
  ipt_rm nat PREROUTING -j DNAT --to-destination 132.168.30.1
  ipt_rm nat POSTROUTING -j MASQUERADE
  ipt_rm filter INPUT -p icmp -j DROP
  ip link del vatan-m2 2>/dev/null && echo "[*] removed old vatan-m2 tunnel"
  true
}

install_files() {
  mkdir -p /etc/gre-tunnel
  cat > /usr/local/sbin/gre-tunnel <<'RUNTIME'
#!/bin/bash
# GRE tunnel runtime. Usage: gre-tunnel up|down|check|watchdog <N>
# Settings for tunnel N live in /etc/gre-tunnel/<N>.conf
set -u
CMD=${1:-}; N=${2:-}
CONF=/etc/gre-tunnel/$N.conf
if [ -z "$N" ] || [ ! -f "$CONF" ]; then echo "usage: gre-tunnel up|down|check|watchdog <N>  (missing $CONF)"; exit 1; fi
# shellcheck source=/dev/null
. "$CONF"   # ROLE LOCAL_IP REMOTE_IP PORTS SSH_PORT

IF=vgre$N
IRAN_TIP=10.200.$N.2
FOREIGN_TIP=10.200.$N.1
if [ "$ROLE" = iran ]; then MY_TIP=$IRAN_TIP; PEER_TIP=$FOREIGN_TIP
else MY_TIP=$FOREIGN_TIP; PEER_TIP=$IRAN_TIP; fi

ipt_add() { local t=$1 op=$2; shift 2
  iptables -w -t "$t" -C "$@" 2>/dev/null || iptables -w -t "$t" "$op" "$@"; }
ipt_del() { local t=$1; shift 2
  while iptables -w -t "$t" -C "$@" 2>/dev/null; do iptables -w -t "$t" -D "$@"; done; }

# Every rule this tunnel uses, applied with ipt_add or ipt_del
rules() { local f=$1
  $f filter -I INPUT -p gre -s "$REMOTE_IP" -j ACCEPT
  $f filter -I INPUT -i "$IF" -j ACCEPT
  $f filter -I FORWARD -i "$IF" -j ACCEPT
  $f filter -I FORWARD -o "$IF" -j ACCEPT
  $f mangle -A FORWARD -o "$IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
  $f mangle -A FORWARD -i "$IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
  if [ "$ROLE" = iran ]; then
    if [ "$PORTS" = all ]; then
      # everything except SSH; GRE and ICMP are never matched
      $f nat -A PREROUTING -d "$LOCAL_IP" -p tcp -m multiport ! --dports "$SSH_PORT" -j DNAT --to-destination "$PEER_TIP"
      $f nat -A PREROUTING -d "$LOCAL_IP" -p udp -j DNAT --to-destination "$PEER_TIP"
    else
      $f nat -A PREROUTING -d "$LOCAL_IP" -p tcp -m multiport --dports "$PORTS" -j DNAT --to-destination "$PEER_TIP"
      $f nat -A PREROUTING -d "$LOCAL_IP" -p udp -m multiport --dports "$PORTS" -j DNAT --to-destination "$PEER_TIP"
    fi
    $f nat -A POSTROUTING -o "$IF" -j MASQUERADE
  fi
}

up() {
  modprobe ip_gre 2>/dev/null
  ip link show "$IF" >/dev/null 2>&1 && ip link del "$IF"
  ip tunnel add "$IF" mode gre local "$LOCAL_IP" remote "$REMOTE_IP" ttl 255 || exit 1
  ip link set "$IF" mtu 1476 up
  ip addr replace "$MY_TIP/30" dev "$IF"
  sysctl -qw net.ipv4.ip_forward=1
  rules ipt_add
  echo "$IF up: $MY_TIP <-> $PEER_TIP"
}

down() {
  rules ipt_del
  ip link del "$IF" 2>/dev/null
  true
}

check() { ping -c 3 -W 2 -q "$PEER_TIP" >/dev/null 2>&1; }

watchdog() {
  local s=/run/gre-watchdog.$N
  if check; then rm -f "$s"; exit 0; fi
  local n=$(( $(cat "$s" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$s"
  if [ "$n" -ge 3 ]; then
    logger -t gre-watchdog "tunnel $N: $PEER_TIP unreachable $n times, restarting"
    rm -f "$s"; systemctl restart "gre-tunnel@$N"
  fi
}

case "$CMD" in
  up) up ;; down) down ;; watchdog) watchdog ;;
  check) if check; then echo "tunnel $N OK ($PEER_TIP reachable)"; else echo "tunnel $N DOWN"; exit 1; fi ;;
  *) echo "usage: gre-tunnel up|down|check|watchdog <N>"; exit 1 ;;
esac
RUNTIME
  chmod +x /usr/local/sbin/gre-tunnel

  cat > /etc/systemd/system/gre-tunnel@.service <<'UNIT'
[Unit]
Description=GRE tunnel %i
After=network-online.target
Wants=network-online.target

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
net.ipv4.ip_forward=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
SYS
  sysctl -q -p /etc/sysctl.d/99-gre-tunnel.conf
  echo ip_gre > /etc/modules-load.d/gre-tunnel.conf
  modprobe ip_gre
  systemctl daemon-reload
}

do_install() {
  echo "Select server location:"; echo "1 - IRAN"; echo "2 - FOREIGN"
  local loc; loc=$(ask "Enter 1 or 2")
  case "$loc" in 1) ROLE=iran ;; 2) ROLE=foreign ;; *) echo "invalid"; exit 1 ;; esac
  local n; n=$(ask "Tunnel number (1 = first foreign server, 2 = second, ...)" 1)
  [[ $n =~ ^[1-9]$ ]] || { echo "tunnel number must be 1-9"; exit 1; }
  local myip; myip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
  local iran foreign
  if [ "$ROLE" = iran ]; then
    iran=$(ask "Enter IRAN server IP" "$myip"); foreign=$(ask "Enter FOREIGN server IP")
  else
    iran=$(ask "Enter IRAN server IP"); foreign=$(ask "Enter FOREIGN server IP" "$myip")
  fi
  valid_ip "$iran" && valid_ip "$foreign" || { echo "invalid IP"; exit 1; }
  local ports=all ssh
  ssh=$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}'); ssh=${ssh:-22}
  if [ "$ROLE" = iran ]; then
    ports=$(ask "Ports to send to this foreign server, comma separated (e.g. 8388,2053), or 'all' = everything except SSH" all)
    [[ $ports == all || $ports =~ ^[0-9]+(,[0-9]+){0,14}$ ]] || { echo "invalid ports"; exit 1; }
    LOCAL_IP=$iran; REMOTE_IP=$foreign
  else
    LOCAL_IP=$foreign; REMOTE_IP=$iran
  fi

  remove_old_vatan
  install_files
  systemctl stop "gre-tunnel@$n" 2>/dev/null
  cat > "/etc/gre-tunnel/$n.conf" <<CONF
ROLE=$ROLE
LOCAL_IP=$LOCAL_IP
REMOTE_IP=$REMOTE_IP
PORTS=$ports
SSH_PORT=$ssh
CONF
  systemctl enable --now "gre-tunnel@$n" "gre-watchdog@$n.timer"
  echo
  if [ "$ROLE" = iran ]; then
    echo "Done. Iran tunnel IP 10.200.$n.2, foreign 10.200.$n.1, forwarding: $ports"
  else
    echo "Done. Foreign tunnel IP 10.200.$n.1, Iran 10.200.$n.2"
  fi
  echo "Test (after both sides are installed): gre-tunnel check $n"
}

do_remove() {
  local n; n=$(ask "Tunnel number to remove" 1)
  systemctl disable --now "gre-watchdog@$n.timer" "gre-tunnel@$n" 2>/dev/null
  rm -f "/etc/gre-tunnel/$n.conf"
  echo "Tunnel $n removed"
}

do_status() {
  for f in /etc/gre-tunnel/*.conf; do
    [ -e "$f" ] || { echo "no tunnels"; return; }
    local n; n=$(basename "$f" .conf)
    /usr/local/sbin/gre-tunnel check "$n"
  done
}

echo "===================================="
echo "   GRE Tunnel (optimized) Setup"
echo "===================================="
echo "1 - Install / update tunnel"
echo "2 - Remove tunnel"
echo "3 - Status"
case "$(ask "Choose" 1)" in
  1) do_install ;; 2) do_remove ;; 3) do_status ;; *) echo "invalid" ;;
esac
