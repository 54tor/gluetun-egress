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
# 1 : un serveur dont tun0 n'a pas d'adresse IPv6 globale est recalé (Linux retire l'IPv6 d'une interface dont le MTU, découvert
# par Gluetun, est sous 1280). 0 (défaut) : aucun contrôle, pour un fournisseur sans IPv6. À poser sur le Gluetun concerné.
REQUIRE_IPV6=${VPN_CHECK_REQUIRE_IPV6:-0}
GATEWAY_UP_FILE=/gateway-state/up
MEASURE_FILE=/gateway-measure/measure
# Une IP recalée est recalée d'office, sans test, pendant ce délai (0 : aucune mémoire).
BAD_TTL_SECONDS=${VPN_CHECK_BAD_TTL_SECONDS:-86400}
# http (défaut) : un téléchargement de VPN_CHECK_BYTES, aucun binaire tiers. ookla : speedtest d'Ookla (latence et débit montant), lourd : voir le README.
ENGINE=${VPN_CHECK_ENGINE:-http}
# « yes » accepte la licence d'Ookla (usage personnel et non commercial) ; « no » : la mesure retombe sur http.
OOKLA_ACCEPT_LICENSE=${VPN_CHECK_OOKLA_ACCEPT_LICENSE:-yes}
# Le CLI d'Ookla n'est pas dans l'image (binaire non redistribuable) : téléchargé une fois, par le tunnel validé, et gardé dans /tmp.
OOKLA_VERSION=${VPN_CHECK_OOKLA_VERSION:-1.2.0}
OOKLA_URL=${VPN_CHECK_OOKLA_URL:-https://install.speedtest.net/app/cli/ookla-speedtest-$OOKLA_VERSION-linux-x86_64.tgz}
# Somme SHA-256 de l'archive : sans elle, le binaire est refusé. Connue pour la 1.2.0 seulement ; pour une autre version, la fournir.
OOKLA_SHA256=${VPN_CHECK_OOKLA_SHA256:-}
[ -n "$OOKLA_SHA256" ] || [ "$OOKLA_VERSION" != 1.2.0 ] || OOKLA_SHA256=5690596c54ff9bed63fa3732f818a05dbc2db19ad36ed68f21ca5f64d5cfeeb7
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

# Le fichier de mesure survit à un changement de serveur (volume persistant) : tant que le nouveau n'est pas validé, il garde l'ancienne
# adresse publique, et un consommateur de tunnels.json en déduit un pays périmé. À chaque changement d'IP on le réécrit avec la nouvelle, sans mesure.
publish_ip_without_measure() {
	measured_ip=$(awk 'NR == 1 { print $4 }' "$MEASURE_FILE" 2>/dev/null)
	[ "$measured_ip" = "$ip" ] && return 0
	{ echo "- - - $ip" >"$MEASURE_FILE.tmp" && mv "$MEASURE_FILE.tmp" "$MEASURE_FILE"; } 2>/dev/null || true
}
publish_ip_without_measure

# Le gateway publie dans GATEWAY_UP_FILE les tunnels en vie. Sans fichier lisible ou sans nom de tunnel,
# on ne peut pas prouver qu'un autre tunnel prend le relais : pas de retest, donc jamais de coupure.
another_tunnel_is_up() {
	[ -n "$TUNNEL_NAME" ] || return 1
	for up_tunnel_name in $(cat "$GATEWAY_UP_FILE" 2>/dev/null); do
		[ "$up_tunnel_name" != "$TUNNEL_NAME" ] && return 0
	done
	return 1
}

# Vrai tant que le fichier de mesure n'a ni latence chiffrée ni l'IP courante (« - - - <ip> » ne compte pas comme une mesure).
measure_is_missing_for_this_ip() {
	! awk -v ip="$ip" 'NR == 1 { found = ($1 ~ /^[0-9]+$/ && $4 == ip) } END { exit !found }' "$MEASURE_FILE" 2>/dev/null
}

validation_is_still_valid() {
	[ "$(cat $PASSED 2>/dev/null)" = "$ip" ] || return 1
	# Une IP validée avant l'arrivée de la mesure n'en a aucune : on la mesure une fois, si un autre tunnel prend le relais.
	if measure_is_missing_for_this_ip && another_tunnel_is_up; then return 1; fi
	[ "$RECHECK_SECONDS" -gt 0 ] || return 0
	validation_age_seconds=$(( $(date +%s) - $(cat $PASSED_AT 2>/dev/null || echo 0) ))
	[ "$validation_age_seconds" -ge "$RECHECK_SECONDS" ] || return 0
	another_tunnel_is_up || return 0
	return 1
}

validation_is_still_valid && exit 0

# Démarrage rapide : le tunnel est déclaré sain dès que la sonde native passe, la mesure et les remplacements de serveur
# se font ensuite en tâche de fond (un remplacement coupe brièvement le tunnel : les dépendants sont relancés).
FAST_START=${VPN_CHECK_FAST_START:-1}
MEASURE_PID=$STATE.measure_pid
if [ "$FAST_START" = 1 ] && [ -z "$VPN_CHECK_IN_BACKGROUND" ]; then
	# BusyBox : « kill -0 "" » réussit, un fichier de PID absent ou vide doit donc être écarté avant.
	measure_pid=$(cat $MEASURE_PID 2>/dev/null)
	{ [ -n "$measure_pid" ] && kill -0 "$measure_pid" 2>/dev/null; } || {
		VPN_CHECK_IN_BACKGROUND=1 setsid sh "$0" >/dev/null 2>&1 </dev/null &
		echo $! >$MEASURE_PID
	}
	exit 0
fi

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

tunnel_has_ipv6() { ip -6 addr show dev tun0 2>/dev/null | grep -q 'inet6 .* scope global'; }

[ "$REQUIRE_IPV6" != 1 ] || tunnel_has_ipv6 || reject "tun0 sans IPv6 (MTU $(cat /sys/class/net/tun0/mtu 2>/dev/null || echo ?))"

ip_is_recently_bad && reject "déjà recalé il y a moins de ${BAD_TTL_SECONDS} s"

up_mbps=
# Renseigne latency (ms) et mbps ; up_mbps (Ookla seulement) reste vide quand la mesure HTTP n'envoie rien. Ookla : bandwidth est en octets par seconde, ping.latency en millisecondes.
measure_with_http() {
	t0=$(now_ms)
	wget -q -T 5 -O /dev/null https://1.1.1.1/cdn-cgi/trace || reject "1.1.1.1 muet"
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

# Contrôles du CLI Ookla téléchargé ($1 = archive, $2 = dossier d'extraction) : somme SHA-256 d'abord (Ookla n'en publie pas, la
# somme vient du paquet AUR et d'un téléchargement recoupé), puis taille, contenu de l'archive, en-tête ELF x86_64, version annoncée.
# 0 si le binaire est exploitable.
check_speedtest_archive() {
	if [ -z "$OOKLA_SHA256" ]; then
		log "CLI Ookla refusé : aucune somme SHA-256 pour la version $OOKLA_VERSION (VPN_CHECK_OOKLA_SHA256)"
		return 1
	fi
	received_sha256=$(sha256sum <"$1" | cut -d ' ' -f 1)
	if [ "$received_sha256" != "$OOKLA_SHA256" ]; then
		log "CLI Ookla refusé : somme SHA-256 reçue $received_sha256, attendue $OOKLA_SHA256"
		return 1
	fi
	size=$(wc -c <"$1")
	if [ "$size" -lt 500000 ] || [ "$size" -gt 30000000 ]; then
		log "CLI Ookla refusé : $size octets reçus, hors de 0,5 à 30 Mo"
		return 1
	fi
	members=$(tar -tzf "$1" 2>/dev/null)
	echo "$members" | grep -qx 'speedtest' || { log "CLI Ookla refusé : speedtest absent de l'archive"; return 1; }
	if echo "$members" | grep -qE '^/|(^|/)\.\.(/|$)'; then
		log "CLI Ookla refusé : chemin absolu ou « .. » dans l'archive"
		return 1
	fi
	tar -xzf "$1" -C "$2" speedtest 2>/dev/null
	{ [ -f "$2/speedtest" ] && [ ! -L "$2/speedtest" ]; } || { log "CLI Ookla refusé : speedtest n'est pas un fichier ordinaire"; return 1; }
	header=$(od -An -tx1 -N20 "$2/speedtest" | tr -d ' \n')
	if [ "$(echo "$header" | cut -c1-10)" != 7f454c4602 ] || [ "$(echo "$header" | cut -c37-40)" != 3e00 ]; then
		log "CLI Ookla refusé : ce n'est pas un exécutable ELF x86_64"
		return 1
	fi
	chmod 755 "$2/speedtest"
	version_line=$(timeout 10 "$2/speedtest" --version 2>/dev/null | head -n 1)
	echo "$version_line" | grep -q "Speedtest by Ookla $OOKLA_VERSION" || { log "CLI Ookla refusé : version annoncée « $version_line », attendue $OOKLA_VERSION"; return 1; }
}

# 0 si $SPEEDTEST_BIN est prêt. Le téléchargement passe par le tunnel (HTTPS, certificats vérifiés par wget, aucune redirection suivie),
# lu sur 30 Mo au plus et 30 s au plus.
fetch_speedtest() {
	[ -x "$SPEEDTEST_BIN" ] && return 0
	last_failure=$(cat "$SPEEDTEST_DIR.failed" 2>/dev/null || echo 0)
	[ $(( $(date +%s) - last_failure )) -ge "$OOKLA_RETRY_SECONDS" ] || return 1
	date +%s >"$SPEEDTEST_DIR.failed"
	case "$OOKLA_URL" in https://*) ;; *) log "CLI Ookla refusé : VPN_CHECK_OOKLA_URL doit être en https"; return 1 ;; esac
	[ "$(uname -m)" = x86_64 ] || { log "CLI Ookla : architecture $(uname -m), x86_64 seulement"; return 1; }
	fetch_dir=$(mktemp -d) || return 1
	timeout 30 wget -q -T 20 --max-redirect=0 -O - "$OOKLA_URL" 2>/dev/null | head -c 30000001 >"$fetch_dir/ookla.tgz"
	if check_speedtest_archive "$fetch_dir/ookla.tgz" "$fetch_dir" && mkdir -p "$SPEEDTEST_DIR" && mv "$fetch_dir/speedtest" "$SPEEDTEST_BIN"; then
		rm -f "$SPEEDTEST_DIR.failed"
		log "CLI Ookla $OOKLA_VERSION téléchargé et contrôlé"
	fi
	rm -rf "$fetch_dir"
	[ -x "$SPEEDTEST_BIN" ]
}

measure_with_ookla() {
	if ! fetch_speedtest; then
		log "CLI Ookla indisponible : mesure HTTP à la place"
		measure_with_http
		return
	fi

	for url in $URLS; do
		wget -q -T 10 -O /dev/null "$url" || reject "$url muet"
	done

	speedtest_json=$(timeout "$SPEEDTEST_TIMEOUT_SECONDS" "$SPEEDTEST_BIN" --accept-license --accept-gdpr -f json 2>/dev/null | tr -d '\n') \
		|| reject "speedtest Ookla en échec"
	latency=$(echo "$speedtest_json" | sed -n 's/.*"ping":{[^}]*"latency":\([0-9]*\).*/\1/p')
	download_bytes_per_second=$(echo "$speedtest_json" | sed -n 's/.*"download":{"bandwidth":\([0-9]*\).*/\1/p')
	upload_bytes_per_second=$(echo "$speedtest_json" | sed -n 's/.*"upload":{"bandwidth":\([0-9]*\).*/\1/p')
	[ -n "$latency" ] && [ -n "$download_bytes_per_second" ] || reject "sortie speedtest Ookla illisible"
	[ -z "$upload_bytes_per_second" ] || up_mbps=$(( upload_bytes_per_second * 8 / 1000000 ))
	mbps=$(( download_bytes_per_second * 8 / 1000000 ))
	[ $latency -le "$MAX_LATENCY_MS" ] || reject "latence ${latency} ms > ${MAX_LATENCY_MS} ms"
}

if [ "$ENGINE" = ookla ] && [ "$OOKLA_ACCEPT_LICENSE" != yes ]; then
	log "moteur ookla sans VPN_CHECK_OOKLA_ACCEPT_LICENSE=yes : mesure HTTP à la place"
	ENGINE=http
fi
if [ "$ENGINE" = ookla ]; then measure_with_ookla; else measure_with_http; fi
[ $mbps -ge "$MIN_MBPS" ] || reject "débit ${mbps} Mbit/s < ${MIN_MBPS} Mbit/s"

log "validé : ${latency} ms, ${mbps} Mbit/s${up_mbps:+, montant ${up_mbps} Mbit/s}"
# Mesure lue par le gateway (tunnels.json) dans le volume propre à ce tunnel ; sans ce volume, l'écriture échoue sans conséquence.
{ echo "$latency $mbps $(date +%s) $ip $up_mbps" >"$MEASURE_FILE.tmp" && mv "$MEASURE_FILE.tmp" "$MEASURE_FILE"; } 2>/dev/null || true
echo "$ip" >$PASSED
date +%s >$PASSED_AT
rm -f $TRIES
