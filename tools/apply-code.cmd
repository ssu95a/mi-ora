@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem ---------------------------------------------------------------------------
rem Apply all MI stored code in dependency order.
rem
rem The manifest is explicit because package/type/view/trigger dependencies
rem cannot be derived safely from filenames. Before execution, this script
rem verifies that every SQL source in the stored-code directories is present
rem in the manifest.
rem
rem Usage:
rem   apply-code.cmd
rem ---------------------------------------------------------------------------

for %%I in ("%~dp0..") do set "MI_CODE_ROOT=%%~fI"
set "MI_CODE_MANIFEST=%MI_CODE_ROOT%\ddl\apply-code.sql"

if not exist "%MI_CODE_MANIFEST%" (
   echo ERROR: Stored-code manifest not found:
   echo   %MI_CODE_MANIFEST%
   exit /b 10
)

set /a MI_CODE_MISSING=0

for /r "%MI_CODE_ROOT%\ddl" %%F in (*.sql) do (
   set "MI_CODE_REL=%%~fF"
   set "MI_CODE_REL=!MI_CODE_REL:%MI_CODE_ROOT%\=!"
   set "MI_CODE_STORED="

   if not "!MI_CODE_REL:\packages\=!"=="!MI_CODE_REL!" set "MI_CODE_STORED=1"
   if not "!MI_CODE_REL:\types\=!"=="!MI_CODE_REL!" set "MI_CODE_STORED=1"
   if not "!MI_CODE_REL:\views\=!"=="!MI_CODE_REL!" set "MI_CODE_STORED=1"
   if not "!MI_CODE_REL:\triggers\=!"=="!MI_CODE_REL!" set "MI_CODE_STORED=1"

   if defined MI_CODE_STORED (
      set "MI_CODE_INCLUDE=@!MI_CODE_REL:\=/!"

      %SystemRoot%\System32\findstr.exe /i /l /x ^
         /c:"!MI_CODE_INCLUDE!" "%MI_CODE_MANIFEST%" >nul

      if errorlevel 1 (
         echo ERROR: Stored-code SQL file is missing from ddl\apply-code.sql:
         echo   !MI_CODE_REL!
         set /a MI_CODE_MISSING+=1
      )
   )
)

if not "%MI_CODE_MISSING%"=="0" (
   echo.
   echo ERROR: Stored-code manifest is incomplete. Missing files: %MI_CODE_MISSING%
   exit /b 11
)

echo ============================================================
echo Applying all MI stored code
echo Manifest: %MI_CODE_MANIFEST%
echo ============================================================
echo.

call "%~dp0apply-sql.cmd" "%MI_CODE_MANIFEST%"
exit /b %ERRORLEVEL%
