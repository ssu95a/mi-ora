CREATE OR REPLACE PACKAGE MI_Request_Sup
IS

   VERSION CONSTANT VARCHAR2(100) :=
      '$Id: {1.0.1} {19.11.2026} Sulimoff$';


   RET_FAIL CONSTANT PLS_INTEGER := -1;
   RET_OK   CONSTANT PLS_INTEGER :=  0;


   FUNCTION get_Version
      RETURN VARCHAR2;


   /*
      Атомарно регистрирует входящий request и одну позицию в указанной
      MI_NNNN-таблице.

      Требования к item table:
         - таблица принадлежит текущей схеме;
         - имя имеет вид MI_NNNN;
         - присутствуют ITM_ID, REQ_ID, CREATED_AT, PAYLOAD, IRES_CODE;
         - PAYLOAD имеет тип CLOB.

      При p_send_response = 1 дополнительно создаёт response и переводит его
      в READY. 
      Oracle package намеренно не вызывает BUS: caller обязан сначала
      COMMIT созданных request/item/response, а затем публиковать READY response
      отдельной transport-операцией. 
      Row lock через BUS не удерживается.

      COMMIT/ROLLBACK не выполняет. При ошибке откатывает только собственную
      работу через DCL.SavePoint/RollBack.
   */
   PROCEDURE apply_Request (
      p_inf_id                IN  MI_REQ.INF_ID%TYPE,
      p_item_table            IN  VARCHAR2,
      p_message_uuid          IN  MI_REQ.MESSAGE_UUID%TYPE,
      p_original_request_uuid IN  MI_REQ.ORIGINAL_REQ_UUID%TYPE,
      p_correlation_id        IN  MI_REQ.CORRELATION_ID%TYPE,
      p_request_time          IN  TIMESTAMP WITH TIME ZONE,
      p_payload_text          IN  CLOB,

      p_req_id                OUT MI_REQ.REQ_ID%TYPE,
      p_itm_id                OUT MI_RSP.ITM_ID%TYPE,
      p_rsp_id                OUT MI_RSP.RSP_ID%TYPE,
      p_ret_code              OUT NUMBER,
      p_ret_info              OUT VARCHAR2,

      p_send_response         IN  NUMBER DEFAULT 0,
      p_response_payload      IN  MI_RSP.PAYLOAD%TYPE DEFAULT NULL
   );

END MI_Request_Sup;
/
CREATE OR REPLACE PACKAGE BODY MI_Request_Sup
IS

   cLogger CONSTANT VARCHAR2(64) := 'mi.request.sup';
   cErrorCode CONSTANT PLS_INTEGER := -20003;


   g_log CONSTANT MI_Logger_T :=
      MI_Logger_T(
         p_logger_name  => cLogger,
         p_package_name => $$PLSQL_UNIT
      );


   /* */
   FUNCTION get_Version
      RETURN VARCHAR2
   IS
   BEGIN
      RETURN VERSION;
   END get_Version;


   /* */
   FUNCTION normalize_Item_Table (
      p_item_table IN VARCHAR2
   )
      RETURN VARCHAR2
   IS
      l_table_name    VARCHAR2(128);
      l_table_count   PLS_INTEGER;
      l_column_count  PLS_INTEGER;
      l_payload_count PLS_INTEGER;
   BEGIN
      IF TRIM(p_item_table) IS NULL THEN
         RAISE_APPLICATION_ERROR(
            cErrorCode,
            'p_item_table must not be NULL or blank'
         );
      END IF;

      l_table_name :=
         UPPER(
            DBMS_ASSERT.SIMPLE_SQL_NAME(
               TRIM(p_item_table)
            )
         );

      IF NOT REGEXP_LIKE(l_table_name, '^MI_[[:digit:]]{4}$', 'c') THEN
         RAISE_APPLICATION_ERROR(
            cErrorCode,
            'p_item_table must have MI_NNNN form'
         );
      END IF;

      SELECT COUNT(*)
        INTO l_table_count
        FROM USER_TABLES
       WHERE TABLE_NAME = l_table_name;

      IF l_table_count <> 1 THEN
         RAISE_APPLICATION_ERROR(
            cErrorCode,
            'Item table does not exist in current schema: ' || l_table_name
         );
      END IF;

      SELECT COUNT(*),
             SUM(
                CASE
                   WHEN COLUMN_NAME = 'PAYLOAD' AND DATA_TYPE = 'CLOB' THEN 1
                   ELSE 0
                END
             )
        INTO l_column_count,
             l_payload_count
        FROM USER_TAB_COLUMNS
       WHERE TABLE_NAME = l_table_name
         AND COLUMN_NAME IN (
                'ITM_ID',
                'REQ_ID',
                'CREATED_AT',
                'PAYLOAD',
                'IRES_CODE'
             );

      IF l_column_count <> 5 OR NVL(l_payload_count, 0) <> 1 THEN
         RAISE_APPLICATION_ERROR(
            cErrorCode,
               'Item table has incompatible columns: '
            || l_table_name
            || '; required ITM_ID, REQ_ID, CREATED_AT, PAYLOAD CLOB, IRES_CODE'
         );
      END IF;

      RETURN l_table_name;
   END normalize_Item_Table;


   /* */
   PROCEDURE apply_Request (
      p_inf_id                IN  MI_REQ.INF_ID%TYPE,
      p_item_table            IN  VARCHAR2,
      p_message_uuid          IN  MI_REQ.MESSAGE_UUID%TYPE,
      p_original_request_uuid IN  MI_REQ.ORIGINAL_REQ_UUID%TYPE,
      p_correlation_id        IN  MI_REQ.CORRELATION_ID%TYPE,
      p_request_time          IN  TIMESTAMP WITH TIME ZONE,
      p_payload_text          IN  CLOB,

      p_req_id                OUT MI_REQ.REQ_ID%TYPE,
      p_itm_id                OUT MI_RSP.ITM_ID%TYPE,
      p_rsp_id                OUT MI_RSP.RSP_ID%TYPE,
      p_ret_code              OUT NUMBER,
      p_ret_info              OUT VARCHAR2,

      p_send_response         IN  NUMBER DEFAULT 0,
      p_response_payload      IN  MI_RSP.PAYLOAD%TYPE DEFAULT NULL
   )
   IS
      e_Apply_Failed EXCEPTION;

      l_item_table       VARCHAR2(128);
      l_prepare_response NUMBER;
      l_failure_info     VARCHAR2(2000);
      l_savepoint_name   DCL.T_Name;

      l_request_result   MI_ResultCtx.exec_Result_t;
      l_response_result  MI_ResultCtx.exec_Result_t;
      l_ready_result     MI_ResultCtx.exec_Result_t;
      l_response_payload MI_RSP.PAYLOAD%TYPE;

      l_sqlcode          PLS_INTEGER;
      l_sqlerrm          VARCHAR2(2000);

      l_log              MI_Logger_T := g_log;


      PROCEDURE fail_Apply (
         p_info IN VARCHAR2
      )
      IS
      BEGIN
         l_failure_info := SUBSTR(p_info, 1, 2000);
         RAISE e_Apply_Failed;
      END fail_Apply;


      PROCEDURE verify_Result (
         p_result     IN MI_ResultCtx.exec_Result_t,
         p_operation  IN VARCHAR2
      )
      IS
      BEGIN
         IF MI_ResultCtx.is_Failed(p_result) THEN
            fail_Apply(
                  p_operation
               || ' failed: '
               || NVL(p_result.result_code, '<NO_RESULT_CODE>')
               || ': '
               || NVL(p_result.result_info, '<NO_RESULT_INFO>')
            );
         END IF;
      END verify_Result;


      PROCEDURE return_Failure (
         p_info IN VARCHAR2
      )
      IS
      BEGIN
         p_req_id   := NULL;
         p_itm_id   := NULL;
         p_rsp_id   := NULL;
         p_ret_code := RET_FAIL;
         p_ret_info := SUBSTR(p_info, 1, 4000);

         l_log.error(
            p_message_text => 'Request registration failed',
            p_action_code  => 'apply_request',
            p_details_text => TO_CLOB(p_ret_info)
         );

         l_log.exit_f(
            p_function_name => 'apply_Request',
            p_message_text  =>
                  'ret_code='
               || TO_CHAR(p_ret_code, 'TM9')
               || '; info='
               || p_ret_info
         );
      END return_Failure;

   BEGIN
      p_req_id   := NULL;
      p_itm_id   := NULL;
      p_rsp_id   := NULL;
      p_ret_code := RET_FAIL;
      p_ret_info := NULL;

      l_prepare_response := NVL(p_send_response, 0);

      l_log.context(
         p_inf_id         => p_inf_id,
         p_correlation_id => p_correlation_id
      );
      l_log.enter_f(
         p_function_name => 'apply_Request',
         p_message_text  =>
               'inf_id='
            || NVL(TO_CHAR(p_inf_id, 'TM9'), '<NULL>')
            || '; item_table='
            || NVL(SUBSTR(TRIM(p_item_table), 1, 128), '<NULL>')
            || '; prepare_response='
            || TO_CHAR(l_prepare_response, 'TM9')
            || '; request_time='
            || CASE
                  WHEN p_request_time IS NULL THEN '<NULL>'
                  ELSE TO_CHAR(
                          p_request_time,
                          'YYYY-MM-DD"T"HH24:MI:SS.FF3TZH:TZM'
                       )
               END
      );

      IF p_inf_id IS NULL THEN
         fail_Apply('p_inf_id must not be NULL');
      END IF;

      IF TRIM(p_item_table) IS NULL THEN
         fail_Apply('p_item_table must not be NULL or blank');
      END IF;

      IF TRIM(p_message_uuid) IS NULL THEN
         fail_Apply('p_message_uuid must not be NULL');
      END IF;

      IF TRIM(p_original_request_uuid) IS NULL THEN
         fail_Apply('p_original_request_uuid must not be NULL');
      END IF;

      IF TRIM(p_correlation_id) IS NULL THEN
         fail_Apply('p_correlation_id must not be NULL');
      END IF;

      IF p_request_time IS NULL THEN
         fail_Apply('p_request_time must not be NULL');
      END IF;

      IF p_payload_text IS NULL
         OR DBMS_LOB.getlength(p_payload_text) = 0
         OR REGEXP_LIKE(
               DBMS_LOB.SUBSTR(p_payload_text, 4000, 1),
               '^[[:space:]]*$'
            )
      THEN
         fail_Apply('p_payload_text must not be NULL or blank');
      END IF;

      IF l_prepare_response NOT IN (0, 1) THEN
         fail_Apply('p_send_response must be 0 or 1');
      END IF;

      BEGIN
         l_item_table := normalize_Item_Table(p_item_table);
      EXCEPTION
         WHEN OTHERS THEN
            fail_Apply(SQLERRM);
      END;

      DCL.SavePoint(l_savepoint_name);

      IF l_savepoint_name IS NULL THEN
         fail_Apply('DCL did not create the apply_Request savepoint');
      END IF;

      l_request_result :=
         MI_Request_Api.create_Request(
            p_inf_id                => p_inf_id,
            p_correlation_id        => p_correlation_id,
            p_original_req_uuid     => p_original_request_uuid,
            p_message_uuid          => p_message_uuid,
            p_status_cd             => MI_Request_Api.STATUS_DONE
         );

      verify_Result(
         p_result    => l_request_result,
         p_operation => 'MI_Request_Api.create_Request'
      );

      p_req_id :=
         MI_ResultCtx.result_Number(
            p_result => l_request_result,
            p_name   => 'req_id'
         );

      IF p_req_id IS NULL THEN
         fail_Apply('MI_Request_Api.create_Request returned NULL req_id');
      END IF;

      p_itm_id := S_MI_ITM.NEXTVAL;

      EXECUTE IMMEDIATE
            'INSERT INTO '
         || l_item_table
         || ' (ITM_ID, REQ_ID, CREATED_AT, PAYLOAD, IRES_CODE) '
         || 'VALUES (:1, :2, SYSTIMESTAMP, :3, 0)'
         USING p_itm_id,
               p_req_id,
               p_payload_text;

      IF l_prepare_response = 1 THEN
         l_response_payload := p_response_payload;

         IF l_response_payload IS NULL THEN
            l_response_payload :=
               TO_CLOB(
                     '{"processed_at":"'
                  || TO_CHAR(
                        SYSTIMESTAMP,
                        'YYYY-MM-DD"T"HH24:MI:SS.FF3TZH:TZM'
                     )
                  || '"}'
               );
         END IF;

         l_response_result :=
            MI_Response_Api.create_Response(
               p_req_id      => p_req_id,
               p_itm_id      => p_itm_id,
               p_category_cd => 'SUCCESS',
               p_result_code => 'OK',
               p_result_info => 'Запрос зарегистрирован',
               p_payload     => l_response_payload
            );

         verify_Result(
            p_result    => l_response_result,
            p_operation => 'MI_Response_Api.create_Response'
         );

         p_rsp_id :=
            MI_ResultCtx.result_Number(
               p_result => l_response_result,
               p_name   => 'rsp_id'
            );

         IF p_rsp_id IS NULL THEN
            fail_Apply('MI_Response_Api.create_Response returned NULL rsp_id');
         END IF;

         l_ready_result := MI_Response_Api.to_Ready(p_rsp_id);

         verify_Result(
            p_result    => l_ready_result,
            p_operation => 'MI_Response_Api.to_Ready'
         );
      END IF;

      l_savepoint_name := NULL;
      p_ret_code := RET_OK;
      p_ret_info :=
            'registered; req_id='
         || TO_CHAR(p_req_id, 'TM9')
         || '; itm_id='
         || TO_CHAR(p_itm_id, 'TM9')
         || CASE
               WHEN p_rsp_id IS NOT NULL
               THEN
                     '; rsp_id='
                  || TO_CHAR(p_rsp_id, 'TM9')
                  || '; response=READY; publish after caller COMMIT'
               ELSE NULL
            END;

      l_log.context(
         p_inf_id         => p_inf_id,
         p_req_id         => p_req_id,
         p_itm_id         => p_itm_id,
         p_rsp_id         => p_rsp_id,
         p_correlation_id => p_correlation_id
      );
      l_log.info(
         p_message_text => 'Request registered',
         p_action_code  => 'apply_request'
      );
      l_log.exit_f(
         p_function_name => 'apply_Request',
         p_message_text  =>
               'ret_code='
            || TO_CHAR(p_ret_code, 'TM9')
            || '; info='
            || p_ret_info
      );

   EXCEPTION
      WHEN e_Apply_Failed THEN
         IF NOT MI_Transaction.rollback_Savepoint(
                   p_name => l_savepoint_name,
                   p_log  => l_log
                )
         THEN
            l_log.error(
               p_message_text => 'Request registration rollback failed',
               p_action_code  => 'rollback',
               p_details_text => TO_CLOB(l_failure_info)
            );
            RAISE_APPLICATION_ERROR(
               cErrorCode,
               'MI_Request_Sup rollback failed; caller ROLLBACK is required'
            );
         END IF;

         return_Failure(l_failure_info);

      WHEN OTHERS THEN
         l_sqlcode := SQLCODE;
         l_sqlerrm := SQLERRM;

         IF NOT MI_Transaction.rollback_Savepoint(
                   p_name => l_savepoint_name,
                   p_log  => l_log
                )
         THEN
            l_log.error(
               p_message_text => 'Request registration rollback failed',
               p_action_code  => 'rollback',
               p_details_text =>
                  TO_CLOB(
                        'cause_code='
                     || TO_CHAR(l_sqlcode, 'TM9')
                     || '; cause_info='
                     || l_sqlerrm
                  )
            );
            RAISE_APPLICATION_ERROR(
               cErrorCode,
               'MI_Request_Sup rollback failed; caller ROLLBACK is required'
            );
         END IF;

         return_Failure(
               'MI_REQUEST_SUP_APPLY_FAILED: '
            || TO_CHAR(l_sqlcode, 'TM9')
            || ': '
            || l_sqlerrm
         );
   END apply_Request;

END MI_Request_Sup;
/
