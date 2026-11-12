#!/bin/sh
# Test des post-rules-N.txt : Gluetun relit INPUT et OUTPUT (iptables et ip6tables) à chaque arrêt de sa redirection de port et à
# chaque découverte de MTU, et son lecteur de règles ne sait lire ni « ! » (source niée), ni « owner », ni « multiport » : une
# telle règle directement dans INPUT ou OUTPUT fait tomber sa boucle (« ParseAddr("!172.30.20.2") », « unexpected optional field »).
# Le test applique chaque fichier dans un conteneur jetable (aucun Gluetun, aucun VPN) puis relit INPUT et OUTPUT comme Gluetun.
# Sortie : « OK <fichier> » ou « ECHEC <fichier> : <raison> » ; code de sortie 0 si tout passe.
set -u

dossier_des_regles=$(cd "$(dirname "$0")/../.." && pwd)
nombre_echecs=0

for fichier_de_regles in "$dossier_des_regles"/post-rules-*.txt; do
	nom=$(basename "$fichier_de_regles")
	listage=$(docker run --rm --cap-add NET_ADMIN -v "$fichier_de_regles:/regles.txt:ro" alpine:latest sh -c '
		apk add -q iptables ip6tables >/dev/null 2>&1
		sh /regles.txt >/tmp/application.txt 2>&1 || { echo "APPLICATION-ECHEC"; cat /tmp/application.txt; exit 0; }
		for table in iptables ip6tables; do
			for chaine in INPUT OUTPUT; do
				$table -L $chaine -n -v --line-numbers
			done
		done' 2>&1)
	if echo "$listage" | grep -q 'APPLICATION-ECHEC'; then
		echo "ECHEC $nom : le fichier ne s'applique pas : $(echo "$listage" | sed -n 2p | cut -c1-100)"
		nombre_echecs=$((nombre_echecs + 1))
		continue
	fi
	illisibles=$(echo "$listage" | grep -E '(^|[[:space:]])!|owner UID|multiport' | head -n 3)
	if [ -n "$illisibles" ]; then
		echo "ECHEC $nom : règle illisible pour Gluetun dans INPUT/OUTPUT : $(echo "$illisibles" | head -n 1 | tr -s ' ' | cut -c1-110)"
		nombre_echecs=$((nombre_echecs + 1))
	else
		echo "OK $nom"
	fi
done

[ "$nombre_echecs" -eq 0 ]
