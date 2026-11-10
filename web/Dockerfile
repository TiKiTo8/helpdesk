FROM nginx:1.29-alpine

# nginx tourne avec son propre utilisateur : il doit pouvoir écrire son cache et son fichier pid
RUN chown -R nginx:nginx /var/cache/nginx /run

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html /usr/share/nginx/html/index.html

USER nginx
