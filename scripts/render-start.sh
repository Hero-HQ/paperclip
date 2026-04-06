#!/bin/sh
# Render production startup script for Paperclip AI
# Auto-bootstraps admin invite on first run, then keeps server running
set -e

echo "[render-start] Paperclip AI starting..."
echo "[render-start] Version: $(cat /app/server/dist/version.js 2>/dev/null | grep -o '"[0-9.]*"' | head -1 || echo unknown)"

# Start the Paperclip server in background
node --import /app/server/node_modules/tsx/dist/loader.mjs /app/server/dist/index.js &
SERVER_PID=$!
echo "[render-start] Server started (PID=$SERVER_PID)"

# Wait up to 90s for server to become healthy
PORT="${PORT:-10000}"
HEALTH_URL="http://127.0.0.1:${PORT}/api/health"
echo "[render-start] Waiting for health check at $HEALTH_URL"
HEALTHY=0
for i in $(seq 1 45); do
  sleep 2
  RESPONSE=$(node -e "
    const http=require('http');
    const req=http.request('$HEALTH_URL',res=>{
      let d='';res.on('data',c=>d+=c);
      res.on('end',()=>{try{console.log(JSON.parse(d).status)}catch{console.log('err')}});
    });
    req.on('error',()=>console.log('down'));
    req.setTimeout(3000,()=>{req.destroy();console.log('timeout')});
    req.end();
  " 2>/dev/null || echo "down")
  if [ "$RESPONSE" = "ok" ]; then
    echo "[render-start] Server healthy after ${i}x2s"
    HEALTHY=1
    break
  fi
done

if [ "$HEALTHY" = "0" ]; then
  echo "[render-start] Server failed to become healthy"
  wait $SERVER_PID
  exit 1
fi

# Check bootstrap status
BOOTSTRAP_STATUS=$(node -e "
  const http=require('http');
  const req=http.request('$HEALTH_URL',res=>{
    let d='';res.on('data',c=>d+=c);
    res.on('end',()=>{
      try{const j=JSON.parse(d);console.log(j.bootstrapStatus+'|'+j.bootstrapInviteActive)}
      catch{console.log('unknown|false')}
    });
  });
  req.on('error',()=>console.log('unknown|false'));
  req.end();
" 2>/dev/null || echo "unknown|false")

BSTATUS=$(echo "$BOOTSTRAP_STATUS" | cut -d'|' -f1)
BACTIVE=$(echo "$BOOTSTRAP_STATUS" | cut -d'|' -f2)

echo "[render-start] Bootstrap status: $BSTATUS (invite active: $BACTIVE)"

if [ "$BSTATUS" = "bootstrap_pending" ] && [ "$BACTIVE" = "false" ]; then
  echo "[render-start] No admin exists — creating bootstrap invite..."
  # Run bootstrap-ceo using the CLI
  node /app/cli/node_modules/tsx/dist/cli.mjs /app/cli/src/index.ts \
    auth bootstrap-ceo \
    --base-url "${PAPERCLIP_PUBLIC_URL:-http://localhost:$PORT}" \
    2>&1 || echo "[render-start] Bootstrap invite creation failed (check DB connectivity)"
elif [ "$BSTATUS" = "bootstrap_pending" ] && [ "$BACTIVE" = "true" ]; then
  echo "[render-start] Bootstrap invite already exists — check logs for invite URL"
else
  echo "[render-start] Admin already configured — skipping bootstrap"
fi

echo "[render-start] ✅ Startup complete — server running on port $PORT"
echo "[render-start] Dashboard: ${PAPERCLIP_PUBLIC_URL:-http://localhost:$PORT}"

# Wait for server (keeps container running)
wait $SERVER_PID
