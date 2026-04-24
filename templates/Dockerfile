FROM odoo:18

USER root

# Paquetes del sistema frecuentes en addons (OCA, localizaciones)
# Nota: libpq-dev no se instala porque la imagen odoo:18 ya trae Postgres client moderno.
# Se usa --fix-broken por si algún addon requiere resolución de deps complejas.
RUN apt-get update && apt-get install -y --no-install-recommends --fix-broken \
    python3-pip \
    git \
    libldap2-dev \
    libsasl2-dev \
    libxml2-dev \
    libxslt1-dev \
    libjpeg-dev \
    fonts-liberation \
    && rm -rf /var/lib/apt/lists/*

# Dependencias Python comunes para addons de terceros
RUN pip install --no-cache-dir --break-system-packages \
    python-stdnum \
    phonenumbers \
    xlsxwriter \
    openpyxl \
    qrcode \
    python-barcode \
    cryptography \
    pycryptodome \
    requests \
    unidecode \
    google-auth \
    cachetools \
    || true

# Instalar dependencias específicas del repo si existen
COPY requirements.txt /tmp/requirements.txt
RUN if [ -s /tmp/requirements.txt ]; then \
      pip install --no-cache-dir --break-system-packages -r /tmp/requirements.txt || true; \
    fi && rm -f /tmp/requirements.txt

USER odoo
