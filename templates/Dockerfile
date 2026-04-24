FROM odoo:18

USER root

# Paquetes del sistema frecuentes en addons (OCA, localizaciones)
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3-pip \
    git \
    libldap2-dev \
    libsasl2-dev \
    libxml2-dev \
    libxslt1-dev \
    libjpeg-dev \
    libpq-dev \
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
