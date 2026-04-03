@echo off

mkdir ..\..\build
pushd ..\..\build
odin build ..\handmade\code -strict-style -define:HANDMADE_INTERNAL=true -debug -o:none -out:handmade.exe -pdb-name:handmade.pdb
popd
