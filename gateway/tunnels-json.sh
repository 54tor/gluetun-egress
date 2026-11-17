# shellcheck shell=sh
# Écriture de tunnels.json : l'état de chaque tunnel (up, IP publique, latence, débit) pour la supervision.
# Source de entrypoint.sh. La mesure d'un tunnel est écrite par vpn-check.sh dans <dossier>/<tunnel>/measure :
# « latence_ms débit_mbit date [ip_publique [débit_montant_mbit]] », dans un volume que le Gluetun écrit : le fichier n'est pas fiable (lu
# seulement s'il est un fichier ordinaire, jamais un lien, et chaque champ est validé). Sans mesure lisible, les champs de mesure valent null.

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

# Les adresses qui joignent le proxy d'entrée depuis le Gluetun du tunnel « vpn<N> » : la N-ième de VPN_IPS et de VPN_IPS6. Un
# consommateur les rapproche de la table des connexions du proxy (clé : adresse source) pour compter celles de chaque ligne.
# Un nom qui n'est pas « vpn<N> », ou un rang hors liste, rend « [] » : jamais d'erreur, le JSON reste valide.
json_adresses_d_entree() {
	rang_du_tunnel=${1#vpn}
	case "$rang_du_tunnel" in '' | *[!0-9]*) echo '[]'; return 0 ;; esac
	adresses_json=
	for liste in "${VPN_IPS:-}" "${VPN_IPS6:-}"; do
		position=0
		for adresse in $liste; do
			position=$((position + 1))
			[ "$position" = "$rang_du_tunnel" ] || continue
			case "$adresse" in *[!0-9a-fA-F.:]*) continue ;; esac
			adresses_json="$adresses_json${adresses_json:+,}\"$adresse\""
		done
	done
	echo "[$adresses_json]"
}

# Lit la première ligne, 255 octets au plus, hors du shell principal et sous délai : un fichier remplacé par un tube
# entre le contrôle et la lecture ne bloque pas la boucle de sonde. Une ligne de 256 octets ou plus est refusée.
lire_ligne_de_mesure() {
	ligne_lue=$(timeout 2 head -c 256 -- "$1" 2>/dev/null | head -n 1) || return 0
	[ "${#ligne_lue}" -lt 256 ] && printf '%s' "$ligne_lue"
	return 0
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
		latence_ms= debit_mbit= date_mesure= ip_publique= debit_montant_mbit=
		fichier_de_mesure="$dossier_des_mesures/$nom_du_tunnel/measure"
		ligne_de_mesure=
		if [ -f "$fichier_de_mesure" ] && [ ! -L "$fichier_de_mesure" ]; then
			ligne_de_mesure=$(lire_ligne_de_mesure "$fichier_de_mesure")
		fi
		read -r latence_ms debit_mbit date_mesure ip_publique debit_montant_mbit <<EOF_MESURE
$ligne_de_mesure
EOF_MESURE
		printf '%s{"name":"%s","up":%s,"public_ip":%s,"latency_ms":%s,"down_mbps":%s,"up_mbps":%s,"measured_at":%s,"ingress_ips":%s}' \
			"$separateur" "$nom_du_tunnel" "$est_up" "$(json_adresse_ou_null "$ip_publique")" \
			"$(json_nombre_ou_null "$latence_ms")" "$(json_nombre_ou_null "$debit_mbit")" "$(json_nombre_ou_null "$debit_montant_mbit")" \
			"$(json_nombre_ou_null "$date_mesure")" "$(json_adresses_d_entree "$nom_du_tunnel")" >> "$fichier_temporaire"
		separateur=,
	done
	printf ']}\n' >> "$fichier_temporaire"
	mv "$fichier_temporaire" "$fichier_tunnels" 2>/dev/null || return 1
}
