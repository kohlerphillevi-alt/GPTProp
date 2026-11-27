# GPTProp

**Dein KI-Desktop-Assistent für Windows** – mit kostenloser Gemini-KI, Zugriff auf deinen PC, App-Steuerung, Spotify und Sprachsteuerung per „Hey Prop“.

<p align="center"><img src="icon.png" width="96" alt="GPTProp Logo"></p>

## ⬇️ Download

Unter **[Releases](../../releases/latest)** gibt es zwei Varianten:

| Datei | Beschreibung |
|---|---|
| `GPTProp-Setup.exe` | Installer mit Startmenü- und Desktop-Verknüpfung (empfohlen) |
| `GPTProp-Portable.exe` | Läuft ohne Installation, z. B. vom USB-Stick |

> Die EXE ist nicht signiert. Windows SmartScreen zeigt beim ersten Start eine Warnung → **„Weitere Informationen“ → „Trotzdem ausführen“**.

## ✨ Funktionen

- **KI-Chat mit Gemini (gratis):** Eigener API-Key in den Einstellungen. GPTProp wählt automatisch das schnellste verfügbare Gratis-Modell (Flash-Lite) und weicht bei Limits/Ausfällen selbstständig auf andere Modelle aus.
- **PC-Zugriff:** PowerShell-Befehle, Dateien lesen/schreiben/auflisten, Papierkorb, Programme/Ordner/Webseiten öffnen, Zwischenablage, Systeminfos, Herunterfahren/Neustart.
- **Jede App bedienen:** Über Windows UI Automation liest GPTProp Knöpfe & Felder von Fenstern und kann klicken und tippen – z. B. *„Starte Minecraft im NoRisk Launcher“*.
- **Spotify:** Play/Pause/Weiter/Zurück/Lautstärke/„Was läuft?“ sofort; Songs per Name abspielen mit optionalem kostenlosem Spotify-Developer-Zugang.
- **Sprachsteuerung „Hey Prop“:** Aktivierungswort wird offline von Windows erkannt, der Befehl per Gemini transkribiert, Antworten werden vorgelesen (Stimme & Tempo einstellbar).
- **Chatverlauf:** Alle Chats bleiben gespeichert – Seitenleiste mit Suche, Umbenennen und Löschen; der letzte Chat öffnet sich beim Start.
- **„Aurora Glass“-Design** mit 4 Themes (Aurora, Ocean, Sunset, Matrix).
- **Bilder:** per Strg+V, Drag & Drop oder Büroklammer anhängen und dazu fragen.
- **Tastenkürzel frei belegbar:** Öffnen (Standard Strg+Leertaste) und Spracheingabe (Strg+Umschalt+Leertaste).
- **Automatische Updates** über GitHub-Releases (installierte Version).
- **Listen & Erinnerungen**, läuft im Infobereich weiter.
- **Offline-Modus** ohne Key (Apps öffnen, Listen, Erinnerungen).

## 🚀 Einrichtung

1. Kostenlosen Gemini-Key holen: <https://aistudio.google.com/apikey>
2. GPTProp öffnen → **Zahnrad** oben rechts → Key einfügen → **„Speichern & prüfen“**
3. Optional: Sprachsteuerung einschalten, Spotify-Zugang eintragen

Keys werden lokal mit Windows-Verschlüsselung (`safeStorage`) gespeichert und nur an Google bzw. Spotify gesendet.

## ⚠️ Sicherheit

GPTProp führt Befehle **standardmäßig ohne Rückfrage** aus – die KI hat volle Benutzerrechte auf dem PC. Wer vorher gefragt werden möchte: Einstellungen → **„Aktionen bestätigen“** einschalten. Gelöschte Dateien landen im Papierkorb.

## 🛠️ Selbst bauen

Voraussetzung: [Node.js](https://nodejs.org) (LTS) unter Windows.

```bat
Installer-bauen.bat
```

Die BAT installiert die Abhängigkeiten, baut `dist\GPTProp-Setup.exe` und `dist\GPTProp-Portable.exe`, legt beide in `..\GPTProp-Weitergeben` ab und installiert die neue Version über eine vorhandene.

**Update veröffentlichen:** Version in `package.json` erhöhen → `Installer-bauen.bat` → `Release-veroeffentlichen.bat`. Alle installierten GPTProp-Versionen aktualisieren sich danach automatisch.

Manuell:

```bash
npm install
npm start          # im Entwicklungsmodus starten
npm run build      # Setup + Portable bauen
```

## 📁 Aufbau

| Datei | Inhalt |
|---|---|
| `main.js` | Electron-Hauptprozess: Gemini-Anbindung & Modellwahl, PC-Werkzeuge, Spotify, Sprachdienst, Tray |
| `preload.js` | Sichere Brücke zwischen Oberfläche und Hauptprozess |
| `index.html` | Oberfläche, KI-Agent-Schleife, Einstellungen, Spracheingabe |
| `uia.ps1` | App-Steuerung über Windows UI Automation |
| `wake.ps1` | Offline-Erkennung des Aktivierungsworts „Hey Prop“ |

## 📄 Lizenz

[MIT](LICENSE)
