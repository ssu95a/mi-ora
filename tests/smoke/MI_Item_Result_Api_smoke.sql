SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK ON
SET VERIFY OFF

PROMPT ============================================================
PROMPT MI_Item_Result_Api smoke test
PROMPT ============================================================

DECLARE
   l_result        MI_ResultCtx.exec_Result_t;
   l_request_uuid  MI_Utils.Uuid_t;
   l_message_uuid  MI_Utils.Uuid_t;
   l_item_uuid     MI_Utils.Uuid_t;


   ---------------------------------------------------------------------------
   PROCEDURE fail (
      p_message IN VARCHAR2
   )
   IS
   BEGIN
      RAISE_APPLICATION_ERROR(
         -20990,
         'MI_Item_Result_Api smoke test failed: ' || p_message
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
   PROCEDURE assert_Failure_Code (
      p_result    IN MI_ResultCtx.exec_Result_t,
      p_code      IN VARCHAR2,
      p_message   IN VARCHAR2
   )
   IS
   BEGIN
      IF MI_ResultCtx.is_Success(p_result)
         OR p_result.result_code <> p_code
      THEN
         fail(
            p_message
            || ' [expected_code='
            || p_code
            || ', actual_code='
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
   END assert_Failure_Code;


BEGIN
   l_request_uuid := MI_Utils.uuid_V7;
   l_message_uuid := MI_Utils.uuid_V7;
   l_item_uuid    := MI_Utils.uuid_V7;


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('1. package version');

   assert_True(
      MI_Item_Result_Api.get_Version IS NOT NULL,
      'get_Version returned NULL'
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('2. reject invalid request UUID');

   l_result :=
      MI_Item_Result_Api.apply_Item_Result(
         p_item_table        => 'MI_0007',
         p_payload_mapper    => 'MI_0007_API.MAP_ITEM_RESULT',
         p_request_uuid      => 'not-a-uuid',
         p_message_uuid      => l_message_uuid,
         p_item_uuid         => l_item_uuid,
         p_response_kind     => MI_Item_Result_Api.RESPONSE_OK,
         p_response_code     => NULL,
         p_response_info     => NULL,
         p_response_details  => NULL,
         p_response_time     => SYSTIMESTAMP,
         p_payload_text      => TO_CLOB('{"docStatus":1}')
      );

   assert_Failure_Code(
      l_result,
      'ITEM_RESULT_INVALID_REQUEST_UUID',
      'invalid request UUID was accepted'
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('3. reject unsupported response kind');

   l_result :=
      MI_Item_Result_Api.apply_Item_Result(
         p_item_table        => 'MI_0007',
         p_payload_mapper    => 'MI_0007_API.MAP_ITEM_RESULT',
         p_request_uuid      => l_request_uuid,
         p_message_uuid      => l_message_uuid,
         p_item_uuid         => l_item_uuid,
         p_response_kind     => 1,
         p_response_code     => NULL,
         p_response_info     => NULL,
         p_response_details  => NULL,
         p_response_time     => SYSTIMESTAMP,
         p_payload_text      => TO_CLOB('{"docStatus":1}')
      );

   assert_Failure_Code(
      l_result,
      'ITEM_RESULT_INVALID_RESPONSE_KIND',
      'unsupported response kind was accepted'
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('4. reject unsafe dynamic SQL identifiers');

   l_result :=
      MI_Item_Result_Api.apply_Item_Result(
         p_item_table        => 'MI_0007;DELETE',
         p_payload_mapper    => 'MI_0007_API.MAP_ITEM_RESULT',
         p_request_uuid      => l_request_uuid,
         p_message_uuid      => l_message_uuid,
         p_item_uuid         => l_item_uuid,
         p_response_kind     => MI_Item_Result_Api.RESPONSE_OK,
         p_response_code     => NULL,
         p_response_info     => NULL,
         p_response_details  => NULL,
         p_response_time     => SYSTIMESTAMP,
         p_payload_text      => TO_CLOB('{"docStatus":1}')
      );

   assert_Failure_Code(
      l_result,
      'ITEM_RESULT_INVALID_CONFIGURATION',
      'unsafe item table identifier was accepted'
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('5. validate successful JSON payload before locking');

   l_result :=
      MI_Item_Result_Api.apply_Item_Result(
         p_item_table        => 'MI_0007',
         p_payload_mapper    => 'MI_0007_API.MAP_ITEM_RESULT',
         p_request_uuid      => l_request_uuid,
         p_message_uuid      => l_message_uuid,
         p_item_uuid         => l_item_uuid,
         p_response_kind     => MI_Item_Result_Api.RESPONSE_OK,
         p_response_code     => NULL,
         p_response_info     => NULL,
         p_response_details  => NULL,
         p_response_time     => SYSTIMESTAMP,
         p_payload_text      => TO_CLOB('{broken-json')
      );

   assert_Failure_Code(
      l_result,
      'ITEM_RESULT_INVALID_JSON',
      'invalid JSON payload was accepted'
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('6. reject payload for failed response');

   l_result :=
      MI_Item_Result_Api.apply_Item_Result(
         p_item_table        => 'MI_0007',
         p_payload_mapper    => NULL,
         p_request_uuid      => l_request_uuid,
         p_message_uuid      => l_message_uuid,
         p_item_uuid         => l_item_uuid,
         p_response_kind     => MI_Item_Result_Api.RESPONSE_FAIL,
         p_response_code     => 'REMOTE_ERROR',
         p_response_info     => 'Remote error',
         p_response_details  => NULL,
         p_response_time     => SYSTIMESTAMP,
         p_payload_text      => TO_CLOB('{}')
      );

   assert_Failure_Code(
      l_result,
      'ITEM_RESULT_UNEXPECTED_PAYLOAD',
      'payload for failed response was accepted'
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('7. report unknown request without touching item table');

   l_result :=
      MI_Item_Result_Api.apply_Item_Result(
         p_item_table        => 'MI_0007',
         p_payload_mapper    => NULL,
         p_request_uuid      => l_request_uuid,
         p_message_uuid      => l_message_uuid,
         p_item_uuid         => l_item_uuid,
         p_response_kind     => MI_Item_Result_Api.RESPONSE_FAIL,
         p_response_code     => 'REMOTE_ERROR',
         p_response_info     => 'Remote error',
         p_response_details  => NULL,
         p_response_time     => SYSTIMESTAMP,
         p_payload_text      => NULL
      );

   assert_Failure_Code(
      l_result,
      'ITEM_RESULT_REQUEST_NOT_FOUND',
      'unknown request was not reported correctly'
   );

   DBMS_OUTPUT.put_line('   OK');


   DBMS_OUTPUT.put_line('MI_Item_Result_Api smoke test passed');
END;
/
