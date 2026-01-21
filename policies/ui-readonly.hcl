path "sys/internal/ui/mounts" {
  capabilities = ["read"]
}

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

path "auth/*" {
  capabilities = ["read", "list"]
}

# UI checks capabilities of the current token
path "sys/capabilities-self" {
  capabilities = ["update"]
}

# Token introspection (helps UI show info; safe)
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
