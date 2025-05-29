#!/usr/bin/env bash
set -euo pipefail # Exit on error, undefined variable, pipe failure

# --- Configuration & Secrets Export ---

# Deployment specific (from CI)
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

# Mail Configuration
export MAIL_USERNAME="${CONF_MAIL_USERNAME:?CONF_MAIL_USERNAME not set}"
export MAIL_PASSWORD="${CONF_MAIL_PASSWORD:?CONF_MAIL_PASSWORD not set}"

# --- Blue/Green Deployment Logic ---
ROOT="/home/almonium/infra"
COLOR_FILE="$ROOT/.next_color"
CURRENT_LINK="$ROOT/current" # Symlink Nginx points to (e.g., to $ROOT/blue or $ROOT/green)

# Decide which colour (slot) will be (re)deployed
export DEPLOY_SLOT=$(cat "$COLOR_FILE" 2>/dev/null || echo "blue") # 'blue' or 'green'

# Determine host port and internal app port for this slot
export APP_INTERNAL_PORT="9998" # Your Spring Boot app listens on this port INSIDE the container
if [[ "$DEPLOY_SLOT" == "blue" ]]; then
  export HOST_PORT="9998" # Blue exposed on host 9998
else
  export HOST_PORT="9999" # Green exposed on host 9999
fi

# Export TAG & PORT so compose picks them up
TARGET_DIR="$ROOT/$DEPLOY_SLOT"
cd "$TARGET_DIR" # e.g., /home/almonium/infra/blue or /home/almonium/infra/green

echo "👉 Deploying $DEPLOY_SLOT stack (service: app) with image tag $TAG, container host port $HOST_PORT (app internal port $APP_INTERNAL_PORT)"

docker compose pull app
docker compose up -d --remove-orphans app

echo "🩺 Waiting for container health on http://127.0.0.1:${HOST_PORT}/api/v1/actuator/health ..."
retries=30
count=0
# Health check against the HOST_PORT because that's where Nginx will eventually route traffic.
# The docker-compose.yaml maps HOST_PORT to APP_INTERNAL_PORT.
until curl -sf "http://127.0.0.1:${HOST_PORT}/api/v1/actuator/health" 2>/dev/null | grep -q '"status":"UP"'; do
  count=$((count+1))
  if [ $count -ge $retries ]; then
    echo "❌ Health check failed for $DEPLOY_SLOT after $retries retries. See logs for 'app_${DEPLOY_SLOT}'."
    # Consider adding: docker compose logs app
    exit 1
  fi
  sleep 2
done
echo "✅ Container for $DEPLOY_SLOT is healthy."

# Atomically swap Nginx upstream
# This assumes Nginx is configured to read from a file/path identified by $CURRENT_LINK
# or that $CURRENT_LINK itself being 'blue' or 'green' influences a map directive.
# Example: Nginx might include $CURRENT_LINK/nginx.conf or similar.
# $(pwd) is $TARGET_DIR which is $ROOT/$DEPLOY_SLOT
ln -sfn "$TARGET_DIR" "$CURRENT_LINK"
# Ensure the user running this script (almonium) has NOPASSWD sudo rights for 'nginx -s reload'
sudo nginx -s reload
echo "🔀 Traffic switched to $DEPLOY_SLOT"

# Flip the colour for the next deploy
NEXT_DEPLOY_SLOT=$([[ "$DEPLOY_SLOT" == "blue" ]] && echo "green" || echo "blue")
echo "$NEXT_DEPLOY_SLOT" > "$COLOR_FILE"

# Optionally stop previous colour's container(s)
PREVIOUS_SLOT="$NEXT_DEPLOY_SLOT" # This is the slot that was active *before* this deployment
PREVIOUS_DIR="$ROOT/$PREVIOUS_SLOT"

if [ -d "$PREVIOUS_DIR" ] && [ -f "$PREVIOUS_DIR/docker-compose.yaml" ]; then
  echo "Stopping previous slot: $PREVIOUS_SLOT"
  # Running docker-compose from within the previous slot's directory ensures correct project context.
  (cd "$PREVIOUS_DIR" && docker compose down --remove-orphans) || echo "Could not stop $PREVIOUS_SLOT, or it was already down. Continuing."
else
  echo "No previous slot $PREVIOUS_SLOT directory or compose file found to stop."
fi

echo "✅ Deploy of $DEPLOY_SLOT finished successfully."
