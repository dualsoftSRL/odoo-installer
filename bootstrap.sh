#!/bin/bash
###############################################################################
# Dualsoft Odoo Installer - Bootstrap
# Descarga y ejecuta el instalador completo
###############################################################################
set -Eeuo pipefail

REPO="dualsoftSRL/odoo-installer"
BRANCH="main"
TMPDIR=$(mktemp -d -t odoo-installer-XXXXXX)

cleanup() {
    rm -rf "$TMPDIR"
}
trap cleanup EXIT

echo "▶ Descargando instalador desde github.com/${REPO}..."

if ! curl -fsSL "https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz" \
    -o "$TMPDIR/installer.tar.gz"; then
    echo "✗ Error descargando el instalador." >&2
    exit 1
fi

tar xzf "$TMPDIR/installer.tar.gz" -C "$TMPDIR"
cd "$TMPDIR/odoo-installer-${BRANCH}"

chmod +x install.sh
exec bash install.sh "$@"
