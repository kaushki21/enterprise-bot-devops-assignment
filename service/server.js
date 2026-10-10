const http = require('http');
const os = require('os');
const fs = require('fs');

const PORT = parseInt(process.env.PORT || '8080', 10);
const HOST = '0.0.0.0';

/**
 * Resolve configuration value dynamically:
 * Prioritize live-mounted ConfigMap files if present,
 * otherwise fall back to environment variable or default.
 */
function getConfig(key, fallback = '') {
  const mountPaths = [
    `/etc/config/${key}`,
    `/etc/config/${key.toLowerCase()}`
  ];

  for (const p of mountPaths) {
    try {
      if (fs.existsSync(p)) {
        const val = fs.readFileSync(p, 'utf8').trim();
        if (val) return val;
      }
    } catch (_) {
      // Ignore read errors and fall back to environment variable
    }
  }

  return process.env[key] || fallback;
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);

  if (req.method === 'GET' && url.pathname === '/') {
    const payload = {
      app: getConfig('APP_NAME', 'demo-app'),
      version: getConfig('VERSION', '1.0.0'),
      pod: os.hostname()
    };

    res.writeHead(200, {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'no-cache, no-store, must-revalidate'
    });
    res.end(JSON.stringify(payload));
    return;
  }

  if (req.method === 'GET' && url.pathname === '/healthz') {
    res.writeHead(200, {
      'Content-Type': 'application/json; charset=utf-8'
    });
    res.end(JSON.stringify({ status: 'ok' }));
    return;
  }

  res.writeHead(404, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify({ error: 'not found' }));
});

server.listen(PORT, HOST, () => {
  console.log(`demo-service listening on ${HOST}:${PORT} (pod: ${os.hostname()})`);
});

// Graceful shutdown handling
function shutdown(signal) {
  console.log(`Received ${signal}, shutting down gracefully...`);
  server.close(() => {
    console.log('HTTP server closed.');
    process.exit(0);
  });
  setTimeout(() => {
    console.error('Forceful shutdown timeout expired.');
    process.exit(1);
  }, 10000).unref();
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
