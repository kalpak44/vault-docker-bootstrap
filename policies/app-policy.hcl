# KV v2: allow an app to manage secrets only under secret/app/*
path "secret/data/app/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "secret/metadata/app/*" {
  capabilities = ["list", "read", "delete"]
}
