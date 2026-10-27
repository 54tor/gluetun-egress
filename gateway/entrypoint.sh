#!/bin/sh
# Gateway de sortie : failover par priorité entre N Gluetun (VPN_IPS, le 1er est prioritaire), fail-closed.
# L'application partage ce namespace (network_mode: service:gateway) : ses paquets sont
# du trafic local routé par la table "main" dont ce script contrôle la route par défaut.
set -eu

: "${APP_PORT:?}" "${LAN_SUBNET:?}" "${INGRESS_IP:?}" "${VPN_IPS:?}"
ALLOW_IN=${ALLOW_IN:-}
ALLOW_OUT=${ALLOW_OUT:-}
PROBE_URLS=${PROBE_URLS:-https://9.9.9.9/ https://8.8.8.8/}
PROBE_URLS6=${PROBE_URLS6:-https://[2620:fe::fe]/ https://[2001:4860:4860::8888]/}
# IPv6 facultative : VPN_IPS6 liste, dans le même ordre que VPN_IPS, l'adresse IPv6 de chaque Gluetun (les N6 premiers
# seulement si certains VPN n'ont pas d'IPv6). Vide : aucune sortie IPv6, la table nftables la refuse.
VPN_IPS6=${VPN_IPS6:-}
LAN_SUBNET6=${LAN_SUBNET6:-fc00::/7}
PROBE_INTERVAL=${PROBE_INTERVAL:-5}
PROBE_TIMEOUT=${PROBE_TIMEOUT:-4}
FAIL_THRESHOLD=${FAIL_THRESHOLD:-3}
RISE_THRESHOLD=${RISE_THRESHOLD:-3}

# VPN n°i : sonde sous l'UID 64100+i, forcée (ip rule uidrange) dans la table 100+i -> SON Gluetun,
# indépendamment de la route active. UID hors des plages usuelles pour ne pas collider avec
# l'UID de l'application (le noyau voit les UID réels, sans user namespace).
UID_BASE=64100
FAMILIES=4
[ -z "$VPN_IPS6" ] || FAMILIES="4 6"

ips_of() { if [ "$1" = 6 ]; then echo $VPN_IPS6; else echo $VPN_IPS; fi; }
# ipf <famille> <args ip> : la commande ip dans la bonne famille
ipf() { f=$1; shift; if [ "$f" = 6 ]; then ip -6 "$@"; else ip "$@"; fi; }

log() { echo "$(date -Iseconds) gateway: $*"; }

# 1. Firewall AVANT toute route : fail-closed dès le départ.
#    ALLOW_IN / ALLOW_OUT : couples « ip:port » séparés par des espaces, mis en ensembles nftables.
#    Un ensemble vide s'écrit sans `elements` : nftables refuse `elements = { }`.
set_elements() {
	[ -n "$1" ] || return 0
	printf 'elements = { %s }' "$(echo $1 | sed 's/ /, /g; s/:/ . /g')"
}
set_elements6() {
	[ -n "$1" ] || return 0
	printf 'elements = { %s }' "$(echo $1 | sed 's/ /, /g')"
}
sed -e "s|# @ALLOW_IN@|$(set_elements "$ALLOW_IN")|" -e "s|# @ALLOW_OUT@|$(set_elements "$ALLOW_OUT")|" \
    -e "s|# @NEXTHOPS6@|$(set_elements6 "$VPN_IPS6")|" \
	/etc/gateway/rules.nft > /run/rules.nft
nft -D LAN="$LAN_SUBNET" -D LAN6="$LAN_SUBNET6" -D INGRESS="$INGRESS_IP" -D APP_PORT="$APP_PORT" \
    -D NEXTHOPS="{ $(echo $VPN_IPS | sed 's/ /, /g') }" -f /run/rules.nft

# 2. Aucune sortie tant qu'aucun VPN n'est validé (par famille).
for f in 4 6; do ipf $f route replace unreachable default 2>/dev/null || [ "$f" = 6 ]; done

# 3. Tables de sonde. Si une route disparaît (eth0 down), la règle 1999 empêche toute retombée
#    sur la table main (pas de faux positif via un autre VPN). Même UID et même numéro de table pour les deux
#    familles : les règles de routage IPv4 et IPv6 sont des jeux distincts.
for f in $FAMILIES; do
	ipf $f rule del priority 1999 2>/dev/null || true
	i=0
	for ip in $(ips_of $f); do
		i=$((i + 1))
		ipf $f route replace default via "$ip" dev eth0 table $((100 + i))
		ipf $f rule del priority $((1000 + i)) 2>/dev/null || true
		ipf $f rule add priority $((1000 + i)) uidrange $((UID_BASE + i))-$((UID_BASE + i)) lookup $((100 + i))
		eval "ok${f}_$i=0 ko${f}_$i=0 up${f}_$i=0"
	done
	ipf $f rule add priority 1999 uidrange $((UID_BASE + 1))-$((UID_BASE + i)) unreachable
done

# 4. DNS de l'application : même fichier que /etc/resolv.conf de l'app (Docker le partage en
#    network_mode container). Écriture en place (pas de rename) pour conserver le bind mount.
#    Au départ, tous les Gluetun (aucun n'est encore validé) ; ensuite le seul VPN actif (set_dns), pour que les
#    noms résolus n'aillent pas chez les fournisseurs inactifs. musl et glibc n'utilisent que les 3 premiers nameserver.
set_dns() { { for n in "$@"; do echo "nameserver $n"; done; echo "options timeout:2 attempts:2"; } > /etc/resolv.conf; }
set_dns $VPN_IPS

mkdir -p /run/gateway

probe() { # $1=uid $2=ip gluetun $3=nom $4=famille -> 0 si Internet joignable à travers CE tunnel
	rc=0
	if [ "$4" = 6 ]; then urls=$PROBE_URLS6 pingopt=-6; else urls=$PROBE_URLS pingopt=-4; fi
	for url in $urls; do
		# Pas de `-f` : toute réponse HTTP (même 404) prouve que le tunnel porte du trafic.
		# `-g` : sans globbing, les crochets d'une adresse IPv6 littérale restent une adresse.
		rc=0
		su-exec "$1:$1" curl -g -sS -o /dev/null --max-time "$PROBE_TIMEOUT" "$url" 2>/dev/null || rc=$?
		[ "$rc" = 0 ] && return 0
	done
	if ! ping $pingopt -c1 -W1 "$2" >/dev/null 2>&1; then
		log "$3 IPv$4 ($2) injoignable (conteneur arrêté ou réseau vpn-gateway)"
	elif [ "$rc" = 28 ]; then
		log "$3 IPv$4 ($2) joignable mais tunnel trop lent (aucune réponse en ${PROBE_TIMEOUT}s)"
	else
		log "$3 IPv$4 ($2) joignable mais aucune sortie Internet via son tunnel"
	fi
	return 1
}

# /run/gateway/active : le VPN actif en IPv4 (contrat historique) ; active6 : celui de l'IPv6.
for f in $FAMILIES; do
	eval "active$f=none"
	echo none > "/run/gateway/active$([ "$f" = 6 ] && echo 6)"
done

trap 'log "arrêt"; exit 0' TERM INT

while :; do
	# sondes en parallèle, familles comprises : la détection d'un VPN ne dépend pas des timeouts des autres
	for f in $FAMILIES; do
		i=0
		for ip in $(ips_of $f); do
			i=$((i + 1))
			probe $((UID_BASE + i)) "$ip" "vpn$i" "$f" &
			eval "pid${f}_$i=\$!"
		done
	done

	for f in $FAMILIES; do
		# le premier VPN "up" dans l'ordre gagne, indépendamment pour chaque famille
		want=none want_ip=
		i=0
		for ip in $(ips_of $f); do
			i=$((i + 1))
			eval "pid=\$pid${f}_$i ok=\$ok${f}_$i ko=\$ko${f}_$i up=\$up${f}_$i"
			if wait "$pid"; then ok=$((ok + 1)); ko=0; else ko=$((ko + 1)); ok=0; fi
			[ "$ok" -ge "$RISE_THRESHOLD" ] && up=1
			[ "$ko" -ge "$FAIL_THRESHOLD" ] && up=0
			eval "ok${f}_$i=$ok ko${f}_$i=$ko up${f}_$i=$up"
			if [ "$up" = 1 ] && [ "$want" = none ]; then want=vpn$i want_ip=$ip; fi
		done

		# idempotent, rejoué à chaque cycle (auto-réparation si la route a été modifiée)
		if [ "$want" = none ]; then
			ipf $f route replace unreachable default
		else
			ipf $f route replace default via "$want_ip" dev eth0
		fi
		eval "active=\$active$f"
		if [ "$want" != "$active" ]; then
			eval "active$f=$want"
			echo "$want" > "/run/gateway/active$([ "$f" = 6 ] && echo 6)"
			log "sortie IPv$f active -> $want"
		fi
	done

	sleep "$PROBE_INTERVAL" & wait $!
done
			[ "$f" = 4 ] && [ "$want" != none ] && set_dns "$want_ip"
