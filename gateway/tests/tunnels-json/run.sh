#!/bin/sh
# Test de ecrire_etat_tunnels (tunnels-json.sh) : tunnels.json est du JSON valide, avec une entrée par tunnel,
# des champs de mesure à null quand le tunnel n'a pas de mesure, et sans fichier temporaire laissé derrière.
# Sortie : « OK <scénario> » ou « ECHEC <scénario> : <raison> » ; code de sortie 0 si tout passe.
set -u

dossier_du_test=$(cd "$(dirname "$0")" && pwd)
dossier_de_travail=$(mktemp -d)
trap 'rm -rf "$dossier_de_travail"' EXIT
nombre_echecs=0

. "$dossier_du_test/../../tunnels-json.sh"

verifier() { # $1=scénario $2=valeur attendue $3=valeur obtenue
	if [ "$2" = "$3" ]; then
		echo "OK $1"
	else
		echo "ECHEC $1 : attendu « $2 », obtenu « $3 »"
		nombre_echecs=$((nombre_echecs + 1))
	fi
}

# vpn1 : up avec mesure (latence, débit, date, IP publique) ; vpn2 : up sans mesure ; vpn3 : down
echo "42 310 1700000000 203.0.113.7" > "$dossier_de_travail/measure-vpn1"
fichier_tunnels="$dossier_de_travail/tunnels.json"
ecrire_etat_tunnels "$fichier_tunnels" "$dossier_de_travail" "vpn1:1 vpn2:1 vpn3:0" 1700000100

jq -e . "$fichier_tunnels" >/dev/null 2>&1 && json_valide=oui || json_valide=non
verifier "json-valide" oui "$json_valide"
verifier "trois-entrees" 3 "$(jq '.tunnels | length' "$fichier_tunnels")"
verifier "written_at" 1700000100 "$(jq '.written_at' "$fichier_tunnels")"
verifier "vpn3-down" false "$(jq '.tunnels[] | select(.name == "vpn3") | .up' "$fichier_tunnels")"
verifier "vpn2-latence-null" null "$(jq '.tunnels[] | select(.name == "vpn2") | .latency_ms' "$fichier_tunnels")"
verifier "vpn2-ip-null" null "$(jq '.tunnels[] | select(.name == "vpn2") | .public_ip' "$fichier_tunnels")"
verifier "vpn1-latence" 42 "$(jq '.tunnels[] | select(.name == "vpn1") | .latency_ms' "$fichier_tunnels")"
verifier "vpn1-debit" 310 "$(jq '.tunnels[] | select(.name == "vpn1") | .down_mbps' "$fichier_tunnels")"
verifier "vpn1-date-mesure" 1700000000 "$(jq '.tunnels[] | select(.name == "vpn1") | .measured_at' "$fichier_tunnels")"
verifier "vpn1-ip" '"203.0.113.7"' "$(jq '.tunnels[] | select(.name == "vpn1") | .public_ip' "$fichier_tunnels")"
verifier "aucun-temporaire" 1 "$(find "$dossier_de_travail" -maxdepth 1 -name '*tunnels.json*' | wc -l | tr -d ' ')"

# Dossier d'écriture inutilisable : la fonction rend un code non nul, et l'appelant sous set -eu survit.
sortie=$(
	set -eu
	ecrire_etat_tunnels "$dossier_de_travail/absent/tunnels.json" "$dossier_de_travail" "vpn1:1" 1700000200 || echo "echec-signale"
	echo "appelant-vivant"
)
verifier "ecriture-impossible-sans-abandon" "echec-signale appelant-vivant" "$(echo $sortie)"

[ "$nombre_echecs" = 0 ]
