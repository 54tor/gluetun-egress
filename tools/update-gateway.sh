#!/bin/sh
# Met à jour le gateway sans toucher aux Gluetun ni aux services qui ne dépendent pas de son réseau : reconstruit l'image (service avec
# « build: ») ou la télécharge (service avec « image: »), contrôle la syntaxe des scripts dans l'image neuve, recrée « gateway », puis
# seulement les conteneurs qui partagent son réseau (network_mode: service:gateway) : Docker ne sait pas les rattacher à un nouveau
# netns, ils sont recréés avec lui, quelques secondes. vpn-check.sh est redéposé dans gateway-state au démarrage du gateway : les
# Gluetun l'utilisent dès leur contrôle suivant.
# Usage : update-gateway.sh [dossier-compose]   (défaut : example/ du dépôt s'il existe, sinon le dossier du script)
# Sortie : une ligne par étape ; code de sortie 0 si le gateway est « healthy » après recréation.
set -eu

dossier_script=$(cd "$(dirname "$0")" && pwd)
dossier_compose=${1:-}
if [ -z "$dossier_compose" ]; then
	dossier_compose=$dossier_script
	[ ! -d "$dossier_script/../example" ] || dossier_compose=$dossier_script/../example
fi
delai_healthy_secondes=60
cd "$dossier_compose"

echo "== mise à jour de l'image"
docker compose build gateway
docker compose pull gateway 2>/dev/null || true

echo "== contrôle de l'image"
image=$(docker compose config --images | grep -m1 -E '(^|/)[^/]*gateway(:|$)')
for chemin in /usr/local/bin/entrypoint.sh /usr/local/bin/probe.sh /usr/local/share/gateway/vpn-check.sh; do
	docker run --rm --entrypoint sh "$image" -n "$chemin"
done

ancien_gateway=$(docker compose ps -q gateway)
projet=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$ancien_gateway")
dependants=$(docker ps -q --filter "label=com.docker.compose.project=$projet" | while read -r conteneur; do
	reseau=$(docker inspect --format '{{.HostConfig.NetworkMode}}' "$conteneur")
	case "$reseau" in "container:$ancien_gateway"*) docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$conteneur" ;; esac
done)

echo "== recréation de gateway"
docker compose up -d --no-deps --force-recreate gateway

echo "== attente du healthcheck"
fin=$(( $(date +%s) + delai_healthy_secondes ))
while [ "$(docker inspect --format '{{.State.Health.Status}}' "$(docker compose ps -q gateway)")" != healthy ]; do
	[ "$(date +%s)" -lt "$fin" ] || { echo "gateway pas healthy après ${delai_healthy_secondes} s" >&2; exit 1; }
	sleep 2
done
echo "gateway healthy"

echo "== recréation des conteneurs sur le réseau du gateway : $(echo $dependants)"
# shellcheck disable=SC2086
[ -z "$dependants" ] || docker compose up -d --no-deps --force-recreate $dependants
