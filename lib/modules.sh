#!/bin/bash
# lib/modules.sh - Lógica de instalación/actualización de módulos Odoo

# Lista de módulos Enterprise a instalar automáticamente
# (excluyendo los que ya vienen por defecto en Odoo 18 Community)
readonly ENTERPRISE_MODULES=(
    "no_publisher_warranty_contract"
    "accountant"
    "web_studio"
    "stock_barcode"
)

# shellcheck disable=SC2034  # estas variables globales se usan en install.sh
ENTERPRISE_FAILED=()
# shellcheck disable=SC2034
TERCEROS_INSTALLED=()
# shellcheck disable=SC2034
TERCEROS_UPGRADED=()
# shellcheck disable=SC2034
TERCEROS_FAILED=()

# Ejecuta un comando dentro del contenedor de Odoo como usuario odoo
odoo_exec() {
    docker compose -f "${INSTANCE_DIR}/docker-compose.yml" exec -T -u odoo odoo "$@"
}

# Ejecuta una consulta SQL en Postgres
db_query() {
    local sql="$1"
    docker compose -f "${INSTANCE_DIR}/docker-compose.yml" exec -T -e PGPASSWORD="$DB_PASSWORD" db \
        psql -U odoo -d "$INSTANCE_NAME" -tAc "$sql" 2>/dev/null
}

# Crear la base de datos inicial de forma automática
# Usa `odoo -d <db> -i base --stop-after-init` con config de DB vacía
create_initial_database() {
    step "Creando base de datos inicial '${INSTANCE_NAME}'..."

    # Crear la DB en Postgres
    docker compose -f "${INSTANCE_DIR}/docker-compose.yml" exec -T -e PGPASSWORD="$DB_PASSWORD" db \
        psql -U odoo -d postgres -c "CREATE DATABASE \"${INSTANCE_NAME}\" OWNER odoo;" >/dev/null 2>&1 || {
        # Si ya existe, seguimos
        info "La DB '${INSTANCE_NAME}' ya existía."
    }

    info "Inicializando Odoo (puede tardar 2-4 minutos)..."

    # Detener el servicio de Odoo, correr init, y reiniciarlo
    docker compose -f "${INSTANCE_DIR}/docker-compose.yml" stop odoo >/dev/null 2>&1

    # Init con base + idioma ES + país DO
    if ! docker compose -f "${INSTANCE_DIR}/docker-compose.yml" run --rm -T odoo \
        odoo -d "$INSTANCE_NAME" \
        -i base,web \
        --load-language=es_DO \
        --without-demo=all \
        --stop-after-init \
        --no-http >> "$INSTALL_LOG" 2>&1; then
        err "Falló la inicialización de la base de datos."
        return 1
    fi

    # Configurar idioma, país y moneda por defecto
    docker compose -f "${INSTANCE_DIR}/docker-compose.yml" run --rm -T odoo \
        odoo shell -d "$INSTANCE_NAME" --no-http --stop-after-init <<'PYEOF' >> "$INSTALL_LOG" 2>&1
lang = env['res.lang'].with_context(active_test=False).search([('code','=','es_DO')], limit=1)
if lang and not lang.active:
    lang.active = True
env['ir.default'].set('res.partner', 'lang', 'es_DO')
company = env.ref('base.main_company')
country_do = env.ref('base.do', raise_if_not_found=False)
if country_do:
    company.country_id = country_do.id
env.cr.commit()
PYEOF

    # Reiniciar el servicio de Odoo
    docker compose -f "${INSTANCE_DIR}/docker-compose.yml" start odoo >/dev/null 2>&1

    # Esperar que vuelva a estar listo
    local retries=30
    while (( retries > 0 )); do
        if docker compose -f "${INSTANCE_DIR}/docker-compose.yml" exec -T -e PGPASSWORD="$DB_PASSWORD" db \
            psql -U odoo -d "$INSTANCE_NAME" -c "SELECT 1 FROM ir_module_module LIMIT 1" >/dev/null 2>&1; then
            break
        fi
        sleep 2
        retries=$((retries - 1))
    done

    ok "Base de datos '${INSTANCE_NAME}' creada e inicializada."
    return 0
}

# Obtener estado de un módulo en la DB
# Devuelve: "installed" | "uninstalled" | "to upgrade" | "uninstallable" | "not_found"
get_module_state() {
    local module="$1"
    local state
    state=$(db_query "SELECT state FROM ir_module_module WHERE name = '${module}' LIMIT 1;")
    echo "${state:-not_found}"
}

# Actualizar lista de módulos en Odoo (scan filesystem)
update_module_list() {
    docker compose -f "${INSTANCE_DIR}/docker-compose.yml" run --rm -T odoo \
        odoo -d "$INSTANCE_NAME" -u base --stop-after-init --no-http >> "$INSTALL_LOG" 2>&1
}

# Instalar una lista de módulos
install_modules() {
    local modules_csv="$1"
    docker compose -f "${INSTANCE_DIR}/docker-compose.yml" stop odoo >/dev/null 2>&1
    local rc=0
    docker compose -f "${INSTANCE_DIR}/docker-compose.yml" run --rm -T odoo \
        odoo -d "$INSTANCE_NAME" -i "$modules_csv" --stop-after-init --no-http >> "$INSTALL_LOG" 2>&1 || rc=$?
    docker compose -f "${INSTANCE_DIR}/docker-compose.yml" start odoo >/dev/null 2>&1
    return $rc
}

# Actualizar una lista de módulos
upgrade_modules() {
    local modules_csv="$1"
    docker compose -f "${INSTANCE_DIR}/docker-compose.yml" stop odoo >/dev/null 2>&1
    local rc=0
    docker compose -f "${INSTANCE_DIR}/docker-compose.yml" run --rm -T odoo \
        odoo -d "$INSTANCE_NAME" -u "$modules_csv" --stop-after-init --no-http >> "$INSTALL_LOG" 2>&1 || rc=$?
    docker compose -f "${INSTANCE_DIR}/docker-compose.yml" start odoo >/dev/null 2>&1
    return $rc
}

# Instalar los módulos Enterprise requeridos
install_enterprise_modules() {
    step "Instalando módulos Enterprise requeridos..."

    # Primero, scan del filesystem para que Odoo reconozca los módulos nuevos
    info "Escaneando módulos disponibles..."
    update_module_list

    local to_install=()
    local skipped=()
    local failed=()
    local already=()

    for mod in "${ENTERPRISE_MODULES[@]}"; do
        local state
        state=$(get_module_state "$mod")
        case "$state" in
            installed)
                already+=("$mod")
                ;;
            uninstalled|"to install")
                to_install+=("$mod")
                ;;
            not_found)
                skipped+=("$mod (no encontrado en el repo)")
                ;;
            *)
                skipped+=("$mod (estado: $state)")
                ;;
        esac
    done

    if (( ${#already[@]} > 0 )); then
        for m in "${already[@]}"; do
            ok "$m (ya instalado)"
        done
    fi

    if (( ${#to_install[@]} > 0 )); then
        info "Instalando: ${to_install[*]}"
        local csv
        csv=$(IFS=,; echo "${to_install[*]}")
        if install_modules "$csv"; then
            # Verificar uno por uno
            for m in "${to_install[@]}"; do
                local st
                st=$(get_module_state "$m")
                if [[ "$st" == "installed" ]]; then
                    ok "$m instalado"
                else
                    failed+=("$m")
                    err "$m NO se instaló (estado: $st)"
                fi
            done
        else
            err "Falló la instalación en batch. Revisa $INSTALL_LOG"
            for m in "${to_install[@]}"; do
                failed+=("$m")
            done
        fi
    fi

    if (( ${#skipped[@]} > 0 )); then
        for m in "${skipped[@]}"; do
            warn "$m"
        done
    fi

    # Guardar fallidos en variable global para el resumen
    ENTERPRISE_FAILED=("${failed[@]}")
    return 0
}

# Lee la versión declarada en el __manifest__.py de un módulo
get_manifest_version() {
    local module_path="$1"
    local manifest="${module_path}/__manifest__.py"
    [[ -f "$manifest" ]] || { echo "0.0.0"; return; }
    python3 -c "
import ast
try:
    with open('$manifest') as f:
        data = ast.literal_eval(f.read())
    print(data.get('version', '0.0.0'))
except Exception:
    print('0.0.0')
" 2>/dev/null || echo "0.0.0"
}

# Menú interactivo para módulos de terceros
manage_terceros_modules() {
    step "Gestión de módulos de la carpeta 'terceros/'"

    local terceros_dir="${INSTANCE_DIR}/addons-repo/terceros"
    if [[ ! -d "$terceros_dir" ]]; then
        warn "No existe la carpeta terceros/."
        return 0
    fi

    # Refrescar la lista de módulos en Odoo
    info "Escaneando módulos..."
    update_module_list

    # Construir arreglos paralelos con info de cada módulo
    local -a mod_names mod_states mod_fs_versions mod_db_versions
    local idx=0

    while IFS= read -r -d '' manifest; do
        local mod_path mod_name fs_ver state db_ver
        mod_path="$(dirname "$manifest")"
        mod_name="$(basename "$mod_path")"
        fs_ver=$(get_manifest_version "$mod_path")
        state=$(get_module_state "$mod_name")
        db_ver=$(db_query "SELECT latest_version FROM ir_module_module WHERE name = '${mod_name}' LIMIT 1;")
        [[ -z "$db_ver" ]] && db_ver="-"

        mod_names+=("$mod_name")
        mod_states+=("$state")
        mod_fs_versions+=("$fs_ver")
        mod_db_versions+=("$db_ver")
        idx=$((idx + 1))
    done < <(find "$terceros_dir" -maxdepth 2 -name "__manifest__.py" -print0 | sort -z)

    local total=${#mod_names[@]}
    if (( total == 0 )); then
        warn "No se encontraron módulos en terceros/."
        return 0
    fi

    # Mostrar tabla
    echo
    hr
    echo -e "${C_BOLD}MÓDULOS EN terceros/ (${total} encontrados)${C_RESET}"
    hr
    echo "Leyenda: [✓] instalado al día  [↑] actualización disponible  [ ] no instalado  [?] estado raro"
    echo
    printf "  %-4s %-8s %-45s %-25s\n" "#" "Estado" "Módulo" "Versión (DB → FS)"
    echo "  ──────────────────────────────────────────────────────────────────────────────────"

    local i
    for ((i=0; i<total; i++)); do
        local marker ver_str
        case "${mod_states[$i]}" in
            installed)
                if [[ "${mod_db_versions[$i]}" != "${mod_fs_versions[$i]}" && "${mod_db_versions[$i]}" != "-" ]]; then
                    marker="[↑]"
                    ver_str="${mod_db_versions[$i]} → ${mod_fs_versions[$i]}"
                else
                    marker="[✓]"
                    ver_str="${mod_fs_versions[$i]}"
                fi
                ;;
            uninstalled)
                marker="[ ]"
                ver_str="${mod_fs_versions[$i]}"
                ;;
            not_found)
                marker="[ ]"
                ver_str="${mod_fs_versions[$i]} (nuevo)"
                ;;
            *)
                marker="[?]"
                ver_str="${mod_states[$i]}"
                ;;
        esac
        printf "  %-4s %-8s %-45s %-25s\n" "$((i+1))" "$marker" "${mod_names[$i]}" "$ver_str"
    done

    echo
    hr
    echo -e "${C_BOLD}¿Qué deseas hacer?${C_RESET}"
    echo "  [A] Instalar TODOS los no instalados"
    echo "  [U] Actualizar TODOS los desactualizados"
    echo "  [B] Instalar TODOS + actualizar desactualizados (recomendado)"
    echo "  [S] Selección manual (uno por uno)"
    echo "  [N] No hacer nada, terminar"
    echo
    local choice
    read -r -p "Opción [A/U/B/S/N]: " choice </dev/tty
    choice="${choice^^}"

    local -a to_install to_upgrade
    to_install=()
    to_upgrade=()

    case "$choice" in
        A)
            for ((i=0; i<total; i++)); do
                if [[ "${mod_states[$i]}" == "uninstalled" || "${mod_states[$i]}" == "not_found" ]]; then
                    to_install+=("${mod_names[$i]}")
                fi
            done
            ;;
        U)
            for ((i=0; i<total; i++)); do
                if [[ "${mod_states[$i]}" == "installed" && "${mod_db_versions[$i]}" != "${mod_fs_versions[$i]}" && "${mod_db_versions[$i]}" != "-" ]]; then
                    to_upgrade+=("${mod_names[$i]}")
                fi
            done
            ;;
        B)
            for ((i=0; i<total; i++)); do
                if [[ "${mod_states[$i]}" == "uninstalled" || "${mod_states[$i]}" == "not_found" ]]; then
                    to_install+=("${mod_names[$i]}")
                elif [[ "${mod_states[$i]}" == "installed" && "${mod_db_versions[$i]}" != "${mod_fs_versions[$i]}" && "${mod_db_versions[$i]}" != "-" ]]; then
                    to_upgrade+=("${mod_names[$i]}")
                fi
            done
            ;;
        S)
            for ((i=0; i<total; i++)); do
                local mod_name="${mod_names[$i]}"
                local state="${mod_states[$i]}"
                echo
                echo -e "  ${C_BOLD}[$((i+1))/$total] ${mod_name}${C_RESET} (estado: $state, versión FS: ${mod_fs_versions[$i]})"
                case "$state" in
                    installed)
                        if [[ "${mod_db_versions[$i]}" != "${mod_fs_versions[$i]}" && "${mod_db_versions[$i]}" != "-" ]]; then
                            if confirm "  ¿Actualizar? (DB: ${mod_db_versions[$i]} → FS: ${mod_fs_versions[$i]})" "y"; then
                                to_upgrade+=("$mod_name")
                            fi
                        else
                            echo "  Ya instalado y al día, se omite."
                        fi
                        ;;
                    uninstalled|not_found)
                        if confirm "  ¿Instalar?" "n"; then
                            to_install+=("$mod_name")
                        fi
                        ;;
                    *)
                        warn "  Estado inusual '$state', se omite."
                        ;;
                esac
            done
            ;;
        N|*)
            info "No se realizarán cambios en terceros/."
            TERCEROS_INSTALLED=()
            TERCEROS_UPGRADED=()
            TERCEROS_FAILED=()
            return 0
            ;;
    esac

    # Ejecutar
    TERCEROS_INSTALLED=()
    TERCEROS_UPGRADED=()
    TERCEROS_FAILED=()

    if (( ${#to_install[@]} > 0 )); then
        info "Instalando ${#to_install[@]} módulo(s): ${to_install[*]}"
        local csv
        csv=$(IFS=,; echo "${to_install[*]}")
        if install_modules "$csv"; then
            for m in "${to_install[@]}"; do
                if [[ "$(get_module_state "$m")" == "installed" ]]; then
                    TERCEROS_INSTALLED+=("$m")
                    ok "$m instalado"
                else
                    TERCEROS_FAILED+=("$m (instalación)")
                    err "$m NO se instaló"
                fi
            done
        else
            for m in "${to_install[@]}"; do
                TERCEROS_FAILED+=("$m (instalación en batch)")
            done
            err "La instalación en batch falló. Revisa $INSTALL_LOG"
        fi
    fi

    if (( ${#to_upgrade[@]} > 0 )); then
        info "Actualizando ${#to_upgrade[@]} módulo(s): ${to_upgrade[*]}"
        local csv
        csv=$(IFS=,; echo "${to_upgrade[*]}")
        if upgrade_modules "$csv"; then
            for m in "${to_upgrade[@]}"; do
                TERCEROS_UPGRADED+=("$m")
                ok "$m actualizado"
            done
        else
            for m in "${to_upgrade[@]}"; do
                TERCEROS_FAILED+=("$m (actualización)")
            done
            err "La actualización en batch falló. Revisa $INSTALL_LOG"
        fi
    fi

    return 0
}
