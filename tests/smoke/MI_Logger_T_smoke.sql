SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK ON
SET VERIFY OFF

PROMPT ============================================================
PROMPT MI_Logger_T object wrapper smoke test
PROMPT ============================================================

DECLARE
   c_logger CONSTANT VARCHAR2(64) := 'mi.log.object.smoke';

   l_run_id          VARCHAR2(32) := LOWER(RAWTOHEX(SYS_GUID()));
   l_message         VARCHAR2(2000);

   l_log             MI_Logger_T;
   l_context_log     MI_Logger_T;

   l_req_id          MI_REQ.REQ_ID%TYPE;
   l_req_inf_id      MI_REQ.INF_ID%TYPE;
   l_req_wsp_id      MI_INF.WSP_ID%TYPE;
   l_req_corr_old    MI_REQ.CORRELATION_ID%TYPE;
   l_req_corr_tmp    MI_REQ.CORRELATION_ID%TYPE;

   l_level_code      MI_LOG.LEVEL_CODE%TYPE;
   l_action_code     MI_LOG.ACTION_CODE%TYPE;
   l_details_text    MI_LOG.DETAILS_TEXT%TYPE;

   l_log_wsp_id      MI_LOG.WSP_ID%TYPE;
   l_log_inf_id      MI_LOG.INF_ID%TYPE;
   l_log_req_id      MI_LOG.REQ_ID%TYPE;
   l_log_itm_id      MI_LOG.ITM_ID%TYPE;
   l_log_rsp_id      MI_LOG.RSP_ID%TYPE;
   l_log_corr        MI_LOG.CORRELATION_ID%TYPE;
   l_log_person_id   MI_LOG.PERSON_ID%TYPE;
   l_log_icusnum     MI_LOG.ICUSNUM%TYPE;

   l_after_corr      MI_REQ.CORRELATION_ID%TYPE;

   l_count           PLS_INTEGER;
   l_has_req         BOOLEAN := TRUE;


   ---------------------------------------------------------------------------
   PROCEDURE fail (
      p_message IN VARCHAR2
   )
   IS
   BEGIN
      RAISE_APPLICATION_ERROR(
         -20990,
         'MI_Logger_T smoke test failed: ' || p_message
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


   ---------------------------------------------------------------------------
   FUNCTION msg (
      p_suffix IN VARCHAR2
   )
      RETURN VARCHAR2
   IS
   BEGIN
      RETURN
         'MI_LOGGER_T_SMOKE/'
         || l_run_id
         || '/'
         || p_suffix;
   END msg;


   ---------------------------------------------------------------------------
   FUNCTION log_Count (
      p_message IN VARCHAR2
   )
      RETURN PLS_INTEGER
   IS
      l_result PLS_INTEGER;
   BEGIN
      SELECT COUNT(*)
        INTO l_result
        FROM MI_LOG
       WHERE LOGGER_NAME  = c_logger
         AND MESSAGE_TEXT = p_message;

      RETURN l_result;
   END log_Count;


BEGIN
   MI_Logger.enable_Log;
   MI_Logger.set_Min_Level(MI_Logger.LEVEL_TRACE);


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('1. construct wrapper and write through info()');

   l_log := MI_Logger_T(c_logger);

   assert_Equals(l_log.logger_name, c_logger, 'LOGGER_NAME attribute');
   assert_True(l_log.req_id IS NULL, 'REQ_ID must be NULL');

   l_message := msg('basic-info');

   l_log.info(
      p_message_text => l_message,
      p_action_code  => 'object_smoke',
      p_details_text => TO_CLOB('basic details')
   );

   assert_True(log_Count(l_message) = 1, 'info row was not inserted');

   SELECT LEVEL_CODE,
          ACTION_CODE,
          DETAILS_TEXT
     INTO l_level_code,
          l_action_code,
          l_details_text
     FROM MI_LOG
    WHERE LOGGER_NAME  = c_logger
      AND MESSAGE_TEXT = l_message;

   assert_Equals(l_level_code, 'inf', 'info LEVEL_CODE');
   assert_Equals(l_action_code, 'object_smoke', 'info ACTION_CODE');

   assert_True(
      DBMS_LOB.compare(l_details_text, TO_CLOB('basic details')) = 0,
      'info DETAILS_TEXT'
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('2. log primitive and all level wrappers');

   l_log.log(MI_Logger.LEVEL_TRACE, msg('direct'), 'direct');
   l_log.trace(msg('trace'));
   l_log.debug(msg('debug'));
   l_log.info(msg('info'));
   l_log.warn(msg('warn'));
   l_log.error(msg('error'));
   l_log.fatal(msg('fatal'));

   SELECT COUNT(*)
     INTO l_count
     FROM MI_LOG
    WHERE LOGGER_NAME = c_logger
      AND MESSAGE_TEXT IN (
             'MI_LOGGER_T_SMOKE/' || l_run_id || '/direct',
             'MI_LOGGER_T_SMOKE/' || l_run_id || '/trace',
             'MI_LOGGER_T_SMOKE/' || l_run_id || '/debug',
             'MI_LOGGER_T_SMOKE/' || l_run_id || '/info',
             'MI_LOGGER_T_SMOKE/' || l_run_id || '/warn',
             'MI_LOGGER_T_SMOKE/' || l_run_id || '/error',
             'MI_LOGGER_T_SMOKE/' || l_run_id || '/fatal'
          );

   assert_True(l_count = 7, 'expected 7 level rows, got ' || l_count);

   SELECT LEVEL_CODE
     INTO l_level_code
     FROM MI_LOG
    WHERE LOGGER_NAME  = c_logger
      AND MESSAGE_TEXT =
             'MI_LOGGER_T_SMOKE/' || l_run_id || '/fatal';

   assert_Equals(l_level_code, 'err', 'fatal physical LEVEL_CODE');

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('3. diagnostic sugar delegates through object.log()');

   l_log.enter_f(
      p_function_name => 'smoke_proc',
      p_message_text  => msg('enter'),
      p_parameters    => TO_CLOB('p1=1')
   );

   l_log.exit_f(
      p_function_name => 'smoke_proc',
      p_message_text  => msg('exit'),
      p_details_text  => TO_CLOB('result=OK')
   );

   l_log.variable_Value(
      p_variable_name => 'l_value',
      p_value_text    => msg('value'),
      p_details_text  => TO_CLOB('value details')
   );

   l_log.label(msg('label'));
   l_log.call_Stack(msg('stack'));

   l_log.version(
      p_object_name  => 'MI_LOG',
      p_version_text => msg('version')
   );

   SELECT COUNT(*)
     INTO l_count
     FROM MI_LOG
    WHERE LOGGER_NAME = c_logger
      AND (
             (ACTION_CODE = 'enter_f'    AND LEVEL_CODE = 'trc')
          OR (ACTION_CODE = 'exit_f'     AND LEVEL_CODE = 'trc')
          OR (ACTION_CODE = 'val'        AND LEVEL_CODE = 'trc')
          OR (ACTION_CODE = 'label'      AND LEVEL_CODE = 'dbg')
          OR (ACTION_CODE = 'call_stack' AND LEVEL_CODE = 'dbg')
          OR (ACTION_CODE = 'version'    AND LEVEL_CODE = 'inf')
      )
      AND (
             MESSAGE_TEXT LIKE '%' || l_run_id || '%'
          OR DBMS_LOB.INSTR(DETAILS_TEXT, l_run_id) > 0
      );

   assert_True(
      l_count = 6,
      'expected 6 diagnostic helper rows, got ' || l_count
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('4. explicit context propagation');

   l_log :=
      MI_Logger_T(
         p_logger_name    => c_logger,
         p_wsp_id         => 101,
         p_inf_id         => 102,
         p_req_id         => 103,
         p_itm_id         => 104,
         p_rsp_id         => 105,
         p_correlation_id => '019a6325-4000-7000-8000-000000000001',
         p_person_id      => 106,
         p_icusnum        => 107
      );

   l_message := msg('explicit-context');
   l_log.info(l_message);

   SELECT WSP_ID,
          INF_ID,
          REQ_ID,
          ITM_ID,
          RSP_ID,
          CORRELATION_ID,
          PERSON_ID,
          ICUSNUM
     INTO l_log_wsp_id,
          l_log_inf_id,
          l_log_req_id,
          l_log_itm_id,
          l_log_rsp_id,
          l_log_corr,
          l_log_person_id,
          l_log_icusnum
     FROM MI_LOG
    WHERE LOGGER_NAME  = c_logger
      AND MESSAGE_TEXT = l_message;

   assert_True(l_log_wsp_id = 101, 'explicit WSP_ID');
   assert_True(l_log_inf_id = 102, 'explicit INF_ID');
   assert_True(l_log_req_id = 103, 'explicit REQ_ID');
   assert_True(l_log_itm_id = 104, 'explicit ITM_ID');
   assert_True(l_log_rsp_id = 105, 'explicit RSP_ID');

   assert_Equals(
      l_log_corr,
      '019a6325-4000-7000-8000-000000000001',
      'explicit CORRELATION_ID'
   );

   assert_True(l_log_person_id = 106, 'explicit PERSON_ID');
   assert_True(l_log_icusnum = 107, 'explicit ICUSNUM');

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('5. core filtering still controls object methods');

   MI_Logger.set_Min_Level(MI_Logger.LEVEL_WARN);

   l_log := MI_Logger_T(c_logger);

   l_log.debug(msg('filtered-debug'));
   l_log.warn(msg('allowed-warn'));

   assert_True(
      log_Count(msg('filtered-debug')) = 0,
      'debug row must be filtered'
   );

   assert_True(
      log_Count(msg('allowed-warn')) = 1,
      'warn row must pass core filter'
   );

   MI_Logger.set_Min_Level(MI_Logger.LEVEL_TRACE);

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('6. REQ context resolution and caller rollback');

   BEGIN
      SELECT REQ_ID,
             INF_ID,
             WSP_ID,
             CORRELATION_ID
        INTO l_req_id,
             l_req_inf_id,
             l_req_wsp_id,
             l_req_corr_old
        FROM (
           SELECT r.REQ_ID,
                  r.INF_ID,
                  i.WSP_ID,
                  r.CORRELATION_ID
             FROM MI_REQ r
             JOIN MI_INF i
               ON i.INF_ID = r.INF_ID
            ORDER BY r.REQ_ID DESC
        )
       WHERE ROWNUM = 1;

   EXCEPTION
      WHEN NO_DATA_FOUND THEN
         l_has_req := FALSE;
   END;


   IF l_has_req THEN
      l_req_corr_tmp := MI_Utils.uuid_V7;

      SAVEPOINT before_object_log;

      UPDATE MI_REQ
         SET CORRELATION_ID = l_req_corr_tmp
       WHERE REQ_ID = l_req_id;

      assert_True(SQL%ROWCOUNT = 1, 'test MI_REQ row was not updated');

      l_context_log :=
         MI_Logger_T(
            p_logger_name => c_logger,
            p_req_id      => l_req_id
         );

      l_message := msg('resolve-uncommitted');
      l_context_log.info(l_message);

      ROLLBACK TO before_object_log;

      SELECT INF_ID,
             WSP_ID,
             REQ_ID,
             CORRELATION_ID
        INTO l_log_inf_id,
             l_log_wsp_id,
             l_log_req_id,
             l_log_corr
        FROM MI_LOG
       WHERE LOGGER_NAME  = c_logger
         AND MESSAGE_TEXT = l_message;

      assert_True(l_log_req_id = l_req_id, 'resolved REQ_ID');
      assert_True(l_log_inf_id = l_req_inf_id, 'resolved INF_ID');
      assert_True(l_log_wsp_id = l_req_wsp_id, 'resolved WSP_ID');

      assert_Equals(
         l_log_corr,
         l_req_corr_tmp,
         'wrapper bypassed core pre-AT context resolution'
      );

      SELECT CORRELATION_ID
        INTO l_after_corr
        FROM MI_REQ
       WHERE REQ_ID = l_req_id;

      assert_Equals(
         l_after_corr,
         l_req_corr_old,
         'object logging committed caller transaction'
      );

      DBMS_OUTPUT.put_line('   OK');
   ELSE
      DBMS_OUTPUT.put_line('   SKIP: no MI_REQ row with matching MI_INF');
   END IF;


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('7. wrapper preserves logger failure isolation');

   l_log :=
      MI_Logger_T(
         p_logger_name => c_logger,
         p_icusnum     => 99999999999999999999
      );

   l_message := msg('internal-failure');
   l_log.error(l_message);

   assert_True(
      log_Count(l_message) = 0,
      'row with invalid ICUSNUM unexpectedly inserted'
   );


   /*
      Invalid event level must also remain harmless. The SQL object contract
      uses INTEGER, while MI_Logger validates its package subtype internally.
   */
   l_log := MI_Logger_T(c_logger);
   l_log.log(999, msg('invalid-level'));

   assert_True(
      log_Count(msg('invalid-level')) = 0,
      'invalid level unexpectedly inserted a row'
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   MI_Logger.enable_Log;
   MI_Logger.set_Min_Level(MI_Logger.LEVEL_DEBUG);

   DBMS_OUTPUT.put_line('');
   DBMS_OUTPUT.put_line('============================================================');
   DBMS_OUTPUT.put_line('MI_Logger_T object wrapper smoke test PASSED');
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
