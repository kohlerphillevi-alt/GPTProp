@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"
title GPTProp bauen und installieren
set CSC_IDENTITY_AUTO_DISCOVERY=false

where node >nul 2>nul || (echo Node.js fehlt. Bitte von https://nodejs.org installieren und erneut starten. & pause & exit /b 1)

echo [1/4] Laufendes GPTProp beenden...
taskkill /IM GPTProp.exe /F >nul 2>nul
ping -n 3 127.0.0.1 >nul

if exist "%LOCALAPPDATA%\electron-builder\Cache\winCodeSign" rmdir /s /q "%LOCALAPPDATA%\electron-builder\Cache\winCodeSign"
if exist dist rmdir /s /q dist
if exist dist (echo dist-Ordner ist gesperrt. Bitte schliessen und erneut starten. & pause & exit /b 1)

echo [2/4] Installiere Abhaengigkeiten...
call npm install || (echo npm install fehlgeschlagen. & pause & exit /b 1)

echo [3/4] Baue GPTProp-Setup.exe...
call npm run build || (echo Build fehlgeschlagen. & pause & exit /b 1)
if not exist "dist\GPTProp-Setup.exe" (echo Setup wurde nicht erzeugt. & pause & exit /b 1)

echo Lege Ordner zum Weitergeben an...
set "SHARE=%~dp0..\GPTProp-Weitergeben"
if not exist "%SHARE%" mkdir "%SHARE%"
copy /y "dist\GPTProp-Setup.exe" "%SHARE%\GPTProp-Setup.exe" >nul || (echo Kopieren fehlgeschlagen. & pause & exit /b 1)
if exist "dist\GPTProp-Portable.exe" copy /y "dist\GPTProp-Portable.exe" "%SHARE%\GPTProp-Portable.exe" >nul
copy /y "ANLEITUNG-Weitergeben.txt" "%SHARE%\ANLEITUNG.txt" >nul

echo [4/4] Installiere neue Version (ueberschreibt die alte, Einstellungen/Listen bleiben)...
start "" /wait "dist\GPTProp-Setup.exe" /S --force-run
if errorlevel 1 (echo Installation fehlgeschlagen. & pause & exit /b 1)

ping -n 4 127.0.0.1 >nul
tasklist /FI "IMAGENAME eq GPTProp.exe" 2>nul | find /I "GPTProp.exe" >nul || (
  if exist "%LOCALAPPDATA%\Programs\GPTProp\GPTProp.exe" start "" "%LOCALAPPDATA%\Programs\GPTProp\GPTProp.exe"
)

echo.
echo Fertig! GPTProp ist aktualisiert und gestartet.
echo Zum Weitergeben: %SHARE%
echo Gemini-Key eintragen: Zahnrad oben rechts in der App.
pause
