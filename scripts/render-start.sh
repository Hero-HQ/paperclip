#!/bin/sh
# Render production startup for Paperclip AI
# If PAPERCLIP_ADMIN_EMAIL + PAPERCLIP_ADMIN_PASSWORD are set,
# auto-creates the admin account on first run — no invite URL needed.
set -e

INTERNAL_PORT=3100
echo "[render-start] Starting Paperclip..."

node --import /app/server/node_modules/tsx/dist/loader.mjs /app/server/dist/index.js &
SERVER_PID=$!

# Wait for server
HEALTHY=0
for i in $(seq 1 45); do
  sleep 2
  STATUS=$(curl -sf "http://127.0.0.1:${INTERNAL_PORT}/api/health" 2>/dev/null \
    | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{process.stdout.write(JSON.parse(d).status)}catch{process.stdout.write('err')}})" 2>/dev/null \
    || echo "down")
  [ "$STATUS" = "ok" ] && { echo "[render-start] Healthy (${i}x2s)"; HEALTHY=1; break; }
done

[ "$HEALTHY" = "0" ] && { echo "[render-start] ERROR: Never became healthy"; wait $SERVER_PID; exit 1; }

# Auto-bootstrap if admin email+password are configured
ADMIN_EMAIL="${PAPERCLIP_ADMIN_EMAIL:-}"
ADMIN_PASSWORD="${PAPERCLIP_ADMIN_PASSWORD:-}"
BSTATUS=$(curl -sf "http://127.0.0.1:${INTERNAL_PORT}/api/health" 2>/dev/null \
  | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{process.stdout.write(JSON.parse(d).bootstrapStatus)}catch{process.stdout.write('unknown')}})" 2>/dev/null \
  || echo "unknown")

echo "[render-start] Bootstrap status: $BSTATUS"

if [ "$BSTATUS" = "bootstrap_pending" ] && [ -n "$ADMIN_EMAIL" ] && [ -n "$ADMIN_PASSWORD" ]; then
  echo "[render-start] Auto-creating admin: $ADMIN_EMAIL"

  node << JSEOF
const http = require('http');
const crypto = require('crypto');

function post(path, body, cookie) {
  return new Promise((resolve) => {
    const data = JSON.stringify(body);
    const headers = {
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(data),
      'Origin': process.env.PAPERCLIP_PUBLIC_URL || 'https://paperclip-m2ko.onrender.com',
    };
    if (cookie) headers['Cookie'] = cookie;
    const req = http.request({
      hostname: '127.0.0.1', port: ${INTERNAL_PORT}, path, method: 'POST', headers
    }, res => {
      let d = '';
      const cookies = res.headers['set-cookie'] || [];
      res.on('data', c => d += c);
      res.on('end', () => {
        try { resolve({ body: JSON.parse(d), status: res.statusCode, cookies }); }
        catch { resolve({ body: d, status: res.statusCode, cookies }); }
      });
    });
    req.on('error', e => resolve({ error: e.message }));
    req.write(data);
    req.end();
  });
}

async function main() {
  const email = process.env.PAPERCLIP_ADMIN_EMAIL;
  const password = process.env.PAPERCLIP_ADMIN_PASSWORD;
  const name = process.env.PAPERCLIP_ADMIN_NAME || 'Deeply Admin';

  // Step 1: Sign up (or sign in if already exists)
  let userId, sessionCookie;
  let res = await post('/api/auth/sign-up/email', { email, password, name });
  if (res.status === 200 && res.body.user) {
    userId = res.body.user.id;
    sessionCookie = res.cookies.find(c => c.includes('session_token'))?.split(';')[0];
    console.log('[bootstrap] Created user:', userId);
  } else if (res.body?.code === 'USER_ALREADY_EXISTS_USE_ANOTHER_EMAIL') {
    // Sign in instead
    res = await post('/api/auth/sign-in/email', { email, password });
    if (res.status === 200 && res.body.user) {
      userId = res.body.user.id;
      sessionCookie = res.cookies.find(c => c.includes('session_token'))?.split(';')[0];
      console.log('[bootstrap] Signed in existing user:', userId);
    } else {
      console.error('[bootstrap] Sign-in failed:', JSON.stringify(res.body));
      return;
    }
  } else {
    console.error('[bootstrap] Sign-up failed:', res.status, JSON.stringify(res.body));
    return;
  }

  if (!userId) { console.error('[bootstrap] No userId'); return; }

  // Step 2: Promote to instance admin directly via DB
  let sql;
  for (const p of ['/app/node_modules/postgres', '/app/packages/db/node_modules/postgres', '/app/server/node_modules/postgres']) {
    try { sql = require(p)(process.env.DATABASE_URL, { max: 1, idle_timeout: 5 }); break; } catch(e) {}
  }
  if (!sql) { console.error('[bootstrap] postgres module not found'); return; }

  try {
    // Check if already admin
    const existing = await sql\`SELECT id FROM instance_user_roles WHERE user_id = \${userId} AND role = 'instance_admin'\`;
    if (existing.length > 0) {
      console.log('[bootstrap] User already instance admin');
    } else {
      await sql\`INSERT INTO instance_user_roles (user_id, role, created_at, updated_at)
        VALUES (\${userId}, 'instance_admin', NOW(), NOW())
        ON CONFLICT DO NOTHING\`;
      console.log('[bootstrap] Promoted to instance admin');
    }
    await sql.end();

    const baseUrl = (process.env.PAPERCLIP_PUBLIC_URL || 'https://paperclip-m2ko.onrender.com').replace(/\/+$/, '');
    console.log('');
    console.log('='.repeat(60));
    console.log('[bootstrap] ADMIN READY');
    console.log('[bootstrap] URL:      ' + baseUrl);
    console.log('[bootstrap] Email:    ' + email);
    console.log('[bootstrap] Password: (set via PAPERCLIP_ADMIN_PASSWORD)');
    console.log('='.repeat(60));
    console.log('');
  } catch(err) {
    console.error('[bootstrap] DB error:', err.message);
    try { await sql.end(); } catch {}
  }
}

main().catch(e => console.error('[bootstrap] Fatal:', e.message));
JSEOF

elif [ "$BSTATUS" = "bootstrap_pending" ]; then
  echo "[render-start] WARN: No PAPERCLIP_ADMIN_EMAIL set — manual bootstrap required"
  echo "[render-start] Set PAPERCLIP_ADMIN_EMAIL + PAPERCLIP_ADMIN_PASSWORD in Render environment"
else
  echo "[render-start] Admin already configured"
fi

echo "[render-start] Ready — ${PAPERCLIP_PUBLIC_URL}"
wait $SERVER_PID
