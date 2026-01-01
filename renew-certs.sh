#!/bin/bash
# Renew SSL certificates and reload nginx

echo "Checking for certificate renewal..."
docker-compose exec -T certbot certbot renew --quiet

# If renewal was successful or certificates are still valid
if [ $? -eq 0 ] || [ $? -eq 1 ]; then
  echo "Reloading nginx..."
  docker-compose exec -T nginx nginx -s reload
  echo "Done!"
else
  echo "Certificate renewal failed!"
  exit 1
fi

