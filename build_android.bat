@echo off
setlocal

pushd "%~dp0"
if errorlevel 1 goto root_error

if not exist ".vscode\supabase.env.json" goto missing_config

echo Building SuelosAR Android APK...
echo.
call flutter build apk --release --dart-define-from-file=.vscode/supabase.env.json
set "BUILD_EXIT_CODE=%ERRORLEVEL%"

if not "%BUILD_EXIT_CODE%"=="0" goto build_failed

echo.
echo SUCCESS: Android APK build completed.
goto finish

:missing_config
set "BUILD_EXIT_CODE=1"
echo ERROR: .vscode\supabase.env.json was not found.
goto finish

:build_failed
echo.
echo FAILURE: Android APK build failed with exit code %BUILD_EXIT_CODE%.

:finish
echo.
pause
popd
endlocal & exit /b %BUILD_EXIT_CODE%

:root_error
echo ERROR: Could not switch to the project root.
echo.
pause
endlocal & exit /b 1
