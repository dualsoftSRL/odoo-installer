#!/bin/bash
# lib/docker-setup.sh - Instalación idempotente de Docker

ensure_docker() {
    if has_cmd docker && docker compose version >/dev/null 2>&1; then
        local docker_version
        docker_version="$(docker --version | awk '{print $3}' | tr -d ',')"
        ok "Docker ya instalado (v${docker_version})."
        return 0
    fi

    info "Instalando Docker Engine + Compose plugin..."

    # Requisitos previos
    run_quiet "apt-get update" apt-get update
    run_quiet "Instalando dependencias" apt-get install -y \
        ca-certificates curl gnupg lsb-release

    # Repositorio oficial de Docker
    install -m 0755 -d /etc/apt/keyrings
    # shellcheck source=/dev/null
    source /etc/os-release
    local os_id="$ID"

    curl -fsSL "https://download.docker.com/linux/${os_id}/gpg" \
        -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/${os_id} \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list

    run_quiet "apt-get update (docker repo)" apt-get update
    run_quiet "Instalando Docker" apt-get install -y \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    systemctl enable --now docker >/dev/null 2>&1 || true

    # Verificación
    if ! docker --version >/dev/null 2>&1; then
        err "La instalación de Docker falló."
        return 1
    fi
    ok "Docker instalado correctamente."
}
