SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK ON
SET VERIFY OFF

PROMPT ============================================================
PROMPT MI_Prp smoke test
PROMPT ============================================================

DECLARE
   l_property_id  VARCHAR2(100);
   l_default      VARCHAR2(100) := 'MI_PRP_DEFAULT';
   l_value        VARCHAR2(32767);
   l_count        PLS_INTEGER;


   PROCEDURE fail (
      p_message IN VARCHAR2
   )
   IS
   BEGIN
      RAISE_APPLICATION_ERROR(
         -20990,
         'MI_Prp smoke test failed: ' || p_message
      );
   END fail;


   PROCEDURE assert_Default (
      p_value    IN VARCHAR2,
      p_context  IN VARCHAR2
   )
   IS
   BEGIN
      IF p_value <> l_default OR p_value IS NULL THEN
         fail(
               p_context
            || ': expected='
            || l_default
            || ', actual='
            || NVL(p_value, '<NULL>')
         );
      END IF;
   END assert_Default;


BEGIN
   SELECT COUNT(*)
     INTO l_count
     FROM MI_INF
    WHERE INF_ID = 607;

   IF l_count <> 1 THEN
      fail('MI_INF does not contain required INF_ID=607');
   END IF;

   l_property_id :=
         'SMOKE_'
      || REPLACE(MI_Utils.uuid_V7, '-', '');

   DBMS_OUTPUT.put_line('1. system property default');

   l_value :=
      MI_Prp.get_Sys_Property(
         p_prp_id    => l_property_id,
         p_def_value => l_default
      );

   assert_Default(l_value, 'system property');

   DBMS_OUTPUT.put_line('   OK');


   DBMS_OUTPUT.put_line('2. workspace property default');

   l_value :=
      MI_Prp.get_Wsp_Property(
         p_wsp_id    => 1,
         p_prp_id    => l_property_id,
         p_def_value => l_default
      );

   assert_Default(l_value, 'workspace property');

   DBMS_OUTPUT.put_line('   OK');


   DBMS_OUTPUT.put_line('3. INF property default');

   l_value :=
      MI_Prp.get_Inf_Property(
         p_inf_id    => 607,
         p_prp_id    => l_property_id,
         p_def_value => l_default
      );

   assert_Default(l_value, 'INF property');

   DBMS_OUTPUT.put_line('   OK');
   DBMS_OUTPUT.put_line('MI_Prp smoke test passed');
END;
/
