#!/bin/bash
# lib/ssh-setup.sh - Descifrado de SSH key embebida y clonado del repo

# La private key cifrada se inyecta desde install.sh como $ENCRYPTED_SSH_KEY_B64
# El repo se clona a $INSTANCE_DIR/addons-repo

readonly REPO_URL="git@github.com:dualsoftSRL/dualsoft-odoo-addons.git"
readonly REPO_BRANCH="main"

# Descifra la key a un archivo temporal, la usa, y la borra
# Uso: setup_ssh_and_clone <instance_dir>
setup_ssh_and_clone() {
    local instance_dir="$1"
    local passphrase key_file ssh_config_dir addons_dir
    local attempts=0 max_attempts=3

    addons_dir="${instance_dir}/addons-repo"
    ssh_config_dir="${instance_dir}/.ssh-tmp"

    # Pedir passphrase (hasta 3 intentos)
    while (( attempts < max_attempts )); do
        read -r -s -p "$(echo -e "${C_BOLD}Passphrase para descifrar la SSH key${C_RESET}: ")" passphrase </dev/tty
        echo

        if [[ -z "$passphrase" ]]; then
            err "Passphrase vacía."
            attempts=$((attempts + 1))
            continue
        fi

        # Crear directorio temporal seguro
        rm -rf "$ssh_config_dir"
        mkdir -p "$ssh_config_dir"
        chmod 700 "$ssh_config_dir"
        key_file="${ssh_config_dir}/id_ed25519"

        # Descifrar
        if echo "$ENCRYPTED_SSH_KEY_B64" | base64 -d 2>/dev/null | \
           openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -d -salt \
                   -k "$passphrase" > "$key_file" 2>/dev/null; then
            # Verificar que el contenido descifrado es una key SSH válida
            if head -1 "$key_file" | grep -q "BEGIN OPENSSH PRIVATE KEY"; then
                chmod 600 "$key_file"
                ok "SSH key descifrada correctamente."
                break
            fi
        fi

        attempts=$((attempts + 1))
        rm -f "$key_file"
        err "Passphrase incorrecta. Intento $attempts de $max_attempts."
        if (( attempts >= max_attempts )); then
            err "Demasiados intentos fallidos. Abortando."
            rm -rf "$ssh_config_dir"
            return 1
        fi
    done

    # Configurar known_hosts de GitHub
    ssh-keyscan -t ed25519,rsa github.com > "${ssh_config_dir}/known_hosts" 2>/dev/null

    # Variable GIT_SSH_COMMAND para usar esta key sin modificar el sistema
    export GIT_SSH_COMMAND="ssh -i ${key_file} -o UserKnownHostsFile=${ssh_config_dir}/known_hosts -o StrictHostKeyChecking=yes -o IdentitiesOnly=yes"

    info "Clonando repositorio de addons..."

    # Clonar (o actualizar si ya existe)
    if [[ -d "$addons_dir/.git" ]]; then
        info "Repo existente, actualizando..."
        (cd "$addons_dir" && git fetch --depth 1 origin "$REPO_BRANCH" && git reset --hard "origin/${REPO_BRANCH}") >/dev/null 2>&1
    else
        rm -rf "$addons_dir"
        if ! git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$addons_dir" 2>/tmp/git-clone.log; then
            err "Error clonando el repositorio:"
            tail -10 /tmp/git-clone.log >&2
            unset GIT_SSH_COMMAND
            rm -rf "$ssh_config_dir"
            return 1
        fi
    fi

    # Limpiar: quitar la key del disco inmediatamente después del clone
    unset GIT_SSH_COMMAND
    shred -u "$key_file" 2>/dev/null || rm -f "$key_file"
    rm -rf "$ssh_config_dir"

    # Verificar estructura esperada
    if [[ ! -d "${addons_dir}/enterprise" ]] || [[ ! -d "${addons_dir}/terceros" ]]; then
        err "El repo no tiene la estructura esperada (falta carpeta enterprise/ o terceros/)."
        return 1
    fi

    local ent_count ter_count
    ent_count=$(find "${addons_dir}/enterprise" -maxdepth 2 -name "__manifest__.py" 2>/dev/null | wc -l)
    ter_count=$(find "${addons_dir}/terceros" -maxdepth 2 -name "__manifest__.py" 2>/dev/null | wc -l)
    ok "Repo clonado: ${ent_count} módulos en enterprise/, ${ter_count} en terceros/."

    return 0
}
