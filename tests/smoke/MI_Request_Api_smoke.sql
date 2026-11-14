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
   l_req_failure_id MI_REQ.REQ_ID%TYPE;

   l_status_cd     MI_REQ.STATUS_CD%TYPE;
   l_external_uuid MI_REQ.EXTERNAL_UUID%TYPE;
   l_corr_id       MI_REQ.CORRELATION_ID%TYPE;
   l_idsmr         MI_REQ.IDSMR%TYPE;
   l_note          MI_REQ.NOTE%TYPE;

   l_failure_uuid     MI_REQ.EXTERNAL_UUID%TYPE;
   l_message_uuid     MI_REQ.MESSAGE_UUID%TYPE;
   l_other_message    MI_REQ.MESSAGE_UUID%TYPE;
   l_result_code      MI_REQ.RESULT_CODE%TYPE;
   l_result_info      MI_REQ.RESULT_INFO%TYPE;
   l_result_time      MI_REQ.RESULT_TIME%TYPE;
   l_occurred_at      MI_REQ.RESULT_TIME%TYPE;

   l_ret_code       NUMBER;
   l_ret_info       VARCHAR2(4000);

   l_log_wsp_id    MI_LOG.WSP_ID%TYPE;
   l_log_inf_id    MI_LOG.INF_ID%TYPE;
   l_log_corr_id   MI_LOG.CORRELATION_ID%TYPE;

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
   MI_Logger.enable_Log;
   MI_Logger.set_Min_Level(MI_Logger.LEVEL_INFO);


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
   DBMS_OUTPUT.put_line('9. apply_Request_Failure contract');

   l_result := MI_Request_Api.create_Request(p_inf_id => l_inf_id);
   assert_Success(l_result, 'failure callback request create failed');

   l_req_failure_id := result_Req_Id(l_result);

   l_result :=
      MI_Request_Api.take_For_Proc(
         p_req_id => l_req_failure_id,
         p_info   => 'failure callback smoke'
      );

   assert_Success(l_result, 'failure callback take failed');

   l_result := MI_Request_Api.to_Sent(l_req_failure_id);
   assert_Success(l_result, 'failure callback to_Sent failed');

   SELECT external_uuid
     INTO l_failure_uuid
     FROM MI_REQ
    WHERE req_id = l_req_failure_id;

   l_message_uuid  := MI_Utils.uuid_V7;
   l_other_message := MI_Utils.uuid_V7;
   l_occurred_at   := SYSTIMESTAMP;


   /* Unsupported transport enum must not modify the SENT request. */
   MI_Request_Api.apply_Request_Failure(
      p_external_uuid => l_failure_uuid,
      p_message_uuid  => l_message_uuid,
      p_reason_code   => 'UNSUPPORTED_REASON',
      p_error_code    => 'SMOKE_REJECTED',
      p_error_info    => 'smoke transport rejection',
      p_error_details => 'smoke failure details',
      p_occurred_at   => l_occurred_at,
      p_ret_code      => l_ret_code,
      p_ret_info      => l_ret_info
   );

   assert_True(
      l_ret_code = MI_Request_Api.RET_FAIL,
      'unsupported reason was unexpectedly accepted'
   );

   assert_True(
      INSTR(l_ret_info, 'REQUEST_FAILURE_INVALID_REASON') > 0,
      'unsupported reason result code is missing'
   );

   assert_True(
      MI_Request_Api.get_Status(l_req_failure_id) = MI_Request_Api.STATUS_SENT,
      'invalid failure callback changed request status'
   );


   /* Lowercase input verifies normalization of the supported enum. */
   MI_Request_Api.apply_Request_Failure(
      p_external_uuid => l_failure_uuid,
      p_message_uuid  => l_message_uuid,
      p_reason_code   => 'request_rejected',
      p_error_code    => 'SMOKE_REJECTED',
      p_error_info    => 'smoke transport rejection',
      p_error_details => 'smoke failure details',
      p_occurred_at   => l_occurred_at,
      p_ret_code      => l_ret_code,
      p_ret_info      => l_ret_info
   );

   assert_True(
      l_ret_code = MI_Request_Api.RET_OK,
      'valid failure callback failed: ' || l_ret_info
   );

   assert_True(
      INSTR(l_ret_info, 'REQUEST_FAILURE_APPLIED') > 0,
      'applied result code is missing'
   );

   SELECT status_cd,
          message_uuid,
          result_code,
          result_info,
          note,
          result_time
     INTO l_status_cd,
          l_external_uuid,
          l_result_code,
          l_result_info,
          l_note,
          l_result_time
     FROM MI_REQ
    WHERE req_id = l_req_failure_id;

   assert_True(
      l_status_cd = MI_Request_Api.STATUS_ERROR,
      'failure callback did not set ERROR'
   );

   assert_Equals(
      TRIM(l_external_uuid),
      TRIM(l_message_uuid),
      'failure callback MESSAGE_UUID mismatch'
   );

   assert_Equals(l_result_code, 'SMOKE_REJECTED', 'RESULT_CODE mismatch');
   assert_Equals(l_result_info, 'smoke transport rejection', 'RESULT_INFO mismatch');
   assert_Equals(l_note, 'smoke failure details', 'NOTE mismatch');

   assert_True(
      l_result_time = l_occurred_at,
      'RESULT_TIME mismatch'
   );


   /* Same MESSAGE_UUID is an idempotent success and must not overwrite data. */
   MI_Request_Api.apply_Request_Failure(
      p_external_uuid => l_failure_uuid,
      p_message_uuid  => l_message_uuid,
      p_reason_code   => 'REQUEST_FAILED',
      p_error_code    => 'SHOULD_NOT_REPLACE',
      p_error_info    => 'SHOULD_NOT_REPLACE',
      p_error_details => 'SHOULD_NOT_REPLACE',
      p_occurred_at   => SYSTIMESTAMP,
      p_ret_code      => l_ret_code,
      p_ret_info      => l_ret_info
   );

   assert_True(
      l_ret_code = MI_Request_Api.RET_OK,
      'idempotent failure callback failed: ' || l_ret_info
   );

   assert_True(
      INSTR(l_ret_info, 'REQUEST_FAILURE_ALREADY_APPLIED') > 0,
      'idempotent result code is missing'
   );

   SELECT result_code,
          result_info,
          note,
          result_time
     INTO l_result_code,
          l_result_info,
          l_note,
          l_result_time
     FROM MI_REQ
    WHERE req_id = l_req_failure_id;

   assert_Equals(
      l_result_code,
      'SMOKE_REJECTED',
      'idempotent callback overwrote RESULT_CODE'
   );

   assert_Equals(
      l_result_info,
      'smoke transport rejection',
      'idempotent callback overwrote RESULT_INFO'
   );

   assert_Equals(
      l_note,
      'smoke failure details',
      'idempotent callback overwrote NOTE'
   );

   assert_True(
      l_result_time = l_occurred_at,
      'idempotent callback overwrote RESULT_TIME'
   );


   /* Different MESSAGE_UUID for terminal ERROR is a conflict. */
   MI_Request_Api.apply_Request_Failure(
      p_external_uuid => l_failure_uuid,
      p_message_uuid  => l_other_message,
      p_reason_code   => 'REQUEST_FAILED',
      p_error_code    => 'OTHER_MESSAGE',
      p_error_info    => 'other message',
      p_error_details => 'other message',
      p_occurred_at   => SYSTIMESTAMP,
      p_ret_code      => l_ret_code,
      p_ret_info      => l_ret_info
   );

   assert_True(
      l_ret_code = MI_Request_Api.RET_FAIL,
      'different terminal MESSAGE_UUID was unexpectedly accepted'
   );

   assert_True(
      INSTR(l_ret_info, 'REQUEST_FAILURE_CONFLICT') > 0,
      'conflict result code is missing'
   );

   DBMS_OUTPUT.put_line('   req_id=' || l_req_failure_id);
   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('10. MI_Logger_T propagates request context');

   SELECT COUNT(*)
     INTO l_count
     FROM MI_LOG
    WHERE LOGGER_NAME = 'mi.request'
      AND REQ_ID      = l_req_id
      AND ACTION_CODE IN (
             'create',
             'take_for_proc',
             'to_sent',
             'to_success'
          );

   assert_True(
      l_count = 4,
      'expected 4 lifecycle log rows, got ' || l_count
   );

   SELECT WSP_ID,
          INF_ID,
          CORRELATION_ID
     INTO l_log_wsp_id,
          l_log_inf_id,
          l_log_corr_id
     FROM MI_LOG
    WHERE LOGGER_NAME  = 'mi.request'
      AND REQ_ID       = l_req_id
      AND ACTION_CODE  = 'create'
      AND MESSAGE_TEXT = 'Request created';

   assert_True(l_log_wsp_id = l_wsp_id, 'log WSP_ID mismatch');
   assert_True(l_log_inf_id = l_inf_id, 'log INF_ID mismatch');

   assert_Equals(
      l_log_corr_id,
      l_corr_id,
      'log CORRELATION_ID mismatch'
   );

   SELECT COUNT(*)
     INTO l_count
     FROM MI_LOG
    WHERE LOGGER_NAME = 'mi.request'
      AND REQ_ID      = l_req_failure_id
      AND INF_ID      = l_inf_id
      AND ACTION_CODE = 'apply_failure'
      AND MESSAGE_TEXT = 'Request failure applied';

   assert_True(
      l_count = 1,
      'apply_Request_Failure log context mismatch'
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('11. API does not commit caller transaction');

   ROLLBACK TO before_request_smoke;

   SELECT COUNT(*)
     INTO l_count
     FROM MI_REQ
    WHERE req_id IN (
       l_req_id,
       l_req_id2,
       l_req_id3,
       l_req_done_id,
       l_req_failure_id
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
