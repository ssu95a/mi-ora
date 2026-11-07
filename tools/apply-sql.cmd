@echo off
setlocal EnableExtensions

rem ---------------------------------------------------------------------------
rem Apply any SQL file with SQL*Plus.
rem
rem Usage:
rem   apply-sql.cmd <sql-file> [user@connect]
rem
rem Connection may also be supplied through MI_ORA_CONNECT:
rem   set MI_ORA_CONNECT=XXI@MYDB
rem   apply-sql.cmd ..\ddl\core\packages\MI_Utils.sql
rem
rem Password is intentionally not accepted separately; SQL*Plus will prompt
rem unless it is already embedded in the connect string.
rem ---------------------------------------------------------------------------

if "%~1"=="" goto :usage

where sqlplus >nul 2>&1
if errorlevel 1 (
   echo ERROR: sqlplus.exe not found in PATH.
   exit /b 2
)

set "SQL_FILE=%~f1"

if not exist "%SQL_FILE%" (
   echo ERROR: SQL file not found:
   echo   %SQL_FILE%
   exit /b 3
)

set "DB_CONNECT=%~2"

if "%DB_CONNECT%"=="" set "DB_CONNECT=%MI_ORA_CONNECT%"

if "%DB_CONNECT%"=="" (
   echo ERROR: Oracle connection is not specified.
   echo.
   echo Pass it as the second argument:
   echo   apply-sql.cmd file.sql XXI@MYDB
   echo.
   echo or set:
   echo   set MI_ORA_CONNECT=XXI@MYDB
   exit /b 4
)

rem Repository SQL files are UTF-8. Tell the Oracle client the input charset.
set "NLS_LANG=.AL32UTF8"

rem SQL*Plus writes UTF-8 to the console when NLS_LANG uses AL32UTF8.
rem Switch cmd.exe to UTF-8 as well, otherwise Russian text is displayed
rem as mojibake (for example: ╨б╨┐╨╕...).
for /f "tokens=2 delims=:" %%A in ('chcp') do set "OLD_CP=%%A"
set "OLD_CP=%OLD_CP: =%"
chcp 65001 >nul

set "RUNNER=%TEMP%\mi-ora-sqlplus-%RANDOM%-%RANDOM%.sql"

(
   echo WHENEVER OSERROR EXIT FAILURE ROLLBACK
   echo WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK
   echo.
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
   echo PROMPT ============================================================
   echo PROMPT Applying SQL file:
   echo PROMPT %SQL_FILE%
   echo PROMPT ============================================================
   echo.
   echo @"%SQL_FILE%"
   echo.
   echo SHOW ERRORS
   echo.
   echo PROMPT ============================================================
   echo PROMPT SQL file applied successfully
   echo PROMPT ============================================================
   echo.
   echo EXIT SUCCESS
) > "%RUNNER%"

sqlplus -L "%DB_CONNECT%" @"%RUNNER%"
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
echo   apply-sql.cmd ^<sql-file^> [user@connect]
echo.
echo Examples:
echo   apply-sql.cmd ddl\core\packages\MI_Utils.sql XXI@MYDB
echo.
echo   set MI_ORA_CONNECT=XXI@MYDB
echo   apply-sql.cmd ddl\core\packages\MI_ResultCtx.sql
exit /b 1
