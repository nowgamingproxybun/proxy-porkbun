# Domain rotation proxy toolkit

Ubuntu **26.04** toolkit that registers a random 20-letter `.com` domain via **Porkbun** (or uses **domains you list yourself**), points DNS at the VM, issues a Let’s Encrypt certificate, and configures nginx reverse proxies for CDN and origin traffic.

**Clients:** start with the step-by-step guide → [`docs/CLIENT_GUIDE.md`](docs/CLIENT_GUIDE.md)

One VM can host **multiple clients** (hostname prefixes) on the same rotated domain. Purchase frequency is set with `--rotate-every-days` (default daily). Configured domains stay reachable for `--retention-days` (default **14**), then local nginx configs and certificates are removed from the VM.

## Client quick start

Host this repository as a **public GitHub repo**, then on the Ubuntu 26.04 VM:

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
  --api-password 'STRONG_PASSWORD' \
  --base-url 'https://github.com/OWNER/REPO'

# Porkbun: add account credit at porkbun.com/account (API uses that balance)
sudo /opt/proxies/scripts/force-rotate.sh
```

`--base-url` accepts `https://github.com/OWNER/REPO`, `.../tree/<ref>`, or a `raw.githubusercontent.com` root. Use `--github-ref` for a non-default branch/tag.

**Manual domains (no Porkbun purchase):** pass `--domain-source manual` and one or more `--domain`. API keys are optional — keep them if those names already live at Porkbun (DNS + wildcard SSL). Otherwise point `domain` and `*.domain` A records to the VM yourself; certificates use HTTP-01.

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
  --api-password 'STRONG_PASSWORD' \
  --base-url 'https://github.com/OWNER/REPO'

# Edit the list later:
#   sudo nano /etc/proxies/domains.list
#   sudo /opt/proxies/scripts/force-rotate.sh --use-domain already-owned.com
```

On an existing install, set `DOMAIN_SOURCE=manual` in `/etc/proxies/credentials.env`, put FQDNs in `/etc/proxies/domains.list`, then run `force-rotate.sh --use-domain NAME`.

**Force a new domain on demand** (Porkbun mode spends account credit):

```bash
sudo /opt/proxies/scripts/force-rotate.sh
```

**Read current domain URLs by VM IP** (Basic Auth; same user/password for all clients):

```bash
curl -u 'domainapi:STRONG_PASSWORD' "http://VM_PUBLIC_IP/api/game/url-extended/clientname42"
```

**Clean up a previous install:**

```bash
curl -fsSL https://raw.githubusercontent.com/OWNER/REPO/main/cleanup.sh | sudo bash -s -- --yes
# or: sudo /opt/proxies/scripts/cleanup.sh --yes [--purge-packages]
```

Full instructions, day-to-day commands, troubleshooting, and file locations: **[Client guide](docs/CLIENT_GUIDE.md)**.

## What gets installed

| Path | Purpose |
|------|---------|
| `/opt/proxies/scripts/manage-clients.sh` | Add/remove/list/sync clients without buying a domain |
| `/etc/proxies/credentials.env` | `DOMAIN_SOURCE`, Porkbun keys, origins, email, intervals |
| `/etc/proxies/domains.list` | Manual FQDN pool when `DOMAIN_SOURCE=manual` |
| `/etc/proxies/clients/<name>.env` | Per-client id (filename) + optional `CASINO_ID` |
| `/etc/proxies/prefixes-client.env` | Per-client hostname templates |
| `/etc/proxies/prefixes-shared.env` | Shared hostname prefixes |
| `/etc/proxies/registrant.env` | Legacy WHOIS file (InternetBS mode only) |
| `/var/lib/proxies/current-domain` | Most recent domain |
| `/var/lib/proxies/urls/<name>.json` | Per-client URL JSON |
| `/var/lib/proxies/domains/<domain>/` | Retention stamps (`created`) |
| `/etc/cron.d/proxies-domain-rotation` | Daily check at 03:00; purchases every `ROTATION_INTERVAL_DAYS` |

### Nginx vhosts (per domain)

- **CDN:** `cdn.<domain>`, `lobby-prod-cdn.<domain>` → `CDN_ORIGIN` (install input)
- **Backend shared:** `proxies-origin-shared-<domain>.conf` → shared prefixes → `BACKEND_ORIGIN`
- **Backend per client:** `proxies-origin-<client>-<domain>.conf` → that client’s prefixes → `BACKEND_ORIGIN`

## Notes

- **Billable:** live Porkbun `domain/create` spends account credit. Manual mode never buys a domain.
- Availability is checked with Porkbun `checkDomain` before every purchase (Porkbun mode only; rate-limited, default 1 check / 10s).
- Wildcard certs use Certbot DNS-01 hooks against the Porkbun DNS API when API keys are set. Manual mode without keys uses HTTP-01 for the hostname list (not a wildcard).
- Local cleanup after `DOMAIN_RETENTION_DAYS` deletes nginx sites and runs `certbot delete` for that domain (not the registrar registration). Let's Encrypt may still email about expiry until the cert ages out; it is not auto-revoked.
- `--email` is used for Let's Encrypt (stored as `CERTBOT_EMAIL` in credentials.env).
- Porkbun API registration requires a verified account email/phone, account credit, and **at least one domain already registered on the website**.
- Target OS is **Ubuntu 26.04** only (install and rotation scripts enforce this).
- Package hosting: publish this repo publicly on GitHub and pass `--base-url https://github.com/OWNER/REPO` (optional `--github-ref`).
- URL API: `GET http://<vm-ip>/api/game/url-extended/<client>` with shared Basic Auth (`--api-user` / `--api-password`).
