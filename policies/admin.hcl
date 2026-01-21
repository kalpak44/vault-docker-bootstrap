# ----------------------------
# System: mounts, health, sealing, audit, tuning, etc.
# ----------------------------
path "sys/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

# Vault UI internal endpoints
path "sys/internal/*" {
  capabilities = ["read", "list"]
}

# ----------------------------
# Auth methods (enable/disable/configure) + tokens
# ----------------------------
path "auth/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

path "auth/token/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

# Useful for UI to self-check
path "sys/capabilities-self" {
  capabilities = ["update"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}

# ----------------------------
# Secrets engines (configure + use)
# ----------------------------
path "secret/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

# If you ever enable additional engines, these cover common defaults:
path "kv/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

path "database/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

path "transit/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

path "pki/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

# ----------------------------
# Identity (entities, groups, aliases) - used by many auth setups
# ----------------------------
path "identity/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

# ----------------------------
# Policies management
# ----------------------------
path "sys/policies/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

path "sys/policy/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

# ----------------------------
# UI convenience (optional but helpful)
# ----------------------------
path "sys/mounts" {
  capabilities = ["read"]
}

path "sys/mounts/*" {
  capabilities = ["read"]
}

path "sys/auth" {
  capabilities = ["read"]
}

path "sys/auth/*" {
  capabilities = ["read"]
}
