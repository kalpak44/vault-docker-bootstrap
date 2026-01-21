#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Configurable env vars
# -----------------------------
: "${VAULT_LISTEN_ADDRESS:=0.0.0.0:8200}"
: "${VAULT_CLUSTER_LISTEN_ADDRESS:=0.0.0.0:8201}"

# External reachable addresses (your LAN IP / hostname)
: "${VAULT_API_ADDR:=http://127.0.0.1:8200}"
: "${VAULT_CLUSTER_ADDR:=http://127.0.0.1:8201}"

: "${VAULT_FILE_STORAGE_PATH:=/vault/data}"
: "${VAULT_INIT_FILE:=/vault/file/init.json}"

: "${VAULT_KEY_SHARES:=1}"
: "${VAULT_KEY_THRESHOLD:=1}"

: "${VAULT_ENABLE_UI:=true}"

# Bootstrap options
: "${VAULT_ENABLE_KV:=true}"
: "${VAULT_KV_PATH:=secret}"

: "${VAULT_WRITE_DEFAULT_POLICY:=true}"
: "${VAULT_DEFAULT_POLICY_NAME:=app-policy}"

: "${VAULT_ENABLE_APPROLE:=false}"
: "${VAULT_APPROLE_NAME:=app}"
: "${VAULT_APPROLE_POLICY:=app-policy}"

# -----------------------------
# Important: force Vault CLI to use HTTP (tls_disable=1)
# This prevents: "HTTP response to HTTPS client"
# -----------------------------
export VAULT_ADDR="${VAULT_API_ADDR}"

mkdir -p /vault/config /vault/data /vault/file

echo "[entrypoint] Rendering vault.hcl..."

# Render template -> actual config file
sed \
  -e "s|{{VAULT_ENABLE_UI}}|${VAULT_ENABLE_UI}|g" \
  -e "s|{{VAULT_FILE_STORAGE_PATH}}|${VAULT_FILE_STORAGE_PATH}|g" \
  -e "s|{{VAULT_LISTEN_ADDRESS}}|${VAULT_LISTEN_ADDRESS}|g" \
  -e "s|{{VAULT_API_ADDR}}|${VAULT_API_ADDR}|g" \
  -e "s|{{VAULT_CLUSTER_ADDR}}|${VAULT_CLUSTER_ADDR}|g" \
  /opt/vault-bootstrap/vault.hcl.template > /vault/config/vault.hcl

echo "[vault] Starting Vault server..."
vault server -config=/vault/config/vault.hcl &
VAULT_PID="$!"

cleanup() {
  echo "[vault] Stopping Vault..."
  kill -TERM "$VAULT_PID" 2>/dev/null || true
  wait "$VAULT_PID" 2>/dev/null || true
}
trap cleanup EXIT

echo "[bootstrap] Waiting for Vault API..."
until curl -s "${VAULT_API_ADDR}/v1/sys/health" >/dev/null 2>&1; do
  sleep 1
done

# -------- Init (idempotent) --------
initialized="$(curl -s "${VAULT_API_ADDR}/v1/sys/init" | jq -r '.initialized')"

if [[ "${initialized}" != "true" ]]; then
  echo "[bootstrap] Vault not initialized -> initializing..."
  VAULT_ADDR="${VAULT_API_ADDR}" vault operator init -format=json \
    -key-shares="${VAULT_KEY_SHARES}" \
    -key-threshold="${VAULT_KEY_THRESHOLD}" | tee "${VAULT_INIT_FILE}" >/dev/null

  chmod 600 "${VAULT_INIT_FILE}"
  echo "[bootstrap] Init saved: ${VAULT_INIT_FILE}"
else
  echo "[bootstrap] Vault already initialized."
fi

# -------- Unseal (idempotent) --------
sealed="$(curl -s "${VAULT_API_ADDR}/v1/sys/seal-status" | jq -r '.sealed')"

if [[ "${sealed}" == "true" ]]; then
  if [[ -f "${VAULT_INIT_FILE}" ]]; then
    unseal_key="$(jq -r '.unseal_keys_b64[0]' "${VAULT_INIT_FILE}")"
    echo "[bootstrap] Unsealing..."
    VAULT_ADDR="${VAULT_API_ADDR}" vault operator unseal "${unseal_key}" >/dev/null
  else
    echo "[bootstrap] ERROR: Vault sealed, but init file missing at ${VAULT_INIT_FILE}"
  fi
else
  echo "[bootstrap] Vault already unsealed."
fi

# -------- Login --------
if [[ -f "${VAULT_INIT_FILE}" ]]; then
  export VAULT_TOKEN
  VAULT_TOKEN="$(jq -r '.root_token' "${VAULT_INIT_FILE}")"

  echo "[bootstrap] Logging in with root token..."
  VAULT_ADDR="${VAULT_API_ADDR}" vault login -no-print "${VAULT_TOKEN}" >/dev/null || true
else
  echo "[bootstrap] WARNING: No init file -> skipping bootstrap actions."
fi

# -------- Bootstrap config --------
if [[ -n "${VAULT_TOKEN:-}" ]]; then

  # Enable KV v2 at secret/
  if [[ "${VAULT_ENABLE_KV}" == "true" ]]; then
    kv_mount="${VAULT_KV_PATH}/"
    if ! VAULT_ADDR="${VAULT_API_ADDR}" vault secrets list -format=json | jq -e --arg m "${kv_mount}" '.[$m]' >/dev/null 2>&1; then
      echo "[bootstrap] Enabling kv-v2 at ${kv_mount}"
      VAULT_ADDR="${VAULT_API_ADDR}" vault secrets enable -path="${VAULT_KV_PATH}" kv-v2 >/dev/null
    else
      echo "[bootstrap] KV already enabled at ${kv_mount}"
    fi
  fi

  # Write default policy
  if [[ "${VAULT_WRITE_DEFAULT_POLICY}" == "true" ]]; then
    echo "[bootstrap] Writing policy ${VAULT_DEFAULT_POLICY_NAME}"
    VAULT_ADDR="${VAULT_API_ADDR}" vault policy write "${VAULT_DEFAULT_POLICY_NAME}" \
      "/opt/vault-bootstrap/policies/${VAULT_DEFAULT_POLICY_NAME}.hcl" >/dev/null
  fi

  # Enable AppRole + create role
  if [[ "${VAULT_ENABLE_APPROLE}" == "true" ]]; then
    if ! VAULT_ADDR="${VAULT_API_ADDR}" vault auth list -format=json | jq -e '."approle/"' >/dev/null 2>&1; then
      echo "[bootstrap] Enabling AppRole auth..."
      VAULT_ADDR="${VAULT_API_ADDR}" vault auth enable approle >/dev/null
    else
      echo "[bootstrap] AppRole already enabled."
    fi

    echo "[bootstrap] Configuring AppRole ${VAULT_APPROLE_NAME}..."
    VAULT_ADDR="${VAULT_API_ADDR}" vault write "auth/approle/role/${VAULT_APPROLE_NAME}" \
      token_policies="${VAULT_APPROLE_POLICY}" \
      token_ttl="1h" token_max_ttl="4h" >/dev/null

    role_id="$(VAULT_ADDR="${VAULT_API_ADDR}" vault read -field=role_id auth/approle/role/${VAULT_APPROLE_NAME}/role-id)"
    secret_id="$(VAULT_ADDR="${VAULT_API_ADDR}" vault write -field=secret_id -f auth/approle/role/${VAULT_APPROLE_NAME}/secret-id)"

    echo "${role_id}" > /vault/file/approle_role_id.txt
    echo "${secret_id}" > /vault/file/approle_secret_id.txt
    chmod 600 /vault/file/approle_role_id.txt /vault/file/approle_secret_id.txt

    echo "[bootstrap] AppRole creds written into /vault/file/"
  fi

  echo "[bootstrap] Completed."
fi

wait "$VAULT_PID"
