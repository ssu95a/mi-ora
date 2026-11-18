SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK ON
SET VERIFY OFF

-- Run while session A is inside queryBusClob after autonomous enqueue/QSOK.

DEFINE APPROVED_REQ_ID = 0

DECLARE
   l_req_id           MI_REQ.REQ_ID%TYPE := &APPROVED_REQ_ID;
   l_dummy            NUMBER;
   l_ret_code         NUMBER;
   l_ret_info         VARCHAR2(4000);
   l_state_cd         CHAR(1);
   l_receive_entered  NUMBER;

   PROCEDURE fail (p_message IN VARCHAR2)
   IS
   BEGIN
      RAISE_APPLICATION_ERROR(-20990, p_message);
   END fail;
BEGIN
   IF l_req_id IN (0, 351) THEN
      fail('Set APPROVED_REQ_ID to the request used by session A, never 351');
   END IF;

   DBMS_OUTPUT.put_line('1. proving dispatch holds no MI_REQ/attempt row lock');

   SELECT REQ_ID
     INTO l_dummy
     FROM MI_REQ
    WHERE REQ_ID = l_req_id
      FOR UPDATE NOWAIT;

   SELECT REQ_ID
     INTO l_dummy
     FROM MI_0600_SEND_ATTEMPT
    WHERE REQ_ID = l_req_id
      FOR UPDATE NOWAIT;

   ROLLBACK;
   DBMS_OUTPUT.put_line('   both NOWAIT row locks acquired: OK');

   DBMS_OUTPUT.put_line('2. reconcile must see shared user lock and skip QUERY_RECEIVE');

   MI_0600_Api.reconcile_Manual_601(
      p_req_id   => l_req_id,
      p_ret_code => l_ret_code,
      p_ret_info => l_ret_info
   );

   IF NVL(l_ret_code, 0) <> MI_0600_Api.RET_FAIL
      OR INSTR(l_ret_info, 'DISPATCH_ACTIVE') = 0
   THEN
      fail('reconcile did not return DISPATCH_ACTIVE: ' || l_ret_info);
   END IF;

   SELECT STATE_CD,
          RECEIVE_ENTERED
     INTO l_state_cd,
          l_receive_entered
     FROM MI_0600_SEND_ATTEMPT
    WHERE REQ_ID = l_req_id;

   IF l_state_cd <> 'C' THEN
      fail('busy reconcile changed attempt state to ' || l_state_cd);
   END IF;

   IF l_receive_entered IS NOT NULL THEN
      fail('busy reconcile persisted receive evidence');
   END IF;

   COMMIT;
   DBMS_OUTPUT.put_line('   DISPATCH_ACTIVE; receive not entered: OK');
END;
/

