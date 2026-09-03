const express = require('express');
const net = require('net');
const environment = require('./config/environment');
const db = require('./config/database');
const routes = require('./routes');
const { errorHandler } = require('./middleware/error-handler');
const logger = require('./middleware/logger');
const corsMiddleware = require('./middleware/cors');
const createQueryParser = require('./middleware/query-normalizer');
const debugSessionMiddleware = require('./middleware/debug-session');

// Basic in-memory per-IP rate limiter. The API exposes 100+ endpoints
// (including expensive operations like POST /results/run and GET
// /results/aggregate) with no throttling — cap requests per client IP within
// a rolling window and respond 429 once exceeded.
const RATE_LIMIT_WINDOW_MS = parseInt(process.env.RATE_LIMIT_WINDOW_MS) || 60000; // 1 minute
const RATE_LIMIT_MAX = parseInt(process.env.RATE_LIMIT_MAX) || 300; // requests/window/IP
const rateLimitHits = new Map(); // ip -> { count, resetAt }
function rateLimitMiddleware(req, res, next) {
  const now = Date.now();
  let entry = rateLimitHits.get(req.ip);
  if (!entry || now > entry.resetAt) {
    entry = { count: 0, resetAt: now + RATE_LIMIT_WINDOW_MS };
    rateLimitHits.set(req.ip, entry);
  }
  entry.count += 1;
  if (entry.count > RATE_LIMIT_MAX) {
    res.setHeader('Retry-After', Math.ceil((entry.resetAt - now) / 1000));
    return res.status(429).json({
      success: false,
      error: { code: 'RATE_LIMIT_EXCEEDED', message: 'Too many requests, please try again later.' },
    });
  }
  next();
}
setInterval(() => {
  const now = Date.now();
  for (const [key, entry] of rateLimitHits) {
    if (now > entry.resetAt) rateLimitHits.delete(key);
  }
}, RATE_LIMIT_WINDOW_MS).unref();

/**
 * FM-Lab REST API
 * Express application setup
 */

const app = express();

// Query parser: parameter names are case-insensitive in BOTH directions —
// lowercase own keys, case-insensitive reads on top (→ query-normalizer.js).
app.set('query parser', createQueryParser());

// Middleware
app.use(corsMiddleware);
app.use(logger);
app.use(rateLimitMiddleware);
app.use(express.json());
app.use(express.urlencoded({ extended: true }));

// Debug-Session: hängt req.debug an + loggt Request-Lifecycle in die korrelierte
// Zeitachse (nur aktiv bei DEBUG_SESSION=1 oder X-Debug-Session-Header). Nach
// dem Body-Parser, damit die Ingestion-Route den Body schon hat.
app.use(debugSessionMiddleware);

// Solution-Kontext (Ausbaustufe M, scharf): der X-Solution-Header wählt die
// Lösung dieses Requests (Per-Tab-Auswahl des Frontends); ohne Header greift
// der Server-Default. Unbekannte/ungültige IDs → 404 VOR jeder Route — das
// Frontend setzt seine Auswahl dann zurück (veralteter localStorage nach
// Löschen/Umbenennen einer Lösung).
app.use((req, res, next) => {
  try {
    req.solutionContext = require('./config/solutions').getRequestContext(req);
    next();
  } catch (err) {
    if (err.code === 'SOLUTION_NOT_FOUND') {
      return res.status(404).json({
        success: false,
        error: { code: 'SOLUTION_NOT_FOUND', message: err.message },
      });
    }
    next(err);
  }
});

// API Routes
app.use('/api', routes);

// Lite web client (optional module): server-rendered HTML surface under /lite.
// The liteweb/ directory may be absent in installations that ship only the
// API — then /lite simply stays 404 and the server runs unchanged.
let liteMounted = false;
{
  const fs = require('fs');
  const path = require('path');
  const litewebDir = path.join(__dirname, '..', 'liteweb');
  if (fs.existsSync(litewebDir)) {
    try {
      app.use('/lite', require(path.join(litewebDir, 'routes'))());
      liteMounted = true;
    } catch (err) {
      console.warn(`Lite web client not mounted: ${err.message}`);
    }
  }
}

// Root endpoint
app.get('/', (req, res) => {
  res.json({
    message: 'FM-Lab REST API',
    version: require('../package.json').version,
    ...(liteMounted ? { liteClient: '/lite' } : {}),
    endpoints: {
      version: '/api/version',
      versionManifest: '/api/version-manifest',
      info: '/api/info',
      get: '/api/get?uuid=<uuid>',
      getDetails: '/api/get-details?uuid=<uuid>',
      list: '/api/list?type=<type>',
      count: '/api/count',
      search: '/api/search?name=<pattern>',
      searchCount: '/api/search/count?name=<pattern>',
      references: '/api/references?uuid=<uuid>',
      query: '/api/query?template=<name>',
      report: '/api/report?template=<name>',
      pluginDocs: '/api/plugin-docs/:source/:function',
      referenceCategories: '/api/reference/categories?lang=<lang>',
      referenceSteps: '/api/reference/steps?lang=<lang>',
      referenceStepDetail: '/api/reference/steps/:idOrSlug?lang=<lang>&content=<meta|summary|full>',
      referenceFunctions: '/api/reference/functions?lang=<lang>',
      referenceFunctionDetail: '/api/reference/functions/:nameOrId?lang=<lang>&content=<meta|summary|full>',
      referenceLookup: '/api/reference/lookup?token=<token>&lang=<lang>',
      referenceHelp: '/api/reference/help/:lang/:slug',
      referenceHelpStatus: '/api/reference/help/status',
      adminReload: 'POST /api/admin/reload',
    },
    documentation: 'See README.md for full API documentation',
  });
});

// 404 handler
app.use((req, res) => {
  res.status(404).json({
    success: false,
    error: {
      code: 'NOT_FOUND',
      message: `Route ${req.method} ${req.path} not found`,
    },
  });
});

// Error handler (must be last)
app.use(errorHandler);

/**
 * Print the "port already taken" banner. Shared by the pre-flight probe and the
 * server 'error' backstop so a double-start reads identically from either path.
 */
function printPortBusy() {
  console.error('');
  console.error('========================================');
  console.error(`✗ Port ${environment.port} is already in use.`);
  console.error('  Another FM-Lab API (or a foreign process) is bound there — NOT starting a second one.');
  console.error('  Stop the running server first:  tools/stop-servers.sh api');
  console.error('  Or, in the Docker Compose topology, from the HOST:  docker compose restart api');
  console.error('========================================');
}

/**
 * Pre-flight: is something already listening on our port? Resolves true if a TCP
 * connect succeeds within 1s. Binding 0.0.0.0 while a stale process holds the port
 * makes Node fire 'listening' (success banner!) AND then 'error' (EADDRINUSE) — so we
 * probe FIRST and never print the banner on a doomed start. 0.0.0.0/:: aren't valid
 * connect targets, so we probe loopback (which the wildcard bind covers).
 */
function portInUse() {
  const host =
    environment.host === '0.0.0.0' || environment.host === '::' || !environment.host
      ? '127.0.0.1'
      : environment.host;
  return new Promise((resolve) => {
    const socket = net.createConnection({ host, port: environment.port });
    const done = (result) => {
      socket.destroy();
      resolve(result);
    };
    socket.setTimeout(1000);
    socket.once('connect', () => done(true));
    socket.once('timeout', () => done(false));
    socket.once('error', () => done(false));
  });
}

/**
 * Start server
 */
async function start() {
  try {
    // Fail fast on a double-start BEFORE opening the DB or printing the ready banner
    // (L2 in the server-restart ticket): a stale process on the port would otherwise
    // keep serving old code while a "successful"-looking boot scrolls past.
    if (await portInUse()) {
      printPortBusy();
      process.exit(1);
    }

    // Invariante I1: 'default' existiert immer — Bundle-Skelett
    // + Minimal-Manifest still herstellen, bevor Pfade aufgelöst werden.
    require('./config/solutions').ensureDefaultSolution();

    // Workspace-Symlinks (db/fm_catalog.duckdb → aktive Lösung) idempotent
    // projizieren — so entsteht der in CLAUDE.md §2 dokumentierte CLI-Lesepfad
    // ab dem ersten API-Start, auch für Ein-Lösungs-Installationen, die nie
    // umschalten (ein REALES File am Linkort bleibt bewusst unberührt).
    require('./config/solutions').ensureWorkspaceSymlinks();

    // Initialize database connection
    console.log('Initializing database connection...');
    await db.initialize();

    // Initialize the writable annotations sidecar (Noise-Filter & semantic
    // enrichment). Guarded: if it can't be opened, the feature stays off and the
    // rest of the API runs unchanged.
    await require('./config/annotations-db').initialize();

    // Load `marked` (ESM-only) before serving any request. Done here — not via a
    // top-level require in docs-content.js — because require(ESM) throws
    // ERR_REQUIRE_ESM on Node 20 (the project's supported floor). Awaiting it here
    // guarantees the synchronous docs render helpers have marked ready.
    await require('./services/docs-content').initMarked();

    // Load the last persisted fmIDE scan into memory (no DB query). The scan
    // itself runs on plugin activation and on explicit Rescan, not every boot.
    try {
      require('./plugins/fmide/fmide.service').loadPersistedStatuses();
    } catch (err) {
      console.warn(`fmIDE status load skipped: ${err.message}`);
    }

    // Start HTTP server. The success banner lives INSIDE the listen callback, so it
    // only prints once the port is actually bound — never on a failed bind.
    const server = app.listen(environment.port, environment.host, () => {
      console.log('');
      console.log('========================================');
      console.log('FM-Lab REST API');
      console.log('========================================');
      console.log(`Environment: ${environment.nodeEnv}`);
      console.log(`Server: http://${environment.host}:${environment.port}`);
      console.log(`API Endpoints: http://${environment.host}:${environment.port}/api`);
      console.log('========================================');
      console.log('');
      console.log('Available endpoints:');
      console.log(`  GET  /api/version        - API version and health`);
      console.log(`  GET  /api/version-manifest - Module version manifest`);
      console.log(`  GET  /api/info           - Solution information`);
      console.log(`  GET  /api/get            - Get object by UUID`);
      console.log(`  GET  /api/get-details    - Type-specific object details`);
      console.log(`  GET  /api/list           - List objects by type`);
      console.log(`  GET  /api/count          - Count objects`);
      console.log(`  GET  /api/search         - Search objects by name`);
      console.log(`  GET  /api/search/count   - Count search results`);
      console.log(`  GET  /api/references     - Get object references`);
      console.log(`  GET  /api/query          - Execute custom SQL template`);
      console.log(`  GET  /api/report         - Execute report SQL template`);
      console.log(`  GET  /api/plugin-docs    - Plugin function documentation (MBS, ...)`);
      console.log(`  GET  /api/reference/*    - FileMaker Reference (Steps, Functions, Help)`);
      console.log('');
      console.log('========================================');
      console.log(`✅ FM-Lab ready → open the web client at http://localhost:5173`);
      console.log(`   (REST-API: http://${environment.host}:${environment.port}/api)`);
      console.log('========================================');
      console.log('');
    });

    // Keep-alive window. Node closes idle pooled connections after 5 s by
    // default, while clients that reuse sockets — browsers and the Vite dev
    // proxy (http.globalAgent has keepAlive:true since Node 19) — consider
    // them usable much longer. A request written onto a socket the server is
    // closing in the same instant fails at transport level: no status code, no
    // access-log entry, just a rejected fetch in the browser. Widening the
    // window past any client's idle time removes the race.
    // headersTimeout MUST stay above keepAliveTimeout, otherwise the header
    // deadline fires while the connection is still legitimately idle.
    server.keepAliveTimeout = environment.api.keepAliveTimeout;
    server.headersTimeout = environment.api.keepAliveTimeout + 1000;

    // Fail-fast on a bad bind. Without this handler an EADDRINUSE surfaces as an
    // unhandled 'error' event; worse, a background start could look like it "succeeded"
    // while a stale process keeps serving the old code on the same port. Print a clear
    // message and exit non-zero so a double-start is unmistakable (never a silent exit 0).
    server.on('error', (err) => {
      if (err.code === 'EADDRINUSE') {
        printPortBusy();
      } else {
        console.error('HTTP server error:', err);
      }
      process.exit(1);
    });

    // Graceful shutdown
    process.on('SIGTERM', () => {
      console.log('SIGTERM signal received: closing HTTP server');
      server.close(async () => {
        console.log('HTTP server closed');
        await db.close();
        process.exit(0);
      });
    });

    process.on('SIGINT', () => {
      console.log('\nSIGINT signal received: closing HTTP server');
      server.close(async () => {
        console.log('HTTP server closed');
        await db.close();
        process.exit(0);
      });
    });
  } catch (error) {
    console.error('Failed to start server:', error);
    process.exit(1);
  }
}

// Start if not in test mode
if (require.main === module) {
  start();
}

module.exports = app;
