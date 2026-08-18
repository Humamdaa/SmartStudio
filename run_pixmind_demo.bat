@echo off
setlocal EnableExtensions
cd /d "%~dp0"

REM Prefer adb from PATH; fall back to the default Android SDK location.
set "ADB=adb"
where adb >nul 2>&1 || set "ADB=%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe"

if not exist "%ADB%" if /i not "%ADB%"=="adb" (
    echo [PixMind] adb not found. Install Android platform-tools or add adb to PATH.
    pause
    exit /b 1
)

echo [PixMind] Connecting phone to local backend...
"%ADB%" reverse tcp:8000 tcp:8000
if errorlevel 1 (
    echo [PixMind] adb reverse failed. Is the phone connected with USB debugging allowed?
    pause
    exit /b 1
)

echo [PixMind] Starting Flutter...
flutter run --dart-define=PIX_MIND_TEXT_API=http://127.0.0.1:8000

pause
