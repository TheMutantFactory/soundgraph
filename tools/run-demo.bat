@echo off
rem Restarts the demo: the SoundGraph editor, in 1:1 detail, without rebuilding.
rem
rem For the show floor. test-soundgraph-godot.bat rebuilds before it launches, which
rem is right at a desk and wrong in front of a queue -- a restart must take seconds
rem and must not depend on a compiler. This launches whatever is already built, and
rem tells the editor to start in 1:1 so every control is on every node however far
rem out the graph is zoomed, at the 4K interface size, with the work area held at 200%
rem after every load - twice the words on the nodes - whatever the last hand at the
rem laptop left behind.
rem
rem Anything else on the command line is passed through to the editor after its own
rem arguments, so a patch or a further --detail= can follow.
rem
rem The Godot binary comes from git config, the same place every other tool reads it:
rem
rem   git config soundgraph.godot "C:/path/to/Godot_console.exe"

setlocal
set "REPO=%~dp0.."

for /f "usebackq delims=" %%G in (`git -C "%REPO%" config --get soundgraph.godot`) do set "GODOT=%%G"

if "%GODOT%"=="" (
    echo soundgraph.godot is not configured. Set it with:
    echo   git config soundgraph.godot "C:/path/to/Godot_console.exe"
    exit /b 1
)

if not exist "%GODOT%" (
    echo Configured Godot binary not found: %GODOT%
    exit /b 1
)

if not exist "%REPO%\editor-godot\bin\soundgraph_godot.dll" (
    echo The extension has never been built here. Run tools\test-soundgraph-godot.bat once,
    echo at a desk, before demo day.
    exit /b 1
)

"%GODOT%" --path "%REPO%\editor-godot" -- --detail=1:1 --size=4k --zoom=2 %*
