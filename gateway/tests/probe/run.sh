#!/bin/sh
# Test de probe (probe.sh) avec ping, su-exec et curl simulés : un Gluetun muet au ping est déclaré en panne sans attendre
# le timeout des URLs ; un paquet ICMP perdu ne suffit pas à le déclarer mort ; la raison de l'échec est la bonne.
# Sortie : « OK <scénario> » ou « ECHEC <scénario> : <raison> » ; code de sortie 0 si tout passe.
set -u

dossier_du_test=$(cd "$(dirname "$0")" && pwd)
dossier_temporaire=$(mktemp -d)
trap 'rm -rf "$dossier_temporaire"' EXIT
nombre_echecs=0

mkdir "$dossier_temporaire/bin"
cat > "$dossier_temporaire/bin/ping" <<'STUB'
#!/bin/sh
echo x >> "$DOSSIER_STUBS/essais_ping"
essais=$(wc -l < "$DOSSIER_STUBS/essais_ping")
[ "$essais" -gt "$PING_ECHECS_AVANT_SUCCES" ]
STUB
cat > "$dossier_temporaire/bin/su-exec" <<'STUB'
#!/bin/sh
shift
exec "$@"
STUB
cat > "$dossier_temporaire/bin/curl" <<'STUB'
#!/bin/sh
for dernier_argument; do :; done
echo "$dernier_argument" >> "$DOSSIER_STUBS/urls_sondees"
exit "$CURL_CODE_DE_SORTIE"
STUB
chmod +x "$dossier_temporaire/bin/ping" "$dossier_temporaire/bin/su-exec" "$dossier_temporaire/bin/curl"

DOSSIER_STUBS=$dossier_temporaire
export DOSSIER_STUBS
PATH="$dossier_temporaire/bin:$PATH"
raisons_des_sondes=$dossier_temporaire/raisons
mkdir "$raisons_des_sondes"
# shellcheck disable=SC2034 # lues par probe.sh, sourcé juste après
PROBE_URLS="https://v4-a/ https://v4-b/"
# shellcheck disable=SC2034
PROBE_URLS6="https://[v6]/"
# shellcheck disable=SC2034
PROBE_TIMEOUT=4
# shellcheck disable=SC1091
. "$dossier_du_test/../../probe.sh"

lancer() { # $1=échecs du ping avant succès $2=code de sortie de curl $3=famille
	: > "$dossier_temporaire/essais_ping"
	: > "$dossier_temporaire/urls_sondees"
	rm -f "$raisons_des_sondes/vpn1-v$3"
	PING_ECHECS_AVANT_SUCCES=$1 CURL_CODE_DE_SORTIE=$2
	export PING_ECHECS_AVANT_SUCCES CURL_CODE_DE_SORTIE
	probe 1001 172.30.20.11 vpn1 "$3"
	code_de_retour=$?
	nombre_urls_sondees=$(grep -c . "$dossier_temporaire/urls_sondees")
	raison_obtenue=$(cat "$raisons_des_sondes/vpn1-v$3" 2>/dev/null)
}

verifier() { # $1=scénario $2=valeur attendue $3=valeur obtenue
	if [ "$2" = "$3" ]; then
		echo "OK $1"
	else
		echo "ECHEC $1 : attendu [$2], obtenu [$3]"
		nombre_echecs=$((nombre_echecs + 1))
	fi
}

lancer 99 0 4
verifier "A-muet-au-ping-echec" 1 "$code_de_retour"
verifier "A-muet-au-ping-aucune-url-sondee" 0 "$nombre_urls_sondees"
case "$raison_obtenue" in
	injoignable*) echo "OK A-raison-injoignable" ;;
	*) echo "ECHEC A-raison-injoignable : [$raison_obtenue]"; nombre_echecs=$((nombre_echecs + 1)) ;;
esac

lancer 1 0 4
verifier "B-un-paquet-perdu-reste-joignable" 0 "$code_de_retour"

lancer 0 0 4
verifier "C-joignable-et-tunnel-ok" 0 "$code_de_retour"
verifier "C-premiere-url-suffit" 1 "$nombre_urls_sondees"

lancer 0 28 4
verifier "D-timeout-echec" 1 "$code_de_retour"
verifier "D-toutes-les-urls-essayees" 2 "$nombre_urls_sondees"
case "$raison_obtenue" in
	*"tunnel trop lent"*) echo "OK D-raison-tunnel-lent" ;;
	*) echo "ECHEC D-raison-tunnel-lent : [$raison_obtenue]"; nombre_echecs=$((nombre_echecs + 1)) ;;
esac

lancer 0 7 4
case "$raison_obtenue" in
	*"aucune sortie Internet"*) echo "OK E-raison-aucune-sortie" ;;
	*) echo "ECHEC E-raison-aucune-sortie : [$raison_obtenue]"; nombre_echecs=$((nombre_echecs + 1)) ;;
esac

lancer 0 0 6
verifier "F-ipv6-sonde-les-urls-v6" "https://[v6]/" "$(cat "$dossier_temporaire/urls_sondees")"

exit "$nombre_echecs"
