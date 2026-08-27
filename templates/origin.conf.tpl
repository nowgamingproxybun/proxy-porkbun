server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name __ORIGIN_SERVER_NAMES__;

    ssl_certificate     /etc/letsencrypt/live/__DOMAIN__/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/__DOMAIN__/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;

    # Variable + resolver => DNS at request time (nginx still starts if upstream is down).
    resolver 127.0.0.53 1.1.1.1 8.8.8.8 valid=60s ipv6=off;

    location / {
        set $proxies_backend_upstream "__BACKEND_ORIGIN__";
        proxy_pass https://$proxies_backend_upstream;
        proxy_ssl_server_name on;
        proxy_ssl_name $host;
        proxy_ssl_verify off;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $server_addr;
        proxy_set_header X-Forwarded-For $host;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;

        proxy_set_header CF-Connecting-IP "";
        proxy_set_header CF-RAY "";
        proxy_set_header CF-Visitor "";
        proxy_set_header CF-IPCountry "";
        proxy_set_header CF-Worker "";
        proxy_set_header CDN-Loop "";
        proxy_set_header CF-Request-ID "";
        proxy_set_header True-Client-IP "";
        proxy_set_header X-CF-Loop "";
        proxy_set_header CF-EW-Via "";

        proxy_set_header CF-IPCity "";
        proxy_set_header CF-IPContinent "";
        proxy_set_header CF-IPLatitude "";
        proxy_set_header CF-IPLongitude "";
        proxy_set_header CF-IPRegionCode "";
        proxy_set_header CF-IPTimeZone "";

        proxy_connect_timeout 10s;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
