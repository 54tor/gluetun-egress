# shellcheck shell=sh
# Journal des sondes : une ligne quand un VPN change d'état, plus un rappel toutes les LOG_REMINDER secondes (600 par défaut)
# tant qu'il reste hors service, au lieu d'une ligne par sonde (quelques secondes d'intervalle, pour toujours, d'un VPN sans
# IPv6 par exemple). Source de entrypoint.sh, qui fournit `log` ; l'état (dernier rappel) vit dans des variables du shell appelant.
LOG_REMINDER=${LOG_REMINDER:-600}

# journaliser_etat_sonde <vpn> <famille> <ip> <était up> <est up> <contrôles échoués de suite> <raison> <maintenant, en secondes>
journaliser_etat_sonde() {
	cle_du_vpn="$1_v$2"
	eval "dernier_rappel=\${dernier_rappel_$cle_du_vpn:-0}"
	if [ "$4" = 0 ] && [ "$5" = 1 ]; then
		log "$1 IPv$2 ($3) revenu"
		eval "dernier_rappel_$cle_du_vpn=0"
	elif [ "$5" = 0 ] && [ "$6" -ge 1 ]; then
		if [ "$dernier_rappel" = 0 ] || [ $(($8 - dernier_rappel)) -ge "$LOG_REMINDER" ]; then
			log "$1 IPv$2 ($3) hors service : $7"
			eval "dernier_rappel_$cle_du_vpn=$8"
		fi
	fi
}
