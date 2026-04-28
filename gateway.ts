/**
 * GBrain HTTP MCP Gateway
 *
 * gbrain serve speaks stdio-only. This gateway:
 *   1. Keeps one persistent gbrain serve process alive
 *   2. Validates Bearer tokens against gbrain's access_tokens table
 *   3. Routes POST /mcp → gbrain stdin → response → HTTP
 *   4. Handles JSON-RPC notifications (no id) with 202, no gbrain response expected
 *   5. Serves GET /mcp as SSE keepalive for Streamable HTTP transport
 *   6. Queues concurrent requests (gbrain serves one at a time, state is in DB)
 *   7. Auto-respawns gbrain process on timeout (stuck mid-protocol recovery)
 *
 * Port: GBRAIN_PORT env var (default 8787)
 */
import { createHash } from 'node:crypto';
import postgres from 'postgres';

const PORT = parseInt(Bun.env.GBRAIN_PORT ?? '8787');
const DATABASE_URL = Bun.env.DATABASE_URL!;

// ── Database connection ───────────────────────────────────────────────────────
const db = postgres(DATABASE_URL);

// ── Token validation ──────────────────────────────────────────────────────────
// GBrain stores tokens SHA-256 hashed in the access_tokens table.
// Cache for 5 minutes to avoid repeated DB round-trips.
const tokenCache = new Map<string, { valid: boolean; ts: number }>();
const TOKEN_TTL = 5 * 60 * 1000;

async function isValidToken(token: string): Promise<boolean> {
  const cached = tokenCache.get(token);
  if (cached && Date.now() - cached.ts < TOKEN_TTL) return cached.valid;
  const hash = createHash('sha256').update(token).digest('hex');
  try {
    const rows = await db`
      SELECT 1 FROM access_tokens
      WHERE token_hash = ${hash}
        AND revoked_at IS NULL
      LIMIT 1
    `;
    const valid = rows.length > 0;
    tokenCache.set(token, { valid, ts: Date.now() });
    return valid;
  } catch (err) {
    console.error('[gateway] token validation failed — failing open', err);
    return true;
  }
}

// ── Persistent gbrain serve process ──────────────────────────────────────────
// One process, one queue. gbrain stdio is synchronous: one JSON-RPC message
// in → one JSON-RPC response out. Concurrent requests are serialised.
type QueueEntry = { msg: string; resolve: (r: string) => void; reject: (e: Error) => void };
let gbrainProc: ReturnType<typeof Bun.spawn>;
let readBuffer = '';
let locked = false;
const queue: QueueEntry[] = [];
const pending: ((line: string) => void)[] = [];

function spawnGbrain() {
  const proc = Bun.spawn(
    ['bun', '/gbrain/src/cli.ts', 'serve'],
    {
      stdin: 'pipe',
      stdout: 'pipe',
      stderr: 'inherit',   // gbrain log messages → container stderr → Dokploy logs
      cwd: '/gbrain',
      env: Bun.env as Record<string, string>,
    }
  );

  // Pipe stdout → pending callbacks, filter to JSON lines only.
  // gbrain may emit non-JSON startup text; we skip anything that isn't JSON.
  (async () => {
    const reader = proc.stdout.getReader();
    const dec = new TextDecoder();
    while (true) {
      const { done, value } = await reader.read();
      if (done) {
        console.error('[gateway] gbrain serve exited — restarting...');
        gbrainProc = spawnGbrain();
        return;
      }
      readBuffer += dec.decode(value);
      const lines = readBuffer.split('\n');
      readBuffer = lines.pop() ?? '';
      for (const line of lines) {
        const t = line.trim();
        // Only dispatch valid JSON objects (MCP responses)
        if (t.startsWith('{') && pending.length > 0) {
          pending.shift()!(t);
        }
      }
    }
  })();

  return proc;
}

function drainQueue() {
  if (locked || queue.length === 0) return;
  locked = true;
  const { msg, resolve, reject } = queue.shift()!;

  const timer = setTimeout(() => {
    pending.shift();
    reject(new Error('gbrain serve response timeout (30s)'));
    locked = false;
    // Kill stale process — it may be stuck mid-protocol handshake
    gbrainProc.kill();
    gbrainProc = spawnGbrain();
    drainQueue();
  }, 30_000);

  pending.push((line: string) => {
    clearTimeout(timer);
    resolve(line);
    locked = false;
    drainQueue();
  });

  gbrainProc.stdin.write(msg + '\n');
}

async function callGbrain(msg: string): Promise<string> {
  return new Promise((resolve, reject) => {
    queue.push({ msg, resolve, reject });
    drainQueue();
  });
}

// ── Start the gbrain process ──────────────────────────────────────────────────
gbrainProc = spawnGbrain();
console.log('[gateway] gbrain serve process started');

// ── HTTP Server ───────────────────────────────────────────────────────────────
Bun.serve({
  port: PORT,
  async fetch(req: Request): Promise<Response> {
    const { pathname } = new URL(req.url);

    // Health check — no auth required
    if (pathname === '/health') {
      return new Response('OK', { status: 200 });
    }

    // Auth
    const auth = req.headers.get('Authorization') ?? '';
    if (!auth.startsWith('Bearer ')) {
      return Response.json(
        { error: 'missing_auth', message: 'Authorization: Bearer TOKEN header required' },
        { status: 401 }
      );
    }
    const valid = await isValidToken(auth.slice(7));
    if (!valid) {
      return Response.json(
        { error: 'invalid_token', message: 'Token not found — create one with: bun run src/commands/auth.ts create "name"' },
        { status: 401 }
      );
    }

    // SSE stream for Streamable HTTP transport (server → client notifications)
    // mcp-remote opens this with GET to receive server-initiated messages.
    if (pathname === '/mcp' && req.method === 'GET') {
      const encoder = new TextEncoder();
      const stream = new ReadableStream({
        start(controller) {
          controller.enqueue(encoder.encode(': connected\n\n'));
          const interval = setInterval(() => {
            try {
              controller.enqueue(encoder.encode(': keepalive\n\n'));
            } catch {
              clearInterval(interval);
            }
          }, 30_000);
        },
      });
      return new Response(stream, {
        headers: {
          'Content-Type': 'text/event-stream',
          'Cache-Control': 'no-cache',
          'Connection': 'keep-alive',
        },
      });
    }

    // MCP endpoint
    if (pathname === '/mcp' && req.method === 'POST') {
      try {
        const body = await req.text();

        let parsed: Record<string, unknown> = {};
        try { parsed = JSON.parse(body); } catch { /* invalid json, treat as request */ }

        // JSON-RPC notifications have no id — gbrain won't send a response
        if (parsed.id === undefined || parsed.id === null) {
          gbrainProc.stdin.write(body + '\n');
          return new Response(null, { status: 202 });
        }

        const response = await callGbrain(body);
        return new Response(response, {
          headers: { 'Content-Type': 'application/json' },
        });
      } catch (err) {
        console.error('[gateway] MCP error:', err);
        return Response.json({ error: 'service_unavailable', message: String(err) }, { status: 503 });
      }
    }

    return new Response('Not Found', { status: 404 });
  },
});

console.log(`[gateway] HTTP MCP gateway listening on :${PORT}`);
console.log(`[gateway] MCP endpoint: http://0.0.0.0:${PORT}/mcp`);
