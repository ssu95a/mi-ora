SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK ON
SET VERIFY OFF

PROMPT ============================================================
PROMPT MI_0607_Api smoke test
PROMPT ============================================================

DECLARE
   l_result           MI_ResultCtx.exec_Result_t;
   l_error_result     MI_ResultCtx.exec_Result_t;

   l_message_uuid     MI_REQ.MESSAGE_UUID%TYPE;
   l_correlation_id   MI_REQ.CORRELATION_ID%TYPE;
   l_task_id          RSD_BASES.TASKID%TYPE;

   l_req_id           MI_REQ.REQ_ID%TYPE;
   l_itm_id           MI_0600.ITM_ID%TYPE;
   l_existing_req_id  MI_REQ.REQ_ID%TYPE;
   l_existing_itm_id  MI_0600.ITM_ID%TYPE;

   l_base_id          RSD_BASES.ID%TYPE;
   l_file_type        RSD_BASES.FILE_TYPE%TYPE;
   l_parse_result     NUMBER;

   l_ret_code         NUMBER;
   l_ret_info         VARCHAR2(4000);
   l_count            PLS_INTEGER;
   l_req_count        PLS_INTEGER;
   l_file_body        BLOB;
   l_other_file_body  BLOB;


   PROCEDURE fail (
      p_message IN VARCHAR2
   )
   IS
   BEGIN
      RAISE_APPLICATION_ERROR(
         -20990,
         'MI_0607_Api smoke test failed: ' || p_message
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


   PROCEDURE assert_Replay_Conflict (
      p_task_id   IN RSD_BASES.TASKID%TYPE,
      p_file_name IN RSD_BASES.FILE_NAME%TYPE,
      p_file_body IN MI_0600.BZIP_DATA%TYPE,
      p_label     IN VARCHAR2
   )
   IS
   BEGIN
      MI_ResultCtx.clear_Current;

      BEGIN
         MI_0607_Api.process_Document_Received(
            p_original_req_uuid => NULL,
            p_message_uuid      => l_message_uuid,
            p_correlation_id    => l_correlation_id,
            p_task_id           => p_task_id,
            p_doc_type          => 'UNO',
            p_doc_date          => SYSDATE,
            p_file_name         => p_file_name,
            p_file_body         => p_file_body,
            p_req_id            => l_req_id,
            p_itm_id            => l_itm_id,
            p_base_id           => l_base_id,
            p_file_type         => l_file_type,
            p_parse_result      => l_parse_result,
            p_ret_code          => l_ret_code,
            p_ret_info          => l_ret_info
         );

         fail(p_label || ' replay conflict was accepted');

      EXCEPTION
         WHEN MI_ResultCtx.result_Failed_Exc THEN
            l_error_result := MI_ResultCtx.current_Result;

            assert_True(
               l_error_result.result_code = 'MI_0607_REPLAY_CONFLICT',
               p_label
               || ' returned result_code='
               || NVL(l_error_result.result_code, '<NULL>')
            );
      END;
   END assert_Replay_Conflict;


BEGIN
   SAVEPOINT before_mi_0607_smoke;

   BEGIN
      SELECT 1
        INTO l_count
        FROM MI_INF
       WHERE INF_ID = 607;

   EXCEPTION
      WHEN NO_DATA_FOUND THEN
         fail('MI_INF does not contain required INF_ID=607');
   END;

   l_message_uuid   := MI_Utils.uuid_V7;
   l_correlation_id := MI_Utils.uuid_V7;
   l_task_id        := MI_Utils.uuid_V7;

   DBMS_LOB.createtemporary(l_file_body, TRUE);
   DBMS_LOB.writeappend(l_file_body, 2, HEXTORAW('7B7D'));

   /* Same byte length as l_file_body, but different content. */
   DBMS_LOB.createtemporary(l_other_file_body, TRUE);
   DBMS_LOB.writeappend(l_other_file_body, 2, HEXTORAW('5B5D'));


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('1. NULL docType raises a named technical error');

   MI_ResultCtx.clear_Current;

   BEGIN
      MI_0607_Api.process_Document_Received(
         p_original_req_uuid => NULL,
         p_message_uuid      => l_message_uuid,
         p_correlation_id    => l_correlation_id,
         p_task_id           => l_task_id,
         p_doc_type          => NULL,
         p_doc_date          => SYSDATE,
         p_file_name         => 'smoke.json',
         p_file_body         => l_file_body,
         p_req_id            => l_req_id,
         p_itm_id            => l_itm_id,
         p_base_id           => l_base_id,
         p_file_type         => l_file_type,
         p_parse_result      => l_parse_result,
         p_ret_code          => l_ret_code,
         p_ret_info          => l_ret_info
      );

      fail('NULL docType was accepted');

   EXCEPTION
      WHEN MI_ResultCtx.result_Failed_Exc THEN
         l_error_result := MI_ResultCtx.current_Result;

         assert_True(
            l_error_result.result_code = 'MI_0607_INVALID_DOC_TYPE',
            'unexpected validation result_code='
            || NVL(l_error_result.result_code, '<NULL>')
         );
   END;

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('2. incomplete replay journal is rejected');

   l_result :=
      MI_Request_Api.create_Request(
         p_inf_id         => 607,
         p_correlation_id => l_correlation_id,
         p_ctaxreq_id     => l_task_id,
         p_message_uuid   => l_message_uuid,
         p_status_cd      => MI_Request_Api.STATUS_DONE
      );

   assert_True(
      MI_ResultCtx.is_Success(l_result),
      'cannot create replay fixture: ' || l_result.result_code
   );

   l_existing_req_id := TO_NUMBER(l_result.parameters('req_id'));

   INSERT INTO MI_0600 (
      EXTERNAL_UUID,
      REQ_ID,
      CZIP_NAME,
      BZIP_DATA,
      IZIP_SIZE,
      IZIP_FILES_COUNT,
      ICREATE_TYPE,
      MESSAGE_UUID,
      IRES_CODE,
      ERROR_CODE,
      CRES_INFO
   )
   VALUES (
      MI_Utils.uuid_V7,
      l_existing_req_id,
      'MI_0607_' || LOWER(TRIM(l_message_uuid)),
      l_file_body,
      DBMS_LOB.getlength(l_file_body),
      1,
      0,
      l_message_uuid,
      MI_Item_Result_Api.RESPONSE_FAIL,
      'PARSING_FAILED',
      TO_CLOB('Stored parsing failure')
   )
   RETURNING ITM_ID
        INTO l_existing_itm_id;

   INSERT INTO MI_0600_F (
      ITM_ID,
      CZIP_FILE_NAME
   )
   VALUES (
      l_existing_itm_id,
      'smoke.json'
   );

   SELECT COUNT(*)
     INTO l_req_count
     FROM MI_REQ;


   MI_ResultCtx.clear_Current;

   BEGIN
      MI_0607_Api.process_Document_Received(
         p_original_req_uuid => NULL,
         p_message_uuid      => l_message_uuid,
         p_correlation_id    => l_correlation_id,
         p_task_id           => l_task_id,
         p_doc_type          => 'UNO',
         p_doc_date          => SYSDATE,
         p_file_name         => 'smoke.json',
         p_file_body         => l_file_body,
         p_req_id            => l_req_id,
         p_itm_id            => l_itm_id,
         p_base_id           => l_base_id,
         p_file_type         => l_file_type,
         p_parse_result      => l_parse_result,
         p_ret_code          => l_ret_code,
         p_ret_info          => l_ret_info
      );

      fail('incomplete replay journal was accepted');

   EXCEPTION
      WHEN MI_ResultCtx.result_Failed_Exc THEN
         l_error_result := MI_ResultCtx.current_Result;

         assert_True(
            l_error_result.result_code = 'MI_0607_INCOMPLETE_JOURNAL',
            'unexpected incomplete-journal result_code='
            || NVL(l_error_result.result_code, '<NULL>')
         );
   END;


   SELECT COUNT(*)
     INTO l_count
     FROM MI_REQ;

   assert_True(
      l_count = l_req_count,
      'incomplete replay check changed MI_REQ'
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line(
      '3. failed replay reproduces the stored business outcome'
   );

   UPDATE MI_0600
      SET TRES_TIME = SYSTIMESTAMP
    WHERE ITM_ID = l_existing_itm_id;

   assert_True(
      SQL%ROWCOUNT = 1,
      'cannot complete replay fixture item'
   );


   MI_0607_Api.process_Document_Received(
      p_original_req_uuid => NULL,
      p_message_uuid      => l_message_uuid,
      p_correlation_id    => l_correlation_id,
      p_task_id           => l_task_id,
      p_doc_type          => 'UNO',
      p_doc_date          => SYSDATE,
      p_file_name         => 'smoke.json',
      p_file_body         => l_file_body,
      p_req_id            => l_req_id,
      p_itm_id            => l_itm_id,
      p_base_id           => l_base_id,
      p_file_type         => l_file_type,
      p_parse_result      => l_parse_result,
      p_ret_code          => l_ret_code,
      p_ret_info          => l_ret_info
   );

   assert_True(
      l_ret_code = MI_0607_Api.RET_PARSING_FAILED,
      'failed replay returned ret_code='
      || NVL(TO_CHAR(l_ret_code), '<NULL>')
   );

   assert_True(
      l_ret_info = 'Stored parsing failure',
      'failed replay did not reproduce stored result info'
   );

   assert_True(
      l_req_id = l_existing_req_id
      AND l_itm_id = l_existing_itm_id,
      'replay returned different journal IDs'
   );

   assert_True(
      l_base_id IS NULL
      AND l_file_type IS NULL
      AND l_parse_result IS NULL,
      'replay exposed RSD result values'
   );

   SELECT COUNT(*)
     INTO l_count
     FROM MI_REQ;

   assert_True(l_count = l_req_count, 'replay created another MI_REQ');

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('4. changed replay input is rejected');

   assert_Replay_Conflict(
      p_task_id   => MI_Utils.uuid_V7,
      p_file_name => 'smoke.json',
      p_file_body => l_file_body,
      p_label     => 'taskId'
   );

   assert_Replay_Conflict(
      p_task_id   => l_task_id,
      p_file_name => 'other.json',
      p_file_body => l_file_body,
      p_label     => 'fileName'
   );

   assert_Replay_Conflict(
      p_task_id   => l_task_id,
      p_file_name => 'smoke.json',
      p_file_body => l_other_file_body,
      p_label     => 'fileBody'
   );

   SELECT COUNT(*)
     INTO l_count
     FROM MI_REQ;

   assert_True(l_count = l_req_count, 'replay conflict changed MI_REQ');

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('5. unknown terminal business error is rejected');

   UPDATE MI_0600
      SET ERROR_CODE = 'UNKNOWN_SMOKE_ERROR'
    WHERE ITM_ID = l_existing_itm_id;

   assert_True(
      SQL%ROWCOUNT = 1,
      'cannot prepare inconsistent terminal fixture'
   );

   MI_ResultCtx.clear_Current;

   BEGIN
      MI_0607_Api.process_Document_Received(
         p_original_req_uuid => NULL,
         p_message_uuid      => l_message_uuid,
         p_correlation_id    => l_correlation_id,
         p_task_id           => l_task_id,
         p_doc_type          => 'UNO',
         p_doc_date          => SYSDATE,
         p_file_name         => 'smoke.json',
         p_file_body         => l_file_body,
         p_req_id            => l_req_id,
         p_itm_id            => l_itm_id,
         p_base_id           => l_base_id,
         p_file_type         => l_file_type,
         p_parse_result      => l_parse_result,
         p_ret_code          => l_ret_code,
         p_ret_info          => l_ret_info
      );

      fail('unknown terminal business error was accepted');

   EXCEPTION
      WHEN MI_ResultCtx.result_Failed_Exc THEN
         l_error_result := MI_ResultCtx.current_Result;

         assert_True(
            l_error_result.result_code = 'MI_0607_INCONSISTENT_JOURNAL',
            'unknown terminal error returned result_code='
            || NVL(l_error_result.result_code, '<NULL>')
         );
   END;

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('6. successful replay returns RET_EXISTS');

   UPDATE MI_0600
      SET IRES_CODE  = MI_Item_Result_Api.RESPONSE_OK,
          ERROR_CODE = NULL,
          CRES_INFO  = NULL,
          TRES_TIME  = SYSTIMESTAMP
    WHERE ITM_ID = l_existing_itm_id;

   assert_True(
      SQL%ROWCOUNT = 1,
      'cannot prepare successful replay fixture'
   );

   MI_0607_Api.process_Document_Received(
      p_original_req_uuid => NULL,
      p_message_uuid      => l_message_uuid,
      p_correlation_id    => l_correlation_id,
      p_task_id           => l_task_id,
      p_doc_type          => 'UNO',
      p_doc_date          => SYSDATE,
      p_file_name         => 'smoke.json',
      p_file_body         => l_file_body,
      p_req_id            => l_req_id,
      p_itm_id            => l_itm_id,
      p_base_id           => l_base_id,
      p_file_type         => l_file_type,
      p_parse_result      => l_parse_result,
      p_ret_code          => l_ret_code,
      p_ret_info          => l_ret_info
   );

   assert_True(
      l_ret_code = MI_0607_Api.RET_EXISTS,
      'successful replay returned ret_code='
      || NVL(TO_CHAR(l_ret_code), '<NULL>')
   );

   assert_True(
      l_req_id = l_existing_req_id
      AND l_itm_id = l_existing_itm_id,
      'successful replay returned different journal IDs'
   );

   assert_True(
      l_base_id IS NULL
      AND l_file_type IS NULL
      AND l_parse_result IS NULL,
      'successful replay exposed RSD result values'
   );

   SELECT COUNT(*)
     INTO l_count
     FROM MI_REQ;

   assert_True(
      l_count = l_req_count,
      'successful replay created another MI_REQ'
   );

   DBMS_OUTPUT.put_line('   OK');


   ROLLBACK TO before_mi_0607_smoke;

   DBMS_LOB.freetemporary(l_file_body);
   DBMS_LOB.freetemporary(l_other_file_body);

   DBMS_OUTPUT.put_line('MI_0607_Api smoke test passed');

EXCEPTION
   WHEN OTHERS THEN
      ROLLBACK TO before_mi_0607_smoke;

      IF DBMS_LOB.istemporary(l_file_body) = 1 THEN
         DBMS_LOB.freetemporary(l_file_body);
      END IF;

      IF DBMS_LOB.istemporary(l_other_file_body) = 1 THEN
         DBMS_LOB.freetemporary(l_other_file_body);
      END IF;

      RAISE;
END;
/
