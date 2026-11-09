CREATE OR REPLACE PACKAGE MI_Item_Result_Api
IS

   VERSION CONSTANT VARCHAR2(100) :=
      '$Id: {1.0.1} {09.11.2026} Sulimoff$';


   /*
      response_kind из входящего item response.
   */
   RESPONSE_FAIL CONSTANT PLS_INTEGER := -1;
   RESPONSE_OK   CONSTANT PLS_INTEGER :=  0;


   /*
      Числовой compatibility result для transport dispatcher.

      Структурированный результат операции возвращается через MI_ResultCtx.
      Значение также помещается в parameters('ret_code').
   */
   RET_FAIL            CONSTANT PLS_INTEGER := -1;
   RET_APPLIED         CONSTANT PLS_INTEGER :=  0;
   RET_ALREADY_APPLIED CONSTANT PLS_INTEGER :=  1;
   RET_OTHER_APPLIED   CONSTANT PLS_INTEGER :=  2;


   FUNCTION get_Version
      RETURN VARCHAR2;


   /*
      Атомарно применяет результат к item.

      p_item_table — имя item table в текущей схеме, без schema prefix.
      Таблица обязана поддерживать общий item outcome contract:

         ITM_ID, REQ_ID, EXTERNAL_UUID, MESSAGE_UUID,
         IRES_CODE, CRES_INFO, TRES_TIME, ERROR_CODE.

      Для успешного response core вызывает business mapper внутри той же
      транзакции, после блокировки MI_REQ и item. Mapper задаётся как
      PACKAGE.PROCEDURE и обязан иметь сигнатуру:

         PROCEDURE map_Item_Result (
            p_itm_id       IN  NUMBER,
            p_payload_text IN  CLOB,
            p_payload_type IN  VARCHAR2,
            p_ires_code    OUT NUMBER,
            p_cres_info    OUT CLOB
         );

      Mapper может изменять business-specific поля item, но не должен
      изменять перечисленные выше common outcome fields. COMMIT, ROLLBACK
      и autonomous transaction в mapper запрещены контрактом.

      Для failed response mapper не вызывается; IRES_CODE устанавливается
      в RESPONSE_FAIL, ERROR_CODE — в p_response_code.

      Конкурентность:
         1. MI_REQ блокируется первым;
         2. item блокируется вторым;
         3. request переводится SENT -> DONE только после обработки всех
            items этого request.

      Такой порядок сериализует результаты одного request и исключает
      потерю финального перехода при параллельной обработке разных items.

      Идемпотентность:
         RET_ALREADY_APPLIED — тот же MESSAGE_UUID, success;
         RET_OTHER_APPLIED   — item уже обработан другим MESSAGE_UUID,
                               failure/conflict.

      Package не выполняет COMMIT. Транзакцией управляет вызывающая сторона.
      Локальный rollback выполняется только через DCL.SavePoint/RollBack;
      поведение при вызове из trigger определяется общим DCL contract.
   */
   FUNCTION apply_Item_Result (
      p_item_table        IN VARCHAR2,
      p_payload_mapper    IN VARCHAR2,

      p_request_uuid      IN MI_REQ.EXTERNAL_UUID%TYPE,
      p_message_uuid      IN MI_REQ.MESSAGE_UUID%TYPE,
      p_item_uuid         IN MI_REQ.EXTERNAL_UUID%TYPE,

      p_response_kind     IN PLS_INTEGER,

      p_response_code     IN MI_REQ.RESULT_CODE%TYPE,
      p_response_info     IN MI_REQ.RESULT_INFO%TYPE,
      p_response_details  IN CLOB,
      p_response_time     IN TIMESTAMP WITH TIME ZONE,

      p_payload_text      IN CLOB,
      p_payload_type      IN VARCHAR2 DEFAULT 'json'
   )
      RETURN MI_ResultCtx.exec_Result_t;

END MI_Item_Result_Api;
/

CREATE OR REPLACE PACKAGE BODY MI_Item_Result_Api
IS

   cLogger CONSTANT VARCHAR2(64) := 'mi.request.item';


   /*
      Package-level constant хранит стабильную идентичность пакета.
      Контекст request/item задаётся только в локальной value-copy l_log.
   */
   g_log CONSTANT MI_Logger_T :=
      MI_Logger_T(
         p_logger_name  => cLogger,
         p_package_name => 'MI_Item_Result_Api'
      );


   ---------------------------------------------------------------------------
   FUNCTION get_Version
      RETURN VARCHAR2
   IS
   BEGIN
      RETURN VERSION;
   END get_Version;


   ---------------------------------------------------------------------------
   FUNCTION mapper_Name (
      p_value IN VARCHAR2
   )
      RETURN VARCHAR2
   IS
      l_value      VARCHAR2(261);
      l_dot_pos    PLS_INTEGER;
      l_package    VARCHAR2(128);
      l_procedure  VARCHAR2(128);
   BEGIN
      l_value   := UPPER(TRIM(p_value));
      l_dot_pos := INSTR(l_value, '.');

      IF l_dot_pos <= 1
         OR l_dot_pos = LENGTH(l_value)
         OR INSTR(l_value, '.', l_dot_pos + 1) > 0
      THEN
         RAISE_APPLICATION_ERROR(
            -20011,
            'Invalid payload mapper, expected PACKAGE.PROCEDURE: '
            || NVL(p_value, '<NULL>')
         );
      END IF;

      l_package :=
         MI_Utils.simple_Sql_Name(
            p_value => SUBSTR(l_value, 1, l_dot_pos - 1),
            p_kind  => 'mapper package'
         );

      l_procedure :=
         MI_Utils.simple_Sql_Name(
            p_value => SUBSTR(l_value, l_dot_pos + 1),
            p_kind  => 'mapper procedure'
         );

      RETURN l_package || '.' || l_procedure;
   END mapper_Name;


   ---------------------------------------------------------------------------
   FUNCTION success_Result (
      p_code               IN VARCHAR2,
      p_info               IN VARCHAR2,
      p_ret_code           IN PLS_INTEGER,

      p_req_id             IN MI_REQ.REQ_ID%TYPE        DEFAULT NULL,
      p_inf_id             IN MI_REQ.INF_ID%TYPE        DEFAULT NULL,
      p_itm_id             IN NUMBER                    DEFAULT NULL,
      p_status_cd          IN MI_REQ.STATUS_CD%TYPE     DEFAULT NULL,

      p_idempotent         IN BOOLEAN                   DEFAULT NULL,
      p_request_completed  IN BOOLEAN                   DEFAULT NULL
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

      l_result.parameters('ret_code') := TO_CHAR(p_ret_code);

      IF p_req_id IS NOT NULL THEN
         l_result.parameters('req_id') := TO_CHAR(p_req_id);
      END IF;

      IF p_inf_id IS NOT NULL THEN
         l_result.parameters('inf_id') := TO_CHAR(p_inf_id);
      END IF;

      IF p_itm_id IS NOT NULL THEN
         l_result.parameters('itm_id') := TO_CHAR(p_itm_id);
      END IF;

      IF p_status_cd IS NOT NULL THEN
         l_result.parameters('status_cd') := TO_CHAR(p_status_cd);
      END IF;

      IF p_idempotent IS NOT NULL THEN
         l_result.parameters('idempotent') :=
            MI_Utils.to_Char(p_idempotent);
      END IF;

      IF p_request_completed IS NOT NULL THEN
         l_result.parameters('request_completed') :=
            MI_Utils.to_Char(p_request_completed);
      END IF;

      RETURN l_result;
   END success_Result;


   ---------------------------------------------------------------------------
   FUNCTION failure_Result (
      p_code       IN VARCHAR2,
      p_info       IN VARCHAR2,
      p_ret_code   IN PLS_INTEGER               DEFAULT RET_FAIL,

      p_req_id     IN MI_REQ.REQ_ID%TYPE        DEFAULT NULL,
      p_inf_id     IN MI_REQ.INF_ID%TYPE        DEFAULT NULL,
      p_itm_id     IN NUMBER                    DEFAULT NULL,
      p_status_cd  IN MI_REQ.STATUS_CD%TYPE     DEFAULT NULL,

      p_details    IN CLOB                      DEFAULT NULL
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

      l_result.parameters('ret_code') := TO_CHAR(p_ret_code);

      IF p_req_id IS NOT NULL THEN
         l_result.parameters('req_id') := TO_CHAR(p_req_id);
      END IF;

      IF p_inf_id IS NOT NULL THEN
         l_result.parameters('inf_id') := TO_CHAR(p_inf_id);
      END IF;

      IF p_itm_id IS NOT NULL THEN
         l_result.parameters('itm_id') := TO_CHAR(p_itm_id);
      END IF;

      IF p_status_cd IS NOT NULL THEN
         l_result.parameters('status_cd') := TO_CHAR(p_status_cd);
      END IF;

      RETURN l_result;
   END failure_Result;


   ---------------------------------------------------------------------------
   FUNCTION apply_Item_Result (
      p_item_table        IN VARCHAR2,
      p_payload_mapper    IN VARCHAR2,

      p_request_uuid      IN MI_REQ.EXTERNAL_UUID%TYPE,
      p_message_uuid      IN MI_REQ.MESSAGE_UUID%TYPE,
      p_item_uuid         IN MI_REQ.EXTERNAL_UUID%TYPE,

      p_response_kind     IN PLS_INTEGER,

      p_response_code     IN MI_REQ.RESULT_CODE%TYPE,
      p_response_info     IN MI_REQ.RESULT_INFO%TYPE,
      p_response_details  IN CLOB,
      p_response_time     IN TIMESTAMP WITH TIME ZONE,

      p_payload_text      IN CLOB,
      p_payload_type      IN VARCHAR2 DEFAULT 'json'
   )
      RETURN MI_ResultCtx.exec_Result_t
   IS
      l_item_table         VARCHAR2(128);
      l_payload_mapper     VARCHAR2(261);
      l_payload_type       VARCHAR2(32767);

      l_req_id             MI_REQ.REQ_ID%TYPE;
      l_inf_id             MI_REQ.INF_ID%TYPE;
      l_status_cd          MI_REQ.STATUS_CD%TYPE;
      l_correlation_id     MI_REQ.CORRELATION_ID%TYPE;

      l_itm_id             NUMBER;
      l_current_message    MI_REQ.MESSAGE_UUID%TYPE;

      l_ires_code          NUMBER;
      l_cres_info          CLOB;
      l_error_code         MI_REQ.RESULT_CODE%TYPE;

      l_pending_count      PLS_INTEGER;
      l_row_count          PLS_INTEGER;
      l_request_completed  BOOLEAN := FALSE;

      l_json_valid         PLS_INTEGER;
      l_xml                XMLTYPE;

      l_sql                VARCHAR2(32767);
      l_result             MI_ResultCtx.exec_Result_t;

      l_sqlcode            PLS_INTEGER;
      l_sqlerrm            VARCHAR2(2000);
      l_savepoint_name     DCL.T_Name;

      l_log                MI_Logger_T := g_log;


      ------------------------------------------------------------------------
      PROCEDURE rollback_Own_Work
      IS
         l_name         DCL.T_Name;
         l_rolled_back  BOOLEAN;
      BEGIN
         IF l_savepoint_name IS NOT NULL THEN
            /*
               Clear first so a DCL error cannot cause a second rollback
               attempt in the outer exception handler.
            */
            l_name           := l_savepoint_name;
            l_savepoint_name := NULL;

            l_rolled_back := DCL.RollBack(l_name);

            IF NOT l_rolled_back THEN
               l_log.warn(
                  p_message_text => 'DCL rollback was not performed',
                  p_action_code  => 'rollback_skipped'
               );
            END IF;
         END IF;
      END rollback_Own_Work;


      ------------------------------------------------------------------------
      PROCEDURE add_Context (
         p_result IN OUT NOCOPY MI_ResultCtx.exec_Result_t
      )
      IS
      BEGIN
         p_result.parameters('ret_code') := TO_CHAR(RET_FAIL);

         IF l_req_id IS NOT NULL THEN
            p_result.parameters('req_id') := TO_CHAR(l_req_id);
         END IF;

         IF l_inf_id IS NOT NULL THEN
            p_result.parameters('inf_id') := TO_CHAR(l_inf_id);
         END IF;

         IF l_itm_id IS NOT NULL THEN
            p_result.parameters('itm_id') := TO_CHAR(l_itm_id);
         END IF;

         IF l_status_cd IS NOT NULL THEN
            p_result.parameters('status_cd') := TO_CHAR(l_status_cd);
         END IF;
      END add_Context;


      ------------------------------------------------------------------------
      PROCEDURE try_Complete_Request
      IS
         l_transition_result MI_ResultCtx.exec_Result_t;
      BEGIN
         l_sql :=
               'SELECT COUNT(*) '
            || '  FROM '
            || l_item_table
            || ' WHERE REQ_ID = :req_id '
            || '   AND MESSAGE_UUID IS NULL '
            || '   AND ROWNUM = 1';

         EXECUTE IMMEDIATE l_sql
            INTO l_pending_count
            USING l_req_id;

         IF l_pending_count > 0
            AND l_status_cd = MI_Request_Api.STATUS_DONE
         THEN
            l_transition_result :=
               failure_Result(
                  p_code      => 'ITEM_RESULT_INCONSISTENT_REQUEST',
                  p_info      => 'Request is DONE but contains unprocessed items',
                  p_req_id    => l_req_id,
                  p_inf_id    => l_inf_id,
                  p_itm_id    => l_itm_id,
                  p_status_cd => l_status_cd
               );

            MI_ResultCtx.raise_Error(l_transition_result);
         END IF;

         IF l_pending_count = 0
            AND l_status_cd = MI_Request_Api.STATUS_SENT
         THEN
            l_transition_result :=
               MI_Request_Api.to_Success(l_req_id);

            IF MI_ResultCtx.is_Failed(l_transition_result) THEN
               l_transition_result :=
                  MI_ResultCtx.wrap_Exception(
                     p_cause => l_transition_result,
                     p_code  => 'ITEM_RESULT_REQUEST_COMPLETE_FAILED',
                     p_info  => 'Не удалось завершить request после обработки items'
                  );

               MI_ResultCtx.raise_Error(l_transition_result);
            END IF;

            l_request_completed := TRUE;
            l_status_cd         := MI_Request_Api.STATUS_DONE;

            l_log.info(
               p_message_text => 'Request completed',
               p_action_code  => 'complete_request'
            );
         END IF;
      END try_Complete_Request;


   BEGIN
      ------------------------------------------------------------------------
      -- Validate scalar input before any lock or DML.
      ------------------------------------------------------------------------
      IF p_request_uuid IS NULL
         OR NOT MI_Utils.is_Uuid(p_request_uuid)
      THEN
         RETURN
            failure_Result(
               p_code => 'ITEM_RESULT_INVALID_REQUEST_UUID',
               p_info => 'p_request_uuid must be a valid UUID'
            );
      END IF;

      IF p_message_uuid IS NULL
         OR NOT MI_Utils.is_Uuid(p_message_uuid)
      THEN
         RETURN
            failure_Result(
               p_code => 'ITEM_RESULT_INVALID_MESSAGE_UUID',
               p_info => 'p_message_uuid must be a valid UUID'
            );
      END IF;

      IF p_item_uuid IS NULL
         OR NOT MI_Utils.is_Uuid(p_item_uuid)
      THEN
         RETURN
            failure_Result(
               p_code => 'ITEM_RESULT_INVALID_ITEM_UUID',
               p_info => 'p_item_uuid must be a valid UUID'
            );
      END IF;

      IF p_response_kind IS NULL
         OR p_response_kind NOT IN (RESPONSE_OK, RESPONSE_FAIL)
      THEN
         RETURN
            failure_Result(
               p_code => 'ITEM_RESULT_INVALID_RESPONSE_KIND',
               p_info =>
                  'Unsupported p_response_kind: '
                  || NVL(TO_CHAR(p_response_kind), '<NULL>')
            );
      END IF;

      IF p_response_time IS NULL THEN
         RETURN
            failure_Result(
               p_code => 'ITEM_RESULT_INVALID_RESPONSE_TIME',
               p_info => 'p_response_time must not be NULL'
            );
      END IF;


      l_payload_type :=
         LOWER(
            NVL(
               NULLIF(TRIM(p_payload_type), ''),
               'json'
            )
         );

      IF l_payload_type NOT IN ('json', 'xml', 'text') THEN
         RETURN
            failure_Result(
               p_code => 'ITEM_RESULT_INVALID_PAYLOAD_TYPE',
               p_info =>
                  'Unsupported p_payload_type: '
                  || l_payload_type
                  || ' (supported: json, xml, text)'
            );
      END IF;


      BEGIN
         l_item_table :=
            MI_Utils.simple_Sql_Name(
               p_value => p_item_table,
               p_kind  => 'item table'
            );

         IF p_response_kind = RESPONSE_OK THEN
            l_payload_mapper := mapper_Name(p_payload_mapper);
         END IF;

      EXCEPTION
         WHEN OTHERS THEN
            l_result :=
               MI_ResultCtx.from_Exception(
                  p_sqlcode => SQLCODE,
                  p_sqlerrm => SQLERRM,
                  p_code    => 'ITEM_RESULT_INVALID_CONFIGURATION',
                  p_info    => 'Invalid item table or payload mapper'
               );

            add_Context(l_result);
            RETURN l_result;
      END;


      IF p_response_kind = RESPONSE_OK THEN
         IF p_payload_text IS NULL
            OR DBMS_LOB.getlength(p_payload_text) = 0
            OR REGEXP_LIKE(
                  p_payload_text,
                  '^[[:space:]]*$'
               )
         THEN
            RETURN
               failure_Result(
                  p_code => 'ITEM_RESULT_PAYLOAD_REQUIRED',
                  p_info => 'p_payload_text must not be NULL or blank for successful item'
               );
         END IF;

         IF l_payload_type = 'json' THEN
            SELECT CASE
                      WHEN p_payload_text IS JSON STRICT THEN 1
                      ELSE 0
                   END
              INTO l_json_valid
              FROM DUAL;

            IF l_json_valid = 0 THEN
               RETURN
                  failure_Result(
                     p_code => 'ITEM_RESULT_INVALID_JSON',
                     p_info => 'p_payload_text is not valid JSON'
                  );
            END IF;

         ELSIF l_payload_type = 'xml' THEN
            BEGIN
               l_xml := XMLTYPE.createXML(p_payload_text);

            EXCEPTION
               WHEN OTHERS THEN
                  l_result :=
                     MI_ResultCtx.from_Exception(
                        p_sqlcode => SQLCODE,
                        p_sqlerrm => SQLERRM,
                        p_code    => 'ITEM_RESULT_INVALID_XML',
                        p_info    => 'p_payload_text is not valid XML'
                     );

                  add_Context(l_result);
                  RETURN l_result;
            END;
         END IF;

      ELSE
         IF p_payload_text IS NOT NULL THEN
            RETURN
               failure_Result(
                  p_code => 'ITEM_RESULT_UNEXPECTED_PAYLOAD',
                  p_info => 'p_payload_text must be NULL for failed item'
               );
         END IF;

         IF TRIM(p_response_code) IS NULL THEN
            RETURN
               failure_Result(
                  p_code => 'ITEM_RESULT_RESPONSE_CODE_REQUIRED',
                  p_info => 'p_response_code must not be NULL or blank for failed item'
               );
         END IF;
      END IF;


      l_log.enter_f(
         p_function_name => 'apply_Item_Result',
         p_message_text  =>
               'table='
            || l_item_table
            || ', request_uuid='
            || TRIM(p_request_uuid)
            || ', item_uuid='
            || TRIM(p_item_uuid)
      );


      DCL.SavePoint(l_savepoint_name);


      ------------------------------------------------------------------------
      -- Request lock is always first: it serializes all item results for one
      -- request and makes the final SENT -> DONE test race-free.
      ------------------------------------------------------------------------
      BEGIN
         SELECT REQ_ID,
                INF_ID,
                STATUS_CD,
                CORRELATION_ID
           INTO l_req_id,
                l_inf_id,
                l_status_cd,
                l_correlation_id
           FROM MI_REQ
          WHERE EXTERNAL_UUID = TRIM(p_request_uuid)
            FOR UPDATE;

      EXCEPTION
         WHEN NO_DATA_FOUND THEN
            rollback_Own_Work;

            RETURN
               failure_Result(
                  p_code => 'ITEM_RESULT_REQUEST_NOT_FOUND',
                  p_info =>
                     'Request not found: request_uuid='
                     || TRIM(p_request_uuid)
               );
      END;


      l_log.context(
         p_inf_id         => l_inf_id,
         p_req_id         => l_req_id,
         p_correlation_id => l_correlation_id
      );


      IF l_status_cd NOT IN (
            MI_Request_Api.STATUS_SENT,
            MI_Request_Api.STATUS_DONE
         )
      THEN
         rollback_Own_Work;

         RETURN
            failure_Result(
               p_code      => 'ITEM_RESULT_REQUEST_BAD_STATUS',
               p_info      =>
                  'Request status must be SENT or DONE, actual='
                  || MI_Request_Api.status_Name(l_status_cd),
               p_req_id    => l_req_id,
               p_inf_id    => l_inf_id,
               p_status_cd => l_status_cd
            );
      END IF;


      ------------------------------------------------------------------------
      -- The item is resolved only inside its request. This is the integrity
      -- check for the polymorphic ITM_ID/table relation.
      ------------------------------------------------------------------------
      l_sql :=
            'SELECT ITM_ID, MESSAGE_UUID '
         || '  FROM '
         || l_item_table
         || ' WHERE REQ_ID = :req_id '
         || '   AND EXTERNAL_UUID = :item_uuid '
         || '   FOR UPDATE';

      BEGIN
         EXECUTE IMMEDIATE l_sql
            INTO l_itm_id,
                 l_current_message
            USING l_req_id,
                  TRIM(p_item_uuid);

      EXCEPTION
         WHEN NO_DATA_FOUND THEN
            rollback_Own_Work;

            RETURN
               failure_Result(
                  p_code      => 'ITEM_RESULT_ITEM_NOT_FOUND',
                  p_info      =>
                        'Item not found: table='
                     || l_item_table
                     || ', request_uuid='
                     || TRIM(p_request_uuid)
                     || ', item_uuid='
                     || TRIM(p_item_uuid),
                  p_req_id    => l_req_id,
                  p_inf_id    => l_inf_id,
                  p_status_cd => l_status_cd
               );
      END;


      l_log.context(
         p_inf_id         => l_inf_id,
         p_req_id         => l_req_id,
         p_itm_id         => l_itm_id,
         p_correlation_id => l_correlation_id
      );


      ------------------------------------------------------------------------
      -- Existing outcome: idempotent replay or conflicting message.
      ------------------------------------------------------------------------
      IF l_current_message IS NOT NULL THEN
         try_Complete_Request;

         IF TRIM(l_current_message) = TRIM(p_message_uuid) THEN
            l_log.info(
               p_message_text => 'Item result already applied',
               p_action_code  => 'already_applied'
            );

            RETURN
               success_Result(
                  p_code               => 'ITEM_RESULT_ALREADY_APPLIED',
                  p_info               => 'Item result already applied',
                  p_ret_code           => RET_ALREADY_APPLIED,
                  p_req_id             => l_req_id,
                  p_inf_id             => l_inf_id,
                  p_itm_id             => l_itm_id,
                  p_status_cd          => l_status_cd,
                  p_idempotent         => TRUE,
                  p_request_completed  => l_request_completed
               );
         END IF;


         l_log.warn(
            p_message_text => 'Item result conflicts with another message',
            p_action_code  => 'message_conflict',
            p_details_text =>
               TO_CLOB(
                     'current_message_uuid='
                  || TRIM(l_current_message)
                  || ', new_message_uuid='
                  || TRIM(p_message_uuid)
               )
         );

         RETURN
            failure_Result(
               p_code      => 'ITEM_RESULT_OTHER_MESSAGE_APPLIED',
               p_info      => 'Item result already applied by another message',
               p_ret_code  => RET_OTHER_APPLIED,
               p_req_id    => l_req_id,
               p_inf_id    => l_inf_id,
               p_itm_id    => l_itm_id,
               p_status_cd => l_status_cd,
               p_details   =>
                  TO_CLOB(
                        'current_message_uuid='
                     || TRIM(l_current_message)
                     || ', new_message_uuid='
                     || TRIM(p_message_uuid)
                  )
            );
      END IF;


      IF l_status_cd = MI_Request_Api.STATUS_DONE THEN
         rollback_Own_Work;

         RETURN
            failure_Result(
               p_code      => 'ITEM_RESULT_INCONSISTENT_REQUEST',
               p_info      => 'Request is DONE but item has no applied message',
               p_req_id    => l_req_id,
               p_inf_id    => l_inf_id,
               p_itm_id    => l_itm_id,
               p_status_cd => l_status_cd
            );
      END IF;


      ------------------------------------------------------------------------
      -- Business mapping is part of the same atomic operation.
      ------------------------------------------------------------------------
      IF p_response_kind = RESPONSE_OK THEN
         l_sql :=
               'BEGIN '
            || l_payload_mapper
            || '('
            || '   p_itm_id       => :itm_id,'
            || '   p_payload_text => :payload_text,'
            || '   p_payload_type => :payload_type,'
            || '   p_ires_code    => :ires_code,'
            || '   p_cres_info    => :cres_info'
            || '); END;';

         BEGIN
            EXECUTE IMMEDIATE l_sql
               USING IN  l_itm_id,
                     IN  p_payload_text,
                     IN  l_payload_type,
                     OUT l_ires_code,
                     OUT l_cres_info;

         EXCEPTION
            WHEN OTHERS THEN
               l_sqlcode := SQLCODE;
               l_sqlerrm := SQLERRM;

               rollback_Own_Work;

               l_log.error(
                  p_message_text => 'Item payload mapping failed',
                  p_action_code  => 'map_payload',
                  p_details_text => TO_CLOB(l_sqlerrm)
               );

               l_result :=
                  MI_ResultCtx.from_Exception(
                     p_sqlcode => l_sqlcode,
                     p_sqlerrm => l_sqlerrm,
                     p_code    => 'ITEM_RESULT_MAPPING_FAILED',
                     p_info    => 'Successful payload business mapping failed'
                  );

               add_Context(l_result);
               RETURN l_result;
         END;


         IF l_ires_code IS NULL THEN
            rollback_Own_Work;

            RETURN
               failure_Result(
                  p_code      => 'ITEM_RESULT_MAPPING_INCOMPLETE',
                  p_info      => 'Payload mapper returned NULL ires_code',
                  p_req_id    => l_req_id,
                  p_inf_id    => l_inf_id,
                  p_itm_id    => l_itm_id,
                  p_status_cd => l_status_cd
               );
         END IF;

         l_error_code := NULL;

      ELSE
         l_ires_code := RESPONSE_FAIL;
         l_error_code := TRIM(p_response_code);

         IF TRIM(p_response_info) IS NOT NULL THEN
            l_cres_info := TO_CLOB(TRIM(p_response_info));

         ELSIF p_response_details IS NOT NULL
            AND DBMS_LOB.getlength(p_response_details) > 0
         THEN
            l_cres_info := p_response_details;

         ELSE
            l_cres_info := TO_CLOB(l_error_code);
         END IF;
      END IF;


      ------------------------------------------------------------------------
      -- Core alone owns common outcome fields.
      ------------------------------------------------------------------------
      l_sql :=
            'UPDATE '
         || l_item_table
         || '   SET IRES_CODE    = :ires_code,'
         || '       CRES_INFO    = :cres_info,'
         || '       TRES_TIME    = :response_time,'
         || '       MESSAGE_UUID = :message_uuid,'
         || '       ERROR_CODE   = :error_code'
         || ' WHERE ITM_ID = :itm_id'
         || '   AND MESSAGE_UUID IS NULL';

      EXECUTE IMMEDIATE l_sql
         USING l_ires_code,
               l_cres_info,
               p_response_time,
               TRIM(p_message_uuid),
               l_error_code,
               l_itm_id;

      l_row_count := SQL%ROWCOUNT;

      IF l_row_count <> 1 THEN
         rollback_Own_Work;

         RETURN
            failure_Result(
               p_code      => 'ITEM_RESULT_UPDATE_FAILED',
               p_info      =>
                  'Item outcome was not applied, row_count='
                  || l_row_count,
               p_req_id    => l_req_id,
               p_inf_id    => l_inf_id,
               p_itm_id    => l_itm_id,
               p_status_cd => l_status_cd
            );
      END IF;


      try_Complete_Request;


      l_log.info(
         p_message_text => 'Item result applied',
         p_action_code  => 'apply_result',
         p_details_text =>
            TO_CLOB(
                  'ires_code='
               || l_ires_code
               || ', request_completed='
               || MI_Utils.to_Char(l_request_completed)
            )
      );

      l_log.exit_f(
         p_function_name => 'apply_Item_Result',
         p_message_text  => 'Item result applied'
      );


      RETURN
         success_Result(
            p_code               => 'ITEM_RESULT_APPLIED',
            p_info               => 'Item result applied',
            p_ret_code           => RET_APPLIED,
            p_req_id             => l_req_id,
            p_inf_id             => l_inf_id,
            p_itm_id             => l_itm_id,
            p_status_cd          => l_status_cd,
            p_idempotent         => FALSE,
            p_request_completed  => l_request_completed
         );


   EXCEPTION
      WHEN OTHERS THEN
         l_sqlcode := SQLCODE;
         l_sqlerrm := SQLERRM;

         rollback_Own_Work;

         l_log.error(
            p_message_text => 'apply_Item_Result failed',
            p_action_code  => 'apply_result',
            p_details_text => TO_CLOB(l_sqlerrm)
         );

         l_result :=
            MI_ResultCtx.from_Exception(
               p_sqlcode => l_sqlcode,
               p_sqlerrm => l_sqlerrm,
               p_code    => 'ITEM_RESULT_APPLY_FAILED',
               p_info    => 'Не удалось применить результат item'
            );

         add_Context(l_result);
         RETURN l_result;
   END apply_Item_Result;

END MI_Item_Result_Api;
/
