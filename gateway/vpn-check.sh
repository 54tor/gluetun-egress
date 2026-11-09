#!/bin/sh
# Sonde de santé Docker d'un Gluetun : la sonde native, puis, une fois par serveur (ou toutes les
# VPN_CHECK_RECHECK_SECONDS si défini), latence, débit et
# joignabilité à travers le tunnel. Un serveur recalé est remplacé (Gluetun en retire un au hasard dans
# son filtre) jusqu'à VPN_CHECK_MAX_REROLLS fois ; au-delà, le conteneur reste unhealthy.
#
# Exige le serveur de contrôle sur 127.0.0.1:8000, protégé par la clé d'API VPN_CHECK_APIKEY (README §3.2.1).

MIN_MBPS=${VPN_CHECK_MIN_MBPS:-20}
MAX_LATENCY_MS=${VPN_CHECK_MAX_LATENCY_MS:-300}
MAX_REROLLS=${VPN_CHECK_MAX_REROLLS:-8}
URLS=${VPN_CHECK_URLS:-https://www.google.com/generate_204 https://www.wikipedia.org/}
BYTES=${VPN_CHECK_BYTES:-10485760}
SPEED_URL=${VPN_CHECK_SPEED_URL:-https://proof.ovh.net/files/10Mb.dat}
# 0 : un serveur validé n'est jamais retesté. Sinon, retest toutes les N secondes, tant qu'un autre tunnel est en vie.
RECHECK_SECONDS=${VPN_CHECK_RECHECK_SECONDS:-0}
TUNNEL_NAME=${VPN_CHECK_NAME:-}
GATEWAY_UP_FILE=/gateway-state/up
# Une IP recalée est recalée d'office, sans test, pendant ce délai (0 : aucune mémoire).
BAD_TTL_SECONDS=${VPN_CHECK_BAD_TTL_SECONDS:-86400}
# http : un téléchargement de VPN_CHECK_BYTES. ookla : speedtest d'Ookla (latence et débit), lourd : voir le README.
ENGINE=${VPN_CHECK_ENGINE:-http}
# L'acceptation de la licence d'Ookla est un acte de l'utilisateur : sans « yes », le moteur ookla recale tout serveur.
OOKLA_ACCEPT_LICENSE=${VPN_CHECK_OOKLA_ACCEPT_LICENSE:-no}
# Le CLI d'Ookla n'est pas dans l'image (binaire non redistribuable) : téléchargé une fois, par le tunnel validé, et gardé dans /tmp.
OOKLA_VERSION=${VPN_CHECK_OOKLA_VERSION:-1.2.0}
OOKLA_URL=${VPN_CHECK_OOKLA_URL:-https://install.speedtest.net/app/cli/ookla-speedtest-$OOKLA_VERSION-linux-x86_64.tgz}
# Après un échec de téléchargement ou de contrôle, on ne retente qu'après ce délai (la mesure retombe sur http entre-temps).
OOKLA_RETRY_SECONDS=${VPN_CHECK_OOKLA_RETRY_SECONDS:-3600}
SPEEDTEST_DIR=/tmp/vpn-check-speedtest
SPEEDTEST_BIN=$SPEEDTEST_DIR/speedtest
SPEEDTEST_TIMEOUT_SECONDS=${VPN_CHECK_OOKLA_TIMEOUT:-50}

STATE=/tmp/vpn-check
BAD=$STATE.bad
PASSED=$STATE.passed
PASSED_AT=$STATE.passed_at
TRIES=$STATE.tries

/gluetun-entrypoint healthcheck >/dev/null 2>&1 || { echo "tunnel indisponible"; exit 1; }

ip=$(cat /tmp/gluetun/ip 2>/dev/null)
[ -n "$ip" ] || { echo "IP publique pas encore connue"; exit 1; }

# Le gateway publie dans GATEWAY_UP_FILE les tunnels en vie. Sans fichier lisible ou sans nom de tunnel,
# on ne peut pas prouver qu'un autre tunnel prend le relais : pas de retest, donc jamais de coupure.
another_tunnel_is_up() {
	[ -n "$TUNNEL_NAME" ] || return 1
	for up_tunnel_name in $(cat "$GATEWAY_UP_FILE" 2>/dev/null); do
		[ "$up_tunnel_name" != "$TUNNEL_NAME" ] && return 0
	done
	return 1
}

validation_is_still_valid() {
	[ "$(cat $PASSED 2>/dev/null)" = "$ip" ] || return 1
	[ "$RECHECK_SECONDS" -gt 0 ] || return 0
	validation_age_seconds=$(( $(date +%s) - $(cat $PASSED_AT 2>/dev/null || echo 0) ))
	[ "$validation_age_seconds" -ge "$RECHECK_SECONDS" ] || return 0
	another_tunnel_is_up || return 0
	return 1
}

validation_is_still_valid && exit 0

# /proc/uptime : la date de busybox ne donne pas les millisecondes.
now_ms() { awk '{ printf "%d", $1 * 1000 }' /proc/uptime; }

log() { echo "$*"; echo "[vpn-check] $ip : $*" >/proc/1/fd/1; }

ip_is_recently_bad() {
	[ -f "$BAD" ] || return 1
	now_seconds=$(date +%s)
	while read -r bad_ip bad_at; do
		[ "$bad_ip" = "$ip" ] && [ $(( now_seconds - bad_at )) -lt "$BAD_TTL_SECONDS" ] && return 0
	done <"$BAD"
	return 1
}

# Réécrit le fichier sans les entrées périmées ni celle de cette IP, puis y ajoute cette IP.
remember_bad_ip() {
	now_seconds=$(date +%s)
	{
		[ -f "$BAD" ] && while read -r bad_ip bad_at; do
			[ "$bad_ip" != "$ip" ] && [ $(( now_seconds - bad_at )) -lt "$BAD_TTL_SECONDS" ] && echo "$bad_ip $bad_at"
		done <"$BAD"
		echo "$ip $now_seconds"
	} >"$BAD.tmp" && mv "$BAD.tmp" "$BAD"
}

reject() {
	# Un recalage d'office garde la date du recalage d'origine : sinon l'IP n'expirerait jamais.
	ip_is_recently_bad || remember_bad_ip
	tries=$(( $(cat $TRIES 2>/dev/null || echo 0) + 1 ))
	echo $tries >$TRIES
	if [ $tries -gt "$MAX_REROLLS" ]; then
		log "recalé ($1), $MAX_REROLLS serveurs essayés : on garde celui-ci, nouveau cycle au prochain contrôle"
		rm -f $TRIES
		exit 1
	fi
	log "recalé ($1), changement de serveur ($tries/$MAX_REROLLS)"
	for status in stopped running; do
		wget -q -T 10 -O /dev/null --method=PUT --header='Content-Type: application/json' \
			--header="X-API-Key: $VPN_CHECK_APIKEY" --body-data="{\"status\":\"$status\"}" http://127.0.0.1:8000/v1/vpn/status
	done
	exit 1
}

ip_is_recently_bad && reject "déjà recalé il y a moins de ${BAD_TTL_SECONDS} s"

# Renseigne latency (ms) et mbps. Ookla : bandwidth est en octets par seconde, ping.latency en millisecondes.
measure_with_http() {
	t0=$(now_ms)
	wget -q -T 5 -O /dev/null https://9.9.9.9/ || reject "9.9.9.9 muet"
	latency=$(( $(now_ms) - t0 ))
	[ $latency -le "$MAX_LATENCY_MS" ] || reject "latence ${latency} ms > ${MAX_LATENCY_MS} ms"

	for url in $URLS; do
		wget -q -T 10 -O /dev/null "$url" || reject "$url muet"
	done

	t0=$(now_ms)
	wget -q -T 20 -O /dev/null "$SPEED_URL" || reject "téléchargement en échec"
	elapsed=$(( $(now_ms) - t0 + 1 ))
	mbps=$(( BYTES * 8 / elapsed / 1000 ))
}

measure_with_ookla() {
	[ "$OOKLA_ACCEPT_LICENSE" = yes ] || reject "licence Ookla non acceptée (VPN_CHECK_OOKLA_ACCEPT_LICENSE=yes)"
	[ -x "$SPEEDTEST_BIN" ] || reject "binaire speedtest absent de /gateway-state"

	wget -q -T 5 -O /dev/null https://9.9.9.9/ || reject "9.9.9.9 muet"
	for url in $URLS; do
		wget -q -T 10 -O /dev/null "$url" || reject "$url muet"
	done

	speedtest_json=$(timeout "$SPEEDTEST_TIMEOUT_SECONDS" "$SPEEDTEST_BIN" --accept-license --accept-gdpr -f json 2>/dev/null | tr -d '\n') \
		|| reject "speedtest Ookla en échec"
	latency=$(echo "$speedtest_json" | sed -n 's/.*"ping":{[^}]*"latency":\([0-9]*\).*/\1/p')
	download_bytes_per_second=$(echo "$speedtest_json" | sed -n 's/.*"download":{"bandwidth":\([0-9]*\).*/\1/p')
	[ -n "$latency" ] && [ -n "$download_bytes_per_second" ] || reject "sortie speedtest Ookla illisible"
	mbps=$(( download_bytes_per_second * 8 / 1000000 ))
	[ $latency -le "$MAX_LATENCY_MS" ] || reject "latence ${latency} ms > ${MAX_LATENCY_MS} ms"
}

if [ "$ENGINE" = ookla ]; then measure_with_ookla; else measure_with_http; fi
[ $mbps -ge "$MIN_MBPS" ] || reject "débit ${mbps} Mbit/s < ${MIN_MBPS} Mbit/s"

log "validé : ${latency} ms, ${mbps} Mbit/s"
echo "$ip" >$PASSED
date +%s >$PASSED_AT
rm -f $TRIES
