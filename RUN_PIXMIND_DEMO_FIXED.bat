@echo off
setlocal EnableExtensions EnableDelayedExpansion
title PixMind Demo Launcher

REM ============================================================
REM PixMind / SmartStudio - Dynamic Windows Demo Launcher
REM Put this file in the ROOT of the Flutter project.
REM Project path is detected automatically from this BAT file.
REM ============================================================

set "PROJECT_ROOT=%~dp0"
cd /d "%PROJECT_ROOT%"

echo.
echo ============================================================
echo   PixMind / SmartStudio Demo Launcher
echo ============================================================
echo Project: %PROJECT_ROOT%
echo.

REM ------------------------------------------------------------
REM 1) Validate Flutter project
REM ------------------------------------------------------------
if not exist "%PROJECT_ROOT%pubspec.yaml" (
    echo [ERROR] pubspec.yaml was not found.
    echo Put this BAT file in the root of the Flutter project.
    goto :fail
)

REM ------------------------------------------------------------
REM 2) Find Flutter dynamically, with your known fallback path
REM ------------------------------------------------------------
set "FLUTTER_EXE="

where flutter >nul 2>&1
if not errorlevel 1 (
    for /f "delims=" %%F in ('where flutter') do (
        if not defined FLUTTER_EXE set "FLUTTER_EXE=%%F"
    )
)

if not defined FLUTTER_EXE (
    if exist "E:\flutter_sdk\flutter\bin\flutter.bat" (
        set "FLUTTER_EXE=E:\flutter_sdk\flutter\bin\flutter.bat"
        set "PATH=E:\flutter_sdk\flutter\bin;%PATH%"
    )
)

if not defined FLUTTER_EXE (
    echo [ERROR] Flutter was not found.
    echo Expected fallback:
    echo   E:\flutter_sdk\flutter\bin\flutter.bat
    goto :fail
)

echo [1/6] Flutter found:
echo       %FLUTTER_EXE%
echo.

REM ------------------------------------------------------------
REM 3) Get Flutter packages
REM ------------------------------------------------------------
echo [2/6] Getting Flutter packages...
call "%FLUTTER_EXE%" pub get
if errorlevel 1 (
    echo.
    echo [ERROR] flutter pub get failed.
    goto :fail
)
echo       Packages ready.
echo.

REM ------------------------------------------------------------
REM 4) Find Android SDK / ADB dynamically
REM ------------------------------------------------------------
set "ADB_EXE="

where adb >nul 2>&1
if not errorlevel 1 (
    for /f "delims=" %%A in ('where adb') do (
        if not defined ADB_EXE set "ADB_EXE=%%A"
    )
)

REM Your Android SDK location
if not defined ADB_EXE (
    if exist "E:\flutter_sdk\android-sdk\platform-tools\adb.exe" (
        set "ANDROID_SDK_ROOT=E:\flutter_sdk\android-sdk"
        set "ANDROID_HOME=E:\flutter_sdk\android-sdk"
        set "ADB_EXE=E:\flutter_sdk\android-sdk\platform-tools\adb.exe"
        set "PATH=E:\flutter_sdk\android-sdk\platform-tools;%PATH%"
    )
)

REM Generic fallbacks
if not defined ADB_EXE if defined ANDROID_SDK_ROOT (
    if exist "%ANDROID_SDK_ROOT%\platform-tools\adb.exe" (
        set "ADB_EXE=%ANDROID_SDK_ROOT%\platform-tools\adb.exe"
    )
)

if not defined ADB_EXE if defined ANDROID_HOME (
    if exist "%ANDROID_HOME%\platform-tools\adb.exe" (
        set "ADB_EXE=%ANDROID_HOME%\platform-tools\adb.exe"
    )
)

if not defined ADB_EXE (
    if exist "%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe" (
        set "ADB_EXE=%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe"
    )
)

if not defined ADB_EXE (
    echo [ERROR] ADB was not found.
    echo.
    echo Checked your expected path:
    echo   E:\flutter_sdk\android-sdk\platform-tools\adb.exe
    echo.
    echo Make sure platform-tools exists inside the Android SDK folder.
    goto :fail
)

echo [3/6] ADB found:
echo       %ADB_EXE%
echo.

REM ------------------------------------------------------------
REM 5) Detect connected Android devices
REM ------------------------------------------------------------
"%ADB_EXE%" start-server >nul 2>&1

set /a DEVICE_COUNT=0
set "FIRST_DEVICE="

for /f "skip=1 tokens=1,2" %%A in ('"%ADB_EXE%" devices') do (
    if "%%B"=="device" (
        set /a DEVICE_COUNT+=1
        set "DEVICE_!DEVICE_COUNT!=%%A"
        if not defined FIRST_DEVICE set "FIRST_DEVICE=%%A"
    )
)

if %DEVICE_COUNT% EQU 0 (
    echo [ERROR] No authorized Android device was found.
    echo.
    echo Connect the phone with USB debugging enabled.
    echo Unlock the phone and accept the USB debugging prompt.
    echo.
    echo Current ADB devices:
    "%ADB_EXE%" devices
    goto :fail
)

if %DEVICE_COUNT% EQU 1 (
    set "DEVICE_ID=%FIRST_DEVICE%"
) else (
    echo Multiple Android devices were found:
    echo.
    for /L %%N in (1,1,%DEVICE_COUNT%) do (
        echo   %%N. !DEVICE_%%N!
    )
    echo.
    set /p "DEVICE_CHOICE=Choose device number [1-%DEVICE_COUNT%]: "

    set "DEVICE_ID="
    for /L %%N in (1,1,%DEVICE_COUNT%) do (
        if "!DEVICE_CHOICE!"=="%%N" set "DEVICE_ID=!DEVICE_%%N!"
    )

    if not defined DEVICE_ID (
        echo [ERROR] Invalid device selection.
        goto :fail
    )
)

echo [4/6] Android device:
echo       %DEVICE_ID%
echo.

REM ------------------------------------------------------------
REM 6) ADB reverse for optional local semantic-search backend
REM ------------------------------------------------------------
echo [5/6] Configuring ADB reverse for port 8000...
"%ADB_EXE%" -s "%DEVICE_ID%" reverse tcp:8000 tcp:8000 >nul 2>&1

if errorlevel 1 (
    echo       [WARNING] Could not create adb reverse tcp:8000.
    echo       The Flutter app can still run.
) else (
    echo       Phone 127.0.0.1:8000 -^> PC localhost:8000
)
echo.

REM ------------------------------------------------------------
REM Optional backend discovery
REM ------------------------------------------------------------
set "BACKEND_DIR="

if defined PIXMIND_BACKEND_DIR (
    if exist "%PIXMIND_BACKEND_DIR%\app\main.py" (
        set "BACKEND_DIR=%PIXMIND_BACKEND_DIR%"
    )
)

if not defined BACKEND_DIR if exist "%PROJECT_ROOT%SmartStudio-Text-Embedding-Backend\app\main.py" (
    set "BACKEND_DIR=%PROJECT_ROOT%SmartStudio-Text-Embedding-Backend"
)

if not defined BACKEND_DIR if exist "%PROJECT_ROOT%backend\app\main.py" (
    set "BACKEND_DIR=%PROJECT_ROOT%backend"
)

if not defined BACKEND_DIR if exist "%PROJECT_ROOT%..\SmartStudio-Text-Embedding-Backend\app\main.py" (
    set "BACKEND_DIR=%PROJECT_ROOT%..\SmartStudio-Text-Embedding-Backend"
)

if defined BACKEND_DIR (
    echo       Text-embedding backend found:
    echo       %BACKEND_DIR%

    if exist "%BACKEND_DIR%\start_server.bat" (
        echo       Starting backend...
        start "PixMind Text Embedding Backend" cmd /k "cd /d ""%BACKEND_DIR%"" && call start_server.bat"
    ) else (
        where python >nul 2>&1
        if not errorlevel 1 (
            echo       Starting Uvicorn backend...
            start "PixMind Text Embedding Backend" cmd /k "cd /d ""%BACKEND_DIR%"" && python -m uvicorn app.main:app --host 0.0.0.0 --port 8000"
        ) else (
            echo       [WARNING] Backend exists, but Python was not found.
        )
    )

    timeout /t 3 /nobreak >nul
) else (
    echo       [INFO] Optional text-embedding backend was not found.
    echo       Main Flutter app will still start.
)

echo.

REM ------------------------------------------------------------
REM 7) Run Flutter on selected Android device
REM ------------------------------------------------------------
echo [6/6] Starting PixMind on %DEVICE_ID%...
echo.
echo ============================================================
echo   Hot reload: r
echo   Quit:       q
echo ============================================================
echo.

call "%FLUTTER_EXE%" run -d "%DEVICE_ID%"
set "FLUTTER_EXIT=%ERRORLEVEL%"

echo.
if not "%FLUTTER_EXIT%"=="0" (
    echo [ERROR] flutter run exited with code %FLUTTER_EXIT%.
    goto :fail
)

echo PixMind stopped normally.
goto :end

:fail
echo.
echo ============================================================
echo   Launcher stopped because of an error.
echo ============================================================
echo.
pause
exit /b 1

:end
echo.
pause
endlocal
exit /b 0
