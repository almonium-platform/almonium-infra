#!/usr/bin/env bash
set -euo pipefail # Exit on error, undefined variable, pipe failure

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
echo "   Image Tag: $TAG, API Hostname for Traefik: $API_HOSTNAME"
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
