SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK ON
SET VERIFY OFF
SET DEFINE OFF

PROMPT ============================================================
PROMPT MI_mbus smoke test
PROMPT ============================================================

DECLARE
   l_result          MI_ResultCtx.exec_Result_t;
   l_create_result   MI_ResultCtx.exec_Result_t;

   l_req_id          MI_REQ.REQ_ID%TYPE;
   l_rsp_req_id      MI_REQ.REQ_ID%TYPE;
   l_rsp_id          MI_RSP.RSP_ID%TYPE;

   l_missing_req_id  MI_REQ.REQ_ID%TYPE;
   l_missing_rsp_id  MI_RSP.RSP_ID%TYPE;

   l_status_before   NUMBER;
   l_status_after    NUMBER;
   l_count           PLS_INTEGER;
   l_parser_error    BOOLEAN;
   l_response_xml    CLOB;
   l_boundary_value  VARCHAR2(2001);
   l_encoded_value   VARCHAR2(6000);


   ---------------------------------------------------------------------------
   PROCEDURE fail (
      p_message IN VARCHAR2
   )
   IS
   BEGIN
      RAISE_APPLICATION_ERROR(
         -20990,
         'MI_mbus smoke test failed: ' || p_message
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
   PROCEDURE assert_Code (
      p_result         IN MI_ResultCtx.exec_Result_t,
      p_expected_code  IN VARCHAR2,
      p_expected_ok    IN BOOLEAN,
      p_context        IN VARCHAR2
   )
   IS
   BEGIN
      IF p_expected_ok THEN
         assert_True(
            MI_ResultCtx.is_Success(p_result),
            p_context
            || ': expected success for code='
            || NVL(p_result.result_code, '<NULL>')
         );
      ELSE
         assert_True(
            MI_ResultCtx.is_Failed(p_result),
            p_context
            || ': expected failure for code='
            || NVL(p_result.result_code, '<NULL>')
         );
      END IF;

      assert_True(
         p_result.result_code = p_expected_code,
         p_context
         || ': expected code='
         || p_expected_code
         || ', actual='
         || NVL(p_result.result_code, '<NULL>')
         || ', info='
         || NVL(p_result.result_info, '<NULL>')
      );
   END assert_Code;


   ---------------------------------------------------------------------------
   PROCEDURE assert_Parse_Error (
      p_xml              IN CLOB,
      p_context          IN VARCHAR2,
      p_expected_action  IN VARCHAR2 DEFAULT NULL
   )
   IS
      l_parse_result  MI_ResultCtx.exec_Result_t;
      l_error_code    PLS_INTEGER;
   BEGIN
      BEGIN
         l_parse_result :=
            MI_ResultCtx.result_From_Xml(
               p_xml             => p_xml,
               p_expected_action => p_expected_action
            );
      EXCEPTION
         WHEN OTHERS THEN
            l_error_code := SQLCODE;
      END;

      assert_True(
         l_error_code = -20011,
         p_context
         || ': expected parser error -20011, actual='
         || NVL(TO_CHAR(l_error_code), '<NONE>')
      );
   END assert_Parse_Error;


   ---------------------------------------------------------------------------
   FUNCTION result_Id (
      p_result  IN MI_ResultCtx.exec_Result_t,
      p_name    IN VARCHAR2
   )
      RETURN NUMBER
   IS
   BEGIN
      IF NOT p_result.parameters.EXISTS(p_name) THEN
         fail('result parameter is absent: ' || p_name);
      END IF;

      RETURN TO_NUMBER(p_result.parameters(p_name));
   END result_Id;


BEGIN
   SAVEPOINT before_mi_mbus_smoke;

   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('0. XXLResponse parser preserves structured result');

   l_response_xml :=
      TO_CLOB(
         q'~<XXLResponse version="1.1" action="send" is_success="true" result_code="SEND_PUBLISHED" result_info="Published"><details>ok</details><parameters>[{"name":"published","value":"true"},{"name":"attempt","value":"2"},{"name":"name","value":"A\u0026B"},{"name":"nested","value":"{\"x\":1}"},{"name":"none","value":null}]</parameters></XXLResponse>~'
      );

   l_result :=
      MI_ResultCtx.result_From_Xml(
         p_xml             => l_response_xml,
         p_expected_action => 'send'
      );

   assert_Code(l_result, 'SEND_PUBLISHED', TRUE, 'successful XXLResponse');
   assert_True(
      DBMS_LOB.SUBSTR(l_result.result_details, 100, 1) = 'ok',
      'XXLResponse details were not parsed'
   );
   assert_True(
      l_result.parameters.EXISTS('published')
      AND l_result.parameters('published') = 'true',
      'boolean response parameter was not parsed'
   );
   assert_True(
      l_result.parameters.EXISTS('attempt')
      AND l_result.parameters('attempt') = '2',
      'numeric response parameter was not parsed'
   );
   assert_True(
      l_result.parameters.EXISTS('name')
      AND l_result.parameters('name') = 'A&B',
      'string response parameter was not decoded'
   );
   assert_True(
      l_result.parameters.EXISTS('nested')
      AND l_result.parameters('nested') = '{"x":1}',
      'nested response parameter was not preserved as JSON'
   );
   assert_True(
      l_result.parameters.EXISTS('none')
      AND l_result.parameters('none') IS NULL,
      'null response parameter was not preserved'
   );
   assert_True(
      l_result.parameters('xml_version') = '1.1'
      AND l_result.parameters('xml_action') = 'send',
      'XXLResponse metadata was not preserved'
   );

   l_response_xml :=
      TO_CLOB(
         q'~<XXLResponse version="1.1" action="send" is_success="false" result_code="SEND_FAILED" result_info="Failed" cause_code="REMOTE_ERROR" cause_info="Remote failure"><details>business details</details><cause_details>cause details</cause_details><parameters>[]</parameters></XXLResponse>~'
      );

   l_result :=
      MI_ResultCtx.result_From_Xml(
         p_xml             => l_response_xml,
         p_expected_action => 'refresh'
      );

   assert_Code(l_result, 'SEND_FAILED', FALSE, 'failed XXLResponse');
   assert_True(
      l_result.cause_code = 'REMOTE_ERROR'
      AND l_result.cause_info = 'Remote failure',
      'XXLResponse cause was not parsed'
   );
   assert_True(
      DBMS_LOB.SUBSTR(l_result.cause_details, 100, 1) = 'cause details',
      'XXLResponse cause_details were not parsed'
   );

   assert_Parse_Error(
      p_xml =>
         TO_CLOB(
            q'~<XXLResponse action="refresh" is_success="true" result_code="REFRESH_OK" result_info="Completed"><parameters>[]</parameters></XXLResponse>~'
         ),
      p_context         => 'versionless XXLResponse',
      p_expected_action => 'refresh'
   );

   assert_Parse_Error(
      p_xml =>
         TO_CLOB(
            q'~<XXLResponse version="2.0" action="refresh" is_success="true" result_code="REFRESH_OK"><parameters>[]</parameters></XXLResponse>~'
         ),
      p_context         => 'unsupported XXLResponse version',
      p_expected_action => 'refresh'
   );

   assert_Parse_Error(
      p_xml =>
         TO_CLOB(
            q'~<XXLResponse version="1.1" action="send" is_success="true" result_code="REFRESH_OK"><parameters>[]</parameters></XXLResponse>~'
         ),
      p_context         => 'successful response with wrong action',
      p_expected_action => 'refresh'
   );

   assert_Parse_Error(
      p_xml =>
         TO_CLOB(
            q'~<XXLResponse version="1.1" is_success="true" result_code="REFRESH_OK"><parameters>[]</parameters></XXLResponse>~'
         ),
      p_context         => 'successful response without action',
      p_expected_action => 'refresh'
   );

   l_boundary_value := RPAD('x', 2000, 'x');
   l_response_xml :=
      TO_CLOB(
            '<XXLResponse version="1.1" action="send" is_success="true" '
         || 'result_code="SEND_OK"><parameters>[{"name":"boundary","value":"'
         || l_boundary_value
         || '"}]</parameters></XXLResponse>'
      );

   l_result :=
      MI_ResultCtx.result_From_Xml(
         p_xml             => l_response_xml,
         p_expected_action => 'send'
      );
   assert_True(
      LENGTH(l_result.parameters('boundary')) = 2000,
      '2000-character JSON parameter was not preserved'
   );

   l_boundary_value := l_boundary_value || 'x';
   assert_Parse_Error(
      p_xml =>
         TO_CLOB(
               '<XXLResponse version="1.1" action="send" is_success="true" '
            || 'result_code="SEND_OK"><parameters>[{"name":"overlong","value":"'
            || l_boundary_value
            || '"}]</parameters></XXLResponse>'
         ),
      p_context         => '2001-character JSON parameter',
      p_expected_action => 'send'
   );

   l_encoded_value :=
      RPAD(CHR(92) || 'u0041', 6000, CHR(92) || 'u0041');
   l_response_xml :=
      TO_CLOB(
            '<XXLResponse version="1.1" action="send" is_success="true" '
         || 'result_code="SEND_OK"><parameters>[{"name":"encoded","value":"'
         || l_encoded_value
         || '"}]</parameters></XXLResponse>'
      );

   l_result :=
      MI_ResultCtx.result_From_Xml(
         p_xml             => l_response_xml,
         p_expected_action => 'send'
      );
   assert_True(
      LENGTH(l_result.parameters('encoded')) = 1000
      AND l_result.parameters('encoded') = RPAD('A', 1000, 'A'),
      'long encoded JSON string was not decoded exactly'
   );

   assert_Parse_Error(
      p_xml =>
         TO_CLOB(
            q'~<XXLResponse version="1.1" action="send" is_success="true" result_code="SEND_OK"><parameters>[{"name":"nested","value":{"x":1}}]</parameters></XXLResponse>~'
         ),
      p_context         => 'non-string JSON parameter value',
      p_expected_action => 'send'
   );

   assert_Parse_Error(
      p_xml =>
         TO_CLOB(
               '<XXLResponse version="1.1" action="send" is_success="true" '
            || 'result_code="SEND_OK"><parameters>[{"name":"'
            || RPAD('n', 101, 'n')
            || '","value":"1"}]</parameters></XXLResponse>'
         ),
      p_context         => 'overlong JSON parameter name',
      p_expected_action => 'send'
   );

   assert_Parse_Error(
      p_xml =>
         TO_CLOB(
            q'~<XXLResponse version="1.1" action="send" is_success="true" result_code="SEND_OK"><parameters>[{"name":"duplicate","value":"1"},{"name":"duplicate","value":"2"}]</parameters></XXLResponse>~'
         ),
      p_context         => 'duplicate JSON parameter name',
      p_expected_action => 'send'
   );

   assert_Parse_Error(
      p_xml =>
         TO_CLOB(
            q'~<XXLResponse version="1.1" action="send" is_success="true" result_code="SEND_OK"><parameters>{"legacy":"object"}</parameters></XXLResponse>~'
         ),
      p_context         => 'legacy JSON object parameters',
      p_expected_action => 'send'
   );

   assert_Parse_Error(
      p_xml =>
         TO_CLOB(
            q'~<XXLResponse version="1.1" action="send" is_success="true" result_code="SEND_OK"><parameters>[{"name":"missing"}]</parameters></XXLResponse>~'
         ),
      p_context         => 'JSON parameter without value',
      p_expected_action => 'send'
   );

   l_parser_error := FALSE;

   BEGIN
      l_result := MI_ResultCtx.result_From_Xml(TO_CLOB('<not-a-response/>'));
   EXCEPTION
      WHEN OTHERS THEN
         IF SQLCODE = -20011 THEN
            l_parser_error := TRUE;
         ELSE
            RAISE;
         END IF;
   END;

   assert_True(l_parser_error, 'invalid XXLResponse was not rejected');

   DBMS_OUTPUT.put_line('   OK');

   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('1. Required test information type exists');

   SELECT COUNT(*)
     INTO l_count
     FROM MI_INF
    WHERE INF_ID = 601;

   assert_True(l_count = 1, 'MI_INF does not contain required INF_ID=601');

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('2. Request not found is a structured failure');

   SELECT NVL(MAX(REQ_ID), 0) + 1000000
     INTO l_missing_req_id
     FROM MI_REQ;

   MI_mbus.send_Request(
      p_req_id => l_missing_req_id,
      p_result => l_result
   );

   assert_Code(
      l_result,
      'MI_MBUS.SEND_REQUEST#REQUEST_NOT_FOUND_IN_X',
      FALSE,
      'missing request'
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line(
      '3. NEW request fixture is created without invoking live Multi-Bus'
   );

   l_create_result :=
      MI_Request_Api.create_Request(
         p_inf_id    => 601,
         p_status_cd => MI_Request_Api.STATUS_NEW
      );

   assert_True(
      MI_ResultCtx.is_Success(l_create_result),
      'create request failed: '
      || NVL(l_create_result.result_code, '<NULL>')
      || ' / '
      || NVL(l_create_result.result_info, '<NULL>')
   );

   l_req_id := result_Id(l_create_result, 'req_id');

   SELECT STATUS_CD
     INTO l_status_before
     FROM MI_REQ
    WHERE REQ_ID = l_req_id;

   SELECT STATUS_CD
     INTO l_status_after
     FROM MI_REQ
    WHERE REQ_ID = l_req_id;

   assert_True(
      l_status_before = MI_Request_Api.STATUS_NEW,
      'request was not created in NEW'
   );
   assert_True(
      l_status_after = l_status_before,
      'request fixture status changed unexpectedly'
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('4. BUSY request is an idempotent success');

   l_create_result := MI_Request_Api.take_For_Proc(l_req_id);
   assert_True(
      MI_ResultCtx.is_Success(l_create_result),
      'take_For_Proc failed: ' || NVL(l_create_result.result_info, '<NULL>')
   );

   MI_mbus.send_Request(
      p_req_id => l_req_id,
      p_result => l_result
   );

   assert_Code(
      l_result,
      MI_mbus.RESULT_ALREADY_IN_PROGRESS,
      TRUE,
      'BUSY request'
   );

   SELECT STATUS_CD
     INTO l_status_after
     FROM MI_REQ
    WHERE REQ_ID = l_req_id;

   assert_True(
      l_status_after = MI_Request_Api.STATUS_BUSY,
      'idempotent send_Request changed BUSY status'
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('5. Response not found is a structured failure');

   SELECT NVL(MAX(RSP_ID), 0) + 1000000
     INTO l_missing_rsp_id
     FROM MI_RSP;

   MI_mbus.send_Response(
      p_rsp_id => l_missing_rsp_id,
      p_result => l_result
   );

   assert_Code(
      l_result,
      'MI_MBUS.SEND_RESPONSE#RESPONSE_NOT_FOUND',
      FALSE,
      'missing response'
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('6. NEW response is rejected with BAD_STATUS');

   l_create_result :=
      MI_Request_Api.create_Request(
         p_inf_id            => 601,
         p_original_req_uuid => MI_Utils.uuid_V7,
         p_status_cd         => MI_Request_Api.STATUS_DONE
      );

   assert_True(
      MI_ResultCtx.is_Success(l_create_result),
      'create response request failed: '
      || NVL(l_create_result.result_info, '<NULL>')
   );

   l_rsp_req_id := result_Id(l_create_result, 'req_id');

   l_create_result :=
      MI_Response_Api.create_Response(
         p_req_id      => l_rsp_req_id,
         p_itm_id      => 1,
         p_category_cd => 'SMOKE',
         p_result_code => 'SMOKE_OK'
      );

   assert_True(
      MI_ResultCtx.is_Success(l_create_result),
      'create response failed: '
      || NVL(l_create_result.result_info, '<NULL>')
   );

   l_rsp_id := result_Id(l_create_result, 'rsp_id');

   MI_mbus.send_Response(
      p_rsp_id => l_rsp_id,
      p_result => l_result
   );

   assert_Code(
      l_result,
      'MI_MBUS.SEND_RESPONSE#BAD_STATUS',
      FALSE,
      'NEW response'
   );

   SELECT STATUS_CD
     INTO l_status_after
     FROM MI_RSP
    WHERE RSP_ID = l_rsp_id;

   assert_True(
      l_status_after = MI_Response_Api.STATUS_NEW,
      'bad-status send_Response changed response status'
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line(
      '7. READY response fixture is created without invoking live Multi-Bus'
   );

   l_create_result := MI_Response_Api.to_Ready(l_rsp_id);
   assert_True(
      MI_ResultCtx.is_Success(l_create_result),
      'to_Ready failed: ' || NVL(l_create_result.result_info, '<NULL>')
   );

   SELECT STATUS_CD
     INTO l_status_before
     FROM MI_RSP
    WHERE RSP_ID = l_rsp_id;

   SELECT STATUS_CD
     INTO l_status_after
     FROM MI_RSP
    WHERE RSP_ID = l_rsp_id;

   assert_True(
      l_status_before = MI_Response_Api.STATUS_READY,
      'response was not READY before send'
   );
   assert_True(
      l_status_after = l_status_before,
      'response fixture status changed unexpectedly'
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('8. SENT response is an idempotent success');

   l_create_result := MI_Response_Api.to_Sent(l_rsp_id);
   assert_True(
      MI_ResultCtx.is_Success(l_create_result),
      'to_Sent failed: ' || NVL(l_create_result.result_info, '<NULL>')
   );

   MI_mbus.send_Response(
      p_rsp_id => l_rsp_id,
      p_result => l_result
   );

   assert_Code(
      l_result,
      MI_mbus.RESULT_ALREADY_SENT,
      TRUE,
      'SENT response'
   );

   SELECT STATUS_CD
     INTO l_status_after
     FROM MI_RSP
    WHERE RSP_ID = l_rsp_id;

   assert_True(
      l_status_after = MI_Response_Api.STATUS_SENT,
      'idempotent send_Response changed SENT status'
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('9. Direct command rejects invalid inputs');

   MI_mbus.send_Command(
      p_result => l_result,
      p_action => '   '
   );
   assert_Code(
      l_result,
      'MI_MBUS.SEND_COMMAND#ACTION_REQUIRED',
      FALSE,
      'blank action'
   );

   MI_mbus.send_Command(
      p_result => l_result,
      p_action => 'bad action'
   );
   assert_Code(
      l_result,
      'MI_MBUS.SEND_COMMAND#INVALID_ACTION',
      FALSE,
      'action with whitespace'
   );

   MI_mbus.send_Command(
      p_result     => l_result,
      p_action     => 'refresh',
      p_parameters => '[1]'
   );
   assert_Code(
      l_result,
      'MI_MBUS.SEND_COMMAND#INVALID_PARAMETERS',
      FALSE,
      'JSON array parameters'
   );

   MI_mbus.send_Command(
      p_result => l_result,
      p_action => 'refresh',
      p_inf_id => -1
   );
   assert_Code(
      l_result,
      'MI_MBUS.SEND_COMMAND#INVALID_INF_ID',
      FALSE,
      'negative inf_id'
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('10. Direct command validates request context');

   MI_mbus.send_Command(
      p_result => l_result,
      p_action => 'refresh',
      p_req_id => l_missing_req_id
   );

   assert_Code(
      l_result,
      'MI_MBUS.SEND_COMMAND#REQUEST_NOT_FOUND',
      FALSE,
      'missing command request'
   );

   MI_mbus.send_Command(
      p_result => l_result,
      p_action => 'refresh',
      p_inf_id => 999999999,
      p_req_id => l_req_id
   );

   assert_Code(
      l_result,
      'MI_MBUS.SEND_COMMAND#INF_ID_MISMATCH',
      FALSE,
      'command request/inf mismatch'
   );
   assert_True(
      l_result.parameters.EXISTS('inf_id')
      AND TO_NUMBER(l_result.parameters('inf_id')) = 601,
      'resolved request information type is absent'
   );

   DBMS_OUTPUT.put_line('   OK');


   ROLLBACK TO before_mi_mbus_smoke;

   DBMS_OUTPUT.put_line('MI_mbus smoke test passed');

EXCEPTION
   WHEN OTHERS THEN
      ROLLBACK TO before_mi_mbus_smoke;
      RAISE;
END;
/
