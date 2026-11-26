#!/bin/sh
# Met à jour vpn-check.sh chez les Gluetun SANS rien redémarrer : télécharge (ou reconstruit) l'image du gateway, en extrait vpn-check.sh,
# contrôle sa syntaxe, puis l'écrit dans le volume gateway-state par le gateway en marche. Les Gluetun l'utilisent à leur contrôle suivant ;
# le gateway, ses conteneurs fils (network_mode: service:gateway) et les Gluetun ne sont ni recréés ni relancés.
# Ne couvre pas entrypoint.sh ni rules.nft : ils tournent dans le gateway, leur mise à jour exige de le recréer (donc ses fils).
# Usage : update-gateway.sh [dossier-compose]   (défaut : example/ du dépôt s'il existe, sinon le dossier du script)
# Sortie : une ligne par étape ; code de sortie 0 si le script est déposé.
set -eu

dossier_script=$(cd "$(dirname "$0")" && pwd)
dossier_compose=${1:-}
if [ -z "$dossier_compose" ]; then
	dossier_compose=$dossier_script
	[ ! -d "$dossier_script/../example" ] || dossier_compose=$dossier_script/../example
fi
cd "$dossier_compose"

echo "== mise à jour de l'image (sans toucher aux conteneurs)"
docker compose build gateway
docker compose pull --ignore-buildable gateway 2>/dev/null || docker compose pull gateway 2>/dev/null || true
image=$(docker compose config --images | grep -m1 -E '(^|/)[^/]*gateway(:|$)')

echo "== extraction et contrôle de vpn-check.sh"
nouveau=$(mktemp)
trap 'rm -f "$nouveau"' EXIT
docker run --rm --entrypoint cat "$image" /usr/local/share/gateway/vpn-check.sh >"$nouveau"
sh -n "$nouveau"

echo "== dépôt dans le volume gateway-state par le gateway en marche"
gateway=$(docker compose ps -q gateway)
[ -n "$gateway" ] || { echo "gateway absent : rien à déposer" >&2; exit 1; }
docker exec -i "$gateway" sh -c 'cat >/run/gateway/.vpn-check.sh.tmp && mv /run/gateway/.vpn-check.sh.tmp /run/gateway/vpn-check.sh' <"$nouveau"
echo "vpn-check.sh déposé"
