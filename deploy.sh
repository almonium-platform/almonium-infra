#!/usr/bin/env bash
set -euo pipefail # Exit on error, undefined variable, pipe failure

# --- Configuration & Secrets Export ---
export TAG="${1:?Error: IMAGE_TAG argument (DEPLOY_IMAGE_TAG) is required.}"

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
export DB_USERNAME="${CONF_DB_USERNAME:?CONF_DB_USERNAME not set}"
export DB_PASSWORD="${CONF_DB_PASSWORD:?CONF_DB_PASSWORD not set}"

# API Keys
export RAPID_API_KEY="${CONF_RAPID_API_KEY:?CONF_RAPID_API_KEY not set}"
export WORDNIK_KEY="${CONF_WORDNIK_KEY:?CONF_WORDNIK_KEY not set}"
export YANDEX_KEY="${CONF_YANDEX_KEY:?CONF_YANDEX_KEY not set}"
export OPENAI_KEY="${CONF_OPENAI_KEY:?CONF_OPENAI_KEY not set}"

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
COLOR_FILE="$ROOT/.next_color"
COMPOSE_TEMPLATE_FILE="$ROOT/docker-compose.template.yaml"

# Decide which colour (slot) will be (re)deployed
export DEPLOY_SLOT=$(cat "$COLOR_FILE" 2>/dev/null || echo "blue")
export APP_INTERNAL_PORT="9998" # App listens on this port INSIDE its container

# Use distinct local ports for healthchecking blue/green slots directly via Docker port mapping
LOCAL_HEALTHCHECK_PORT_BLUE="9988" # Arbitrary, unused host port for blue healthcheck
LOCAL_HEALTHCHECK_PORT_GREEN="9989" # Arbitrary, unused host port for green healthcheck

if [[ "$DEPLOY_SLOT" == "blue" ]]; then
  export LOCAL_HEALTHCHECK_PORT="$LOCAL_HEALTHCHECK_PORT_BLUE"
  export TRAEFIK_ROUTER_PRIORITY="100" # Active slot gets high priority
else
  export LOCAL_HEALTHCHECK_PORT="$LOCAL_HEALTHCHECK_PORT_GREEN"
  export TRAEFIK_ROUTER_PRIORITY="100" # Active slot gets high priority
fi

# Determine the PREVIOUS slot that needs to be stopped/deprioritized
PREVIOUS_SLOT=$([[ "$DEPLOY_SLOT" == "blue" ]] && echo "green" || echo "blue")

echo "👉 Deploying app slot: $DEPLOY_SLOT with image tag $TAG for Traefik."
echo "   App internal port: $APP_INTERNAL_PORT, Local healthcheck via host port: $LOCAL_HEALTHCHECK_PORT"
echo "   This slot ($DEPLOY_SLOT) will be configured as the LIVE service for api.almonium.com."

# Pull the new image
docker compose -p "$DEPLOY_SLOT" -f "$COMPOSE_TEMPLATE_FILE" pull app

# Start the new application slot (blue or green).
# Its labels will define it as wanting to serve api.almonium.com.
# TRAEFIK_ROUTER_PRIORITY is passed as an env var for the compose template if needed.
docker compose -p "$DEPLOY_SLOT" -f "$COMPOSE_TEMPLATE_FILE" up -d --remove-orphans app

echo "🩺 Waiting for container $DEPLOY_SLOT (app_${DEPLOY_SLOT}) to be healthy on http://127.0.0.1:${LOCAL_HEALTHCHECK_PORT}/api/v1/actuator/health ..."
retries=60 # Increased retries slightly
count=0
until curl -sf "http://127.0.0.1:${LOCAL_HEALTHCHECK_PORT}/api/v1/actuator/health" 2>/dev/null | grep -q '"status":"UP"'; do
  count=$((count+1))
  if [ $count -ge $retries ]; then
    echo "❌ Health check failed for $DEPLOY_SLOT (app_${DEPLOY_SLOT}) after $retries retries."
    docker compose -p "$DEPLOY_SLOT" -f "$COMPOSE_TEMPLATE_FILE" logs app # Show logs on failure
    exit 1
  fi
  echo "Health check attempt $count/$retries for $DEPLOY_SLOT failed. Retrying in 2s..."
  sleep 2
done
echo "✅ Container $DEPLOY_SLOT (app_${DEPLOY_SLOT}) is healthy (checked via local port mapping)."

# --- Traffic Switching with Traefik ---
echo "Switching Traefik traffic to $DEPLOY_SLOT by stopping previous slot: $PREVIOUS_SLOT."

# Stop and remove the PREVIOUS application slot.
# When it's gone, Traefik will only see the NEWLY DEPLOYED slot (DEPLOY_SLOT)
# as a backend for the Host(`api.almonium.com`) router rule.
docker compose -p "$PREVIOUS_SLOT" -f "$COMPOSE_TEMPLATE_FILE" down --remove-orphans || echo "Info: Could not stop $PREVIOUS_SLOT (app_${PREVIOUS_SLOT}), or it was already down."

echo "🔀 Traefik should now be routing traffic for api.almonium.com to $DEPLOY_SLOT (app_${DEPLOY_SLOT})."

# Flip the colour for the next deploy
echo "$([[ "$DEPLOY_SLOT" == "blue" ]] && echo "green" || echo "blue")" > "$COLOR_FILE"

echo "✅ Deploy of $DEPLOY_SLOT (for Traefik) finished successfully."
