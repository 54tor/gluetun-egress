#!/bin/sh
# Gateway de sortie : failover par priorité (ou répartition, EGRESS_MODE) entre N Gluetun (VPN_IPS), fail-closed.
# L'application partage ce namespace (network_mode: service:gateway) : ses paquets sont
# du trafic local routé par la table "main" dont ce script contrôle la route par défaut.
set -eu

: "${APP_PORT:?}" "${LAN_SUBNET:?}" "${INGRESS_IP:?}" "${VPN_IPS:?}"
ALLOW_IN=${ALLOW_IN:-}
ALLOW_OUT=${ALLOW_OUT:-}
PROBE_URLS=${PROBE_URLS:-https://1.1.1.1/ https://8.8.8.8/ https://9.9.9.9/}
PROBE_URLS6=${PROBE_URLS6:-https://[2620:fe::fe]/ https://[2001:4860:4860::8888]/}
# IPv6 facultative : VPN_IPS6 liste, dans le même ordre que VPN_IPS, l'adresse IPv6 de chaque Gluetun (les N6 premiers
# seulement si certains VPN n'ont pas d'IPv6). Vide : aucune sortie IPv6, la table nftables la refuse.
VPN_IPS6=${VPN_IPS6:-}
LAN_SUBNET6=${LAN_SUBNET6:-fc00::/7}
# failover : un seul VPN porte la sortie (le premier en vie). balance-dest : répartition entre tous les VPN en vie,
# une destination gardant le même VPN. balance-flow : répartition par connexion (l'IP de sortie varie d'une connexion à l'autre).
EGRESS_MODE=${EGRESS_MODE:-failover}
PROBE_INTERVAL=${PROBE_INTERVAL:-5}
PROBE_INTERVAL_DOWN=${PROBE_INTERVAL_DOWN:-1}
PROBE_TIMEOUT=${PROBE_TIMEOUT:-4}
FAIL_THRESHOLD=${FAIL_THRESHOLD:-3}
RISE_THRESHOLD=${RISE_THRESHOLD:-3}
# Facultatif : RESTART_DEPENDENTS_<n> liste les conteneurs en network_mode service:<Gluetun n> à relancer quand ce
# Gluetun revient après une panne (ils restent « Up » sans réseau s'il a redémarré hors de Compose). Exige le socket.
# Facultatif : PORT_FORWARD_<n> nomme le conteneur du Gluetun n dont le port redirigé (NAT-PMP) est surveillé : absent
# PF_MISS_LIMIT contrôles de suite, il est relancé avec les conteneurs de RESTART_DEPENDENTS_<n> (watch-port-forward.sh). Exige le socket.
DOCKER_SOCKET=${DOCKER_SOCKET:-/var/run/docker.sock}
export DOCKER_SOCKET

# Ces valeurs finissent dans sed et nft : seuls les caractères d'une adresse ou d'un couple ip:port passent.
# `case` et non grep : grep valide ligne par ligne, une valeur sur plusieurs lignes passerait.
check() { case "$2" in *[!$3' ']*) echo "gateway: $1 contient des caractères invalides" >&2; exit 1 ;; esac; }
case "$EGRESS_MODE" in failover|balance-dest|balance-flow) ;; *) echo "gateway: EGRESS_MODE doit valoir failover, balance-dest ou balance-flow" >&2; exit 1 ;; esac
check ALLOW_IN "$ALLOW_IN" '0-9.:'
check ALLOW_OUT "$ALLOW_OUT" '0-9.:'
check VPN_IPS "$VPN_IPS" '0-9.'
check VPN_IPS6 "$VPN_IPS6" '0-9a-fA-F:'
check LAN_SUBNET "$LAN_SUBNET" '0-9./'
check LAN_SUBNET6 "$LAN_SUBNET6" '0-9a-fA-F:/'
check INGRESS_IP "$INGRESS_IP" '0-9.'
check APP_PORT "$APP_PORT" '-0-9'

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
. /usr/local/bin/probe-log.sh
. /usr/local/bin/probe.sh
. /usr/local/bin/tunnels-json.sh

restart_dependents() { # $1=n° du VPN revenu après une panne
	eval "names=\${RESTART_DEPENDENTS_$1:-}"
	for name in $names; do
		echo "$name" | grep -Eq '^[a-zA-Z0-9][a-zA-Z0-9_.-]*$' || { log "RESTART_DEPENDENTS_$1 : nom invalide ignoré"; continue; }
		[ -S "$DOCKER_SOCKET" ] || { log "socket Docker absent : $name non relancé"; continue; }
		code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 --unix-socket "$DOCKER_SOCKET" \
			-X POST "http://docker/containers/$name/restart" 2>/dev/null) || code=erreur
		log "vpn$1 revenu : relance de $name -> HTTP $code"
	done
}

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

# Hash du multipath (0 = adresses source et destination, 1 = ports compris) : /proc/sys est en lecture seule ici, il se
# pose par sysctls: du service (EGRESS_HASH_POLICY dans l'exemple). Sans effet en failover.
if [ "$EGRESS_MODE" = balance-flow ]; then hash_policy=1; else hash_policy=0; fi
if [ "$EGRESS_MODE" != failover ]; then
	for f in $FAMILIES; do
		[ "$(sysctl -n net.ipv$f.fib_multipath_hash_policy)" = "$hash_policy" ] \
			|| echo "gateway: net.ipv$f.fib_multipath_hash_policy devrait valoir $hash_policy pour $EGRESS_MODE (sysctls: du service)" >&2
	done
fi

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
		eval "ok${f}_$i=0 ko${f}_$i=0 up${f}_$i=0 down${f}_$i=0"
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
# La raison du dernier échec de chaque sonde : la sonde l'écrit, la boucle principale décide s'il faut la journaliser.
raisons_des_sondes=/run/probe-reasons
mkdir -p "$raisons_des_sondes"
# vpn-check.sh : la sonde de santé des Gluetun, livrée avec l'image et déposée dans le volume partagé à chaque
# démarrage (mv : un Gluetun ne lit jamais un fichier à moitié écrit).
cp /usr/local/share/gateway/vpn-check.sh /run/gateway/.vpn-check.sh.tmp
mv /run/gateway/.vpn-check.sh.tmp /run/gateway/vpn-check.sh

# /run/gateway/active : le VPN actif en IPv4 (contrat historique) ; active6 : celui de l'IPv6.
for f in $FAMILIES; do
	eval "active$f=none"
	echo none > "/run/gateway/active$([ "$f" = 6 ] && echo 6)"
done
# /run/gateway/up : tous les VPN « up » en IPv4 (vpn1 vpn2…), lu par vpn-check.sh pour ne jamais recycler le dernier.
: > /run/gateway/up

# Surveillance du port redirigé : un processus par Gluetun qui en a un (PORT_FORWARD_<n>), arrêté avec le gateway.
surveillances=""
i=0
for ip in $VPN_IPS; do
	i=$((i + 1))
	eval "gluetun_surveille=\${PORT_FORWARD_$i:-}"
	[ -n "$gluetun_surveille" ] || continue
	[ -S "$DOCKER_SOCKET" ] || { log "socket Docker absent : port redirigé de $gluetun_surveille non surveillé"; continue; }
	eval "dependants=\${RESTART_DEPENDENTS_$i:-}"
	sh /usr/local/bin/watch-port-forward.sh "$gluetun_surveille" $dependants &
	surveillances="$surveillances $!"
done

trap 'log "arrêt"; [ -z "$surveillances" ] || kill $surveillances 2>/dev/null; exit 0' TERM INT

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
		# failover : le premier VPN "up" dans l'ordre gagne ; balance-* : tous les VPN "up" ; par famille
		want=none want_ips= up_names= etats_des_tunnels=
		i=0
		for ip in $(ips_of $f); do
			i=$((i + 1))
			eval "pid=\$pid${f}_$i ok=\$ok${f}_$i ko=\$ko${f}_$i up=\$up${f}_$i down=\$down${f}_$i"
			if wait "$pid"; then ok=$((ok + 1)); ko=0; else ko=$((ko + 1)); ok=0; fi
			was_up=$up
			[ "$ok" -ge "$RISE_THRESHOLD" ] && up=1
			[ "$ko" -ge "$FAIL_THRESHOLD" ] && up=0
			[ "$was_up" = 1 ] && [ "$up" = 0 ] && down=1
			journaliser_etat_sonde "vpn$i" "$f" "$ip" "$was_up" "$up" "$ko" "$(cat "$raisons_des_sondes/vpn$i-v$f" 2>/dev/null)" "$(date +%s)"
			if [ "$f" = 4 ] && [ "$was_up" = 0 ] && [ "$up" = 1 ] && [ "$down" = 1 ]; then
				down=0
				restart_dependents "$i" &
			fi
			eval "ok${f}_$i=$ok ko${f}_$i=$ko up${f}_$i=$up down${f}_$i=$down"
			[ "$up" = 1 ] && up_names="$up_names vpn$i"
			etats_des_tunnels="$etats_des_tunnels vpn$i:$up"
			if [ "$up" = 1 ] && { [ -z "$want_ips" ] || [ "$EGRESS_MODE" != failover ]; }; then
				want_ips="$want_ips $ip"
				if [ "$want" = none ]; then want=vpn$i; else want="$want,vpn$i"; fi
			fi
		done

		[ "$f" = 4 ] && echo "$up_names" > /run/gateway/up
		if [ "$f" = 4 ]; then
			ecrire_etat_tunnels /run/gateway/tunnels.json /run/gateway-measure "$etats_des_tunnels" "$(date +%s)" || log "tunnels.json non écrit"
		fi
		# idempotent, rejoué à chaque cycle (auto-réparation si la route a été modifiée)
		if [ "$want" = none ]; then
			ipf $f route replace unreachable default
		elif [ "$EGRESS_MODE" = failover ]; then
			ipf $f route replace default via $want_ips dev eth0
		else
			nexthops_args=
			for ip in $want_ips; do nexthops_args="$nexthops_args nexthop via $ip dev eth0 weight 1"; done
			ipf $f route replace default $nexthops_args
		fi
		eval "active=\$active$f"
		if [ "$want" != "$active" ]; then
			eval "active$f=$want"
			echo "$want" > "/run/gateway/active$([ "$f" = 6 ] && echo 6)"
			[ "$f" = 4 ] && [ "$want" != none ] && set_dns $want_ips
			log "sortie IPv$f active -> $want"
		fi
	done

	# Sans aucun VPN validé, on resonde vite : la première sortie n'attend pas RISE_THRESHOLD × PROBE_INTERVAL.
	if [ "$active4" = none ]; then attente=$PROBE_INTERVAL_DOWN; else attente=$PROBE_INTERVAL; fi
	sleep "$attente" & wait $!
done
