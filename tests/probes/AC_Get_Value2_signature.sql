PROMPT ============================================================
PROMPT AC.GET_VALUE2 visible overloads and argument types
PROMPT ============================================================

COLUMN OWNER         FORMAT A20
COLUMN PACKAGE_NAME  FORMAT A20
COLUMN OBJECT_NAME   FORMAT A20
COLUMN OVERLOAD      FORMAT A8
COLUMN ARGUMENT_NAME FORMAT A24
COLUMN DATA_TYPE     FORMAT A20
COLUMN TYPE_OWNER    FORMAT A20
COLUMN TYPE_NAME     FORMAT A30
COLUMN TYPE_SUBNAME  FORMAT A30
COLUMN IN_OUT        FORMAT A10

SELECT OWNER,
       PACKAGE_NAME,
       OBJECT_NAME,
       OVERLOAD,
       POSITION,
       SEQUENCE,
       DATA_LEVEL,
       ARGUMENT_NAME,
       DATA_TYPE,
       TYPE_OWNER,
       TYPE_NAME,
       TYPE_SUBNAME,
       IN_OUT,
       DEFAULTED
  FROM ALL_ARGUMENTS
 WHERE (
          UPPER(PACKAGE_NAME) = 'AC'
      AND UPPER(OBJECT_NAME) = 'GET_VALUE2'
       )
    OR (
          UPPER(OWNER) = 'AC'
      AND PACKAGE_NAME IS NULL
      AND UPPER(OBJECT_NAME) = 'GET_VALUE2'
       )
 ORDER BY OWNER,
          SUBPROGRAM_ID,
          SEQUENCE;

PROMPT ============================================================
PROMPT End of AC.GET_VALUE2 signature probe
PROMPT ============================================================
