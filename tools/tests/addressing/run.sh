#!/bin/sh
# Test de tools/set-addressing.sh sur une copie du dépôt : plus aucune trace de l'ancien plan hors README et tools/, le nouveau plan
# est cohérent (les tests des scripts passent avec lui), un échange de préfixes ne corrompt rien, une valeur invalide est refusée.
# Sortie : « OK <cas> » ou « ECHEC <cas> : attendu [...], obtenu [...] » ; code de sortie 0 si tout passe.
set -u

dossier_du_test=$(cd "$(dirname "$0")" && pwd)
racine=$(cd "$dossier_du_test/../../.." && pwd)
dossier_de_travail=$(mktemp -d)
trap 'rm -rf "$dossier_de_travail"' EXIT
nombre_echecs=0

verifier() {
	if [ "$2" = "$3" ]; then echo "OK $1"; else echo "ECHEC $1 : attendu [$2], obtenu [$3]"; nombre_echecs=$((nombre_echecs + 1)); fi
}

copie=$dossier_de_travail/copie
mkdir "$copie"
(cd "$racine" && tar cf - --exclude=.git .) | tar xf - -C "$copie"
. "$copie/tools/addressing.env"
export SET_ADDRESSING_SANS_DOCKER=1
traces() { grep -rIlE "$1" "$copie" --exclude=README.md --exclude-dir=tools | wc -l; }

sh "$copie/tools/set-addressing.sh" 10.77.1 10.77.2 fd77:7 >/dev/null
verifier "plus-de-trace-ipv4-frontend" 0 "$(traces "$(echo "$FRONTEND_PREFIX." | sed 's/\./\\./g')")"
verifier "plus-de-trace-ipv4-vpn" 0 "$(traces "$(echo "$VPN_PREFIX." | sed 's/\./\\./g')")"
verifier "plus-de-trace-ula" 0 "$(traces "$ULA_PREFIX::")"
verifier "valeurs-courantes-a-jour" "10.77.1 10.77.2 fd77:7" "$(. "$copie/tools/addressing.env"; echo "$FRONTEND_PREFIX $VPN_PREFIX $ULA_PREFIX")"
verifier "compose-sur-le-nouveau-plan" 1 "$(grep -c 'ipv4_address: 10.77.1.10 ' "$copie/example/docker-compose.yml" | sed 's/^[2-9]$/1/')"
verifier "hote-suit-le-sous-reseau-vpn" "$(printf '10.77.2.0/24 vpngw-egress\nfd77:7::/64 vpngw-egress')" "$(grep -v '^#' "$copie/host/vpngw.conf.example" | grep .)"
verifier "tests-gateway-sur-le-nouveau-plan" 0 "$(sh "$copie/gateway/tests/probe-log/run.sh" 2>&1 | grep -vc '^OK')"
verifier "tests-tunnels-sur-le-nouveau-plan" 0 "$(sh "$copie/gateway/tests/tunnels-json/run.sh" 2>&1 | grep -vc '^OK')"

verifier "meme-plan-sans-effet" "set-addressing : plan déjà en place" "$(sh "$copie/tools/set-addressing.sh" 10.77.1 10.77.2 fd77:7)"

sh "$copie/tools/set-addressing.sh" 10.77.2 10.77.1 fd77:7 >/dev/null
verifier "echange-frontend-vpn" "10.77.2 10.77.1" "$(. "$copie/tools/addressing.env"; echo "$FRONTEND_PREFIX $VPN_PREFIX")"
verifier "echange-sans-marqueur-oublie" 0 "$(grep -rIl '@@' "$copie" --exclude=README.md --exclude-dir=tools --exclude-dir=.git | wc -l)"
verifier "echange-caddy-sur-le-nouveau-frontend" 1 "$(grep -c 'ipv4_address: 10.77.2.10 ' "$copie/example/docker-compose.yml" | sed 's/^[2-9]$/1/')"

sh "$copie/tools/set-addressing.sh" 10.77.1 10.77.2 fd77:7 Pile >/dev/null 2>&1
verifier "nom-invalide-refuse" 1 "$?"
sh "$copie/tools/set-addressing.sh" 10.77.1 10.77.2 fd77:7 abcdefghij >/dev/null 2>&1
verifier "nom-trop-long-refuse" 1 "$?"

sh "$copie/tools/set-addressing.sh" 10.77.1 10.77.2 - blog >/dev/null
verifier "nom-de-projet" 1 "$(grep -c '^name: blog$' "$copie/example/docker-compose.yml")"
verifier "plus-de-nom-d-origine" 0 "$(grep -rIlE '(^|[^A-Za-z0-9_])vpnstack-|^name: vpnstack$' "$copie" --exclude=README.md --exclude-dir=tools | wc -l)"
verifier "pont-de-la-pile" 1 "$(grep -c 'bridge.name: vpngw-blog$' "$copie/example/docker-compose.yml")"
verifier "hote-suit-le-pont" "$(printf '10.77.2.0/24 vpngw-blog\nfd77:7::/64 vpngw-blog')" "$(grep -v '^#' "$copie/host/vpngw.conf.example" | grep .)"
verifier "valeurs-nom-pont" "blog vpngw-blog" "$(. "$copie/tools/addressing.env"; echo "$NOM_DE_PILE $PONT")"
verifier "ula-conserve-avec-tiret" fd77:7 "$(. "$copie/tools/addressing.env"; echo "$ULA_PREFIX")"

mkdir "$dossier_de_travail/faux"
printf '#!/bin/sh\ncase "$2" in ls) echo reseau1 ;; inspect) echo "10.88.1.0/24 " ;; esac\n' > "$dossier_de_travail/faux/docker"
sed -i 's/case "$2"/case "$1 $2"/; s/ls)/"network ls")/; s/inspect)/"network inspect")/' "$dossier_de_travail/faux/docker"
chmod +x "$dossier_de_travail/faux/docker"
env -u SET_ADDRESSING_SANS_DOCKER PATH="$dossier_de_travail/faux:$PATH" sh "$copie/tools/set-addressing.sh" 10.88.1 10.88.2 >/dev/null 2>&1
verifier "plage-deja-prise-par-docker-refusee" 1 "$?"
env -u SET_ADDRESSING_SANS_DOCKER PATH="$dossier_de_travail/faux:$PATH" sh "$copie/tools/set-addressing.sh" 10.88.5 10.88.6 >/dev/null 2>&1
verifier "plage-libre-acceptee" 0 "$?"

sh "$copie/tools/set-addressing.sh" 8.8.8 10.77.1 >/dev/null 2>&1
verifier "prefixe-public-refuse" 1 "$?"
sh "$copie/tools/set-addressing.sh" 10.77.300 10.77.1 >/dev/null 2>&1
verifier "octet-hors-plage-refuse" 1 "$?"
sh "$copie/tools/set-addressing.sh" 10.77.1 10.77.1 >/dev/null 2>&1
verifier "prefixes-identiques-refuses" 1 "$?"
sh "$copie/tools/set-addressing.sh" 10.77.1 10.77.2 2001:db8 >/dev/null 2>&1
verifier "ula-invalide-refuse" 1 "$?"
sh "$copie/tools/set-addressing.sh" 10.77.1 >/dev/null 2>&1
verifier "argument-manquant-refuse" 1 "$?"

[ "$nombre_echecs" -eq 0 ]
