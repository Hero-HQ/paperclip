#!/bin/sh
# Render production startup script for Paperclip AI
# Starts server + auto-creates bootstrap admin invite on first run
set -e

PORT="${PORT:-10000}"
echo "[render-start] Starting Paperclip on port $PORT..."

# Start Paperclip server in background
node --import /app/server/node_modules/tsx/dist/loader.mjs /app/server/dist/index.js &
SERVER_PID=$!

# Wait up to 90s for server health
HEALTHY=0
for i in $(seq 1 45); do
  sleep 2
  STATUS=$(curl -sf "http://127.0.0.1:${PORT}/api/health" 2>/dev/null | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{process.stdout.write(JSON.parse(d).status)}catch{process.stdout.write('err')}})" 2>/dev/null || echo "down")
  if [ "$STATUS" = "ok" ]; then
    echo "[render-start] Healthy after $((i*2))s"
    HEALTHY=1
    break
  fi
done

if [ "$HEALTHY" = "0" ]; then
  echo "[render-start] ERROR: Server never became healthy — exiting"
  wait $SERVER_PID; exit 1
fi

# Check if bootstrap is needed
HEALTH=$(curl -sf "http://127.0.0.1:${PORT}/api/health" 2>/dev/null || echo '{}')
B_STATUS=$(echo "$HEALTH" | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{const j=JSON.parse(d);process.stdout.write(j.bootstrapStatus+'|'+j.bootstrapInviteActive)}catch{process.stdout.write('unknown|false')}})" 2>/dev/null || echo "unknown|false")
BSTATUS=$(echo "$B_STATUS" | cut -d'|' -f1)
BACTIVE=$(echo "$B_STATUS" | cut -d'|' -f2)

echo "[render-start] Bootstrap: status=$BSTATUS active=$BACTIVE"

if [ "$BSTATUS" = "bootstrap_pending" ] && [ "$BACTIVE" = "false" ]; then
  echo "[render-start] Creating bootstrap invite via DB..."
  
  # Use the postgres package bundled with the app
  POSTGRES_MOD=$(find /app/node_modules/postgres /app/packages/db/node_modules/postgres -name "src/index.js" 2>/dev/null | head -1 || echo "")
  if [ -z "$POSTGRES_MOD" ]; then
    POSTGRES_MOD=$(node -e "console.log(require.resolve('postgres',{paths:['/app','/app/packages/db','/app/server']}))" 2>/dev/null || echo "")
  fi
  
  echo "[render-start] postgres module: $POSTGRES_MOD"
  
  node << JSEOF
const crypto = require('crypto');

async function run() {
  const DATABASE_URL = process.env.DATABASE_URL;
  if (!DATABASE_URL) { console.error('[bootstrap] ERROR: DATABASE_URL not set'); return; }

  // Try to find postgres module
  let sql;
  const paths = [
    '/app/node_modules/postgres',
    '/app/packages/db/node_modules/postgres',
    '/app/server/node_modules/postgres'
  ];
  for (const p of paths) {
    try { sql = require(p)(DATABASE_URL, {max:1,idle_timeout:10}); break; } catch(e) {}
  }
  if (!sql) { console.error('[bootstrap] ERROR: postgres module not found'); return; }

  try {
    const token = 'pcp_bootstrap_' + crypto.randomBytes(24).toString('hex');
    const tokenHash = crypto.createHash('sha256').update(token).digest('hex');
    const expiresAt = new Date(Date.now() + 72*60*60*1000).toISOString();

    // Revoke existing pending invites
    await sql\`UPDATE invites SET revoked_at=NOW(), updated_at=NOW()
      WHERE invite_type='bootstrap_ceo' AND revoked_at IS NULL AND accepted_at IS NULL AND expires_at > NOW()\`;

    // Insert bootstrap invite
    await sql\`INSERT INTO invites (invite_type, token_hash, allowed_join_types, expires_at, invited_by_user_id, created_at, updated_at)
      VALUES ('bootstrap_ceo', \${tokenHash}, 'human', \${expiresAt}, 'system', NOW(), NOW())\`;

    await sql.end();

    const baseUrl = (process.env.PAPERCLIP_PUBLIC_URL || 'http://localhost:${PORT}').replace(/\/+$/, '');
    const inviteUrl = baseUrl + '/invite/' + token;

    console.log('');
    console.log('============================================================');
    console.log('[bootstrap] ADMIN SETUP — open this URL in your browser:');
    console.log('[bootstrap] ' + inviteUrl);
    console.log('[bootstrap] Expires in 72 hours');
    console.log('============================================================');
    console.log('');
  } catch(err) {
    console.error('[bootstrap] DB error:', err.message);
    try { await sql.end(); } catch {}
  }
}

run().catch(err => console.error('[bootstrap] Fatal:', err.message));
JSEOF

else
  echo "[render-start] Bootstrap not needed (status=$BSTATUS active=$BACTIVE)"
fi

echo "[render-start] Ready — ${PAPERCLIP_PUBLIC_URL:-http://localhost:$PORT}"
wait $SERVER_PID
