@echo off
rem Opens the gate watcher in its own window and comes straight back.
rem
rem The window follows tools/pre-push.sh through a push: which stage it is on, how
rem long, the check count inside a Godot suite, and the verdict, with a beep either
rem way. It reads run/gate-status, which the gate rewrites at every step, so it can be
rem opened before the push, during it, or after, and it works whether the push was
rem typed here or made by a tool. Close it whenever; nothing depends on it.

start "SoundGraph gate" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0watch-gate.ps1"
