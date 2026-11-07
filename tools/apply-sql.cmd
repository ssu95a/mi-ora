@echo off
setlocal EnableExtensions

rem ---------------------------------------------------------------------------
rem Apply any SQL file with SQL*Plus.
rem
rem Usage:
rem   apply-sql.cmd <sql-file>
rem
rem Connection settings are read from:
rem   1) file specified by MI_ORA_ENV
rem   2) tools\oracle.env
rem
rem oracle.env format:
rem   ORA_USER=XXI
rem   ORA_PASSWORD=secret
rem   ORA_SID=DEV8I
rem
rem ORA_SID is the TNS alias used after "@", for example DEV8I.
rem ---------------------------------------------------------------------------

if "%~1"=="" goto :usage

set "SQL_FILE=%~f1"

if not exist "%SQL_FILE%" (
   echo ERROR: SQL file not found:
   echo   %SQL_FILE%
   exit /b 3
)

rem ---------------------------------------------------------------------------
rem Load local Oracle environment.
rem ---------------------------------------------------------------------------
set "ENV_FILE=%MI_ORA_ENV%"
if "%ENV_FILE%"=="" set "ENV_FILE=%~dp0oracle.env"

if not exist "%ENV_FILE%" (
   echo ERROR: Oracle environment file not found:
   echo   %ENV_FILE%
   echo.
   echo Create tools\oracle.env from tools\oracle.env.example
   echo or set MI_ORA_ENV to another file.
   exit /b 4
)

for /f "usebackq eol=# tokens=1,* delims==" %%A in ("%ENV_FILE%") do (
   if /I "%%A"=="ORA_USER"        set "ORA_USER=%%B"
   if /I "%%A"=="ORA_PASSWORD"    set "ORA_PASSWORD=%%B"
   if /I "%%A"=="ORA_SID"         set "ORA_SID=%%B"
   if /I "%%A"=="ORA_TNS_ADMIN"   set "TNS_ADMIN=%%B"
   if /I "%%A"=="ORACLE_IC_HOME"  set "ORACLE_IC_HOME=%%B"
   if /I "%%A"=="ORA_NLS_LANG"    set "NLS_LANG=%%B"
)

if "%ORA_USER%"=="" (
   echo ERROR: ORA_USER is not set in:
   echo   %ENV_FILE%
   exit /b 5
)

if "%ORA_PASSWORD%"=="" (
   echo ERROR: ORA_PASSWORD is not set in:
   echo   %ENV_FILE%
   exit /b 6
)

if "%ORA_SID%"=="" (
   echo ERROR: ORA_SID is not set in:
   echo   %ENV_FILE%
   exit /b 7
)

rem Repository SQL files are UTF-8.
if "%NLS_LANG%"=="" set "NLS_LANG=.AL32UTF8"

rem Prefer explicitly configured Instant Client, otherwise use PATH.
if not "%ORACLE_IC_HOME%"=="" (
   set "SQLPLUS=%ORACLE_IC_HOME%\sqlplus.exe"
) else (
   set "SQLPLUS=sqlplus.exe"
)

if not "%ORACLE_IC_HOME%"=="" (
   if not exist "%SQLPLUS%" (
      echo ERROR: sqlplus.exe not found:
      echo   %SQLPLUS%
      exit /b 8
   )
) else (
   where sqlplus >nul 2>&1
   if errorlevel 1 (
      echo ERROR: sqlplus.exe not found in PATH.
      echo Set ORACLE_IC_HOME in oracle.env.
      exit /b 8
   )
)

rem SQL*Plus writes UTF-8 to the console when NLS_LANG uses AL32UTF8.
rem Switch cmd.exe to UTF-8 and restore the old code page afterwards.
for /f "tokens=2 delims=:" %%A in ('chcp') do set "OLD_CP=%%A"
set "OLD_CP=%OLD_CP: =%"
chcp 65001 >nul

set "RUNNER=%TEMP%\mi-ora-sqlplus-%RANDOM%-%RANDOM%.sql"

rem Password is written only to the temporary runner, never passed on the
rem command line. ECHO is disabled for CONNECT so the password is not printed.
(
   echo WHENEVER OSERROR EXIT FAILURE ROLLBACK
   echo WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK
   echo.
   echo SET ECHO OFF
   echo CONNECT %ORA_USER%/"%ORA_PASSWORD%"@%ORA_SID%
   echo SET ECHO ON
   echo SET FEEDBACK ON
   echo SET HEADING ON
   echo SET SERVEROUTPUT ON SIZE UNLIMITED
   echo SET SQLBLANKLINES ON
   echo SET VERIFY OFF
   echo SET TIMING ON
   echo SET LINESIZE 250
   echo SET PAGESIZE 100
   echo.
   echo COLUMN MI_RUN_STARTED NEW_VALUE MI_RUN_STARTED NOPRINT
   echo SELECT TO_CHAR^(SYSDATE, 'YYYYMMDDHH24MISS'^) MI_RUN_STARTED FROM dual;
   echo.
   echo PROMPT ============================================================
   echo PROMPT Applying SQL file:
   echo PROMPT %SQL_FILE%
   echo PROMPT Oracle alias: %ORA_SID%
   echo PROMPT Oracle user:  %ORA_USER%
   echo PROMPT ============================================================
   echo.
   echo @"%SQL_FILE%"
   echo.
   echo SHOW ERRORS
   echo.
   echo DECLARE
   echo    l_count PLS_INTEGER;
   echo BEGIN
   echo    SELECT COUNT^(*^)
   echo      INTO l_count
   echo      FROM USER_OBJECTS o
   echo     WHERE o.status = 'INVALID'
   echo       AND o.last_ddl_time ^>= TO_DATE^('&&MI_RUN_STARTED', 'YYYYMMDDHH24MISS'^)
   echo       AND EXISTS ^(
   echo              SELECT 1
   echo                FROM USER_ERRORS e
   echo               WHERE e.name = o.object_name
   echo                 AND e.type = o.object_type
   echo           ^);
   echo.
   echo    IF l_count ^> 0 THEN
   echo       FOR r IN ^(
   echo          SELECT o.object_name, o.object_type
   echo            FROM USER_OBJECTS o
   echo           WHERE o.status = 'INVALID'
   echo             AND o.last_ddl_time ^>= TO_DATE^('&&MI_RUN_STARTED', 'YYYYMMDDHH24MISS'^)
   echo             AND EXISTS ^(
   echo                    SELECT 1
   echo                      FROM USER_ERRORS e
   echo                     WHERE e.name = o.object_name
   echo                       AND e.type = o.object_type
   echo                 ^)
   echo           ORDER BY o.object_name, o.object_type
   echo       ^) LOOP
   echo          DBMS_OUTPUT.PUT_LINE^('INVALID: ' ^|^| r.object_name ^|^| ' [' ^|^| r.object_type ^|^| ']'^);
   echo       END LOOP;
   echo.
   echo       RAISE_APPLICATION_ERROR^(
   echo          -20001,
   echo          'SQL file created or compiled INVALID objects: ' ^|^| l_count
   echo       ^);
   echo    END IF;
   echo END;
   echo /
   echo.
   echo PROMPT ============================================================
   echo PROMPT SQL file applied successfully
   echo PROMPT ============================================================
   echo.
   echo EXIT SUCCESS
) > "%RUNNER%"

"%SQLPLUS%" -L /nolog @"%RUNNER%"
set "RC=%ERRORLEVEL%"

del /q "%RUNNER%" >nul 2>&1

if defined OLD_CP chcp %OLD_CP% >nul

if not "%RC%"=="0" (
   echo.
   echo ============================================================
   echo SQL*Plus FAILED, RC=%RC%
   echo ============================================================
   exit /b %RC%
)

echo.
echo ============================================================
echo SQL*Plus SUCCESS
echo ============================================================

exit /b 0


:usage
echo Usage:
echo   apply-sql.cmd ^<sql-file^>
echo.
echo Configuration:
echo   tools\oracle.env
echo.
echo Optional:
echo   set MI_ORA_ENV=D:\private\mi-ora.env
echo.
echo Example:
echo   apply-sql.cmd tests\smoke\MI_ResultCtx_smoke.sql
exit /b 1
