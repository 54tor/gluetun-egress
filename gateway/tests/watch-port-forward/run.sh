#!/bin/sh
# Test de watch-port-forward.sh contre un faux démon Docker (fake_docker.py) : aucun conteneur, aucun vrai socket.
# Quatre scénarios, une seule surveillance qui tourne pendant tout le test :
#   A. le conteneur est arrêté                  -> aucune relance (rien à relancer)
#   B. il tourne et le port est présent         -> aucune relance
#   C. il tourne et le port est absent          -> exactement une relance du Gluetun, une fois la limite de contrôles manqués
#                                                  atteinte, puis une relance de chacun de ses dépendants (ils restent orphelins sinon)
#   D. le port revient puis disparaît 2 fois    -> pas de nouvelle relance (le compteur est remis à zéro dès que le port revient)
# Sortie : « OK <scénario> » ou « ECHEC <scénario> : <raison> » ; code de sortie 0 si tout passe.
set -u

dossier_du_test=$(cd "$(dirname "$0")" && pwd)
script_a_tester="$dossier_du_test/../../watch-port-forward.sh"
dossier_temporaire=$(mktemp -d)
nombre_echecs=0

processus_du_faux_docker=""
processus_de_surveillance=""
nettoyer() {
	[ -n "$processus_de_surveillance" ] && kill "$processus_de_surveillance" 2>/dev/null
	[ -n "$processus_du_faux_docker" ] && kill "$processus_du_faux_docker" 2>/dev/null
	rm -rf "$dossier_temporaire"
}
trap nettoyer EXIT INT TERM

mkdir -p "$dossier_temporaire/etat"
journal="$dossier_temporaire/requetes.log"
: > "$journal"

python3 "$dossier_du_test/fake_docker.py" "$dossier_temporaire/docker.sock" "$dossier_temporaire/etat" &
processus_du_faux_docker=$!

attente=0
while [ ! -S "$dossier_temporaire/docker.sock" ] && [ "$attente" -lt 50 ]; do
	sleep 0.1
	attente=$((attente + 1))
done
[ -S "$dossier_temporaire/docker.sock" ] || { echo "ECHEC demarrage : le faux démon Docker ne répond pas"; exit 1; }

compter_les_relances() { # $1=conteneur (par défaut le Gluetun)
	grep -c "^POST /containers/${1:-vpnstack-gluetun1-1}/restart" "$journal"
}

verifier() { # $1=scénario $2=valeur attendue $3=valeur obtenue
	if [ "$2" = "$3" ]; then
		echo "OK $1"
	else
		echo "ECHEC $1 : $2 relance(s) attendue(s), $3 obtenue(s)"
		nombre_echecs=$((nombre_echecs + 1))
	fi
}

DOCKER_SOCKET="$dossier_temporaire/docker.sock" PF_CHECK_EVERY=1 PF_MISS_LIMIT=3 PF_DEPENDENTS_DELAY=1 \
	sh "$script_a_tester" vpnstack-gluetun1-1 vpnstack-wgentry1-1 vpnstack-client-1 >/dev/null 2>&1 &
processus_de_surveillance=$!

# A. conteneur arrêté
echo non > "$dossier_temporaire/etat/running"
: > "$dossier_temporaire/etat/port"
sleep 5
verifier "A-conteneur-arrete" 0 "$(compter_les_relances)"

# B. conteneur en marche, port présent
echo oui > "$dossier_temporaire/etat/running"
echo 51234 > "$dossier_temporaire/etat/port"
sleep 5
verifier "B-port-present" 0 "$(compter_les_relances)"

# C. port absent : une relance une fois les trois contrôles manqués passés
: > "$dossier_temporaire/etat/port"
attente=0
while [ "$(compter_les_relances)" -lt 1 ] && [ "$attente" -lt 12 ]; do
	sleep 1
	attente=$((attente + 1))
done
echo 51234 > "$dossier_temporaire/etat/port"
sleep 3
verifier "C-port-absent" 1 "$(compter_les_relances)"
verifier "C-dependant-wgentry-relance" 1 "$(compter_les_relances vpnstack-wgentry1-1)"
verifier "C-dependant-client-relance" 1 "$(compter_les_relances vpnstack-client-1)"

# D. le port est revenu, disparaît deux contrôles seulement, revient : aucune relance de plus
sleep 2
: > "$dossier_temporaire/etat/port"
sleep 1.5
echo 51234 > "$dossier_temporaire/etat/port"
sleep 3
verifier "D-compteur-remis-a-zero" 1 "$(compter_les_relances)"
verifier "D-dependants-pas-relances-en-plus" 1 "$(compter_les_relances vpnstack-client-1)"

[ "$nombre_echecs" -eq 0 ]
