CREATE OR REPLACE PACKAGE MI_Request_Api
IS

   VERSION CONSTANT VARCHAR2(100) :=  '$Id: {1.2.3} {26.11.2026} Sulimoff$';


   SUBTYPE Status_t IS PLS_INTEGER RANGE -1 .. 3;

   STATUS_ERROR CONSTANT Status_t := -1;
   STATUS_NEW   CONSTANT Status_t :=  0;
   STATUS_DONE  CONSTANT Status_t :=  1;
   STATUS_BUSY  CONSTANT Status_t :=  2;
   STATUS_SENT  CONSTANT Status_t :=  3;


   /* JDBC compatibility result for transport callbacks. */
   RET_FAIL CONSTANT PLS_INTEGER := -1;
   RET_OK   CONSTANT PLS_INTEGER :=  0;

   /* */
   FUNCTION get_Version
      RETURN VARCHAR2;


   /* */
   FUNCTION status_Name (
      p_status_cd IN Status_t
   )
      RETURN VARCHAR2;


   /* */
   FUNCTION exists_Inf (
      p_inf_id IN MI_INF.INF_ID%TYPE
   )
      RETURN BOOLEAN;


   FUNCTION exists_Request (
      p_req_id IN MI_REQ.REQ_ID%TYPE
   )
      RETURN BOOLEAN;


   /* */
   FUNCTION resolve_Wsp_Id (
      p_inf_id IN MI_INF.INF_ID%TYPE
   )
      RETURN MI_WSP.WSP_ID%TYPE;


   /* */
   FUNCTION resolve_Inf_Id (
      p_req_id IN MI_REQ.REQ_ID%TYPE
   )
      RETURN MI_REQ.INF_ID%TYPE;


   /* */
   FUNCTION get_Status (
      p_req_id IN MI_REQ.REQ_ID%TYPE
   )
      RETURN Status_t;

   /* */
   FUNCTION get_Correlation_Id (
      p_req_id IN MI_REQ.REQ_ID%TYPE
   )
      RETURN MI_REQ.CORRELATION_ID%TYPE;


   /*
      Создаёт request header.

      REQ_ID, CREATED_AT и IDSMR заполняются defaults таблицы MI_REQ.
      EXTERNAL_UUID генерируется всегда.
      CORRELATION_ID генерируется, если не передан.

      Подтверждённые initial states:
         NEW  (0) - исходящий / ещё не обработанный request;
         DONE (1) - уже принятый входящий business request.
   */
   FUNCTION create_Request (
      p_inf_id                IN MI_REQ.INF_ID%TYPE,

      p_correlation_id        IN MI_REQ.CORRELATION_ID%TYPE       DEFAULT NULL,
      p_original_req_uuid     IN MI_REQ.ORIGINAL_REQ_UUID%TYPE    DEFAULT NULL,
      p_ctaxreq_id            IN MI_REQ.CTAXREQ_ID%TYPE           DEFAULT NULL,
      p_message_uuid          IN MI_REQ.MESSAGE_UUID%TYPE         DEFAULT NULL,

      p_status_cd             IN Status_t                         DEFAULT STATUS_NEW,

      p_itype                 IN MI_REQ.ITYPE%TYPE                DEFAULT NULL,
      p_i1                    IN MI_REQ.I1%TYPE                   DEFAULT NULL,
      p_i2                    IN MI_REQ.I2%TYPE                   DEFAULT NULL,
      p_i3                    IN MI_REQ.I3%TYPE                   DEFAULT NULL,

      p_parent_req_id         IN MI_REQ.PARENT_REQ_ID%TYPE        DEFAULT NULL
   )
      RETURN MI_ResultCtx.exec_Result_t;


   /*
      NEW / ERROR -> BUSY
   */
   FUNCTION take_For_Proc (
      p_req_id IN MI_REQ.REQ_ID%TYPE,
      p_info   IN VARCHAR2 DEFAULT NULL
   )
      RETURN MI_ResultCtx.exec_Result_t;


   /* JDBC scalar wrapper. COMMIT/ROLLBACK не выполняет. */
   PROCEDURE take_For_Proc (
      p_req_id    IN  MI_REQ.REQ_ID%TYPE,
      p_info      IN  VARCHAR2,
      p_ret_code  OUT NUMBER,
      p_ret_info  OUT VARCHAR2
   );


   /*
      BUSY -> SENT
   */
   FUNCTION to_Sent (
      p_req_id IN MI_REQ.REQ_ID%TYPE
   )
      RETURN MI_ResultCtx.exec_Result_t;


   /* JDBC scalar wrapper. COMMIT/ROLLBACK не выполняет. */
   PROCEDURE to_Sent (
      p_req_id    IN  MI_REQ.REQ_ID%TYPE,
      p_ret_code  OUT NUMBER,
      p_ret_info  OUT VARCHAR2
   );


   /*
      SENT -> DONE
   */
   FUNCTION to_Success (
      p_req_id IN MI_REQ.REQ_ID%TYPE
   )
      RETURN MI_ResultCtx.exec_Result_t;


   /* JDBC scalar wrapper. COMMIT/ROLLBACK не выполняет. */
   PROCEDURE to_Success (
      p_req_id    IN  MI_REQ.REQ_ID%TYPE,
      p_ret_code  OUT NUMBER,
      p_ret_info  OUT VARCHAR2
   );


   /*
      BUSY / SENT -> ERROR
   */
   FUNCTION to_Error (
      p_req_id IN MI_REQ.REQ_ID%TYPE
   )
      RETURN MI_ResultCtx.exec_Result_t;


   /* JDBC scalar wrapper. COMMIT/ROLLBACK не выполняет. */
   PROCEDURE to_Error (
      p_req_id    IN  MI_REQ.REQ_ID%TYPE,
      p_ret_code  OUT NUMBER,
      p_ret_info  OUT VARCHAR2
   );


   /*
      Применяет отрицательный transport response к исходящему request.

      Поддерживаемые причины: REQUEST_REJECTED, REQUEST_FAILED.
      Результат применим только к request в статусе SENT.

      Повтор с тем же MESSAGE_UUID идемпотентен. Другой MESSAGE_UUID для уже
      завершённого ERROR request считается конфликтом и данные не изменяет.

      Процедура предназначена для вызова через JDBC. COMMIT не выполняется.
      Транзакцией управляет вызывающая сторона. Локальный rollback выполняется
      только через DCL.SavePoint/RollBack.
   */
   PROCEDURE apply_Request_Failure (
      p_external_uuid  IN MI_REQ.EXTERNAL_UUID%TYPE,
      p_message_uuid   IN MI_REQ.MESSAGE_UUID%TYPE,

      p_reason_code    IN VARCHAR2,

      p_error_code     IN MI_REQ.RESULT_CODE%TYPE,
      p_error_info     IN MI_REQ.RESULT_INFO%TYPE,
      p_error_details  IN MI_REQ.NOTE%TYPE,
      p_occurred_at    IN MI_REQ.RESULT_TIME%TYPE,

      p_ret_code       OUT NUMBER,
      p_ret_info       OUT VARCHAR2
   );


   /*
      Любое состояние -> NEW.
      Если request уже NEW, операция считается успешной и ничего не меняет.
   */
   FUNCTION reset (
      p_req_id IN MI_REQ.REQ_ID%TYPE,
      p_info   IN VARCHAR2 DEFAULT NULL
   )
      RETURN MI_ResultCtx.exec_Result_t;

END MI_Request_Api;
/
CREATE OR REPLACE PACKAGE BODY MI_Request_Api
IS

   cLogger CONSTANT VARCHAR2(64) := 'mi.request';

   /* Глобальный логгер  */
   g_log CONSTANT MI_Logger_T := MI_Logger_T( p_logger_name  => cLogger, p_package_name => $$PLSQL_UNIT );


   /* */
   FUNCTION get_Version
      RETURN VARCHAR2
   IS
   BEGIN
      RETURN VERSION;
   END get_Version;


   /* */
   FUNCTION status_Name (
      p_status_cd IN Status_t
   )
      RETURN VARCHAR2
   IS
   BEGIN
      RETURN
         CASE p_status_cd
            WHEN STATUS_ERROR THEN 'ERROR'
            WHEN STATUS_NEW   THEN 'NEW'
            WHEN STATUS_DONE  THEN 'DONE'
            WHEN STATUS_BUSY  THEN 'BUSY'
            WHEN STATUS_SENT  THEN 'SENT'
            ELSE 'UNKNOWN'
         END;
   END status_Name;


   /* */
   FUNCTION exists_Inf (
      p_inf_id IN MI_INF.INF_ID%TYPE
   )
      RETURN BOOLEAN
   IS
      l_dummy PLS_INTEGER;
   BEGIN
      SELECT 1
        INTO l_dummy
        FROM MI_INF
       WHERE INF_ID = p_inf_id;

      RETURN TRUE;

   EXCEPTION
      WHEN NO_DATA_FOUND THEN
         RETURN FALSE;
   END exists_Inf;


   /* */
   FUNCTION exists_Request (
      p_req_id IN MI_REQ.REQ_ID%TYPE
   )
      RETURN BOOLEAN
   IS
      l_dummy PLS_INTEGER;
   BEGIN
      SELECT 1
        INTO l_dummy
        FROM MI_REQ
       WHERE REQ_ID = p_req_id;

      RETURN TRUE;

   EXCEPTION
      WHEN NO_DATA_FOUND THEN
         RETURN FALSE;
   END exists_Request;


   /* */
   FUNCTION resolve_Wsp_Id (
      p_inf_id IN MI_INF.INF_ID%TYPE
   )
      RETURN MI_WSP.WSP_ID%TYPE
   IS
      l_wsp_id MI_WSP.WSP_ID%TYPE;
   BEGIN
      SELECT WSP_ID
        INTO l_wsp_id
        FROM MI_INF
       WHERE INF_ID = p_inf_id;

      RETURN l_wsp_id;
   END resolve_Wsp_Id;


   /* */
   FUNCTION resolve_Inf_Id (
      p_req_id IN MI_REQ.REQ_ID%TYPE
   )
      RETURN MI_REQ.INF_ID%TYPE
   IS
      l_inf_id MI_REQ.INF_ID%TYPE;
   BEGIN
      SELECT INF_ID
        INTO l_inf_id
        FROM MI_REQ
       WHERE REQ_ID = p_req_id;

      RETURN l_inf_id;
   END resolve_Inf_Id;


   /* */
   FUNCTION get_Status (
      p_req_id IN MI_REQ.REQ_ID%TYPE
   )
      RETURN Status_t
   IS
      l_status_cd MI_REQ.STATUS_CD%TYPE;
   BEGIN
      SELECT STATUS_CD
        INTO l_status_cd
        FROM MI_REQ
       WHERE REQ_ID = p_req_id;

      RETURN l_status_cd;
   END get_Status;


   /* */
   FUNCTION get_Correlation_Id (
      p_req_id IN MI_REQ.REQ_ID%TYPE
   )
      RETURN MI_REQ.CORRELATION_ID%TYPE
   IS
      l_correlation_id MI_REQ.CORRELATION_ID%TYPE;
   BEGIN
      SELECT CORRELATION_ID
        INTO l_correlation_id
        FROM MI_REQ
       WHERE REQ_ID = p_req_id;

      RETURN l_correlation_id;
   END get_Correlation_Id;


   /* */
   FUNCTION success_Result (
      p_code      IN VARCHAR2,
      p_info      IN VARCHAR2,
      p_req_id    IN MI_REQ.REQ_ID%TYPE DEFAULT NULL,
      p_inf_id    IN MI_REQ.INF_ID%TYPE DEFAULT NULL,
      p_status_cd IN Status_t            DEFAULT NULL,
      p_ret_code  IN PLS_INTEGER         DEFAULT NULL
   )
      RETURN MI_ResultCtx.exec_Result_t
   IS
      l_result MI_ResultCtx.exec_Result_t;
   BEGIN
      l_result :=
         MI_ResultCtx.success(
            p_code => p_code,
            p_info => p_info
         );

      IF p_req_id IS NOT NULL THEN
         l_result.parameters('req_id') := TO_CHAR(p_req_id);
      END IF;

      IF p_inf_id IS NOT NULL THEN
         l_result.parameters('inf_id') := TO_CHAR(p_inf_id);
      END IF;

      IF p_status_cd IS NOT NULL THEN
         l_result.parameters('status_cd') := TO_CHAR(p_status_cd);
      END IF;

      IF p_ret_code IS NOT NULL THEN
         l_result.parameters('ret_code') := TO_CHAR(p_ret_code);
      END IF;

      RETURN l_result;
   END success_Result;


   /* */
   FUNCTION failure_Result (
      p_code          IN VARCHAR2,
      p_info          IN VARCHAR2,
      p_req_id        IN MI_REQ.REQ_ID%TYPE DEFAULT NULL,
      p_inf_id        IN MI_REQ.INF_ID%TYPE DEFAULT NULL,
      p_status_cd     IN Status_t            DEFAULT NULL,
      p_details       IN CLOB                DEFAULT NULL,
      p_ret_code      IN PLS_INTEGER         DEFAULT NULL
   )
      RETURN MI_ResultCtx.exec_Result_t
   IS
      l_result MI_ResultCtx.exec_Result_t;
   BEGIN
      l_result :=
         MI_ResultCtx.failure(
            p_code    => p_code,
            p_info    => p_info,
            p_details => p_details
         );

      IF p_req_id IS NOT NULL THEN
         l_result.parameters('req_id') := TO_CHAR(p_req_id);
      END IF;

      IF p_inf_id IS NOT NULL THEN
         l_result.parameters('inf_id') := TO_CHAR(p_inf_id);
      END IF;

      IF p_status_cd IS NOT NULL THEN
         l_result.parameters('status_cd') := TO_CHAR(p_status_cd);
      END IF;

      IF p_ret_code IS NOT NULL THEN
         l_result.parameters('ret_code') := TO_CHAR(p_ret_code);
      END IF;

      RETURN l_result;
   END failure_Result;


   /* */
   FUNCTION current_State_Failure (
      p_req_id     IN MI_REQ.REQ_ID%TYPE,
      p_operation  IN VARCHAR2,
      p_expected   IN VARCHAR2
   )
      RETURN MI_ResultCtx.exec_Result_t
   IS
      l_inf_id     MI_REQ.INF_ID%TYPE;
      l_status_cd  MI_REQ.STATUS_CD%TYPE;
      l_note       MI_REQ.NOTE%TYPE;
      l_result     MI_ResultCtx.exec_Result_t;
   BEGIN
      SELECT INF_ID,
             STATUS_CD,
             NOTE
        INTO l_inf_id,
             l_status_cd,
             l_note
        FROM MI_REQ
       WHERE REQ_ID = p_req_id;

      l_result :=
         failure_Result(
            p_code      => 'REQUEST_BAD_STATUS',
            p_info      =>
               p_operation
               || ': недопустимый статус '
               || status_Name(l_status_cd)
               || ' ('
               || l_status_cd
               || '), ожидается '
               || p_expected,
            p_req_id    => p_req_id,
            p_inf_id    => l_inf_id,
            p_status_cd => l_status_cd,
            p_details   => l_note
         );

      RETURN l_result;

   EXCEPTION
      WHEN NO_DATA_FOUND THEN
         RETURN
            failure_Result(
               p_code   => 'REQUEST_NOT_FOUND',
               p_info   => 'Не найден request с req_id=' || p_req_id,
               p_req_id => p_req_id
            );
   END current_State_Failure;


   /* */
   FUNCTION create_Request (
      p_inf_id                IN MI_REQ.INF_ID%TYPE,

      p_correlation_id        IN MI_REQ.CORRELATION_ID%TYPE       DEFAULT NULL,
      p_original_req_uuid     IN MI_REQ.ORIGINAL_REQ_UUID%TYPE    DEFAULT NULL,
      p_ctaxreq_id            IN MI_REQ.CTAXREQ_ID%TYPE           DEFAULT NULL,
      p_message_uuid          IN MI_REQ.MESSAGE_UUID%TYPE         DEFAULT NULL,

      p_status_cd             IN Status_t                         DEFAULT STATUS_NEW,

      p_itype                 IN MI_REQ.ITYPE%TYPE                DEFAULT NULL,
      p_i1                    IN MI_REQ.I1%TYPE                   DEFAULT NULL,
      p_i2                    IN MI_REQ.I2%TYPE                   DEFAULT NULL,
      p_i3                    IN MI_REQ.I3%TYPE                   DEFAULT NULL,

      p_parent_req_id         IN MI_REQ.PARENT_REQ_ID%TYPE        DEFAULT NULL
   )
      RETURN MI_ResultCtx.exec_Result_t
   IS
      l_req_id          MI_REQ.REQ_ID%TYPE;
      l_external_uuid   MI_REQ.EXTERNAL_UUID%TYPE;
      l_correlation_id  MI_REQ.CORRELATION_ID%TYPE;

      l_result          MI_ResultCtx.exec_Result_t;
      l_sqlcode         PLS_INTEGER;
      l_sqlerrm         VARCHAR2(2000);

      l_log             MI_Logger_T := g_log;
   BEGIN
      l_log.context(
         p_inf_id         => p_inf_id,
         p_correlation_id => p_correlation_id
      );

      IF p_inf_id IS NULL THEN
         RETURN
            failure_Result(
               p_code => 'REQUEST_INVALID_INF_ID',
               p_info => 'p_inf_id must not be NULL'
            );
      END IF;

      IF p_status_cd IS NULL
         OR p_status_cd NOT IN (STATUS_NEW, STATUS_DONE)
      THEN
         RETURN
            failure_Result(
               p_code      => 'REQUEST_INVALID_INITIAL_STATUS',
               p_info      =>
                  'Request may be created only in NEW or DONE status',
               p_inf_id    => p_inf_id,
               p_status_cd => p_status_cd
            );
      END IF;


      IF NOT exists_Inf(p_inf_id) THEN
         RETURN
            failure_Result(
               p_code   => 'REQUEST_INF_NOT_FOUND',
               p_info   => 'Не найден вид сведений inf_id=' || p_inf_id,
               p_inf_id => p_inf_id
            );
      END IF;


      l_external_uuid  := MI_Utils.uuid_V7;
      l_correlation_id := NVL(p_correlation_id, MI_Utils.uuid_V7);

      l_log.context(
         p_inf_id         => p_inf_id,
         p_correlation_id => l_correlation_id
      );


      INSERT INTO MI_REQ (
         INF_ID,

         EXTERNAL_UUID,
         CORRELATION_ID,

         ORIGINAL_REQ_UUID,
         CTAXREQ_ID,
         MESSAGE_UUID,

         STATUS_CD,

         ITYPE,
         I1,
         I2,
         I3,

         PARENT_REQ_ID
      )
      VALUES (
         p_inf_id,

         l_external_uuid,
         l_correlation_id,

         p_original_req_uuid,
         p_ctaxreq_id,
         p_message_uuid,

         p_status_cd,

         p_itype,
         p_i1,
         p_i2,
         p_i3,

         p_parent_req_id
      )
      RETURNING REQ_ID
           INTO l_req_id;


      l_log.context(
         p_inf_id         => p_inf_id,
         p_req_id         => l_req_id,
         p_correlation_id => l_correlation_id
      );

      l_log.info(
         p_message_text => 'Request created',
         p_action_code  => 'create'
      );


      l_result :=
         success_Result(
            p_code      => 'REQUEST_CREATED',
            p_info      => 'Request created',
            p_req_id    => l_req_id,
            p_inf_id    => p_inf_id,
            p_status_cd => p_status_cd
         );

      l_result.parameters('external_uuid')  := l_external_uuid;
      l_result.parameters('correlation_id') := l_correlation_id;

      RETURN l_result;

   EXCEPTION
      WHEN OTHERS THEN
         l_sqlcode := SQLCODE;
         l_sqlerrm := SQLERRM;

         l_log.error(
            p_message_text => 'create_Request failed',
            p_action_code  => 'create',
            p_details_text => TO_CLOB(l_sqlerrm)
         );

         RETURN
            MI_ResultCtx.from_Exception(
               p_sqlcode => l_sqlcode,
               p_sqlerrm => l_sqlerrm,
               p_code    => 'REQUEST_CREATE_FAILED',
               p_info    => 'Не удалось создать request'
            );
   END create_Request;


   /* */
   FUNCTION take_For_Proc (
      p_req_id IN MI_REQ.REQ_ID%TYPE,
      p_info   IN VARCHAR2 DEFAULT NULL
   )
      RETURN MI_ResultCtx.exec_Result_t
   IS
      l_inf_id    MI_REQ.INF_ID%TYPE;
      l_note      MI_REQ.NOTE%TYPE;

      l_sqlcode   PLS_INTEGER;
      l_sqlerrm   VARCHAR2(2000);

      l_log       MI_Logger_T := g_log;
   BEGIN
      l_log.context(p_req_id => p_req_id);

      l_note :=
         SUBSTR(
            TRIM(NVL(p_info, ''))
            || ' ['
            || TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD HH24:MI:SS.FF3')
            || ']',
            1,
            500
         );


      UPDATE MI_REQ
         SET STATUS_CD = STATUS_BUSY,
             NOTE      = l_note
       WHERE REQ_ID = p_req_id
         AND STATUS_CD IN (STATUS_NEW, STATUS_ERROR)
      RETURNING INF_ID
           INTO l_inf_id;


      IF SQL%ROWCOUNT = 1 THEN
         l_log.context(
            p_inf_id => l_inf_id,
            p_req_id => p_req_id
         );

         l_log.info(
            p_message_text => 'Request taken for processing',
            p_action_code  => 'take_for_proc',
            p_details_text => TO_CLOB(l_note)
         );

         RETURN
            success_Result(
               p_code      => 'REQUEST_TAKEN',
               p_info      => 'Request taken for processing',
               p_req_id    => p_req_id,
               p_inf_id    => l_inf_id,
               p_status_cd => STATUS_BUSY
            );
      END IF;


      RETURN
         current_State_Failure(
            p_req_id    => p_req_id,
            p_operation => 'take_For_Proc',
            p_expected  => 'NEW or ERROR'
         );

   EXCEPTION
      WHEN OTHERS THEN
         l_sqlcode := SQLCODE;
         l_sqlerrm := SQLERRM;

         l_log.error(
            p_message_text => 'take_For_Proc failed',
            p_action_code  => 'take_for_proc',
            p_details_text => TO_CLOB(l_sqlerrm)
         );

         RETURN
            MI_ResultCtx.from_Exception(
               p_sqlcode => l_sqlcode,
               p_sqlerrm => l_sqlerrm,
               p_code    => 'REQUEST_TAKE_FAILED',
               p_info    => 'Ошибка взятия request в обработку'
            );
   END take_For_Proc;


   /* */
   PROCEDURE take_For_Proc (
      p_req_id    IN  MI_REQ.REQ_ID%TYPE,
      p_info      IN  VARCHAR2,
      p_ret_code  OUT NUMBER,
      p_ret_info  OUT VARCHAR2
   )
   IS
      l_result MI_ResultCtx.exec_Result_t;
   BEGIN
      l_result :=
         take_For_Proc(
            p_req_id => p_req_id,
            p_info   => p_info
         );

      MI_ResultCtx.export_Jdbc_Result(
         p_result        => l_result,
         p_success_code  => RET_OK,
         p_failure_code  => RET_FAIL,
         p_ret_code      => p_ret_code,
         p_ret_info      => p_ret_info
      );
   END take_For_Proc;


   /* */
   FUNCTION to_Sent (
      p_req_id IN MI_REQ.REQ_ID%TYPE
   )
      RETURN MI_ResultCtx.exec_Result_t
   IS
      l_inf_id    MI_REQ.INF_ID%TYPE;

      l_sqlcode   PLS_INTEGER;
      l_sqlerrm   VARCHAR2(2000);

      l_log       MI_Logger_T := g_log;
   BEGIN
      l_log.context(p_req_id => p_req_id);

      UPDATE MI_REQ
         SET STATUS_CD = STATUS_SENT
       WHERE REQ_ID = p_req_id
         AND STATUS_CD = STATUS_BUSY
      RETURNING INF_ID
           INTO l_inf_id;


      IF SQL%ROWCOUNT = 1 THEN
         l_log.context(
            p_inf_id => l_inf_id,
            p_req_id => p_req_id
         );

         l_log.info(
            p_message_text => 'Request moved to SENT',
            p_action_code  => 'to_sent'
         );

         RETURN
            success_Result(
               p_code      => 'REQUEST_SENT',
               p_info      => 'Request moved to SENT',
               p_req_id    => p_req_id,
               p_inf_id    => l_inf_id,
               p_status_cd => STATUS_SENT
            );
      END IF;


      RETURN
         current_State_Failure(
            p_req_id    => p_req_id,
            p_operation => 'to_Sent',
            p_expected  => 'BUSY'
         );

   EXCEPTION
      WHEN OTHERS THEN
         l_sqlcode := SQLCODE;
         l_sqlerrm := SQLERRM;

         l_log.error(
            p_message_text => 'to_Sent failed',
            p_action_code  => 'to_sent',
            p_details_text => TO_CLOB(l_sqlerrm)
         );

         RETURN
            MI_ResultCtx.from_Exception(
               p_sqlcode => l_sqlcode,
               p_sqlerrm => l_sqlerrm,
               p_code    => 'REQUEST_TO_SENT_FAILED',
               p_info    => 'Ошибка перевода request в SENT'
            );
   END to_Sent;


   /* */
   PROCEDURE to_Sent (
      p_req_id    IN  MI_REQ.REQ_ID%TYPE,
      p_ret_code  OUT NUMBER,
      p_ret_info  OUT VARCHAR2
   )
   IS
      l_result MI_ResultCtx.exec_Result_t;
   BEGIN
      l_result := to_Sent(p_req_id => p_req_id);

      MI_ResultCtx.export_Jdbc_Result(
         p_result        => l_result,
         p_success_code  => RET_OK,
         p_failure_code  => RET_FAIL,
         p_ret_code      => p_ret_code,
         p_ret_info      => p_ret_info
      );
   END to_Sent;


   /* */
   FUNCTION to_Success (
      p_req_id IN MI_REQ.REQ_ID%TYPE
   )
      RETURN MI_ResultCtx.exec_Result_t
   IS
      l_inf_id    MI_REQ.INF_ID%TYPE;

      l_sqlcode   PLS_INTEGER;
      l_sqlerrm   VARCHAR2(2000);

      l_log       MI_Logger_T := g_log;
   BEGIN
      l_log.context(p_req_id => p_req_id);

      UPDATE MI_REQ
         SET STATUS_CD = STATUS_DONE
       WHERE REQ_ID = p_req_id
         AND STATUS_CD = STATUS_SENT
      RETURNING INF_ID
           INTO l_inf_id;


      IF SQL%ROWCOUNT = 1 THEN
         l_log.context(
            p_inf_id => l_inf_id,
            p_req_id => p_req_id
         );

         l_log.info(
            p_message_text => 'Request moved to DONE',
            p_action_code  => 'to_success'
         );

         RETURN
            success_Result(
               p_code      => 'REQUEST_DONE',
               p_info      => 'Request moved to DONE',
               p_req_id    => p_req_id,
               p_inf_id    => l_inf_id,
               p_status_cd => STATUS_DONE
            );
      END IF;


      RETURN
         current_State_Failure(
            p_req_id    => p_req_id,
            p_operation => 'to_Success',
            p_expected  => 'SENT'
         );

   EXCEPTION
      WHEN OTHERS THEN
         l_sqlcode := SQLCODE;
         l_sqlerrm := SQLERRM;

         l_log.error(
            p_message_text => 'to_Success failed',
            p_action_code  => 'to_success',
            p_details_text => TO_CLOB(l_sqlerrm)
         );

         RETURN
            MI_ResultCtx.from_Exception(
               p_sqlcode => l_sqlcode,
               p_sqlerrm => l_sqlerrm,
               p_code    => 'REQUEST_TO_SUCCESS_FAILED',
               p_info    => 'Ошибка перевода request в DONE'
            );
   END to_Success;


   /* */
   PROCEDURE to_Success (
      p_req_id    IN  MI_REQ.REQ_ID%TYPE,
      p_ret_code  OUT NUMBER,
      p_ret_info  OUT VARCHAR2
   )
   IS
      l_result MI_ResultCtx.exec_Result_t;
   BEGIN
      l_result := to_Success(p_req_id => p_req_id);

      MI_ResultCtx.export_Jdbc_Result(
         p_result        => l_result,
         p_success_code  => RET_OK,
         p_failure_code  => RET_FAIL,
         p_ret_code      => p_ret_code,
         p_ret_info      => p_ret_info
      );
   END to_Success;


   /* */
   FUNCTION to_Error (
      p_req_id IN MI_REQ.REQ_ID%TYPE
   )
      RETURN MI_ResultCtx.exec_Result_t
   IS
      l_inf_id    MI_REQ.INF_ID%TYPE;

      l_sqlcode   PLS_INTEGER;
      l_sqlerrm   VARCHAR2(2000);

      l_log       MI_Logger_T := g_log;
   BEGIN
      l_log.context(p_req_id => p_req_id);

      UPDATE MI_REQ
         SET STATUS_CD = STATUS_ERROR
       WHERE REQ_ID = p_req_id
         AND STATUS_CD IN (STATUS_BUSY, STATUS_SENT)
      RETURNING INF_ID
           INTO l_inf_id;


      IF SQL%ROWCOUNT = 1 THEN
         l_log.context(
            p_inf_id => l_inf_id,
            p_req_id => p_req_id
         );

         l_log.info(
            p_message_text => 'Request moved to ERROR',
            p_action_code  => 'to_error'
         );

         RETURN
            success_Result(
               p_code      => 'REQUEST_ERROR',
               p_info      => 'Request moved to ERROR',
               p_req_id    => p_req_id,
               p_inf_id    => l_inf_id,
               p_status_cd => STATUS_ERROR
            );
      END IF;


      RETURN
         current_State_Failure(
            p_req_id    => p_req_id,
            p_operation => 'to_Error',
            p_expected  => 'BUSY or SENT'
         );

   EXCEPTION
      WHEN OTHERS THEN
         l_sqlcode := SQLCODE;
         l_sqlerrm := SQLERRM;

         l_log.error(
            p_message_text => 'to_Error failed',
            p_action_code  => 'to_error',
            p_details_text => TO_CLOB(l_sqlerrm)
         );

         RETURN
            MI_ResultCtx.from_Exception(
               p_sqlcode => l_sqlcode,
               p_sqlerrm => l_sqlerrm,
               p_code    => 'REQUEST_TO_ERROR_FAILED',
               p_info    => 'Ошибка перевода request в ERROR'
            );
   END to_Error;


   /* */
   PROCEDURE to_Error (
      p_req_id    IN  MI_REQ.REQ_ID%TYPE,
      p_ret_code  OUT NUMBER,
      p_ret_info  OUT VARCHAR2
   )
   IS
      l_result MI_ResultCtx.exec_Result_t;
   BEGIN
      l_result := to_Error(p_req_id => p_req_id);

      MI_ResultCtx.export_Jdbc_Result(
         p_result        => l_result,
         p_success_code  => RET_OK,
         p_failure_code  => RET_FAIL,
         p_ret_code      => p_ret_code,
         p_ret_info      => p_ret_info
      );
   END to_Error;


   /* */
   FUNCTION apply_Request_Failure_Impl (
      p_external_uuid  IN MI_REQ.EXTERNAL_UUID%TYPE,
      p_message_uuid   IN MI_REQ.MESSAGE_UUID%TYPE,

      p_reason_code    IN VARCHAR2,

      p_error_code     IN MI_REQ.RESULT_CODE%TYPE,
      p_error_info     IN MI_REQ.RESULT_INFO%TYPE,
      p_error_details  IN MI_REQ.NOTE%TYPE,
      p_occurred_at    IN MI_REQ.RESULT_TIME%TYPE
   )
      RETURN MI_ResultCtx.exec_Result_t
   IS
      l_req_id                MI_REQ.REQ_ID%TYPE;
      l_inf_id                MI_REQ.INF_ID%TYPE;
      l_status_cd             MI_REQ.STATUS_CD%TYPE;
      l_current_message_uuid  MI_REQ.MESSAGE_UUID%TYPE;
      l_correlation_id        MI_REQ.CORRELATION_ID%TYPE;

      l_reason_code           VARCHAR2(32767);
      l_savepoint_name        DCL.T_Name;
      l_row_count             PLS_INTEGER;

      l_result                MI_ResultCtx.exec_Result_t;
      l_sqlcode               PLS_INTEGER;
      l_sqlerrm               VARCHAR2(2000);
      l_rollback_ok           BOOLEAN;

      l_log                   MI_Logger_T := g_log;


      /* */
      PROCEDURE rollback_For_Result
      IS
      BEGIN
         IF NOT MI_Transaction.rollback_Savepoint(
                   p_name => l_savepoint_name,
                   p_log  => l_log
                )
         THEN
            MI_ResultCtx.raise_Error(
               p_code => 'REQUEST_FAILURE_ROLLBACK_FAILED',
               p_info =>
                  'Не удалось завершить обработку без изменений; '
                  || 'требуется полный rollback транзакции'
            );
         END IF;
      END rollback_For_Result;


      /* */
      PROCEDURE add_Transport_Context (
         p_value IN OUT NOCOPY MI_ResultCtx.exec_Result_t
      )
      IS
      BEGIN
         p_value.parameters('ret_code') := TO_CHAR(RET_FAIL);

         IF p_external_uuid IS NOT NULL THEN
            p_value.parameters('external_uuid') := TRIM(p_external_uuid);
         END IF;

         IF p_message_uuid IS NOT NULL THEN
            p_value.parameters('message_uuid') := TRIM(p_message_uuid);
         END IF;

         IF l_reason_code IS NOT NULL THEN
            p_value.parameters('reason_code') := l_reason_code;
         END IF;

         IF l_req_id IS NOT NULL THEN
            p_value.parameters('req_id') := TO_CHAR(l_req_id);
         END IF;

         IF l_inf_id IS NOT NULL THEN
            p_value.parameters('inf_id') := TO_CHAR(l_inf_id);
         END IF;

         IF l_status_cd IS NOT NULL THEN
            p_value.parameters('status_cd') := TO_CHAR(l_status_cd);
         END IF;
      END add_Transport_Context;


   BEGIN
      
      -- Validate the transport envelope before locks and DML.
      
      IF p_external_uuid IS NULL OR NOT MI_Utils.is_Uuid(TRIM(p_external_uuid))
      THEN
         RETURN
            failure_Result(
               p_code     => 'REQUEST_FAILURE_INVALID_REQUEST_UUID',
               p_info     => 'p_external_uuid must be a valid UUID',
               p_ret_code => RET_FAIL
            );
      END IF;

      IF p_message_uuid IS NULL OR NOT MI_Utils.is_Uuid(TRIM(p_message_uuid))
      THEN
         RETURN
            failure_Result(
               p_code     => 'REQUEST_FAILURE_INVALID_MESSAGE_UUID',
               p_info     => 'p_message_uuid must be a valid UUID',
               p_ret_code => RET_FAIL
            );
      END IF;

      l_reason_code := UPPER(TRIM(p_reason_code));

      IF l_reason_code IS NULL
         OR l_reason_code NOT IN ('REQUEST_REJECTED', 'REQUEST_FAILED')
      THEN
         RETURN
            failure_Result(
               p_code     => 'REQUEST_FAILURE_INVALID_REASON',
               p_info     => 'Unsupported p_reason_code: ' || NVL(l_reason_code, '<NULL>'),
               p_ret_code => RET_FAIL
            );
      END IF;


      g_log.enter_f(
         p_function_name => 'apply_Request_Failure',
         p_message_text  => 'external_uuid=' || TRIM(p_external_uuid) || ', reason_code='|| l_reason_code
      );


      DCL.SavePoint(l_savepoint_name);

      IF l_savepoint_name IS NULL THEN
         RETURN
            failure_Result(
               p_code     => 'REQUEST_FAILURE_SAVEPOINT_UNAVAILABLE',
               p_info     => 'DCL did not create the operation savepoint',
               p_ret_code => RET_FAIL
            );
      END IF;


      /*
         MI_REQ is the aggregate root. The row is locked before inspecting
         status and idempotency state, so concurrent callbacks are serialized.
      */
      BEGIN
         SELECT REQ_ID,
                INF_ID,
                STATUS_CD,
                MESSAGE_UUID,
                CORRELATION_ID
           INTO l_req_id,
                l_inf_id,
                l_status_cd,
                l_current_message_uuid,
                l_correlation_id
           FROM MI_REQ
          WHERE EXTERNAL_UUID = TRIM(p_external_uuid)
            FOR UPDATE;

      EXCEPTION
         WHEN NO_DATA_FOUND THEN
            rollback_For_Result;

            RETURN
               failure_Result(
                  p_code     => 'REQUEST_FAILURE_NOT_FOUND',
                  p_info     =>
                     'Не найден request с external_uuid='
                     || TRIM(p_external_uuid),
                  p_ret_code => RET_FAIL
               );
      END;


      l_log.context(
         p_inf_id         => l_inf_id,
         p_req_id         => l_req_id,
         p_correlation_id => l_correlation_id
      );


      IF l_status_cd = STATUS_ERROR THEN
         IF TRIM(l_current_message_uuid) = TRIM(p_message_uuid) THEN
            rollback_For_Result;

            l_log.info(
               p_message_text => 'Request failure already applied',
               p_action_code  => 'failure_idempotent',
               p_details_text => TO_CLOB('message_uuid=' || TRIM(p_message_uuid))
            );

            l_result :=
               success_Result(
                  p_code      => 'REQUEST_FAILURE_ALREADY_APPLIED',
                  p_info      => 'Отрицательный ответ уже применён ранее',
                  p_req_id    => l_req_id,
                  p_inf_id    => l_inf_id,
                  p_status_cd => STATUS_ERROR,
                  p_ret_code  => RET_OK
               );

            l_result.parameters('idempotent')  := 'true';
            l_result.parameters('reason_code') := l_reason_code;
            l_result.parameters('message_uuid') := TRIM(p_message_uuid);

            RETURN l_result;
         END IF;

         rollback_For_Result;

         RETURN
            failure_Result(
               p_code      => 'REQUEST_FAILURE_CONFLICT',
               p_info      =>
                    'Request уже установлен в ERROR другим сообщением: '
                 || 'current_message_uuid='
                 || NVL(TRIM(l_current_message_uuid), '<NULL>')
                 || ', incoming_message_uuid='
                 || TRIM(p_message_uuid),
               p_req_id    => l_req_id,
               p_inf_id    => l_inf_id,
               p_status_cd => l_status_cd,
               p_ret_code  => RET_FAIL
            );
      END IF;


      IF l_status_cd <> STATUS_SENT THEN
         rollback_For_Result;

         RETURN
            failure_Result(
               p_code      => 'REQUEST_FAILURE_BAD_STATUS',
               p_info      =>
                    'Request должен находиться в SENT; current_status='
                 || status_Name(l_status_cd)
                 || ' ('
                 || NVL(TO_CHAR(l_status_cd), '<NULL>')
                 || ')',
               p_req_id    => l_req_id,
               p_inf_id    => l_inf_id,
               p_status_cd => l_status_cd,
               p_ret_code  => RET_FAIL
            );
      END IF;


      UPDATE MI_REQ
         SET STATUS_CD    = STATUS_ERROR,
             RESULT_CODE  = p_error_code,
             RESULT_INFO  = p_error_info,
             NOTE         = p_error_details,
             RESULT_TIME  = p_occurred_at,
             MESSAGE_UUID = TRIM(p_message_uuid)
       WHERE REQ_ID = l_req_id
         AND STATUS_CD = STATUS_SENT;

      l_row_count := SQL%ROWCOUNT;

      IF l_row_count <> 1 THEN
         rollback_For_Result;

         RETURN
            failure_Result(
               p_code      => 'REQUEST_FAILURE_UPDATE_FAILED',
               p_info      =>
                  'Отрицательный ответ не применён, row_count='
                  || l_row_count,
               p_req_id    => l_req_id,
               p_inf_id    => l_inf_id,
               p_status_cd => l_status_cd,
               p_ret_code  => RET_FAIL
            );
      END IF;


      l_status_cd := STATUS_ERROR;

      l_log.info(
         p_message_text => 'Request failure applied',
         p_action_code  => 'apply_failure',
         p_details_text =>
            TO_CLOB(
                  'reason_code='
               || l_reason_code
               || ', error_code='
               || NVL(p_error_code, '<NULL>')
               || ', message_uuid='
               || TRIM(p_message_uuid)
            )
      );

      l_log.exit_f(
         p_function_name => 'apply_Request_Failure',
         p_message_text  => 'OK'
      );


      l_result :=
         success_Result(
            p_code      => 'REQUEST_FAILURE_APPLIED',
            p_info      => 'Отрицательный ответ успешно применён',
            p_req_id    => l_req_id,
            p_inf_id    => l_inf_id,
            p_status_cd => STATUS_ERROR,
            p_ret_code  => RET_OK
         );

      l_result.parameters('idempotent')   := 'false';
      l_result.parameters('reason_code')  := l_reason_code;
      l_result.parameters('message_uuid') := TRIM(p_message_uuid);

      RETURN l_result;


   EXCEPTION
      WHEN OTHERS THEN
         l_sqlcode     := SQLCODE;
         l_sqlerrm     := SQLERRM;
         l_rollback_ok :=
            MI_Transaction.rollback_Savepoint(
               p_name => l_savepoint_name,
               p_log  => l_log
            );

         l_log.error(
            p_message_text => 'apply_Request_Failure failed',
            p_action_code  => 'apply_failure',
            p_details_text =>
               TO_CLOB(
                     l_sqlerrm
                  || CHR(10)
                  || DBMS_UTILITY.format_error_backtrace
                  || CHR(10)
                  || 'own_rollback='
                  || MI_Utils.to_Char(l_rollback_ok)
               )
         );

         l_result :=
            MI_ResultCtx.from_Exception(
               p_sqlcode => l_sqlcode,
               p_sqlerrm => l_sqlerrm,
               p_code    => 'REQUEST_FAILURE_APPLY_FAILED',
               p_info    => 'Не удалось применить отрицательный ответ'
            );

         add_Transport_Context(l_result);

         IF NOT l_rollback_ok THEN
            l_result :=
               MI_ResultCtx.wrap_Exception(
                  p_cause => l_result,
                  p_code  => 'REQUEST_FAILURE_ROLLBACK_FAILED',
                  p_info  =>
                     'Не удалось откатить собственную работу; '
                     || 'требуется полный rollback транзакции'
               );

            MI_ResultCtx.raise_Error(l_result);
         END IF;

         RETURN l_result;
   END apply_Request_Failure_Impl;


   /* */
   PROCEDURE apply_Request_Failure (
      p_external_uuid  IN MI_REQ.EXTERNAL_UUID%TYPE,
      p_message_uuid   IN MI_REQ.MESSAGE_UUID%TYPE,

      p_reason_code    IN VARCHAR2,

      p_error_code     IN MI_REQ.RESULT_CODE%TYPE,
      p_error_info     IN MI_REQ.RESULT_INFO%TYPE,
      p_error_details  IN MI_REQ.NOTE%TYPE,
      p_occurred_at    IN MI_REQ.RESULT_TIME%TYPE,

      p_ret_code       OUT NUMBER,
      p_ret_info       OUT VARCHAR2
   )
   IS
      l_result MI_ResultCtx.exec_Result_t;
   BEGIN
      p_ret_code := RET_FAIL;
      p_ret_info := NULL;

      l_result :=
         apply_Request_Failure_Impl(
            p_external_uuid => p_external_uuid,
            p_message_uuid  => p_message_uuid,
            p_reason_code   => p_reason_code,
            p_error_code    => p_error_code,
            p_error_info    => p_error_info,
            p_error_details => p_error_details,
            p_occurred_at   => p_occurred_at
         );

      MI_ResultCtx.export_Jdbc_Result(
         p_result        => l_result,
         p_success_code  => RET_OK,
         p_failure_code  => RET_FAIL,
         p_ret_code      => p_ret_code,
         p_ret_info      => p_ret_info
      );
   END apply_Request_Failure;


   /* */
   FUNCTION reset (
      p_req_id IN MI_REQ.REQ_ID%TYPE,
      p_info   IN VARCHAR2 DEFAULT NULL
   )
      RETURN MI_ResultCtx.exec_Result_t
   IS
      l_inf_id      MI_REQ.INF_ID%TYPE;
      l_status_cd   MI_REQ.STATUS_CD%TYPE;
      l_note        MI_REQ.NOTE%TYPE;

      l_sqlcode     PLS_INTEGER;
      l_sqlerrm     VARCHAR2(2000);

      l_log         MI_Logger_T := g_log;
   BEGIN
      l_log.context(p_req_id => p_req_id);

      l_note :=
         SUBSTR(
            TRIM(NVL(p_info, ''))
            || ' [RESET '
            || TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD HH24:MI:SS.FF3')
            || ']',
            1,
            500
         );


      UPDATE MI_REQ
         SET STATUS_CD = STATUS_NEW,
             NOTE      = l_note
       WHERE REQ_ID = p_req_id
         AND STATUS_CD <> STATUS_NEW
      RETURNING INF_ID
           INTO l_inf_id;


      IF SQL%ROWCOUNT = 1 THEN
         l_log.context(
            p_inf_id => l_inf_id,
            p_req_id => p_req_id
         );

         l_log.info(
            p_message_text => 'Request reset to NEW',
            p_action_code  => 'reset',
            p_details_text => TO_CLOB(l_note)
         );

         RETURN
            success_Result(
               p_code      => 'REQUEST_RESET',
               p_info      => 'Request reset to NEW',
               p_req_id    => p_req_id,
               p_inf_id    => l_inf_id,
               p_status_cd => STATUS_NEW
            );
      END IF;


      BEGIN
         SELECT INF_ID,
                STATUS_CD
           INTO l_inf_id,
                l_status_cd
           FROM MI_REQ
          WHERE REQ_ID = p_req_id;

      EXCEPTION
         WHEN NO_DATA_FOUND THEN
            RETURN
               failure_Result(
                  p_code   => 'REQUEST_NOT_FOUND',
                  p_info   => 'Не найден request с req_id=' || p_req_id,
                  p_req_id => p_req_id
               );
      END;

      l_log.context(
         p_inf_id => l_inf_id,
         p_req_id => p_req_id
      );


      /*
         reset(NEW) идемпотентен.
      */
      IF l_status_cd = STATUS_NEW THEN
         RETURN
            success_Result(
               p_code      => 'REQUEST_ALREADY_NEW',
               p_info      => 'Request already in NEW status',
               p_req_id    => p_req_id,
               p_inf_id    => l_inf_id,
               p_status_cd => STATUS_NEW
            );
      END IF;


      RETURN
         failure_Result(
            p_code      => 'REQUEST_RESET_FAILED',
            p_info      => 'Не удалось сбросить request в NEW',
            p_req_id    => p_req_id,
            p_inf_id    => l_inf_id,
            p_status_cd => l_status_cd
         );

   EXCEPTION
      WHEN OTHERS THEN
         l_sqlcode := SQLCODE;
         l_sqlerrm := SQLERRM;

         l_log.error(
            p_message_text => 'reset failed',
            p_action_code  => 'reset',
            p_details_text => TO_CLOB(l_sqlerrm)
         );

         RETURN
            MI_ResultCtx.from_Exception(
               p_sqlcode => l_sqlcode,
               p_sqlerrm => l_sqlerrm,
               p_code    => 'REQUEST_RESET_FAILED',
               p_info    => 'Ошибка reset request'
            );
   END reset;

END MI_Request_Api;
/
