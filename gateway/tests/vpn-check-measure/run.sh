#!/bin/sh
# Test de publish_ip_without_measure (vpn-check.sh) : un changement d'IP réécrit le fichier de mesure avec la nouvelle adresse et
# sans latence ni débit ; la même IP laisse la mesure intacte ; un dossier absent n'est pas une erreur.
# Sortie : « OK <scénario> » ou « ECHEC <scénario> : <raison> » ; code de sortie 0 si tout passe.
# ip est lue par la fonction extraite de vpn-check.sh.
# shellcheck disable=SC2034
set -u

dossier_du_test=$(cd "$(dirname "$0")" && pwd)
dossier_temporaire=$(mktemp -d)
trap 'rm -rf "$dossier_temporaire"' EXIT
nombre_echecs=0

definition=$(sed -n '/^publish_ip_without_measure() {/,/^}/p' "$dossier_du_test/../../vpn-check.sh")
[ -n "$definition" ] || { echo "ECHEC extraction : fonction introuvable dans vpn-check.sh"; exit 1; }
eval "$definition"
eval "$(sed -n '/^measure_is_missing_for_this_ip() {/,/^}/p' "$dossier_du_test/../../vpn-check.sh")"

verifier() { # $1=scénario $2=attendu $3=obtenu
	if [ "$2" = "$3" ]; then
		echo "OK $1"
	else
		echo "ECHEC $1 : attendu « $2 », obtenu « $3 »"
		nombre_echecs=$((nombre_echecs + 1))
	fi
}

ip=
MEASURE_FILE="$dossier_temporaire/measure"

echo "12 340 1700000000 203.0.113.7 80" >"$MEASURE_FILE"
ip=198.51.100.9
publish_ip_without_measure
verifier "nouvelle-ip-sans-mesure" "- - - 198.51.100.9" "$(cat "$MEASURE_FILE")"

echo "12 340 1700000000 203.0.113.7 80" >"$MEASURE_FILE"
ip=203.0.113.7
publish_ip_without_measure
verifier "meme-ip-mesure-intacte" "12 340 1700000000 203.0.113.7 80" "$(cat "$MEASURE_FILE")"

rm -f "$MEASURE_FILE"
ip=198.51.100.9
publish_ip_without_measure
verifier "premier-depot-sans-fichier" "- - - 198.51.100.9" "$(cat "$MEASURE_FILE")"

MEASURE_FILE="$dossier_temporaire/absent/measure"
publish_ip_without_measure
verifier "dossier-absent-sans-erreur" "0" "$?"

MEASURE_FILE="$dossier_temporaire/mesure-absente"
MEASURED="$dossier_temporaire/measured"
ip=198.51.100.9
rm -f "$MEASURED"
measure_is_missing_for_this_ip
verifier "ip-jamais-mesuree-mesure-absente" "0" "$?"
echo "$ip" >"$MEASURED"
measure_is_missing_for_this_ip
verifier "ip-deja-mesuree-pas-de-retest" "1" "$?"

[ "$nombre_echecs" -eq 0 ]
