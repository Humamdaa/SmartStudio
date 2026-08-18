@echo off

echo [PixMind] Connecting phone to local backend...
"E:\flutter_sdk\android-sdk\platform-tools\adb.exe" reverse tcp:8000 tcp:8000

echo [PixMind] Starting Flutter...
flutter run --dart-define=PIX_MIND_TEXT_API=http://127.0.0.1:8000

pause