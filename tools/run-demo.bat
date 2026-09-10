@echo off
rem Restarts the demo: the SoundGraph editor, in 1:1 detail, without rebuilding.
rem
rem For the show floor. test-soundgraph-godot.bat rebuilds before it launches, which
rem is right at a desk and wrong in front of a queue -- a restart must take seconds
rem and must not depend on a compiler. This launches whatever is already built, and
rem tells the editor to start in 1:1 so every control is on every node however far
rem out the graph is zoomed, at the 4K interface size - whose work area draws its
rem words and cells at twice the chrome - whatever the last hand at the laptop left
rem behind. Add --zoom=2 for twice that again, nodes and all.
rem
rem Full screen, through Godot's own switch (it goes before the --, where the engine
rem reads its options; everything after the -- is the editor's). Alt+Enter is not a
rem thing a queue should watch somebody remember.
rem
rem Anything else on the command line is passed through to the editor after its own
rem arguments, so a patch or a further --detail= can follow. Quit is on the hamburger
rem and on Ctrl+Q, so a full screen with no title bar still has a way out.
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

rem The plain binary beside the console one, when it is there. The console flavour is a
rem wrapper: it starts the real editor as a child and pipes its output to the terminal,
rem which is what the gate wants and what a show does not -- a second window, and an
rem editor that comes up behind the terminal because a grandchild is not owed the front.
set "GUI=%GODOT:_console.exe=.exe%"
if exist "%GUI%" set "GODOT=%GUI%"

rem The terminal goes down before the editor comes up. Whatever window this was typed
rem into is the one in front right now; it is minimised, not closed, so the output and
rem the prompt are still there when the show is over.
powershell -NoProfile -Command "$q = [char]34; $w = Add-Type -Name Win -Namespace Demo -PassThru -MemberDefinition ('[DllImport(' + $q + 'user32.dll' + $q + ')] public static extern IntPtr GetForegroundWindow(); [DllImport(' + $q + 'user32.dll' + $q + ')] public static extern bool ShowWindow(IntPtr h, int n);'); [void]$w::ShowWindow($w::GetForegroundWindow(), 6)" >nul 2>&1

"%GODOT%" --path "%REPO%\editor-godot" --fullscreen -- --detail=1:1 --size=4k --arrange --case=168 %*
