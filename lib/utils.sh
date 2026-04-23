#!/bin/bash
# lib/utils.sh - Utilidades comunes: colores, logging, helpers

# Colores
readonly C_RESET='\033[0m'
readonly C_RED='\033[0;31m'
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[0;33m'
readonly C_BLUE='\033[0;34m'
readonly C_CYAN='\033[0;36m'
readonly C_BOLD='\033[1m'

# Logging
log() {
    local level="$1"
    shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$ts] [$level] $msg" >> "${INSTALL_LOG:-/tmp/odoo-install.log}"
}

info()    { echo -e "${C_CYAN}${C_BOLD}[INFO]${C_RESET} $*"; log "INFO" "$*"; }
ok()      { echo -e "${C_GREEN}${C_BOLD}[ OK ]${C_RESET} $*"; log "OK" "$*"; }
warn()    { echo -e "${C_YELLOW}${C_BOLD}[WARN]${C_RESET} $*"; log "WARN" "$*"; }
err()     { echo -e "${C_RED}${C_BOLD}[ERR ]${C_RESET} $*" >&2; log "ERROR" "$*"; }
step()    { echo -e "\n${C_BLUE}${C_BOLD}▶ $*${C_RESET}"; log "STEP" "$*"; }

# Separador visual
hr() {
    echo -e "${C_BLUE}══════════════════════════════════════════════════${C_RESET}"
}

# Prompt con valor por defecto
# Uso: ask "¿Pregunta?" "default" VAR_OUT
ask() {
    local prompt="$1"
    local default="${2:-}"
    local varname="$3"
    local response

    if [[ -n "$default" ]]; then
        read -r -p "$(echo -e "${C_BOLD}${prompt}${C_RESET} [${C_CYAN}${default}${C_RESET}]: ")" response
        response="${response:-$default}"
    else
        read -r -p "$(echo -e "${C_BOLD}${prompt}${C_RESET}: ")" response
    fi

    printf -v "$varname" '%s' "$response"
}

# Prompt yes/no
# Uso: if confirm "¿Continuar?" "y"; then ... fi
confirm() {
    local prompt="$1"
    local default="${2:-n}"
    local yn_hint response

    if [[ "$default" == "y" ]]; then
        yn_hint="[Y/n]"
    else
        yn_hint="[y/N]"
    fi

    read -r -p "$(echo -e "${C_BOLD}${prompt}${C_RESET} ${yn_hint}: ")" response
    response="${response:-$default}"
    [[ "$response" =~ ^[Yy]$ ]]
}

# Prompt de password oculto con confirmación (o auto-generado)
ask_password() {
    local prompt="$1"
    local varname="$2"
    local pass1 pass2

    while true; do
        read -r -s -p "$(echo -e "${C_BOLD}${prompt}${C_RESET} (Enter para auto-generar): ")" pass1
        echo
        if [[ -z "$pass1" ]]; then
            pass1="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)"
            ok "Password generada automáticamente."
            break
        fi
        read -r -s -p "$(echo -e "${C_BOLD}Confirma la password${C_RESET}: ")" pass2
        echo
        if [[ "$pass1" == "$pass2" ]]; then
            break
        fi
        err "Las passwords no coinciden. Intenta de nuevo."
    done

    printf -v "$varname" '%s' "$pass1"
}

# Ejecuta un comando y oculta la salida salvo en caso de error
run_quiet() {
    local desc="$1"
    shift
    local output
    if output="$("$@" 2>&1)"; then
        log "CMD" "OK: $*"
        return 0
    else
        local rc=$?
        err "$desc falló:"
        echo "$output" | tail -20 >&2
        log "CMD" "FAIL ($rc): $*"
        log "CMD_OUTPUT" "$output"
        return $rc
    fi
}

# Verifica que un comando existe
has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# Genera una password aleatoria
gen_password() {
    local len="${1:-24}"
    openssl rand -base64 48 | tr -d '/+=\n' | head -c "$len"
}
