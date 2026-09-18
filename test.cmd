@echo off
setlocal
cd /d "%~dp0"

echo ==================================================
echo   AetherChat  --  core tests
echo   package : AetherCore
echo   path    : %CD%\AetherCore
echo ==================================================
echo.

where swift >nul 2>nul
if errorlevel 1 goto noswift

echo [ok] swift found:
swift --version
echo.
echo [run] swift test --package-path AetherCore
echo --------------------------------------------------
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Continue'; & swift test --package-path AetherCore 2>&1 | Tee-Object -FilePath 'test-output.log'; exit $LASTEXITCODE"
set RC=%ERRORLEVEL%
echo --------------------------------------------------
echo.
echo Full log written to: %CD%\test-output.log
if "%RC%"=="0" (
  echo [PASS] all tests green.
) else (
  echo [FAIL] exit code %RC%.
  echo        Open test-output.log and send its contents back.
)
echo.
pause
exit /b %RC%

:noswift
echo [X] swift was not found on PATH.
echo.
echo Install the Swift toolchain first:
echo.
echo     winget install --id Swift.Toolchain -e
echo.
echo Then CLOSE this window, open a NEW Command Prompt, and run test.cmd again.
echo A new terminal is required, because PATH is only refreshed in new sessions.
echo.
pause
exit /b 1
