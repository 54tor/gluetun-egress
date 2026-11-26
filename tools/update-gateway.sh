#!/bin/sh
# Met à jour le gateway sans toucher aux Gluetun, aux wgentry ni à Caddy : reconstruit l'image, contrôle la syntaxe des scripts dans
# l'image neuve, puis recrée « gateway » et les conteneurs qui partagent son réseau (ceux en network_mode service:gateway, comme « app » : Docker ne
# sait pas les rattacher à un nouveau netns, ils sont recréés avec lui, quelques secondes). vpn-check.sh est redéposé dans
# gateway-state au démarrage du gateway : les Gluetun l'utilisent dès leur contrôle suivant.
# Usage : tools/update-gateway.sh [dossier-compose]   (défaut : example/)
# Sortie : une ligne par étape ; code de sortie 0 si le gateway est « healthy » après recréation.
set -eu

racine=$(cd "$(dirname "$0")/.." && pwd)
dossier_compose=${1:-$racine/example}
delai_healthy_secondes=60
cd "$dossier_compose"

echo "== build"
docker compose build gateway

echo "== contrôle de l'image"
image=$(docker compose config --images | grep -m1 gateway)
for script in entrypoint.sh probe.sh vpn-check.sh; do
	chemin=/usr/local/bin/$script
	[ "$script" != vpn-check.sh ] || chemin=/usr/local/share/gateway/vpn-check.sh
	docker run --rm --entrypoint sh "$image" -n "$chemin"
done

echo "== recréation de gateway et des conteneurs qui partagent son réseau"
docker compose up -d --no-deps --force-recreate gateway
docker compose up -d   # recrée seulement ce qui pointe vers l'ancien gateway (network_mode: service:gateway)

echo "== attente du healthcheck"
fin=$(( $(date +%s) + delai_healthy_secondes ))
while [ "$(date +%s)" -lt "$fin" ]; do
	etat=$(docker inspect --format '{{.State.Health.Status}}' "$(docker compose ps -q gateway)")
	[ "$etat" != healthy ] || { echo "gateway healthy"; exit 0; }
	sleep 2
done
echo "gateway pas healthy après ${delai_healthy_secondes} s" >&2
exit 1
