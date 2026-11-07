@echo off
setlocal EnableExtensions

rem ---------------------------------------------------------------------------
rem Generates Oracle MERGE DML for MI_WSP / MI_INF from PostgreSQL.
rem
rem Output:
rem   <repo-root>\mi-wsp-inf.oracle.sql
rem
rem PostgreSQL connection:
rem   - with no arguments, psql uses standard libpq environment/defaults
rem     (PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD/.pgpass);
rem   - optional first argument may be a psql connection string.
rem     Prefer .pgpass instead of putting a password on the command line.
rem ---------------------------------------------------------------------------

set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..\..") do set "REPO_ROOT=%%~fI"

set "SQL_FILE=%SCRIPT_DIR%export-mi-wsp-inf.pg.sql"
set "OUT_FILE=%REPO_ROOT%\mi-wsp-inf.oracle.sql"
set "TMP_FILE=%OUT_FILE%.tmp"

if not exist "%SQL_FILE%" (
   echo ERROR: generator SQL not found:
   echo   %SQL_FILE%
   exit /b 8
)

where psql >nul 2>&1
if errorlevel 1 (
   echo ERROR: psql.exe not found in PATH.
   exit /b 8
)

del /q "%TMP_FILE%" >nul 2>&1

echo ============================================================
echo PostgreSQL -^> Oracle core data generator
echo SQL:    %SQL_FILE%
echo Output: %OUT_FILE%
echo ============================================================

if "%~1"=="" (
   psql -X -v ON_ERROR_STOP=1 -f "%SQL_FILE%" > "%TMP_FILE%"
) else (
   psql "%~1" -X -v ON_ERROR_STOP=1 -f "%SQL_FILE%" > "%TMP_FILE%"
)

set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
   del /q "%TMP_FILE%" >nul 2>&1
   echo.
   echo ERROR: PostgreSQL export failed. Output file was not replaced.
   exit /b %RC%
)

move /Y "%TMP_FILE%" "%OUT_FILE%" >nul
if errorlevel 1 (
   echo ERROR: cannot move generated file to:
   echo   %OUT_FILE%
   exit /b 8
)

for %%I in ("%OUT_FILE%") do (
   echo.
   echo Oracle SQL generated successfully:
   echo   %%~fI
   echo   %%~zI bytes
)

exit /b 0
