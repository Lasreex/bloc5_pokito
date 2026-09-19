# On part d'une image Nginx ultra-légère (Alpine Linux)
FROM nginx:alpine

# On copie notre page HTML dans le dossier web par défaut de Nginx
COPY website/* /usr/share/nginx/html/

# On expose le port 80 (standard HTTP)
EXPOSE 80