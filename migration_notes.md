## Certifications
sudo mkdir -p ./certbot/conf/live/shamaut.com
sudo chown -R $USER:$USER ./certbot
sudo chmod -R 755 ./certbot

* Generate temporary certificate, while working on the website (IP only, no domain)
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout ./certbot/conf/live/shamaut.com/privkey.pem \
  -out ./certbot/conf/live/shamaut.com/fullchain.pem \
  -subj "/C=US/ST=Denial/L=Springfield/O=Dis/CN=shamaut.com"

* Generate the certificate
docker run --rm \
  -v $(pwd)/certbot/conf:/etc/letsencrypt \
  -v $(pwd)/certbot/www:/var/www/certbot \
  certbot/certbot certonly --webroot -w /var/www/certbot \
  --email alfreds@actappon.com \
  -d shamaut.com -d www.shamaut.com \
  --agree-tos --no-eff-email

* Check existing certificates
ls -lah ./certbot/conf/live/shamaut.com/

* Force renew 
docker exec -it certbot certbot renew --force-renewal

* Verify renewal works
docker exec -it certbot certbot renew --dry-run

