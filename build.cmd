@echo off
rem Build LeakWatch.exe with dcc32 (Delphi 2009) into build\.
rem
rem Override these if your folders differ:
rem   BDS   - Delphi 2009 root (contains bin\dcc32.exe and lib\)
rem   INDY  - Indy "Lib" folder (Core, Protocols, System)
rem   JDO   - JsonDataObjects "Source" folder
setlocal
rem dcc32 resolves the "in" paths of the .dpr relative to the current folder
cd /d "%~dp0"
if "%BDS%"=="" set "BDS=C:\Program Files (x86)\CodeGear\RAD Studio\6.0"
if "%INDY%"=="" set "INDY=%~dp0..\Indy\Lib"
if "%JDO%"=="" set "JDO=%~dp0..\JsonDataObjects\Source"

set "OUT=%~dp0build"
if not exist "%OUT%\dcu" mkdir "%OUT%\dcu"

"%BDS%\bin\dcc32.exe" -B -Q ^
  "-U%BDS%\lib;%~dp0src;%~dp0third_party\FastMM4;%INDY%\Core;%INDY%\Protocols;%INDY%\System;%JDO%" ^
  "-I%INDY%\Core;%INDY%\System" ^
  "-N0%OUT%\dcu" "-E%OUT%" "%~dp0LeakWatch.dpr"
exit /b %ERRORLEVEL%
