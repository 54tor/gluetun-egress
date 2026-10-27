#!/bin/sh
# Sonde de santé Docker d'un Gluetun : la sonde native, puis, une fois par serveur, latence, débit et
# joignabilité à travers le tunnel. Un serveur recalé est remplacé (Gluetun en retire un au hasard dans
# son filtre) jusqu'à VPN_CHECK_MAX_REROLLS fois ; au-delà, le conteneur reste unhealthy.
#
# Exige le serveur de contrôle sur 127.0.0.1:8000 et le rôle de gluetun/auth.toml.

MIN_MBPS=${VPN_CHECK_MIN_MBPS:-20}
MAX_LATENCY_MS=${VPN_CHECK_MAX_LATENCY_MS:-300}
MAX_REROLLS=${VPN_CHECK_MAX_REROLLS:-8}
URLS=${VPN_CHECK_URLS:-https://www.google.com/generate_204 https://www.wikipedia.org/}
BYTES=${VPN_CHECK_BYTES:-10485760}
SPEED_URL=${VPN_CHECK_SPEED_URL:-https://proof.ovh.net/files/10Mb.dat}

STATE=/tmp/vpn-check
PASSED=$STATE.passed
TRIES=$STATE.tries

/gluetun-entrypoint healthcheck >/dev/null 2>&1 || { echo "tunnel indisponible"; exit 1; }

ip=$(cat /tmp/gluetun/ip 2>/dev/null)
[ -n "$ip" ] || { echo "IP publique pas encore connue"; exit 1; }
[ "$(cat $PASSED 2>/dev/null)" = "$ip" ] && exit 0

# /proc/uptime : la date de busybox ne donne pas les millisecondes.
now_ms() { awk '{ printf "%d", $1 * 1000 }' /proc/uptime; }

log() { echo "$*"; echo "[vpn-check] $ip : $*" >/proc/1/fd/1; }

reject() {
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
			--body-data="{\"status\":\"$status\"}" http://127.0.0.1:8000/v1/vpn/status
	done
	exit 1
}

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
[ $mbps -ge "$MIN_MBPS" ] || reject "débit ${mbps} Mbit/s < ${MIN_MBPS} Mbit/s"

log "validé : ${latency} ms, ${mbps} Mbit/s"
echo "$ip" >$PASSED
rm -f $TRIES
