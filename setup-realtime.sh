#!/bin/bash
# ============================================================
# OpenClaw Realtime-Voice-Server – Setup-Script
# SDP-Proxy fuer OpenAI Realtime API (WebRTC)
# ============================================================
# Nutzung:
#   curl -sL https://tikitackr.github.io/OpenClaw-Website/setup-realtime.sh | bash
# Oder manuell:
#   bash setup-realtime.sh
# ============================================================

set -e

REALTIME_DIR="/opt/openclaw-realtime"
SERVICE_NAME="openclaw-realtime"
TOKEN_FILE="/opt/openclaw-sync/SYNC_TOKEN.txt"
REALTIME_PORT=3458

echo ""
echo "========================================="
echo "  OpenClaw Realtime-Voice-Server Setup"
echo "========================================="
echo ""

# --- Pruefen ob Sync-Server Token existiert ---
if [ -f "$TOKEN_FILE" ]; then
  SYNC_TOKEN=$(cat "$TOKEN_FILE")
  echo "✅ SYNC_TOKEN gefunden (aus Sync-Server)"
else
  echo "⚠️  Kein SYNC_TOKEN gefunden unter $TOKEN_FILE"
  echo "   Stelle sicher dass der Sync-Server zuerst installiert ist."
  if [ -z "$SYNC_TOKEN" ]; then
    echo "❌ Abbruch – SYNC_TOKEN nicht verfuegbar."
    exit 1
  fi
fi

# --- OpenAI API-Key pruefen ---
if [ -z "$OPENAI_API_KEY" ]; then
  # Versuche aus OpenClaw Docker-Container zu lesen
  OPENAI_API_KEY=$(docker exec $(docker ps -q --filter "name=openclaw") env 2>/dev/null | grep OPENAI_API_KEY | cut -d= -f2- || true)

  if [ -z "$OPENAI_API_KEY" ]; then
    echo ""
    echo "⚠️  OPENAI_API_KEY nicht gefunden."
    echo "   Bitte setze den Key vor dem Setup:"
    echo "   export OPENAI_API_KEY=sk-..."
    echo "   bash setup-realtime.sh"
    echo ""
    echo "❌ Abbruch – OPENAI_API_KEY nicht verfuegbar."
    exit 1
  fi
  echo "✅ OPENAI_API_KEY aus Docker-Container gelesen"
fi

# --- Pruefen ob Node.js installiert ist ---
if ! command -v node &> /dev/null; then
  echo "❌ Node.js nicht gefunden. Bitte zuerst installieren."
  exit 1
fi
echo "✅ Node.js $(node -v)"

# --- Update-Modus erkennen ---
if [ -d "$REALTIME_DIR" ] && [ -f "$REALTIME_DIR/server.js" ]; then
  echo ""
  echo "🔄 Bestehende Installation erkannt – Update-Modus"
  UPDATE_MODE=true
else
  echo ""
  echo "📦 Neue Installation"
  UPDATE_MODE=false
fi

# --- Ordner erstellen ---
mkdir -p "$REALTIME_DIR"

# --- server.js schreiben ---
cat > "$REALTIME_DIR/server.js" << 'SERVEREOF'
// ============================================================
// OpenClaw Realtime-Voice-Server
// SDP-Proxy fuer OpenAI Realtime API (WebRTC)
// ============================================================
const express = require('express');

const PORT = process.env.REALTIME_PORT || 3458;
const SYNC_TOKEN = process.env.SYNC_TOKEN;
const OPENAI_API_KEY = process.env.OPENAI_API_KEY;

if (!SYNC_TOKEN) { console.error('FEHLER: SYNC_TOKEN nicht gesetzt!'); process.exit(1); }
if (!OPENAI_API_KEY) { console.error('FEHLER: OPENAI_API_KEY nicht gesetzt!'); process.exit(1); }

const app = express();

// CORS
app.use((req, res, next) => {
  const allowedOrigins = ['https://tikitackr.github.io', 'http://localhost:3000', 'http://localhost:5173'];
  const origin = req.headers.origin;
  if (allowedOrigins.includes(origin)) res.setHeader('Access-Control-Allow-Origin', origin);
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  res.setHeader('Access-Control-Max-Age', '86400');
  if (req.method === 'OPTIONS') return res.sendStatus(204);
  next();
});

app.use(express.text({ type: ['application/sdp', 'text/plain'], limit: '50kb' }));
app.use(express.json({ limit: '50kb' }));

function requireAuth(req, res, next) {
  const auth = req.headers.authorization;
  if (!auth || auth !== `Bearer ${SYNC_TOKEN}`) return res.status(401).json({ error: 'Unauthorized' });
  next();
}

// Session-Config
const SESSION_CONFIG = JSON.stringify({
  type: 'realtime',
  model: 'gpt-realtime-mini',
  voice: 'marin',
  instructions: 'Du bist Cowan, ein freundlicher und kompetenter Buch-Begleiter fuer das OpenClaw-Sachbuch. Du sprichst Deutsch, antwortest in 1-2 kurzen Saetzen, stellst Rueckfragen wenn etwas unklar ist, und hilfst dem Leser beim Verstehen von KI-Agenten, OpenClaw-Setup und Programmierung. Kein Markdown, keine Listen, keine Emojis – du sprichst natuerlich wie in einem echten Gespraech.',
  input_audio_transcription: { model: 'whisper-1' },
  turn_detection: { type: 'server_vad', threshold: 0.5, prefix_padding_ms: 300, silence_duration_ms: 600 }
});

app.get('/health', (req, res) => {
  res.json({ status: 'ok', service: 'openclaw-realtime', version: '1.0.0', model: 'gpt-realtime-mini', timestamp: new Date().toISOString() });
});

app.post('/session', requireAuth, async (req, res) => {
  const sdpOffer = typeof req.body === 'string' ? req.body : null;
  if (!sdpOffer || !sdpOffer.includes('v=0')) {
    return res.status(400).json({ error: 'SDP-Offer erwartet (text/plain oder application/sdp)' });
  }

  try {
    const boundary = '----OpenClawBoundary' + Date.now();
    const body =
      `--${boundary}\r\n` +
      `Content-Disposition: form-data; name="session"\r\n` +
      `Content-Type: application/json\r\n\r\n` +
      `${SESSION_CONFIG}\r\n` +
      `--${boundary}\r\n` +
      `Content-Disposition: form-data; name="sdp"\r\n` +
      `Content-Type: application/sdp\r\n\r\n` +
      `${sdpOffer}\r\n` +
      `--${boundary}--\r\n`;

    console.log(`[Realtime] SDP-Offer empfangen (${sdpOffer.length} bytes)`);

    const response = await fetch('https://api.openai.com/v1/realtime/calls', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${OPENAI_API_KEY}`,
        'Content-Type': `multipart/form-data; boundary=${boundary}`
      },
      body: body
    });

    if (!response.ok) {
      const errorText = await response.text();
      console.error(`[Realtime] OpenAI Fehler ${response.status}:`, errorText);
      return res.status(response.status).json({ error: 'OpenAI Realtime API Fehler', status: response.status, details: errorText });
    }

    const sdpAnswer = await response.text();
    console.log(`[Realtime] SDP-Answer erhalten (${sdpAnswer.length} bytes)`);
    res.setHeader('Content-Type', 'application/sdp');
    res.send(sdpAnswer);
  } catch (err) {
    console.error('[Realtime] Fehler:', err.message);
    res.status(500).json({ error: 'Verbindung zu OpenAI fehlgeschlagen', details: err.message });
  }
});

app.use((req, res) => {
  res.status(404).json({ error: 'Nicht gefunden. Endpunkte: /health, POST /session' });
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`\n  OpenClaw Realtime-Voice-Server laeuft auf Port ${PORT}`);
  console.log(`  Modell: gpt-realtime-mini`);
  console.log(`  Health: http://localhost:${PORT}/health`);
  console.log(`  Token:  ${SYNC_TOKEN.slice(0, 4)}...${SYNC_TOKEN.slice(-4)}`);
  console.log(`  OpenAI: ${OPENAI_API_KEY.slice(0, 7)}...${OPENAI_API_KEY.slice(-4)}\n`);
});
SERVEREOF

# --- package.json schreiben ---
cat > "$REALTIME_DIR/package.json" << 'PKGEOF'
{
  "name": "openclaw-realtime",
  "version": "1.0.0",
  "description": "SDP-Proxy fuer OpenAI Realtime API (WebRTC)",
  "main": "server.js",
  "scripts": { "start": "node server.js" },
  "dependencies": {
    "express": "^4.18.2"
  }
}
PKGEOF

# --- npm install ---
echo ""
echo "📦 Installiere Abhaengigkeiten..."
cd "$REALTIME_DIR"
npm install --production 2>&1 | tail -3

# --- OpenAI Key speichern ---
echo "$OPENAI_API_KEY" > "$REALTIME_DIR/OPENAI_KEY.txt"
chmod 600 "$REALTIME_DIR/OPENAI_KEY.txt"
echo "✅ OpenAI-Key gespeichert (chmod 600)"

# --- systemd Service ---
cat > /etc/systemd/system/${SERVICE_NAME}.service << SVCEOF
[Unit]
Description=OpenClaw Realtime-Voice-Server (SDP-Proxy)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${REALTIME_DIR}
Environment=SYNC_TOKEN=$(cat "$TOKEN_FILE" 2>/dev/null || echo "$SYNC_TOKEN")
Environment=OPENAI_API_KEY=$(cat "$REALTIME_DIR/OPENAI_KEY.txt" 2>/dev/null || echo "$OPENAI_API_KEY")
Environment=REALTIME_PORT=${REALTIME_PORT}
ExecStart=/usr/bin/node server.js
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF

# --- Service starten ---
systemctl daemon-reload
systemctl enable ${SERVICE_NAME}

if [ "$UPDATE_MODE" = true ]; then
  systemctl restart ${SERVICE_NAME}
  echo ""
  echo "🔄 Realtime-Server aktualisiert + neu gestartet"
else
  systemctl start ${SERVICE_NAME}
  echo ""
  echo "✅ Realtime-Server installiert + gestartet"
fi

# --- Tailscale Serve konfigurieren (Port 8445) ---
echo ""
echo "🌐 Konfiguriere Tailscale Serve auf Port 8445..."
sudo tailscale serve --bg --https 8445 http://localhost:${REALTIME_PORT} 2>/dev/null || {
  echo "⚠️  Tailscale Serve konnte nicht konfiguriert werden."
  echo "   Manuell: sudo tailscale serve --bg --https 8445 http://localhost:${REALTIME_PORT}"
}

# --- Status ---
sleep 2
echo ""
echo "========================================="
echo "  ✅ Realtime-Voice-Server Setup komplett!"
echo "========================================="
echo ""
echo "  Port:     ${REALTIME_PORT} (lokal)"
echo "  HTTPS:    https://$(tailscale status --json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['Self']['DNSName'].rstrip('.'))" 2>/dev/null || echo 'DEIN-TAILSCALE-HOSTNAME'):8445"
echo "  Token:    Gleicher wie Sync-Server"
echo "  Modell:   gpt-realtime-mini"
echo ""
echo "  Health:   curl https://HOSTNAME:8445/health"
echo ""
