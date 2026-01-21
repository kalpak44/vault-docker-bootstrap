ui = {{VAULT_ENABLE_UI}}

storage "file" {
  path = "{{VAULT_FILE_STORAGE_PATH}}"
}

listener "tcp" {
  address     = "{{VAULT_LISTEN_ADDRESS}}"
  tls_disable = 1
}

api_addr     = "{{VAULT_API_ADDR}}"
cluster_addr = "{{VAULT_CLUSTER_ADDR}}"
