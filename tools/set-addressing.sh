#!/bin/sh
# Change le plan d'adressage de toute la pile d'un coup (README §7). Les arguments sont des préfixes : les sous-réseaux restent
# des /24 (IPv4) et un /64 (ULA), les hôtes gardent leur rang (.2 gateway, .10 Caddy, .11 et suivants les Gluetun).
# Usage : tools/set-addressing.sh <préfixe frontend> <préfixe vpn-gateway> [préfixe ULA|-] [nom de pile]
#   exemple : tools/set-addressing.sh 10.50.1 10.50.2 fd50:2:1 blog
# Plusieurs piles sur un hôte : un dépôt par pile, chacune avec ses plages et son nom (projet Compose, noms de conteneurs, pont
# vpngw-<nom>). Le nom tient en 9 caractères (a-z, 0-9) parce qu'un nom de pont Linux en compte 15 au plus.
# Variable SET_ADDRESSING_SANS_DOCKER=1 : ne pas comparer aux réseaux Docker existants. Tout le dépôt est réécrit en place, sauf le README (il décrit les valeurs d'origine) et tools/. tools/addressing.env garde
# les valeurs courantes : relancer avec les mêmes valeurs ne change rien.
set -eu

racine=$(cd "$(dirname "$0")/.." && pwd)
fichier_des_valeurs=$racine/tools/addressing.env
. "$fichier_des_valeurs"

erreur() {
	echo "set-addressing : $*" >&2
	exit 1
}

prefixe_ipv4_prive() {
	echo "$1" | grep -qE '^(10\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}|192\.168\.[0-9]{1,3})$' || return 1
	for octet in $(echo "$1" | tr . ' '); do [ "$octet" -le 255 ] || return 1; done
}

nouveau_frontend=${1:-}
nouveau_vpn=${2:-}
nouvel_ula=${3:--}
[ "$nouvel_ula" != - ] || nouvel_ula=$ULA_PREFIX
nouveau_nom=${4:-$NOM_DE_PILE}
[ -n "$nouveau_frontend" ] && [ -n "$nouveau_vpn" ] || erreur "usage : tools/set-addressing.sh <préfixe frontend> <préfixe vpn-gateway> [préfixe ULA|-] [nom de pile]"
prefixe_ipv4_prive "$nouveau_frontend" || erreur "préfixe frontend invalide ou public : $nouveau_frontend (attendu A.B.C privé, ex. 10.50.1)"
prefixe_ipv4_prive "$nouveau_vpn" || erreur "préfixe vpn-gateway invalide ou public : $nouveau_vpn (attendu A.B.C privé, ex. 10.50.2)"
[ "$nouveau_frontend" != "$nouveau_vpn" ] || erreur "frontend et vpn-gateway ne peuvent pas partager le préfixe $nouveau_vpn"
echo "$nouvel_ula" | grep -qE '^f[cd][0-9a-f]{2}(:[0-9a-f]{1,4}){0,2}$' || erreur "préfixe ULA invalide : $nouvel_ula (attendu fdXX ou fdXX:YYYY:ZZZZ, ex. fd50:2:1)"

echo "$nouveau_nom" | grep -qE '^[a-z][a-z0-9]{0,8}$' || erreur "nom de pile invalide : $nouveau_nom (a-z et 0-9, 9 caractères au plus, ex. blog)"

if [ "$nouveau_frontend" = "$FRONTEND_PREFIX" ] && [ "$nouveau_vpn" = "$VPN_PREFIX" ] && [ "$nouvel_ula" = "$ULA_PREFIX" ] && [ "$nouveau_nom" = "$NOM_DE_PILE" ]; then
	echo "set-addressing : plan déjà en place"
	exit 0
fi

plages_deja_prises() {
	[ -z "${SET_ADDRESSING_SANS_DOCKER:-}" ] || return 0
	command -v docker >/dev/null 2>&1 || return 0
	reseaux_docker=$(docker network ls -q 2>/dev/null) || return 0
	[ -n "$reseaux_docker" ] || return 0
	docker network inspect $reseaux_docker --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null | tr ' ' '\n'
}

for prefixe_a_verifier in "$nouveau_frontend" "$nouveau_vpn"; do
	[ "$prefixe_a_verifier" != "$FRONTEND_PREFIX" ] && [ "$prefixe_a_verifier" != "$VPN_PREFIX" ] || continue
	if plages_deja_prises | grep -qE "^$(echo "$prefixe_a_verifier" | sed 's/\./\\./g')\.0/"; then
		erreur "$prefixe_a_verifier.0/24 est déjà pris par un réseau Docker (une autre pile ?) ; choisir une autre plage"
	fi
done

echapper() { echo "$1" | sed 's/\./\\./g'; }
ancien_frontend=$(echapper "$FRONTEND_PREFIX.")
ancien_vpn=$(echapper "$VPN_PREFIX.")
ancien_ula="$ULA_PREFIX::"

# Deux passes par des marqueurs : un échange de préfixes (frontend <-> vpn-gateway) ne se marche pas dessus.
fichiers=$(find "$racine" -type f ! -path '*/.git/*' ! -path "$racine/tools/*" ! -name README.md ! -name LICENSE)
for fichier in $fichiers; do
	grep -qIE "$ancien_frontend|$ancien_vpn|$ancien_ula" "$fichier" || continue
	sed -i -e "s/$ancien_frontend/@@FRONTEND@@/g" -e "s/$ancien_vpn/@@VPN@@/g" -e "s/$ancien_ula/@@ULA@@/g" \
		-e "s/@@FRONTEND@@/$nouveau_frontend./g" -e "s/@@VPN@@/$nouveau_vpn./g" -e "s/@@ULA@@/$nouvel_ula::/g" "$fichier"
	echo "réécrit : ${fichier#"$racine"/}"
done

nouveau_pont=$PONT
if [ "$nouveau_nom" != "$NOM_DE_PILE" ]; then
	nouveau_pont=vpngw-$nouveau_nom
	for fichier in $fichiers; do
		grep -qIE "(^|[^A-Za-z0-9_])$NOM_DE_PILE-|^name: $NOM_DE_PILE\$|$PONT" "$fichier" || continue
		sed -i -e "s/\b$NOM_DE_PILE-/$nouveau_nom-/g" -e "s/^name: $NOM_DE_PILE\$/name: $nouveau_nom/" -e "s/$PONT/$nouveau_pont/g" "$fichier"
		echo "renommé : ${fichier#"$racine"/}"
	done
fi

printf 'FRONTEND_PREFIX=%s\nVPN_PREFIX=%s\nULA_PREFIX=%s\nNOM_DE_PILE=%s\nPONT=%s\n' "$nouveau_frontend" "$nouveau_vpn" "$nouvel_ula" "$nouveau_nom" "$nouveau_pont" > "$fichier_des_valeurs"
echo "set-addressing : pile $nouveau_nom, frontend $nouveau_frontend.0/24, vpn-gateway $nouveau_vpn.0/24, ULA $nouvel_ula::/64, pont $nouveau_pont"
echo "À faire : ajouter « $nouveau_vpn.0/24 $nouveau_pont » à /etc/gluetun-egress/vpngw.conf (hôte, une ligne par pile)."
