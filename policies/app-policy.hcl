# Vault UI needs this to render without the ACL warning
path "sys/internal/ui/mounts" {
  capabilities = ["read"]
}

# UI often checks mounts/auth methods
path "sys/mounts" {
  capabilities = ["read"]
}

path "sys/auth" {
  capabilities = ["read"]
}

path "sys/auth/*" {
  capabilities = ["read"]
}

# UI checks what you can do
path "sys/capabilities-self" {
  capabilities = ["update"]
}

# Helpful for token display in UI
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
