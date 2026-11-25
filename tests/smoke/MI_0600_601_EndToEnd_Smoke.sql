-- Run the entire block in the IDE SQL Window with DBMS Output enabled.
-- Use a clean Oracle session as the MI owner and an already captured request.

DECLARE
   l_req_id    CONSTANT NUMBER := 0; -- Replace with the actual REQ_ID.
   l_send      CONSTANT NUMBER := 0; -- 0 = status only, 1 = one approved NEW/601 send.
   l_result    MI_ResultCtx.exec_Result_t;
   l_exception VARCHAR2(4000);

   TYPE snapshot_t IS RECORD (
      inf_id        MI_REQ.INF_ID%TYPE,
      status_cd     MI_REQ.STATUS_CD%TYPE,
      itm_id        MI_0600.ITM_ID%TYPE,
      dsend_stamp   MI_0600.DSEND_STAMP%TYPE,
      zip_bytes     NUMBER,
      message_uuid  MI_0600.MESSAGE_UUID%TYPE,
      ires_code     MI_0600.IRES_CODE%TYPE,
      tres_time     MI_0600.TRES_TIME%TYPE,
      error_code    MI_0600.ERROR_CODE%TYPE
   );

   l_snapshot snapshot_t;

   PROCEDURE read_Snapshot
   IS
   BEGIN
      SELECT r.INF_ID, r.STATUS_CD, i.ITM_ID, i.DSEND_STAMP,
             DBMS_LOB.GETLENGTH(i.BZIP_DATA), i.MESSAGE_UUID, i.IRES_CODE,
             i.TRES_TIME, i.ERROR_CODE
        INTO l_snapshot
        FROM MI_REQ r
        LEFT JOIN MI_0600 i ON i.REQ_ID = r.REQ_ID
       WHERE r.REQ_ID = l_req_id;
   EXCEPTION
      WHEN NO_DATA_FOUND THEN
         RAISE_APPLICATION_ERROR(-20990, 'REQ_ID not found in MI_REQ');
      WHEN TOO_MANY_ROWS THEN
         RAISE_APPLICATION_ERROR(-20990, 'Expected at most one MI_0600 item for REQ_ID');
   END read_Snapshot;

   PROCEDURE print_Snapshot (p_phase IN VARCHAR2)
   IS
   BEGIN
      DBMS_OUTPUT.PUT_LINE('--- ' || p_phase || ' ---');
      DBMS_OUTPUT.PUT_LINE('REQ_ID=' || l_req_id || ' INF_ID=' || l_snapshot.inf_id);
      DBMS_OUTPUT.PUT_LINE('STATUS_CD=' || l_snapshot.status_cd
                          || ' (' || MI_Request_Api.status_Name(l_snapshot.status_cd) || ')');
      DBMS_OUTPUT.PUT_LINE('ITM_ID=' || NVL(TO_CHAR(l_snapshot.itm_id), '<null>')
                          || ' DSEND_STAMP='
                          || NVL(TO_CHAR(l_snapshot.dsend_stamp, 'YYYY-MM-DD HH24:MI:SS.FF3'), '<null>'));
      DBMS_OUTPUT.PUT_LINE('IRES_CODE=' || NVL(TO_CHAR(l_snapshot.ires_code), '<null>')
                          || ' TRES_TIME='
                          || NVL(TO_CHAR(l_snapshot.tres_time, 'YYYY-MM-DD HH24:MI:SS.FF3'), '<null>'));
      DBMS_OUTPUT.PUT_LINE('ERROR_CODE=' || NVL(l_snapshot.error_code, '<null>')
                          || ' MESSAGE_UUID=' || NVL(TRIM(l_snapshot.message_uuid), '<null>'));
   END print_Snapshot;

   PROCEDURE print_Result_Parameter (p_key IN VARCHAR2)
   IS
   BEGIN
      IF l_result.parameters.EXISTS(p_key) THEN
         DBMS_OUTPUT.PUT_LINE(p_key || '=' || l_result.parameters(p_key));
      END IF;
   END print_Result_Parameter;
BEGIN
   IF l_req_id IS NULL OR l_req_id <= 0 OR l_req_id <> TRUNC(l_req_id)
      OR l_send IS NULL OR l_send NOT IN (0, 1)
   THEN
      RAISE_APPLICATION_ERROR(-20990, 'Enter a positive integer REQ_ID and mode 0 or 1');
   END IF;

   IF l_send = 1 AND l_req_id = 351 THEN
      RAISE_APPLICATION_ERROR(-20990, 'REQ_ID=351 is history. Use mode 0');
   END IF;

   read_Snapshot;
   IF l_send = 0 THEN
      print_Snapshot('STATUS ONLY');
      RETURN;
   END IF;

   print_Snapshot('BEFORE SEND');
   IF NVL(l_snapshot.inf_id, -1) <> 601
      OR NVL(l_snapshot.status_cd, -1) <> MI_Request_Api.STATUS_NEW
      OR l_snapshot.itm_id IS NULL
      OR NVL(l_snapshot.zip_bytes, 0) = 0
      OR l_snapshot.dsend_stamp IS NOT NULL
   THEN
      RAISE_APPLICATION_ERROR(-20990, 'Send requires NEW/601 with a ZIP and no DSEND_STAMP');
   END IF;

   BEGIN
      MI_mbus.send_Request(p_req_id => l_req_id, p_result => l_result);
   EXCEPTION
      WHEN OTHERS THEN
         l_exception := SQLERRM;
   END;

   DBMS_OUTPUT.PUT_LINE('--- MULTI-BUS / XXL ---');
   IF l_exception IS NOT NULL THEN
      DBMS_OUTPUT.PUT_LINE('EXCEPTION=' || l_exception);
   ELSE
      DBMS_OUTPUT.PUT_LINE('RESULT_CODE=' || NVL(l_result.result_code, '<null>'));
      DBMS_OUTPUT.PUT_LINE('RESULT_INFO=' || NVL(l_result.result_info, '<null>'));
      DBMS_OUTPUT.PUT_LINE('CAUSE_CODE=' || NVL(l_result.cause_code, '<null>'));
      DBMS_OUTPUT.PUT_LINE('CAUSE_INFO=' || NVL(l_result.cause_info, '<null>'));
      print_Result_Parameter('bus_result_code');
      print_Result_Parameter('response_size');
      print_Result_Parameter('call_uuid');
      print_Result_Parameter('bus_correlation_id');
      print_Result_Parameter('delivery_outcome');
   END IF;

   read_Snapshot;
   print_Snapshot('AFTER SEND');

   IF l_exception IS NULL AND MI_ResultCtx.is_Success(l_result)
      AND l_result.result_code = 'SEND_PUBLISHED'
      AND l_snapshot.status_cd IN (MI_Request_Api.STATUS_SENT, MI_Request_Api.STATUS_DONE)
      AND l_snapshot.dsend_stamp IS NOT NULL
   THEN
      DBMS_OUTPUT.PUT_LINE('PUBLISH_SMOKE=PASS');
   ELSE
      DBMS_OUTPUT.PUT_LINE('PUBLISH_SMOKE=CHECK_REQUIRED. Use mode 0 to check again');
   END IF;
END;
