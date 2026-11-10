@echo off
rem Starts the CyberAIContext companion.
rem First run creates a Python environment in .venv; packages are reinstalled when requirements.txt changes.
cd /d "%~dp0"
if not exist ".venv\Scripts\python.exe" (
    echo Creating Python environment...
    py -3 -m venv .venv || python -m venv .venv || goto :error
    ".venv\Scripts\python.exe" -m pip install --upgrade pip
)
fc /b requirements.txt ".venv\requirements.installed" >nul 2>&1
if errorlevel 1 (
    echo Installing / updating packages...
    ".venv\Scripts\python.exe" -m pip install -r requirements.txt || goto :error
    copy /y requirements.txt ".venv\requirements.installed" >nul
)
".venv\Scripts\python.exe" cyberai_companion.py %*
pause
exit /b 0

:error
echo.
echo Installation failed. Python 3.10+ is required: https://www.python.org/downloads/
pause
exit /b 1
