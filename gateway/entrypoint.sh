#!/bin/sh
# Gateway de sortie : failover par priorité entre N Gluetun (VPN_IPS, le 1er est prioritaire), fail-closed.
# L'application partage ce namespace (network_mode: service:gateway) : ses paquets sont
# du trafic local routé par la table "main" dont ce script contrôle la route par défaut.
set -eu

: "${APP_PORT:?}" "${LAN_SUBNET:?}" "${INGRESS_IP:?}" "${VPN_IPS:?}"
ALLOW_IN=${ALLOW_IN:-}
ALLOW_OUT=${ALLOW_OUT:-}
PROBE_URLS=${PROBE_URLS:-https://9.9.9.9/ https://8.8.8.8/}
PROBE_INTERVAL=${PROBE_INTERVAL:-5}
PROBE_TIMEOUT=${PROBE_TIMEOUT:-4}
FAIL_THRESHOLD=${FAIL_THRESHOLD:-3}
RISE_THRESHOLD=${RISE_THRESHOLD:-3}

# VPN n°i : sonde sous l'UID 64100+i, forcée (ip rule uidrange) dans la table 100+i -> SON Gluetun,
# indépendamment de la route active. UID hors des plages usuelles pour ne pas collider avec
# l'UID de l'application (le noyau voit les UID réels, sans user namespace).
UID_BASE=64100
N=$(echo $VPN_IPS | wc -w)

log() { echo "$(date -Iseconds) gateway: $*"; }

# 1. Firewall AVANT toute route : fail-closed dès le départ.
#    ALLOW_IN / ALLOW_OUT : couples « ip:port » séparés par des espaces, mis en ensembles nftables.
#    Un ensemble vide s'écrit sans `elements` : nftables refuse `elements = { }`.
set_elements() {
	[ -n "$1" ] || return 0
	printf 'elements = { %s }' "$(echo $1 | sed 's/ /, /g; s/:/ . /g')"
}
sed -e "s|# @ALLOW_IN@|$(set_elements "$ALLOW_IN")|" -e "s|# @ALLOW_OUT@|$(set_elements "$ALLOW_OUT")|" \
	/etc/gateway/rules.nft > /run/rules.nft
nft -D LAN="$LAN_SUBNET" -D INGRESS="$INGRESS_IP" -D APP_PORT="$APP_PORT" \
    -D NEXTHOPS="{ $(echo $VPN_IPS | sed 's/ /, /g') }" -f /run/rules.nft

# 2. Aucune sortie tant qu'aucun VPN n'est validé.
ip route replace unreachable default

# 3. Tables de sonde. Si une route disparaît (eth0 down), la règle 1999 empêche toute retombée
#    sur la table main (pas de faux positif via un autre VPN).
ip rule del priority 1999 2>/dev/null || true
i=0
for ip in $VPN_IPS; do
	i=$((i + 1))
	ip route replace default via "$ip" dev eth0 table $((100 + i))
	ip rule del priority $((1000 + i)) 2>/dev/null || true
	ip rule add priority $((1000 + i)) uidrange $((UID_BASE + i))-$((UID_BASE + i)) lookup $((100 + i))
	eval "ok$i=0 ko$i=0 up$i=0"
done
ip rule add priority 1999 uidrange $((UID_BASE + 1))-$((UID_BASE + N)) unreachable

# 4. DNS de l'application : même fichier que /etc/resolv.conf de l'app (Docker le partage en
#    network_mode container). Écriture en place (pas de rename) pour conserver le bind mount.
#    musl interroge les serveurs en parallèle ; glibc séquentiellement (timeout court).
#    musl et glibc n'utilisent que les 3 premiers nameserver.
{ for ip in $VPN_IPS; do echo "nameserver $ip"; done; echo "options timeout:2 attempts:2"; } > /etc/resolv.conf

mkdir -p /run/gateway

probe() { # $1=uid $2=ip gluetun $3=nom -> 0 si Internet joignable à travers CE tunnel
	for url in $PROBE_URLS; do
		if su-exec "$1:$1" curl -fsS -o /dev/null --max-time "$PROBE_TIMEOUT" "$url" 2>/dev/null; then
			return 0
		fi
	done
	if ping -c1 -W1 "$2" >/dev/null 2>&1; then
		log "$3 ($2) joignable mais aucune sortie Internet via son tunnel"
	else
		log "$3 ($2) injoignable (conteneur arrêté ou réseau vpn-gateway)"
	fi
	return 1
}

active=none
echo none > /run/gateway/active

trap 'log "arrêt"; exit 0' TERM INT

while :; do
	# sondes en parallèle : la détection d'un VPN ne dépend pas des timeouts des autres
	i=0
	for ip in $VPN_IPS; do
		i=$((i + 1))
		probe $((UID_BASE + i)) "$ip" "vpn$i" &
		eval "pid$i=\$!"
	done

	# le premier VPN "up" dans l'ordre de VPN_IPS gagne
	want=none want_ip=
	i=0
	for ip in $VPN_IPS; do
		i=$((i + 1))
		eval "pid=\$pid$i ok=\$ok$i ko=\$ko$i up=\$up$i"
		if wait "$pid"; then ok=$((ok + 1)); ko=0; else ko=$((ko + 1)); ok=0; fi
		[ "$ok" -ge "$RISE_THRESHOLD" ] && up=1
		[ "$ko" -ge "$FAIL_THRESHOLD" ] && up=0
		eval "ok$i=$ok ko$i=$ko up$i=$up"
		if [ "$up" = 1 ] && [ "$want" = none ]; then want=vpn$i want_ip=$ip; fi
	done

	# idempotent, rejoué à chaque cycle (auto-réparation si la route a été modifiée)
	if [ "$want" = none ]; then
		ip route replace unreachable default
	else
		ip route replace default via "$want_ip" dev eth0
	fi
	if [ "$want" != "$active" ]; then
		active=$want
		echo "$active" > /run/gateway/active
		log "sortie active -> $active"
	fi

	sleep "$PROBE_INTERVAL" & wait $!
done
