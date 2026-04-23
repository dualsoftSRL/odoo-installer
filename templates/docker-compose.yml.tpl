services:
  traefik:
    image: traefik:v3.1
    container_name: ${INSTANCE_NAME}_traefik
    restart: unless-stopped
    command:
      - "--api.dashboard=false"
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.web.http.redirections.entrypoint.to=websecure"
      - "--entrypoints.web.http.redirections.entrypoint.scheme=https"
      - "--entrypoints.websecure.address=:443"
      - "--certificatesresolvers.letsencrypt.acme.tlschallenge=true"
      - "--certificatesresolvers.letsencrypt.acme.email=${ADMIN_EMAIL}"
      - "--certificatesresolvers.letsencrypt.acme.storage=/letsencrypt/acme.json"
      - "--log.level=INFO"
      - "--accesslog=false"
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./data/letsencrypt:/letsencrypt
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      - odoo_net

  db:
    image: postgres:16
    container_name: ${INSTANCE_NAME}_db
    restart: unless-stopped
    environment:
      POSTGRES_DB: postgres
      POSTGRES_USER: odoo
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      PGDATA: /var/lib/postgresql/data/pgdata
      TZ: America/Santo_Domingo
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U odoo -d postgres"]
      interval: 5s
      timeout: 5s
      retries: 10
    networks:
      - odoo_net

  odoo:
    build:
      context: .
      dockerfile: Dockerfile
    image: ${INSTANCE_NAME}_odoo:latest
    container_name: ${INSTANCE_NAME}_odoo
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    environment:
      HOST: db
      USER: odoo
      PASSWORD: ${DB_PASSWORD}
      TZ: America/Santo_Domingo
    volumes:
      - ./data/odoo:/var/lib/odoo
      - ./addons-repo:/mnt/extra-addons:ro
      - ./config/odoo.conf:/etc/odoo/odoo.conf:ro
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${INSTANCE_NAME}.rule=Host(`${DOMAIN}`)"
      - "traefik.http.routers.${INSTANCE_NAME}.entrypoints=websecure"
      - "traefik.http.routers.${INSTANCE_NAME}.tls.certresolver=letsencrypt"
      - "traefik.http.services.${INSTANCE_NAME}.loadbalancer.server.port=8069"
      - "traefik.http.routers.${INSTANCE_NAME}-ws.rule=Host(`${DOMAIN}`) && PathPrefix(`/websocket`)"
      - "traefik.http.routers.${INSTANCE_NAME}-ws.entrypoints=websecure"
      - "traefik.http.routers.${INSTANCE_NAME}-ws.tls.certresolver=letsencrypt"
      - "traefik.http.routers.${INSTANCE_NAME}-ws.service=${INSTANCE_NAME}-ws"
      - "traefik.http.services.${INSTANCE_NAME}-ws.loadbalancer.server.port=8072"
    networks:
      - odoo_net

networks:
  odoo_net:
    name: ${INSTANCE_NAME}_net
    driver: bridge
