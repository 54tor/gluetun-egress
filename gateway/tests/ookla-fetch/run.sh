#!/bin/sh
# Test des contrôles du CLI Ookla téléchargé (check_speedtest_archive, fetch_speedtest de vpn-check.sh), hors réseau : une archive qui
# ne passe pas un contrôle est refusée avec sa raison, un échec n'est pas retenté avant le délai, une URL en http n'est jamais appelée.
# Le cas positif (vrai binaire d'Ookla) ne se teste qu'avec un vrai téléchargement : voir le README §4.8.
# Sortie : « OK <cas> » ou « ECHEC <cas> : attendu [...], obtenu [...] » ; code de sortie 0 si tout passe.
# shellcheck disable=SC2034
set -u

dossier_du_test=$(cd "$(dirname "$0")" && pwd)
dossier_temporaire=$(mktemp -d)
trap 'rm -rf "$dossier_temporaire"' EXIT
nombre_echecs=0

for fonction in check_speedtest_archive fetch_speedtest tunnel_has_internet; do
	definition=$(sed -n "/^$fonction() {/,/^}/p" "$dossier_du_test/../../vpn-check.sh")
	[ -n "$definition" ] || { echo "ECHEC extraction : $fonction introuvable dans vpn-check.sh"; exit 1; }
	eval "$definition"
done

journal="$dossier_temporaire/journal"
log() { echo "$*" >>"$journal"; }
verifier() {
	if [ "$2" = "$3" ]; then echo "OK $1"; else echo "ECHEC $1 : attendu [$2], obtenu [$3]"; nombre_echecs=$((nombre_echecs + 1)); fi
}

OOKLA_VERSION=1.2.0
elf_assez_gros=$(command -v bash)
[ "$(wc -c <"$elf_assez_gros")" -ge 500000 ] || { echo "ECHEC préparation : bash trop petit pour le test"; exit 1; }

creer_archive() { # $1=nom du fichier de sortie, puis des triplets nom:type:source (type f ou l)
	python3 - "$@" <<'PY'
import sys, tarfile, io
sortie, *membres = sys.argv[1:]
with tarfile.open(sortie, "w:gz") as archive:
    for membre in membres:
        nom, type_, source = membre.split("|", 2)
        if type_ == "l":
            info = tarfile.TarInfo(nom); info.type = tarfile.SYMTYPE; info.linkname = source; archive.addfile(info)
        else:
            contenu = open(source, "rb").read() if source.startswith("/") else source.encode()
            info = tarfile.TarInfo(nom); info.size = len(contenu); info.mode = 0o755; archive.addfile(info, io.BytesIO(contenu))
PY
}

controler() { # $1=cas $2=attendu $3=fragment du journal attendu $4...=membres
	cas=$1; attendu=$2; fragment=$3; shift 3
	: >"$journal"
	rm -rf "$dossier_temporaire/sortie" && mkdir "$dossier_temporaire/sortie"
	creer_archive "$dossier_temporaire/a.tgz" "$@"
	OOKLA_SHA256=$(sha256sum <"$dossier_temporaire/a.tgz" | cut -d ' ' -f 1)
	check_speedtest_archive "$dossier_temporaire/a.tgz" "$dossier_temporaire/sortie" >/dev/null 2>&1
	verifier "$cas-code" "$attendu" "$?"
	grep -q "$fragment" "$journal" && verifier "$cas-raison" ok ok || verifier "$cas-raison" "$fragment" "$(cat "$journal")"
}

controler "trop-petite" 1 "hors de 0,5 à 30 Mo" "speedtest|f|petit"
python3 -c "import os, sys; sys.stdout.buffer.write(b'#!/bin/sh\n' + os.urandom(600000))" >"$dossier_temporaire/script"
controler "membre-absent" 1 "speedtest absent" "autre|f|$elf_assez_gros"
controler "chemin-absolu" 1 "chemin absolu" "speedtest|f|$elf_assez_gros" "/etc/evil|f|x"
controler "chemin-parent" 1 "chemin absolu ou « .. »" "speedtest|f|$elf_assez_gros" "../evil|f|x"
controler "lien-symbolique" 1 "pas un fichier ordinaire" "speedtest|l|/etc/passwd" "bourrage|f|$dossier_temporaire/script"
controler "pas-elf" 1 "pas un exécutable ELF" "speedtest|f|$dossier_temporaire/script"
controler "version-inattendue" 1 "version annoncée" "speedtest|f|$elf_assez_gros"

controler_somme() { # $1=cas $2=somme donnée au script (vide : aucune) $3=fragment du journal attendu
	: >"$journal"
	rm -rf "$dossier_temporaire/sortie" && mkdir "$dossier_temporaire/sortie"
	creer_archive "$dossier_temporaire/a.tgz" "speedtest|f|$elf_assez_gros"
	OOKLA_SHA256=$2
	check_speedtest_archive "$dossier_temporaire/a.tgz" "$dossier_temporaire/sortie" >/dev/null 2>&1
	verifier "$1-code" 1 "$?"
	grep -q "$3" "$journal" && verifier "$1-raison" ok ok || verifier "$1-raison" "$3" "$(cat "$journal")"
}
: >"$dossier_temporaire/vide.tgz"
: >"$journal"
check_speedtest_archive "$dossier_temporaire/vide.tgz" "$dossier_temporaire" >/dev/null 2>&1
verifier "archive-vide-code" 1 "$?"
grep -q "téléchargement vide" "$journal" && verifier "archive-vide-raison" ok ok || verifier "archive-vide-raison" "téléchargement vide" "$(cat "$journal")"
controler_somme "somme-absente" "" "aucune somme SHA-256"
controler_somme "somme-differente" "0000000000000000000000000000000000000000000000000000000000000000" "somme SHA-256 reçue"

# fetch_speedtest : un faux wget compte ses appels
mkdir "$dossier_temporaire/faux"
printf '#!/bin/sh\necho appel >>"%s/appels"\n' "$dossier_temporaire" >"$dossier_temporaire/faux/wget"
chmod +x "$dossier_temporaire/faux/wget"
PATH="$dossier_temporaire/faux:$PATH"
tunnel_has_internet() { return 0; }
appels() { [ -f "$dossier_temporaire/appels" ] && wc -l <"$dossier_temporaire/appels" || echo 0; }
SPEEDTEST_DIR="$dossier_temporaire/speedtest"
SPEEDTEST_BIN="$SPEEDTEST_DIR/speedtest"
OOKLA_URL=https://exemple.invalide/ookla.tgz
OOKLA_RETRY_SECONDS=3600

fetch_speedtest >/dev/null 2>&1
verifier "premier-echec-code" 1 "$?"
verifier "premier-essai-telecharge" 1 "$(appels)"
fetch_speedtest >/dev/null 2>&1
verifier "echec-non-retente-avant-le-delai" 1 "$(appels)"
OOKLA_RETRY_SECONDS=0
fetch_speedtest >/dev/null 2>&1
verifier "retente-apres-le-delai" 2 "$(appels)"
OOKLA_URL=http://exemple.invalide/ookla.tgz
fetch_speedtest >/dev/null 2>&1
verifier "url-http-refusee-code" 1 "$?"
verifier "url-http-sans-appel" 2 "$(appels)"
tunnel_has_internet() { return 1; }
rm -f "$SPEEDTEST_DIR.failed"
OOKLA_URL=https://exemple.invalide/ookla.tgz
fetch_speedtest >/dev/null 2>&1
verifier "sans-internet-code" 1 "$?"
verifier "sans-internet-sans-appel" 2 "$(appels)"
[ ! -f "$SPEEDTEST_DIR.failed" ] && verifier "sans-internet-sans-penalite" ok ok || verifier "sans-internet-sans-penalite" ok penalite
tunnel_has_internet() { return 0; }
mkdir -p "$SPEEDTEST_DIR" && printf '#!/bin/sh\n' >"$SPEEDTEST_BIN" && chmod +x "$SPEEDTEST_BIN"
fetch_speedtest
verifier "binaire-present-pas-de-telechargement" 0 "$?"
verifier "binaire-present-sans-appel" 2 "$(appels)"

[ "$nombre_echecs" -eq 0 ]
