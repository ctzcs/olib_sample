@echo off
rem Usage: publish.bat [sample]   e.g. publish.bat net_fps
rem Release build without a console window into build\publish\<sample>\win-x64, plus a zip next to it.
rem Shaders are embedded with #load; the only runtime file is SDL3.dll from the Odin install.
setlocal
cd /d "%~dp0"
set SAMPLE=%~1
if "%SAMPLE%"=="" set SAMPLE=net_fps
if not exist ".\src\%SAMPLE%\main.odin" (
	echo Unknown sample: %SAMPLE%
	exit /b 1
)
set OUT=build\publish\%SAMPLE%\win-x64
if exist "%OUT%" rmdir /s /q "%OUT%"
mkdir "%OUT%"
odin build ".\src\%SAMPLE%" -collection:olib=..\olib -o:speed -subsystem:windows -out:"%OUT%\%SAMPLE%.exe"
if errorlevel 1 exit /b 1
for /f "delims=" %%R in ('odin root') do set "ODIN_DIR=%%R"
copy /y "%ODIN_DIR%\vendor\sdl3\SDL3.dll" "%OUT%\SDL3.dll" >nul
if errorlevel 1 exit /b 1
rem Voice codec libraries live in ..\olib\build (not in git); ship them when present.
for %%L in (opus.dll rnnoise.dll) do if exist "..\olib\build\%%L" copy /y "..\olib\build\%%L" "%OUT%\%%L" >nul
if exist ".\src\%SAMPLE%\PLAY.txt" copy /y ".\src\%SAMPLE%\PLAY.txt" "%OUT%\README.txt" >nul
powershell -NoProfile -Command "Compress-Archive -Path '%OUT%\*' -DestinationPath 'build\publish\%SAMPLE%-win-x64.zip' -Force"
if errorlevel 1 exit /b 1
echo Published: %OUT%
echo Zip:       build\publish\%SAMPLE%-win-x64.zip
exit /b 0
