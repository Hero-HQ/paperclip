#!/bin/sh
# Render startup script — auto-bootstraps admin on every restart until admin exists
set -e

PORT="${PORT:-10000}"
echo "[render-start] Starting Paperclip on port $PORT..."

# Start server in background
node --import /app/server/node_modules/tsx/dist/loader.mjs /app/server/dist/index.js &
SERVER_PID=$!

# Wait for health
HEALTHY=0
for i in $(seq 1 45); do
  sleep 2
  STATUS=$(curl -sf "http://127.0.0.1:${PORT}/api/health" 2>/dev/null \
    | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{process.stdout.write(JSON.parse(d).status)}catch{process.stdout.write('err')}})" 2>/dev/null \
    || echo "down")
  if [ "$STATUS" = "ok" ]; then
    echo "[render-start] Server healthy (${i}x2s)"
    HEALTHY=1; break
  fi
done

if [ "$HEALTHY" = "0" ]; then
  echo "[render-start] ERROR: Server never became healthy"
  wait $SERVER_PID; exit 1
fi

# Auto-bootstrap: always revoke+recreate invite if no admin yet
HEALTH=$(curl -sf "http://127.0.0.1:${PORT}/api/health" 2>/dev/null || echo '{}')
BSTATUS=$(echo "$HEALTH" | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{process.stdout.write(JSON.parse(d).bootstrapStatus)}catch{process.stdout.write('unknown')}})" 2>/dev/null || echo "unknown")

echo "[render-start] Bootstrap status: $BSTATUS"

if [ "$BSTATUS" = "bootstrap_pending" ]; then
  node << 'JSEOF'
const crypto = require('crypto');
async function run() {
  const DATABASE_URL = process.env.DATABASE_URL;
  if (!DATABASE_URL) { console.error('[bootstrap] ERROR: DATABASE_URL not set'); return; }

  let sql;
  for (const p of ['/app/node_modules/postgres','/app/packages/db/node_modules/postgres','/app/server/node_modules/postgres']) {
    try { sql = require(p)(DATABASE_URL, {max:1,idle_timeout:5}); break; } catch(e) {}
  }
  if (!sql) { console.error('[bootstrap] postgres module not found in standard paths'); return; }

  try {
    // Always revoke existing and create fresh so we always have a printable URL
    await sql`UPDATE invites SET revoked_at=NOW(), updated_at=NOW()
      WHERE invite_type='bootstrap_ceo' AND revoked_at IS NULL AND accepted_at IS NULL`;

    const token = 'pcp_bootstrap_' + crypto.randomBytes(24).toString('hex');
    const tokenHash = crypto.createHash('sha256').update(token).digest('hex');
    const expiresAt = new Date(Date.now() + 72*60*60*1000);

    await sql`INSERT INTO invites (invite_type, token_hash, allowed_join_types, expires_at, invited_by_user_id, created_at, updated_at)
      VALUES ('bootstrap_ceo', ${tokenHash}, 'human', ${expiresAt}, 'system', NOW(), NOW())`;

    await sql.end();

    const baseUrl = (process.env.PAPERCLIP_PUBLIC_URL || 'http://localhost:10000').replace(/\/+$/, '');
    const url = `${baseUrl}/invite/${token}`;
    console.log('');
    console.log('='.repeat(70));
    console.log('[bootstrap] ✅ ADMIN SETUP — open this URL in your browser:');
    console.log(`[bootstrap] ${url}`);
    console.log(`[bootstrap] Expires: ${expiresAt.toISOString()}`);
    console.log('='.repeat(70));
    console.log('');
  } catch(err) {
    console.error('[bootstrap] DB error:', err.message);
    try { await sql.end(); } catch {}
  }
}
run().catch(e => console.error('[bootstrap] Fatal:', e.message));
JSEOF
else
  echo "[render-start] Admin exists — no bootstrap needed"
fi

echo "[render-start] Ready — ${PAPERCLIP_PUBLIC_URL:-http://localhost:$PORT}"
wait $SERVER_PID
