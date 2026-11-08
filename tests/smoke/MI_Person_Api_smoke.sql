SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK ON
SET VERIFY OFF

PROMPT ============================================================
PROMPT MI_Person_Api smoke test
PROMPT ============================================================

DECLARE
   l_result       MI_ResultCtx.exec_Result_t;
   l_person       MI_PERSON%ROWTYPE;

   l_person_id    MI_PERSON.PERSON_ID%TYPE;
   l_person_id_2  MI_PERSON.PERSON_ID%TYPE;

   l_snils        MI_PERSON.SNILS%TYPE;
   l_doc_num      MI_PERSON.DOC_NUM%TYPE;

   l_icusnum      MI_PERSON.ICUSNUM%TYPE;
   l_link_count   PLS_INTEGER;
   l_count        PLS_INTEGER;


   ---------------------------------------------------------------------------
   PROCEDURE fail (
      p_message IN VARCHAR2
   )
   IS
   BEGIN
      RAISE_APPLICATION_ERROR(
         -20990,
         'MI_Person_Api smoke test failed: ' || p_message
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
   PROCEDURE assert_Equals (
      p_actual    IN VARCHAR2,
      p_expected  IN VARCHAR2,
      p_message   IN VARCHAR2
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
   PROCEDURE assert_Failed (
      p_result   IN MI_ResultCtx.exec_Result_t,
      p_message  IN VARCHAR2
   )
   IS
   BEGIN
      IF MI_ResultCtx.is_Success(p_result) THEN
         fail(
            p_message
            || ' [result_code='
            || NVL(p_result.result_code, '<NULL>')
            || ']'
         );
      END IF;
   END assert_Failed;


   ---------------------------------------------------------------------------
   FUNCTION result_Id (
      p_result IN MI_ResultCtx.exec_Result_t
   )
      RETURN MI_PERSON.PERSON_ID%TYPE
   IS
   BEGIN
      RETURN TO_NUMBER(p_result.parameters('person_id'));

   EXCEPTION
      WHEN NO_DATA_FOUND THEN
         fail('result does not contain parameter person_id');
         RETURN NULL;
   END result_Id;


BEGIN
   SAVEPOINT before_person_smoke;


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('1. validate prerequisites');

   SELECT COUNT(*)
     INTO l_count
     FROM MI_INF
    WHERE INF_ID = 1;

   assert_True(
      l_count = 1,
      'MI_INF does not contain required SNILS profile INF_ID=1'
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('2. create person by SNILS profile');

   l_snils :=
      'T'
      || TO_CHAR(
            SYSTIMESTAMP,
            'YYMMDDHH24MISSFF6'
         );

   l_result :=
      MI_Person_Api.get_Or_Create(
         p_inf_id      => 1,
         p_person_json => TO_CLOB(
            '{'
            || '"snils":"' || l_snils || '",'
            || '"first_name":"Smoke",'
            || '"birth_date":"2000-01-02"'
            || '}'
         )
      );

   assert_Success(l_result, 'first get_Or_Create failed');
   assert_Equals(l_result.result_code, 'PERSON_CREATED', 'first result code');
   assert_Equals(l_result.parameters('created'), 'true', 'created parameter');
   assert_Equals(l_result.parameters('linked'), 'true', 'linked parameter');

   l_person_id := result_Id(l_result);
   l_person    := MI_Person_Api.get_Person(l_person_id);

   assert_Equals(l_person.snils, l_snils, 'stored SNILS');
   assert_Equals(l_person.first_name, 'Smoke', 'stored FIRST_NAME');

   assert_True(
      l_person.birth_date = DATE '2000-01-02',
      'stored BIRTH_DATE mismatch'
   );

   SELECT COUNT(*)
     INTO l_link_count
     FROM MI_P2I
    WHERE PERSON_ID = l_person_id
      AND INF_ID = 1;

   assert_True(l_link_count = 1, 'MI_P2I link was not created');

   DBMS_OUTPUT.put_line('   person_id=' || l_person_id);
   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('3. repeat call finds person and ignores duplicate link');

   l_result :=
      MI_Person_Api.get_Or_Create(
         p_inf_id      => 1,
         p_person_json => TO_CLOB(
            '{"snils":"' || l_snils || '","first_name":"Other"}'
         )
      );

   assert_Success(l_result, 'second get_Or_Create failed');
   assert_Equals(l_result.result_code, 'PERSON_FOUND', 'second result code');
   assert_Equals(l_result.parameters('created'), 'false', 'created parameter');
   assert_Equals(l_result.parameters('linked'), 'false', 'linked parameter');

   l_person_id_2 := result_Id(l_result);

   assert_True(
      l_person_id_2 = l_person_id,
      'SNILS profile returned a different person'
   );

   SELECT COUNT(*)
     INTO l_link_count
     FROM MI_P2I
    WHERE PERSON_ID = l_person_id
      AND INF_ID = 1;

   assert_True(l_link_count = 1, 'duplicate MI_P2I link was created');

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('4. validate input failures');

   l_result :=
      MI_Person_Api.get_Or_Create(
         p_inf_id      => NULL,
         p_person_json => TO_CLOB('{}')
      );

   assert_Failed(l_result, 'NULL INF_ID was unexpectedly accepted');
   assert_Equals(
      l_result.result_code,
      'PERSON_INVALID_INF_ID',
      'NULL INF_ID result code'
   );


   l_result :=
      MI_Person_Api.get_Or_Create(
         p_inf_id      => 1,
         p_person_json => TO_CLOB('[1,2,3]')
      );

   assert_Failed(l_result, 'JSON array was unexpectedly accepted');
   assert_Equals(
      l_result.result_code,
      'PERSON_INVALID_JSON',
      'invalid JSON result code'
   );


   l_result :=
      MI_Person_Api.get_Or_Create(
         p_inf_id      => 1,
         p_person_json => TO_CLOB('{snils:"lax-json"}')
      );

   assert_Failed(l_result, 'lax JSON syntax was unexpectedly accepted');
   assert_Equals(
      l_result.result_code,
      'PERSON_INVALID_JSON',
      'lax JSON result code'
   );


   l_result :=
      MI_Person_Api.get_Or_Create(
         p_inf_id      => 1,
         p_person_json => TO_CLOB('{"birth_date":"02.01.2000"}')
      );

   assert_Failed(l_result, 'invalid date was unexpectedly accepted');
   assert_Equals(
      l_result.result_code,
      'PERSON_INVALID_DATA',
      'invalid date result code'
   );


   l_result :=
      MI_Person_Api.get_Or_Create(
         p_inf_id      => 1,
         p_person_json => TO_CLOB('{"gender_id":1.5}')
      );

   assert_Failed(l_result, 'fractional identifier was unexpectedly accepted');
   assert_Equals(
      l_result.result_code,
      'PERSON_INVALID_DATA',
      'fractional identifier result code'
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('5. document profile global fallback');

   SELECT COUNT(*)
     INTO l_count
     FROM MI_INF
    WHERE INF_ID IN (74, 75);

   IF l_count = 2 THEN
      l_doc_num :=
         'T'
         || TO_CHAR(
               SYSTIMESTAMP,
               'YYMMDDHH24MISSFF6'
            );

      l_result :=
         MI_Person_Api.get_Or_Create(
            p_inf_id      => 74,
            p_person_json => TO_CLOB(
               '{'
               || '"doc_type_id":999,'
               || '"doc_ser":"TST",'
               || '"doc_num":"' || l_doc_num || '",'
               || '"doc_issue_date":"2026-11-08"'
               || '}'
            )
         );

      assert_Success(l_result, 'INF_ID=74 creation failed');
      assert_Equals(l_result.result_code, 'PERSON_CREATED', 'INF_ID=74 result');

      l_person_id := result_Id(l_result);


      l_result :=
         MI_Person_Api.get_Or_Create(
            p_inf_id      => 75,
            p_person_json => TO_CLOB(
               '{'
               || '"doc_type_id":999,'
               || '"doc_ser":"TST",'
               || '"doc_num":"' || l_doc_num || '",'
               || '"doc_issue_date":"2026-11-08"'
               || '}'
            )
         );

      assert_Success(l_result, 'INF_ID=75 lookup failed');
      assert_Equals(l_result.result_code, 'PERSON_FOUND', 'INF_ID=75 result');

      l_person_id_2 := result_Id(l_result);

      assert_True(
         l_person_id_2 = l_person_id,
         'global document lookup returned a different person'
      );

      SELECT COUNT(*)
        INTO l_link_count
        FROM MI_P2I
       WHERE PERSON_ID = l_person_id
         AND INF_ID IN (74, 75);

      assert_True(
         l_link_count = 2,
         'document person is not linked to both INF_ID values'
      );

      DBMS_OUTPUT.put_line('   OK');
   ELSE
      DBMS_OUTPUT.put_line('   SKIPPED: MI_INF 74/75 are not both present');
   END IF;


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('6. ICUSNUM overload and get_Last_Person_Id');

   BEGIN
      SELECT ICUSNUM
        INTO l_icusnum
        FROM (
           SELECT ICUSNUM
             FROM CUS
            WHERE ICUSNUM IS NOT NULL
            ORDER BY ICUSNUM
        )
       WHERE ROWNUM = 1;

   EXCEPTION
      WHEN NO_DATA_FOUND THEN
         l_icusnum := NULL;
   END;


   IF l_icusnum IS NOT NULL THEN
      l_snils :=
         'I'
         || TO_CHAR(
               SYSTIMESTAMP,
               'YYMMDDHH24MISSFF6'
            );

      l_result :=
         MI_Person_Api.get_Or_Create(
            p_inf_id      => 1,
            p_icusnum     => l_icusnum,
            p_person_json => TO_CLOB('{"snils":"' || l_snils || '"}')
         );

      assert_Success(l_result, 'ICUSNUM overload failed');

      l_person_id := result_Id(l_result);
      l_person    := MI_Person_Api.get_Person(l_person_id);

      assert_True(l_person.icusnum = l_icusnum, 'ICUSNUM was not applied');

      assert_True(
         MI_Person_Api.get_Last_Person_Id(l_icusnum, 1) = l_person_id,
         'get_Last_Person_Id returned an unexpected person'
      );

      DBMS_OUTPUT.put_line('   OK');
   ELSE
      DBMS_OUTPUT.put_line('   SKIPPED: CUS is empty');
   END IF;


   ROLLBACK TO before_person_smoke;

   DBMS_OUTPUT.put_line('MI_Person_Api smoke test completed successfully');

EXCEPTION
   WHEN OTHERS THEN
      ROLLBACK TO before_person_smoke;
      RAISE;
END;
/
