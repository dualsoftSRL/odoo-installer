#!/bin/bash
###############################################################################
# Dualsoft Odoo Installer - Bootstrap
###############################################################################
set -Eeuo pipefail

REPO="${ODOO_INSTALLER_REPO:-dualsoftSRL/odoo-installer}"
BRANCH="${ODOO_INSTALLER_BRANCH:-main}"

C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_CYAN='\033[0;36m'
C_RESET='\033[0m'

info()  { echo -e "${C_CYAN}▶${C_RESET} $*"; }
ok()    { echo -e "${C_GREEN}✓${C_RESET} $*"; }
err()   { echo -e "${C_RED}✗${C_RESET} $*" >&2; }

if [[ $EUID -ne 0 ]]; then
    err "Este script debe ejecutarse como root (usa sudo)."
    exit 1
fi

if ! curl -fsS --max-time 5 https://github.com >/dev/null 2>&1; then
    err "Sin conectividad a GitHub."
    exit 1
fi

for cmd in tar curl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        err "Falta comando requerido: $cmd"
        exit 1
    fi
done

TMPDIR=$(mktemp -d -t odoo-installer-XXXXXX)
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

info "Descargando instalador (${REPO}@${BRANCH})..."

URL="https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz"
if ! curl -fsSL "$URL" -o "$TMPDIR/installer.tar.gz"; then
    err "Error descargando desde $URL"
    exit 1
fi

tar xzf "$TMPDIR/installer.tar.gz" -C "$TMPDIR"

INSTALLER_DIR=""
for d in "$TMPDIR"/*/; do
    [[ -d "$d" && -f "${d}install.sh" ]] && INSTALLER_DIR="${d%/}" && break
done

if [[ -z "$INSTALLER_DIR" ]]; then
    err "Estructura del instalador inesperada."
    echo "Contenido descargado en $TMPDIR:" >&2
    ls -la "$TMPDIR" >&2
    for d in "$TMPDIR"/*/; do
        [[ -d "$d" ]] && echo "--- contenido de $d ---" >&2 && ls -la "$d" >&2
    done
    exit 1
fi

ok "Instalador descargado."

chmod +x "$INSTALLER_DIR/install.sh"
exec bash "$INSTALLER_DIR/install.sh" "$@" </dev/tty
