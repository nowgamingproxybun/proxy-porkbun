# IP-facing management API (default_server on HTTP).
# Clients call http://<vm-public-ip>/api/game/url-extended/<client> with Basic Auth
# (shared username/password for all clients). HTTPS is not used here because a
# publicly trusted certificate cannot be issued for a raw IP.

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    location / {
        return 404 '{"status":"NOT_FOUND"}';
        default_type application/json;
    }

    # HTTP-01 for manual domains (no InternetBS DNS API).
    location ^~ /.well-known/acme-challenge/ {
        root __ACME_WEBROOT__;
        default_type text/plain;
    }

    # Require client suffix: /api/game/url-extended/<client>
    location = /api/game/url-extended {
        auth_basic           "proxies domain API";
        auth_basic_user_file __API_HTPASSWD__;
        default_type application/json;
        add_header Cache-Control "no-store" always;
        return 404 '{"status":"NOT_FOUND","message":"Use /api/game/url-extended/<client>"}';
    }

    location ~ ^/api/game/url-extended/([A-Za-z0-9][A-Za-z0-9_-]*)$ {
        auth_basic           "proxies domain API";
        auth_basic_user_file __API_HTPASSWD__;

        set $api_client $1;

        # Static files reject POST with 405. Named error_page locations keep POST,
        # so they 405 again. URI-based error_page switches the method to GET.
        # Game clients (Apache-HttpClient) POST; body is ignored.
        error_page 418 = /__proxies_urls/$api_client.json;
        return 418;
    }

    location /__proxies_urls/ {
        internal;
        default_type application/json;
        add_header Cache-Control "no-store" always;
        alias __URLS_ROOT__/urls/;
    }
}

# Catch HTTPS to the raw IP so it does not fall through to a domain vhost.
# No certificate is required; the handshake is rejected.
server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name _;
    ssl_reject_handshake on;
}
