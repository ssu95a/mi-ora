PROMPT ============================================================
PROMPT Applying MI stored code
PROMPT ============================================================

/*
   Stored-code deployment manifest.

   Order is dependency-sensitive. Do not replace this manifest with an
   alphabetical directory scan. tools/apply-code.cmd verifies that every SQL
   source under packages, types, views and triggers is listed here.

   Table DDL is intentionally outside this deployment unit.
*/


PROMPT ------------------------------------------------------------
PROMPT Core utility packages
PROMPT ------------------------------------------------------------

@ddl/core/packages/MI_Utils.sql
SHOW ERRORS PACKAGE MI_Utils
SHOW ERRORS PACKAGE BODY MI_Utils

@ddl/core/packages/MI_ResultCtx.sql
SHOW ERRORS PACKAGE MI_ResultCtx
SHOW ERRORS PACKAGE BODY MI_ResultCtx

@ddl/core/packages/MI_Logger.sql
SHOW ERRORS PACKAGE MI_Logger
SHOW ERRORS PACKAGE BODY MI_Logger


PROMPT ------------------------------------------------------------
PROMPT SQL object types with stored methods
PROMPT ------------------------------------------------------------

@ddl/core/types/MI_Logger_T.sql
SHOW ERRORS TYPE MI_Logger_T
SHOW ERRORS TYPE BODY MI_Logger_T


PROMPT ------------------------------------------------------------
PROMPT Core business API packages
PROMPT ------------------------------------------------------------

@ddl/core/packages/MI_Request_Api.sql
SHOW ERRORS PACKAGE MI_Request_Api
SHOW ERRORS PACKAGE BODY MI_Request_Api

@ddl/core/packages/MI_Response_Api.sql
SHOW ERRORS PACKAGE MI_Response_Api
SHOW ERRORS PACKAGE BODY MI_Response_Api

@ddl/core/packages/MI_Person_Api.sql
SHOW ERRORS PACKAGE MI_Person_Api
SHOW ERRORS PACKAGE BODY MI_Person_Api

@ddl/core/packages/MI_Item_Result_Api.sql
SHOW ERRORS PACKAGE MI_Item_Result_Api
SHOW ERRORS PACKAGE BODY MI_Item_Result_Api


PROMPT ------------------------------------------------------------
PROMPT Business API packages
PROMPT ------------------------------------------------------------

@ddl/mi_0600/packages/MI_0600_Api.sql
SHOW ERRORS PACKAGE MI_0600_Api
SHOW ERRORS PACKAGE BODY MI_0600_Api

@ddl/mi_0600/packages/MI_0607_Api.sql
SHOW ERRORS PACKAGE MI_0607_Api
SHOW ERRORS PACKAGE BODY MI_0607_Api


PROMPT ------------------------------------------------------------
PROMPT Views
PROMPT ------------------------------------------------------------

@ddl/mi_0007/views/V_MI_0007.sql
SHOW ERRORS VIEW V_MI_0007


PROMPT ------------------------------------------------------------
PROMPT Triggers
PROMPT ------------------------------------------------------------

@ddl/mi_0600/triggers/T_AU_MI_REQ__0600_SENT.sql
SHOW ERRORS TRIGGER T_AU_MI_REQ__0600_SENT

PROMPT ============================================================
PROMPT MI stored code applied
PROMPT ============================================================
