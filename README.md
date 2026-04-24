# Dualsoft Odoo 18 Installer

Instalador automatizado de Odoo 18 + PostgreSQL 16 + Traefik (SSL) con addons de `dualsoftSRL/dualsoft-odoo-addons`.

## Comando único para el técnico

En un VPS limpio con Ubuntu 22.04/24.04 o Debian 12:

```bash
curl -fsSL https://raw.githubusercontent.com/dualsoftSRL/odoo-installer/main/bootstrap.sh | sudo bash
```

## Pre-requisitos del VPS

- Ubuntu 22.04 / 24.04 o Debian 12
- Mínimo 2 GB RAM, 20 GB disco libre
- Acceso root (sudo)
- Puertos 80 y 443 libres
- Dominio apuntando (registro A) al IP del VPS

## Lo que va a pedir el script

1. Nombre de la instancia (ej: `cliente1`)
2. Dominio completo (ej: `erp.cliente.com`)
3. Email admin (para Let's Encrypt)
4. Master password de Odoo (Enter para auto-generar)
5. **Passphrase de la SSH key** (tú se la das al técnico por canal privado)
6. Menú interactivo de módulos `terceros/`

## Estructura del proyecto

```
odoo-installer/
├── bootstrap.sh            # Entrypoint remoto (descarga y ejecuta)
├── install.sh              # Script principal
├── lib/
│   ├── utils.sh            # Colores, logging, prompts
│   ├── validators.sh       # Validaciones (OS, DNS, puertos...)
│   ├── docker-setup.sh     # Instalación de Docker
│   ├── ssh-setup.sh        # Descifrado de key + git clone
│   └── modules.sh          # Lógica de módulos Odoo
├── templates/
│   ├── docker-compose.yml.tpl
│   ├── odoo.conf.tpl
│   └── Dockerfile
└── README.md
```

## Variables de entorno para testing

Útiles al probar en VMs pequeñas:

```bash
# Bajar el mínimo de RAM requerido (default 1800 MB)
export ODOO_MIN_RAM_MB=1024

# Bajar el mínimo de disco (default 20 GB)
export ODOO_MIN_DISK_GB=5

# Usar otra rama del repo (default: main)
export ODOO_INSTALLER_BRANCH=develop

# Usar otro fork (default: dualsoftSRL/odoo-installer)
export ODOO_INSTALLER_REPO=usuario/otro-repo

# Ejecutar preservando las env vars:
sudo -E bash bootstrap.sh
```

O todo inline:
```bash
curl -fsSL https://raw.githubusercontent.com/dualsoftSRL/odoo-installer/main/bootstrap.sh | \
  sudo -E ODOO_MIN_DISK_GB=5 bash
```

## Rotar la SSH key

Si necesitas cambiar la key o passphrase:

1. Generar nueva key en local:
   ```bash
   ssh-keygen -t ed25519 -C "dualsoft-odoo" -f ~/new_key -N ""
   ```
2. Agregar `new_key.pub` como Deploy Key en GitHub (read-only), borrar la anterior.
3. Cifrar con nueva passphrase:
   ```bash
   openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt \
     -in ~/new_key -out ~/new_key.enc -k 'NUEVA_PASSPHRASE'
   base64 -i ~/new_key.enc -o ~/new_key.enc.b64
   tr -d '\n' < ~/new_key.enc.b64
   ```
4. Copia el output y reemplaza el valor de `ENCRYPTED_SSH_KEY_B64` en `install.sh` (todo en una línea).
5. Push a GitHub.

## Sobre workers de Odoo

Se calculan automáticamente:
- Fórmula: `(CPUs × 2) + 1`
- Ajustado por RAM (cada worker ~250 MB)
- Mínimo 0 (multithreading puro si el VPS es muy chico)
- Máximo 16

| CPUs | RAM   | Workers |
|------|-------|---------|
| 2    | 4 GB  | 5       |
| 4    | 8 GB  | 9       |
| 8    | 16 GB | 16      |

## Flujo del instalador

1. Validaciones de pre-requisitos (OS, RAM, disco, puertos, internet)
2. Recolección de datos (instancia, dominio, email, master password)
3. Validación de DNS (que el dominio apunte al VPS)
4. Instalación de Docker si falta
5. Passphrase → descifrado de SSH key → clone del repo
6. Auto-detección de dependencias Python de los addons
7. Build de imagen Docker con esas dependencias
8. Levantar servicios (DB → Odoo → Traefik) con healthchecks
9. Creación automática de la DB (idioma `es_DO`, país DO)
10. Instalación automática de 4 módulos Enterprise
11. Menú interactivo para módulos de la carpeta `terceros/`
12. Verificación de SSL + resumen final

## Troubleshooting común

**"El certificado Let's Encrypt no se emitió":**
- Verifica DNS: `dig +short tu-dominio.com` debe mostrar el IP del VPS
- Verifica puertos 80/443 abiertos en firewall del proveedor
- Let's Encrypt tiene rate limits: si fallas muchas veces, espera 1 hora
- Revisar: `docker logs <instance>_traefik`

**"Algunos módulos de terceros fallan al instalar":**
- Normal, a veces tienen deps no declaradas
- Revisar: `docker logs <instance>_odoo | grep -i error`
- Instalar la dep manualmente y reintentar el módulo desde la UI

**"No puedo acceder al admin de Odoo":**
- La master password está en `/opt/odoo/<instancia>/.credentials`
- Con `list_db = False`, el selector de DB está oculto. Para gestión, accede a `https://dominio/web/database/manager`

## Seguridad

- La private key embebida está cifrada con AES-256-CBC (PBKDF2, 100k iteraciones)
- Sin passphrase correcta, el script no puede clonar el repo
- La key se descifra solo en memoria/tmp y se borra con `shred` inmediatamente después del clone
- Las credenciales se guardan en `.credentials` con `chmod 600`
- Todos los contenedores corren en una red Docker aislada
