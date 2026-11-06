#!/bin/sh
# Bring up the WireGuard tunnel described by $WG_CONF as wg0, make it the
# only way out of this container, then run Tor as an unprivileged user.
#
# After this script, the main routing table holds the container's own
# subnet (so gwproxy and the host can reach the SOCKS ports), a host
# route to each WireGuard endpoint via the Docker gateway, and a default
# route through wg0. There is no other default route: if wg0 goes away,
# traffic has nowhere to go instead of leaking out of eth0.
#
# Environment:
#   WG_CONF          WireGuard config (wg-quick format)  [/etc/gwtor/wg.conf]
#   WG_DNS           resolvers to use when the config has no DNS line,
#                    reached through the tunnel                 [1.1.1.1]
#   TOR_SOCKS_PORTS  first-last SOCKS port range              [8000-8009]
#   TOR_SOCKS_ACCEPT CIDRs allowed to use the SOCKS ports  [10.185.100.0/24]
#   TOR_EXTRA_CONF   extra lines appended to the generated torrc       []

set -eu

WG_CONF=${WG_CONF:-/etc/gwtor/wg.conf}
WG_DNS=${WG_DNS:-1.1.1.1}
TOR_SOCKS_PORTS=${TOR_SOCKS_PORTS:-8000-8009}
TOR_SOCKS_ACCEPT=${TOR_SOCKS_ACCEPT:-10.185.100.0/24}
TOR_EXTRA_CONF=${TOR_EXTRA_CONF:-}
IFACE=wg0
RUN_DIR=/run/gwtor
TOR_DATA=/var/lib/tor

log() { printf 'gwtor: %s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

[ -r "$WG_CONF" ] || die "cannot read $WG_CONF"

# Values of one key in the [Interface] (or [Peer]) sections, comma and
# space separated, one per line. Comments and blank lines are skipped.
conf_values() {
	awk -v sect="$1" -v key="$2" '
		{ sub(/#.*/, ""); gsub(/^[ \t]+|[ \t]+$/, "") }
		/^\[/ { cur = tolower($0); next }
		cur == "[" tolower(sect) "]" {
			i = index($0, "=")
			if (i == 0) next
			k = substr($0, 1, i - 1); v = substr($0, i + 1)
			gsub(/[ \t]/, "", k)
			if (tolower(k) != tolower(key)) next
			n = split(v, a, /[ \t,]+/)
			for (j = 1; j <= n; j++) if (a[j] != "") print a[j]
		}' "$WG_CONF"
}

# Tor, running unprivileged, reads its torrc from here, but the stripped
# WireGuard config holds the private key and stays root's alone.
mkdir -p "$RUN_DIR"
chmod 0755 "$RUN_DIR"

# wg(8) does not know the wg-quick only keys; strip them.
(umask 077; awk '
	{ line = $0; k = $0; sub(/#.*/, "", k); sub(/=.*/, "", k)
	  gsub(/[ \t]/, "", k); k = tolower(k) }
	k ~ /^(address|dns|mtu|table|preup|postup|predown|postdown|saveconfig)$/ { next }
	{ print line }' "$WG_CONF" > "$RUN_DIR/wg.conf")

ADDRS=$(conf_values Interface Address)
DNS=$(conf_values Interface DNS)
MTU=$(conf_values Interface MTU | head -n 1)
ENDPOINTS=$(conf_values Peer Endpoint)
[ -n "$ADDRS" ] || die "$WG_CONF has no Address"
[ -n "$ENDPOINTS" ] || die "$WG_CONF has no peer Endpoint"

GW=$(ip -4 route show default | awk '{ print $3; exit }')
GW_DEV=$(ip -4 route show default | awk '{ print $5; exit }')
[ -n "$GW" ] || die "no default route to reach the WireGuard endpoint"

# Resolve the endpoints now, while the Docker resolver is still reachable.
EP_ADDRS=
for ep in $ENDPOINTS; do
	host=${ep%:*}
	case "$host" in
	\[*\]) die "IPv6 endpoint $ep: the gwtor network is IPv4 only" ;;
	esac
	addr=$(getent ahostsv4 "$host" | awk '{ print $1; exit }')
	[ -n "$addr" ] || die "cannot resolve endpoint $host"
	EP_ADDRS="$EP_ADDRS $addr"
done

# IPv6 is off in containers on an IPv4-only network; the compose file
# turns it back on so the tunnel's IPv6 address and route can be set.
HAVE_V6=0
if [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1)" = 0 ]; then
	HAVE_V6=1
fi

ip link del "$IFACE" 2>/dev/null || true
ip link add "$IFACE" type wireguard
wg setconf "$IFACE" "$RUN_DIR/wg.conf"
for a in $ADDRS; do
	case "$a" in
	*:*)
		if [ "$HAVE_V6" = 1 ]; then
			ip -6 addr add "$a" dev "$IFACE"
		else
			log "IPv6 disabled, skipping address $a"
		fi ;;
	*)	ip -4 addr add "$a" dev "$IFACE" ;;
	esac
done
ip link set dev "$IFACE" mtu "${MTU:-1420}" up

for addr in $EP_ADDRS; do
	ip -4 route replace "$addr/32" via "$GW" dev "$GW_DEV"
done
ip -4 route del default
ip -4 route add default dev "$IFACE"
if [ "$HAVE_V6" = 1 ]; then
	ip -6 route del default 2>/dev/null || true
	ip -6 route add default dev "$IFACE"
fi
# shellcheck disable=SC2086 # split the list on purpose
log "$IFACE up: addresses $(printf "%s " $ADDRS)endpoints$EP_ADDRS via $GW"

# Resolve through the tunnel, not through Docker's resolver, which
# would forward the queries out of the host's own connection.
[ -n "$DNS" ] || DNS=$(echo "$WG_DNS" | tr -s ', ' '\n')
: > "$RUN_DIR/resolv.conf"
for d in $DNS; do
	case "$d" in
	*[!0-9a-fA-F.:]*) log "ignoring DNS search domain $d" ;;
	*) echo "nameserver $d" >> "$RUN_DIR/resolv.conf" ;;
	esac
done
cat "$RUN_DIR/resolv.conf" > /etc/resolv.conf

first=${TOR_SOCKS_PORTS%-*}
last=${TOR_SOCKS_PORTS#*-}
TORRC=$RUN_DIR/torrc
{
	echo "DataDirectory $TOR_DATA"
	echo "GeoIPFile /usr/local/share/tor/geoip"
	echo "GeoIPv6File /usr/local/share/tor/geoip6"
	echo "Log notice stdout"
	echo "Log notice file $TOR_DATA/notices.log"
	# Streams on different SOCKS ports never share a circuit.
	p=$first
	while [ "$p" -le "$last" ]; do
		echo "SocksPort 0.0.0.0:$p"
		p=$((p + 1))
	done
	echo "SocksPolicy accept 127.0.0.0/8"
	for c in $(echo "$TOR_SOCKS_ACCEPT" | tr ',' ' '); do
		echo "SocksPolicy accept $c"
	done
	echo "SocksPolicy reject *"
	echo "SocksPolicy reject6 *"
	if [ "$HAVE_V6" = 1 ]; then
		echo "ClientUseIPv6 1"
	fi
	[ -z "$TOR_EXTRA_CONF" ] || printf '%s\n' "$TOR_EXTRA_CONF"
} > "$TORRC"
chmod 0644 "$TORRC"

chown -R tor:tor "$TOR_DATA"
chmod 0700 "$TOR_DATA"
# The healthcheck looks for "Bootstrapped 100%" from this run only.
: > "$TOR_DATA/notices.log"
chown tor:tor "$TOR_DATA/notices.log"

exec setpriv --reuid=tor --regid=tor --init-groups \
	--inh-caps=-all --bounding-set=-all \
	/usr/local/bin/tor -f "$TORRC" "$@"
