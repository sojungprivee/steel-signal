@echo off
chcp 65001 >nul
setlocal
title SteelSignal

rem ===== SteelSignal 실행: 더블클릭하면 웹 화면이 열립니다 =====
set "APP=%~dp0steelsignal"
set "EXE=%APP%\.venv\Scripts\steelsignal.exe"
set "URL=http://127.0.0.1:8765/"

if not exist "%APP%\install.ps1" (
    echo [오류] steelsignal 폴더를 찾을 수 없습니다: "%APP%"
    echo        이 파일은 steelsignal 폴더와 같은 위치에 있어야 합니다.
    pause
    exit /b 1
)

rem 처음 실행이면 설치부터 (예약 작업·바로가기는 만들지 않음)
if not exist "%EXE%" (
    echo 처음 실행합니다. 설치를 진행합니다. 몇 분 걸릴 수 있습니다...
    powershell -NoProfile -ExecutionPolicy Bypass -File "%APP%\install.ps1" -NoSchedule -NoShortcut
    if not exist "%EXE%" (
        echo [오류] 설치에 실패했습니다. 위 메시지를 확인하세요.
        pause
        exit /b 1
    )
)

rem 이미 켜져 있으면 브라우저만 연다
curl -s -o nul --max-time 2 "%URL%" >nul 2>&1
if not errorlevel 1 (
    echo SteelSignal 화면이 이미 실행 중입니다. 브라우저를 엽니다.
    if not defined SS_DRYRUN start "" "%URL%"
    exit /b 0
)

echo.
echo  SteelSignal 화면을 엽니다: %URL%
echo  이 창을 닫으면 화면이 종료됩니다. (실행 중에는 창을 최소화해 두세요)
echo.
if defined SS_DRYRUN (
    echo [DRYRUN] "%EXE%" --home "%APP%" ui
    exit /b 0
)
cd /d "%APP%"
"%EXE%" --home "%APP%" ui
if errorlevel 1 pause
