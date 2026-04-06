#!/bin/sh
# Render production startup script for Paperclip AI
# Starts server, then auto-bootstraps admin invite on first run
set -e

echo "[render-start] Paperclip AI starting on port ${PORT:-10000}..."

# Start the Paperclip server in background
node --import /app/server/node_modules/tsx/dist/loader.mjs /app/server/dist/index.js &
SERVER_PID=$!

# Wait up to 90s for server to become healthy
PORT="${PORT:-10000}"
HEALTHY=0
for i in $(seq 1 45); do
  sleep 2
  STATUS=$(node -e "
    const http=require('http');
    const req=http.request({hostname:'127.0.0.1',port:$PORT,path:'/api/health'},res=>{
      let d='';res.on('data',c=>d+=c);
      res.on('end',()=>{try{console.log(JSON.parse(d).status)}catch{console.log('err')}});
    });
    req.on('error',()=>console.log('down'));
    req.setTimeout(3000,()=>{req.destroy();console.log('timeout')});
    req.end();
  " 2>/dev/null || echo "down")
  if [ "$STATUS" = "ok" ]; then
    echo "[render-start] Server healthy (${i}x2s)"
    HEALTHY=1
    break
  fi
done

if [ "$HEALTHY" = "0" ]; then
  echo "[render-start] ERROR: Server never became healthy"
  wait $SERVER_PID; exit 1
fi

# Check bootstrap status and auto-create invite if needed
node -e "
const http = require('http');
const { createHash, randomBytes } = require('crypto');

function get(path) {
  return new Promise((resolve) => {
    const req = http.request({hostname:'127.0.0.1',port:$PORT,path}, res => {
      let d=''; res.on('data',c=>d+=c);
      res.on('end', () => { try { resolve(JSON.parse(d)); } catch { resolve({}); } });
    });
    req.on('error', () => resolve({}));
    req.end();
  });
}

async function main() {
  const health = await get('/api/health');
  console.log('[bootstrap] status:', health.bootstrapStatus, '| invite active:', health.bootstrapInviteActive);
  
  if (health.bootstrapStatus !== 'bootstrap_pending' || health.bootstrapInviteActive === true) {
    console.log('[bootstrap] No action needed');
    return;
  }

  // Direct DB approach — insert bootstrap invite
  const { Client } = require('/app/server/node_modules/pg');
  const client = new Client({ connectionString: process.env.DATABASE_URL });
  await client.connect();

  const token = 'pcp_bootstrap_' + randomBytes(24).toString('hex');
  const tokenHash = createHash('sha256').update(token).digest('hex');
  const expiresAt = new Date(Date.now() + 72 * 60 * 60 * 1000); // 72h

  // Revoke any existing pending bootstrap invites
  await client.query(
    \`UPDATE invites SET revoked_at=NOW(), updated_at=NOW()
     WHERE invite_type='bootstrap_ceo' AND revoked_at IS NULL AND accepted_at IS NULL AND expires_at > NOW()\`
  );

  // Insert new bootstrap invite
  await client.query(
    \`INSERT INTO invites (invite_type, token_hash, allowed_join_types, expires_at, invited_by_user_id, created_at, updated_at)
     VALUES ('bootstrap_ceo', \$1, 'human', \$2, 'system', NOW(), NOW())\`,
    [tokenHash, expiresAt]
  );

  await client.end();

  const baseUrl = process.env.PAPERCLIP_PUBLIC_URL || 'http://localhost:$PORT';
  const inviteUrl = baseUrl + '/invite/' + token;
  console.log('');
  console.log('='.repeat(60));
  console.log('[bootstrap] ✅ BOOTSTRAP INVITE CREATED');
  console.log('[bootstrap] Open this URL to create the admin account:');
  console.log('[bootstrap] ' + inviteUrl);
  console.log('[bootstrap] Expires: ' + expiresAt.toISOString());
  console.log('='.repeat(60));
  console.log('');
}

main().catch(err => {
  console.error('[bootstrap] ERROR:', err.message);
});
" 2>&1

echo "[render-start] ✅ Ready — ${PAPERCLIP_PUBLIC_URL:-http://localhost:$PORT}"
wait $SERVER_PID
