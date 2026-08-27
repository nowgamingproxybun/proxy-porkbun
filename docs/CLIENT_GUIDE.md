# Client guide — domain rotation proxies

This guide explains how to install and operate the proxy toolkit on an **Ubuntu 26.04** VM.

## What this system does

Once a day (or on demand), the toolkit checks whether a new domain is due. With the default **Porkbun** interval it:

1. Picks a **random 20-letter `.com` domain**
2. Checks that it is **available** on Porkbun
3. **Registers** the domain (account credit)
4. Points the domain and `*.domain` DNS **A** records to this VM’s public IP
5. Issues a **wildcard SSL certificate** (Let’s Encrypt)
6. Configures **nginx** with two virtual hosts:
   - **CDN:** `cdn.<domain>` and `lobby-prod-cdn.<domain>` → `--cdn-origin`
   - **Backend:** per-client + shared hostname prefixes → `--backend-origin`

One VM / one rotated domain can host **multiple clients**. Each client is a file under `/etc/proxies/clients/<name>.env`; hostname labels like `{name}-gc-prod` and `{name}-gc-prod-bgsp` are generated from shared templates.

How often a **new** domain is purchased is set at install with `--rotate-every-days` (default **1**). Cron still runs daily so incomplete setups can resume and expired local configs can be cleaned up.

Older domains stay online for **`--retention-days`** (default **14**), then their local nginx configs and certificates are removed from the VM.

To skip purchases and use names you already own, see **[Manual domains](#manual-domains-skip-porkbun-purchase)**.

---

## Requirements

Before you start, make sure you have:

| Requirement | Notes |
|-------------|--------|
| Ubuntu 26.04 server | Fresh VM is fine; install/rotation refuse other releases |
| Root / sudo access | Install and rotation must run as root |
| Porkbun API key + secret key | Required for automatic purchase. Optional in `--domain-source manual` |
| Porkbun account credit | Each new `domain/create` spends prepaid credit (Porkbun mode only) |
| Own domain names (manual mode) | `--domain NAME` / `/etc/proxies/domains.list` — no purchase |
| One or more client ids | Hostname prefix id(s), e.g. `clientname42` (`--client`, repeatable) |
| CDN origin host | Upstream for CDN vhost (`--cdn-origin`) |
| Backend origin host | Upstream for backend vhost (`--backend-origin`) |
| Real email address | `--email`: Let's Encrypt ACME account |
| Public GitHub repo URL | Used as `--base-url` (installer downloads package files from it) |

Porkbun WHOIS uses the **account contact** on porkbun.com (privacy on by default). No `registrant.env` is required.

Porkbun API registration also needs: verified account email + phone, enough credit, and **at least one domain already bought on the website** (first API purchase is blocked otherwise). Create keys at https://porkbun.com/account/api .

---

## Quick start (recommended)

### Step 1 — Install

Replace `OWNER/REPO` with your public GitHub repository and fill in the other placeholders:

```bash
curl -fsSL https://raw.githubusercontent.com/OWNER/REPO/main/install.sh | sudo bash -s -- \
  --api-key 'YOUR_PORKBUN_API_KEY' \
  --password 'YOUR_PORKBUN_SECRET_KEY' \
  --client 'clientname42' \
  --client 'otherclient' \
  --cdn-origin 'cdn.your-upstream.example' \
  --backend-origin 'backend.your-upstream.example' \
  --email 'you@your-real-domain.com' \
  --rotate-every-days 2 \
  --api-user 'domainapi' \
  --api-password 'CHOOSE_A_STRONG_PASSWORD' \
  --base-url 'https://github.com/OWNER/REPO'
```

`--client` is **repeatable** . Each client gets `/etc/proxies/clients/<name>.env`.

`--rotate-every-days` (default `1`) controls how often a **new** domain is purchased. Cron still runs every day at 03:00 to resume incomplete jobs and clean up expired local configs. On-demand `force-rotate.sh` always buys/resumes immediately and ignores the interval.

To install from a non-`main` branch or tag:

```bash
... --base-url 'https://github.com/OWNER/REPO' --github-ref 'v1.2.3'
```

`--base-url` also accepts:

- `https://github.com/OWNER/REPO/tree/main`
- `https://raw.githubusercontent.com/OWNER/REPO/main`

This will:

- Download the toolkit into `/opt/proxies/`
- Install `nginx`, `certbot`, `curl`, and `jq`
- Save credentials (origins, email, rotation/retention) to `/etc/proxies/credentials.env`
- Create `/etc/proxies/clients/<name>.env` for each `--client`
- Install prefix templates: `prefixes-client.env` + `prefixes-shared.env`
- Create Basic Auth for the IP API (`/etc/proxies/api.htpasswd`)
- Schedule a daily check at **03:00** (system time); purchases follow `--rotate-every-days`

### Step 2 — Porkbun credit and API access

1. Create an API key + secret at https://porkbun.com/account/api  
2. Add **account credit** at https://porkbun.com/account (API purchases spend this balance, not a card per domain)  
3. Verify account email and phone  
4. Register **one domain on the website** first if the account has never bought one (Porkbun blocks the first API registration otherwise)  
5. Optional: enable auto top-up and a monthly spend cap on the API settings page  

`--email` is only used for Let's Encrypt / Certbot.

### Step 3 — Run the first domain rotation

```bash
sudo /opt/proxies/scripts/force-rotate.sh
```

When it finishes, it prints the new domain name. Example hostnames for `--client clientname42`:

```text
cdn.NEWdomain.com
lobby-prod-cdn.NEWdomain.com
clientname42-gs-prod.NEWdomain.com
clientname42-gs-prod-bgsp.NEWdomain.com
clientname42-gs-demo-prod.NEWdomain.com
clientname42-gs-demo-prod-bgsp.NEWdomain.com
clientname42-lobby-prod.NEWdomain.com
clientname42-lobby-prod-bgsp.NEWdomain.com
clientname42-api-prod.NEWdomain.com
clientname42-api-prod-bgsp.NEWdomain.com
clientname42-gc-prod.NEWdomain.com
clientname42-gc-prod-bgsp.NEWdomain.com
lottery-api-instant.NEWdomain.com
lottery-api-instant-prod.NEWdomain.com
lottery-web-prod.NEWdomain.com
player-history-prod.NEWdomain.com
player-history-prod-bgsp.NEWdomain.com
tournaments-prod.NEWdomain.com
tournaments-prod-bgsp.NEWdomain.com
replays-ong-prod-ext.NEWdomain.com
```

Add another client later (no reinstall / no new domain purchase):

```bash
sudo /opt/proxies/scripts/manage-clients.sh add otherclient
# optional:
sudo /opt/proxies/scripts/manage-clients.sh add otherclient --casino-id othercasino

sudo /opt/proxies/scripts/manage-clients.sh list
sudo /opt/proxies/scripts/manage-clients.sh remove oldclient --yes
sudo /opt/proxies/scripts/manage-clients.sh sync   # re-apply after manual edits under clients/
```

`manage-clients.sh` updates `/etc/proxies/clients/`, refreshes nginx origin sites for all tracked domains, and regenerates `/api/game/url-extended/<client>` JSON for the current domain.

### One-shot install

```bash
curl -fsSL https://raw.githubusercontent.com/OWNER/REPO/main/install.sh | sudo bash -s -- \
  --api-key 'YOUR_PORKBUN_API_KEY' \
  --password 'YOUR_PORKBUN_SECRET_KEY' \
  --client 'YOUR_CLIENT_NAME' \
  --cdn-origin 'cdn.your-upstream.example' \
  --backend-origin 'backend.your-upstream.example' \
  --email 'you@your-real-domain.com' \
  --api-user 'domainapi' \
  --api-password 'CHOOSE_A_STRONG_PASSWORD' \
  --base-url 'https://github.com/OWNER/REPO' \
  --run-now
```

---

## Manual domains (skip Porkbun purchase)

You do not have to buy random `.com` names. Set `DOMAIN_SOURCE=manual` and list the FQDNs you already own.

**New install:**

```bash
curl -fsSL https://raw.githubusercontent.com/OWNER/REPO/main/install.sh | sudo bash -s -- \
  --domain-source manual \
  --domain 'already-owned.com' \
  --domain 'second-owned.com' \
  --client 'clientname42' \
  --cdn-origin 'cdn.your-upstream.example' \
  --backend-origin 'backend.your-upstream.example' \
  --email 'you@your-real-domain.com' \
  --api-user 'domainapi' \
  --api-password 'CHOOSE_A_STRONG_PASSWORD' \
  --base-url 'https://github.com/OWNER/REPO'
```

`--domain` is repeatable and implies `--domain-source manual`. `--api-key` / `--password` are optional:

| Porkbun keys | What happens |
|--------------|--------------|
| Provided | Skip `domain/create`. Toolkit still writes A records and issues a **wildcard** cert via DNS-01 (domains must already be at Porkbun). |
| Omitted | You point `already-owned.com` and `*.already-owned.com` A records to this VM. Toolkit issues an HTTP-01 cert covering CDN + origin hostnames (not a wildcard). |

**Already installed (Porkbun mode → manual):**

```bash
sudo nano /etc/proxies/credentials.env
# set: DOMAIN_SOURCE="manual"
# leave PORKBUN_* filled if those domains are at Porkbun; otherwise clear them

sudo nano /etc/proxies/domains.list
# one FQDN per line

sudo /opt/proxies/scripts/force-rotate.sh --use-domain already-owned.com
```

**Day to day:**

```bash
# Add another owned name
echo 'third-owned.com' | sudo tee -a /etc/proxies/domains.list
sudo /opt/proxies/scripts/force-rotate.sh --use-domain third-owned.com

# Activate the next unused name from the list
sudo /opt/proxies/scripts/force-rotate.sh
```

Listed manual domains are **not** removed by `--retention-days` cleanup. Cron still resumes incomplete setups.

After you add a client in HTTP-01 mode (no Porkbun keys), `manage-clients.sh add` expands the certificate so the new hostnames are included.

---

## Current domain URLs API (`/api/game/url-extended/<client>`)

After at least one successful rotation, the VM exposes an **HTTP** endpoint on its **public IP** . Use Basic Auth credentials from install (`--api-user` / `--api-password`) — the **same** password for every client. Append the client id to the path:

```bash
VM_IP="$(curl -4 -fsS https://ifconfig.me)"

curl --location "http://${VM_IP}/api/game/url-extended/clientname42" \
  --header 'Content-Type: application/json' \
  --header "Authorization: Basic $(printf '%s' 'domainapi:CHOOSE_A_STRONG_PASSWORD' | base64)"
```

Or with curl’s `-u`:

```bash
curl -u 'domainapi:CHOOSE_A_STRONG_PASSWORD' "http://${VM_IP}/api/game/url-extended/clientname42"
```

Example response shape:

```json
{
  "hostUrl": "https://clientname42-gc-prod.NEWdomain.com",
  "apiServerUrl": "https://clientname42-api-prod.NEWdomain.com",
  "casinoId": "clientname42",
  "campaignUrl": "https://campaign-prod.NEWdomain.com",
  "jackpotContributionUrl": "https://timescale-service-prod.NEWdomain.com",
  "reconciliationUrl": "https://history-service-prod.NEWdomain.com",
  "matchHistoryUrl": "https://player-history-prod.NEWdomain.com",
  "tournamentUrl": "https://tournaments-prod.NEWdomain.com",
  "status": "OK"
}
```

Notes:

- `GET` and `POST` both return the JSON (`POST` is what the Java game client uses). The request body is ignored.
- Path must include the client id (`/api/game/url-extended/<client>`). Bare `/api/game/url-extended` returns 404 with a hint.
- Unknown clients (no `/var/lib/proxies/urls/<client>.json`) return 404.
- URL hostnames use the current rotated domain. `hostUrl` / `apiServerUrl` include the client id; the other URL fields are shared prefixes.
- `casinoId` defaults to the client filename (override with `CASINO_ID=` in that client’s `.env`).
- Each `force-rotate` / daily rotation regenerates the JSON files.

---

## Clean up a previous install

To wipe toolkit files from the VM (nginx proxies sites, cron, `/opt/proxies`, `/etc/proxies`, `/var/lib/proxies`, rotation log, and tracked Let's Encrypt certs):

```bash
curl -fsSL https://raw.githubusercontent.com/OWNER/REPO/main/cleanup.sh | sudo bash -s -- --yes
```

Or if the package is already on disk:

```bash
sudo /opt/proxies/scripts/cleanup.sh --yes
```

Optional flags:

```bash
# Also apt-purge nginx/certbot/apache2-utils
sudo /opt/proxies/scripts/cleanup.sh --yes --purge-packages

# Keep Let's Encrypt certs
sudo /opt/proxies/scripts/cleanup.sh --yes --keep-certs

# Keep /var/log/proxies-rotate.log
sudo /opt/proxies/scripts/cleanup.sh --yes --keep-logs
```

This does **not** cancel domains at Porkbun.

---

## Force a new domain now (on demand)

Ignores `--rotate-every-days` / `ROTATION_INTERVAL_DAYS` and runs the full pipeline immediately.

Use this whenever you need a **new domain immediately**, or to **finish setup** for a domain that was already purchased but failed later (e.g. SSL):

```bash
sudo /opt/proxies/scripts/force-rotate.sh
```

Behavior:

- If a previous run **bought** a domain but did not finish (status `purchased` / `dns_configured` / `ssl_issued`), the script **resumes that domain** and does **not** buy another.
- Otherwise it purchases a new random `.com`.

Resume a specific already-owned domain:

```bash
sudo /opt/proxies/scripts/force-rotate.sh --resume-domain adnurpvmulmdogidlnsb.com
```

Force buying a brand-new domain even if an incomplete one exists (spends money again):

```bash
sudo /opt/proxies/scripts/force-rotate.sh --force-new
```

When it finishes, it prints the domain name. Confirm with:

```bash
sudo cat /var/lib/proxies/current-domain
sudo cat /var/lib/proxies/domains/*/status
```

To change the scheduled purchase interval or retention later without reinstalling:

```bash
sudo sed -i 's/^ROTATION_INTERVAL_DAYS=.*/ROTATION_INTERVAL_DAYS=3/' /etc/proxies/credentials.env
sudo sed -i 's/^DOMAIN_RETENTION_DAYS=.*/DOMAIN_RETENTION_DAYS=21/' /etc/proxies/credentials.env
```

---

## Day-to-day operations

### Check the current (latest) domain

```bash
sudo cat /var/lib/proxies/current-domain
```

### List domains still kept on this VM

```bash
sudo ls /var/lib/proxies/domains/
```

Each directory has a `created` stamp used for the retention window (`DOMAIN_RETENTION_DAYS`).

### Only clean up domains older than the retention window

```bash
sudo /opt/proxies/scripts/rotate-domain.sh --cleanup-only
```

### View rotation logs (cron)

```bash
sudo tail -n 100 /var/log/proxies-rotate.log
```

### Reload nginx after manual edits

```bash
sudo nginx -t && sudo systemctl reload nginx
```

---

## Install options reference

| Option | Meaning |
|--------|---------|
| `--api-key` | Porkbun API key (**required** unless manual) |
| `--password` | Porkbun secret API key (**required** unless manual) |
| `--secret-key` | Alias for `--password` |
| `--domain-source` | `porkbun` (default), `internetbs` (legacy), or `manual` |
| `--client NAME` | Client id for hostname prefixes (**required**, repeatable) |
| `--client-name NAME` | Legacy alias for a single `--client` |
| `--cdn-origin` | Upstream host for CDN vhost (**required**), e.g. `cdn.example.com` |
| `--backend-origin` | Upstream host for backend vhost (**required**), e.g. `p4.example.com` |
| `--email` | Real mailbox for Let's Encrypt (**required**) |
| `--rotate-every-days N` | Purchase a new domain every N days (default: `1`, max: `365`). Cron still runs daily. |
| `--retention-days N` | Keep each domain’s local nginx sites and certs for N days (default: `14`, max: `365`). |
| `--casino-id` | Written into the client `.env` only when exactly one `--client` is installed |
| `--api-user` | Basic Auth user for `/api/game/url-extended` (**required** on first install) |
| `--api-password` | Basic Auth password for `/api/game/url-extended` |
| `--base-url` | Public GitHub repo URL (or raw.githubusercontent.com root) |
| `--github-ref` | Branch/tag when repo URL has no `/tree/...` (default: `main`) |
| `--registrant-file` | Legacy InternetBS WHOIS file (only if `--domain-source internetbs`) |
| `--run-now` | Register the first domain immediately after install |
| `--skip-cron` | Do not create the daily cron job |
| `--local-dir` | Install from a local folder instead of downloading (support / testing) |
| `--prefix DIR` | Install under a custom prefix (testing) |
| `--skip-packages` | Skip `apt` installs (testing) |

---

## Important files on the server

| Path | What it is |
|------|------------|
| `/opt/proxies/` | Scripts, hooks, templates |
| `/opt/proxies/scripts/manage-clients.sh` | Add / remove / list / sync clients after install |
| `/opt/proxies/scripts/rotate-domain.sh` | Same pipeline (used by cron and force-rotate) |
| `/opt/proxies/docs/CLIENT_GUIDE.md` | This guide (installed copy) |
| `/etc/proxies/credentials.env` | `DOMAIN_SOURCE`, Porkbun keys, origins, email, intervals |
| `/etc/proxies/clients/<name>.env` | Per-client config (filename = client id; optional `CASINO_ID`) |
| `/etc/proxies/prefixes-client.env` | Per-client hostname templates (`__CLIENT__-…`) |
| `/etc/proxies/prefixes-shared.env` | Shared hostname prefixes |
| `/var/lib/proxies/pending-domain` | Incomplete purchase being resumed (if any) |
| `/var/lib/proxies/domains/<domain>/status` | `purchased` → `dns_configured` → `ssl_issued` → `active` |
| `/etc/proxies/registrant.env` | Legacy WHOIS file (InternetBS mode only) |
| `/etc/proxies/api.htpasswd` | Basic Auth for `/api/game/url-extended` |
| `/var/lib/proxies/urls/<name>.json` | Per-client URL payload |
| `/var/lib/proxies/current-urls.json` | Copy of first client JSON (debug); API uses `/urls/<client>.json` |
| `/var/lib/proxies/current-domain` | Latest registered domain |
| `/var/lib/proxies/domains/<domain>/` | Retention stamps |
| `/etc/nginx/sites-enabled/proxies-*.conf` | Active vhosts: CDN, origin-shared, origin-`<client>` per live domain |
| `/etc/letsencrypt/live/<domain>/` | SSL certificates |
| `/etc/cron.d/proxies-domain-rotation` | Daily check (purchases per `ROTATION_INTERVAL_DAYS`) |

---

## How long domains stay available

- Every successful rotation **adds** a new domain; previous ones are **not** removed immediately.
- Domains remain configured and reachable for **`DOMAIN_RETENTION_DAYS`** (default 14; set with `--retention-days`) from the `created` stamp on the VM.
- After that window, local nginx site files **and** the Let's Encrypt certificate for that domain are deleted (`certbot delete`). That also removes the local renewal config, so `certbot renew` will not keep trying that cert.
- Domains are **not** automatically cancelled at Porkbun (billing/renewal is separate).
- **Let's Encrypt emails:** deleting locally does **not** revoke the certificate at Let's Encrypt. You may still receive expiry reminder emails for removed domains until those certs naturally expire (usually harmless if the domain is already gone from the VM). Revocation is not done automatically.
---
