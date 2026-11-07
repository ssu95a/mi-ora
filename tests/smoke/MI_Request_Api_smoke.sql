SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK ON
SET VERIFY OFF

PROMPT ============================================================
PROMPT MI_Request_Api smoke test
PROMPT ============================================================

DECLARE
   l_inf_id        MI_INF.INF_ID%TYPE;
   l_wsp_id        MI_INF.WSP_ID%TYPE;

   l_req_id        MI_REQ.REQ_ID%TYPE;
   l_req_id2       MI_REQ.REQ_ID%TYPE;
   l_req_id3       MI_REQ.REQ_ID%TYPE;
   l_req_done_id   MI_REQ.REQ_ID%TYPE;

   l_status_cd     MI_REQ.STATUS_CD%TYPE;
   l_external_uuid MI_REQ.EXTERNAL_UUID%TYPE;
   l_corr_id       MI_REQ.CORRELATION_ID%TYPE;
   l_idsmr         MI_REQ.IDSMR%TYPE;
   l_note          MI_REQ.NOTE%TYPE;

   l_result        MI_ResultCtx.exec_Result_t;

   l_count         PLS_INTEGER;


   ---------------------------------------------------------------------------
   PROCEDURE fail (
      p_message IN VARCHAR2
   )
   IS
   BEGIN
      RAISE_APPLICATION_ERROR(
         -20990,
         'MI_Request_Api smoke test failed: ' || p_message
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
   FUNCTION result_Req_Id (
      p_result IN MI_ResultCtx.exec_Result_t
   )
      RETURN MI_REQ.REQ_ID%TYPE
   IS
   BEGIN
      RETURN TO_NUMBER(p_result.parameters('req_id'));

   EXCEPTION
      WHEN NO_DATA_FOUND THEN
         fail('result does not contain parameter req_id');
         RETURN NULL;
   END result_Req_Id;


BEGIN
   ---------------------------------------------------------------------------
   BEGIN
      SELECT inf_id,
             wsp_id
        INTO l_inf_id,
             l_wsp_id
        FROM (
           SELECT inf_id,
                  wsp_id
             FROM MI_INF
            ORDER BY inf_id
        )
       WHERE ROWNUM = 1;

   EXCEPTION
      WHEN NO_DATA_FOUND THEN
         fail('MI_INF is empty');
   END;


   SAVEPOINT before_request_smoke;


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('1. create NEW request');

   l_result :=
      MI_Request_Api.create_Request(
         p_inf_id => l_inf_id
      );

   assert_True(
      MI_ResultCtx.is_Success(l_result),
      'create_Request(NEW) failed: ' || l_result.result_code
   );

   assert_Equals(
      l_result.result_code,
      'REQUEST_CREATED',
      'create NEW result code'
   );

   l_req_id := result_Req_Id(l_result);

   SELECT status_cd,
          external_uuid,
          correlation_id,
          idsmr
     INTO l_status_cd,
          l_external_uuid,
          l_corr_id,
          l_idsmr
     FROM MI_REQ
    WHERE req_id = l_req_id;

   assert_True(l_req_id IS NOT NULL, 'REQ_ID is NULL');
   assert_True(l_external_uuid IS NOT NULL, 'EXTERNAL_UUID is NULL');
   assert_True(l_corr_id IS NOT NULL, 'CORRELATION_ID is NULL');
   assert_True(l_idsmr IS NOT NULL, 'IDSMR default did not fire');

   assert_True(
      l_status_cd = MI_Request_Api.STATUS_NEW,
      'new request STATUS_CD is not NEW'
   );

   assert_True(
      MI_Request_Api.exists_Request(l_req_id),
      'exists_Request returned FALSE'
   );

   assert_True(
      MI_Request_Api.exists_Inf(l_inf_id),
      'exists_Inf returned FALSE'
   );

   assert_True(
      MI_Request_Api.resolve_Inf_Id(l_req_id) = l_inf_id,
      'resolve_Inf_Id mismatch'
   );

   assert_True(
      MI_Request_Api.resolve_Wsp_Id(l_inf_id) = l_wsp_id,
      'resolve_Wsp_Id mismatch'
   );

   assert_True(
      MI_Request_Api.get_Status(l_req_id) = MI_Request_Api.STATUS_NEW,
      'get_Status mismatch'
   );

   assert_Equals(
      MI_Request_Api.get_Correlation_Id(l_req_id),
      l_corr_id,
      'get_Correlation_Id mismatch'
   );

   DBMS_OUTPUT.put_line('   req_id=' || l_req_id);
   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('2. create DONE request');

   l_result :=
      MI_Request_Api.create_Request(
         p_inf_id    => l_inf_id,
         p_status_cd => MI_Request_Api.STATUS_DONE
      );

   assert_True(
      MI_ResultCtx.is_Success(l_result),
      'create_Request(DONE) failed: ' || l_result.result_code
   );

   l_req_done_id := result_Req_Id(l_result);

   assert_True(
      MI_Request_Api.get_Status(l_req_done_id) = MI_Request_Api.STATUS_DONE,
      'DONE request created with wrong status'
   );

   DBMS_OUTPUT.put_line('   req_id=' || l_req_done_id);
   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('3. reject invalid initial BUSY status');

   l_result :=
      MI_Request_Api.create_Request(
         p_inf_id    => l_inf_id,
         p_status_cd => MI_Request_Api.STATUS_BUSY
      );

   assert_True(
      MI_ResultCtx.is_Failed(l_result),
      'BUSY initial status was unexpectedly accepted'
   );

   assert_Equals(
      l_result.result_code,
      'REQUEST_INVALID_INITIAL_STATUS',
      'invalid initial status result code'
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('4. NEW -> BUSY -> SENT -> DONE');

   l_result :=
      MI_Request_Api.take_For_Proc(
         p_req_id => l_req_id,
         p_info   => 'smoke processing'
      );

   assert_Success(l_result, 'take_For_Proc failed');

   assert_True(
      MI_Request_Api.get_Status(l_req_id) = MI_Request_Api.STATUS_BUSY,
      'request is not BUSY'
   );

   SELECT note
     INTO l_note
     FROM MI_REQ
    WHERE req_id = l_req_id;

   assert_True(
      INSTR(l_note, 'smoke processing') > 0,
      'take_For_Proc did not save NOTE'
   );


   l_result := MI_Request_Api.to_Sent(l_req_id);

   assert_Success(l_result, 'to_Sent failed');

   assert_True(
      MI_Request_Api.get_Status(l_req_id) = MI_Request_Api.STATUS_SENT,
      'request is not SENT'
   );


   l_result := MI_Request_Api.to_Success(l_req_id);

   assert_Success(l_result, 'to_Success failed');

   assert_True(
      MI_Request_Api.get_Status(l_req_id) = MI_Request_Api.STATUS_DONE,
      'request is not DONE'
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('5. rejected transition keeps current state');

   l_result := MI_Request_Api.to_Sent(l_req_id);

   assert_True(
      MI_ResultCtx.is_Failed(l_result),
      'DONE -> SENT was unexpectedly accepted'
   );

   assert_Equals(
      l_result.result_code,
      'REQUEST_BAD_STATUS',
      'bad transition result code'
   );

   assert_True(
      MI_Request_Api.get_Status(l_req_id) = MI_Request_Api.STATUS_DONE,
      'rejected transition changed status'
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('6. ERROR may be taken for processing again');

   l_result := MI_Request_Api.create_Request(p_inf_id => l_inf_id);
   assert_Success(l_result, 'second create failed');

   l_req_id2 := result_Req_Id(l_result);

   l_result := MI_Request_Api.take_For_Proc(l_req_id2, 'first attempt');
   assert_Success(l_result, 'second take failed');

   l_result := MI_Request_Api.to_Error(l_req_id2);
   assert_Success(l_result, 'BUSY -> ERROR failed');

   assert_True(
      MI_Request_Api.get_Status(l_req_id2) = MI_Request_Api.STATUS_ERROR,
      'request is not ERROR'
   );

   l_result := MI_Request_Api.take_For_Proc(l_req_id2, 'retry');
   assert_Success(l_result, 'ERROR -> BUSY retry failed');

   assert_True(
      MI_Request_Api.get_Status(l_req_id2) = MI_Request_Api.STATUS_BUSY,
      'retry request is not BUSY'
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('7. SENT -> ERROR');

   l_result := MI_Request_Api.create_Request(p_inf_id => l_inf_id);
   assert_Success(l_result, 'third create failed');

   l_req_id3 := result_Req_Id(l_result);

   l_result := MI_Request_Api.take_For_Proc(l_req_id3);
   assert_Success(l_result, 'third take failed');

   l_result := MI_Request_Api.to_Sent(l_req_id3);
   assert_Success(l_result, 'third to_Sent failed');

   l_result := MI_Request_Api.to_Error(l_req_id3);
   assert_Success(l_result, 'SENT -> ERROR failed');

   assert_True(
      MI_Request_Api.get_Status(l_req_id3) = MI_Request_Api.STATUS_ERROR,
      'SENT -> ERROR final state mismatch'
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('8. reset is idempotent');

   l_result :=
      MI_Request_Api.reset(
         p_req_id => l_req_id2,
         p_info   => 'smoke reset'
      );

   assert_Success(l_result, 'reset BUSY -> NEW failed');

   assert_Equals(
      l_result.result_code,
      'REQUEST_RESET',
      'reset result code'
   );

   assert_True(
      MI_Request_Api.get_Status(l_req_id2) = MI_Request_Api.STATUS_NEW,
      'reset did not set NEW'
   );


   l_result := MI_Request_Api.reset(l_req_id2, 'second reset');

   assert_Success(l_result, 'idempotent reset(NEW) failed');

   assert_Equals(
      l_result.result_code,
      'REQUEST_ALREADY_NEW',
      'idempotent reset result code'
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('9. API does not commit caller transaction');

   ROLLBACK TO before_request_smoke;

   SELECT COUNT(*)
     INTO l_count
     FROM MI_REQ
    WHERE req_id IN (
       l_req_id,
       l_req_id2,
       l_req_id3,
       l_req_done_id
    );

   assert_True(
      l_count = 0,
      'MI_Request_Api committed caller transaction'
   );

   DBMS_OUTPUT.put_line('   OK');


   DBMS_OUTPUT.put_line('============================================================');
   DBMS_OUTPUT.put_line('MI_Request_Api smoke test PASSED');
   DBMS_OUTPUT.put_line('============================================================');

END;
/
