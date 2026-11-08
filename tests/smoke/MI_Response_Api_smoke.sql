SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK ON
SET VERIFY OFF

PROMPT ============================================================
PROMPT MI_Response_Api smoke test
PROMPT ============================================================

DECLARE
   l_inf_id         MI_INF.INF_ID%TYPE;

   l_req_id         MI_REQ.REQ_ID%TYPE;
   l_itm_id         MI_RSP.ITM_ID%TYPE;

   l_rsp_id         MI_RSP.RSP_ID%TYPE;
   l_rsp_id2        MI_RSP.RSP_ID%TYPE;
   l_rsp_uuid       MI_RSP.RSP_UUID%TYPE;
   l_result_uuid    MI_RSP.RSP_UUID%TYPE;

   l_status_cd      MI_RSP.STATUS_CD%TYPE;
   l_category_cd    MI_RSP.CATEGORY_CD%TYPE;
   l_result_code    MI_RSP.RESULT_CODE%TYPE;
   l_result_info    MI_RSP.RESULT_INFO%TYPE;
   l_payload        MI_RSP.PAYLOAD%TYPE;
   l_sent_at        MI_RSP.SENT_AT%TYPE;

   l_result         MI_ResultCtx.exec_Result_t;

   l_count          PLS_INTEGER;


   ---------------------------------------------------------------------------
   PROCEDURE fail (
      p_message IN VARCHAR2
   )
   IS
   BEGIN
      RAISE_APPLICATION_ERROR(
         -20990,
         'MI_Response_Api smoke test failed: ' || p_message
      );
   END fail;


   ---------------------------------------------------------------------------
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


   ---------------------------------------------------------------------------
   PROCEDURE assert_Success (
      p_result   IN MI_ResultCtx.exec_Result_t,
      p_message  IN VARCHAR2
   )
   IS
   BEGIN
      IF MI_ResultCtx.is_Failed(p_result) THEN
         fail(
            p_message
            || ' [result_code='
            || NVL(p_result.result_code, '<NULL>')
            || ', result_info='
            || NVL(p_result.result_info, '<NULL>')
            || ', cause_code='
            || NVL(p_result.cause_code, '<NULL>')
            || ', cause_info='
            || NVL(p_result.cause_info, '<NULL>')
            || ']'
         );
      END IF;
   END assert_Success;


   ---------------------------------------------------------------------------
   PROCEDURE assert_Failed (
      p_result   IN MI_ResultCtx.exec_Result_t,
      p_message  IN VARCHAR2
   )
   IS
   BEGIN
      IF MI_ResultCtx.is_Success(p_result) THEN
         fail(
            p_message
            || ' [result_code='
            || NVL(p_result.result_code, '<NULL>')
            || ']'
         );
      END IF;
   END assert_Failed;


   ---------------------------------------------------------------------------
   PROCEDURE assert_Equals (
      p_actual   IN VARCHAR2,
      p_expected IN VARCHAR2,
      p_message  IN VARCHAR2
   )
   IS
   BEGIN
      IF    p_actual <> p_expected
         OR (p_actual IS NULL AND p_expected IS NOT NULL)
         OR (p_actual IS NOT NULL AND p_expected IS NULL)
      THEN
         fail(
            p_message
            || ' [expected='
            || NVL(p_expected, '<NULL>')
            || ', actual='
            || NVL(p_actual, '<NULL>')
            || ']'
         );
      END IF;
   END assert_Equals;


   ---------------------------------------------------------------------------
   FUNCTION result_Id (
      p_result     IN MI_ResultCtx.exec_Result_t,
      p_parameter  IN VARCHAR2
   )
      RETURN NUMBER
   IS
   BEGIN
      RETURN TO_NUMBER(p_result.parameters(p_parameter));

   EXCEPTION
      WHEN NO_DATA_FOUND THEN
         fail('result does not contain parameter ' || p_parameter);
         RETURN NULL;
   END result_Id;


BEGIN
   ---------------------------------------------------------------------------
   BEGIN
      SELECT INF_ID
        INTO l_inf_id
        FROM (
           SELECT INF_ID
             FROM MI_INF
            ORDER BY INF_ID
        )
       WHERE ROWNUM = 1;

   EXCEPTION
      WHEN NO_DATA_FOUND THEN
         fail('MI_INF is empty');
   END;


   SAVEPOINT before_response_smoke;


   l_result :=
      MI_Request_Api.create_Request(
         p_inf_id => l_inf_id
      );

   assert_Success(l_result, 'test request creation failed');

   l_req_id := result_Id(l_result, 'req_id');

   /*
      MI_RSP.ITM_ID is a polymorphic reference. Item tables are outside this
      core smoke test, so an isolated non-NULL value is sufficient here.
   */
   l_itm_id := l_req_id;


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('1. create NEW response');

   l_result :=
      MI_Response_Api.create_Response(
         p_req_id      => l_req_id,
         p_itm_id      => l_itm_id,
         p_category_cd => 'SUCCESS',
         p_result_code => 'OK',
         p_result_info => 'smoke response',
         p_payload     => TO_CLOB('{"ok":true}')
      );

   assert_Success(l_result, 'create_Response failed');

   assert_Equals(
      l_result.result_code,
      'RESPONSE_CREATED',
      'create result code'
   );

   l_rsp_id   := result_Id(l_result, 'rsp_id');
   l_result_uuid := l_result.parameters('rsp_uuid');

   SELECT STATUS_CD,
          RSP_UUID,
          CATEGORY_CD,
          RESULT_CODE,
          RESULT_INFO,
          PAYLOAD,
          SENT_AT
     INTO l_status_cd,
          l_rsp_uuid,
          l_category_cd,
          l_result_code,
          l_result_info,
          l_payload,
          l_sent_at
     FROM MI_RSP
    WHERE RSP_ID = l_rsp_id;

   assert_True(l_rsp_id IS NOT NULL, 'RSP_ID is NULL');
   assert_True(l_rsp_uuid IS NOT NULL, 'RSP_UUID is NULL');
   assert_True(LENGTH(l_rsp_uuid) = 36, 'RSP_UUID length is not 36');
   assert_True(l_sent_at IS NULL, 'SENT_AT is set for NEW response');

   assert_Equals(
      l_result_uuid,
      l_rsp_uuid,
      'returned RSP_UUID mismatch'
   );

   assert_True(
      l_status_cd = MI_Response_Api.STATUS_NEW,
      'new response STATUS_CD is not NEW'
   );

   assert_Equals(l_category_cd, 'SUCCESS', 'CATEGORY_CD mismatch');
   assert_Equals(l_result_code, 'OK', 'RESULT_CODE mismatch');
   assert_Equals(l_result_info, 'smoke response', 'RESULT_INFO mismatch');

   assert_True(
      DBMS_LOB.compare(l_payload, TO_CLOB('{"ok":true}')) = 0,
      'PAYLOAD mismatch'
   );

   assert_True(
      MI_Response_Api.exists_Response(l_rsp_id),
      'exists_Response returned FALSE'
   );

   assert_True(
      MI_Response_Api.get_Status(l_rsp_id) = MI_Response_Api.STATUS_NEW,
      'get_Status mismatch'
   );

   assert_Equals(
      MI_Response_Api.get_Rsp_Uuid(l_rsp_id),
      l_rsp_uuid,
      'get_Rsp_Uuid mismatch'
   );

   DBMS_OUTPUT.put_line('   rsp_id=' || l_rsp_id);
   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('2. NEW -> READY -> SENT');

   l_result := MI_Response_Api.to_Ready(l_rsp_id);

   assert_Success(l_result, 'to_Ready failed');

   assert_Equals(
      l_result.result_code,
      'RESPONSE_READY',
      'to_Ready result code'
   );

   assert_True(
      MI_Response_Api.get_Status(l_rsp_id) = MI_Response_Api.STATUS_READY,
      'response is not READY'
   );


   l_result := MI_Response_Api.to_Sent(l_rsp_id);

   assert_Success(l_result, 'to_Sent failed');

   assert_Equals(
      l_result.result_code,
      'RESPONSE_SENT',
      'to_Sent result code'
   );

   SELECT STATUS_CD,
          SENT_AT
     INTO l_status_cd,
          l_sent_at
     FROM MI_RSP
    WHERE RSP_ID = l_rsp_id;

   assert_True(
      l_status_cd = MI_Response_Api.STATUS_SENT,
      'response is not SENT'
   );

   assert_True(l_sent_at IS NOT NULL, 'SENT_AT was not set');

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('3. rejected transition keeps current state');

   l_result :=
      MI_Response_Api.create_Response(
         p_req_id      => l_req_id,
         p_itm_id      => l_itm_id,
         p_category_cd => 'SUCCESS',
         p_result_code => 'OK'
      );

   assert_Success(l_result, 'second response creation failed');

   l_rsp_id2 := result_Id(l_result, 'rsp_id');


   l_result := MI_Response_Api.to_Sent(l_rsp_id2);

   assert_Failed(l_result, 'NEW -> SENT was unexpectedly accepted');

   assert_Equals(
      l_result.result_code,
      'RESPONSE_BAD_STATUS',
      'bad transition result code'
   );

   assert_True(
      MI_Response_Api.get_Status(l_rsp_id2) = MI_Response_Api.STATUS_NEW,
      'rejected transition changed status'
   );


   l_result := MI_Response_Api.to_Ready(l_rsp_id2);
   assert_Success(l_result, 'second response to_Ready failed');

   l_result := MI_Response_Api.to_Ready(l_rsp_id2);

   assert_Failed(l_result, 'duplicate to_Ready was unexpectedly accepted');

   assert_Equals(
      l_result.result_code,
      'RESPONSE_BAD_STATUS',
      'duplicate to_Ready result code'
   );

   assert_True(
      MI_Response_Api.get_Status(l_rsp_id2) = MI_Response_Api.STATUS_READY,
      'duplicate to_Ready changed status'
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('4. reject invalid input before INSERT');

   l_result :=
      MI_Response_Api.create_Response(
         p_req_id      => l_req_id,
         p_itm_id      => NULL,
         p_category_cd => 'SUCCESS',
         p_result_code => 'OK'
      );

   assert_Failed(l_result, 'NULL ITM_ID was unexpectedly accepted');

   assert_Equals(
      l_result.result_code,
      'RESPONSE_INVALID_ITM_ID',
      'NULL ITM_ID result code'
   );


   l_result :=
      MI_Response_Api.create_Response(
         p_req_id      => l_req_id,
         p_itm_id      => l_itm_id,
         p_category_cd => '   ',
         p_result_code => 'OK'
      );

   assert_Failed(l_result, 'blank CATEGORY_CD was unexpectedly accepted');

   assert_Equals(
      l_result.result_code,
      'RESPONSE_INVALID_CATEGORY',
      'blank CATEGORY_CD result code'
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('5. reject missing request');

   l_result :=
      MI_Response_Api.create_Response(
         p_req_id      => -1,
         p_itm_id      => l_itm_id,
         p_category_cd => 'SUCCESS',
         p_result_code => 'OK'
      );

   assert_Failed(l_result, 'missing request was unexpectedly accepted');

   assert_Equals(
      l_result.result_code,
      'RESPONSE_REQUEST_NOT_FOUND',
      'missing request result code'
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('6. reject missing response');

   l_result := MI_Response_Api.to_Ready(-1);

   assert_Failed(l_result, 'missing response was unexpectedly accepted');

   assert_Equals(
      l_result.result_code,
      'RESPONSE_NOT_FOUND',
      'missing response result code'
   );

   assert_True(
      NOT MI_Response_Api.exists_Response(-1),
      'exists_Response returned TRUE for missing response'
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('7. invalid JSON returns structured failure');

   SELECT COUNT(*)
     INTO l_count
     FROM MI_RSP
    WHERE REQ_ID = l_req_id;

   DECLARE
      l_count_before PLS_INTEGER := l_count;
   BEGIN
      l_result :=
         MI_Response_Api.create_Response(
            p_req_id      => l_req_id,
            p_itm_id      => l_itm_id,
            p_category_cd => 'SUCCESS',
            p_result_code => 'OK',
            p_payload     => TO_CLOB('{invalid')
         );

      assert_Failed(l_result, 'invalid JSON was unexpectedly accepted');

      assert_Equals(
         l_result.result_code,
         'RESPONSE_CREATE_FAILED',
         'invalid JSON result code'
      );

      assert_Equals(
         l_result.cause_code,
         'ORA-02290',
         'invalid JSON cause code'
      );

      SELECT COUNT(*)
        INTO l_count
        FROM MI_RSP
       WHERE REQ_ID = l_req_id;

      assert_True(
         l_count = l_count_before,
         'invalid JSON left a response row'
      );
   END;

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   ROLLBACK TO before_response_smoke;

   SELECT COUNT(*)
     INTO l_count
     FROM MI_RSP
    WHERE RSP_ID IN (l_rsp_id, l_rsp_id2);

   assert_True(l_count = 0, 'ROLLBACK did not remove test responses');

   SELECT COUNT(*)
     INTO l_count
     FROM MI_REQ
    WHERE REQ_ID = l_req_id;

   assert_True(l_count = 0, 'ROLLBACK did not remove test request');


   DBMS_OUTPUT.put_line('============================================================');
   DBMS_OUTPUT.put_line('MI_Response_Api smoke test PASSED');
   DBMS_OUTPUT.put_line('============================================================');
END;
/
