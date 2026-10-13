#!/bin/sh
# Pose sur l'hôte la règle DOCKER-USER qui ferme la fenêtre de démarrage d'un Gluetun (README §4.6) : tout paquet dont la
# source est le sous-réseau vpn-gateway et qui sort par un autre pont que le sien est jeté. Les autres réseaux, dont
# frontend, ne sont pas touchés.
# Usage : vpngw-firewall.sh up|down|status [fichier]
#   fichier : une ligne « sous-réseau pont » par pile (défaut /etc/gluetun-egress/vpngw.conf), # pour un commentaire.
# Variables : IPTABLES (défaut iptables), ATTENTE_CHAINE (secondes d'attente de DOCKER-USER, défaut 30).
set -eu

action=${1:-up}
fichier_de_configuration=${2:-/etc/gluetun-egress/vpngw.conf}
IPTABLES=${IPTABLES:-iptables}
secondes_d_attente=${ATTENTE_CHAINE:-30}

erreur() {
	echo "vpngw-firewall : $*" >&2
	exit 1
}

[ -r "$fichier_de_configuration" ] || erreur "fichier illisible : $fichier_de_configuration"
reseaux=$(grep -vE '^[[:space:]]*(#|$)' "$fichier_de_configuration" || true)
[ -n "$reseaux" ] || erreur "aucun sous-réseau dans $fichier_de_configuration"

while read -r sous_reseau pont reste; do
	echo "$sous_reseau" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$' || erreur "sous-réseau invalide : $sous_reseau"
	echo "$pont" | grep -qE '^[A-Za-z0-9_-]{1,15}$' || erreur "pont invalide : $pont"
	[ -z "$reste" ] || erreur "ligne invalide : $sous_reseau $pont $reste"
done <<EOF
$reseaux
EOF

pour_chaque_reseau() {
	while read -r sous_reseau pont _; do
		"$1" "$sous_reseau" "$pont"
	done <<EOF
$reseaux
EOF
}

attendre_la_chaine() {
	secondes=0
	until $IPTABLES -n -L DOCKER-USER >/dev/null 2>&1; do
		[ "$secondes" -lt "$secondes_d_attente" ] || erreur "chaîne DOCKER-USER absente (Docker est-il démarré ?)"
		sleep 1
		secondes=$((secondes + 1))
	done
}

regle_presente() {
	$IPTABLES -C DOCKER-USER -s "$1" ! -o "$2" -j DROP >/dev/null 2>&1
}

poser() {
	regle_presente "$1" "$2" && return 0
	$IPTABLES -I DOCKER-USER -s "$1" ! -o "$2" -j DROP
	echo "règle posée : source $1, hors du pont $2"
}

retirer() {
	while regle_presente "$1" "$2"; do
		$IPTABLES -D DOCKER-USER -s "$1" ! -o "$2" -j DROP
		echo "règle retirée : source $1, hors du pont $2"
	done
}

afficher() {
	if regle_presente "$1" "$2"; then echo "$1 hors de $2 : posée"; else echo "$1 hors de $2 : absente"; fi
}

case "$action" in
	up) attendre_la_chaine; pour_chaque_reseau poser ;;
	down) $IPTABLES -n -L DOCKER-USER >/dev/null 2>&1 || exit 0; pour_chaque_reseau retirer ;;
	status) pour_chaque_reseau afficher ;;
	*) erreur "action inconnue : $action (up, down ou status)" ;;
esac
