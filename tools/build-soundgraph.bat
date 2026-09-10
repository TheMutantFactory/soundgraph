@echo off
rem Builds SoundGraph without launching it: the Godot extensions, and the native tools
rem and tests on request.
rem
rem test-soundgraph-godot.bat builds and then opens the editor, which is right when you
rem want to look and wrong when you only want to know it compiles -- before a push, on a
rem machine with no screen, or to hand a fresh DLL to run-demo.bat, which never builds.
rem
rem   (no option)   both extensions, the desktop DLL and the wasm -- what the gate expects
rem   --desktop     the desktop DLL only, without the emsdk environment
rem   --native      the native build too: sg-render, sg-validate, the C++ tests
rem
rem Git Bash is found the way the launcher finds it, from git's own install.

setlocal enabledelayedexpansion
set "REPO=%~dp0.."

set "EXT_ARGS="
set "NATIVE="
:parse
if "%~1"=="" goto resolved
if /I "%~1"=="--desktop" (
    set "EXT_ARGS=--desktop"
) else if /I "%~1"=="--native" (
    set "NATIVE=1"
) else (
    echo unknown option: %~1
    echo   build-soundgraph.bat [--desktop] [--native]
    exit /b 1
)
shift
goto parse
:resolved

set "BASH="
for /f "usebackq delims=" %%G in (`where git 2^>nul`) do (
    if not defined BASH if exist "%%~dpG..\bin\bash.exe" set "BASH=%%~dpG..\bin\bash.exe"
)
if not defined BASH (
    where bash >nul 2>&1
    if not errorlevel 1 set "BASH=bash"
)
if not defined BASH (
    echo Git Bash not found; run tools/rebuild-extensions.sh from Git Bash instead.
    exit /b 1
)

"%BASH%" "%REPO%\tools\rebuild-extensions.sh" %EXT_ARGS%
if errorlevel 1 (
    echo.
    echo The extension build failed.
    exit /b 1
)

if not defined NATIVE goto done

rem The native build wants the Visual Studio environment; vswhere says where it is.
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
set "VSROOT="
if exist "%VSWHERE%" (
    for /f "usebackq delims=" %%G in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSROOT=%%G"
)
if not defined VSROOT (
    echo No Visual Studio with the C++ tools was found, so the native build was skipped.
    exit /b 1
)
call "%VSROOT%\VC\Auxiliary\Build\vcvars64.bat" >nul
cmake --build "%REPO%\build"
if errorlevel 1 (
    echo.
    echo The native build failed.
    exit /b 1
)

:done
echo.
echo Built. Nothing was launched.
