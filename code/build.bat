@echo off

mkdir ..\..\build
pushd ..\..\build
odin build ..\handmade\code\game -strict-style -define:HANDMADE_INTERNAL=true -debug -build-mode:dll -out:game.dll -pdb-name:game_%RANDOM%.pdb
rem If handmade.exe already running: Then only compile game.dll and exit cleanly
set EXE=handmade.exe
FOR /F %%x IN ('tasklist /NH /FI "IMAGENAME eq %EXE%"') DO IF %%x == %EXE% exit /b 0 
odin build ..\handmade\code\main -strict-style -define:HANDMADE_INTERNAL=true -debug -out:handmade.exe -pdb-name:handmade_%RANDOM%.pdb
popd
