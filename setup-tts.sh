#!/bin/bash
# ============================================================
# OpenClaw TTS-Server – Setup-Script
# Installiert Edge TTS Server auf dem VPS (neben dem Sync-Server)
# ============================================================
# Nutzung:
#   curl -sL https://tikitackr.github.io/OpenClaw-Website/setup-tts.sh | bash
# Oder manuell:
#   bash setup-tts.sh
# ============================================================

set -e

TTS_DIR="/opt/openclaw-tts"
SERVICE_NAME="openclaw-tts"
TOKEN_FILE="/opt/openclaw-sync/SYNC_TOKEN.txt"
TTS_PORT=3457

echo ""
echo "========================================="
echo "  OpenClaw TTS-Server Setup"
echo "========================================="
echo ""

# --- Pruefen ob Sync-Server Token existiert ---
if [ -f "$TOKEN_FILE" ]; then
  SYNC_TOKEN=$(cat "$TOKEN_FILE")
  echo "✅ SYNC_TOKEN gefunden (aus Sync-Server)"
else
  echo "⚠️  Kein SYNC_TOKEN gefunden unter $TOKEN_FILE"
  echo "   Stelle sicher dass der Sync-Server zuerst installiert ist."
  echo "   Oder setze SYNC_TOKEN manuell:"
  echo "   export SYNC_TOKEN=dein-token"
  echo ""
  if [ -z "$SYNC_TOKEN" ]; then
    echo "❌ Abbruch – SYNC_TOKEN nicht verfuegbar."
    exit 1
  fi
fi

# --- Pruefen ob Node.js installiert ist ---
if ! command -v node &> /dev/null; then
  echo "❌ Node.js nicht gefunden. Bitte zuerst installieren."
  exit 1
fi
echo "✅ Node.js $(node -v)"

# --- Update-Modus erkennen ---
if [ -d "$TTS_DIR" ] && [ -f "$TTS_DIR/server.js" ]; then
  echo ""
  echo "🔄 Bestehende Installation erkannt – Update-Modus"
  echo "   Token bleibt erhalten, nur server.js wird ersetzt."
  UPDATE_MODE=true
else
  echo ""
  echo "📦 Neue Installation"
  UPDATE_MODE=false
fi

# --- Ordner erstellen ---
mkdir -p "$TTS_DIR"

# --- server.js schreiben ---
cat > "$TTS_DIR/server.js" << 'SERVEREOF'
// ============================================================
// OpenClaw TTS-Server
// Edge TTS (Microsoft Neural Voices) fuer Cowan Sprachausgabe
// ============================================================
const express = require('express');
const { EdgeTTS } = require('node-edge-tts');
const path = require('path');
const fs = require('fs');
const os = require('os');
const crypto = require('crypto');

const PORT = process.env.TTS_PORT || 3457;
const SYNC_TOKEN = process.env.SYNC_TOKEN;
const DEFAULT_VOICE = process.env.TTS_VOICE || 'de-DE-KatjaNeural';
const DEFAULT_FORMAT = 'audio-24khz-96kbitrate-mono-mp3';

if (!SYNC_TOKEN) {
  console.error('FEHLER: SYNC_TOKEN nicht gesetzt!');
  process.exit(1);
}

const TEMP_DIR = path.join(os.tmpdir(), 'openclaw-tts');
if (!fs.existsSync(TEMP_DIR)) {
  fs.mkdirSync(TEMP_DIR, { recursive: true });
}

const app = express();

app.use((req, res, next) => {
  const allowedOrigins = [
    'https://tikitackr.github.io',
    'http://localhost:3000',
    'http://localhost:5173'
  ];
  const origin = req.headers.origin;
  if (allowedOrigins.includes(origin)) {
    res.setHeader('Access-Control-Allow-Origin', origin);
  }
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  res.setHeader('Access-Control-Max-Age', '86400');
  if (req.method === 'OPTIONS') return res.sendStatus(204);
  next();
});

app.use(express.json({ limit: '100kb' }));

function requireAuth(req, res, next) {
  const auth = req.headers.authorization;
  if (!auth || auth !== `Bearer ${SYNC_TOKEN}`) {
    return res.status(401).json({ error: 'Unauthorized' });
  }
  next();
}

const VOICES = {
  'de-DE-KatjaNeural': { gender: 'weiblich', beschreibung: 'Standard – warm und natuerlich' },
  'de-DE-AmalaNeural': { gender: 'weiblich', beschreibung: 'Klar und freundlich' },
  'de-DE-ConradNeural': { gender: 'maennlich', beschreibung: 'Ruhig und sachlich' },
  'de-DE-KillianNeural': { gender: 'maennlich', beschreibung: 'Energisch und deutlich' }
};

app.get('/health', (req, res) => {
  res.json({ status: 'ok', service: 'openclaw-tts', version: '1.0.0', defaultVoice: DEFAULT_VOICE, timestamp: new Date().toISOString() });
});

app.get('/voices', (req, res) => {
  res.json({ voices: VOICES, default: DEFAULT_VOICE });
});

app.post('/speak', requireAuth, async (req, res) => {
  const { text, voice, rate, pitch } = req.body;

  if (!text || typeof text !== 'string' || text.trim().length === 0) {
    return res.status(400).json({ error: 'Feld "text" ist erforderlich' });
  }
  if (text.length > 5000) {
    return res.status(400).json({ error: 'Text zu lang (max 5000 Zeichen)' });
  }

  const selectedVoice = voice || DEFAULT_VOICE;
  if (voice && !VOICES[voice]) {
    return res.status(400).json({ error: `Unbekannte Stimme: "${voice}"`, verfuegbar: Object.keys(VOICES) });
  }

  const tempId = crypto.randomBytes(8).toString('hex');
  const tempFile = path.join(TEMP_DIR, `tts-${tempId}.mp3`);

  try {
    const tts = new EdgeTTS({
      voice: selectedVoice,
      lang: 'de-DE',
      outputFormat: DEFAULT_FORMAT,
      rate: rate || '+0%',
      pitch: pitch || '+0%',
      timeout: 15000
    });

    await tts.ttsPromise(text.trim(), tempFile);

    const stat = fs.statSync(tempFile);
    console.log(`TTS: "${text.trim().slice(0, 50)}..." → ${selectedVoice} (${stat.size} bytes)`);

    res.setHeader('Content-Type', 'audio/mpeg');
    res.setHeader('Content-Length', stat.size);
    res.setHeader('X-TTS-Voice', selectedVoice);

    const stream = fs.createReadStream(tempFile);
    stream.pipe(res);
    stream.on('end', () => { fs.unlink(tempFile, () => {}); });
  } catch (err) {
    console.error('TTS-Fehler:', err.message);
    fs.unlink(tempFile, () => {});
    res.status(500).json({ error: 'TTS-Synthese fehlgeschlagen', details: err.message });
  }
});

app.use((req, res) => {
  res.status(404).json({ error: 'Nicht gefunden. Endpunkte: /health, /voices, POST /speak' });
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`\n  OpenClaw TTS-Server laeuft auf Port ${PORT}`);
  console.log(`  Stimme: ${DEFAULT_VOICE}`);
  console.log(`  Health: http://localhost:${PORT}/health\n`);
});
SERVEREOF

# --- package.json schreiben ---
cat > "$TTS_DIR/package.json" << 'PKGEOF'
{
  "name": "openclaw-tts-server",
  "version": "1.0.0",
  "description": "OpenClaw TTS-Server – Edge TTS fuer Cowan",
  "main": "server.js",
  "scripts": { "start": "node server.js" },
  "dependencies": {
    "express": "^4.18.2",
    "node-edge-tts": "^1.0.0"
  }
}
PKGEOF

# --- npm install ---
echo ""
echo "📦 Installiere Abhaengigkeiten..."
cd "$TTS_DIR"
npm install --production 2>&1 | tail -3

# --- systemd Service ---
cat > /etc/systemd/system/${SERVICE_NAME}.service << SVCEOF
[Unit]
Description=OpenClaw TTS-Server (Edge TTS)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${TTS_DIR}
Environment=SYNC_TOKEN=$(cat "$TOKEN_FILE" 2>/dev/null || echo "$SYNC_TOKEN")
Environment=TTS_PORT=${TTS_PORT}
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
  echo "🔄 TTS-Server aktualisiert + neu gestartet"
else
  systemctl start ${SERVICE_NAME}
  echo ""
  echo "✅ TTS-Server installiert + gestartet"
fi

# --- Tailscale Serve konfigurieren (Port 8444) ---
echo ""
echo "🌐 Konfiguriere Tailscale Serve auf Port 8444..."
sudo tailscale serve --bg --https 8444 http://localhost:${TTS_PORT} 2>/dev/null || {
  echo "⚠️  Tailscale Serve konnte nicht konfiguriert werden."
  echo "   Manuell ausfuehren: sudo tailscale serve --bg --https 8444 http://localhost:${TTS_PORT}"
}

# --- Status ---
sleep 2
echo ""
echo "========================================="
echo "  ✅ TTS-Server Setup komplett!"
echo "========================================="
echo ""
echo "  Port:     ${TTS_PORT} (lokal)"
echo "  HTTPS:    https://$(tailscale status --json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['Self']['DNSName'].rstrip('.'))" 2>/dev/null || echo 'DEIN-TAILSCALE-HOSTNAME'):8444"
echo "  Token:    Gleicher wie Sync-Server"
echo "  Stimme:   de-DE-KatjaNeural"
echo ""
echo "  Test:     curl -X POST https://HOSTNAME:8444/speak \\"
echo "              -H 'Authorization: Bearer DEIN_TOKEN' \\"
echo "              -H 'Content-Type: application/json' \\"
echo "              -d '{\"text\": \"Hallo, ich bin Cowan!\"}' -o test.mp3"
echo ""
