FROM nginx:1.29-alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY site/ /usr/share/nginx/html/
COPY version.json /usr/share/nginx/html/version.json
RUN chmod -R a+rX /usr/share/nginx/html

EXPOSE 80
