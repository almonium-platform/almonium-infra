#!/usr/bin/env bash
# /usr/local/bin/deploy.sh on the server (symlink from repo)
# Usage: sudo deploy.sh <IMAGE_TAG>

set -euo pipefail
IMAGE_TAG="$1"

ROOT=/home/almonium/infra
COLOR_FILE="$ROOT/.next_color"
CURRENT_LINK="$ROOT/current"

# Decide which colour will be (re)deployed
NEXT=$(cat "$COLOR_FILE" 2>/dev/null || echo blue)
[[ "$NEXT" == blue ]] && PORT=9998 || PORT=9999

cd "$ROOT/$NEXT"

# Export TAG & PORT so compose picks them up
export TAG="$IMAGE_TAG"
export PORT="$PORT"

echo "👉 Deploying $NEXT stack with tag $TAG on port $PORT"

docker compose pull
docker compose up -d --remove-orphans

echo "🩺 Waiting for container health..."
until curl -sf "http://127.0.0.1:${PORT}/api/v1/actuator/health" | grep -q '"status":"UP"' ; do
  sleep 2
done

# Atomically swap Nginx upstream
ln -sfn "$(pwd)" "$CURRENT_LINK"
sudo nginx -s reload
echo "🔀 Traffic switched to $NEXT"

# Flip the colour for next deploy
echo $([[ "$NEXT" == blue ]] && echo green || echo blue) > "$COLOR_FILE"

# Optionally stop previous colour
PREV=$([[ "$NEXT" == blue ]] && echo green || echo blue)
docker compose -p "$PREV" -f "$ROOT/$PREV/docker-compose.yml" down --remove-orphans || true

echo "✅ Deploy finished"
