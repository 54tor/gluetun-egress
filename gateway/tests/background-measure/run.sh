#!/bin/sh
# Test de background_measure_is_running (vpn-check.sh) : le PID noté pour la mesure de fond ne compte que s'il désigne un vpn-check.sh
# vivant. Un zombie (mesure terminée, jamais récoltée par le PID 1 du Gluetun), un PID réattribué, un PID mort ou un fichier vide
# doivent laisser relancer la mesure.
# Sortie : « OK <cas> » ou « ECHEC <cas> : attendu [...], obtenu [...] » ; code de sortie 0 si tout passe.
set -u

dossier_du_test=$(cd "$(dirname "$0")" && pwd)
dossier_temporaire=$(mktemp -d)
pids_a_arreter=""
trap 'for pid in $pids_a_arreter; do kill "$pid" 2>/dev/null; done; rm -rf "$dossier_temporaire"' EXIT
nombre_echecs=0

definition=$(sed -n "/^background_measure_is_running() {/,/^}/p" "$dossier_du_test/../../vpn-check.sh")
[ -n "$definition" ] || { echo "ECHEC extraction : background_measure_is_running introuvable dans vpn-check.sh"; exit 1; }
eval "$definition"

verifier() {
	if [ "$2" = "$3" ]; then echo "OK $1"; else echo "ECHEC $1 : attendu [$2], obtenu [$3]"; nombre_echecs=$((nombre_echecs + 1)); fi
}

MEASURE_PID="$dossier_temporaire/measure_pid"

controler() { # $1=cas $2=PID écrit dans le fichier (vide : fichier vide) $3=code attendu
	printf '%s' "$2" >"$MEASURE_PID"
	background_measure_is_running
	verifier "$1" "$3" "$?"
}

# Mesure de fond vivante : la ligne de commande contient vpn-check.sh.
sh -c 'sleep 20; :' vpn-check.sh &
mesure_vivante=$!
pids_a_arreter="$pids_a_arreter $mesure_vivante"

# Zombie : un parent qui ne récolte pas son enfant terminé (comme le PID 1 de Gluetun).
sh -c 'sh -c "exit 0" & echo $! >"$1"; exec sleep 20' parent "$dossier_temporaire/pid_du_zombie" &
pids_a_arreter="$pids_a_arreter $!"
sleep 0.3
zombie=$(cat "$dossier_temporaire/pid_du_zombie")

# PID réattribué : un processus vivant qui n'est pas un vpn-check.sh.
sleep 20 &
autre_processus=$!
pids_a_arreter="$pids_a_arreter $autre_processus"

mesure_terminee=$(sh -c 'echo $$')

sleep 0.3
controler "mesure-vivante" "$mesure_vivante" 0
controler "zombie-ne-bloque-pas" "$zombie" 1
controler "pid-reattribue-ne-bloque-pas" "$autre_processus" 1
controler "pid-mort-ne-bloque-pas" "$mesure_terminee" 1
controler "fichier-vide-ne-bloque-pas" "" 1
rm -f "$MEASURE_PID"
background_measure_is_running
verifier "fichier-absent-ne-bloque-pas" 1 "$?"

[ "$nombre_echecs" -eq 0 ]
