DECLARE
   l_request_uuid MI_REQ.ORIGINAL_REQ_UUID%TYPE := MI_Utils.uuid_V7;
   l_byte_body    BLOB;
   l_req_id       MI_REQ.REQ_ID%TYPE;
   l_itm_id       MI_0600.ITM_ID%TYPE;
   l_base_id      RSD_BASES.ID%TYPE;
   l_file_type    RSD_BASES.FILE_TYPE%TYPE;
   l_parse_result NUMBER;
   l_ret_code     NUMBER;
   l_ret_info     VARCHAR2(4000);
   l_count        PLS_INTEGER;

   PROCEDURE assert_True(p_ok IN BOOLEAN, p_message IN VARCHAR2)
   IS
   BEGIN
      IF p_ok IS NULL OR NOT p_ok THEN
         RAISE_APPLICATION_ERROR(-20990, 'MI 607/608 smoke: ' || p_message);
      END IF;
   END;

   PROCEDURE receive(p_inf_id IN MI_REQ.INF_ID%TYPE, p_legacy IN BOOLEAN DEFAULT FALSE)
   IS
      l_message_uuid MI_REQ.MESSAGE_UUID%TYPE := MI_Utils.uuid_V7;
      l_task_id      RSD_BASES.TASKID%TYPE := MI_Utils.uuid_V7;
   BEGIN
      IF p_legacy THEN
         MI_0607_Api.process_Document_Received(
            l_request_uuid, l_message_uuid, NULL, l_task_id, 'UNO', SYSDATE,
            'mi-smoke-invalid.json', l_byte_body, l_req_id, l_itm_id,
            l_base_id, l_file_type, l_parse_result, l_ret_code, l_ret_info
         );
      ELSE
         MI_0607_Api.process_Document_Received(
            l_request_uuid, l_message_uuid, NULL, l_task_id, 'UNO', SYSDATE,
            'mi-smoke-invalid.json', l_byte_body, l_req_id, l_itm_id,
            l_base_id, l_file_type, l_parse_result, l_ret_code, l_ret_info, p_inf_id
         );
      END IF;
   END;

   PROCEDURE assert_Journal(p_inf_id IN MI_REQ.INF_ID%TYPE, p_prefix IN VARCHAR2)
   IS
   BEGIN
      assert_True(l_ret_code IN (MI_0607_Api.RET_CREATE_BASE_FAILED, MI_0607_Api.RET_DOC_TYPE_MISMATCH)
                  AND l_req_id IS NOT NULL AND l_itm_id IS NOT NULL,
                  'expected business rejection with journal: ' || l_ret_info);

      SELECT COUNT(*)
        INTO l_count
        FROM MI_REQ r
        JOIN MI_0600 i ON i.REQ_ID = r.REQ_ID
        JOIN MI_0600_F f ON f.ITM_ID = i.ITM_ID
       WHERE r.REQ_ID = l_req_id
         AND r.INF_ID = p_inf_id
         AND LOWER(TRIM(r.ORIGINAL_REQ_UUID)) = LOWER(TRIM(l_request_uuid))
         AND i.ITM_ID = l_itm_id
         AND i.CZIP_NAME = p_prefix || LOWER(TRIM(l_request_uuid))
         AND f.CZIP_FILE_NAME = 'mi-smoke-invalid.json';

      assert_True(l_count = 1, 'journal missing or stored under wrong INF_ID=' || p_inf_id);
      DBMS_OUTPUT.put_line('INF_ID=' || p_inf_id || ' REQ_ID=' || l_req_id || ' ITM_ID=' || l_itm_id);
   END;

BEGIN
   SAVEPOINT before_607_608_smoke;
   DBMS_LOB.createtemporary(l_byte_body, TRUE);
   -- An empty JSON object reaches the journal and is rejected by the business parser.
   DBMS_LOB.writeappend(l_byte_body, 2, HEXTORAW('7B7D'));

   receive(NULL);
   assert_True(l_ret_code = MI_0607_Api.RET_FAIL AND l_req_id IS NULL
               AND INSTR(l_ret_info, 'MI_0607_INVALID_INF_ID:') = 1,
               'NULL INF_ID must be rejected before registration');

   receive(607, TRUE);
   assert_Journal(607, 'MI_0607_');

   receive(608);
   assert_Journal(608, 'MI_0608_');

   receive(608);
   assert_True(l_ret_code = MI_0607_Api.RET_FAIL AND l_req_id IS NULL AND l_itm_id IS NULL
               AND INSTR(l_ret_info, 'MI_0607_DUPLICATE_REQUEST:') = 1,
               'repeat 608 must be rejected: ' || l_ret_info);

   SELECT COUNT(*)
     INTO l_count
     FROM MI_REQ
    WHERE INF_ID = 608
      AND LOWER(TRIM(ORIGINAL_REQ_UUID)) = LOWER(TRIM(l_request_uuid));
   assert_True(l_count = 1, 'repeat 608 changed journal count');

   ROLLBACK TO before_607_608_smoke;
   DBMS_LOB.freetemporary(l_byte_body);
   DBMS_OUTPUT.put_line('MI_0607_0608_SMOKE=PASS');
EXCEPTION
   WHEN OTHERS THEN
      ROLLBACK TO before_607_608_smoke;
      IF DBMS_LOB.istemporary(l_byte_body) = 1 THEN
         DBMS_LOB.freetemporary(l_byte_body);
      END IF;
      RAISE;
END;
