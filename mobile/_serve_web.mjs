import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, 'build', 'web');
const host = '0.0.0.0';
const port = Number(process.env.WEB_PORT || 8080);

const mime = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.wasm': 'application/wasm',
  '.ttf': 'font/ttf',
  '.otf': 'font/otf',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.map': 'application/json',
  '.txt': 'text/plain; charset=utf-8',
};

function safeJoin(base, reqPath) {
  const decoded = decodeURIComponent((reqPath || '/').split('?')[0]);
  const cleaned = path.normalize(decoded).replace(/^(\.\.[/\\])+/, '');
  const full = path.join(base, cleaned);
  if (!full.startsWith(base)) return null;
  return full;
}

const commonHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET,HEAD,OPTIONS',
  'Cross-Origin-Resource-Policy': 'cross-origin',
};

const server = http.createServer((req, res) => {
  const peer = req.socket.remoteAddress || '?';
  console.log(`[${new Date().toISOString()}] ${peer} ${req.method} ${req.url}`);

  if (req.method === 'OPTIONS') {
    res.writeHead(204, commonHeaders);
    res.end();
    return;
  }

  // 简易连通性探测（不依赖 Flutter）
  if (req.url === '/health' || req.url === '/ping') {
    res.writeHead(200, {
      ...commonHeaders,
      'Content-Type': 'application/json; charset=utf-8',
    });
    res.end(JSON.stringify({ ok: true, service: 'codeassist-web', port }));
    return;
  }

  let filePath = safeJoin(root, req.url === '/' ? '/index.html' : req.url);
  if (!filePath) {
    res.writeHead(403, commonHeaders);
    res.end('Forbidden');
    return;
  }

  fs.stat(filePath, (err, st) => {
    if (!err && st.isDirectory()) {
      filePath = path.join(filePath, 'index.html');
    }

    fs.readFile(filePath, (readErr, data) => {
      if (readErr) {
        // SPA fallback
        const index = path.join(root, 'index.html');
        fs.readFile(index, (indexErr, indexData) => {
          if (indexErr) {
            res.writeHead(404, commonHeaders);
            res.end('Not Found');
            return;
          }
          res.writeHead(200, {
            ...commonHeaders,
            'Content-Type': 'text/html; charset=utf-8',
          });
          res.end(indexData);
        });
        return;
      }
      const ext = path.extname(filePath).toLowerCase();
      res.writeHead(200, {
        ...commonHeaders,
        'Content-Type': mime[ext] || 'application/octet-stream',
        'Cache-Control': ext === '.html' ? 'no-cache' : 'public, max-age=3600',
      });
      res.end(data);
    });
  });
});

server.listen(port, host, () => {
  console.log(`CodeAssist Web listening on http://${host}:${port}`);
  console.log(`LAN URL example: http://192.168.1.5:${port}`);
});
