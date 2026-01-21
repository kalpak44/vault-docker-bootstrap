# Vault Docker Bootstrap

A practical bootstrap image for HashiCorp Vault (private networks / homelab) that:

- Starts Vault (HTTP, tls_disable=1)
- Initializes & unseals automatically (persisting init.json)
- Enables KV v2 at `secret/`
- Installs an `admin` policy (full access)
- Enables `userpass` auth and creates an admin user for the UI

> This is intended for private networks. For production: TLS + auto-unseal + no root token stored on disk.

---

## Login to UI (recommended)

Use **userpass**:
- Username: `VAULT_UI_ADMIN_USERNAME` (default: admin)
- Password: `VAULT_UI_ADMIN_PASSWORD` (you must set it)

UI:
- http://<your-ip>:8200

---

## Persistent outputs

- `/vault/file/init.json` (root token + unseal keys)

Treat `/vault/file` as sensitive.

---

## Docker Hub publishing

This repo publishes:
- `kalpak44/vault-docker-bootstrap:latest`
- `kalpak44/vault-docker-bootstrap:<shortsha>`
