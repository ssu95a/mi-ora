SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK ON
SET VERIFY OFF

PROMPT ============================================================
PROMPT MI_0600 manual 601 non-live smoke
PROMPT WARNING: run only in a disposable/non-production schema.
PROMPT No Multi-Bus enqueue is performed by this script.
PROMPT ============================================================

DECLARE
   l_req_id              MI_REQ.REQ_ID%TYPE;
   l_itm_id              MI_0600.ITM_ID%TYPE;
   l_call_uuid           VARCHAR2(36);
   l_bus_correlation_id  VARCHAR2(200);
   l_ret_code            NUMBER;
   l_ret_info            VARCHAR2(4000);
   l_zip_blob            BLOB;

   l_route_result        MI_ResultCtx.exec_Result_t;
   l_mbus_result         MI_ResultCtx.exec_Result_t;
   l_gate_alias          VARCHAR2(100);
   l_request_queue       VARCHAR2(100);
   l_response_queue      VARCHAR2(100);
   l_timeout_sec         PLS_INTEGER;

   l_pinned_gate         VARCHAR2(100);
   l_pinned_request      VARCHAR2(100);
   l_pinned_response     VARCHAR2(100);
   l_pinned_timeout      PLS_INTEGER;
   l_state_cd            CHAR(1);
   l_transport_entered   NUMBER;
   l_status_cd           MI_REQ.STATUS_CD%TYPE;
   l_dsend_stamp         MI_0600.DSEND_STAMP%TYPE;
   l_tx_id               VARCHAR2(100);
   l_count_before        PLS_INTEGER;
   l_count_after         PLS_INTEGER;

   PROCEDURE fail (p_message IN VARCHAR2)
   IS
   BEGIN
      RAISE_APPLICATION_ERROR(
         -20990,
         'MI_0600 manual 601 smoke failed: ' || p_message
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

   PROCEDURE cleanup
   IS
   BEGIN
      ROLLBACK;

      IF l_req_id IS NOT NULL THEN
         DELETE FROM MI_REQ
          WHERE REQ_ID = l_req_id;
         COMMIT;
      END IF;

      IF DBMS_LOB.istemporary(l_zip_blob) = 1 THEN
         DBMS_LOB.freetemporary(l_zip_blob);
      END IF;
   EXCEPTION
      WHEN OTHERS THEN
         ROLLBACK;
   END cleanup;
BEGIN
   DBMS_LOB.createtemporary(l_zip_blob, TRUE);
   DBMS_LOB.writeappend(
      l_zip_blob,
      22,
      HEXTORAW('504B0506000000000000000000000000000000000000')
   );

   DBMS_OUTPUT.put_line('1. create disposable NEW/601 fixture');

   MI_0600_Api.create_Request(
      p_inf_id            => 601,
      p_czip_name         =>
            'MANUAL_601_SMOKE_'
         || REPLACE(MI_Utils.uuid_V7, '-', '')
         || '.zip',
      p_bzip_data         => l_zip_blob,
      p_izip_size         => DBMS_LOB.getlength(l_zip_blob),
      p_izip_files_count  => 1,
      p_file_names        => SYS.ODCIVARCHAR2LIST('manual-601-smoke.xml'),
      p_original_req_uuid => NULL,
      p_message_uuid      => NULL,
      p_ctaxreq_id        => NULL,
      p_icreate_type      => 0,
      p_req_id            => l_req_id,
      p_itm_id            => l_itm_id,
      p_ret_code          => l_ret_code,
      p_ret_info          => l_ret_info
   );

   assert_True(
      l_ret_code = MI_0600_Api.RET_OK,
      'fixture creation failed: ' || l_ret_info
   );
   COMMIT;
   DBMS_OUTPUT.put_line('   REQ_ID=' || l_req_id || ' OK');

   DBMS_OUTPUT.put_line('2. claim pins route and opens caller transaction');

   MI_0600_Api.claim_Manual_601(
      p_req_id             => l_req_id,
      p_call_uuid          => l_call_uuid,
      p_bus_correlation_id => l_bus_correlation_id,
      p_ret_code           => l_ret_code,
      p_ret_info           => l_ret_info
   );

   assert_True(
      l_ret_code = MI_0600_Api.RET_OK,
      'claim failed: ' || l_ret_info
   );

   l_tx_id := DBMS_TRANSACTION.LOCAL_TRANSACTION_ID(FALSE);
   assert_True(l_tx_id IS NOT NULL, 'claim did not open a transaction');

   SELECT GATE_ALIAS,
          REQUEST_QUEUE,
          RESPONSE_QUEUE,
          TIMEOUT_SEC,
          STATE_CD,
          TRANSPORT_ENTERED
     INTO l_pinned_gate,
          l_pinned_request,
          l_pinned_response,
          l_pinned_timeout,
          l_state_cd,
          l_transport_entered
     FROM MI_0600_SEND_ATTEMPT
    WHERE REQ_ID = l_req_id;

   MI_mbus.resolve_Request_Route(
      p_req_id         => l_req_id,
      p_gate_alias     => l_gate_alias,
      p_request_queue  => l_request_queue,
      p_response_queue => l_response_queue,
      p_timeout_sec    => l_timeout_sec,
      p_result         => l_route_result
   );

   assert_True(
      MI_ResultCtx.is_Success(l_route_result),
      'route resolver failed'
   );
   assert_True(l_pinned_gate = l_gate_alias, 'gate alias was not pinned');
   assert_True(l_pinned_request = l_request_queue, 'request queue was not pinned');
   assert_True(l_pinned_response = l_response_queue, 'response queue was not pinned');
   assert_True(l_pinned_timeout = l_timeout_sec, 'timeout was not pinned');
   assert_True(l_state_cd = 'C', 'attempt is not CLAIMED');
   assert_True(l_transport_entered IS NULL, 'transport was entered during claim');
   DBMS_OUTPUT.put_line('   CALL_UUID=' || l_call_uuid);
   DBMS_OUTPUT.put_line('   CBS_ID=' || l_bus_correlation_id);
   DBMS_OUTPUT.put_line('   OK');

   DBMS_OUTPUT.put_line('3. omitted claim COMMIT rejects dispatch before BUS');

   MI_0600_Api.dispatch_Claimed_601(
      p_req_id    => l_req_id,
      p_call_uuid => l_call_uuid,
      p_ret_code  => l_ret_code,
      p_ret_info  => l_ret_info
   );

   assert_True(l_ret_code = MI_0600_Api.RET_FAIL, 'dispatch unexpectedly succeeded');
   assert_True(
      INSTR(l_ret_info, 'CLAIM_COMMIT_REQUIRED') > 0,
      'unexpected missing-COMMIT result: ' || l_ret_info
   );

   SELECT a.STATE_CD,
          a.TRANSPORT_ENTERED,
          r.STATUS_CD,
          h.DSEND_STAMP
     INTO l_state_cd,
          l_transport_entered,
          l_status_cd,
          l_dsend_stamp
     FROM MI_0600_SEND_ATTEMPT a
     JOIN MI_REQ r
       ON r.REQ_ID = a.REQ_ID
     JOIN MI_0600 h
       ON h.REQ_ID = a.REQ_ID
    WHERE a.REQ_ID = l_req_id;

   assert_True(l_state_cd = 'C', 'missing-COMMIT changed attempt state');
   assert_True(l_transport_entered IS NULL, 'missing-COMMIT entered transport');
   assert_True(l_status_cd = MI_Request_Api.STATUS_NEW, 'missing-COMMIT changed request');
   assert_True(l_dsend_stamp IS NULL, 'missing-COMMIT stamped request');
   COMMIT;
   DBMS_OUTPUT.put_line('   OK');

   DBMS_OUTPUT.put_line('4. ordinary MI_mbus path cannot bypass managed 601');

   MI_mbus.send_Request(
      p_req_id => l_req_id,
      p_result => l_mbus_result
   );

   assert_True(MI_ResultCtx.is_Failed(l_mbus_result), 'ordinary send unexpectedly succeeded');
   assert_True(
      l_mbus_result.result_code =
         'MI_MBUS.SEND_REQUEST#MANAGED_601_REQUIRED',
      'unexpected bypass result: ' || NVL(l_mbus_result.result_code, '<NULL>')
   );

   SELECT STATE_CD,
          TRANSPORT_ENTERED
     INTO l_state_cd,
          l_transport_entered
     FROM MI_0600_SEND_ATTEMPT
    WHERE REQ_ID = l_req_id;

   assert_True(l_state_cd = 'C', 'ordinary send changed attempt state');
   assert_True(l_transport_entered IS NULL, 'ordinary send entered transport');
   DBMS_OUTPUT.put_line('   OK');

   DBMS_OUTPUT.put_line('5. JDBC send_Pending remains fail-closed');

   MI_0600_Api.send_Pending(l_ret_code, l_ret_info);
   assert_True(l_ret_code = MI_0600_Api.RET_FAIL, 'send_Pending must fail closed');
   assert_True(
      INSTR(l_ret_info, 'MI_0600_SEND_PENDING_UNSUPPORTED') = 1,
      'send_Pending contract changed: ' || l_ret_info
   );
   DBMS_OUTPUT.put_line('   OK');

   DBMS_OUTPUT.put_line('6. REQ_ID=351 rejected before attempt DML');

   SELECT COUNT(*)
     INTO l_count_before
     FROM MI_0600_SEND_ATTEMPT
    WHERE REQ_ID = 351;

   MI_0600_Api.claim_Manual_601(
      p_req_id             => 351,
      p_call_uuid          => l_call_uuid,
      p_bus_correlation_id => l_bus_correlation_id,
      p_ret_code           => l_ret_code,
      p_ret_info           => l_ret_info
   );

   SELECT COUNT(*)
     INTO l_count_after
     FROM MI_0600_SEND_ATTEMPT
    WHERE REQ_ID = 351;

   assert_True(l_ret_code = MI_0600_Api.RET_FAIL, 'REQ_ID=351 was accepted');
   assert_True(
      INSTR(l_ret_info, 'REQ_ID_351_FORBIDDEN') > 0,
      'unexpected REQ_ID=351 result: ' || l_ret_info
   );
   assert_True(l_count_after = l_count_before, 'REQ_ID=351 attempt DML occurred');
   DBMS_OUTPUT.put_line('   OK');

   cleanup;
   DBMS_OUTPUT.put_line('MI_0600 manual 601 non-live smoke passed');

EXCEPTION
   WHEN OTHERS THEN
      cleanup;
      RAISE;
END;
/

