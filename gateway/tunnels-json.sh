# shellcheck shell=sh
# Écriture de tunnels.json : l'état de chaque tunnel (up, IP publique, latence, débit) pour la supervision.
# Source de entrypoint.sh. La mesure d'un tunnel est écrite par vpn-check.sh dans <dossier>/measure-<tunnel> :
# « latence_ms débit_mbit date [ip_publique] ». Sans mesure lisible, les quatre champs de mesure valent null.

# Un nombre entier, sinon null : le JSON reste valide quoi que contienne le fichier de mesure.
json_nombre_ou_null() {
	case "$1" in
		'' | *[!0-9]*) echo null ;;
		*) echo "$1" ;;
	esac
}

# Une adresse IP entre guillemets, sinon null.
json_adresse_ou_null() {
	case "$1" in
		'' | *[!0-9a-fA-F.:]*) echo null ;;
		*) echo "\"$1\"" ;;
	esac
}

# ecrire_etat_tunnels <fichier> <dossier des mesures> "<tunnel>:<1 si up, 0 sinon> ..." <maintenant, en secondes>
ecrire_etat_tunnels() {
	fichier_tunnels="$1"
	dossier_des_mesures="$2"
	etats_des_tunnels="$3"
	date_ecriture="$4"
	fichier_temporaire="$fichier_tunnels.tmp"
	separateur=

	# Un échec d'écriture ne doit jamais arrêter l'appelant (set -e) : on rend 1, il journalise.
	{ printf '' > "$fichier_temporaire"; } 2>/dev/null || return 1
	printf '{"written_at":%s,"tunnels":[' "$date_ecriture" > "$fichier_temporaire"
	for etat_du_tunnel in $etats_des_tunnels; do
		nom_du_tunnel=${etat_du_tunnel%%:*}
		[ "${etat_du_tunnel##*:}" = 1 ] && est_up=true || est_up=false
		latence_ms= debit_mbit= date_mesure= ip_publique=
		fichier_de_mesure="$dossier_des_mesures/measure-$nom_du_tunnel"
		[ -r "$fichier_de_mesure" ] && read -r latence_ms debit_mbit date_mesure ip_publique < "$fichier_de_mesure"
		printf '%s{"name":"%s","up":%s,"public_ip":%s,"latency_ms":%s,"down_mbps":%s,"measured_at":%s}' \
			"$separateur" "$nom_du_tunnel" "$est_up" "$(json_adresse_ou_null "$ip_publique")" \
			"$(json_nombre_ou_null "$latence_ms")" "$(json_nombre_ou_null "$debit_mbit")" \
			"$(json_nombre_ou_null "$date_mesure")" >> "$fichier_temporaire"
		separateur=,
	done
	printf ']}\n' >> "$fichier_temporaire"
	mv "$fichier_temporaire" "$fichier_tunnels" 2>/dev/null || return 1
}
