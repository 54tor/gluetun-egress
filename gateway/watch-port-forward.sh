#!/bin/sh
# Surveille le port redirigé (NAT-PMP de Proton) d'un Gluetun : absent PF_MISS_LIMIT contrôles de suite, le conteneur est
# relancé (il change de serveur, et la redirection revient presque toujours). Sa demande NAT-PMP peut expirer au démarrage
# sans jamais être renouvelée : sans cette surveillance, l'écoute entrante d'un service de sa pile reste sans port.
# Les conteneurs qui partagent la pile du Gluetun (arguments suivants) restent orphelins, sans réseau, quand il redémarre :
# ils sont relancés à leur tour, PF_DEPENDENTS_DELAY secondes après lui. Le gateway ne le fait pas dans ce cas, un
# redémarrage rapide n'étant pas vu comme une panne.
# Usage : watch-port-forward.sh <conteneur du Gluetun> [conteneur dépendant...]
# Variables : DOCKER_SOCKET (/var/run/docker.sock), PF_CHECK_EVERY (30 s), PF_MISS_LIMIT (6), PF_DEPENDENTS_DELAY (5 s),
# PORT_FORWARD_FILE (/gluetun/forwarded_port).
set -u

conteneur=${1:?usage: watch-port-forward.sh <conteneur du Gluetun> [conteneur dépendant...]}
shift
dependants="$*"
DOCKER_SOCKET=${DOCKER_SOCKET:-/var/run/docker.sock}
PF_CHECK_EVERY=${PF_CHECK_EVERY:-30}
PF_MISS_LIMIT=${PF_MISS_LIMIT:-6}
PF_DEPENDENTS_DELAY=${PF_DEPENDENTS_DELAY:-5}
PORT_FORWARD_FILE=${PORT_FORWARD_FILE:-/gluetun/forwarded_port}

log() { echo "$(date -Iseconds) port-forward: $*"; }

nom_de_conteneur_valide() { echo "$1" | grep -Eq '^[a-zA-Z0-9][a-zA-Z0-9_.-]*$'; }
nom_de_conteneur_valide "$conteneur" || { log "nom de conteneur invalide : $conteneur"; exit 1; }
for dependant in $dependants; do
	nom_de_conteneur_valide "$dependant" || { log "nom de dépendant invalide : $dependant"; exit 1; }
done
echo "$PORT_FORWARD_FILE" | grep -Eq '^/[a-zA-Z0-9_./-]+$' || { log "PORT_FORWARD_FILE invalide : $PORT_FORWARD_FILE"; exit 1; }
case "$PF_MISS_LIMIT$PF_CHECK_EVERY$PF_DEPENDENTS_DELAY" in *[!0-9]*) log "PF_CHECK_EVERY, PF_MISS_LIMIT et PF_DEPENDENTS_DELAY doivent être des entiers"; exit 1 ;; esac

relancer() { # $1=conteneur ; affiche le code HTTP de la réponse
	curl -sS -o /dev/null -w '%{http_code}' --max-time 60 --unix-socket "$DOCKER_SOCKET" \
		-X POST "http://docker/containers/$1/restart" 2>/dev/null || echo erreur
}

appel_docker() { # $1=méthode $2=chemin ; le corps de la réponse sur la sortie standard
	curl -sS --max-time 10 --unix-socket "$DOCKER_SOCKET" -X "$1" "http://docker$2" 2>/dev/null
}

conteneur_en_marche() {
	appel_docker GET "/containers/$conteneur/json" | grep -Eq '"Running": ?true'
}

port_redirige_present() {
	appel_docker GET "/containers/$conteneur/archive?path=$PORT_FORWARD_FILE" | tar -xO 2>/dev/null | grep -q .
}

controles_manques=0
while sleep "$PF_CHECK_EVERY"; do
	if ! conteneur_en_marche; then
		controles_manques=0
		continue
	fi
	if port_redirige_present; then
		controles_manques=0
		continue
	fi
	controles_manques=$((controles_manques + 1))
	if [ "$controles_manques" -ge "$PF_MISS_LIMIT" ]; then
		log "$conteneur sans port redirigé depuis $controles_manques contrôles : relance -> HTTP $(relancer "$conteneur")"
		controles_manques=0
		if [ -n "$dependants" ]; then
			sleep "$PF_DEPENDENTS_DELAY"
			for dependant in $dependants; do
				log "$conteneur relancé : relance de $dependant -> HTTP $(relancer "$dependant")"
			done
		fi
	fi
done
