PROMPT ============================================================
PROMPT Applying MI_Logger_T context contract
PROMPT ============================================================

/*
   Replacing a SQL object type invalidates dependent PL/SQL units. Keep the
   type and all current package users in one apply unit so the post-apply
   INVALID-object check sees a consistent schema.
*/

@ddl/core/types/MI_Logger_T.sql
SHOW ERRORS TYPE MI_Logger_T
SHOW ERRORS TYPE BODY MI_Logger_T

@ddl/core/packages/MI_Request_Api.sql
SHOW ERRORS PACKAGE MI_Request_Api
SHOW ERRORS PACKAGE BODY MI_Request_Api

@ddl/core/packages/MI_Person_Api.sql
SHOW ERRORS PACKAGE MI_Person_Api
SHOW ERRORS PACKAGE BODY MI_Person_Api

@ddl/core/packages/MI_Item_Result_Api.sql
SHOW ERRORS PACKAGE MI_Item_Result_Api
SHOW ERRORS PACKAGE BODY MI_Item_Result_Api

PROMPT ============================================================
PROMPT MI_Logger_T context contract applied
PROMPT ============================================================
