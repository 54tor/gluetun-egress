# shellcheck shell=sh
# Sonde d'un VPN. Source de entrypoint.sh, qui fournit PROBE_URLS, PROBE_URLS6, PROBE_TIMEOUT et raisons_des_sondes.

# Deux essais : un paquet ICMP perdu ne doit pas compter comme une panne.
gluetun_repond_au_ping() { # $1=famille $2=ip gluetun
	ping "-$1" -c1 -W1 "$2" >/dev/null 2>&1 || ping "-$1" -c1 -W1 "$2" >/dev/null 2>&1
}

probe() { # $1=uid $2=ip gluetun $3=nom $4=famille -> 0 si Internet joignable à travers CE tunnel
	if ! gluetun_repond_au_ping "$4" "$2"; then
		# Conteneur arrêté : inutile d'attendre le timeout de chaque URL, la panne est certaine.
		echo "injoignable (conteneur arrêté ou réseau vpn-gateway)" > "$raisons_des_sondes/$3-v$4"
		return 1
	fi
	if [ "$4" = 6 ]; then urls=$PROBE_URLS6; else urls=$PROBE_URLS; fi
	rc=0
	for url in $urls; do
		# Pas de `-f` : toute réponse HTTP (même 404) prouve que le tunnel porte du trafic.
		# `-g` : sans globbing, les crochets d'une adresse IPv6 littérale restent une adresse.
		rc=0
		su-exec "$1:$1" curl -g -sS -o /dev/null --max-time "$PROBE_TIMEOUT" "$url" 2>/dev/null || rc=$?
		[ "$rc" = 0 ] && return 0
	done
	if [ "$rc" = 28 ]; then
		echo "joignable mais tunnel trop lent (aucune réponse en ${PROBE_TIMEOUT}s)" > "$raisons_des_sondes/$3-v$4"
	else
		echo "joignable mais aucune sortie Internet via son tunnel" > "$raisons_des_sondes/$3-v$4"
	fi
	return 1
}
