SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK ON
SET VERIFY OFF

-- REAL TEST-TRANSPORT SMOKE. Requires explicit operator approval.
-- Run only for one disposable NEW/601 request routed to isolated CBS queues.
-- Start session B after the test transport has autonomously enqueued the
-- request, committed QSOK, and session A is still waiting for a response.

DEFINE APPROVED_REQ_ID = 0

DECLARE
   l_req_id              MI_REQ.REQ_ID%TYPE := &APPROVED_REQ_ID;
   l_call_uuid           VARCHAR2(36);
   l_bus_correlation_id  VARCHAR2(200);
   l_ret_code            NUMBER;
   l_ret_info            VARCHAR2(4000);
   l_state_cd            CHAR(1);
   l_attempt_count       PLS_INTEGER;

   PROCEDURE fail (p_message IN VARCHAR2)
   IS
   BEGIN
      RAISE_APPLICATION_ERROR(-20990, p_message);
   END fail;
BEGIN
   IF l_req_id IN (0, 351) THEN
      fail('Set APPROVED_REQ_ID to one disposable NEW/601 request, never 351');
   END IF;

   MI_0600_Api.claim_Manual_601(
      p_req_id             => l_req_id,
      p_call_uuid          => l_call_uuid,
      p_bus_correlation_id => l_bus_correlation_id,
      p_ret_code           => l_ret_code,
      p_ret_info           => l_ret_info
   );

   IF NVL(l_ret_code, -1) <> MI_0600_Api.RET_OK THEN
      ROLLBACK;
      fail('claim failed: ' || l_ret_info);
   END IF;

   DBMS_OUTPUT.put_line('CALL_UUID=' || l_call_uuid);
   DBMS_OUTPUT.put_line('CBS_ID=' || l_bus_correlation_id);
   DBMS_OUTPUT.put_line('Committing durable claim before BUS');
   COMMIT;

   DBMS_OUTPUT.put_line(
      'Starting controlled dispatch. Run session B only after autonomous QSOK is observed.'
   );

   MI_0600_Api.dispatch_Claimed_601(
      p_req_id    => l_req_id,
      p_call_uuid => l_call_uuid,
      p_ret_code  => l_ret_code,
      p_ret_info  => l_ret_info
   );

   SELECT STATE_CD
     INTO l_state_cd
     FROM MI_0600_SEND_ATTEMPT
    WHERE REQ_ID = l_req_id;

   DBMS_OUTPUT.put_line('dispatch ret_code=' || l_ret_code);
   DBMS_OUTPUT.put_line('dispatch ret_info=' || l_ret_info);
   DBMS_OUTPUT.put_line('attempt state=' || l_state_cd);

   -- Always persist S/U/N, including timeout/fault UNKNOWN.
   COMMIT;

   DBMS_OUTPUT.put_line('Verifying that a second dispatch cannot enqueue');

   MI_0600_Api.dispatch_Claimed_601(
      p_req_id    => l_req_id,
      p_call_uuid => l_call_uuid,
      p_ret_code  => l_ret_code,
      p_ret_info  => l_ret_info
   );

   IF NVL(l_ret_code, -1) = MI_0600_Api.RET_OK
      OR INSTR(l_ret_info, 'DISPATCH_CAPABILITY_MISSING') = 0
   THEN
      fail('second dispatch was not blocked: ' || l_ret_info);
   END IF;

   SELECT COUNT(*)
     INTO l_attempt_count
     FROM MI_0600_SEND_ATTEMPT
    WHERE REQ_ID = l_req_id;

   IF l_attempt_count <> 1 THEN
      fail('expected exactly one durable attempt');
   END IF;

   COMMIT;
   DBMS_OUTPUT.put_line('Session A completed; verify exactly one QSOK externally');
END;
/

