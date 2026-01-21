#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Base config
# -----------------------------
: "${VAULT_LISTEN_ADDRESS:=0.0.0.0:8200}"
: "${VAULT_API_ADDR:=http://127.0.0.1:8200}"
: "${VAULT_CLUSTER_ADDR:=http://127.0.0.1:8201}"

: "${VAULT_FILE_STORAGE_PATH:=/vault/data}"
: "${VAULT_INIT_FILE:=/vault/file/init.json}"

: "${VAULT_KEY_SHARES:=1}"
: "${VAULT_KEY_THRESHOLD:=1}"

: "${VAULT_ENABLE_UI:=true}"

# -----------------------------
# Bootstrap behavior
# -----------------------------
: "${VAULT_ENABLE_KV:=true}"
: "${VAULT_KV_PATH:=secret}"

: "${VAULT_WRITE_POLICIES:=true}"

# Auto-policy loading:
# - Default dir is the policies folder inside the image
# - Override in docker-compose to point at a mounted folder, e.g. /vault/policies
: "${VAULT_POLICIES_DIR:=/opt/vault-bootstrap/policies}"
: "${VAULT_POLICIES_GLOB:=*.hcl}"
# Set to "true" if you want to load policies recursively from subfolders
: "${VAULT_POLICIES_RECURSIVE:=false}"

# Human-friendly UI login (recommended for your use)
: "${VAULT_ENABLE_USERPASS:=true}"
: "${VAULT_UI_ADMIN_USERNAME:=admin}"
: "${VAULT_UI_ADMIN_PASSWORD:=change-me-now}"   # IMPORTANT: override in compose/env
: "${VAULT_UI_ADMIN_POLICIES:=admin}"

# Optional: AppRole for Kubernetes later (off by default here)
: "${VAULT_ENABLE_APPROLE:=false}"
: "${VAULT_APPROLE_NAME:=k8s-app}"
: "${VAULT_APPROLE_POLICIES:=app-policy}"

# -----------------------------
# Important: force Vault CLI to use HTTP (tls_disable=1)
# prevents "HTTP response to HTTPS client"
# -----------------------------
export VAULT_ADDR="${VAULT_API_ADDR}"

mkdir -p /vault/config /vault/data /vault/file

echo "[entrypoint] Rendering vault.hcl..."
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

# -------- Login (needs init file) --------
if [[ -f "${VAULT_INIT_FILE}" ]]; then
  export VAULT_TOKEN
  VAULT_TOKEN="$(jq -r '.root_token' "${VAULT_INIT_FILE}")"
  echo "[bootstrap] Logging in with root token (bootstrap only)..."
  VAULT_ADDR="${VAULT_API_ADDR}" vault login -no-print "${VAULT_TOKEN}" >/dev/null || true
else
  echo "[bootstrap] WARNING: No init file -> skipping bootstrap actions."
fi

# -------- Bootstrap config --------
if [[ -n "${VAULT_TOKEN:-}" ]]; then

  # Enable KV v2
  if [[ "${VAULT_ENABLE_KV}" == "true" ]]; then
    kv_mount="${VAULT_KV_PATH}/"
    if ! VAULT_ADDR="${VAULT_API_ADDR}" vault secrets list -format=json | jq -e --arg m "${kv_mount}" '.[$m]' >/dev/null 2>&1; then
      echo "[bootstrap] Enabling kv-v2 at ${kv_mount}"
      VAULT_ADDR="${VAULT_API_ADDR}" vault secrets enable -path="${VAULT_KV_PATH}" kv-v2 >/dev/null
    else
      echo "[bootstrap] KV already enabled at ${kv_mount}"
    fi
  fi

  # Write policies (AUTO: all .hcl files in policies dir)
  if [[ "${VAULT_WRITE_POLICIES}" == "true" ]]; then
    echo "[bootstrap] Writing policies from ${VAULT_POLICIES_DIR}..."

    if [[ ! -d "${VAULT_POLICIES_DIR}" ]]; then
      echo "[bootstrap] WARNING: Policies dir not found: ${VAULT_POLICIES_DIR} (skipping)"
    else
      if [[ "${VAULT_POLICIES_RECURSIVE}" == "true" ]]; then
        mapfile -t policy_files < <(find "${VAULT_POLICIES_DIR}" -type f -name '*.hcl' | sort)
      else
        shopt -s nullglob
        policy_files=( "${VAULT_POLICIES_DIR}"/${VAULT_POLICIES_GLOB} )
        shopt -u nullglob
      fi

      if (( ${#policy_files[@]} == 0 )); then
        echo "[bootstrap] WARNING: No policy files found in ${VAULT_POLICIES_DIR}"
      else
        for f in "${policy_files[@]}"; do
          # Policy name = filename without .hcl
          name="$(basename "${f}")"
          name="${name%.hcl}"

          echo "[bootstrap] - writing policy: ${name} (from ${f})"
          VAULT_ADDR="${VAULT_API_ADDR}" vault policy write "${name}" "${f}" >/dev/null
        done
      fi
    fi
  fi

  # Enable userpass + create admin user for UI (idempotent-ish)
  if [[ "${VAULT_ENABLE_USERPASS}" == "true" ]]; then
    if ! VAULT_ADDR="${VAULT_API_ADDR}" vault auth list -format=json | jq -e '."userpass/"' >/dev/null 2>&1; then
      echo "[bootstrap] Enabling userpass auth..."
      VAULT_ADDR="${VAULT_API_ADDR}" vault auth enable userpass >/dev/null
    else
      echo "[bootstrap] userpass already enabled."
    fi

    if [[ "${VAULT_UI_ADMIN_PASSWORD}" == "change-me-now" ]]; then
      echo "[bootstrap] WARNING: VAULT_UI_ADMIN_PASSWORD is still default. Override it in compose/env."
    fi

    echo "[bootstrap] Creating/updating UI admin user: ${VAULT_UI_ADMIN_USERNAME}"
    VAULT_ADDR="${VAULT_API_ADDR}" vault write "auth/userpass/users/${VAULT_UI_ADMIN_USERNAME}" \
      password="${VAULT_UI_ADMIN_PASSWORD}" \
      policies="${VAULT_UI_ADMIN_POLICIES}" >/dev/null
  fi

  # Optional: AppRole for Kubernetes later
  if [[ "${VAULT_ENABLE_APPROLE}" == "true" ]]; then
    if ! VAULT_ADDR="${VAULT_API_ADDR}" vault auth list -format=json | jq -e '."approle/"' >/dev/null 2>&1; then
      echo "[bootstrap] Enabling AppRole auth..."
      VAULT_ADDR="${VAULT_API_ADDR}" vault auth enable approle >/dev/null
    else
      echo "[bootstrap] AppRole already enabled."
    fi

    echo "[bootstrap] Configuring AppRole ${VAULT_APPROLE_NAME} with policies: ${VAULT_APPROLE_POLICIES}"
    VAULT_ADDR="${VAULT_API_ADDR}" vault write "auth/approle/role/${VAULT_APPROLE_NAME}" \
      token_policies="${VAULT_APPROLE_POLICIES}" \
      token_ttl="24h" token_max_ttl="72h" >/dev/null

    role_id="$(VAULT_ADDR="${VAULT_API_ADDR}" vault read -field=role_id auth/approle/role/${VAULT_APPROLE_NAME}/role-id)"
    secret_id="$(VAULT_ADDR="${VAULT_API_ADDR}" vault write -field=secret_id -f auth/approle/role/${VAULT_APPROLE_NAME}/secret-id)"

    echo "${role_id}" > /vault/file/approle_role_id.txt
    echo "${secret_id}" > /vault/file/approle_secret_id.txt
    chmod 600 /vault/file/approle_role_id.txt /vault/file/approle_secret_id.txt

    echo "[bootstrap] AppRole creds written to /vault/file/"
  fi

  echo "[bootstrap] Completed."
fi

wait "$VAULT_PID"
