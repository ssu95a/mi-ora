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
   DBMS_OUTPUT.put_line('2. replay returns RET_EXISTS without RSD processing');

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
      MESSAGE_UUID
   )
   VALUES (
      MI_Utils.uuid_V7,
      l_existing_req_id,
      'MI_0607_' || LOWER(TRIM(l_message_uuid)),
      l_file_body,
      DBMS_LOB.getlength(l_file_body),
      1,
      0,
      l_message_uuid
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
      'replay returned ret_code=' || NVL(TO_CHAR(l_ret_code), '<NULL>')
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


   ROLLBACK TO before_mi_0607_smoke;

   DBMS_LOB.freetemporary(l_file_body);

   DBMS_OUTPUT.put_line('MI_0607_Api smoke test passed');

EXCEPTION
   WHEN OTHERS THEN
      ROLLBACK TO before_mi_0607_smoke;

      IF DBMS_LOB.istemporary(l_file_body) = 1 THEN
         DBMS_LOB.freetemporary(l_file_body);
      END IF;

      RAISE;
END;
/
