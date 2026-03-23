@echo off

mkdir ..\..\build
pushd ..\..\build
odin build ..\handmade\code -debug -o:none -out:handmade.exe -pdb-name:handmade.pdb
popd
