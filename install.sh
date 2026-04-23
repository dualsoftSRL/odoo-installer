#!/bin/bash
###############################################################################
# Dualsoft - Odoo 18 Installer
# Instalación automatizada de Odoo 18 + Postgres 16 + Traefik (SSL) + addons
# Uso: sudo bash install.sh
###############################################################################

set -Eeuo pipefail

# ──────────────────────────────────────────────────────────────
# SSH KEY CIFRADA (embebida) - Repo: dualsoftSRL/dualsoft-odoo-addons
# Descifrar requiere la passphrase que se pide al técnico al ejecutar.
# ──────────────────────────────────────────────────────────────
readonly ENCRYPTED_SSH_KEY_B64="U2FsdGVkX19/i9r3uVJdO1MRjYPq5RtNR5mpYzS06XS9AYPFpx4b8PjApOaBQ0Ntveutixr4Lln0vixXIeD27XzyhyHWK5he0DHWXvS6fVWMOem/hBMC2pxWF51OphXYthyAPcRpMQPYIUgOK3PoywUb32US0eAcx2cwpkv0GrgJ1SKDrN8UUwgnTbk7szeGO2LfbsDbX8ix2q8Q76yPyF+skA5Lxzbnx+F4/j9OfUJGMAPn0Jx3+5WgF5E882Tc7m0+yx1u1wkI66O2sR+1DLvEtNS/yLDbq/VwfsWak7IYMMI1HIZwfJY0f6A1EXyCV1LmA7R3+psl7k5CHdJSd+Mbc859fMKA1mNtaeRzyXBlOUl0hA1O9h1gLQtx880+Fb+lNF7A08dd5sKb0j+QBPWkz1al5hReNM3o0qcFB/CyQVb4LRqe+umEH1Iob8+5yX56ZN7AvdE7FyHFfVfIOXZVmCu5oAVpV2ySZlVA1KFZicreUYEWP9oEGWX6LYF+W2iH3DMeafpamsQwJcCGT/ARp2z3RZNdCPlojIKL02sinMY3/GAFvmpsggHebZ1q"

# ──────────────────────────────────────────────────────────────
# Variables globales
# ──────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly INSTALL_BASE="/opt/odoo"
INSTANCE_NAME=""
INSTANCE_DIR=""
DOMAIN=""
ADMIN_EMAIL=""
MASTER_PASSWORD=""
DB_PASSWORD=""
WORKERS=2
CRON_THREADS=2
PUBLIC_IP=""
INSTALL_LOG="/tmp/odoo-install-$(date +%Y%m%d-%H%M%S).log"

# Arrays globales para reporte final
ENTERPRISE_FAILED=()
TERCEROS_INSTALLED=()
TERCEROS_UPGRADED=()
TERCEROS_FAILED=()

# ──────────────────────────────────────────────────────────────
# Cargar librerías
# ──────────────────────────────────────────────────────────────
# shellcheck source=lib/utils.sh
source "${SCRIPT_DIR}/lib/utils.sh"
# shellcheck source=lib/validators.sh
source "${SCRIPT_DIR}/lib/validators.sh"
# shellcheck source=lib/docker-setup.sh
source "${SCRIPT_DIR}/lib/docker-setup.sh"
# shellcheck source=lib/ssh-setup.sh
source "${SCRIPT_DIR}/lib/ssh-setup.sh"
# shellcheck source=lib/modules.sh
source "${SCRIPT_DIR}/lib/modules.sh"

# ──────────────────────────────────────────────────────────────
# Manejo de errores
# ──────────────────────────────────────────────────────────────
rollback() {
    local exit_code="$1"
    local line="$2"

    echo
    err "El instalador falló (exit=$exit_code en línea $line)."
    err "Log completo: $INSTALL_LOG"
    echo

    if [[ -n "$INSTANCE_DIR" && -d "$INSTANCE_DIR" ]]; then
        if confirm "¿Deseas hacer rollback completo (borrar todo lo creado)?" "y"; then
            info "Ejecutando rollback..."
            if [[ -f "${INSTANCE_DIR}/docker-compose.yml" ]]; then
                docker compose -f "${INSTANCE_DIR}/docker-compose.yml" down -v --remove-orphans 2>/dev/null || true
            fi
            rm -rf "$INSTANCE_DIR"
            ok "Rollback completo."
        else
            warn "Instalación parcial preservada en $INSTANCE_DIR"
        fi
    fi

    # Mostrar últimas líneas del log
    echo
    err "Últimas 20 líneas del log:"
    tail -20 "$INSTALL_LOG" 2>/dev/null || true
    exit "$exit_code"
}

trap 'rollback $? $LINENO' ERR

# ──────────────────────────────────────────────────────────────
# Banner
# ──────────────────────────────────────────────────────────────
banner() {
    clear
    cat <<'EOF'

  ╔══════════════════════════════════════════════════════╗
  ║                                                      ║
  ║     DUALSOFT - ODOO 18 INSTALLER                     ║
  ║     Odoo 18 + PostgreSQL 16 + Traefik (SSL)          ║
  ║                                                      ║
  ╚══════════════════════════════════════════════════════╝

EOF
}

# ──────────────────────────────────────────────────────────────
# Cálculo automático de workers
# ──────────────────────────────────────────────────────────────
calculate_workers() {
    local cores ram_mb
    cores=$(nproc)
    ram_mb=$(free -m | awk '/^Mem:/{print $2}')

    # Fórmula oficial: (cores * 2) + 1
    local calc=$(( (cores * 2) + 1 ))

    # Limitar por RAM: cada worker ~200MB
    local by_ram=$(( (ram_mb - 1024) / 250 ))
    if (( by_ram < calc )); then
        calc=$by_ram
    fi

    # Mínimo 0 (sin workers = multithreading), máximo 16
    if (( calc < 2 )); then
        WORKERS=0
        CRON_THREADS=1
    elif (( calc > 16 )); then
        WORKERS=16
        CRON_THREADS=2
    else
        WORKERS=$calc
        CRON_THREADS=2
    fi

    info "Recursos: ${cores} CPU / ${ram_mb}MB RAM → ${WORKERS} workers, ${CRON_THREADS} cron threads"
}

# ──────────────────────────────────────────────────────────────
# Recolección de datos del técnico
# ──────────────────────────────────────────────────────────────
collect_inputs() {
    step "Configuración de la instalación"

    # Nombre de instancia
    while true; do
        ask "Nombre del cliente / instancia (solo minúsculas, sin espacios)" "" INSTANCE_NAME
        if is_valid_instance_name "$INSTANCE_NAME"; then
            INSTANCE_DIR="${INSTALL_BASE}/${INSTANCE_NAME}"
            if [[ -d "$INSTANCE_DIR" ]]; then
                warn "Ya existe una instalación en $INSTANCE_DIR"
                if confirm "¿Sobrescribir? (se perderán datos existentes)" "n"; then
                    info "Limpiando instalación anterior..."
                    if [[ -f "${INSTANCE_DIR}/docker-compose.yml" ]]; then
                        docker compose -f "${INSTANCE_DIR}/docker-compose.yml" down -v --remove-orphans 2>/dev/null || true
                    fi
                    rm -rf "$INSTANCE_DIR"
                    break
                fi
            else
                break
            fi
        else
            err "Nombre inválido. Debe empezar con letra, 3-30 caracteres, solo minúsculas/números/guiones."
        fi
    done

    # Dominio
    while true; do
        ask "Dominio completo (ej: erp.cliente.com)" "" DOMAIN
        if is_valid_domain "$DOMAIN"; then
            break
        fi
        err "Dominio con formato inválido."
    done

    # Email admin (para Let's Encrypt)
    while true; do
        ask "Email del administrador (para Let's Encrypt)" "" ADMIN_EMAIL
        if is_valid_email "$ADMIN_EMAIL"; then
            break
        fi
        err "Email con formato inválido."
    done

    # Master password (auto o manual)
    ask_password "Master password de Odoo (admin_passwd)" MASTER_PASSWORD

    # DB password (auto siempre, no la necesita el usuario)
    DB_PASSWORD="$(gen_password 32)"

    # Workers: automático
    calculate_workers

    # Confirmación final
    echo
    hr
    echo -e "${C_BOLD}Resumen de la instalación:${C_RESET}"
    echo "  Instancia:       $INSTANCE_NAME"
    echo "  Dominio:         https://$DOMAIN"
    echo "  Email admin:     $ADMIN_EMAIL"
    echo "  Directorio:      $INSTANCE_DIR"
    echo "  Workers:         $WORKERS"
    echo "  Cron threads:    $CRON_THREADS"
    echo "  Postgres:        16"
    echo "  Zona horaria:    America/Santo_Domingo"
    hr
    echo

    if ! confirm "¿Proceder con la instalación?" "y"; then
        info "Instalación cancelada por el usuario."
        exit 0
    fi
}

# ──────────────────────────────────────────────────────────────
# Validación de DNS
# ──────────────────────────────────────────────────────────────
validate_dns() {
    step "Validando DNS del dominio $DOMAIN"
    PUBLIC_IP="$(get_public_ip)"
    info "IP pública del VPS: $PUBLIC_IP"

    if check_dns_points_here "$DOMAIN"; then
        return 0
    fi

    warn "El dominio $DOMAIN no apunta correctamente a este VPS."
    warn "El certificado SSL FALLARÁ si no se corrige."
    echo
    echo "Configura un registro A: $DOMAIN → $PUBLIC_IP"
    echo
    if ! confirm "¿Continuar de todos modos? (NO recomendado)" "n"; then
        info "Instalación cancelada. Configura el DNS primero."
        exit 0
    fi
}

# ──────────────────────────────────────────────────────────────
# Renderizado de plantillas
# ──────────────────────────────────────────────────────────────
render_templates() {
    step "Generando archivos de configuración"
    mkdir -p "$INSTANCE_DIR"/{config,data/postgres,data/odoo,data/letsencrypt,addons-repo}
    touch "$INSTANCE_DIR/data/letsencrypt/acme.json"
    chmod 600 "$INSTANCE_DIR/data/letsencrypt/acme.json"

    # Exportar variables para envsubst
    export INSTANCE_NAME DOMAIN ADMIN_EMAIL DB_PASSWORD MASTER_PASSWORD WORKERS CRON_THREADS

    envsubst '${INSTANCE_NAME} ${DOMAIN} ${ADMIN_EMAIL} ${DB_PASSWORD}' \
        < "${SCRIPT_DIR}/templates/docker-compose.yml.tpl" \
        > "${INSTANCE_DIR}/docker-compose.yml"

    envsubst '${MASTER_PASSWORD} ${DB_PASSWORD} ${WORKERS} ${CRON_THREADS}' \
        < "${SCRIPT_DIR}/templates/odoo.conf.tpl" \
        > "${INSTANCE_DIR}/config/odoo.conf"

    cp "${SCRIPT_DIR}/templates/Dockerfile" "${INSTANCE_DIR}/Dockerfile"

    ok "Archivos de configuración generados."
}

# ──────────────────────────────────────────────────────────────
# Auto-detección de dependencias de los addons
# ──────────────────────────────────────────────────────────────
detect_addon_dependencies() {
    step "Detectando dependencias Python de los addons"
    local addons_dir="${INSTANCE_DIR}/addons-repo"
    local req_file="${INSTANCE_DIR}/requirements.txt"

    # Unir todos los requirements.txt encontrados en los addons
    : > "$req_file"
    find "$addons_dir" -maxdepth 3 -name "requirements.txt" -print0 2>/dev/null | while IFS= read -r -d '' f; do
        cat "$f" >> "$req_file"
        echo "" >> "$req_file"
    done

    # Extraer external_dependencies de todos los __manifest__.py
    python3 <<PYEOF >> "$req_file" 2>/dev/null || true
import ast, glob, os
pkgs = set()
for manifest in glob.glob("${addons_dir}/*/*/__manifest__.py"):
    try:
        with open(manifest) as f:
            data = ast.literal_eval(f.read())
        ext = data.get('external_dependencies', {})
        for p in ext.get('python', []):
            pkgs.add(p)
    except Exception:
        pass
for p in sorted(pkgs):
    print(p)
PYEOF

    # Limpiar duplicados y líneas vacías
    if [[ -s "$req_file" ]]; then
        sort -u "$req_file" | grep -v '^\s*$' | grep -v '^#' > "${req_file}.clean"
        mv "${req_file}.clean" "$req_file"
        local count
        count=$(wc -l < "$req_file")
        ok "Detectadas $count dependencias Python."
    else
        ok "No se detectaron dependencias Python adicionales."
    fi
}

# ──────────────────────────────────────────────────────────────
# Build de la imagen Odoo
# ──────────────────────────────────────────────────────────────
build_odoo_image() {
    step "Construyendo imagen Odoo con dependencias"
    cd "$INSTANCE_DIR"
    if ! docker compose build odoo >> "$INSTALL_LOG" 2>&1; then
        err "Fallo construyendo la imagen Odoo. Ver log: $INSTALL_LOG"
        return 1
    fi
    ok "Imagen Odoo construida."
}

# ──────────────────────────────────────────────────────────────
# Levantar servicios
# ──────────────────────────────────────────────────────────────
start_services() {
    step "Levantando servicios (DB, Odoo, Traefik)"
    cd "$INSTANCE_DIR"

    # Levantar DB primero y esperar healthy
    docker compose up -d db >> "$INSTALL_LOG" 2>&1
    local retries=30
    while (( retries > 0 )); do
        local health
        health=$(docker inspect --format='{{.State.Health.Status}}' "${INSTANCE_NAME}_db" 2>/dev/null || echo "starting")
        if [[ "$health" == "healthy" ]]; then
            ok "PostgreSQL listo."
            break
        fi
        sleep 2
        retries=$((retries - 1))
    done
    if (( retries == 0 )); then
        err "PostgreSQL no arrancó correctamente."
        return 1
    fi

    # Levantar Odoo y Traefik
    docker compose up -d odoo traefik >> "$INSTALL_LOG" 2>&1
    sleep 5

    # Esperar que Odoo responda en el puerto 8069 (interno)
    retries=30
    while (( retries > 0 )); do
        if docker compose exec -T odoo curl -fsS http://localhost:8069/web/database/selector >/dev/null 2>&1; then
            ok "Odoo respondiendo internamente."
            break
        fi
        sleep 3
        retries=$((retries - 1))
    done

    if (( retries == 0 )); then
        err "Odoo no responde en el puerto interno."
        return 1
    fi

    ok "Servicios arriba."
}

# ──────────────────────────────────────────────────────────────
# Verificación final
# ──────────────────────────────────────────────────────────────
verify_ssl_and_http() {
    step "Verificando HTTPS y certificado SSL"
    info "Esperando emisión del certificado (hasta 60s)..."

    local retries=20
    while (( retries > 0 )); do
        local http_code
        http_code=$(curl -k -s -o /dev/null -w "%{http_code}" "https://${DOMAIN}/web/login" --max-time 10 2>/dev/null || echo "000")
        if [[ "$http_code" =~ ^(200|303|302)$ ]]; then
            # Verificar que el cert NO sea self-signed (Traefik default)
            if echo | openssl s_client -servername "$DOMAIN" -connect "${DOMAIN}:443" 2>/dev/null | \
               openssl x509 -noout -issuer 2>/dev/null | grep -qi "let's encrypt\|letsencrypt"; then
                ok "HTTPS + Let's Encrypt funcionando (HTTP $http_code)."
                return 0
            fi
        fi
        sleep 3
        retries=$((retries - 1))
    done

    warn "El certificado Let's Encrypt aún no se emitió. Puede tardar unos minutos más."
    warn "Verifica manualmente: curl -v https://${DOMAIN}"
    return 0
}

# ──────────────────────────────────────────────────────────────
# Guardar credenciales y crear uninstall
# ──────────────────────────────────────────────────────────────
save_credentials() {
    local cred_file="${INSTANCE_DIR}/.credentials"
    cat > "$cred_file" <<EOF
# Credenciales de Odoo - ${INSTANCE_NAME}
# Generado: $(date)

URL=https://${DOMAIN}
DOMAIN=${DOMAIN}
INSTANCE_NAME=${INSTANCE_NAME}
ADMIN_EMAIL=${ADMIN_EMAIL}
MASTER_PASSWORD=${MASTER_PASSWORD}
DB_PASSWORD=${DB_PASSWORD}
DB_NAME=${INSTANCE_NAME}
WORKERS=${WORKERS}
INSTANCE_DIR=${INSTANCE_DIR}
EOF
    chmod 600 "$cred_file"

    # Script de uninstall específico
    cat > "${INSTANCE_DIR}/uninstall.sh" <<EOF
#!/bin/bash
# Desinstala la instancia ${INSTANCE_NAME}
set -e
if [[ \$EUID -ne 0 ]]; then echo "Requiere sudo"; exit 1; fi
echo "ADVERTENCIA: esto eliminará TODO sobre ${INSTANCE_NAME} (datos incluidos)."
read -p "Escribe '${INSTANCE_NAME}' para confirmar: " confirm
if [[ "\$confirm" != "${INSTANCE_NAME}" ]]; then echo "Cancelado."; exit 1; fi
cd "${INSTANCE_DIR}"
docker compose down -v --remove-orphans
cd /
rm -rf "${INSTANCE_DIR}"
docker image rm "${INSTANCE_NAME}_odoo:latest" 2>/dev/null || true
echo "Instancia ${INSTANCE_NAME} eliminada completamente."
EOF
    chmod +x "${INSTANCE_DIR}/uninstall.sh"
}

# ──────────────────────────────────────────────────────────────
# Setup de cron de backups
# ──────────────────────────────────────────────────────────────
setup_backup_cron() {
    local backup_script="${INSTANCE_DIR}/backup.sh"
    local backup_dir="/opt/backups/${INSTANCE_NAME}"
    mkdir -p "$backup_dir"

    cat > "$backup_script" <<EOF
#!/bin/bash
# Backup diario de ${INSTANCE_NAME}
set -e
TS=\$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="${backup_dir}"
mkdir -p "\$BACKUP_DIR"

# Dump de la DB
docker compose -f "${INSTANCE_DIR}/docker-compose.yml" exec -T -e PGPASSWORD="${DB_PASSWORD}" db \\
    pg_dump -U odoo -Fc "${INSTANCE_NAME}" > "\$BACKUP_DIR/db-\$TS.dump"

# Filestore
tar czf "\$BACKUP_DIR/filestore-\$TS.tar.gz" -C "${INSTANCE_DIR}/data" odoo 2>/dev/null || true

# Rotar: conservar últimos 7 días
find "\$BACKUP_DIR" -name "*.dump" -mtime +7 -delete
find "\$BACKUP_DIR" -name "*.tar.gz" -mtime +7 -delete
EOF
    chmod +x "$backup_script"

    # Agregar al cron (evitar duplicados)
    local cron_line="0 3 * * * ${backup_script} >> /var/log/odoo-backup-${INSTANCE_NAME}.log 2>&1"
    ( crontab -l 2>/dev/null | grep -v "${backup_script}" ; echo "$cron_line" ) | crontab -

    ok "Cron de backup configurado (diario a las 3am)."
}

# ──────────────────────────────────────────────────────────────
# Resumen final
# ──────────────────────────────────────────────────────────────
final_summary() {
    echo
    hr
    echo -e "${C_GREEN}${C_BOLD}  ✓ INSTALACIÓN COMPLETA${C_RESET}"
    hr
    echo -e "  ${C_BOLD}URL:${C_RESET}            https://${DOMAIN}"
    echo -e "  ${C_BOLD}Instancia:${C_RESET}      ${INSTANCE_NAME}"
    echo -e "  ${C_BOLD}Base de datos:${C_RESET}  ${INSTANCE_NAME}"
    echo -e "  ${C_BOLD}Master pwd:${C_RESET}     ${MASTER_PASSWORD}"
    echo
    echo -e "  ${C_BOLD}Paths importantes:${C_RESET}"
    echo "    Config:       ${INSTANCE_DIR}/"
    echo "    Credenciales: ${INSTANCE_DIR}/.credentials"
    echo "    Log install:  ${INSTALL_LOG}"
    echo "    Backups:      /opt/backups/${INSTANCE_NAME}/"
    echo
    echo -e "  ${C_BOLD}Comandos útiles:${C_RESET}"
    echo "    Ver logs:     docker compose -f ${INSTANCE_DIR}/docker-compose.yml logs -f odoo"
    echo "    Reiniciar:    docker compose -f ${INSTANCE_DIR}/docker-compose.yml restart"
    echo "    Desinstalar:  sudo bash ${INSTANCE_DIR}/uninstall.sh"
    hr

    # Reporte de módulos
    echo
    echo -e "${C_BOLD}Módulos Enterprise:${C_RESET}"
    if (( ${#ENTERPRISE_FAILED[@]} == 0 )); then
        echo -e "  ${C_GREEN}✓ Todos instalados correctamente${C_RESET}"
    else
        echo -e "  ${C_RED}Fallidos:${C_RESET}"
        for m in "${ENTERPRISE_FAILED[@]}"; do echo "    ✗ $m"; done
    fi

    echo
    echo -e "${C_BOLD}Módulos Terceros:${C_RESET}"
    echo "  Instalados: ${#TERCEROS_INSTALLED[@]}"
    echo "  Actualizados: ${#TERCEROS_UPGRADED[@]}"
    echo "  Fallidos: ${#TERCEROS_FAILED[@]}"
    if (( ${#TERCEROS_FAILED[@]} > 0 )); then
        echo -e "  ${C_RED}Detalle de fallos:${C_RESET}"
        for m in "${TERCEROS_FAILED[@]}"; do echo "    ✗ $m"; done
    fi
    hr
    echo
}

# ──────────────────────────────────────────────────────────────
# MAIN
# ──────────────────────────────────────────────────────────────
main() {
    banner

    # Inicializar log
    touch "$INSTALL_LOG"
    log "INIT" "Iniciando instalación en $(date)"

    step "Verificando pre-requisitos del sistema"
    check_root
    check_os
    check_arch
    check_resources
    check_ports
    check_internet

    step "Verificando Docker"
    ensure_docker

    # Recolectar inputs del técnico
    collect_inputs

    # Validar DNS ANTES de construir nada
    validate_dns

    # Descifrar key + clonar repo
    step "Configurando acceso al repositorio de addons"
    mkdir -p "$INSTANCE_DIR"
    if ! setup_ssh_and_clone "$INSTANCE_DIR"; then
        err "No se pudo clonar el repositorio de addons."
        exit 1
    fi

    # Generar configs
    render_templates

    # Detectar deps y build
    detect_addon_dependencies
    build_odoo_image

    # Levantar servicios
    start_services

    # Crear DB
    create_initial_database

    # Instalar módulos Enterprise
    install_enterprise_modules

    # Menú interactivo de terceros
    manage_terceros_modules

    # Verificar SSL
    verify_ssl_and_http

    # Guardar credenciales y uninstall
    save_credentials
    setup_backup_cron

    # Desactivar trap de rollback (ya terminamos bien)
    trap - ERR

    # Resumen
    final_summary
}

main "$@"
