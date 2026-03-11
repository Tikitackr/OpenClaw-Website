#!/bin/bash
# ============================================================
# OpenClaw Sync-Server – Setup-Script
# Ein Befehl, alles automatisch.
# ============================================================

set -e

echo ""
echo "======================================"
echo "  OpenClaw Sync-Server Setup"
echo "======================================"
echo ""

# --- 1. Node.js pruefen/installieren ---
echo "[1/6] Node.js pruefen..."
if command -v node &> /dev/null; then
  echo "  ✓ Node.js $(node -v) ist bereits installiert"
else
  echo "  → Node.js wird installiert..."
  apt update -qq && apt install -y -qq nodejs npm > /dev/null 2>&1
  echo "  ✓ Node.js $(node -v) installiert"
fi

# --- 2. Ordner anlegen ---
echo "[2/6] Ordner anlegen..."
mkdir -p /root/sync-server
mkdir -p /root/sync-data
echo "  ✓ /root/sync-server und /root/sync-data erstellt"

# --- 3. Server-Dateien erstellen ---
echo "[3/6] Server-Dateien erstellen..."

cat > /root/sync-server/package.json << 'PKGJSON'
{
  "name": "openclaw-sync-server",
  "version": "1.0.0",
  "dependencies": {
    "express": "^4.21.0"
  }
}
PKGJSON

cat > /root/sync-server/server.js << 'SERVERJS'
const express = require('express');
const fs = require('fs');
const path = require('path');
const PORT = process.env.SYNC_PORT || 3456;
const SYNC_TOKEN = process.env.SYNC_TOKEN;
const DATA_DIR = process.env.SYNC_DATA_DIR || '/root/sync-data';
if (!SYNC_TOKEN) { console.error('FEHLER: SYNC_TOKEN nicht gesetzt!'); process.exit(1); }
if (!fs.existsSync(DATA_DIR)) { fs.mkdirSync(DATA_DIR, { recursive: true }); }
const app = express();
app.use((req, res, next) => {
  const allowed = ['https://tikitackr.github.io','http://localhost:3000','http://localhost:5173'];
  const origin = req.headers.origin;
  if (allowed.includes(origin)) res.setHeader('Access-Control-Allow-Origin', origin);
  res.setHeader('Access-Control-Allow-Methods', 'GET, PUT, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  res.setHeader('Access-Control-Max-Age', '86400');
  if (req.method === 'OPTIONS') return res.sendStatus(204);
  next();
});
app.use(express.json({ limit: '1mb' }));
function requireAuth(req, res, next) {
  const auth = req.headers.authorization;
  if (!auth || auth !== 'Bearer ' + SYNC_TOKEN) {
    return res.status(401).json({ error: 'Unauthorized' });
  }
  next();
}
function isValidFilename(name) {
  return /^[a-zA-Z0-9_-]+\.json$/.test(name);
}
app.get('/health', (req, res) => {
  res.json({ status: 'ok', timestamp: new Date().toISOString(), version: '1.0.0' });
});
app.get('/:filename', requireAuth, (req, res) => {
  const { filename } = req.params;
  if (!isValidFilename(filename)) return res.status(400).json({ error: 'Ungueltiger Dateiname' });
  const fp = path.join(DATA_DIR, filename);
  if (!fs.existsSync(fp)) return res.status(404).json({ error: 'Nicht gefunden', file: filename });
  try { res.json(JSON.parse(fs.readFileSync(fp, 'utf-8'))); }
  catch (e) { res.status(500).json({ error: 'Lesefehler' }); }
});
app.put('/:filename', requireAuth, (req, res) => {
  const { filename } = req.params;
  if (!isValidFilename(filename)) return res.status(400).json({ error: 'Ungueltiger Dateiname' });
  if (!req.body || typeof req.body !== 'object') return res.status(400).json({ error: 'Body muss JSON sein' });
  const fp = path.join(DATA_DIR, filename);
  try {
    fs.writeFileSync(fp, JSON.stringify(req.body, null, 2), 'utf-8');
    console.log('Geschrieben: ' + filename);
    res.json({ ok: true, file: filename, timestamp: new Date().toISOString() });
  } catch (e) { res.status(500).json({ error: 'Schreibfehler' }); }
});
app.use((req, res) => { res.status(404).json({ error: 'Nicht gefunden' }); });
app.listen(PORT, '0.0.0.0', () => {
  console.log('Sync-Server laeuft auf Port ' + PORT);
});
SERVERJS

echo "  ✓ server.js + package.json erstellt"

# --- 4. Dependencies installieren ---
echo "[4/6] Dependencies installieren..."
cd /root/sync-server && npm install --quiet 2>&1 | tail -1
echo "  ✓ Express installiert"

# --- 5. Token generieren + systemd-Service ---
echo "[5/6] Token generieren + Service einrichten..."
SYNC_TOKEN=$(openssl rand -hex 32)

cat > /etc/systemd/system/openclaw-sync.service << SYSTEMD
[Unit]
Description=OpenClaw Sync-Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root/sync-server
ExecStart=/usr/bin/node /root/sync-server/server.js
Restart=on-failure
RestartSec=5
Environment=SYNC_PORT=3456
Environment=SYNC_TOKEN=${SYNC_TOKEN}
Environment=SYNC_DATA_DIR=/root/sync-data

[Install]
WantedBy=multi-user.target
SYSTEMD

systemctl daemon-reload
systemctl enable openclaw-sync --quiet
systemctl start openclaw-sync

# Token in Datei speichern (zum spaeter nochmal nachschauen)
echo "${SYNC_TOKEN}" > /root/sync-data/SYNC_TOKEN.txt
chmod 600 /root/sync-data/SYNC_TOKEN.txt
echo "  ✓ Service laeuft und startet automatisch nach Reboot"
echo "  ✓ Token gespeichert in /root/sync-data/SYNC_TOKEN.txt"

# --- 6. Tailscale Serve ---
echo "[6/6] Tailscale HTTPS einrichten..."
tailscale serve --bg --https 8443 http://localhost:3456 > /dev/null 2>&1
TAILSCALE_HOSTNAME=$(tailscale status --json | grep -o '"DNSName":"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')
echo "  ✓ HTTPS auf Port 8443 aktiv"

# --- Fertig! ---
echo ""
echo "======================================"
echo "  ✓ Sync-Server ist eingerichtet!"
echo "======================================"
echo ""
echo "  SYNC_URL:   https://${TAILSCALE_HOSTNAME}:8443"
echo "  SYNC_TOKEN: ${SYNC_TOKEN}"
echo ""
echo "  ╔══════════════════════════════════════════╗"
echo "  ║  WICHTIG: Notiere dir den SYNC_TOKEN!    ║"
echo "  ║  Du brauchst ihn unter 'Meine Daten'    ║"
echo "  ║  im Dashboard.                           ║"
echo "  ╚══════════════════════════════════════════╝"
echo ""
echo "  Health-Check: curl -k https://${TAILSCALE_HOSTNAME}:8443/health"
echo ""
echo "  Token vergessen? Jederzeit abrufen mit:"
echo "  cat /root/sync-data/SYNC_TOKEN.txt"
echo ""
