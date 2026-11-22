# Guía de Variables de Entorno, Secretos Jasypt, mTLS y Despliegue — Pockit Finance

Este documento describe la configuración completa de ambientes mitológicos (**Ares**, **Hermes** y **Zeus**), el cifrado de secretos con **Jasypt (`ENC(...)`)**, la generación de certificados **mTLS PKCS12** y los comandos de despliegue para desarrollo local y Oracle Cloud Infrastructure (OCI).

---

## 1. Mapa de Ambientes Mitológicos

| Ambiente | Propósito | Archivo Compose | Archivo de Entorno | Base de Datos | Seguridad de Red |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Ares** | Desarrollo local | `docker-compose.yml` (`--profile ares`) | `.env.ares` | PostgreSQL 15 local (`pockit-ares-db:5432`) | HTTP local (`8080`, `8081`, `5432`) |
| **Hermes** | QA / Staging (OCI) | `docker-compose.hermes.yml` | `.env.hermes` | Supabase Cloud QA (`:6543` pooler / `:5432` Flyway) | Red interna `internal: true` + mTLS + Gateway en `443:8443` |
| **Zeus** | Producción (OCI) | `docker-compose.zeus.yml` | `.env.zeus` | Supabase Cloud PROD (`:6543` pooler / `:5432` Flyway) | Red interna `internal: true` + mTLS + Gateway en `443:8443` + Swagger deshabilitado |

---

## 2. Catálogo de Variables de Entorno

### 2.1. Generales y Base de Datos

| Variable | Obligatoria | Ambientes | Formato en Hermes/Zeus | Descripción |
| :--- | :---: | :--- | :--- | :--- |
| `SPRING_PROFILES_ACTIVE` | Sí | Todos | Texto plano (`ares`/`hermes`/`zeus`) | Activa el perfil de Spring Boot correspondiente. |
| `ARES_DB_NAME` | No | Ares | Texto plano | Nombre de la BD PostgreSQL local (default: `pockit-ares`). |
| `ARES_DB_USER` | No | Ares | Texto plano | Usuario de la BD PostgreSQL local (default: `pockit_admin`). |
| `ARES_DB_PASSWORD` | No | Ares | Texto plano | Contraseña local de PostgreSQL (solo desarrollo). |
| `ARES_DB_PORT` | No | Ares | Número | Puerto host para PostgreSQL local (default: `5432`). |
| `DB_URL` | Sí | Hermes, Zeus | Texto plano | URL JDBC de Supabase Transaction Pooler (`:6543`, `sslmode=require`). |
| `FLYWAY_DB_URL` | Sí | Hermes, Zeus | Texto plano | URL JDBC directa de Supabase (`:5432`, `sslmode=require`) para migraciones Flyway. |
| `DB_USERNAME` | Sí | Hermes, Zeus | Texto plano | Usuario PostgreSQL (`postgres.<project_ref>`). |
| `DB_PASSWORD` | Sí | Hermes, Zeus | `ENC(...)` | Contraseña de BD cifrada con Jasypt. |

### 2.2. Cifrado, Seguridad y Supabase Storage

| Variable | Obligatoria | Ambientes | Formato en Hermes/Zeus | Descripción |
| :--- | :---: | :--- | :--- | :--- |
| `JASYPT_ENCRYPTOR_PASSWORD` | Sí | Todos | Texto plano (en runtime) | Llave maestra de descifrado Jasypt. **Nunca versionar en Git.** |
| `JWT_SECRET` | Sí | Todos | `ENC(...)` | Secreto HMAC-SHA512 (mínimo 64 bytes) para firmar/validar JWT. |
| `JWT_ISSUER` | No | Todos | Texto plano | Emisor de los tokens JWT (default: `pockit-ms-auth-user`). |
| `APP_CRYPTO_RSA_PRIVATE_KEY` | Sí en Zeus | Hermes, Zeus | `ENC(...)` | Clave privada RSA (PKCS#8 Base64) para cifrado de payloads sensibles. |
| `APP_CRYPTO_RSA_PUBLIC_KEY` | Sí en Zeus | Hermes, Zeus | Texto plano | Clave pública RSA (X.509 Base64). |
| `APP_CORS_ALLOWED_ORIGINS` | Sí | Todos | Texto plano | Lista separada por comas de orígenes CORS permitidos. |
| `SUPABASE_URL` | Sí en Zeus | Hermes, Zeus | Texto plano | URL base del proyecto Supabase para Storage. |
| `SUPABASE_SERVICE_ROLE_KEY` | Sí en Zeus | Hermes, Zeus | `ENC(...)` | Llave Service Role de Supabase Storage cifrada con Jasypt. |
| `SUPABASE_AVATAR_BUCKET` | No | Todos | Texto plano | Bucket de avatares en Supabase Storage (default: `avatars`). |

### 2.3. Certificados mTLS y JVM

| Variable | Obligatoria | Ambientes | Formato en Hermes/Zeus | Descripción |
| :--- | :---: | :--- | :--- | :--- |
| `SSL_KEYSTORE_PASSWORD` | Sí | Hermes, Zeus | `ENC(...)` | Contraseña de los keystores PKCS12 (`gateway-keystore.p12`, `ms-auth-keystore.p12`). |
| `SSL_TRUSTSTORE_PASSWORD` | Sí | Hermes, Zeus | `ENC(...)` | Contraseña del truststore PKCS12 (`pockit-truststore.p12`). |
| `MTLS_HEALTHCHECK_PASSWORD` | Sí | Hermes, Zeus | Texto plano (en runtime) | Contraseña del keystore usada por el healthcheck `curl` interno del contenedor. |
| `MS_AUTH_JAVA_OPTS` | No | Hermes, Zeus | Texto plano | Opciones JVM de `pockit-ms-auth-user`. |
| `GATEWAY_JAVA_OPTS` | No | Hermes, Zeus | Texto plano | Opciones JVM de `pockit-api-gateway`. |

---

## 3. Generación de Secretos Cifrados con Jasypt (`ENC(...)`)

Los microservicios están configurados con:
- **Algoritmo:** `PBEWITHHMACSHA512ANDAES_256`
- **IV Generator:** `org.jasypt.iv.RandomIvGenerator`
- **Salt Generator:** `org.jasypt.salt.RandomSaltGenerator`
- **Salida:** `base64`

Para cifrar un secreto desde cualquiera de los microservicios Maven (por ejemplo, `pockit-ms-auth-user`):

```bash
cd ../pockit-ms-auth-user

./mvnw jasypt:encrypt-value \
  -Djasypt.encryptor.password="TU_LLAVE_MAESTRA_JASYPT" \
  -Djasypt.encryptor.algorithm="PBEWITHHMACSHA512ANDAES_256" \
  -Djasypt.encryptor.ivGeneratorClassname="org.jasypt.iv.RandomIvGenerator" \
  -Djasypt.plugin.value="VALOR_SECRETO_EN_TEXTO_PLANO"
```

Copia el resultado con el formato `ENC(textoBase64Cifrado)` dentro de `.env.hermes` o `.env.zeus`.

> **Importante:** Usa llaves maestras `JASYPT_ENCRYPTOR_PASSWORD` **completamente distintas** para **Hermes** y **Zeus**.

---

## 4. Generación de Certificados mTLS (`certs/generate-mtls-certs.sh`)

El script `certs/generate-mtls-certs.sh` es idempotente y genera los artefactos PKCS12 requeridos en `certs/generated/` (directorio ignorado por Git):

- `pockit-root-ca.key` y `pockit-root-ca.crt` (`PockitRootCA`)
- `gateway-keystore.p12` (alias `pockit-api-gateway`, SANs: `DNS:localhost,DNS:pockit-api-gateway,IP:127.0.0.1`)
- `ms-auth-keystore.p12` (alias `pockit-ms-auth-user`, SANs: `DNS:localhost,DNS:pockit-ms-auth-user,IP:127.0.0.1`)
- `pockit-truststore.p12` (alias `pockit-root-ca`, importando `PockitRootCA`)

### Ejecución estándar

```bash
chmod +x certs/generate-mtls-certs.sh
MTLS_STORE_PASSWORD="TuPasswordRobustaDeKeystore" \
MTLS_VALIDITY_DAYS=365 \
./certs/generate-mtls-certs.sh
```

### Rotación / Regeneración forzada

```bash
MTLS_FORCE_REGENERATE=true \
MTLS_STORE_PASSWORD="NuevaPasswordRobustaDeKeystore" \
MTLS_VALIDITY_DAYS=365 \
./certs/generate-mtls-certs.sh
```

---

## 5. Comandos de Despliegue por Ambiente

### 5.1. Ambiente Ares (Desarrollo Local)

```bash
# 1. Crear archivo de variables local
cp .env.ares.example .env.ares

# 2. Levantar solo la base de datos local (opcional si ejecutas los MS desde IDE)
docker compose --env-file .env.ares --profile ares up -d pockit-ares-db

# 3. Levantar stack completo (PostgreSQL + ms-auth-user + api-gateway)
docker compose --env-file .env.ares --profile ares up -d --build

# 4. Verificar salud de servicios
docker compose --profile ares ps
curl -fsS http://localhost:8081/actuator/health
curl -fsS http://localhost:8080/actuator/health

# 5. Detener stack local
docker compose --profile ares down
```

### 5.2. Ambiente Hermes (QA / Staging en OCI)

```bash
# 1. Preparar variables de entorno con secretos ENC(...)
cp .env.hermes.example .env.hermes
# Editar .env.hermes con los secretos reales cifrados

# 2. Generar certificados mTLS (idempotente)
MTLS_STORE_PASSWORD="<password-mtls-hermes>" ./certs/generate-mtls-certs.sh

# 3. Desplegar servicios en OCI
docker compose --env-file .env.hermes -f docker-compose.hermes.yml up -d --build

# 4. Verificar estado y Smoke Check
docker compose --env-file .env.hermes -f docker-compose.hermes.yml ps
curl -fsS --retry 10 https://qa.pockitfinance.com/actuator/health
```

### 5.3. Ambiente Zeus (Producción en OCI)

```bash
# 1. Preparar variables de entorno de producción con secretos ENC(...)
cp .env.zeus.example .env.zeus
# Editar .env.zeus con los secretos de producción cifrados

# 2. Generar certificados mTLS (idempotente)
MTLS_STORE_PASSWORD="<password-mtls-zeus>" ./certs/generate-mtls-certs.sh

# 3. Desplegar servicios en OCI
docker compose --env-file .env.zeus -f docker-compose.zeus.yml up -d --build

# 4. Verificar estado y Smoke Check
docker compose --env-file .env.zeus -f docker-compose.zeus.yml ps
curl -fsS --retry 10 https://app.pockitfinance.com/actuator/health
```

---

## 6. Credenciales Requeridas en Jenkins (`Jenkinsfile`)

Para ejecutar el pipeline declarativo en Jenkins, configurar las siguientes credenciales en **Manage Jenkins → Credentials**:

| Credential ID | Tipo | Descripción |
| :--- | :--- | :--- |
| `pockit-git-org-url` | Secret text | URL base de la organización Git (ej. `https://github.com/twinsoft-org`). |
| `pockit-git-credentials` | Username with password / SSH | Credenciales de lectura de repositorios Git. |
| `oci-hermes-host` | Secret text | IP o dominio del servidor OCI de Hermes (QA). |
| `oci-hermes-ssh-key` | SSH Username with private key | Llave privada SSH para despliegue en Hermes. |
| `oci-hermes-gateway-url` | Secret text | URL base HTTPS del API Gateway en Hermes (ej. `https://qa.pockitfinance.com`). |
| `oci-zeus-host` | Secret text | IP o dominio del servidor OCI de Zeus (PROD). |
| `oci-zeus-ssh-key` | SSH Username with private key | Llave privada SSH para despliegue en Zeus. |
| `oci-zeus-gateway-url` | Secret text | URL base HTTPS del API Gateway en Zeus (ej. `https://app.pockitfinance.com`). |
