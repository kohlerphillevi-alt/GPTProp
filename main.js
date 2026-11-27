const { app, BrowserWindow, globalShortcut, shell, Tray, Menu, nativeImage, ipcMain, safeStorage, clipboard, session } = require('electron');
const path = require('path');
const fs = require('fs');
const os = require('os');
const { spawn } = require('child_process');

let win, tray, quitting = false;

/* ======================= Einstellungen ======================= */
const SETTINGS_FILE = () => path.join(app.getPath('userData'), 'settings.json');
const DEFAULTS = { apiKeyEnc: '', apiKeyPlain: '', model: 'auto', confirmActions: false };
let settings = { ...DEFAULTS };

function loadSettings() {
  try { settings = { ...DEFAULTS, ...JSON.parse(fs.readFileSync(SETTINGS_FILE(), 'utf8')) }; }
  catch { settings = { ...DEFAULTS }; }
  // Einmalig: Nachfragen standardmäßig aus (kann in den Einstellungen wieder eingeschaltet werden)
  if (settings.noConfirmMigrated !== true) { settings.confirmActions = false; settings.noConfirmMigrated = true; saveSettings(); }
  // Einmalig: Sprachsteuerung für bestehende Installationen einschalten (neue Installationen: aus)
  if (settings.voiceMigrated !== true) { if (settings.apiKeyEnc || settings.apiKeyPlain) settings.voice = true; settings.voiceMigrated = true; saveSettings(); }
}
function saveSettings() {
  try {
    fs.mkdirSync(path.dirname(SETTINGS_FILE()), { recursive: true });
    fs.writeFileSync(SETTINGS_FILE(), JSON.stringify(settings, null, 2), 'utf8');
  } catch (e) { console.error('Einstellungen nicht gespeichert:', e); }
}
function getKey() {
  if (settings.apiKeyEnc) {
    try { return safeStorage.decryptString(Buffer.from(settings.apiKeyEnc, 'base64')); } catch { /* fällt durch */ }
  }
  return settings.apiKeyPlain || '';
}
function setKey(key) {
  key = String(key || '').trim();
  settings.apiKeyEnc = ''; settings.apiKeyPlain = '';
  if (!key) return;
  try {
    if (safeStorage.isEncryptionAvailable()) { settings.apiKeyEnc = safeStorage.encryptString(key).toString('base64'); return; }
  } catch { /* fällt durch */ }
  settings.apiKeyPlain = key;
}
const mask = (k) => (k ? (k.length > 10 ? k.slice(0, 4) + '…' + k.slice(-4) : '••••') : '');
// Allgemeine Geheimnis-Speicherung (Spotify-Zugang)
function encSecret(v) {
  v = String(v || '').trim();
  if (!v) return '';
  try { if (safeStorage.isEncryptionAvailable()) return 'enc:' + safeStorage.encryptString(v).toString('base64'); } catch { /* fällt durch */ }
  return 'raw:' + Buffer.from(v).toString('base64');
}
function decSecret(v) {
  v = String(v || '');
  try {
    if (v.startsWith('enc:')) return safeStorage.decryptString(Buffer.from(v.slice(4), 'base64'));
    if (v.startsWith('raw:')) return Buffer.from(v.slice(4), 'base64').toString();
  } catch { /* egal */ }
  return '';
}

/* ======================= Gemini ======================= */
const BASE = 'https://generativelanguage.googleapis.com/v1beta';
// Werden genutzt, falls die Modellliste nicht geladen werden kann
const FALLBACK_MODELS = ['models/gemini-flash-lite-latest', 'models/gemini-2.5-flash-lite', 'models/gemini-2.0-flash-lite', 'models/gemini-flash-latest', 'models/gemini-2.5-flash', 'models/gemini-2.0-flash'];
let modelCache = { key: '', at: 0, list: [] };
const cooldown = new Map(); // Modell -> Zeitstempel, bis wann es übersprungen wird
let lastModel = '';

// Alte Keys (AIza…) per x-goog-api-key, neue Keys (AQ.…) per Authorization: Bearer.
// Funktioniert eine Variante nicht (401/403), wird automatisch die andere probiert und gemerkt.
const authMode = new Map();
const authHeaders = (key, mode) => (mode === 'bearer' ? { Authorization: 'Bearer ' + key } : { 'x-goog-api-key': key });
const defaultMode = (key) => (/^AQ\./.test(key) ? 'bearer' : 'header');
async function gFetch(url, key, opts = {}) {
  const mode = authMode.get(key) || defaultMode(key);
  const go = (m) => fetch(url, { ...opts, headers: { ...(opts.headers || {}), ...authHeaders(key, m) } });
  const r = await go(mode);
  if (r.status !== 401 && r.status !== 403) { if (r.ok) authMode.set(key, mode); return r; }
  const other = mode === 'bearer' ? 'header' : 'bearer';
  const r2 = await go(other);
  if (r2.ok) { authMode.set(key, other); return r2; }
  return r2.status === 401 || r2.status === 403 ? r : r2;
}
const errReason = (j) => ((j?.error?.details || []).find((d) => d.reason) || {}).reason || '';
function keyHint(key) {
  return /^AQ\./.test(key || '')
    ? ' Tipp: Falls es weiter nicht klappt, erstelle unter aistudio.google.com/apikey einen Key, der mit „AIza“ beginnt.'
    : '';
}

function scoreModel(m) {
  const id = String(m.name || '').replace(/^models\//, '');
  if (!/^gemini/.test(id)) return null;
  if (!(m.supportedGenerationMethods || []).includes('generateContent')) return null;
  if (/embed|tts|image|audio|live|vision|computer-use|robotics|aqa|learnlm|nano|veo|imagen|banana|thinking-exp|research|diffusion/.test(id)) return null;
  const v = parseFloat((id.match(/gemini-(\d+(?:\.\d+)?)/) || [])[1] || '0');
  // Geschwindigkeit zuerst: kleinstes/schnellstes Modell (Flash-Lite) vor Flash vor Pro
  let s = /flash-lite|lite/.test(id) ? 300 : /flash/.test(id) ? 200 : /pro/.test(id) ? 40 : 100;
  s += v * 10;
  if (/preview|exp/.test(id)) s -= 120;
  if (/-\d{3}$/.test(id)) s -= 2;
  return s;
}

async function fetchModels(key, force) {
  if (!force && modelCache.key === key && Date.now() - modelCache.at < 3600e3 && modelCache.list.length) return modelCache.list;
  const all = [];
  let token = '';
  for (let i = 0; i < 10; i++) {
    const url = `${BASE}/models?pageSize=1000${token ? '&pageToken=' + encodeURIComponent(token) : ''}`;
    const r = await gFetch(url, key, { signal: AbortSignal.timeout(20000) });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) {
      const reason = errReason(j);
      const err = new Error((j?.error?.message || `HTTP ${r.status}`) + (reason ? ` (${reason})` : '') + keyHint(key));
      err.status = r.status;
      throw err;
    }
    all.push(...(j.models || []));
    token = j.nextPageToken;
    if (!token) break;
  }
  const list = all
    .map((m) => ({ name: m.name, label: m.displayName || m.name.replace(/^models\//, ''), score: scoreModel(m) }))
    .filter((m) => m.score !== null)
    .sort((a, b) => b.score - a.score);
  modelCache = { key, at: Date.now(), list };
  return list;
}

// Diagnose-Protokoll (enthält niemals den Key)
const LOG_FILE = () => path.join(app.getPath('userData'), 'gptprop.log');
function log(...a) {
  try {
    const f = LOG_FILE();
    if (fs.existsSync(f) && fs.statSync(f).size > 512 * 1024) fs.renameSync(f, f + '.old');
    fs.appendFileSync(f, new Date().toLocaleString('de-DE') + '  ' + a.join(' ') + '\n', 'utf8');
  } catch { /* egal */ }
}
function progress(text) { try { if (win && !win.isDestroyed()) win.webContents.send('gen-progress', text); } catch { /* egal */ } }

// Schnell-Modus: "Nachdenken" der Modelle minimieren – spart pro Antwort mehrere Sekunden
function thinkingFor(model) {
  const id = model.replace(/^models\//, '');
  if (/gemini-[3-9]/.test(id)) return { thinkingLevel: 'low' };
  if (/2\.5-pro/.test(id)) return { thinkingBudget: 128 };
  if (/2\.5-flash|flash-latest|flash-lite-latest/.test(id)) return { thinkingBudget: 0 };
  return null;
}
const noThinking = new Set(); // Modelle, die thinkingConfig ablehnen
function bodyFor(model, body) {
  const t = noThinking.has(model) ? null : thinkingFor(model);
  if (!t) return JSON.stringify(body);
  return JSON.stringify({ ...body, generationConfig: { ...(body.generationConfig || {}), thinkingConfig: t } });
}

function parseRetry(j) {
  const d = (j?.error?.details || []).find((x) => String(x['@type'] || '').includes('RetryInfo'));
  const s = d && parseFloat(String(d.retryDelay || '').replace('s', ''));
  return s && isFinite(s) ? Math.min(Math.max(s, 5), 3600) * 1000 : 60000;
}

async function generate(body) {
  const key = getKey();
  if (!key) return { ok: false, code: 'NO_KEY', error: 'Kein Gemini-API-Key hinterlegt. Öffne die Einstellungen (Zahnrad oben rechts).' };

  let ranked = [];
  progress('Modellliste');
  try { ranked = (await fetchModels(key)).map((m) => m.name); }
  catch (e) {
    log('Modellliste FEHLER', e.status || '', e.message);
    if (e.status === 400 || e.status === 401 || e.status === 403) return { ok: false, code: 'BAD_KEY', error: 'Der API-Key wurde abgelehnt: ' + e.message };
    ranked = [];
  }
  if (!ranked.length) ranked = FALLBACK_MODELS.slice();
  // Fest gewähltes Modell zuerst; bei "Automatisch" das zuletzt funktionierende zuerst (spart Fehlversuche)
  const first = settings.model && settings.model !== 'auto' ? settings.model : (lastModel && ranked.includes(lastModel) && /lite/.test(lastModel) ? lastModel : '');
  let order = first ? [first, ...ranked.filter((m) => m !== first)] : ranked;
  const now = Date.now();
  const ready = order.filter((m) => (cooldown.get(m) || 0) <= now);
  // Sind alle gesperrt, die mit der kürzesten Sperre zuerst probieren
  order = ready.length ? ready : order.slice().sort((a, b) => (cooldown.get(a) || 0) - (cooldown.get(b) || 0));
  order = order.slice(0, 6);
  log('Anfrage, Reihenfolge:', order.map((m) => m.replace(/^models\//, '')).join(' > '), '| Auth:', authMode.get(key) || defaultMode(key));

  const deadline = Date.now() + 90000; // nie länger als 90 s insgesamt
  let lastErr = 'Unbekannter Fehler';
  for (let i = 0; i < order.length; i++) {
    const model = order[i];
    const left = deadline - Date.now();
    if (left < 5000) { lastErr = 'Zeitüberschreitung – Gemini hat zu lange nicht geantwortet.'; break; }
    const short = model.replace(/^models\//, '');
    progress(short);
    const t0 = Date.now();
    let r, j;
    try {
      r = await gFetch(`${BASE}/${model}:generateContent`, key, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: bodyFor(model, body),
        signal: AbortSignal.timeout(Math.min(30000, left)) // hängt ein Modell, schnell zum nächsten
      });
      j = await r.json().catch(() => ({}));
    } catch (e) {
      lastErr = `${short}: Netzwerkfehler – ` + (e.name === 'TimeoutError' ? 'keine Antwort innerhalb des Zeitlimits' : (e.cause && e.cause.code) || e.message);
      log(short, 'FEHLER', lastErr, `${Date.now() - t0}ms`);
      cooldown.set(model, Date.now() + 60000);
      continue;
    }
    const cand = j?.candidates?.[0];
    log(short, 'HTTP', r.status, `${Date.now() - t0}ms`, r.ok ? `finish=${cand?.finishReason || '-'} parts=${cand?.content?.parts?.length || 0}` : `${errReason(j)} ${String(j?.error?.message || '').slice(0, 200)}`);
    if (r.ok) {
      lastModel = model;
      return { ok: true, data: j, model: short };
    }
    const msg = j?.error?.message || `HTTP ${r.status}`;
    lastErr = `${short}: ${msg}`;
    if (r.status === 400 && /thinking/i.test(msg) && !noThinking.has(model)) {
      noThinking.add(model); i--; continue; // gleiches Modell ohne thinkingConfig nochmal
    }
    const reason = errReason(j);
    if (r.status === 401 || ((r.status === 400 || r.status === 403) && (/API key|API_KEY/i.test(msg) || /API_KEY|SERVICE_BLOCKED|TOKEN/.test(reason)))) {
      return { ok: false, code: 'BAD_KEY', error: 'Der API-Key wurde abgelehnt: ' + msg + (reason ? ` (${reason})` : '') + keyHint(key) };
    }
    if (r.status === 429) cooldown.set(model, Date.now() + parseRetry(j));
    else if (r.status === 404 || r.status === 403) cooldown.set(model, Date.now() + 6 * 3600e3);
    else if (r.status >= 500) cooldown.set(model, Date.now() + 30000);
    // 400 (z. B. Modell unterstützt etwas nicht): ohne Sperre nächstes Modell probieren
  }
  return { ok: false, code: 'ALL_FAILED', error: 'Kein Gemini-Modell ist gerade verfügbar. Letzter Fehler – ' + lastErr };
}

/* ======================= PC-Werkzeuge ======================= */
function expandPath(p) {
  let s = String(p || '').trim().replace(/^["']|["']$/g, '');
  s = s.replace(/%([^%]+)%/g, (m, v) => process.env[v] ?? m);
  s = s.replace(/\$env:(\w+)/gi, (m, v) => process.env[v] ?? m);
  if (s === '~' || s.startsWith('~/') || s.startsWith('~\\')) s = path.join(os.homedir(), s.slice(1));
  if (!s) s = os.homedir();
  return path.isAbsolute(s) ? path.normalize(s) : path.join(os.homedir(), s);
}
const clip = (s, n) => (s.length > n ? s.slice(0, n) + `\n… [${s.length - n} Zeichen abgeschnitten]` : s);

function runPowerShell(command, cwd, timeoutSec, maxOut = 8000) {
  return new Promise((resolve) => {
    const prefix = "$ProgressPreference='SilentlyContinue';[Console]::OutputEncoding=[Text.Encoding]::UTF8;$OutputEncoding=[Text.Encoding]::UTF8;";
    const encoded = Buffer.from(prefix + String(command), 'utf16le').toString('base64');
    let dir = cwd ? expandPath(cwd) : os.homedir();
    if (!fs.existsSync(dir)) dir = os.homedir();
    const t = Math.min(Math.max(Number(timeoutSec) || 60, 1), 600);
    let out = '', err = '', done = false;
    let child;
    try {
      child = spawn('powershell.exe', ['-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', encoded], { cwd: dir, windowsHide: true });
    } catch (e) { resolve({ error: 'Start fehlgeschlagen: ' + e.message }); return; }
    const finish = (res) => { if (!done) { done = true; clearTimeout(timer); resolve(res); } };
    const timer = setTimeout(() => {
      try { spawn('taskkill', ['/PID', String(child.pid), '/T', '/F'], { windowsHide: true }); } catch { /* egal */ }
      finish({ exit_code: null, timed_out: true, stdout: clip(out, maxOut), stderr: clip(err, 3000), hinweis: `Nach ${t}s abgebrochen.` });
    }, t * 1000);
    child.stdout.on('data', (d) => { if (out.length < 200000) out += d.toString('utf8'); });
    child.stderr.on('data', (d) => { if (err.length < 50000) err += d.toString('utf8'); });
    child.on('error', (e) => finish({ error: e.message }));
    child.on('close', (code) => finish({ exit_code: code, stdout: clip(out.trim(), maxOut), stderr: clip(err.trim(), 3000) }));
  });
}

/* ======================= Spotify ======================= */
// Steuerung über die Windows-Mediensteuerung (SMTC) – funktioniert ohne Login
const SMTC_ACTIONS = ['status', 'play', 'pause', 'toggle', 'next', 'previous'];
function smtcScript(action) {
  return [
    'Add-Type -AssemblyName System.Runtime.WindowsRuntime',
    "$asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]",
    'function Await($op, [Type]$t) { $task = $asTask.MakeGenericMethod($t).Invoke($null, @($op)); $task.Wait(5000) | Out-Null; $task.Result }',
    '[void][Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]',
    '$mgr = Await ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])',
    "$s = $mgr.GetSessions() | Where-Object { $_.SourceAppUserModelId -match 'spotify' } | Select-Object -First 1",
    "if (-not $s) { '{\"running\":false}'; exit }",
    `$a = '${action}'`,
    "switch ($a) { 'play' { Await ($s.TryPlayAsync()) ([bool]) | Out-Null } 'pause' { Await ($s.TryPauseAsync()) ([bool]) | Out-Null } 'toggle' { Await ($s.TryTogglePlayPauseAsync()) ([bool]) | Out-Null } 'next' { Await ($s.TrySkipNextAsync()) ([bool]) | Out-Null } 'previous' { Await ($s.TrySkipPreviousAsync()) ([bool]) | Out-Null } }",
    "if ($a -ne 'status') { Start-Sleep -Milliseconds 800 }",
    '$p = Await ($s.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])',
    '@{ running = $true; status = "$($s.GetPlaybackInfo().PlaybackStatus)"; artist = $p.Artist; title = $p.Title; album = $p.AlbumTitle } | ConvertTo-Json -Compress'
  ].join('\n');
}
async function smtc(action) {
  if (!SMTC_ACTIONS.includes(action)) return { error: 'Unbekannte Aktion: ' + action };
  const r = await runPowerShell(smtcScript(action), null, 20);
  try { return JSON.parse(String(r.stdout || '').trim().split('\n').pop()); }
  catch { return { error: 'Mediensteuerung nicht erreichbar.', details: (r.stderr || r.error || '').slice(0, 300) }; }
}
async function volumeKeys(kind, times) {
  const code = kind === 'up' ? 175 : kind === 'down' ? 174 : 173;
  const n = kind === 'mute' ? 1 : Math.min(Math.max(Number(times) || 5, 1), 50);
  await runPowerShell(`$w = New-Object -ComObject WScript.Shell; 1..${n} | ForEach-Object { $w.SendKeys([char]${code}) }`, null, 15);
  return { ok: true, volume: kind, steps: n };
}

function spotifyExe() {
  const c = [path.join(process.env.LOCALAPPDATA || '', 'Microsoft', 'WindowsApps', 'Spotify.exe'), path.join(process.env.APPDATA || '', 'Spotify', 'Spotify.exe')];
  for (const f of c) { try { fs.lstatSync(f); return f; } catch { /* weiter */ } }
  return '';
}
function launchSpotify(uri) {
  const exe = spotifyExe();
  if (!exe) { shell.openExternal(uri).catch(() => {}); return false; }
  try { const ch = spawn(exe, ['--uri=' + uri], { detached: true, stdio: 'ignore' }); ch.on('error', () => shell.openExternal(uri).catch(() => {})); ch.unref(); return true; }
  catch { shell.openExternal(uri).catch(() => {}); return false; }
}
// Direkte Links/URIs erkennen
function parseSpotifyRef(q) {
  const s = String(q || '').trim();
  let m = s.match(/open\.spotify\.com\/(?:intl-[a-z-]+\/)?(track|album|playlist|artist|episode|show)\/([A-Za-z0-9]{22})/i);
  if (m) return `spotify:${m[1].toLowerCase()}:${m[2]}`;
  m = s.match(/^spotify:(track|album|playlist|artist|episode|show):([A-Za-z0-9]{22})$/i);
  return m ? `spotify:${m[1].toLowerCase()}:${m[2]}` : '';
}
let spToken = { id: '', token: '', exp: 0 };
async function spotifyToken(id, secret) {
  if (spToken.id === id && spToken.token && Date.now() < spToken.exp) return spToken.token;
  const r = await fetch('https://accounts.spotify.com/api/token', {
    method: 'POST',
    headers: { Authorization: 'Basic ' + Buffer.from(id + ':' + secret).toString('base64'), 'Content-Type': 'application/x-www-form-urlencoded' },
    body: 'grant_type=client_credentials',
    signal: AbortSignal.timeout(15000)
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok || !j.access_token) throw new Error('Spotify-Zugang abgelehnt: ' + (j.error_description || j.error || 'HTTP ' + r.status));
  spToken = { id, token: j.access_token, exp: Date.now() + ((j.expires_in || 3600) - 60) * 1000 };
  return spToken.token;
}
const spotifyCreds = () => ({ id: decSecret(settings.spotifyId), secret: decSecret(settings.spotifySecret) });
async function spotifySearch(query, type) {
  const { id, secret } = spotifyCreds();
  if (!id || !secret) return null;
  const t = ['track', 'album', 'artist', 'playlist'].includes(type) ? type : 'track';
  const token = await spotifyToken(id, secret);
  const r = await fetch(`https://api.spotify.com/v1/search?type=${t}&limit=5&market=DE&q=${encodeURIComponent(query)}`, { headers: { Authorization: 'Bearer ' + token }, signal: AbortSignal.timeout(15000) });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error('Spotify-Suche fehlgeschlagen: ' + (j?.error?.message || 'HTTP ' + r.status));
  const item = (j[t + 's']?.items || []).find(Boolean);
  if (!item) return { notFound: true };
  const who = item.artists ? item.artists.map((a) => a.name).join(', ') : item.owner?.display_name || '';
  return { uri: item.uri, name: item.name, by: who, type: t };
}
async function spotifyPlay({ query, type }) {
  const q = String(query || '').trim();
  if (!q) return smtc('play');
  let uri = parseSpotifyRef(q), found = null;
  if (!uri) {
    try { found = await spotifySearch(q, type); }
    catch (e) { return { error: e.message, hint: 'Spotify-Zugang in den GPTProp-Einstellungen prüfen.' }; }
    if (found && found.notFound) return { error: `Auf Spotify nichts gefunden für „${q}“.` };
    if (found) uri = found.uri;
  }
  if (!uri) {
    launchSpotify('spotify:search:' + encodeURIComponent(q));
    return { played: false, opened_search: q, hint: 'Ohne Spotify-Zugang kann ich nur die Suche öffnen – der Nutzer muss auf Play klicken. Für automatisches Abspielen in den GPTProp-Einstellungen Spotify Client ID und Secret eintragen.' };
  }
  launchSpotify(uri);
  let st = null;
  for (let i = 0; i < 8; i++) {
    await new Promise((r) => setTimeout(r, 1200));
    st = await smtc('status');
    if (st && st.status === 'Playing' && (!found || !found.name || String(st.title || '').toLowerCase().includes(found.name.toLowerCase().slice(0, 12)))) break;
  }
  return { played: !!(st && st.status === 'Playing'), requested: found ? `${found.by} – ${found.name}` : uri, now_playing: st && st.title ? `${st.artist} – ${st.title}` : null, status: st && st.status };
}

/* ======================= App-Steuerung (UI Automation) ======================= */
// uia.ps1 liegt im App-Paket (asar); PowerShell braucht eine echte Datei mit BOM
// Skripte aus dem App-Paket als echte Dateien (mit BOM) in den Benutzerordner kopieren
function ensureScript(name) {
  try {
    const src = fs.readFileSync(path.join(__dirname, name), 'utf8').replace(/^\uFEFF/, '');
    const dst = path.join(app.getPath('userData'), name);
    let cur = '';
    try { cur = fs.readFileSync(dst, 'utf8').replace(/^\uFEFF/, ''); } catch { /* neu */ }
    if (cur !== src) fs.writeFileSync(dst, '\uFEFF' + src, 'utf8');
    return dst;
  } catch (e) { log(name + ' konnte nicht bereitgestellt werden:', e.message); return ''; }
}
let uiaPath = '';
function ensureUia() { uiaPath = ensureScript('uia.ps1'); return uiaPath; }

/* ======================= Sprachsteuerung "Hey Prop" ======================= */
// wake.ps1 lauscht offline (Windows-Spracherkennung) auf das Aktivierungswort.
// Die Aufnahme des Befehls macht das Fenster (Mikrofon-Puffer), Gemini wandelt sie in Text um.
const SENS = { low: 0.45, normal: 0.33, high: 0.27 };
let wakeProc = null, wakeWant = false, wakeTimer = null, lastWake = 0;
let voiceState = { state: 'off', error: '' };
function setVoiceState(state, error = '') {
  voiceState = { state, error };
  try { if (win && !win.isDestroyed()) win.webContents.send('voice-state', voiceState); } catch { /* egal */ }
  try { if (tray) tray.setToolTip(state === 'listening' ? 'GPTProp – hört auf „Hey Prop“' : 'GPTProp'); } catch { /* egal */ }
}
function wakeStart() {
  wakeWant = true;
  clearTimeout(wakeTimer);
  if (wakeProc) return;
  const file = ensureScript('wake.ps1');
  if (!file) { setVoiceState('error', 'Sprachdienst-Datei fehlt.'); return; }
  setVoiceState('starting');
  let errMsg = '';
  try {
    wakeProc = spawn('powershell.exe', ['-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', file, '-MinConf', String(SENS[settings.voiceSensitivity] || SENS.normal)], { windowsHide: true });
  } catch (e) { wakeProc = null; setVoiceState('error', e.message); return; }
  const proc = wakeProc;
  let buf = '';
  proc.stdout.on('data', (d) => {
    buf += d.toString('utf8');
    let i;
    while ((i = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, i).trim(); buf = buf.slice(i + 1);
      if (line === 'READY') setVoiceState('listening');
      else if (/^WAKE/.test(line)) onWake(line);
      else if (line.startsWith('ERROR')) { errMsg = line.slice(6); log('Sprachdienst:', line); }
    }
  });
  proc.stderr.on('data', (d) => { const s = d.toString('utf8').trim(); if (s) log('Sprachdienst stderr:', s.slice(0, 300)); });
  proc.on('error', (e) => { errMsg = e.message; });
  proc.on('close', () => {
    if (wakeProc === proc) wakeProc = null;
    if (!wakeWant) { setVoiceState('off'); return; }
    setVoiceState('error', errMsg || 'Sprachdienst wurde beendet – starte neu…');
    wakeTimer = setTimeout(() => { if (wakeWant) wakeStart(); }, errMsg ? 30000 : 3000);
  });
}
function wakeStop() {
  wakeWant = false;
  clearTimeout(wakeTimer);
  if (wakeProc) { try { wakeProc.kill(); } catch { /* egal */ } wakeProc = null; }
  setVoiceState('off');
}
function onWake(line) {
  if (Date.now() - lastWake < 2500) return;
  lastWake = Date.now();
  log('Aktivierungswort erkannt', line.split(' ')[1] || '');
  if (!win || win.isDestroyed()) return;
  if (!win.isVisible() || win.isMinimized()) { if (win.isMinimized()) win.restore(); win.showInactive(); }
  win.webContents.send('voice-wake');
}
function applyVoice() { if (settings.voice) wakeStart(); else wakeStop(); }

async function transcribe(b64) {
  if (typeof b64 !== 'string' || !b64 || b64.length > 12e6) return { ok: false, error: 'Ungültige Aufnahme.' };
  const r = await generate({
    contents: [{ role: 'user', parts: [
      { inlineData: { mimeType: 'audio/wav', data: b64 } },
      { text: 'Transkribiere diese deutsche Sprachaufnahme wörtlich. Lass ein Aktivierungswort wie "Hey Prop" am Anfang weg. Gib NUR den gesprochenen Befehl als Text zurück, ohne Anführungszeichen und ohne Erklärung. Wenn nichts Verständliches gesagt wurde, antworte genau: NICHTS' }
    ] }],
    generationConfig: { temperature: 0, maxOutputTokens: 400 }
  });
  if (!r.ok) return r;
  let t = (r.data?.candidates?.[0]?.content?.parts || []).filter((p) => !p.thought).map((p) => p.text || '').join('').trim();
  t = t.replace(/^["„“']+|["“”']+$/g, '').trim();
  if (/^NICHTS\.?$/i.test(t)) t = '';
  return { ok: true, text: t };
}
const UIA_ACTIONS = ['windows', 'launch', 'focus', 'snapshot', 'click', 'type', 'keys', 'click_at'];
async function uia(action, args = {}) {
  if (!UIA_ACTIONS.includes(action)) return { error: 'Unbekannte Aktion.' };
  const file = uiaPath || ensureUia();
  if (!file) return { error: 'App-Steuerung nicht verfügbar.' };
  const wait = Math.min(Math.max(Number(args.wait_seconds ?? 8) || 0, 0), 60);
  const b64 = Buffer.from(JSON.stringify({ ...args, wait_seconds: wait }), 'utf8').toString('base64');
  const r = await runPowerShell(`& '${file.replace(/'/g, "''")}' '${action}' '${b64}'`, null, wait + 40, 60000);
  const line = String(r.stdout || '').trim().split('\n').filter((l) => l.trim().startsWith('{')).pop();
  try { return JSON.parse(line); }
  catch { return { error: r.timed_out ? 'Zeitüberschreitung bei der App-Steuerung.' : 'App-Steuerung fehlgeschlagen.', details: String(r.stderr || r.error || r.stdout || '').slice(0, 400) }; }
}

const TOOLS = {
  async app_launch({ name }) { return uia('launch', { name }); },
  async ui_windows() { return uia('windows', {}); },
  async ui_snapshot(a) { return uia('snapshot', { window: a.window, filter: a.filter, wait_seconds: a.wait_seconds ?? 10 }); },
  async ui_click(a) { return uia('click', { window: a.window, name: a.name, type: a.type, index: a.index, mouse: a.mouse, right: a.right, double: a.double, wait_seconds: a.wait_seconds ?? 15 }); },
  async ui_type(a) { return uia('type', { window: a.window, field: a.field, text: a.text, press_enter: a.press_enter, append: a.append, wait_seconds: a.wait_seconds ?? 8 }); },
  async ui_keys(a) { return uia('keys', { window: a.window, keys: a.keys, wait_seconds: a.wait_seconds ?? 5 }); },
  async ui_click_at(a) { return uia('click_at', { window: a.window, x: a.x, y: a.y, right: a.right, double: a.double, wait_seconds: 3 }); },
  async spotify_play(a) { return spotifyPlay(a); },
  async spotify_control({ action, steps }) {
    const act = String(action || 'status').toLowerCase();
    if (act === 'volume_up') return volumeKeys('up', steps);
    if (act === 'volume_down') return volumeKeys('down', steps);
    if (act === 'mute') return volumeKeys('mute');
    const r = await smtc(act);
    if (r && r.running === false && act !== 'status') {
      if (act === 'play') { launchSpotify('spotify:'); return { ok: true, hint: 'Spotify wurde gestartet.' }; }
      return { error: 'Spotify läuft gerade nicht.' };
    }
    return r;
  },
  async run_command({ command, cwd, timeout_seconds }) {
    if (!command) return { error: 'Kein Befehl angegeben.' };
    return runPowerShell(command, cwd, timeout_seconds);
  },
  async read_file({ path: p, max_chars }) {
    const f = expandPath(p);
    const st = await fs.promises.stat(f);
    if (st.isDirectory()) return { error: 'Das ist ein Ordner. Nutze list_directory.' };
    if (st.size > 20 * 1024 * 1024) return { error: `Datei zu groß (${st.size} Bytes).` };
    const buf = await fs.promises.readFile(f);
    if (buf.subarray(0, 8000).includes(0)) return { path: f, size: st.size, error: 'Binärdatei – Inhalt kann nicht als Text gelesen werden.' };
    return { path: f, size: st.size, content: clip(buf.toString('utf8'), Math.min(Number(max_chars) || 30000, 100000)) };
  },
  async write_file({ path: p, content, append }) {
    const f = expandPath(p);
    await fs.promises.mkdir(path.dirname(f), { recursive: true });
    if (append) await fs.promises.appendFile(f, String(content ?? ''), 'utf8');
    else await fs.promises.writeFile(f, String(content ?? ''), 'utf8');
    return { ok: true, path: f };
  },
  async list_directory({ path: p }) {
    const d = expandPath(p);
    const entries = await fs.promises.readdir(d, { withFileTypes: true });
    const items = [];
    for (const e of entries.slice(0, 400)) {
      const full = path.join(d, e.name);
      let size, modified;
      try { const st = await fs.promises.stat(full); size = e.isDirectory() ? undefined : st.size; modified = st.mtime.toISOString().slice(0, 16); } catch { /* egal */ }
      items.push({ name: e.name, type: e.isDirectory() ? 'ordner' : 'datei', size, modified });
    }
    return { path: d, count: entries.length, items, truncated: entries.length > 400 };
  },
  async open_item({ target }) {
    const t = String(target || '').trim();
    if (!t) return { error: 'Kein Ziel angegeben.' };
    if (/^[a-z][a-z0-9+.-]*:/i.test(t) && !/^[a-z]:[\\/]/i.test(t)) {
      if (/^(javascript|data|vbscript):/i.test(t)) return { error: 'Dieses Protokoll ist nicht erlaubt.' };
      await shell.openExternal(t);
      return { ok: true, opened: t };
    }
    const f = expandPath(t);
    if (!fs.existsSync(f)) return { error: `Nicht gefunden: ${f}. Für Programme nutze run_command mit Start-Process.` };
    const e = await shell.openPath(f);
    return e ? { error: e } : { ok: true, opened: f };
  },
  async delete_item({ path: p }) {
    const f = expandPath(p);
    if (!fs.existsSync(f)) return { error: 'Nicht gefunden: ' + f };
    await shell.trashItem(f);
    return { ok: true, moved_to_recycle_bin: f };
  },
  async system_info() {
    return {
      os: `${os.type()} ${os.release()} (${os.arch()})`, host: os.hostname(), user: os.userInfo().username,
      home: os.homedir(), desktop: app.getPath('desktop'), documents: app.getPath('documents'), downloads: app.getPath('downloads'),
      cpu: `${os.cpus()[0]?.model || '?'} (${os.cpus().length} Threads)`,
      ram_gb: { total: +(os.totalmem() / 1073741824).toFixed(1), free: +(os.freemem() / 1073741824).toFixed(1) },
      uptime_h: +(os.uptime() / 3600).toFixed(1), local_time: new Date().toString()
    };
  },
  async clipboard_read() { return { text: clip(clipboard.readText(), 20000) }; },
  async clipboard_write({ text }) { clipboard.writeText(String(text ?? '')); return { ok: true }; }
};

/* ======================= IPC ======================= */
function publicSettings() {
  const key = getKey();
  return {
    hasKey: !!key, keyMasked: mask(key), model: settings.model || 'auto', confirmActions: settings.confirmActions !== false,
    autostart: app.getLoginItemSettings().openAtLogin, version: app.getVersion(), logFile: LOG_FILE(),
    hasSpotify: !!(spotifyCreds().id && spotifyCreds().secret), spotifyIdMasked: mask(spotifyCreds().id),
    autoUpdate: settings.autoUpdate !== false, update: updState,
    hotkeyOpen: hk('hotkeyOpen'), hotkeyVoice: hk('hotkeyVoice'), hotkeyStatus: { ...hotkeyStatus }, hotkeyDefaults: HOTKEY_DEFAULTS,
    voice: !!settings.voice, voiceSpeak: settings.voiceSpeak !== false, ttsVoice: settings.ttsVoice || '', ttsRate: settings.ttsRate || 1.25, voiceSensitivity: settings.voiceSensitivity || 'normal', voiceState, lastModel: lastModel.replace(/^models\//, ''),
    env: { user: os.userInfo().username, home: os.homedir(), desktop: app.getPath('desktop'), downloads: app.getPath('downloads'), documents: app.getPath('documents'), os: `${os.type()} ${os.release()}` }
  };
}

ipcMain.handle('settings:get', () => publicSettings());
ipcMain.handle('settings:set', (e, s = {}) => {
  if (typeof s.apiKey === 'string') { setKey(s.apiKey); modelCache = { key: '', at: 0, list: [] }; cooldown.clear(); }
  if (typeof s.spotifyId === 'string') { settings.spotifyId = encSecret(s.spotifyId); spToken = { id: '', token: '', exp: 0 }; }
  if (typeof s.spotifySecret === 'string') { settings.spotifySecret = encSecret(s.spotifySecret); spToken = { id: '', token: '', exp: 0 }; }
  if (typeof s.model === 'string') settings.model = s.model || 'auto';
  if (typeof s.confirmActions === 'boolean') settings.confirmActions = s.confirmActions;
  if (typeof s.autostart === 'boolean') { try { app.setLoginItemSettings({ openAtLogin: s.autostart }); } catch { /* egal */ } }
  if (typeof s.voiceSpeak === 'boolean') settings.voiceSpeak = s.voiceSpeak;
  if (typeof s.ttsVoice === 'string') settings.ttsVoice = s.ttsVoice.slice(0, 200);
  if (typeof s.ttsRate === 'number' && isFinite(s.ttsRate)) settings.ttsRate = Math.min(Math.max(s.ttsRate, 0.7), 2);
  if (typeof s.voiceSensitivity === 'string' && SENS[s.voiceSensitivity]) {
    const changed = settings.voiceSensitivity !== s.voiceSensitivity;
    settings.voiceSensitivity = s.voiceSensitivity;
    if (changed && settings.voice) { wakeStop(); setTimeout(applyVoice, 300); }
  }
  if (typeof s.voice === 'boolean') { settings.voice = s.voice; applyVoice(); }
  if (typeof s.autoUpdate === 'boolean') { settings.autoUpdate = s.autoUpdate; scheduleUpdates(); }
  // Tastenkürzel: prüfen, registrieren; schlägt es fehl, altes Kürzel behalten
  const hotkeyError = {};
  for (const name of ['hotkeyOpen', 'hotkeyVoice']) {
    if (typeof s[name] !== 'string') continue;
    const a = s[name].trim();
    if (!validAccel(a)) { hotkeyError[name] = 'Ungültige Kombination – bitte mit Strg, Alt, Umschalt oder Win kombinieren.'; continue; }
    const old = hk(name);
    settings[name] = a;
    registerHotkeys();
    if (a && hotkeyStatus[name]) { hotkeyError[name] = hotkeyStatus[name]; settings[name] = old; registerHotkeys(); }
  }
  saveSettings();
  return { ...publicSettings(), hotkeyError };
});
ipcMain.handle('gemini:test', async (e, key) => {
  const k = String(key || '').trim() || getKey();
  if (!k) return { ok: false, error: 'Kein Key eingegeben.' };
  try { const list = await fetchModels(k, true); return { ok: true, count: list.length, best: list[0]?.name.replace(/^models\//, '') || '' }; }
  catch (err) { return { ok: false, error: err.message, status: err.status || 0 }; }
});
// Während in den Einstellungen ein neues Kürzel aufgenommen wird, globale Kürzel pausieren
ipcMain.handle('update:check', () => checkForUpdates(true));
ipcMain.handle('update:install', () => installUpdate());
ipcMain.handle('hotkeys:pause', () => { try { globalShortcut.unregisterAll(); } catch { /* egal */ } return true; });
ipcMain.handle('hotkeys:resume', () => { registerHotkeys(); return { ...hotkeyStatus }; });
ipcMain.handle('voice:transcribe', async (e, b64) => {
  try { return await transcribe(b64); } catch (err) { return { ok: false, error: err.message }; }
});
ipcMain.handle('spotify:test', async (e, id, secret) => {
  const c = spotifyCreds();
  id = String(id || '').trim() || c.id; secret = String(secret || '').trim() || c.secret;
  if (!id || !secret) return { ok: false, error: 'Client ID und Client Secret eingeben.' };
  try { spToken = { id: '', token: '', exp: 0 }; await spotifyToken(id, secret); return { ok: true }; }
  catch (err) { return { ok: false, error: err.message }; }
});
ipcMain.handle('gemini:models', async (e, force) => {
  const k = getKey();
  if (!k) return { ok: false, error: 'Kein Key.' };
  try { const list = await fetchModels(k, !!force); return { ok: true, models: list.map((m) => ({ name: m.name, label: m.label })) }; }
  catch (err) { return { ok: false, error: err.message }; }
});
ipcMain.handle('gemini:generate', async (e, body) => {
  try { return await generate(body); }
  catch (err) { return { ok: false, code: 'ERROR', error: err.message }; }
});
ipcMain.handle('tool:run', async (e, name, args) => {
  const fn = Object.prototype.hasOwnProperty.call(TOOLS, name) ? TOOLS[name] : null;
  if (!fn) return { error: 'Unbekanntes Werkzeug: ' + name };
  try { return await fn(args || {}); }
  catch (err) { return { error: err.message }; }
});

/* ======================= Fenster & Tray ======================= */
function show() {
  if (!win) return;
  if (win.isMinimized()) win.restore();
  win.show();
  win.focus();
  win.webContents.executeJavaScript("document.getElementById('userInput')&&document.getElementById('userInput').focus()").catch(() => {});
}

function create() {
  win = new BrowserWindow({
    width: 860, height: 900, minWidth: 420, minHeight: 520,
    backgroundColor: '#0d0b17', title: 'GPTProp', show: false,
    titleBarStyle: 'hidden',
    titleBarOverlay: { color: '#0d0b17', symbolColor: '#c9c2ec', height: 52 },
    icon: path.join(__dirname, 'icon.png'),
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, nodeIntegration: false, sandbox: true, backgroundThrottling: false }
  });
  win.loadFile('index.html');
  win.once('ready-to-show', () => win.show());
  const external = (url) => { if (!/^(javascript|data|file|vbscript):/i.test(url)) shell.openExternal(url).catch(() => {}); };
  win.webContents.setWindowOpenHandler(({ url }) => { external(url); return { action: 'deny' }; });
  win.webContents.on('will-navigate', (e, url) => { if (!url.startsWith('file:')) { e.preventDefault(); external(url); } });
  win.on('close', (e) => { if (!quitting) { e.preventDefault(); win.hide(); } });
}

function openSettings() { show(); win.webContents.send('open-settings'); }

/* ======================= Automatische Updates (GitHub-Releases) ======================= */
const REPO = { owner: 'kohlerphillevi-alt', repo: 'GPTProp' };
const RELEASES_URL = `https://github.com/${REPO.owner}/${REPO.repo}/releases/latest`;
let autoUpdater = null;
try { ({ autoUpdater } = require('electron-updater')); } catch (e) { log('electron-updater nicht verfügbar:', e.message); }
const isPortable = !!process.env.PORTABLE_EXECUTABLE_FILE;
let updState = { state: 'idle', version: '', percent: 0, error: '', portable: isPortable, url: RELEASES_URL, checkedAt: 0 };
let updTimer = null, updInit = false;
function setUpd(patch) {
  updState = { ...updState, ...patch };
  try { if (win && !win.isDestroyed()) win.webContents.send('update-state', updState); } catch { /* egal */ }
  try { if (tray) tray.setContextMenu(trayMenu()); } catch { /* egal */ }
}
// "2.10.0" > "2.9.1"?
function newerVersion(a, b) {
  const p = (v) => String(v || '').replace(/^v/, '').split('-')[0].split('.').map((n) => parseInt(n, 10) || 0);
  const x = p(a), y = p(b);
  for (let i = 0; i < 3; i++) { if ((x[i] || 0) !== (y[i] || 0)) return (x[i] || 0) > (y[i] || 0); }
  return false;
}
async function checkPortableUpdate() {
  const r = await fetch(`https://api.github.com/repos/${REPO.owner}/${REPO.repo}/releases/latest`, { headers: { Accept: 'application/vnd.github+json', 'User-Agent': 'GPTProp-Updater' }, signal: AbortSignal.timeout(15000) });
  if (r.status === 404) { setUpd({ state: 'none', checkedAt: Date.now() }); return; }
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(j.message || 'HTTP ' + r.status);
  const v = String(j.tag_name || '').replace(/^v/, '');
  if (v && newerVersion(v, app.getVersion())) setUpd({ state: 'available', version: v, url: j.html_url || RELEASES_URL, checkedAt: Date.now() });
  else setUpd({ state: 'none', checkedAt: Date.now() });
}
async function checkForUpdates(manual) {
  if (!app.isPackaged) { setUpd({ state: 'error', error: 'Updates gibt es nur in der installierten App.' }); return updState; }
  if (['checking', 'downloading', 'ready'].includes(updState.state)) return updState;
  setUpd({ state: 'checking', error: '' });
  try {
    if (isPortable || !autoUpdater) await checkPortableUpdate();
    else await autoUpdater.checkForUpdates();
  } catch (e) {
    const msg = String(e && e.message || e);
    // Noch kein Release veröffentlicht -> kein Fehler, einfach "aktuell"
    if (/404|latest\.yml|No published versions|Cannot find/i.test(msg)) setUpd({ state: 'none', checkedAt: Date.now() });
    else { setUpd({ state: 'error', error: msg.split('\n')[0].slice(0, 200) }); if (manual) log('Update-Prüfung fehlgeschlagen:', msg.slice(0, 300)); }
  }
  return updState;
}
function initUpdater() {
  if (updInit || !app.isPackaged) return;
  updInit = true;
  if (autoUpdater && !isPortable) {
    autoUpdater.autoDownload = true;
    autoUpdater.autoInstallOnAppQuit = true;
    autoUpdater.logger = { info: () => {}, warn: (m) => log('Updater:', String(m).slice(0, 200)), error: (m) => log('Updater-Fehler:', String(m).slice(0, 300)), debug: () => {} };
    autoUpdater.on('checking-for-update', () => setUpd({ state: 'checking' }));
    autoUpdater.on('update-available', (i) => setUpd({ state: 'downloading', version: i.version, percent: 0 }));
    autoUpdater.on('update-not-available', () => setUpd({ state: 'none', checkedAt: Date.now() }));
    autoUpdater.on('download-progress', (p) => setUpd({ state: 'downloading', percent: Math.round(p.percent || 0) }));
    autoUpdater.on('update-downloaded', (i) => {
      setUpd({ state: 'ready', version: i.version, percent: 100, checkedAt: Date.now() });
      log('Update bereit:', i.version);
    });
    autoUpdater.on('error', (e) => {
      const msg = String(e && e.message || e);
      if (/404|latest\.yml|No published versions/i.test(msg)) setUpd({ state: 'none', checkedAt: Date.now() });
      else setUpd({ state: 'error', error: msg.split('\n')[0].slice(0, 200) });
    });
  }
  scheduleUpdates();
}
function scheduleUpdates() {
  clearInterval(updTimer); updTimer = null;
  if (settings.autoUpdate === false || !app.isPackaged) return;
  setTimeout(() => { if (settings.autoUpdate !== false) checkForUpdates(false); }, 15000);
  updTimer = setInterval(() => { if (settings.autoUpdate !== false) checkForUpdates(false); }, 4 * 3600e3);
}
function installUpdate() {
  if (updState.state !== 'ready' || !autoUpdater) { if (updState.state === 'available') shell.openExternal(updState.url).catch(() => {}); return false; }
  quitting = true;
  wakeStop();
  setImmediate(() => { try { autoUpdater.quitAndInstall(true, true); } catch (e) { log('Update-Installation fehlgeschlagen:', e.message); quitting = false; } });
  return true;
}

/* ======================= Tastenkürzel (frei belegbar) ======================= */
const HOTKEY_DEFAULTS = { hotkeyOpen: 'Control+Space', hotkeyVoice: 'Control+Shift+Space' };
let hotkeyStatus = { hotkeyOpen: '', hotkeyVoice: '' }; // '' = ok, sonst Fehlertext
const hk = (name) => (typeof settings[name] === 'string' ? settings[name] : HOTKEY_DEFAULTS[name]);
function startVoiceHotkey() { show(); try { win.webContents.send('voice-ptt'); } catch { /* egal */ } }
// Gültiges Electron-Kürzel? (mind. eine Zusatztaste, außer F-Tasten)
function validAccel(a) {
  if (!a) return true; // leer = aus
  const parts = String(a).split('+');
  const key = parts[parts.length - 1];
  const mods = parts.slice(0, -1);
  if (!key || parts.length > 4) return false;
  if (!mods.every((m) => ['Control', 'Alt', 'Shift', 'Super'].includes(m))) return false;
  if (!/^(F([1-9]|1[0-9]|2[0-4])|[A-Z0-9]|Space|Tab|Enter|Backspace|Delete|Insert|Home|End|PageUp|PageDown|Up|Down|Left|Right|Plus|[,.\-;/'`[\]\\=])$/.test(key)) return false;
  return mods.length > 0 || /^F\d+$/.test(key);
}
function registerHotkeys() {
  try { globalShortcut.unregisterAll(); } catch { /* egal */ }
  const map = { hotkeyOpen: show, hotkeyVoice: startVoiceHotkey };
  const used = new Set();
  for (const name of Object.keys(map)) {
    const a = hk(name);
    hotkeyStatus[name] = '';
    if (!a) continue;
    if (used.has(a)) { hotkeyStatus[name] = 'Doppelt belegt'; continue; }
    let ok = false;
    try { ok = globalShortcut.register(a, map[name]); } catch { ok = false; }
    if (ok) used.add(a); else hotkeyStatus[name] = 'Von einem anderen Programm belegt';
  }
  try { if (tray) tray.setContextMenu(trayMenu()); } catch { /* egal */ }
}
// Electron-Kürzel lesbar machen: "Control+Shift+Space" -> "Strg+Umschalt+Leertaste"
function accelLabel(a) {
  if (!a) return 'aus';
  const t = { Control: 'Strg', Alt: 'Alt', Shift: 'Umschalt', Super: 'Win', Space: 'Leertaste', Up: '↑', Down: '↓', Left: '←', Right: '→', Delete: 'Entf', Insert: 'Einfg', Home: 'Pos1', End: 'Ende', PageUp: 'Bild↑', PageDown: 'Bild↓', Backspace: 'Rück', Enter: 'Enter', Plus: '+' };
  return a.split('+').map((p) => t[p] || p).join('+');
}

function createTray() {
  const img = nativeImage.createFromPath(path.join(__dirname, 'icon.png')).resize({ width: 16, height: 16 });
  tray = new Tray(img);
  tray.setToolTip('GPTProp');
  tray.setContextMenu(trayMenu());
  tray.on('click', show);
  tray.on('right-click', () => tray.setContextMenu(trayMenu()));
}
function trayMenu() {
  return Menu.buildFromTemplate([
    { label: `GPTProp öffnen${hk('hotkeyOpen') ? ` (${accelLabel(hk('hotkeyOpen'))})` : ''}`, click: show },
    { label: `Spracheingabe${hk('hotkeyVoice') ? ` (${accelLabel(hk('hotkeyVoice'))})` : ''}`, click: startVoiceHotkey },
    ...(updState.state === 'ready' ? [{ label: `⬆ Update ${updState.version} installieren & neu starten`, click: installUpdate }] : []),
    ...(updState.state === 'available' ? [{ label: `⬆ Version ${updState.version} herunterladen`, click: installUpdate }] : []),
    { label: 'Einstellungen', click: openSettings },
    { label: 'Sprachsteuerung „Hey Prop“', type: 'checkbox', checked: !!settings.voice,
      click: (i) => { settings.voice = i.checked; saveSettings(); applyVoice(); try { win.webContents.send('settings-changed'); } catch { /* egal */ } } },
    { label: 'Mit Windows starten', type: 'checkbox', checked: app.getLoginItemSettings().openAtLogin,
      click: (i) => app.setLoginItemSettings({ openAtLogin: i.checked }) },
    { type: 'separator' },
    { label: 'Beenden', click: () => { quitting = true; app.quit(); } }
  ]);
}

// Signaltöne/Vorlesen ohne vorherigen Klick erlauben (Sprachsteuerung aus dem Hintergrund)
app.commandLine.appendSwitch('autoplay-policy', 'no-user-gesture-required');
if (!app.requestSingleInstanceLock()) app.quit();
else {
  app.setAppUserModelId('de.gptprop.app');
  app.on('second-instance', show);
  app.whenReady().then(() => {
    loadSettings();
    ensureUia();
    // Mikrofon (Sprachsteuerung) und Benachrichtigungen erlauben
    const allowed = ['media', 'notifications', 'speaker-selection'];
    session.defaultSession.setPermissionRequestHandler((wc, perm, cb) => cb(allowed.includes(perm)));
    session.defaultSession.setPermissionCheckHandler((wc, perm) => allowed.includes(perm));
    create();
    applyVoice();
    createTray();
    registerHotkeys();
    initUpdater();
    // Modellliste vorab laden, damit die erste Nachricht nicht warten muss
    const k = getKey();
    if (k) fetchModels(k).catch((e) => log('Vorab-Laden der Modelle fehlgeschlagen:', e.message));
  });
}
app.on('before-quit', () => { quitting = true; wakeStop(); });
app.on('will-quit', () => globalShortcut.unregisterAll());
