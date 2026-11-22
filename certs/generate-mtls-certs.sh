#!/usr/bin/env bash
# ==============================================================================
# Pockit Finance - Generador Idempotente de Certificados mTLS (CA + PKCS12)
# ==============================================================================
# Genera en certs/generated/ (ignorado por Git):
#   - pockit-root-ca.key / pockit-root-ca.crt (PockitRootCA)
#   - gateway-keystore.p12  (alias: pockit-api-gateway)
#   - ms-auth-keystore.p12  (alias: pockit-ms-auth-user)
#   - pockit-truststore.p12 (alias: pockit-root-ca)
#
# Variables de entorno configurables:
#   MTLS_STORE_PASSWORD   Contrasena para keystores y truststore PKCS12
#   MTLS_VALIDITY_DAYS    Vigencia en dias de los certificados de servicio (default: 365)
#   MTLS_CA_VALIDITY_DAYS Vigencia en dias de la Root CA (default: 1825)
#   MTLS_FORCE_REGENERATE Si es "true", regenera todos los artefactos (default: false)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${MTLS_OUTPUT_DIR:-${SCRIPT_DIR}/generated}"
MTLS_STORE_PASSWORD="${MTLS_STORE_PASSWORD:-pockit-mtls-change-me}"
MTLS_VALIDITY_DAYS="${MTLS_VALIDITY_DAYS:-365}"
MTLS_CA_VALIDITY_DAYS="${MTLS_CA_VALIDITY_DAYS:-1825}"
MTLS_FORCE_REGENERATE="${MTLS_FORCE_REGENERATE:-false}"

CA_KEY="${OUTPUT_DIR}/pockit-root-ca.key"
CA_CRT="${OUTPUT_DIR}/pockit-root-ca.crt"
GATEWAY_P12="${OUTPUT_DIR}/gateway-keystore.p12"
MS_AUTH_P12="${OUTPUT_DIR}/ms-auth-keystore.p12"
TRUSTSTORE_P12="${OUTPUT_DIR}/pockit-truststore.p12"

require_command() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "[ERROR] El comando requerido '${cmd}' no esta instalado o no esta en el PATH." >&2
    exit 1
  fi
}

require_command openssl
require_command keytool

if [[ "${MTLS_STORE_PASSWORD}" == "pockit-mtls-change-me" ]]; then
  echo "[WARN] Usando MTLS_STORE_PASSWORD por defecto. Define una contrasena robusta en Hermes/Zeus."
fi

if [[ "${MTLS_FORCE_REGENERATE}" != "true" ]] \
  && [[ -f "${CA_KEY}" ]] \
  && [[ -f "${CA_CRT}" ]] \
  && [[ -f "${GATEWAY_P12}" ]] \
  && [[ -f "${MS_AUTH_P12}" ]] \
  && [[ -f "${TRUSTSTORE_P12}" ]]; then
  echo "[INFO] Los certificados mTLS ya existen en '${OUTPUT_DIR}'."
  echo "[INFO] Para regenerarlos, ejecuta: MTLS_FORCE_REGENERATE=true $0"
  exit 0
fi

mkdir -p "${OUTPUT_DIR}"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "${TMP_DIR}"
  rm -f "${OUTPUT_DIR}/pockit-root-ca.srl"
}
trap cleanup EXIT

# ------------------------------------------------------------------------------
# 1. Root CA: PockitRootCA
# ------------------------------------------------------------------------------
if [[ "${MTLS_FORCE_REGENERATE}" == "true" ]] || [[ ! -f "${CA_KEY}" ]] || [[ ! -f "${CA_CRT}" ]]; then
  echo "[1/4] Generando PockitRootCA (RSA 4096, vigencia ${MTLS_CA_VALIDITY_DAYS} dias)..."
  CA_CNF="${TMP_DIR}/pockit-root-ca.cnf"
  cat > "${CA_CNF}" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3_ca
prompt = no

[dn]
C = CO
O = Pockit Finance
OU = Security
CN = PockitRootCA

[v3_ca]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical,CA:TRUE,pathlen:0
keyUsage = critical,digitalSignature,cRLSign,keyCertSign
EOF

  openssl genrsa -out "${CA_KEY}" 4096
  openssl req -x509 -new -nodes \
    -key "${CA_KEY}" \
    -sha256 \
    -days "${MTLS_CA_VALIDITY_DAYS}" \
    -config "${CA_CNF}" \
    -out "${CA_CRT}"
else
  echo "[1/4] Reutilizando PockitRootCA existente en '${OUTPUT_DIR}'..."
fi

# ------------------------------------------------------------------------------
# Funcion auxiliar para emitir keystore PKCS12 firmado por PockitRootCA
# ------------------------------------------------------------------------------
generate_service_keystore() {
  local service_alias="$1"
  local common_name="$2"
  local san_entries="$3"
  local output_p12="$4"

  local svc_key="${TMP_DIR}/${service_alias}.key"
  local svc_csr="${TMP_DIR}/${service_alias}.csr"
  local svc_crt="${TMP_DIR}/${service_alias}.crt"
  local svc_cnf="${TMP_DIR}/${service_alias}.cnf"
  local svc_ext="${TMP_DIR}/${service_alias}.ext"

  cat > "${svc_cnf}" <<EOF
[req]
distinguished_name = dn
prompt = no

[dn]
C = CO
O = Pockit Finance
OU = Microservices
CN = ${common_name}
EOF

  cat > "${svc_ext}" <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth,clientAuth
subjectAltName=${san_entries}
EOF

  openssl genrsa -out "${svc_key}" 2048

  openssl req -new \
    -key "${svc_key}" \
    -config "${svc_cnf}" \
    -out "${svc_csr}"

  openssl x509 -req \
    -in "${svc_csr}" \
    -CA "${CA_CRT}" \
    -CAkey "${CA_KEY}" \
    -CAcreateserial \
    -CAserial "${TMP_DIR}/pockit-root-ca.srl" \
    -out "${svc_crt}" \
    -days "${MTLS_VALIDITY_DAYS}" \
    -sha256 \
    -extfile "${svc_ext}"

  rm -f "${output_p12}"
  openssl pkcs12 -export \
    -in "${svc_crt}" \
    -inkey "${svc_key}" \
    -certfile "${CA_CRT}" \
    -name "${service_alias}" \
    -out "${output_p12}" \
    -passout "env:MTLS_STORE_PASSWORD"
}

export MTLS_STORE_PASSWORD

# ------------------------------------------------------------------------------
# 2. Keystore API Gateway
# ------------------------------------------------------------------------------
echo "[2/4] Generando gateway-keystore.p12 (SAN: DNS:localhost,DNS:pockit-api-gateway,IP:127.0.0.1)..."
generate_service_keystore \
  "pockit-api-gateway" \
  "pockit-api-gateway" \
  "DNS:localhost,DNS:pockit-api-gateway,IP:127.0.0.1" \
  "${GATEWAY_P12}"

# ------------------------------------------------------------------------------
# 3. Keystore MS Auth User
# ------------------------------------------------------------------------------
echo "[3/4] Generando ms-auth-keystore.p12 (SAN: DNS:localhost,DNS:pockit-ms-auth-user,IP:127.0.0.1)..."
generate_service_keystore \
  "pockit-ms-auth-user" \
  "pockit-ms-auth-user" \
  "DNS:localhost,DNS:pockit-ms-auth-user,IP:127.0.0.1" \
  "${MS_AUTH_P12}"

# ------------------------------------------------------------------------------
# 4. Truststore PKCS12 con PockitRootCA
# ------------------------------------------------------------------------------
echo "[4/4] Generando pockit-truststore.p12 importando PockitRootCA..."
rm -f "${TRUSTSTORE_P12}"
keytool -importcert \
  -noprompt \
  -trustcacerts \
  -alias "pockit-root-ca" \
  -file "${CA_CRT}" \
  -keystore "${TRUSTSTORE_P12}" \
  -storetype PKCS12 \
  -storepass:env MTLS_STORE_PASSWORD >/dev/null

# Permisos seguros (clave privada solo lectura propietario; p12/crt legibles para contenedor non-root :ro)
chmod 600 "${CA_KEY}"
chmod 644 "${CA_CRT}" "${GATEWAY_P12}" "${MS_AUTH_P12}" "${TRUSTSTORE_P12}"

echo "[OK] Artefactos mTLS generados correctamente en '${OUTPUT_DIR}':"
echo "     - $(basename "${CA_KEY}")"
echo "     - $(basename "${CA_CRT}")"
echo "     - $(basename "${GATEWAY_P12}")"
echo "     - $(basename "${MS_AUTH_P12}")"
echo "     - $(basename "${TRUSTSTORE_P12}")"
