SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK ON
SET VERIFY OFF

PROMPT ============================================================
PROMPT MI_0606_Api.send_Document safe smoke test
PROMPT No valid OUTFILE_ID is sent to Multi-Bus
PROMPT ============================================================

DECLARE
   l_req_id           NUMBER;
   l_ret_code         NUMBER;
   l_ret_info         VARCHAR2(4000);
   l_argument_cnt     PLS_INTEGER;
   l_send_call_cnt    PLS_INTEGER;
   l_side_effect_cnt  PLS_INTEGER;
   l_validation_line  PLS_INTEGER;
   l_send_line        PLS_INTEGER;
   l_proc_end_line    PLS_INTEGER;


   PROCEDURE fail (
      p_message IN VARCHAR2
   )
   IS
   BEGIN
      RAISE_APPLICATION_ERROR(
         -20990,
         'MI_0606_Api.send_Document smoke test failed: ' || p_message
      );
   END fail;


   PROCEDURE assert_True (
      p_condition IN BOOLEAN,
      p_message   IN VARCHAR2
   )
   IS
   BEGIN
      IF p_condition IS NULL OR NOT p_condition THEN
         fail(p_message);
      END IF;
   END assert_True;


   PROCEDURE assert_Invalid_Outfile_Id (
      p_outfile_id  IN NUMBER,
      p_label       IN VARCHAR2
   )
   IS
   BEGIN
      MI_0606_Api.send_Document(
         p_outfile_id => p_outfile_id,
         p_req_id     => l_req_id,
         p_ret_code   => l_ret_code,
         p_ret_info   => l_ret_info
      );

      assert_True(
         l_req_id IS NULL,
         p_label || ' returned req_id=' || TO_CHAR(l_req_id, 'TM9')
      );

      assert_True(
         l_ret_code = MI_0606_Api.RET_FAIL,
         p_label || ' ret_code=' || NVL(TO_CHAR(l_ret_code), '<NULL>')
      );

      assert_True(
         INSTR(
            NVL(l_ret_info, '<NULL>'),
            'MI_0606_SEND_DOCUMENT_INVALID_OUTFILE_ID'
         ) = 1,
         p_label || ' ret_info=' || NVL(l_ret_info, '<NULL>')
      );
   END assert_Invalid_Outfile_Id;


BEGIN
   DBMS_OUTPUT.put_line('1. exact scalar JDBC ABI');

   SELECT COUNT(*)
     INTO l_argument_cnt
     FROM USER_ARGUMENTS
    WHERE PACKAGE_NAME = 'MI_0606_API'
      AND OBJECT_NAME = 'SEND_DOCUMENT'
      AND DATA_LEVEL = 0
      AND (
            (POSITION = 1
             AND ARGUMENT_NAME = 'P_OUTFILE_ID'
             AND IN_OUT = 'IN'
             AND DATA_TYPE = 'NUMBER')
         OR (POSITION = 2
             AND ARGUMENT_NAME = 'P_REQ_ID'
             AND IN_OUT = 'OUT'
             AND DATA_TYPE = 'NUMBER')
         OR (POSITION = 3
             AND ARGUMENT_NAME = 'P_RET_CODE'
             AND IN_OUT = 'OUT'
             AND DATA_TYPE = 'NUMBER')
         OR (POSITION = 4
             AND ARGUMENT_NAME = 'P_RET_INFO'
             AND IN_OUT = 'OUT'
             AND DATA_TYPE = 'VARCHAR2')
          );

   assert_True(
      l_argument_cnt = 4,
      'unexpected scalar ABI argument count=' || l_argument_cnt
   );

   SELECT COUNT(*)
     INTO l_argument_cnt
     FROM USER_ARGUMENTS
    WHERE PACKAGE_NAME = 'MI_0606_API'
      AND OBJECT_NAME = 'SEND_DOCUMENT'
      AND DATA_LEVEL = 0;

   assert_True(
      l_argument_cnt = 4,
      'send_Document has extra arguments; count=' || l_argument_cnt
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('2. invalid identifiers are rejected before transport');

   assert_Invalid_Outfile_Id(NULL, 'NULL');
   assert_Invalid_Outfile_Id(0, 'zero');
   assert_Invalid_Outfile_Id(-1, 'negative');
   assert_Invalid_Outfile_Id(1.5, 'fractional');

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('3. facade contains exactly one Multi-Bus call');

   SELECT COUNT(*), MIN(LINE)
     INTO l_send_call_cnt, l_send_line
     FROM USER_SOURCE
    WHERE NAME = 'MI_0606_API'
      AND TYPE = 'PACKAGE BODY'
      AND UPPER(TEXT) LIKE '%MI_MBUS.SEND_COMMAND(%';

   assert_True(
      l_send_call_cnt = 1,
      'Multi-Bus call count=' || l_send_call_cnt
   );

   SELECT MIN(LINE)
     INTO l_validation_line
     FROM USER_SOURCE
    WHERE NAME = 'MI_0606_API'
      AND TYPE = 'PACKAGE BODY'
      AND UPPER(TEXT) LIKE '%P_OUTFILE_ID IS NULL%';

   assert_True(
      l_validation_line IS NOT NULL
      AND l_validation_line < l_send_line,
      'OUTFILE_ID validation is not before the Multi-Bus call'
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('4. facade has no SQL DML or transaction control');

   SELECT MIN(LINE)
     INTO l_proc_end_line
     FROM USER_SOURCE
    WHERE NAME = 'MI_0606_API'
      AND TYPE = 'PACKAGE BODY'
      AND LINE > l_send_line
      AND REGEXP_LIKE(TEXT, '^[[:space:]]*END[[:space:]]+SEND_DOCUMENT[[:space:]]*;[[:space:]]*$', 'i');

   SELECT COUNT(*)
     INTO l_side_effect_cnt
     FROM USER_SOURCE
    WHERE NAME = 'MI_0606_API'
      AND TYPE = 'PACKAGE BODY'
      AND LINE BETWEEN l_validation_line AND l_proc_end_line
      AND REGEXP_LIKE(
             UPPER(TEXT),
             '(^|[^A-Z_])(INSERT|UPDATE|DELETE|MERGE|COMMIT|ROLLBACK)([^A-Z_]|$)'
          );

   assert_True(
      l_proc_end_line IS NOT NULL,
      'send_Document procedure end was not found'
   );

   assert_True(
      l_side_effect_cnt = 0,
      'facade contains DML or transaction control; count='
      || l_side_effect_cnt
   );

   DBMS_OUTPUT.put_line('   OK');
   DBMS_OUTPUT.put_line('MI_0606_Api.send_Document safe smoke test passed');
END;
/
