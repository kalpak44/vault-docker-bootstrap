# Allow creating/reading/updating secrets in the "app" subtree (KV v2)
path "secret/data/app/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "secret/metadata/app/*" {
  capabilities = ["list", "read", "delete"]
}
