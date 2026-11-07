SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK ON
SET VERIFY OFF

PROMPT ============================================================
PROMPT MI_Logger smoke test
PROMPT ============================================================

DECLARE
   c_logger CONSTANT VARCHAR2(64) := 'mi.logger.smoke';

   l_run_id          VARCHAR2(32) := LOWER(RAWTOHEX(SYS_GUID()));
   l_message         VARCHAR2(2000);

   l_req_id          MI_REQ.REQ_ID%TYPE;
   l_req_inf_id      MI_REQ.INF_ID%TYPE;
   l_req_wsp_id      MI_INF.WSP_ID%TYPE;
   l_req_corr_old    MI_REQ.CORRELATION_ID%TYPE;
   l_req_corr_tmp    MI_REQ.CORRELATION_ID%TYPE;

   l_count           PLS_INTEGER;
   l_level_code      MI_LOG.LEVEL_CODE%TYPE;
   l_action_code     MI_LOG.ACTION_CODE%TYPE;
   l_log_inf_id      MI_LOG.INF_ID%TYPE;
   l_log_wsp_id      MI_LOG.WSP_ID%TYPE;
   l_log_corr         MI_LOG.CORRELATION_ID%TYPE;
   l_after_corr       MI_REQ.CORRELATION_ID%TYPE;

   l_has_req         BOOLEAN := TRUE;


   PROCEDURE fail (
      p_message IN VARCHAR2
   )
   IS
   BEGIN
      RAISE_APPLICATION_ERROR(
         -20990,
         'MI_Logger smoke test failed: ' || p_message
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


   FUNCTION msg (
      p_suffix IN VARCHAR2
   )
      RETURN VARCHAR2
   IS
   BEGIN
      RETURN
         'MI_LOGGER_SMOKE/'
         || l_run_id
         || '/'
         || p_suffix;
   END msg;


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
       WHERE logger_name  = c_logger
         AND message_text = p_message;

      RETURN l_result;
   END log_Count;


BEGIN
   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('1. basic autonomous write');

   MI_Logger.enable_Log;
   MI_Logger.set_Min_Level(MI_Logger.LEVEL_TRACE);

   l_message := msg('basic');

   MI_Logger.info(
      p_logger_name    => c_logger,
      p_message_text   => l_message,
      p_correlation_id => MI_Utils.uuid_V7,
      p_action_code    => 'smoke'
   );

   assert_True(
      log_Count(l_message) = 1,
      'basic log row was not inserted'
   );

   SELECT level_code,
          action_code
     INTO l_level_code,
          l_action_code
     FROM MI_LOG
    WHERE logger_name  = c_logger
      AND message_text = l_message;

   assert_Equals(l_level_code, 'inf', 'basic LEVEL_CODE');
   assert_Equals(l_action_code, 'smoke', 'basic ACTION_CODE');

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('2. level filtering');

   assert_True(
      MI_Logger.is_Enabled(MI_Logger.LEVEL_ALL) = FALSE,
      'LEVEL_ALL is a threshold, not an event level'
   );

   assert_True(
      MI_Logger.is_Enabled(MI_Logger.LEVEL_OFF) = FALSE,
      'LEVEL_OFF is a threshold, not an event level'
   );

   MI_Logger.set_Min_Level(MI_Logger.LEVEL_WARN);

   l_message := msg('filtered-debug');

   MI_Logger.debug(
      p_logger_name  => c_logger,
      p_message_text => l_message
   );

   assert_True(
      log_Count(l_message) = 0,
      'debug row must be filtered when min level = wrn'
   );

   l_message := msg('allowed-warn');

   MI_Logger.warn(
      p_logger_name  => c_logger,
      p_message_text => l_message
   );

   assert_True(
      log_Count(l_message) = 1,
      'warn row must pass when min level = wrn'
   );


   /*
      FATAL является отдельным уровнем фильтрации.
      Пока MI_LOG v1 хранит его физически как LEVEL_CODE='err'.
   */
   MI_Logger.set_Min_Level(MI_Logger.LEVEL_FATAL);

   l_message := msg('filtered-error');

   MI_Logger.error(
      p_logger_name  => c_logger,
      p_message_text => l_message
   );

   assert_True(
      log_Count(l_message) = 0,
      'error row must be filtered when min level = fatal'
   );


   l_message := msg('allowed-fatal');

   MI_Logger.fatal(
      p_logger_name  => c_logger,
      p_message_text => l_message
   );

   assert_True(
      log_Count(l_message) = 1,
      'fatal row must pass when min level = fatal'
   );

   SELECT level_code
     INTO l_level_code
     FROM MI_LOG
    WHERE logger_name  = c_logger
      AND message_text = l_message;

   assert_Equals(
      l_level_code,
      'err',
      'fatal physical LEVEL_CODE'
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('3. disable / enable');

   MI_Logger.disable_Log;

   l_message := msg('disabled');

   MI_Logger.error(
      p_logger_name  => c_logger,
      p_message_text => l_message
   );

   assert_True(
      log_Count(l_message) = 0,
      'disabled logger inserted a row'
   );

   MI_Logger.enable_Log;
   MI_Logger.set_Min_Level(MI_Logger.LEVEL_TRACE);

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('4. diagnostic helpers');

   MI_Logger.enter_f(
      p_logger_name   => c_logger,
      p_function_name => 'smoke_proc',
      p_message_text  => msg('enter'),
      p_parameters    => TO_CLOB('p1=1')
   );

   MI_Logger.exit_f(
      p_logger_name   => c_logger,
      p_function_name => 'smoke_proc',
      p_message_text  => msg('exit')
   );

   MI_Logger.variable_Value(
      p_logger_name   => c_logger,
      p_variable_name => 'l_value',
      p_value_text    => '42',
      p_details_text  => TO_CLOB(msg('val'))
   );

   MI_Logger.label(
      p_logger_name  => c_logger,
      p_message_text => msg('label')
   );

   MI_Logger.call_Stack(
      p_logger_name  => c_logger,
      p_message_text => msg('stack')
   );

   MI_Logger.version(
      p_logger_name  => c_logger,
      p_object_name  => 'MI_LOGGER_SMOKE',
      p_version_text => msg('version')
   );

   SELECT COUNT(*)
     INTO l_count
     FROM MI_LOG
    WHERE logger_name = c_logger
      AND (
             (action_code = 'enter_f'    AND level_code = 'trc')
          OR (action_code = 'exit_f'     AND level_code = 'trc')
          OR (action_code = 'val'        AND level_code = 'trc')
          OR (action_code = 'label'      AND level_code = 'dbg')
          OR (action_code = 'call_stack' AND level_code = 'dbg')
          OR (action_code = 'version'    AND level_code = 'inf')
      )
      AND (
             message_text LIKE '%' || l_run_id || '%'
          OR DBMS_LOB.INSTR(details_text, l_run_id) > 0
      );

   assert_True(
      l_count = 6,
      'expected 6 diagnostic helper rows, got ' || l_count
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('5. autonomous row survives caller rollback');

   SAVEPOINT before_logger;

   l_message := msg('rollback');

   MI_Logger.info(
      p_logger_name  => c_logger,
      p_message_text => l_message
   );

   ROLLBACK TO before_logger;

   assert_True(
      log_Count(l_message) = 1,
      'autonomous log row disappeared after caller rollback'
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('6. REQ context is resolved before autonomous transaction');

   BEGIN
      SELECT req_id,
             inf_id,
             wsp_id,
             correlation_id
        INTO l_req_id,
             l_req_inf_id,
             l_req_wsp_id,
             l_req_corr_old
        FROM (
           SELECT r.req_id,
                  r.inf_id,
                  i.wsp_id,
                  r.correlation_id
             FROM MI_REQ r
             JOIN MI_INF i
               ON i.inf_id = r.inf_id
            ORDER BY r.req_id DESC
        )
       WHERE ROWNUM = 1;

   EXCEPTION
      WHEN NO_DATA_FOUND THEN
         l_has_req := FALSE;
   END;


   IF l_has_req THEN
      l_req_corr_tmp := MI_Utils.uuid_V7;

      SAVEPOINT before_req_change;

      UPDATE MI_REQ
         SET correlation_id = l_req_corr_tmp
       WHERE req_id = l_req_id;

      assert_True(
         SQL%ROWCOUNT = 1,
         'test MI_REQ row was not updated'
      );

      l_message := msg('resolve-uncommitted');

      /*
         Передаём только REQ_ID.
         MI_Logger должен прочитать незакоммиченный MI_REQ в основной
         транзакции и передать уже разрешённый context в autonomous insert.
      */
      MI_Logger.info(
         p_logger_name  => c_logger,
         p_message_text => l_message,
         p_req_id       => l_req_id
      );

      ROLLBACK TO before_req_change;

      SELECT inf_id,
             wsp_id,
             correlation_id
        INTO l_log_inf_id,
             l_log_wsp_id,
             l_log_corr
        FROM MI_LOG
       WHERE logger_name  = c_logger
         AND message_text = l_message;

      assert_True(
         l_log_inf_id = l_req_inf_id,
         'resolved INF_ID does not match MI_REQ'
      );

      assert_True(
         l_log_wsp_id = l_req_wsp_id,
         'resolved WSP_ID does not match MI_INF'
      );

      assert_Equals(
         l_log_corr,
         l_req_corr_tmp,
         'logger did not see uncommitted CORRELATION_ID'
      );

      SELECT correlation_id
        INTO l_after_corr
        FROM MI_REQ
       WHERE req_id = l_req_id;

      assert_Equals(
         l_after_corr,
         l_req_corr_old,
         'caller rollback did not restore MI_REQ.CORRELATION_ID'
      );

      DBMS_OUTPUT.put_line('   OK');
   ELSE
      DBMS_OUTPUT.put_line('   SKIP: no MI_REQ row with matching MI_INF');
   END IF;


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('7. logger failure does not break caller');

   l_message := msg('internal-failure');

   /*
      ICUSNUM is NUMBER(12). Значение ниже заведомо не помещается,
      поэтому autonomous INSERT должен упасть внутри logger.
      Ошибка обязана быть поглощена logger-ом.
   */
   MI_Logger.error(
      p_logger_name  => c_logger,
      p_message_text => l_message,
      p_icusnum      => 99999999999999999999
   );

   assert_True(
      log_Count(l_message) = 0,
      'row with invalid ICUSNUM unexpectedly inserted'
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   /*
      Не оставляем вызывающую session в trace/disabled режиме.
   */
   MI_Logger.enable_Log;
   MI_Logger.set_Min_Level(MI_Logger.LEVEL_DEBUG);

   DBMS_OUTPUT.put_line('');
   DBMS_OUTPUT.put_line('============================================================');
   DBMS_OUTPUT.put_line('MI_Logger smoke test PASSED');
   DBMS_OUTPUT.put_line('============================================================');

EXCEPTION
   WHEN OTHERS THEN
      /*
         Восстанавливаем рабочий режим logger даже при падении smoke-test.
      */
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
