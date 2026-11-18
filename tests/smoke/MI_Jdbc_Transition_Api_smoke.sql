SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK ON
SET VERIFY OFF

PROMPT ============================================================
PROMPT MI JDBC transition API smoke test
PROMPT ============================================================

DECLARE
   l_inf_id        MI_INF.INF_ID%TYPE;

   l_req_id        MI_REQ.REQ_ID%TYPE;
   l_error_req_id  MI_REQ.REQ_ID%TYPE;
   l_rsp_id        MI_RSP.RSP_ID%TYPE;

   l_ret_code      NUMBER;
   l_ret_info      VARCHAR2(4000);
   l_result        MI_ResultCtx.exec_Result_t;


   ---------------------------------------------------------------------------
   PROCEDURE fail (
      p_message IN VARCHAR2
   )
   IS
   BEGIN
      RAISE_APPLICATION_ERROR(
         -20990,
         'MI JDBC transition API smoke failed: ' || p_message
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
   PROCEDURE assert_Ret_Ok (
      p_operation    IN VARCHAR2,
      p_result_code  IN VARCHAR2
   )
   IS
   BEGIN
      IF l_ret_code <> 0 OR l_ret_code IS NULL THEN
         fail(
              p_operation
           || ' returned ret_code='
           || NVL(TO_CHAR(l_ret_code), '<NULL>')
           || ', ret_info='
           || NVL(l_ret_info, '<NULL>')
         );
      END IF;

      assert_True(
         l_ret_info IS NOT NULL,
         p_operation || ' returned empty ret_info'
      );

      assert_True(
         INSTR(l_ret_info, p_result_code || ':') = 1,
         p_operation || ' lost result code; ret_info=' || l_ret_info
      );
   END assert_Ret_Ok;


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
      WHEN NO_DATA_FOUND OR VALUE_ERROR THEN
         fail('result does not contain numeric parameter ' || p_parameter);
         RETURN NULL;
   END result_Id;


   ---------------------------------------------------------------------------
   FUNCTION create_Request
      RETURN MI_REQ.REQ_ID%TYPE
   IS
      l_create_result MI_ResultCtx.exec_Result_t;
   BEGIN
      l_create_result :=
         MI_Request_Api.create_Request(
            p_inf_id => l_inf_id
         );

      IF MI_ResultCtx.is_Failed(l_create_result) THEN
         fail(
              'create_Request failed: '
           || NVL(l_create_result.result_code, '<NULL>')
           || ': '
           || NVL(l_create_result.result_info, '<NULL>')
         );
      END IF;

      RETURN result_Id(l_create_result, 'req_id');
   END create_Request;


BEGIN
   SAVEPOINT before_jdbc_transition_smoke;


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


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('1. MI_Request_Api JDBC success transitions');

   l_req_id := create_Request;

   MI_Request_Api.take_For_Proc(
      l_req_id,
      'JDBC ABI smoke',
      l_ret_code,
      l_ret_info
   );

   assert_Ret_Ok('MI_Request_Api.take_For_Proc', 'REQUEST_TAKEN');
   assert_True(
      MI_Request_Api.get_Status(l_req_id) = MI_Request_Api.STATUS_BUSY,
      'take_For_Proc did not set BUSY'
   );

   MI_Request_Api.to_Sent(
      l_req_id,
      l_ret_code,
      l_ret_info
   );

   assert_Ret_Ok('MI_Request_Api.to_Sent', 'REQUEST_SENT');
   assert_True(
      MI_Request_Api.get_Status(l_req_id) = MI_Request_Api.STATUS_SENT,
      'to_Sent did not set SENT'
   );


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('2. MI_Response_Api JDBC success transition');

   l_result :=
      MI_Response_Api.create_Response(
         p_req_id      => l_req_id,
         p_itm_id      => l_req_id,
         p_category_cd => 'SUCCESS',
         p_result_code => 'OK',
         p_result_info => 'JDBC ABI smoke',
         p_payload     => TO_CLOB('{"ok":true}')
      );

   IF MI_ResultCtx.is_Failed(l_result) THEN
      fail(
           'create_Response failed: '
        || NVL(l_result.result_code, '<NULL>')
        || ': '
        || NVL(l_result.result_info, '<NULL>')
      );
   END IF;

   l_rsp_id := result_Id(l_result, 'rsp_id');

   l_result := MI_Response_Api.to_Ready(l_rsp_id);

   IF MI_ResultCtx.is_Failed(l_result) THEN
      fail(
           'to_Ready failed: '
        || NVL(l_result.result_code, '<NULL>')
        || ': '
        || NVL(l_result.result_info, '<NULL>')
      );
   END IF;

   MI_Response_Api.to_Sent(
      l_rsp_id,
      l_ret_code,
      l_ret_info
   );

   assert_Ret_Ok('MI_Response_Api.to_Sent', 'RESPONSE_SENT');
   assert_True(
      MI_Response_Api.get_Status(l_rsp_id) = MI_Response_Api.STATUS_SENT,
      'response to_Sent did not set SENT'
   );

   MI_Response_Api.to_Sent(
      l_rsp_id,
      l_ret_code,
      l_ret_info
   );

   assert_True(
      l_ret_code = MI_Response_Api.RET_FAIL,
      'response bad status did not return RET_FAIL; ret_info=' || l_ret_info
   );
   assert_True(
      INSTR(l_ret_info, 'RESPONSE_BAD_STATUS:') = 1,
      'response bad status lost result code: ' || l_ret_info
   );
   assert_True(
      MI_Response_Api.get_Status(l_rsp_id) = MI_Response_Api.STATUS_SENT,
      'failed response wrapper call changed response status'
   );


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('3. MI_Request_Api JDBC DONE transition');

   MI_Request_Api.to_Success(
      l_req_id,
      l_ret_code,
      l_ret_info
   );

   assert_Ret_Ok('MI_Request_Api.to_Success', 'REQUEST_DONE');
   assert_True(
      MI_Request_Api.get_Status(l_req_id) = MI_Request_Api.STATUS_DONE,
      'to_Success did not set DONE'
   );


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('4. MI_Request_Api JDBC ERROR transition');

   l_error_req_id := create_Request;

   MI_Request_Api.take_For_Proc(
      l_error_req_id,
      'JDBC ABI smoke error path',
      l_ret_code,
      l_ret_info
   );

   assert_Ret_Ok(
      'MI_Request_Api.take_For_Proc(error path)',
      'REQUEST_TAKEN'
   );

   MI_Request_Api.to_Error(
      l_error_req_id,
      l_ret_code,
      l_ret_info
   );

   assert_Ret_Ok('MI_Request_Api.to_Error', 'REQUEST_ERROR');
   assert_True(
      MI_Request_Api.get_Status(l_error_req_id) = MI_Request_Api.STATUS_ERROR,
      'to_Error did not set ERROR'
   );


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('5. JDBC wrapper failure mapping');

   MI_Request_Api.to_Sent(
      l_req_id,
      l_ret_code,
      l_ret_info
   );

   assert_True(
      l_ret_code = MI_Request_Api.RET_FAIL,
      'bad status did not return RET_FAIL; ret_info=' || l_ret_info
   );
   assert_True(
      INSTR(l_ret_info, 'REQUEST_BAD_STATUS:') = 1,
      'bad status ret_info lost result code: ' || l_ret_info
   );
   assert_True(
      MI_Request_Api.get_Status(l_req_id) = MI_Request_Api.STATUS_DONE,
      'failed wrapper call changed request status'
   );


   ROLLBACK TO before_jdbc_transition_smoke;

   DBMS_OUTPUT.put_line('MI JDBC transition API smoke test passed.');

EXCEPTION
   WHEN OTHERS THEN
      ROLLBACK TO before_jdbc_transition_smoke;
      RAISE;
END;
/

PROMPT ============================================================
PROMPT MI JDBC transition API smoke test completed successfully
PROMPT ============================================================
