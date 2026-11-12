#!/bin/sh
# Test de journaliser_etat_sonde (probe-log.sh) : une ligne aux changements d'état d'un VPN, un rappel toutes les LOG_REMINDER
# secondes tant qu'il reste hors service, et rien pour les échecs isolés sous le seuil. L'heure est injectée : aucun `sleep`.
# Sortie : « OK <scénario> » ou « ECHEC <scénario> : <raison> » ; code de sortie 0 si tout passe.
set -u

dossier_du_test=$(cd "$(dirname "$0")" && pwd)
nombre_echecs=0

log() { echo "gateway: $*"; }
# shellcheck disable=SC2034  # lue par probe-log.sh
LOG_REMINDER=600
. "$dossier_du_test/../../probe-log.sh"

compter_les_lignes() { printf '%s' "$1" | grep -c .; }

verifier() { # $1=scénario $2=nombre attendu $3=sortie obtenue
	obtenu=$(compter_les_lignes "$3")
	if [ "$2" = "$obtenu" ]; then
		echo "OK $1"
	else
		echo "ECHEC $1 : $2 ligne(s) attendue(s), $obtenu obtenue(s) : $(printf '%s' "$3" | tr '\n' '|' | cut -c1-160)"
		nombre_echecs=$((nombre_echecs + 1))
	fi
}

# A. un VPN jamais up (sans IPv6) échoue à chaque cycle : une ligne au premier échec, rien ensuite, un rappel après 600 s
sortie=$(
	maintenant=1000
	while [ "$maintenant" -le 1500 ]; do
		journaliser_etat_sonde vpn3 6 fd30:20::13 0 0 1 "aucune sortie Internet" "$maintenant"
		maintenant=$((maintenant + 3))
	done
)
verifier "A-premier-echec-une-seule-ligne" 1 "$sortie"
sortie=$(
	journaliser_etat_sonde vpn3 6 fd30:20::13 0 0 1 "aucune sortie Internet" 1000
	journaliser_etat_sonde vpn3 6 fd30:20::13 0 0 1 "aucune sortie Internet" 1599
	journaliser_etat_sonde vpn3 6 fd30:20::13 0 0 1 "aucune sortie Internet" 1600
)
verifier "A-rappel-apres-600-s" 2 "$sortie"

# B. le VPN repasse up : une ligne « revenu », puis rien tant qu'il reste up
sortie=$(
	journaliser_etat_sonde vpn1 4 172.30.20.11 0 1 0 "" 2000
	journaliser_etat_sonde vpn1 4 172.30.20.11 1 1 0 "" 2003
	journaliser_etat_sonde vpn1 4 172.30.20.11 1 1 0 "" 2006
)
verifier "B-retour-une-seule-ligne" 1 "$sortie"

# C. un échec isolé d'un VPN up, sous le seuil de pannes : aucune ligne
sortie=$(journaliser_etat_sonde vpn1 4 172.30.20.11 1 1 1 "tunnel trop lent" 3000)
verifier "C-echec-isole-silencieux" 0 "$sortie"

# D. un VPN up tombe (le seuil est atteint) : une ligne avec la raison
sortie=$(journaliser_etat_sonde vpn1 4 172.30.20.11 1 0 2 "tunnel trop lent" 4000)
verifier "D-panne-une-ligne" 1 "$sortie"
case "$sortie" in
	*"tunnel trop lent"*) echo "OK D-la-raison-est-journalisee" ;;
	*) echo "ECHEC D-la-raison-est-journalisee : $sortie"; nombre_echecs=$((nombre_echecs + 1)) ;;
esac

# E. deux VPN en panne en même temps : chacun a son propre rappel
sortie=$(
	journaliser_etat_sonde vpn2 6 fd30:20::12 0 0 1 "tunnel trop lent" 5000
	journaliser_etat_sonde vpn3 6 fd30:20::13 0 0 1 "injoignable" 5000
	journaliser_etat_sonde vpn2 6 fd30:20::12 0 0 1 "tunnel trop lent" 5003
	journaliser_etat_sonde vpn3 6 fd30:20::13 0 0 1 "injoignable" 5003
)
verifier "E-deux-vpn-independants" 2 "$sortie"

[ "$nombre_echecs" -eq 0 ]
