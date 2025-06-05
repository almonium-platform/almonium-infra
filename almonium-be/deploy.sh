#!/usr/bin/env bash
set -euo pipefail # Exit on error, undefined variable, pipe failure

# --- Configuration & Secrets Export ---
export DEPLOY_IMAGE_TAG="${DEPLOY_IMAGE_TAG:?DEPLOY_IMAGE_TAG not set}"
export DEPLOY_ENVIRONMENT="${DEPLOY_ENVIRONMENT:?DEPLOY_ENVIRONMENT not set}"
export API_HOSTNAME="${API_HOSTNAME:?API_HOSTNAME not set}"

# Server Configuration
export LOCAL_PORT="${CONF_LOCAL_PORT:?CONF_LOCAL_PORT not set}"
export DEBUG_PORT="${CONF_DEBUG_PORT:?CONF_DEBUG_PORT not set}"
export SPRING_PROFILE="${CONF_SPRING_PROFILE:?CONF_SPRING_PROFILE not set}"

# JWT Configuration
export JWT_SECRET="${CONF_JWT_SECRET:?CONF_JWT_SECRET not set}"

# Database Configuration
export DB_NAME="${CONF_DB_NAME:?CONF_DB_NAME not set}"
export DB_HOST="${CONF_DB_HOST:?CONF_DB_HOST not set}"
export DB_PORT="${CONF_DB_PORT:?CONF_DB_PORT not set}"
export DB_SCHEMA="${CONF_DB_SCHEMA:?CONF_DB_SCHEMA not set}"
export DB_USERNAME="${CONF_DB_USERNAME:?CONF_DB_USERNAME not set}"
export DB_PASSWORD="${CONF_DB_PASSWORD:?CONF_DB_PASSWORD not set}"

# API Keys
export RAPID_API_KEY="${CONF_RAPID_API_KEY:?CONF_RAPID_API_KEY not set}"
export WORDNIK_KEY="${CONF_WORDNIK_KEY:?CONF_WORDNIK_KEY not set}"
export YANDEX_KEY="${CONF_YANDEX_KEY:?CONF_YANDEX_KEY not set}"
export OPENAI_KEY="${CONF_OPENAI_KEY:?CONF_OPENAI_KEY not set}"
export GEMINI_API_KEY="${CONF_GEMINI_API_KEY:?CONF_GEMINI_API_KEY not set}"

# Stripe Configuration
export STRIPE_KEY="${CONF_STRIPE_KEY:?CONF_STRIPE_KEY not set}"
export STRIPE_WEBHOOK_SECRET="${CONF_STRIPE_WEBHOOK_SECRET:?CONF_STRIPE_WEBHOOK_SECRET not set}"

# Stream Configuration
export STREAM_KEY="${CONF_STREAM_KEY:?CONF_STREAM_KEY not set}"
export STREAM_SECRET="${CONF_STREAM_SECRET:?CONF_STREAM_SECRET not set}"

# Google Cloud Configuration
export GOOGLE_PROJECT_ID="${CONF_GOOGLE_PROJECT_ID:?CONF_GOOGLE_PROJECT_ID not set}"
export GOOGLE_SERVICE_ACCOUNT_KEY_BASE64="${CONF_GOOGLE_SERVICE_ACCOUNT_KEY_BASE64:?CONF_GOOGLE_SERVICE_ACCOUNT_KEY_BASE64 not set}"

# Firebase Configuration
export FIREBASE_STORAGE_BUCKET="${CONF_FIREBASE_STORAGE_BUCKET:?CONF_FIREBASE_STORAGE_BUCKET not set}"

# OAuth2 Configuration
export GOOGLE_ID="${CONF_GOOGLE_ID:?CONF_GOOGLE_ID not set}"
export GOOGLE_SECRET="${CONF_GOOGLE_SECRET:?CONF_GOOGLE_SECRET not set}"
export FACEBOOK_ID="${CONF_FACEBOOK_ID:?CONF_FACEBOOK_ID not set}"
export FACEBOOK_SECRET="${CONF_FACEBOOK_SECRET:?CONF_FACEBOOK_SECRET not set}"
export APPLE_ID="${CONF_APPLE_ID:?CONF_APPLE_ID not set}"
export APPLE_SECRET="${CONF_APPLE_SECRET:?CONF_APPLE_SECRET not set}"

# RabbitMQ Configuration
export RABBITMQ_HOST="${CONF_RABBITMQ_HOST:?CONF_RABBITMQ_HOST not set}"
export RABBITMQ_PORT="${CONF_RABBITMQ_PORT:?CONF_RABBITMQ_PORT not set}"
export RABBITMQ_USER="${CONF_RABBITMQ_USER:?CONF_RABBITMQ_USER not set}"
export RABBITMQ_PASS="${CONF_RABBITMQ_PASS:?CONF_RABBITMQ_PASS not set}"

# Mail Configuration
export MAIL_USERNAME="${CONF_MAIL_USERNAME:?CONF_MAIL_USERNAME not set}"
export MAIL_PASSWORD="${CONF_MAIL_PASSWORD:?CONF_MAIL_PASSWORD not set}"

# --- Blue/Green Deployment Logic ---
ROOT="/home/almonium/infra"
COMPOSE_TEMPLATE_FILE="$ROOT/almonium-be/docker-compose.template.yaml"

# --- Environment-Specific Naming & State ---
PROJECT_NAME_BASE="almonium-be"
PROJECT_NAME_SUFFIX="_${DEPLOY_ENVIRONMENT}" # e.g., "_staging", "_prod"
COLOR_FILE="$ROOT/.next_color${PROJECT_NAME_SUFFIX}"

export DEPLOY_SLOT=$(cat "$COLOR_FILE" 2>/dev/null || echo "blue") # blue/green state per environment
export APP_INTERNAL_PORT="9998" # App listens on this port INSIDE its container

# These ports are only for the script's direct health check, not for public Traefik routing.
if [[ "$DEPLOY_ENVIRONMENT" == "staging" ]]; then
  LOCAL_HEALTHCHECK_PORT_BLUE="9978"  # Staging blue
  LOCAL_HEALTHCHECK_PORT_GREEN="9979" # Staging green
else # Default to production ports
  LOCAL_HEALTHCHECK_PORT_BLUE="9988"  # Production blue
  LOCAL_HEALTHCHECK_PORT_GREEN="9989" # Production green
fi

if [[ "$DEPLOY_SLOT" == "blue" ]]; then
  export LOCAL_HEALTHCHECK_PORT="$LOCAL_HEALTHCHECK_PORT_BLUE"
else
  export LOCAL_HEALTHCHECK_PORT="$LOCAL_HEALTHCHECK_PORT_GREEN"
fi

PREVIOUS_SLOT=$([[ "$DEPLOY_SLOT" == "blue" ]] && echo "green" || echo "blue")

# --- Docker Compose Project Name ---
DOCKER_COMPOSE_PROJECT_NAME="${PROJECT_NAME_BASE}${PROJECT_NAME_SUFFIX}"

echo "👉 Deploying for ENVIRONMENT: [$DEPLOY_ENVIRONMENT], TARGET SLOT: [$DEPLOY_SLOT]"
echo "   Application: ${PROJECT_NAME_BASE}, Docker Compose Project: ${DOCKER_COMPOSE_PROJECT_NAME}"
echo "   Image Tag: ${DEPLOY_IMAGE_TAG}, API Hostname for Traefik: $API_HOSTNAME"
echo "   App Internal Port: $APP_INTERNAL_PORT, Script Healthcheck via Host Port: $LOCAL_HEALTHCHECK_PORT"

echo "Pulling image for service 'app'..."
docker compose -p "${DOCKER_COMPOSE_PROJECT_NAME}" -f "$COMPOSE_TEMPLATE_FILE" pull app

echo "Starting/Updating service 'app' for slot [$DEPLOY_SLOT] in project [${DOCKER_COMPOSE_PROJECT_NAME}]..."
docker compose -p "${DOCKER_COMPOSE_PROJECT_NAME}" -f "$COMPOSE_TEMPLATE_FILE" up -d --remove-orphans app

EXPECTED_CONTAINER_NAME="app_${DEPLOY_ENVIRONMENT}_${DEPLOY_SLOT}"

echo "🩺 Waiting for container [$EXPECTED_CONTAINER_NAME] to be healthy on http://127.0.0.1:${LOCAL_HEALTHCHECK_PORT}/api/v1/actuator/health ..."
retries=60
count=0
until curl -sf "http://127.0.0.1:${LOCAL_HEALTHCHECK_PORT}/api/v1/actuator/health" 2>/dev/null | grep -q '"status":"UP"'; do
  count=$((count+1))
  if [ $count -ge $retries ]; then
    echo "❌ Health check failed for [$EXPECTED_CONTAINER_NAME] after $retries retries."
    docker compose -p "${DOCKER_COMPOSE_PROJECT_NAME}" -f "$COMPOSE_TEMPLATE_FILE" logs app
    exit 1
  fi
  echo "Health check attempt $count/$retries for [$EXPECTED_CONTAINER_NAME] failed. Retrying in 2s..."
  sleep 2
done
echo "✅ Container [$EXPECTED_CONTAINER_NAME] is healthy (checked via local port mapping)."

# --- Traffic Switching with Traefik ---

PREVIOUS_DOCKER_COMPOSE_PROJECT_NAME_FOR_DOWN="${PROJECT_NAME_BASE}${PROJECT_NAME_SUFFIX}"
DOCKER_PROJECT_NAME_CURRENT_SLOT="${PROJECT_NAME_BASE}${PROJECT_NAME_SUFFIX}_${DEPLOY_SLOT}"
DOCKER_PROJECT_NAME_PREVIOUS_SLOT="${PROJECT_NAME_BASE}${PROJECT_NAME_SUFFIX}_${PREVIOUS_SLOT}"

echo "Re-confirming current slot with project name ${DOCKER_PROJECT_NAME_CURRENT_SLOT}"
echo "Stopping previous slot by bringing down Docker Compose project: [$DOCKER_PROJECT_NAME_PREVIOUS_SLOT]."

PREVIOUS_CONTAINER_NAME="app_${DEPLOY_ENVIRONMENT}_${PREVIOUS_SLOT}"

echo "Stopping and removing previous container: [$PREVIOUS_CONTAINER_NAME]"

if docker ps -a --format '{{.Names}}' | grep -q "^${PREVIOUS_CONTAINER_NAME}$"; then
  docker stop "$PREVIOUS_CONTAINER_NAME" && docker rm "$PREVIOUS_CONTAINER_NAME" || echo "Warning: Could not stop/remove $PREVIOUS_CONTAINER_NAME cleanly."
else
  echo "Info: Previous container [$PREVIOUS_CONTAINER_NAME] not found or already removed."
fi

echo "🔀 Traefik should now be routing [$API_HOSTNAME] to [$EXPECTED_CONTAINER_NAME]."

# Flip the colour file for the next deploy for this environment
echo "$([[ "$DEPLOY_SLOT" == "blue" ]] && echo "green" || echo "blue")" > "$COLOR_FILE"

echo "✅ Deploy for ENV: [$DEPLOY_ENVIRONMENT], SLOT: [$DEPLOY_SLOT], HOSTNAME: [$API_HOSTNAME] finished successfully."
