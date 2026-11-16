SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK ON
SET VERIFY OFF

PROMPT ============================================================
PROMPT MI_0606_Api smoke test
PROMPT ============================================================

DECLARE
   l_error_result  MI_ResultCtx.exec_Result_t;

   l_req_id        MI_REQ.REQ_ID%TYPE;
   l_itm_id        MI_0600.ITM_ID%TYPE;
   l_missing_id    MI_REQ.REQ_ID%TYPE;

   l_task_id       VARCHAR2(4000);
   l_doc_key       VARCHAR2(4000);
   l_doc_type      VARCHAR2(4000);
   l_error_code    VARCHAR2(4000);
   l_file_name     VARCHAR2(4000);
   l_file_body     BLOB;

   l_ret_code      NUMBER;
   l_ret_info      VARCHAR2(4000);
   l_argument_cnt  PLS_INTEGER;
   l_source_cnt    PLS_INTEGER;


   PROCEDURE fail (
      p_message IN VARCHAR2
   )
   IS
   BEGIN
      RAISE_APPLICATION_ERROR(
         -20990,
         'MI_0606_Api smoke test failed: ' || p_message
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


BEGIN
   DBMS_OUTPUT.put_line('1. package version');

   assert_True(
      MI_0606_Api.get_Version IS NOT NULL,
      'get_Version returned NULL'
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('2. capture JDBC boundary contains four OUT arguments');

   SELECT COUNT(*)
     INTO l_argument_cnt
     FROM USER_ARGUMENTS
    WHERE PACKAGE_NAME = 'MI_0606_API'
      AND OBJECT_NAME = 'CAPTURE_PENDING'
      AND DATA_LEVEL = 0
      AND IN_OUT = 'OUT'
      AND ARGUMENT_NAME IN (
             'P_CAPTURED_COUNT',
             'P_SKIPPED_COUNT',
             'P_RET_CODE',
             'P_RET_INFO'
          );

   assert_True(
      l_argument_cnt = 4,
      'capture_Pending JDBC OUT contract is incomplete; count='
      || l_argument_cnt
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('3. NULL source id returns RET_NO_DATA');

   MI_0606_Api.create_Request(
      p_outfile_id => NULL,
      p_req_id     => l_req_id,
      p_itm_id     => l_itm_id,
      p_ret_code   => l_ret_code,
      p_ret_info   => l_ret_info
   );

   assert_True(
      l_ret_code = MI_0606_Api.RET_NO_DATA,
      'NULL source id ret_code=' || NVL(TO_CHAR(l_ret_code), '<NULL>')
   );

   assert_True(
      l_req_id IS NULL AND l_itm_id IS NULL,
      'NULL source id returned request/item identity'
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('4. missing request returns RET_NO_DATA');

   SELECT NVL(MIN(REQ_ID), 0) - 1
     INTO l_missing_id
     FROM MI_REQ;

   MI_0606_Api.prepare_Send_Document(
      p_req_id     => l_missing_id,
      p_task_id    => l_task_id,
      p_doc_key    => l_doc_key,
      p_doc_type   => l_doc_type,
      p_error_code => l_error_code,
      p_file_name  => l_file_name,
      p_file_body  => l_file_body,
      p_ret_code   => l_ret_code,
      p_ret_info   => l_ret_info
   );

   assert_True(
      l_ret_code = MI_0606_Api.RET_NO_DATA,
      'missing request ret_code=' || NVL(TO_CHAR(l_ret_code), '<NULL>')
   );

   assert_True(
      l_task_id IS NULL
      AND l_doc_key IS NULL
      AND l_doc_type IS NULL
      AND l_error_code IS NULL
      AND l_file_name IS NULL
      AND l_file_body IS NULL,
      'missing request returned SEND_DOCUMENT data'
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('5. invalid protocol input raises named technical error');

   MI_ResultCtx.clear_Current;

   BEGIN
      MI_0606_Api.apply_Document_Status(
         p_message_uuid  => 'not-a-uuid',
         p_doc_key       => MI_Utils.uuid_V7,
         p_state         => 'PROCESSED',
         p_message       => NULL,
         p_response_time => SYSTIMESTAMP,
         p_req_id        => l_req_id,
         p_itm_id        => l_itm_id,
         p_ret_code      => l_ret_code,
         p_ret_info      => l_ret_info
      );

      fail('invalid message UUID was accepted');

   EXCEPTION
      WHEN MI_ResultCtx.result_Failed_Exc THEN
         l_error_result := MI_ResultCtx.current_Result;

         assert_True(
            l_error_result.result_code = 'MI_0606_INVALID_MESSAGE_UUID',
            'unexpected validation result_code='
            || NVL(l_error_result.result_code, '<NULL>')
         );
   END;

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('6. NULL DOCUMENT_STATUS state is rejected');

   MI_ResultCtx.clear_Current;

   BEGIN
      MI_0606_Api.apply_Document_Status(
         p_message_uuid  => MI_Utils.uuid_V7,
         p_doc_key       => MI_Utils.uuid_V7,
         p_state         => NULL,
         p_message       => NULL,
         p_response_time => SYSTIMESTAMP,
         p_req_id        => l_req_id,
         p_itm_id        => l_itm_id,
         p_ret_code      => l_ret_code,
         p_ret_info      => l_ret_info
      );

      fail('NULL DOCUMENT_STATUS state was accepted');

   EXCEPTION
      WHEN MI_ResultCtx.result_Failed_Exc THEN
         l_error_result := MI_ResultCtx.current_Result;

         assert_True(
            l_error_result.result_code =
               'MI_0606_UNSUPPORTED_DOCUMENT_STATE',
            'unexpected NULL-state result_code='
            || NVL(l_error_result.result_code, '<NULL>')
         );
   END;

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('7. capture uses REC_STATE 0 -> 2');

   SELECT COUNT(*)
     INTO l_source_cnt
     FROM USER_SOURCE
    WHERE NAME = 'MI_0606_API'
      AND TYPE = 'PACKAGE BODY'
      AND UPPER(TEXT) LIKE '%SET REC_STATE = ''2''%';

   assert_True(
      l_source_cnt = 1,
      'compiled package does not contain exactly one REC_STATE=2 transition'
   );

   SELECT COUNT(*)
     INTO l_source_cnt
     FROM USER_SOURCE
    WHERE NAME = 'MI_0606_API'
      AND TYPE = 'PACKAGE BODY'
      AND UPPER(TEXT) LIKE '%SET REC_STATE = ''1''%';

   assert_True(
      l_source_cnt = 0,
      'compiled package still contains REC_STATE=1 transition'
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('8. capture does not read BINFILE');

   SELECT COUNT(*)
     INTO l_source_cnt
     FROM USER_SOURCE
    WHERE NAME = 'MI_0606_API'
      AND TYPE = 'PACKAGE BODY'
      AND UPPER(TEXT) LIKE '%BINFILE%';

   assert_True(
      l_source_cnt = 0,
      'compiled package still depends on RSD_OUTFILES.BINFILE'
   );

   DBMS_OUTPUT.put_line('   OK');
   DBMS_OUTPUT.put_line('MI_0606_Api smoke test passed');
END;
/
