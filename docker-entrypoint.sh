#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Vault bootstrap entrypoint (production-leaning, idempotent)
#
# What it does (if enabled via envs):
#  - Renders vault.hcl from template
#  - Starts Vault
#  - Optionally initializes + unseals (LAB/PoC only; not recommended for prod)
#  - Logs in using root token (only if init file exists and bootstrap enabled)
#  - Enables KV v2 mount
#  - Writes policies from a directory
#  - Enables userpass and creates/updates an admin user (optional)
#  - Enables Kubernetes auth, configures TokenReview, and creates a role (optional)
#
# Production notes:
#  - Prefer running with TLS, auto-unseal (KMS/HSM), and no init/unseal in container.
#  - Persisting init.json and root token is not production-safe.
# ============================================================

log()  { echo "[$(date -Is)] $*"; }
warn() { echo "[$(date -Is)] WARNING: $*" >&2; }
err()  { echo "[$(date -Is)] ERROR: $*" >&2; }
die()  { err "$*"; exit 1; }

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
# Bootstrap control switches
# -----------------------------
# For prod, set VAULT_BOOTSTRAP_INIT_UNSEAL=false and handle init/unseal separately.
: "${VAULT_BOOTSTRAP_INIT_UNSEAL:=true}"      # init+unseal inside container (LAB/PoC)
: "${VAULT_BOOTSTRAP_CONFIGURE:=true}"        # enable mounts/auth/policies/users/roles

# If true, writes root token + unseal key to VAULT_INIT_FILE (dangerous for prod).
# For safer behavior, set false and manage secrets outside container.
: "${VAULT_PERSIST_INIT_FILE:=true}"

# -----------------------------
# KV + policy loading
# -----------------------------
: "${VAULT_ENABLE_KV:=true}"
: "${VAULT_KV_PATH:=kv}"  # use kv to match your ESO config

: "${VAULT_WRITE_POLICIES:=true}"
: "${VAULT_POLICIES_DIR:=/opt/vault-bootstrap/policies}"
: "${VAULT_POLICIES_GLOB:=*.hcl}"
: "${VAULT_POLICIES_RECURSIVE:=false}"

# -----------------------------
# Human-friendly UI login (optional)
# -----------------------------
: "${VAULT_ENABLE_USERPASS:=true}"
: "${VAULT_UI_ADMIN_USERNAME:=admin}"
: "${VAULT_UI_ADMIN_PASSWORD:=change-me-now}"     # override via env/compose
: "${VAULT_UI_ADMIN_POLICIES:=admin}"             # or "eso-read-kv" etc.

# -----------------------------
# Kubernetes auth bootstrap (optional)
# -----------------------------
: "${VAULT_ENABLE_K8S_AUTH:=true}"
: "${VAULT_K8S_AUTH_PATH:=kubernetes}"

# You MUST provide these for external clusters:
# - K8S_HOST: Kubernetes API server URL (e.g. https://10.152.183.1:443)
# - K8S_CACERT_FILE: CA cert file path
# - K8S_TOKENREVIEW_JWT_FILE: token reviewer JWT file path
: "${K8S_HOST:=}"
: "${K8S_CACERT_FILE:=/vault/file/k8s-ca.crt}"
: "${K8S_TOKENREVIEW_JWT_FILE:=/vault/file/tokenreview.jwt}"

# Vault role used by ESO (Option B global)
: "${VAULT_K8S_ROLE_NAME:=eso-global}"
: "${VAULT_K8S_BOUND_SA_NAMES:=eso-vault-auth}"
: "${VAULT_K8S_BOUND_SA_NAMESPACES:=external-secrets}"
: "${VAULT_K8S_ROLE_POLICIES:=eso-read-kv}"  # set to "admin" only for PoC
: "${VAULT_K8S_ROLE_TTL:=1h}"

# -----------------------------
# Optional: create initial KV secrets (off by default)
# -----------------------------
: "${VAULT_SEED_SECRETS:=false}"
: "${VAULT_SEED_POC_SECRET_PATH:=kv/poc}"
: "${VAULT_SEED_POC_SECRET_MESSAGE:=hello-from-vault}"

# -----------------------------
# Important: force Vault CLI to use the API addr (HTTP if tls_disable=1)
# -----------------------------
export VAULT_ADDR="${VAULT_API_ADDR}"

mkdir -p /vault/config /vault/data /vault/file

# -----------------------------
# Render vault.hcl
# -----------------------------
log "[entrypoint] Rendering vault.hcl..."
if [[ ! -f /opt/vault-bootstrap/vault.hcl.template ]]; then
  die "Missing template: /opt/vault-bootstrap/vault.hcl.template"
fi

sed \
  -e "s|{{VAULT_ENABLE_UI}}|${VAULT_ENABLE_UI}|g" \
  -e "s|{{VAULT_FILE_STORAGE_PATH}}|${VAULT_FILE_STORAGE_PATH}|g" \
  -e "s|{{VAULT_LISTEN_ADDRESS}}|${VAULT_LISTEN_ADDRESS}|g" \
  -e "s|{{VAULT_API_ADDR}}|${VAULT_API_ADDR}|g" \
  -e "s|{{VAULT_CLUSTER_ADDR}}|${VAULT_CLUSTER_ADDR}|g" \
  /opt/vault-bootstrap/vault.hcl.template > /vault/config/vault.hcl

# -----------------------------
# Start Vault server
# -----------------------------
log "[vault] Starting Vault server..."
vault server -config=/vault/config/vault.hcl &
VAULT_PID="$!"

cleanup() {
  log "[vault] Stopping Vault..."
  kill -TERM "$VAULT_PID" 2>/dev/null || true
  wait "$VAULT_PID" 2>/dev/null || true
}
trap cleanup EXIT

log "[bootstrap] Waiting for Vault API..."
until curl -s "${VAULT_API_ADDR}/v1/sys/health" >/dev/null 2>&1; do
  sleep 1
done

# -----------------------------
# Helpers
# -----------------------------
vault_json() { VAULT_ADDR="${VAULT_API_ADDR}" vault "$@" -format=json; }

vault_is_initialized() {
  curl -s "${VAULT_API_ADDR}/v1/sys/init" | jq -r '.initialized' | grep -q '^true$'
}

vault_is_sealed() {
  curl -s "${VAULT_API_ADDR}/v1/sys/seal-status" | jq -r '.sealed' | grep -q '^true$'
}

require_vault_token() {
  [[ -n "${VAULT_TOKEN:-}" ]] || die "VAULT_TOKEN is not set (login/bootstrap failed)"
}

# -----------------------------
# Init (LAB/PoC) - idempotent
# -----------------------------
if [[ "${VAULT_BOOTSTRAP_INIT_UNSEAL}" == "true" ]]; then
  if ! vault_is_initialized; then
    log "[bootstrap] Vault not initialized -> initializing..."
    init_json="$(VAULT_ADDR="${VAULT_API_ADDR}" vault operator init -format=json \
      -key-shares="${VAULT_KEY_SHARES}" \
      -key-threshold="${VAULT_KEY_THRESHOLD}")"

    if [[ "${VAULT_PERSIST_INIT_FILE}" == "true" ]]; then
      umask 077
      echo "${init_json}" > "${VAULT_INIT_FILE}"
      chmod 600 "${VAULT_INIT_FILE}"
      log "[bootstrap] Init saved: ${VAULT_INIT_FILE}"
    else
      warn "VAULT_PERSIST_INIT_FILE=false: init output NOT persisted. You must capture unseal key + root token externally."
    fi
  else
    log "[bootstrap] Vault already initialized."
  fi

  # Unseal - idempotent
  if vault_is_sealed; then
    if [[ -f "${VAULT_INIT_FILE}" ]]; then
      unseal_key="$(jq -r '.unseal_keys_b64[0]' "${VAULT_INIT_FILE}")"
      log "[bootstrap] Unsealing..."
      VAULT_ADDR="${VAULT_API_ADDR}" vault operator unseal "${unseal_key}" >/dev/null
    else
      die "Vault is sealed but init file missing at ${VAULT_INIT_FILE}. Cannot unseal."
    fi
  else
    log "[bootstrap] Vault already unsealed."
  fi
else
  log "[bootstrap] VAULT_BOOTSTRAP_INIT_UNSEAL=false (skipping init/unseal)."
fi

# -----------------------------
# Login (only possible if init file exists)
# -----------------------------
if [[ -f "${VAULT_INIT_FILE}" ]]; then
  export VAULT_TOKEN
  VAULT_TOKEN="$(jq -r '.root_token' "${VAULT_INIT_FILE}")"
  log "[bootstrap] Logging in with root token (bootstrap actions only)..."
  VAULT_ADDR="${VAULT_API_ADDR}" vault login -no-print "${VAULT_TOKEN}" >/dev/null || true
else
  warn "No init file at ${VAULT_INIT_FILE}. Skipping login/bootstrap actions that require VAULT_TOKEN."
fi

# -----------------------------
# Bootstrap config (mounts/policies/users/k8s auth/roles)
# -----------------------------
if [[ "${VAULT_BOOTSTRAP_CONFIGURE}" == "true" ]]; then
  if [[ -n "${VAULT_TOKEN:-}" ]]; then
    # ---- Enable KV v2 ----
    if [[ "${VAULT_ENABLE_KV}" == "true" ]]; then
      kv_mount="${VAULT_KV_PATH}/"
      if ! vault_json secrets list | jq -e --arg m "${kv_mount}" '.[$m]' >/dev/null 2>&1; then
        log "[bootstrap] Enabling kv-v2 at ${kv_mount}"
        VAULT_ADDR="${VAULT_API_ADDR}" vault secrets enable -path="${VAULT_KV_PATH}" kv-v2 >/dev/null
      else
        log "[bootstrap] KV already enabled at ${kv_mount}"
      fi
    fi

    # ---- Write policies (AUTO: all .hcl files in policies dir) ----
    if [[ "${VAULT_WRITE_POLICIES}" == "true" ]]; then
      log "[bootstrap] Writing policies from ${VAULT_POLICIES_DIR}..."
      if [[ ! -d "${VAULT_POLICIES_DIR}" ]]; then
        warn "Policies dir not found: ${VAULT_POLICIES_DIR} (skipping)"
      else
        if [[ "${VAULT_POLICIES_RECURSIVE}" == "true" ]]; then
          mapfile -t policy_files < <(find "${VAULT_POLICIES_DIR}" -type f -name '*.hcl' | sort)
        else
          shopt -s nullglob
          policy_files=( "${VAULT_POLICIES_DIR}"/${VAULT_POLICIES_GLOB} )
          shopt -u nullglob
        fi

        if (( ${#policy_files[@]} == 0 )); then
          warn "No policy files found in ${VAULT_POLICIES_DIR}"
        else
          for f in "${policy_files[@]}"; do
            name="$(basename "${f}")"
            name="${name%.hcl}"
            log "[bootstrap] - writing policy: ${name} (from ${f})"
            VAULT_ADDR="${VAULT_API_ADDR}" vault policy write "${name}" "${f}" >/dev/null
          done
        fi
      fi
    fi

    # ---- Enable userpass + create admin user (optional) ----
    if [[ "${VAULT_ENABLE_USERPASS}" == "true" ]]; then
      if ! vault_json auth list | jq -e '."userpass/"' >/dev/null 2>&1; then
        log "[bootstrap] Enabling userpass auth..."
        VAULT_ADDR="${VAULT_API_ADDR}" vault auth enable userpass >/dev/null
      else
        log "[bootstrap] userpass already enabled."
      fi

      if [[ "${VAULT_UI_ADMIN_PASSWORD}" == "change-me-now" ]]; then
        warn "VAULT_UI_ADMIN_PASSWORD is still default. Override it in compose/env."
      fi

      log "[bootstrap] Creating/updating UI admin user: ${VAULT_UI_ADMIN_USERNAME}"
      VAULT_ADDR="${VAULT_API_ADDR}" vault write "auth/userpass/users/${VAULT_UI_ADMIN_USERNAME}" \
        password="${VAULT_UI_ADMIN_PASSWORD}" \
        policies="${VAULT_UI_ADMIN_POLICIES}" >/dev/null
    fi

    # ---- Enable Kubernetes auth + configure + create role (optional) ----
    if [[ "${VAULT_ENABLE_K8S_AUTH}" == "true" ]]; then
      auth_mount="${VAULT_K8S_AUTH_PATH}/"

      if ! vault_json auth list | jq -e --arg m "${auth_mount}" '.[$m]' >/dev/null 2>&1; then
        log "[bootstrap] Enabling Kubernetes auth at ${auth_mount}"
        VAULT_ADDR="${VAULT_API_ADDR}" vault auth enable -path="${VAULT_K8S_AUTH_PATH}" kubernetes >/dev/null
      else
        log "[bootstrap] Kubernetes auth already enabled at ${auth_mount}"
      fi

      if [[ -z "${K8S_HOST}" ]]; then
        warn "K8S_HOST not set -> skipping kubernetes auth config + role creation."
      elif [[ ! -f "${K8S_CACERT_FILE}" ]]; then
        warn "Missing ${K8S_CACERT_FILE} -> skipping kubernetes auth config + role creation."
      elif [[ ! -f "${K8S_TOKENREVIEW_JWT_FILE}" ]]; then
        warn "Missing ${K8S_TOKENREVIEW_JWT_FILE} -> skipping kubernetes auth config + role creation."
      else
        log "[bootstrap] Configuring Kubernetes auth (TokenReview)..."
        VAULT_ADDR="${VAULT_API_ADDR}" vault write "auth/${VAULT_K8S_AUTH_PATH}/config" \
          kubernetes_host="${K8S_HOST}" \
          kubernetes_ca_cert=@"${K8S_CACERT_FILE}" \
          token_reviewer_jwt=@"${K8S_TOKENREVIEW_JWT_FILE}" >/dev/null

        log "[bootstrap] Creating/updating Vault role ${VAULT_K8S_ROLE_NAME} for ESO..."
        VAULT_ADDR="${VAULT_API_ADDR}" vault write "auth/${VAULT_K8S_AUTH_PATH}/role/${VAULT_K8S_ROLE_NAME}" \
          bound_service_account_names="${VAULT_K8S_BOUND_SA_NAMES}" \
          bound_service_account_namespaces="${VAULT_K8S_BOUND_SA_NAMESPACES}" \
          policies="${VAULT_K8S_ROLE_POLICIES}" \
          ttl="${VAULT_K8S_ROLE_TTL}" >/dev/null
      fi
    fi

    # ---- Seed a PoC secret (optional) ----
    if [[ "${VAULT_SEED_SECRETS}" == "true" ]]; then
      # This uses kv-v2 "vault kv put" semantics (path like kv/poc)
      log "[bootstrap] Seeding PoC secret at ${VAULT_SEED_POC_SECRET_PATH}..."
      VAULT_ADDR="${VAULT_API_ADDR}" vault kv put "${VAULT_SEED_POC_SECRET_PATH}" \
        message="${VAULT_SEED_POC_SECRET_MESSAGE}" >/dev/null
    fi

    log "[bootstrap] Completed."
  else
    warn "No VAULT_TOKEN available; skipping bootstrap configure actions."
  fi
else
  log "[bootstrap] VAULT_BOOTSTRAP_CONFIGURE=false (skipping mounts/policies/auth/users/roles)."
fi

# Keep Vault running
wait "$VAULT_PID"
