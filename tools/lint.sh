#!/bin/sh
# Contrôles statiques : shellcheck, hadolint, actionlint et gitleaks (historique compris), chacun dans un conteneur Docker (images non
# épinglées, comme le reste du projet). Réglages : .shellcheckrc, .hadolint.yaml. Appelé par la CI ; à lancer avant de proposer un changement.
# Sortie : une section par outil ; code de sortie 0 si tout passe.
set -u

racine=$(cd "$(dirname "$0")/.." && pwd)
cd "$racine" || exit 1
nombre_echecs=0

etape() {
	echo "== $1"
	shift
	"$@" || nombre_echecs=$((nombre_echecs + 1))
}

# shellcheck disable=SC2046
etape shellcheck docker run --rm -v "$racine:/mnt:ro" -w /mnt koalaman/shellcheck:stable -S warning $(git ls-files '*.sh')
etape hadolint sh -c 'docker run --rm -i -v "$1/.hadolint.yaml:/.config/hadolint.yaml:ro" hadolint/hadolint < "$1/gateway/Dockerfile"' _ "$racine"
etape actionlint docker run --rm -v "$racine:/repo:ro" -w /repo rhysd/actionlint:latest
etape gitleaks docker run --rm -v "$racine:/repo:ro" -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0=/repo \
	zricethezav/gitleaks:latest detect --source /repo --no-banner --redact

[ "$nombre_echecs" -eq 0 ]
