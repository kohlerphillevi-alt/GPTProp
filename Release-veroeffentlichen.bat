@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"
title GPTProp-Update veroeffentlichen

rem Ablauf fuer ein Update:
rem   1. In package.json "version" erhoehen (z. B. 2.0.0 -> 2.1.0)
rem   2. Installer-bauen.bat ausfuehren
rem   3. Diese Datei ausfuehren -> Code wird hochgeladen, Release erstellt,
rem      alle installierten GPTProp-Versionen aktualisieren sich automatisch.

set "PATH=%PATH%;%ProgramFiles%\Git\cmd;%ProgramFiles%\GitHub CLI"
where gh >nul 2>nul || (echo GitHub CLI fehlt: winget install GitHub.cli & pause & exit /b 1)
where git >nul 2>nul || (echo Git fehlt: winget install Git.Git & pause & exit /b 1)
gh auth status >nul 2>nul || (echo Nicht bei GitHub angemeldet. Bitte "gh auth login" ausfuehren. & pause & exit /b 1)

for /f "usebackq delims=" %%v in (`node -p "require('./package.json').version"`) do set "VER=%%v"
if "%VER%"=="" (echo Version nicht lesbar. & pause & exit /b 1)
echo Version: %VER%

if not exist "dist\GPTProp-Setup.exe" (echo Erst Installer-bauen.bat ausfuehren. & pause & exit /b 1)
if not exist "dist\latest.yml" (echo dist\latest.yml fehlt - erst Installer-bauen.bat ausfuehren. & pause & exit /b 1)
findstr /c:"version: %VER%" "dist\latest.yml" >nul || (echo Der Build passt nicht zu Version %VER%. Bitte Installer-bauen.bat erneut ausfuehren. & pause & exit /b 1)

gh release view "v%VER%" >nul 2>nul && (echo Version v%VER% ist schon veroeffentlicht. Bitte in package.json die Version erhoehen und neu bauen. & pause & exit /b 1)

echo [1/2] Code hochladen...
git add -A
git commit -m "GPTProp %VER%" >nul 2>nul
git push || (echo Hochladen des Codes fehlgeschlagen. & pause & exit /b 1)

echo [2/2] Release v%VER% erstellen...
set "ASSETS=dist\GPTProp-Setup.exe dist\GPTProp-Setup.exe.blockmap dist\latest.yml"
if exist "dist\GPTProp-Portable.exe" set "ASSETS=%ASSETS% dist\GPTProp-Portable.exe"
gh release create "v%VER%" %ASSETS% --title "GPTProp %VER%" --notes "Installieren: GPTProp-Setup.exe herunterladen und starten. Vorhandene Installationen aktualisieren sich automatisch." || (echo Release fehlgeschlagen. & pause & exit /b 1)

echo.
echo Fertig! Alle GPTProp-Installationen bekommen Version %VER% automatisch.
pause
