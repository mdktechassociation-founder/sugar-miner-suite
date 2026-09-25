/**
 * SugarBridge — WebSocket ⇄ TCP Stratum bridge for Sugarchain (Cloudflare Worker)
 *
 * Fixes over the original:
 *   1. Origin allow-list — stops strangers using your Worker as a free open relay.
 *   2. Binary frames: `writer.write(ArrayBuffer)` is a TypeError in Workers (the
 *      WritableStream only takes Uint8Array or views) — now wrapped.
 *   3. Real connect errors: `connect()` fails *asynchronously*, so the original
 *      try/catch around it never fired; we await `socket.opened` instead and close
 *      the WebSocket with 1011 + a reason the client can show.
 *   4. Errors are logged instead of silently swallowed; the close code tells the
 *      truth (1000 for a clean pool close, 1011 for failure).
 *   5. Configurable via env vars; no hard-coded pool.
 *
 * Deploy:  wrangler deploy
 * Vars:    POOL_HOST=stratum.poolab.org  POOL_PORT=8451  ALLOWED_ORIGINS=*
 */

import { connect } from 'cloudflare:sockets';

const DEFAULT_HOST = 'stratum.poolab.org';
const DEFAULT_PORT = 8451;

// A Stratum line is tiny; anything larger is junk or an attack.
const MAX_LINE_BYTES = 64 * 1024;

export default {
  async fetch(request, env) {
    const upgrade = request.headers.get('Upgrade');
    if (!upgrade || upgrade.toLowerCase() !== 'websocket') {
      return new Response('Expected WebSocket upgrade', { status: 426 });
    }

    // ---- 1. only let your own page(s) use this bridge -------------------------
    const origin = request.headers.get('Origin') || '';
    const allow = (env.ALLOWED_ORIGINS || '*').split(',').map(s => s.trim()).filter(Boolean);
    if (!allow.includes('*') && !allow.includes(origin)) {
      return new Response('Forbidden origin', { status: 403 });
    }

    const POOL_HOST = env.POOL_HOST || DEFAULT_HOST;
    const POOL_PORT = Number(env.POOL_PORT || DEFAULT_PORT);

    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    server.accept();

    // ---- 3. connect and find out whether it actually worked -------------------
    let tcp;
    try {
      tcp = connect({ hostname: POOL_HOST, port: POOL_PORT });
      await tcp.opened;                       // <-- the original code skipped this
    } catch (err) {
      console.error(`connect ${POOL_HOST}:${POOL_PORT} failed:`, err && err.message);
      try { server.close(1011, `Cannot reach ${POOL_HOST}:${POOL_PORT}`); } catch {}
      return new Response(null, { status: 101, webSocket: client });
    }

    const writer = tcp.writable.getWriter();
    const encoder = new TextEncoder();
    const decoder = new TextDecoder();
    let closed = false;

    const shutdown = async (code, reason) => {
      if (closed) return;
      closed = true;
      try { server.close(code, reason); } catch {}
      try { await tcp.close(); } catch {}
    };

    // ---- client → pool --------------------------------------------------------
    server.addEventListener('message', async (event) => {
      try {
        const data = event.data;
        const bytes = typeof data === 'string'
          ? encoder.encode(data.endsWith('\n') ? data : data + '\n')
          : new Uint8Array(data);               // <-- 2. ArrayBuffer → Uint8Array view
        await writer.write(bytes);
      } catch (err) {
        console.error('write to pool failed:', err && err.message);
        shutdown(1011, 'TCP write error');
      }
    });

    // ---- pool → client --------------------------------------------------------
    (async () => {
      const reader = tcp.readable.getReader();
      let buffer = '';
      try {
        for (;;) {
          const { value, done } = await reader.read();
          if (done) break;
          buffer += decoder.decode(value, { stream: true });

          if (buffer.length > MAX_LINE_BYTES) throw new Error('runaway line from pool');

          const lines = buffer.split('\n');
          buffer = lines.pop();                 // keep the partial tail
          for (const line of lines) {
            if (line.trim()) server.send(line + '\n');
          }
        }
        if (buffer.trim()) server.send(buffer + '\n');   // don't drop a final unsplit line
        await shutdown(1000, 'Pool closed the connection');
      } catch (err) {
        console.error('read from pool failed:', err && err.message);
        await shutdown(1011, 'Pool read error');
      }
    })();

    server.addEventListener('close', () => { shutdown(1000, 'Client closed'); });
    server.addEventListener('error', () => { shutdown(1011, 'Socket error'); });

    return new Response(null, { status: 101, webSocket: client });
  },
};
