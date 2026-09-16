import { defineConfig, type Plugin, type ViteDevServer } from 'vite';
import react from '@vitejs/plugin-react';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

// Build-Zeit-Version aus der eigenen package.json. Wird als globales
// __APP_VERSION__ ins Bundle injiziert, damit der Versions-Balken die
// *tatsächlich gebaute* Frontend-Version zeigt (wahrheitsgetreu zum laufenden
// Build, nicht nur die im Manifest gespiegelte Repo-Version). Ermöglicht später
// eine Drift-Anzeige „Bundle ≠ Manifest = Frontend nicht neu gebaut".
// Repo-Root (zwei Ebenen über apps/web) — Anker für die Watch-Excludes der
// GB-Datenverzeichnisse, damit gleichnamige Quellordner (z. B. src/docs/) NICHT
// mit ausgeschlossen werden.
const repoRoot = fileURLToPath(new URL('../../', import.meta.url));

const pkg = JSON.parse(
  readFileSync(fileURLToPath(new URL('./package.json', import.meta.url)), 'utf-8'),
);

/**
 * Raises the dev server's HTTP keep-alive window past the browser's socket
 * reuse time. Node's 5 s default closes pooled connections while the browser
 * still holds them as usable — an SPA navigation firing several requests onto
 * that pool then fails at transport level ("Load failed" / "Failed to fetch"),
 * while a full page reload always works because it opens fresh sockets.
 * Mirrors the same setting on the REST API (rest-api/src/index.js).
 * headersTimeout must stay above keepAliveTimeout.
 */
const keepAlivePlugin = (): Plugin => ({
  name: 'fmlab-keep-alive',
  configureServer(server: ViteDevServer) {
    // No own HTTP server in middleware mode; the `in` check also narrows the
    // http.Server | Http2SecureServer union (HTTP/2 has no such knobs).
    const http = server.httpServer;
    if (!http || !('keepAliveTimeout' in http)) return;
    http.keepAliveTimeout = 65000;
    http.headersTimeout = 66000;
  },
});

export default defineConfig({
  plugins: [react(), keepAlivePlugin()],
  define: {
    __APP_VERSION__: JSON.stringify(pkg.version),
  },
  server: {
    // Bind-Adresse aus der Umgebung: Host-sicherer Default (false → localhost),
    // im Dev-Container injiziert devcontainer.json VITE_DEV_HOST=0.0.0.0, damit
    // der Dev-Server vom Host erreichbar ist (Port-Forwarding). Keine Umstellung
    // beim Wechsel Host <-> Container nötig.
    host: process.env.VITE_DEV_HOST || false,
    port: 5173,
    strictPort: true,
    // FS-Watcher entlasten (Docker-Desktop-Stabilität auf macOS, s. .vscode/
    // settings.json). Vite-Root ist apps/web, daher sieht der Dev-Server die
    // GB-Datenverzeichnisse im Repo-Root normalerweise gar nicht — diese Liste
    // ist defensiv (deckt dist/.vite + den Fall „Vite vom Repo-Root gestartet").
    // Die Datenverzeichnisse sind ABSOLUT auf den Repo-Root verankert: ein
    // nacktes `**/docs/**` schloss auch `src/docs/` aus — Änderungen an der
    // DocsEntryView wurden dann nie invalidiert (Vite servierte den alten
    // Transform bis zum Neustart).
    watch: {
      ignored: [
        '**/node_modules/**',
        '**/.git/**',
        '**/dist/**',
        '**/.vite/**',
        '**/*.duckdb',
        ...['db', 'output', 'logs', '.fmlab', 'xml', 'docs', '_Backup'].map(
          (dir) => `${repoRoot}${dir}/**`,
        ),
      ],
    },
    // open nur lokal auf dem Host sinnvoll; im Container (kein Browser) leise aus.
    // VS Code öffnet das Frontend dort via Port-Forwarding/openBrowser.
    open: !process.env.VITE_DEV_HOST,
    // Same-origin-Proxy: Das Frontend ruft die API über den relativen Pfad
    // `/api` auf (VITE_API_URL leer). Der Dev-Server leitet diese Requests
    // serverseitig an die REST-API auf localhost:3003 weiter — unabhängig
    // davon, auf welchen Host-Port der Dev-Container 3003 weiterleitet
    // (z. B. 3004 bei Port-Kollision). Der Browser muss 3003 nie kennen.
    //
    // Ziel per VITE_API_PROXY_TARGET übersteuerbar: Default localhost:3003 gilt,
    // wenn API + Dev-Server im selben Prozess/Container laufen (native, start-
    // servers.sh, Dev-Container). Laufen sie als GETRENNTE Container (Compose-
    // Multi-Service), zeigt die Var auf den Service-DNS-Namen, z. B. http://api:3003.
    proxy: {
      '/api': {
        target: process.env.VITE_API_PROXY_TARGET || 'http://localhost:3003',
        changeOrigin: true,
        configure(proxy) {
          // http-proxy erzwingt ohne agent-Option Connection: close auf Hop 2
          // (Vite→API) und kopiert den Header der API-Antwort zum Browser
          // zurück — das tötet das Pooling auf Hop 1 (Browser→Vite) für jeden
          // /api-Request. Der Header gehört Hop 1 nicht; ohne ihn gilt Vites
          // Keep-Alive-Fenster (65 s, Plugin fmlab-keep-alive). Hop 2 bleibt
          // bewusst Connection: close (container-intern, erwiesenermaßen
          // stabil — ein keepAlive-Agent würde sich den Node-Client-Race auf
          // wiederverwendeten Sockets einhandeln, ECONNRESET → 502).
          proxy.on('proxyRes', proxyRes => {
            delete proxyRes.headers.connection;
          });
        }
      }
    }
  }
});
