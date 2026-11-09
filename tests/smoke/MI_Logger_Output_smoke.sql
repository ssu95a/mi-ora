SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK ON
SET VERIFY OFF

PROMPT ============================================================
PROMPT MI_Logger DBMS_OUTPUT smoke test
PROMPT ============================================================

DECLARE
   l_marker         VARCHAR2(100);
   l_details_marker VARCHAR2(100);

   l_lines          DBMS_OUTPUT.CHARARR;
   l_line_count     INTEGER;

   l_header_found   BOOLEAN := FALSE;
   l_details_found  BOOLEAN := FALSE;


   PROCEDURE assert_True (
      p_condition IN BOOLEAN,
      p_message   IN VARCHAR2
   )
   IS
   BEGIN
      IF p_condition IS NULL OR NOT p_condition THEN
         RAISE_APPLICATION_ERROR(
            -20990,
            'MI_Logger DBMS_OUTPUT smoke test failed: ' || p_message
         );
      END IF;
   END assert_True;

BEGIN
   l_marker :=
      'mi_logger_output_header_'
      || LOWER(RAWTOHEX(SYS_GUID()));

   l_details_marker :=
      'mi_logger_output_details_'
      || LOWER(RAWTOHEX(SYS_GUID()));


   /* Remove output left by an earlier script in the same SQL*Plus session. */
   DBMS_OUTPUT.enable(NULL);
   l_line_count := 1000000;
   DBMS_OUTPUT.get_lines(l_lines, l_line_count);


   MI_Logger.enable_Log;
   MI_Logger.set_Min_Level(MI_Logger.LEVEL_INFO);

   MI_Logger.info(
      p_logger_name  => 'mi.logger.output.smoke',
      p_message_text => l_marker,
      p_action_code  => 'dbms_output',
      p_details_text => TO_CLOB(l_details_marker)
   );


   l_line_count := 1000000;
   DBMS_OUTPUT.get_lines(l_lines, l_line_count);

   IF l_line_count > 0 THEN
      FOR i IN 1 .. l_line_count LOOP
         IF INSTR(l_lines(i), l_marker) > 0 THEN
            l_header_found := TRUE;
         END IF;

         IF INSTR(l_lines(i), l_details_marker) > 0 THEN
            l_details_found := TRUE;
         END IF;
      END LOOP;
   END IF;

   assert_True(l_header_found,  'header was not written');
   assert_True(l_details_found, 'CLOB details were not written');


   MI_Logger.set_Min_Level(MI_Logger.LEVEL_DEBUG);

   DBMS_OUTPUT.put_line('============================================================');
   DBMS_OUTPUT.put_line('MI_Logger DBMS_OUTPUT smoke test PASSED');
   DBMS_OUTPUT.put_line('============================================================');

EXCEPTION
   WHEN OTHERS THEN
      BEGIN
         MI_Logger.enable_Log;
         MI_Logger.set_Min_Level(MI_Logger.LEVEL_DEBUG);
      EXCEPTION
         WHEN OTHERS THEN
            NULL;
      END;

      RAISE;
END;
/
