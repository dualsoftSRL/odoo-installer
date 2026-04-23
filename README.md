# Dualsoft Odoo 18 Installer

Instalador automatizado de Odoo 18 + PostgreSQL 16 + Traefik (SSL) con addons de `dualsoftSRL/dualsoft-odoo-addons`.

## Para el técnico que lo ejecuta

**Pre-requisitos en el VPS:**
- Ubuntu 22.04 / 24.04 o Debian 12
- Mínimo 2GB RAM, 20GB disco
- Acceso root (sudo)
- Puertos 80 y 443 libres
- Dominio apuntando (registro A) al IP del VPS

**Ejecución:**
```bash
sudo bash install.sh
```

El script va a pedir:
1. Passphrase para descifrar la SSH key (**se la das tú al técnico por canal privado**)
2. Nombre de la instancia (ej: `cliente1`)
3. Dominio completo (ej: `erp.cliente.com`)
4. Email admin (para Let's Encrypt)
5. Master password de Odoo (o Enter para auto-generar)
6. Menú interactivo de módulos `terceros/`

## Estructura del proyecto

```
odoo-installer/
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

## Distribución al técnico

Este proyecto se distribuye como un **tarball** (NO scripts sueltos), porque el instalador necesita las librerías y templates al lado:

```bash
# Desde la máquina del desarrollador, empaquetar:
cd /home/claude
tar czf odoo-installer.tar.gz odoo-installer/

# Subir a un servidor con auth (o mandar por canal privado)
# En el VPS, el técnico ejecuta:
wget https://tu-servidor/odoo-installer.tar.gz
tar xzf odoo-installer.tar.gz
cd odoo-installer
sudo bash install.sh
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
   ```
4. Reemplazar el valor de `ENCRYPTED_SSH_KEY_B64` en `install.sh` con el contenido de `new_key.enc.b64`.
5. Re-distribuir el tarball con la nueva passphrase.

## Sobre workers de Odoo

Se calculan automáticamente:
- Fórmula: `(CPUs × 2) + 1`
- Ajustado por RAM (cada worker ~250MB)
- Mínimo 0 (multithreading puro si el VPS es muy chico)
- Máximo 16

Ejemplos:
| CPUs | RAM | Workers |
|------|-----|---------|
| 2 | 4GB | 5 |
| 4 | 8GB | 9 |
| 8 | 16GB | 16 |

## Instalaciones múltiples en un mismo VPS

El script soporta varios clientes en el mismo VPS siempre que:
- Cada uno tenga un **nombre de instancia distinto**
- Cada uno tenga un **dominio distinto**

Traefik actúa como router único y dirige por dominio. Pero ojo:
- Solo puede haber **un** contenedor en puertos 80/443. El primer instalador arranca Traefik, los siguientes deberían reutilizarlo (mejora futura a implementar si aplica).

Para ahora, asume **un cliente por VPS**.

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
- Con `list_db = False` en config, el selector de DB está oculto. Para gestión de DBs, acceder directamente a `https://dominio/web/database/manager` (requiere master password)

## Seguridad

- La private key embebida está **cifrada con AES-256-CBC** (PBKDF2, 100k iteraciones)
- Sin passphrase correcta, el script es inútil para clonar el repo
- La key se descifra **solo en memoria/tmp** y se borra inmediatamente después del clone con `shred`
- Las credenciales se guardan en `.credentials` con `chmod 600`
- Todos los contenedores corren en una red Docker aislada
