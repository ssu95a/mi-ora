SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK ON
SET VERIFY OFF
SET DEFINE OFF

PROMPT ============================================================
PROMPT MI_ResultCtx XXLResponse 1.1 smoke test
PROMPT ============================================================

DECLARE
   l_result  MI_ResultCtx.exec_Result_t;


   ---------------------------------------------------------------------------
   PROCEDURE fail (
      p_message IN VARCHAR2
   )
   IS
   BEGIN
      RAISE_APPLICATION_ERROR(
         -20990,
         'MI_ResultCtx XXLResponse smoke test failed: ' || p_message
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
   PROCEDURE assert_Parse_Error (
      p_parameters IN CLOB,
      p_context    IN VARCHAR2,
      p_version    IN VARCHAR2 DEFAULT '1.1'
   )
   IS
      l_xml         CLOB;
      l_bad_result  MI_ResultCtx.exec_Result_t;
      l_sqlcode     PLS_INTEGER;
   BEGIN
      l_xml :=
            '<XXLResponse version="'
         || p_version
         || '" action="send" is_success="true" result_code="OK">'
         || '<parameters>'
         || p_parameters
         || '</parameters></XXLResponse>';

      BEGIN
         l_bad_result :=
            MI_ResultCtx.result_From_Xml(
               p_xml             => l_xml,
               p_expected_action => 'send'
            );
      EXCEPTION
         WHEN OTHERS THEN
            l_sqlcode := SQLCODE;
      END;

      assert_True(
         l_sqlcode = -20011,
            p_context
         || ': expected parser error -20011, actual='
         || NVL(TO_CHAR(l_sqlcode), '<NONE>')
      );
   END assert_Parse_Error;


BEGIN
   DBMS_OUTPUT.put_line('1. String/null parameters are decoded');

   l_result :=
      MI_ResultCtx.result_From_Xml(
         p_xml =>
            TO_CLOB(
               q'~<XXLResponse version="1.1" action="send" is_success="true" result_code="OK"><parameters>[{"name":"string","value":"A\u0026B"},{"name":"number","value":"2"},{"name":"boolean","value":"true"},{"name":"nested","value":"{\"x\":1}"},{"name":"none","value":null}]</parameters></XXLResponse>~'
            ),
         p_expected_action => 'send'
      );

   assert_True(l_result.parameters('string') = 'A&B', 'escaped string');
   assert_True(l_result.parameters('number') = '2', 'number lexical text');
   assert_True(l_result.parameters('boolean') = 'true', 'boolean lexical text');
   assert_True(l_result.parameters('nested') = '{"x":1}', 'nested JSON text');
   assert_True(
      l_result.parameters.EXISTS('none')
      AND l_result.parameters('none') IS NULL,
      'JSON null'
   );
   assert_True(l_result.parameters('xml_version') = '1.1', 'wire version');
   assert_True(l_result.parameters('xml_action') = 'send', 'wire action');

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('2. Empty array is accepted');

   l_result :=
      MI_ResultCtx.result_From_Xml(
         p_xml =>
            TO_CLOB(
               q'~<XXLResponse version="1.1" action="send" is_success="true" result_code="OK"><parameters>[]</parameters></XXLResponse>~'
            ),
         p_expected_action => 'send'
      );

   assert_True(l_result.parameters.COUNT = 2, 'empty parameter array');

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('3. Invalid array contracts are rejected');

   assert_Parse_Error(
      p_parameters => TO_CLOB('{"legacy":"object"}'),
      p_context    => 'legacy object'
   );

   assert_Parse_Error(
      p_parameters =>
         TO_CLOB(
            '[{"name":"duplicate","value":"1"},'
            || '{"name":"duplicate","value":"2"}]'
         ),
      p_context => 'duplicate name'
   );

   assert_Parse_Error(
      p_parameters => TO_CLOB('[{"name":"missing"}]'),
      p_context    => 'missing value'
   );

   assert_Parse_Error(
      p_parameters => TO_CLOB('[{"name":"object","value":{"x":1}}]'),
      p_context    => 'non-string value'
   );

   assert_Parse_Error(
      p_parameters => TO_CLOB('[]'),
      p_context    => 'legacy version',
      p_version    => '1.0'
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('4. Contract limits are enforced');

   assert_Parse_Error(
      p_parameters =>
         TO_CLOB(
               '[{"name":"'
            || RPAD('n', 101, 'n')
            || '","value":"1"}]'
         ),
      p_context => '101-character name'
   );

   assert_Parse_Error(
      p_parameters =>
         TO_CLOB(
               '[{"name":"value","value":"'
            || RPAD('x', 2001, 'x')
            || '"}]'
         ),
      p_context => '2001-character value'
   );

   DBMS_OUTPUT.put_line('   OK');


   DBMS_OUTPUT.put_line('');
   DBMS_OUTPUT.put_line('============================================================');
   DBMS_OUTPUT.put_line('MI_ResultCtx XXLResponse 1.1 smoke test PASSED');
   DBMS_OUTPUT.put_line('============================================================');
END;
/
