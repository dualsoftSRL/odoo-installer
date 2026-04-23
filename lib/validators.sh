#!/bin/bash
# lib/validators.sh - Validaciones previas y durante la instalación

# Verifica que se ejecute como root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        err "Este script debe ejecutarse como root (usa sudo)."
        exit 1
    fi
}

# Valida SO soportado
check_os() {
    if [[ ! -f /etc/os-release ]]; then
        err "No se puede detectar el sistema operativo."
        exit 1
    fi
    # shellcheck source=/dev/null
    source /etc/os-release
    case "$ID" in
        ubuntu)
            if [[ ! "$VERSION_ID" =~ ^(22\.04|24\.04)$ ]]; then
                err "Ubuntu $VERSION_ID no soportado. Usa 22.04 o 24.04."
                exit 1
            fi
            ;;
        debian)
            if [[ ! "$VERSION_ID" =~ ^12$ ]]; then
                err "Debian $VERSION_ID no soportado. Usa Debian 12."
                exit 1
            fi
            ;;
        *)
            err "SO no soportado: $ID. Usa Ubuntu 22.04/24.04 o Debian 12."
            exit 1
            ;;
    esac
    ok "Sistema operativo: $PRETTY_NAME"
}

# Valida arquitectura
check_arch() {
    local arch
    arch="$(uname -m)"
    if [[ "$arch" != "x86_64" && "$arch" != "aarch64" ]]; then
        err "Arquitectura no soportada: $arch"
        exit 1
    fi
    ok "Arquitectura: $arch"
}

# Valida recursos mínimos
check_resources() {
    local ram_mb disk_gb
    ram_mb=$(free -m | awk '/^Mem:/{print $2}')
    disk_gb=$(df -BG / | awk 'NR==2{gsub("G","",$4); print $4}')

    if (( ram_mb < 1800 )); then
        err "RAM insuficiente: ${ram_mb}MB. Se requieren al menos 2GB."
        exit 1
    fi
    if (( disk_gb < 20 )); then
        err "Espacio en disco insuficiente: ${disk_gb}GB. Se requieren al menos 20GB."
        exit 1
    fi
    ok "RAM: ${ram_mb}MB | Disco libre: ${disk_gb}GB"
}

# Valida puertos 80 y 443 libres
check_ports() {
    local port in_use=0
    for port in 80 443; do
        if ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE ":${port}$"; then
            err "Puerto $port está en uso. Libéralo antes de continuar."
            in_use=1
        fi
    done
    (( in_use == 0 )) || exit 1
    ok "Puertos 80 y 443 disponibles."
}

# Valida conectividad a internet
check_internet() {
    if ! curl -fsS --max-time 5 https://www.google.com >/dev/null 2>&1; then
        err "Sin conectividad a internet."
        exit 1
    fi
    ok "Conectividad a internet confirmada."
}

# Valida formato de dominio
is_valid_domain() {
    local domain="$1"
    [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]]
}

# Valida formato de email
is_valid_email() {
    local email="$1"
    [[ "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

# Valida nombre de instancia (sin espacios, solo alfanumérico y guiones)
is_valid_instance_name() {
    local name="$1"
    [[ "$name" =~ ^[a-z][a-z0-9_-]{2,30}$ ]]
}

# Obtiene IP pública del VPS
get_public_ip() {
    curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null \
        || curl -fsS --max-time 5 https://ifconfig.me 2>/dev/null \
        || echo ""
}

# Verifica que el dominio resuelva al IP de este VPS
check_dns_points_here() {
    local domain="$1"
    local public_ip resolved_ip
    public_ip="$(get_public_ip)"
    if [[ -z "$public_ip" ]]; then
        warn "No se pudo obtener IP pública del VPS."
        return 1
    fi
    resolved_ip="$(dig +short +time=3 +tries=1 "$domain" A | tail -1)"
    if [[ -z "$resolved_ip" ]]; then
        warn "El dominio $domain no tiene registro A."
        return 1
    fi
    if [[ "$resolved_ip" != "$public_ip" ]]; then
        warn "El dominio $domain apunta a $resolved_ip, pero este VPS es $public_ip."
        return 1
    fi
    ok "DNS OK: $domain → $public_ip"
    return 0
}
