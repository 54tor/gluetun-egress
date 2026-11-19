#!/bin/sh
# Test de vpngw-firewall.sh avec un faux iptables et un faux ip6tables (l'état des règles est un fichier chacun) : aucune règle réelle, aucun droit root.
# Sortie : « OK <cas> » ou « ECHEC <cas> : attendu [...], obtenu [...] » ; code de sortie 0 si tout passe.
set -u

dossier_du_test=$(cd "$(dirname "$0")" && pwd)
script_a_tester=$dossier_du_test/../../vpngw-firewall.sh
dossier_de_travail=$(mktemp -d)
trap 'rm -rf "$dossier_de_travail"' EXIT
nombre_echecs=0

verifier() {
	if [ "$2" = "$3" ]; then echo "OK $1"; else echo "ECHEC $1 : attendu [$2], obtenu [$3]"; nombre_echecs=$((nombre_echecs + 1)); fi
}

cat > "$dossier_de_travail/iptables" <<'FAUX'
#!/bin/sh
etat=$ETAT_IPTABLES
action=$1
shift
case "$action" in
	-n) [ ! -f "$etat.sans-chaine" ] ;;
	-C) grep -qxF -- "$*" "$etat" ;;
	-I) echo "$*" >> "$etat" ;;
	-D) grep -vxF -- "$*" "$etat" > "$etat.tmp" || true; mv "$etat.tmp" "$etat" ;;
esac
FAUX
sed 's/ETAT_IPTABLES/ETAT_IP6TABLES/' "$dossier_de_travail/iptables" > "$dossier_de_travail/ip6tables"
chmod +x "$dossier_de_travail/iptables" "$dossier_de_travail/ip6tables"
export ETAT_IPTABLES="$dossier_de_travail/etat" IPTABLES="$dossier_de_travail/iptables" ATTENTE_CHAINE=1
export ETAT_IP6TABLES="$dossier_de_travail/etat6" IP6TABLES="$dossier_de_travail/ip6tables"
: > "$ETAT_IPTABLES"
: > "$ETAT_IP6TABLES"

fichier_de_reseaux="$dossier_de_travail/vpngw.conf"
printf '# commentaire\n\n172.30.20.0/24 vpngw-egress\n10.50.2.0/24 vpngw-autre\n' > "$fichier_de_reseaux"

printf 'fd30:20::/64 vpngw-egress\n' > "$dossier_de_travail/ipv6.conf"
sh "$script_a_tester" up "$dossier_de_travail/ipv6.conf" >/dev/null
verifier "ipv6-regle-dans-ip6tables" "DOCKER-USER -s fd30:20::/64 ! -o vpngw-egress -j DROP" "$(sed -n 1p "$ETAT_IP6TABLES")"
verifier "ipv6-rien-dans-iptables" 0 "$(wc -l < "$ETAT_IPTABLES")"
sh "$script_a_tester" up "$dossier_de_travail/ipv6.conf" >/dev/null
verifier "ipv6-up-deux-fois-sans-doublon" 1 "$(wc -l < "$ETAT_IP6TABLES")"
verifier "ipv6-status-posee" "fd30:20::/64 hors de vpngw-egress : posée" "$(sh "$script_a_tester" status "$dossier_de_travail/ipv6.conf" | sed -n 1p)"
touch "$ETAT_IP6TABLES.sans-chaine"
sh "$script_a_tester" up "$dossier_de_travail/ipv6.conf" >/dev/null 2>&1
verifier "ipv6-chaine-absente-echec" 1 "$?"
sh "$script_a_tester" down "$dossier_de_travail/ipv6.conf" >/dev/null 2>&1
verifier "ipv6-down-sans-chaine-sans-erreur" 0 "$?"
rm -f "$ETAT_IP6TABLES.sans-chaine"
sh "$script_a_tester" down "$dossier_de_travail/ipv6.conf" >/dev/null
verifier "ipv6-down-retire" 0 "$(wc -l < "$ETAT_IP6TABLES")"
printf '172.30.20.0/24 vpngw-egress\nfd30:20::/64 vpngw-egress\n' > "$dossier_de_travail/double.conf"
sh "$script_a_tester" up "$dossier_de_travail/double.conf" >/dev/null
verifier "double-famille-une-regle-chacune" "1 1" "$(wc -l < "$ETAT_IPTABLES") $(wc -l < "$ETAT_IP6TABLES")"
sh "$script_a_tester" down "$dossier_de_travail/double.conf" >/dev/null
verifier "double-famille-down" "0 0" "$(wc -l < "$ETAT_IPTABLES") $(wc -l < "$ETAT_IP6TABLES")"
printf 'zz:zz::/64 vpngw-egress\n' > "$dossier_de_travail/mauvais.conf"
sh "$script_a_tester" up "$dossier_de_travail/mauvais.conf" >/dev/null 2>&1
verifier "sous-reseau-ipv6-invalide-refuse" 1 "$?"

sh "$script_a_tester" up "$fichier_de_reseaux" >/dev/null
verifier "deux-reseaux-deux-regles" 2 "$(wc -l < "$ETAT_IPTABLES")"
verifier "forme-de-la-regle" "DOCKER-USER -s 172.30.20.0/24 ! -o vpngw-egress -j DROP" "$(sed -n 1p "$ETAT_IPTABLES")"

sh "$script_a_tester" up "$fichier_de_reseaux" >/dev/null
verifier "up-deux-fois-sans-doublon" 2 "$(wc -l < "$ETAT_IPTABLES")"

sh "$script_a_tester" down "$fichier_de_reseaux" >/dev/null
verifier "down-retire-tout" 0 "$(wc -l < "$ETAT_IPTABLES")"
sh "$script_a_tester" down "$fichier_de_reseaux" >/dev/null
verifier "down-deux-fois-sans-erreur" 0 "$?"

verifier "status-absente" "172.30.20.0/24 hors de vpngw-egress : absente" "$(sh "$script_a_tester" status "$fichier_de_reseaux" | sed -n 1p)"

touch "$ETAT_IPTABLES.sans-chaine"
sh "$script_a_tester" up "$fichier_de_reseaux" >/dev/null 2>&1
verifier "chaine-absente-echec" 1 "$?"
sh "$script_a_tester" down "$fichier_de_reseaux" >/dev/null 2>&1
verifier "down-sans-chaine-sans-erreur" 0 "$?"
rm -f "$ETAT_IPTABLES.sans-chaine"

printf '8.8.8/24 vpngw-egress\n' > "$dossier_de_travail/mauvais.conf"
sh "$script_a_tester" up "$dossier_de_travail/mauvais.conf" >/dev/null 2>&1
verifier "sous-reseau-invalide-refuse" 1 "$?"
printf '172.30.20.0/24 pont-beaucoup-trop-long\n' > "$dossier_de_travail/mauvais.conf"
sh "$script_a_tester" up "$dossier_de_travail/mauvais.conf" >/dev/null 2>&1
verifier "pont-invalide-refuse" 1 "$?"
sh "$script_a_tester" up "$dossier_de_travail/absent.conf" >/dev/null 2>&1
verifier "fichier-absent-refuse" 1 "$?"
sh "$script_a_tester" fusion "$fichier_de_reseaux" >/dev/null 2>&1
verifier "action-inconnue-refusee" 1 "$?"
verifier "rien-pose-apres-refus" 0 "$(wc -l < "$ETAT_IPTABLES")"

[ "$nombre_echecs" -eq 0 ]
