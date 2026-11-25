@echo off
setlocal EnableExtensions

rem ---------------------------------------------------------------------------
rem Apply the complete repeatable MI stored-code deployment unit.
rem
rem This wrapper is intended for the integrated Oracle baseline. It refuses to
rem run from an older feature branch that does not contain the approved 0202,
rem transaction/result helpers and 0607 sources.
rem
rem One-time table DDL is intentionally excluded. Existing CREATE TABLE scripts
rem are not idempotent and must not be executed during a stored-code refresh.
rem
rem Usage:
rem   tools\apply-all.cmd
rem ---------------------------------------------------------------------------

for %%I in ("%~dp0..") do set "MI_REPO_ROOT=%%~fI"

for %%F in (
   "ddl\core\packages\MI_Transaction.sql"
   "ddl\core\packages\MI_Request_Sup.sql"
   "ddl\mi_0202\packages\MI_0202_Api.sql"
   "ddl\mi_0600\packages\MI_0607_Api.sql"
) do (
   if not exist "%MI_REPO_ROOT%\%%~F" (
      echo ERROR: Integrated deployment source is missing:
      echo   %%~F
      echo.
      echo Run this script only from the approved integration branch.
      exit /b 12
   )
)

echo ============================================================
echo Applying complete repeatable MI stored code
echo Repository: %MI_REPO_ROOT%
echo ============================================================
echo.

call "%~dp0apply-code.cmd"
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
   echo.
   echo ============================================================
   echo MI stored-code deployment FAILED, RC=%RC%
   echo ============================================================
   exit /b %RC%
)

echo.
echo ============================================================
echo Complete repeatable MI stored code applied successfully
echo One-time table DDL was not executed
echo ============================================================

exit /b 0
