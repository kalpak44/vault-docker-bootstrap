# Vault Docker Bootstrap

A clean, production-style Docker image for **HashiCorp Vault** that can automatically:

✅ Start Vault server  
✅ Initialize Vault (first run)  
✅ Unseal Vault (on restarts)  
✅ Enable KV v2 (optional)  
✅ Writes policies:
- `app-policy` (manage secrets at `secret/app/*`)
- `ui-readonly` (prevents Vault UI "Resultant ACL check failed" warning)

✅ Enable AppRole + generate credentials (optional)  

> ⚠️ This image is intended for homelabs, internal environments and quick bootstrap.  
> It stores init data (unseal key + root token) inside a persistent mounted folder.
> For production, use TLS + auto-unseal (KMS/Transit).

---

## Features

- **Idempotent bootstrap**: safe to restart
- **No manual shell steps**
- Everything stored inside mounted folders:
  - Vault data → `/vault/data`
  - Init output → `/vault/file/init.json`
  - Optional AppRole creds → `/vault/file/approle_*.txt`

---

## Build

```bash
docker build -t vault-docker-bootstrap:1.21.2 .
