SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK ON
SET VERIFY OFF

PROMPT ============================================================
PROMPT MI_0607_Api smoke test
PROMPT ============================================================

DECLARE
   l_result             MI_ResultCtx.exec_Result_t;
   l_error_result       MI_ResultCtx.exec_Result_t;

   l_original_req_uuid  MI_REQ.ORIGINAL_REQ_UUID%TYPE;
   l_other_request_uuid MI_REQ.ORIGINAL_REQ_UUID%TYPE;
   l_message_uuid       MI_REQ.MESSAGE_UUID%TYPE;
   l_new_message_uuid   MI_REQ.MESSAGE_UUID%TYPE;
   l_correlation_id     MI_REQ.CORRELATION_ID%TYPE;
   l_task_id            RSD_BASES.TASKID%TYPE;

   l_req_id             MI_REQ.REQ_ID%TYPE;
   l_itm_id             MI_0600.ITM_ID%TYPE;
   l_existing_req_id    MI_REQ.REQ_ID%TYPE;
   l_existing_itm_id    MI_0600.ITM_ID%TYPE;

   l_base_id            RSD_BASES.ID%TYPE;
   l_file_type          RSD_BASES.FILE_TYPE%TYPE;
   l_parse_result       NUMBER;
   l_outfile_id         RSD_OUTFILES.ID%TYPE;

   l_ret_code           NUMBER;
   l_ret_info           VARCHAR2(4000);

   l_req_count          PLS_INTEGER;
   l_item_count         PLS_INTEGER;
   l_file_count         PLS_INTEGER;
   l_actual_count       PLS_INTEGER;
   l_payload_compare    PLS_INTEGER;
   l_stored_message     MI_REQ.MESSAGE_UUID%TYPE;
   l_stored_body        MI_0600.BZIP_DATA%TYPE;

   l_file_body          BLOB;
   l_other_file_body    BLOB;


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


   PROCEDURE call_Duplicate (
      p_original_req_uuid IN MI_REQ.ORIGINAL_REQ_UUID%TYPE,
      p_message_uuid      IN MI_REQ.MESSAGE_UUID%TYPE,
      p_file_body         IN MI_0600.BZIP_DATA%TYPE
   )
   IS
   BEGIN
      l_req_id       := -1;
      l_itm_id       := -1;
      l_base_id      := -1;
      l_file_type    := 'X';
      l_parse_result := -1;
      l_outfile_id   := -1;
      l_ret_code     := NULL;
      l_ret_info     := NULL;

      MI_0607_Api.process_Document_Received(
         p_original_req_uuid => p_original_req_uuid,
         p_message_uuid      => p_message_uuid,
         p_correlation_id    => MI_Utils.uuid_V7,
         p_task_id           => MI_Utils.uuid_V7,
         p_doc_type          => 'UPO',
         p_doc_date          => SYSDATE,
         p_file_name         => 'changed.json',
         p_file_body         => p_file_body,
         p_req_id            => l_req_id,
         p_itm_id            => l_itm_id,
         p_base_id           => l_base_id,
         p_file_type         => l_file_type,
         p_parse_result      => l_parse_result,
         p_ret_code          => l_ret_code,
         p_ret_info          => l_ret_info,
         p_inf_id            => 607,
         p_outfile_id        => l_outfile_id
      );

      assert_True(
         l_ret_code = MI_0607_Api.RET_FAIL,
         'duplicate returned ret_code='
         || NVL(TO_CHAR(l_ret_code), '<NULL>')
      );

      assert_True(
         INSTR(NVL(l_ret_info, '<NULL>'), 'MI_0607_DUPLICATE_REQUEST:') = 1,
         'unexpected duplicate ret_info=' || NVL(l_ret_info, '<NULL>')
      );

      assert_True(
         l_req_id IS NULL
         AND l_itm_id IS NULL
         AND l_base_id IS NULL
         AND l_file_type IS NULL
         AND l_parse_result IS NULL
         AND l_outfile_id IS NULL,
         'duplicate exposed identifiers or business result'
      );
   END call_Duplicate;


BEGIN
   SAVEPOINT before_mi_0607_smoke;

   BEGIN
      SELECT 1
        INTO l_req_count
        FROM MI_INF
       WHERE INF_ID = 607;

   EXCEPTION
      WHEN NO_DATA_FOUND THEN
         fail('MI_INF does not contain required INF_ID=607');
   END;

   l_original_req_uuid  := MI_Utils.uuid_V7;
   l_other_request_uuid := MI_Utils.uuid_V7;
   l_message_uuid       := MI_Utils.uuid_V7;
   l_new_message_uuid   := MI_Utils.uuid_V7;
   l_correlation_id     := MI_Utils.uuid_V7;
   l_task_id            := MI_Utils.uuid_V7;

   DBMS_LOB.createtemporary(l_file_body, TRUE);
   DBMS_LOB.writeappend(l_file_body, 2, HEXTORAW('7B7D'));

   DBMS_LOB.createtemporary(l_other_file_body, TRUE);
   DBMS_LOB.writeappend(l_other_file_body, 2, HEXTORAW('5B5D'));


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('1. DOCUMENT_RECEIVED requestId is required');

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
         p_ret_info          => l_ret_info,
         p_inf_id            => 607,
         p_outfile_id        => l_outfile_id
      );

      fail('NULL original_request_uuid was accepted');

   EXCEPTION
      WHEN MI_ResultCtx.result_Failed_Exc THEN
         l_error_result := MI_ResultCtx.current_Result;

         assert_True(
            l_error_result.result_code = 'MI_0607_INVALID_ORIGINAL_UUID',
            'unexpected validation result_code='
            || NVL(l_error_result.result_code, '<NULL>')
         );
   END;

   DBMS_OUTPUT.put_line('   OK');

   MI_ResultCtx.clear_Current;


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('2. duplicate requestId returns RET_FAIL');

   l_result :=
      MI_Request_Api.create_Request(
         p_inf_id            => 607,
         p_correlation_id    => l_correlation_id,
         p_original_req_uuid => UPPER(l_original_req_uuid),
         p_ctaxreq_id        => l_task_id,
         p_message_uuid      => l_message_uuid,
         p_status_cd         => MI_Request_Api.STATUS_DONE
      );

   assert_True(
      MI_ResultCtx.is_Success(l_result),
      'cannot create duplicate fixture: ' || l_result.result_code
   );

   l_existing_req_id := TO_NUMBER(l_result.parameters('req_id'));

   /* Old journal naming proves duplicate lookup is based on requestId. */
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
      TRES_TIME
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
      MI_Item_Result_Api.RESPONSE_OK,
      SYSTIMESTAMP
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

   SELECT COUNT(*)
     INTO l_item_count
     FROM MI_0600;

   SELECT COUNT(*)
     INTO l_file_count
     FROM MI_0600_F;

   call_Duplicate(
      l_original_req_uuid,
      l_new_message_uuid,
      l_other_file_body
   );

   SELECT COUNT(*)
     INTO l_actual_count
     FROM MI_REQ;

   assert_True(l_actual_count = l_req_count, 'duplicate changed MI_REQ');

   SELECT COUNT(*)
     INTO l_actual_count
     FROM MI_0600;

   assert_True(l_actual_count = l_item_count, 'duplicate changed MI_0600');

   SELECT COUNT(*)
     INTO l_actual_count
     FROM MI_0600_F;

   assert_True(l_actual_count = l_file_count, 'duplicate changed MI_0600_F');

   SELECT r.MESSAGE_UUID,
          i.BZIP_DATA
     INTO l_stored_message,
          l_stored_body
     FROM MI_REQ r
     JOIN MI_0600 i
       ON i.REQ_ID = r.REQ_ID
    WHERE r.REQ_ID = l_existing_req_id
      AND i.ITM_ID = l_existing_itm_id;

   l_payload_compare := DBMS_LOB.compare(l_stored_body, l_file_body);

   assert_True(
      LOWER(TRIM(l_stored_message)) = LOWER(TRIM(l_message_uuid)),
      'duplicate changed stored MESSAGE_UUID'
   );

   assert_True(l_payload_compare = 0, 'duplicate changed stored payload');

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('3. failed journal is also a duplicate');

   UPDATE MI_0600
      SET IRES_CODE  = MI_Item_Result_Api.RESPONSE_FAIL,
          ERROR_CODE = 'PARSING_FAILED',
          CRES_INFO  = TO_CLOB('Stored parsing failure')
    WHERE ITM_ID = l_existing_itm_id;

   assert_True(SQL%ROWCOUNT = 1, 'cannot prepare failed fixture');

   call_Duplicate(
      l_original_req_uuid,
      MI_Utils.uuid_V7,
      l_file_body
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('4. MI_REQ header alone reserves requestId');

   l_result :=
      MI_Request_Api.create_Request(
         p_inf_id            => 607,
         p_correlation_id    => MI_Utils.uuid_V7,
         p_original_req_uuid => l_other_request_uuid,
         p_ctaxreq_id        => MI_Utils.uuid_V7,
         p_message_uuid      => MI_Utils.uuid_V7,
         p_status_cd         => MI_Request_Api.STATUS_DONE
      );

   assert_True(
      MI_ResultCtx.is_Success(l_result),
      'cannot create header-only fixture: ' || l_result.result_code
   );

   call_Duplicate(
      l_other_request_uuid,
      MI_Utils.uuid_V7,
      l_file_body
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
