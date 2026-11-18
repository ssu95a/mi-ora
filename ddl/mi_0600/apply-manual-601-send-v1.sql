-- One-time installation of manual MI_0600/601 send v1.
-- Run as the MI schema owner. Caller owns SQL*Plus transaction outcome.

WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK

PROMPT Creating MI_0600_SEND_ATTEMPT
@@tables/MI_0600_SEND_ATTEMPT.sql

PROMPT Compiling MI_mbus
@@../mbus/packages/MI_mbus.sql
SHOW ERRORS PACKAGE MI_mbus
SHOW ERRORS PACKAGE BODY MI_mbus

PROMPT Compiling MI_0600_Api
@@packages/MI_0600_Api.sql
SHOW ERRORS PACKAGE MI_0600_Api
SHOW ERRORS PACKAGE BODY MI_0600_Api

PROMPT Package compilation above is the definer-rights probe for
PROMPT CBSBUS_CORID, CBS_BUS queryBusClob/QUERY_RECEIVE and SYS.DBMS_LOCK.
PROMPT The installer performs no BUS call.

COMMIT

