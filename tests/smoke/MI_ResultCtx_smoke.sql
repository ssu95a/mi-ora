SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK ON
SET VERIFY OFF

PROMPT ============================================================
PROMPT MI_ResultCtx smoke test
PROMPT ============================================================

DECLARE
   l_result    MI_ResultCtx.exec_Result_t;
   l_sqlcode   PLS_INTEGER;
   l_sqlerrm   VARCHAR2(4000);

   l_zero      NUMBER := 0;
   l_value     NUMBER;


   PROCEDURE fail (
      p_message IN VARCHAR2
   )
   IS
   BEGIN
      RAISE_APPLICATION_ERROR(
         -20990,
         'MI_ResultCtx smoke test failed: ' || p_message
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


   PROCEDURE assert_False (
      p_condition IN BOOLEAN,
      p_message   IN VARCHAR2
   )
   IS
   BEGIN
      IF p_condition IS NULL OR p_condition THEN
         fail(p_message);
      END IF;
   END assert_False;


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


BEGIN
   DBMS_OUTPUT.put_line('1. success()');

   l_result := MI_ResultCtx.success;

   assert_True(
      l_result.is_success,
      'success().is_success'
   );

   assert_Equals(
      l_result.result_code,
      'SUCCESS',
      'success().result_code'
   );

   assert_True(
      MI_ResultCtx.is_Success(l_result),
      'is_Success(success)'
   );

   assert_False(
      MI_ResultCtx.is_Failed(l_result),
      'is_Failed(success)'
   );

   /*
      raise_Error(success) должен быть no-op.
   */
   MI_ResultCtx.raise_Error(l_result);

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('2. failure()');

   l_result :=
      MI_ResultCtx.failure(
         p_code          => 'TEST_FAILURE',
         p_info          => 'Test failure',
         p_details       => TO_CLOB('result details'),
         p_cause_code    => 'CAUSE_1',
         p_cause_info    => 'Cause information',
         p_cause_details => TO_CLOB('cause details')
      );

   l_result.parameters('req_id') := '12345';

   assert_False(
      l_result.is_success,
      'failure().is_success'
   );

   assert_True(
      MI_ResultCtx.is_Failed(l_result),
      'is_Failed(failure)'
   );

   assert_Equals(
      l_result.result_code,
      'TEST_FAILURE',
      'failure().result_code'
   );

   assert_Equals(
      l_result.cause_code,
      'CAUSE_1',
      'failure().cause_code'
   );

   assert_True(
      l_result.parameters.EXISTS('req_id'),
      'failure().parameters(req_id) exists'
   );

   assert_Equals(
      l_result.parameters('req_id'),
      '12345',
      'failure().parameters(req_id)'
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('3. structured raise_Error() / ORA-20002');

   MI_ResultCtx.clear_Current;

   BEGIN
      l_result :=
         MI_ResultCtx.failure(
            p_code          => 'STRUCTURED_FAILURE',
            p_info          => 'Structured failure',
            p_details       => TO_CLOB('structured details'),
            p_cause_code    => 'SOURCE_ERROR',
            p_cause_info    => 'Source error'
         );

      l_result.parameters('req_id') := '777';
      l_result.parameters('kind')   := 'smoke';

      MI_ResultCtx.raise_Error(l_result);

      fail('raise_Error() did not raise result_Failed_Exc');

   EXCEPTION
      WHEN MI_ResultCtx.result_Failed_Exc THEN
         /*
            SQLCODE / SQLERRM фиксируем сразу в exception handler.
         */
         l_sqlcode := SQLCODE;
         l_sqlerrm := SQLERRM;

         assert_True(
            l_sqlcode = MI_ResultCtx.cResult_Failed_Code,
            'structured exception SQLCODE'
         );

         assert_True(
            MI_ResultCtx.has_Current_Result,
            'has_Current_Result after structured exception'
         );

         l_result :=
            MI_ResultCtx.from_Exception(
               p_sqlcode => l_sqlcode,
               p_sqlerrm => l_sqlerrm
            );

         assert_False(
            l_result.is_success,
            'restored structured result.is_success'
         );

         assert_Equals(
            l_result.result_code,
            'STRUCTURED_FAILURE',
            'restored structured result_code'
         );

         assert_Equals(
            l_result.result_info,
            'Structured failure',
            'restored structured result_info'
         );

         assert_Equals(
            l_result.cause_code,
            'SOURCE_ERROR',
            'restored structured cause_code'
         );

         assert_True(
            l_result.parameters.EXISTS('req_id'),
            'restored parameters(req_id) exists'
         );

         assert_Equals(
            l_result.parameters('req_id'),
            '777',
            'restored parameters(req_id)'
         );

         assert_Equals(
            l_result.parameters('kind'),
            'smoke',
            'restored parameters(kind)'
         );
   END;

   MI_ResultCtx.clear_Current;

   assert_False(
      MI_ResultCtx.has_Current_Result,
      'clear_Current()'
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('4. Oracle ZERO_DIVIDE -> from_Exception()');

   BEGIN
      l_value := 1 / l_zero;

      fail('ZERO_DIVIDE was not raised');

   EXCEPTION
      WHEN ZERO_DIVIDE THEN
         l_sqlcode := SQLCODE;
         l_sqlerrm := SQLERRM;

         l_result :=
            MI_ResultCtx.from_Exception(
               p_sqlcode => l_sqlcode,
               p_sqlerrm => l_sqlerrm
            );

         assert_False(
            l_result.is_success,
            'ZERO_DIVIDE result.is_success'
         );

         assert_Equals(
            l_result.result_code,
            'UNEXPECTED_ERROR',
            'ZERO_DIVIDE result_code'
         );

         assert_Equals(
            l_result.cause_code,
            'ORA-01476',
            'ZERO_DIVIDE cause_code'
         );

         assert_True(
            l_result.cause_info IS NOT NULL,
            'ZERO_DIVIDE cause_info'
         );

         assert_True(
            l_result.parameters.EXISTS('sqlcode'),
            'ZERO_DIVIDE parameters(sqlcode) exists'
         );

         assert_Equals(
            l_result.parameters('sqlcode'),
            '-1476',
            'ZERO_DIVIDE parameters(sqlcode)'
         );

         assert_True(
            l_result.cause_details IS NOT NULL,
            'ZERO_DIVIDE cause_details'
         );

         assert_True(
            DBMS_LOB.INSTR(
               l_result.cause_details,
               'BACKTRACE:'
            ) > 0,
            'ZERO_DIVIDE cause_details contains BACKTRACE'
         );
   END;

   DBMS_OUTPUT.put_line('   OK');


   DBMS_OUTPUT.put_line('');
   DBMS_OUTPUT.put_line('============================================================');
   DBMS_OUTPUT.put_line('MI_ResultCtx smoke test PASSED');
   DBMS_OUTPUT.put_line('============================================================');
END;
/
