@echo off
rem Build and run the unit tests with dcc32 (Delphi 2009), headless (DUnit text runner).
rem Exit code is non-zero if the build or any test fails.
rem
rem Override BDS, INDY or JDO if your folders differ (see ..\build.cmd).
rem Set LEAKWATCH_FASTMM4=1 to test with FastMM4 instead of the built-in
rem memory manager.
setlocal
rem dcc32 resolves the "in" paths of the .dpr relative to the current folder
cd /d "%~dp0"
if "%BDS%"=="" set "BDS=C:\Program Files (x86)\CodeGear\RAD Studio\6.0"
if "%INDY%"=="" set "INDY=%~dp0..\..\Indy\Lib"
if "%JDO%"=="" set "JDO=%~dp0..\..\JsonDataObjects\Source"

set "OUT=%~dp0..\build\test"
if not exist "%OUT%\dcu" mkdir "%OUT%\dcu"
set "DEFINES="
if "%LEAKWATCH_FASTMM4%"=="1" set "DEFINES=-DLEAKWATCH_FASTMM4"

"%BDS%\bin\dcc32.exe" -B -Q %DEFINES% ^
  "-U%BDS%\lib;%~dp0;%~dp0..\src;%~dp0..\third_party\FastMM4;%INDY%\Core;%INDY%\Protocols;%INDY%\System;%JDO%" ^
  "-I%INDY%\Core;%INDY%\System" ^
  "-N0%OUT%\dcu" "-E%OUT%" "%~dp0LeakWatchTests.dpr"
if errorlevel 1 exit /b 1

rem -integration also runs the tests against a local RabbitMQ (localhost:15672)
"%OUT%\LeakWatchTests.exe" %*
exit /b %ERRORLEVEL%
