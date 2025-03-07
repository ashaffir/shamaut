# Actappon website 
This is a simple Wordpress website.
Architecture is based on Docker services: Wordpress, MySQL DB and NGINX web server.

## Setup
### Directory structure
```
├── README.md
├── docker-compose.yml
└── nginx
    ├── default.conf
```

### Creating the SSL certificate
1. Modify the default.conf file (for the Nginx), not to include the pem files (remove the secured server section)
2. Start the docker-compose with all that is inside
3. From inside the certbot docker run:

certbot certonly --webroot --webroot-path=/var/www/certbot --email alfreds@actappon.com --agree-tos --no-eff-email -d actappon.com --debug

* For multiple subdomains
1. Use the monolitic structure in this repo for the nginx conf
2. Run (from the certbot docker)
```certbot certonly --manual --preferred-challenges=dns --email alfreds@actappon.com --agree-tos --no-eff-email -d *.actappon.com```

- When promped to add the challenge to the DNS TXT make sure to are the ```_acme-challenge``` only in the TXT DNS (without the .actappon.com)
- Make sure to check that the new TXT entry was propagated using: https://toolbox.googleapps.com/apps/dig/#TXT/_acme-challenge.actappon.com

3. The pem file created are only for the subdomains.

4. Delete the previous actappon.com-0001 directory from the certbot/conf/archive and delete the new one that was created at /etc/letsencrypt/archive/actappon.com-0001
* Notice, the files are in the "archive" directory, not in the live (where they are linking to the archive


either directly to the certbot/conf/live/


### Install docker and docker-compose 

### Run the docker compose
docker-compose up -d



