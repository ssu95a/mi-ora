CREATE OR REPLACE PACKAGE MI_0600_Api
IS

   /* MI-edo. Пакет бизнес-логики для 404 файлов */

   VERSION CONSTANT VARCHAR2(100) := '$Id: {1.1.1} {18.11.2026} Sulimoff$';


   RET_FAIL     CONSTANT NUMBER := -1;
   RET_OK       CONSTANT NUMBER :=  0;
   RET_NO_DATA  CONSTANT NUMBER :=  1;
   RET_EXISTS   CONSTANT NUMBER :=  4;

   ERR_DUPLICATE_ARCHIVE CONSTANT PLS_INTEGER := -20022;

   /* Версия*/
   FUNCTION get_Version
      RETURN VARCHAR2;


   /*
      Атомарно создаёт MI_REQ, один MI_0600 item и список имён файлов.

      CZIP_NAME идентифицирует финальный архив. Повторный архив отклоняется
      исключением ORA-20022 / MI_0600_DUPLICATE_ARCHIVE. Существующие request,
      item, BLOB и список файлов не изменяются.

      Для ответчиков 602/604/612 дополнительно распознаётся повтор по
      ORIGINAL_REQ_UUID внутри того же INF_ID.

      Package не выполняет COMMIT. 
      При ошибке откатывает только собственную работу через DCL.SavePoint/RollBack.
   */
   PROCEDURE create_Request (
      p_inf_id                IN MI_REQ.INF_ID%TYPE,
      
      p_czip_name             IN MI_0600.CZIP_NAME%TYPE,
      p_bzip_data             IN MI_0600.BZIP_DATA%TYPE,
      p_izip_size             IN MI_0600.IZIP_SIZE%TYPE,
      p_izip_files_count      IN MI_0600.IZIP_FILES_COUNT%TYPE,
      p_file_names            IN SYS.ODCIVARCHAR2LIST,

      p_req_id                OUT MI_REQ.REQ_ID%TYPE,
      p_itm_id                OUT MI_0600.ITM_ID%TYPE,
      p_ret_code              OUT NUMBER,
      p_ret_info              OUT VARCHAR2,

      p_original_req_uuid     IN MI_REQ.ORIGINAL_REQ_UUID%TYPE,
      p_message_uuid          IN MI_REQ.MESSAGE_UUID%TYPE,
      p_ctaxreq_id            IN MI_REQ.CTAXREQ_ID%TYPE,
      p_icreate_type          IN MI_0600.ICREATE_TYPE%TYPE
   );


   /*
      Временный Oracle transport stub для существующего Java scheduler ABI.

      До согласования Multi-Bus API отправка не выполняется. Процедура не
      изменяет MI_REQ, не захватывает request и не выполняет COMMIT.
   */
   PROCEDURE send_Pending (
      p_ret_code  OUT NUMBER,
      p_ret_info  OUT VARCHAR2
   );


   /*
      Manual v1: фиксирует один явно заданный NEW/601 и его Multi-Bus маршрут.
      Package не выполняет COMMIT; caller обязан COMMIT до dispatch.
   */
   PROCEDURE claim_Manual_601 (
      p_req_id              IN  MI_REQ.REQ_ID%TYPE,
      p_call_uuid           OUT VARCHAR2,
      p_bus_correlation_id  OUT VARCHAR2,
      p_ret_code            OUT NUMBER,
      p_ret_info            OUT VARCHAR2
   );


   /*
      Выполняет одноразовую отправку уже committed claim. Открытая локальная
      транзакция отклоняется до transport. Результат S/U/N коммитит caller.
   */
   PROCEDURE dispatch_Claimed_601 (
      p_req_id    IN  MI_REQ.REQ_ID%TYPE,
      p_call_uuid IN  VARCHAR2,
      p_ret_code  OUT NUMBER,
      p_ret_info  OUT VARCHAR2
   );


   /*
      Receive-only reconciliation по сохранённой очереди/CBS correlation.
      Никогда не выполняет enqueue. Результат коммитит caller.
   */
   PROCEDURE reconcile_Manual_601 (
      p_req_id    IN  MI_REQ.REQ_ID%TYPE,
      p_ret_code  OUT NUMBER,
      p_ret_info  OUT VARCHAR2
   );


   /*
      Дата последней постановки архива в очередь по имени файла внутри ZIP.
   */
   FUNCTION get_Fns_File_Inqueue_Date (
      p_file_name IN MI_0600_F.CZIP_FILE_NAME%TYPE
   )
      RETURN DATE;


   /*
      Business wrapper общего item-result contract.
   */
   PROCEDURE apply_Item_Result (
      p_request_uuid      IN MI_REQ.EXTERNAL_UUID%TYPE,
      p_message_uuid      IN MI_REQ.MESSAGE_UUID%TYPE,
      p_item_uuid         IN MI_0600.EXTERNAL_UUID%TYPE,

      p_response_kind     IN NUMBER,

      p_response_code     IN MI_REQ.RESULT_CODE%TYPE,
      p_response_info     IN MI_REQ.RESULT_INFO%TYPE,
      p_response_details  IN CLOB,
      p_response_time     IN TIMESTAMP WITH TIME ZONE,

      p_payload_text      IN CLOB,
      p_payload_type      IN VARCHAR2,

      p_ret_code          OUT NUMBER,
      p_ret_info          OUT VARCHAR2
   );


   /*
      Mapper signature is fixed by MI_Item_Result_Api.
      Mapper owns only interpretation of the business payload; common item
      outcome fields are written by MI_Item_Result_Api.
   */
   PROCEDURE map_Item_Result (
      p_itm_id        IN  NUMBER,
      p_payload_text  IN  CLOB,
      p_payload_type  IN  VARCHAR2,
      p_ires_code     OUT NUMBER,
      p_cres_info     OUT CLOB
   );


   /* Called from the MI_REQ SENT transition trigger. */
   PROCEDURE on_Request_Sent (
      p_req_id IN MI_REQ.REQ_ID%TYPE
   );

END MI_0600_Api;
/
CREATE OR REPLACE PACKAGE BODY MI_0600_Api
IS

   /* logger Id */
   cLogger CONSTANT VARCHAR2(64) := 'mi.0600';


   /* */
   g_log CONSTANT MI_Logger_T := MI_Logger_T( p_logger_name  => cLogger, p_package_name => $$PLSQL_UNIT );

   
   /* */
   e_Duplicate_Archive EXCEPTION;
   PRAGMA EXCEPTION_INIT(e_Duplicate_Archive, -20022);

   /*
      One-shot dispatch capability. Raw token never leaves package state and
      is never persisted; only SHA-256 is stored in MI_0600_SEND_ATTEMPT.
   */
   g_dispatch_req_id     MI_REQ.REQ_ID%TYPE;
   g_dispatch_call_uuid  VARCHAR2(36);
   g_dispatch_token      VARCHAR2(64);


   PROCEDURE clear_Dispatch_Capability
   IS
   BEGIN
      g_dispatch_req_id := NULL;
      g_dispatch_call_uuid := NULL;
      g_dispatch_token := NULL;
   END clear_Dispatch_Capability;


   /* */
   FUNCTION get_Version
      RETURN VARCHAR2
   IS
   BEGIN
      RETURN VERSION;
   END get_Version;


   /* Список поддерживаемых ВС */
   FUNCTION is_Supported_Inf (
      p_inf_id IN MI_REQ.INF_ID%TYPE
   )
      RETURN BOOLEAN
   IS
   BEGIN
      RETURN p_inf_id IN (601, 602, 603, 604, 611, 612);
   END is_Supported_Inf;


   /* Признак является ли ВС ответчиком */
   FUNCTION is_Responder_Inf (
      p_inf_id IN MI_REQ.INF_ID%TYPE
   )
      RETURN BOOLEAN
   IS
   BEGIN
      RETURN p_inf_id IN (602, 604, 612);
   END is_Responder_Inf;


   /* Готовит объект с успешным результатом работы */
   FUNCTION success_Result (
      p_code             IN VARCHAR2,
      p_info             IN VARCHAR2,
      p_ret_code         IN PLS_INTEGER,

      p_req_id           IN MI_REQ.REQ_ID%TYPE          DEFAULT NULL,
      p_itm_id           IN MI_0600.ITM_ID%TYPE         DEFAULT NULL,
      p_request_uuid     IN MI_REQ.EXTERNAL_UUID%TYPE   DEFAULT NULL,
      p_item_uuid        IN MI_0600.EXTERNAL_UUID%TYPE  DEFAULT NULL,

      p_idempotent       IN BOOLEAN                     DEFAULT NULL,
      p_archive_updated  IN BOOLEAN                     DEFAULT NULL
   )
      RETURN MI_ResultCtx.exec_Result_t
   IS
      l_result MI_ResultCtx.exec_Result_t;
   BEGIN
      l_result := MI_ResultCtx.success( p_code => p_code, p_info => p_info );

      l_result.parameters('ret_code') := TO_CHAR(p_ret_code);

      IF p_req_id IS NOT NULL THEN
         l_result.parameters('req_id') := TO_CHAR(p_req_id);
      END IF;

      IF p_itm_id IS NOT NULL THEN
         l_result.parameters('itm_id') := TO_CHAR(p_itm_id);
      END IF;

      IF p_request_uuid IS NOT NULL THEN
         l_result.parameters('request_uuid') := TRIM(p_request_uuid);
      END IF;

      IF p_item_uuid IS NOT NULL THEN
         l_result.parameters('item_uuid') := TRIM(p_item_uuid);
      END IF;

      IF p_idempotent IS NOT NULL THEN
         l_result.parameters('idempotent') := MI_Utils.to_Char(p_idempotent);
      END IF;

      IF p_archive_updated IS NOT NULL THEN
         l_result.parameters('archive_updated') := MI_Utils.to_Char(p_archive_updated);
      END IF;

      RETURN l_result;
      
   END success_Result;


    /* Готовит объект с результатом работы при ошибке*/
   FUNCTION failure_Result (
      p_code      IN VARCHAR2,
      p_info      IN VARCHAR2,
      p_details   IN CLOB                 DEFAULT NULL,
      p_req_id    IN MI_REQ.REQ_ID%TYPE   DEFAULT NULL,
      p_itm_id    IN MI_0600.ITM_ID%TYPE  DEFAULT NULL
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

      l_result.parameters('ret_code') := TO_CHAR(RET_FAIL);

      IF p_req_id IS NOT NULL THEN
         l_result.parameters('req_id') := TO_CHAR(p_req_id);
      END IF;

      IF p_itm_id IS NOT NULL THEN
         l_result.parameters('itm_id') := TO_CHAR(p_itm_id);
      END IF;

      RETURN l_result;
      
   END failure_Result;


   /* */
   FUNCTION result_Number (
      p_result  IN MI_ResultCtx.exec_Result_t,
      p_name    IN VARCHAR2
   )
      RETURN NUMBER
   IS
   BEGIN
      RETURN TO_NUMBER(p_result.parameters(p_name));
   EXCEPTION
      WHEN NO_DATA_FOUND OR VALUE_ERROR THEN
         RETURN NULL;
   END result_Number;


   /* */
   FUNCTION result_Text (
      p_result  IN MI_ResultCtx.exec_Result_t,
      p_name    IN VARCHAR2
   )
      RETURN VARCHAR2
   IS
   BEGIN
      RETURN SUBSTR(p_result.parameters(p_name), 1, 2000);
   EXCEPTION
      WHEN NO_DATA_FOUND THEN
         RETURN NULL;
   END result_Text;


   /* */
   PROCEDURE export_Result (
      p_result    IN  MI_ResultCtx.exec_Result_t,
      p_ret_code  OUT NUMBER,
      p_ret_info  OUT VARCHAR2
   )
   IS
   BEGIN
   
      p_ret_code := result_Number(p_result, 'ret_code');

      IF p_ret_code IS NULL THEN
         IF MI_ResultCtx.is_Success(p_result) THEN
            p_ret_code := RET_OK;
         ELSE
            p_ret_code := RET_FAIL;
         END IF;
      END IF;

      p_ret_info := SUBSTR( NVL(p_result.result_code, '<NO_RESULT_CODE>') || ': ' || NVL(p_result.result_info, '<NO_RESULT_INFO>') 
                            || CASE WHEN p_result.cause_code IS NOT NULL OR p_result.cause_info IS NOT NULL THEN '; cause='
                            || NVL( p_result.cause_code, '<NO_CAUSE_CODE>' )
                            || ': '
                            || NVL( p_result.cause_info, '<NO_CAUSE_INFO>')
                            ELSE NULL
                        END, 1, 4000 );

   END export_Result;


   /* Сохраняет имена файлов нового запроса */
   PROCEDURE insert_File_Names (
      p_itm_id      IN MI_0600.ITM_ID%TYPE,
      p_file_names  IN SYS.ODCIVARCHAR2LIST
   )
   IS
      l_index      PLS_INTEGER;
      l_file_name  MI_0600_F.CZIP_FILE_NAME%TYPE;
   BEGIN
   
      IF p_file_names.COUNT = 0 THEN
         RETURN;
      END IF;

      l_index := p_file_names.FIRST;

      WHILE l_index IS NOT NULL LOOP
   
         l_file_name := TRIM(p_file_names(l_index));

         IF l_file_name IS NOT NULL THEN

            BEGIN
            
               INSERT INTO MI_0600_F 
                  ( ITM_ID, CZIP_FILE_NAME )
               VALUES 
                  ( p_itm_id, l_file_name );

            EXCEPTION
               /* Повторяющиеся имена в одном списке не дублируют ссылку. */
               WHEN DUP_VAL_ON_INDEX THEN
                  NULL;
            END;
            
         END IF;

         l_index := p_file_names.NEXT(l_index);
         
      END LOOP;

   EXCEPTION
      /* Пропущенная коллекция SQL атомарно равна NULL */
      WHEN COLLECTION_IS_NULL THEN
           NULL;
   END insert_File_Names;


   /* Проверяет нарушение уникальности финального архива */
   FUNCTION archive_Exists (
      p_czip_name IN MI_0600.CZIP_NAME%TYPE
   )
      RETURN BOOLEAN
   IS
      l_exists PLS_INTEGER;
   BEGIN
   
      SELECT 1
        INTO l_exists
        FROM MI_0600
       WHERE CZIP_NAME = p_czip_name;

      RETURN TRUE;

   EXCEPTION
      WHEN NO_DATA_FOUND THEN
         RETURN FALSE;
   END archive_Exists;


   /* Бросает сильную ошибку без изменения существующего архива */
   PROCEDURE raise_Duplicate_Archive (
      p_czip_name IN MI_0600.CZIP_NAME%TYPE
   )
   IS
   BEGIN
      RAISE_APPLICATION_ERROR( ERR_DUPLICATE_ARCHIVE, 'MI_0600_DUPLICATE_ARCHIVE: archive already registered: ' || p_czip_name );
   END raise_Duplicate_Archive;


   /* Логика создания запроса из списка файлов */
   FUNCTION create_Request_Impl (
      p_inf_id                IN MI_REQ.INF_ID%TYPE,
      
      p_czip_name             IN MI_0600.CZIP_NAME%TYPE,
      p_bzip_data             IN MI_0600.BZIP_DATA%TYPE,
      p_izip_size             IN MI_0600.IZIP_SIZE%TYPE        DEFAULT NULL,
      p_izip_files_count      IN MI_0600.IZIP_FILES_COUNT%TYPE DEFAULT NULL,
      p_file_names            IN SYS.ODCIVARCHAR2LIST          DEFAULT NULL,

      p_original_req_uuid     IN MI_REQ.ORIGINAL_REQ_UUID%TYPE DEFAULT NULL,
      p_message_uuid          IN MI_REQ.MESSAGE_UUID%TYPE      DEFAULT NULL,
      p_ctaxreq_id            IN MI_REQ.CTAXREQ_ID%TYPE        DEFAULT NULL,
      p_icreate_type          IN MI_0600.ICREATE_TYPE%TYPE     DEFAULT 0
   )
      RETURN MI_ResultCtx.exec_Result_t
   IS
      l_czip_name          MI_0600.CZIP_NAME%TYPE;
      l_zip_size           MI_0600.IZIP_SIZE%TYPE;
      l_zip_files_count    MI_0600.IZIP_FILES_COUNT%TYPE;

      l_req_id             MI_REQ.REQ_ID%TYPE;
      l_itm_id             MI_0600.ITM_ID%TYPE;
      l_request_uuid       MI_REQ.EXTERNAL_UUID%TYPE;
      l_item_uuid          MI_0600.EXTERNAL_UUID%TYPE;
      l_correlation_id     MI_REQ.CORRELATION_ID%TYPE;
      l_status_cd          MI_REQ.STATUS_CD%TYPE;

      l_request_result     MI_ResultCtx.exec_Result_t;
      l_result             MI_ResultCtx.exec_Result_t;

      l_savepoint_name     DCL.T_Name;
      l_sqlcode            PLS_INTEGER;
      l_sqlerrm            VARCHAR2(2000);

      l_log                MI_Logger_T := g_log;

      /* */
      PROCEDURE rollback_Own_Work
      IS
         l_name         DCL.T_Name;
         l_rolled_back  BOOLEAN;
      BEGIN
         
         IF l_savepoint_name IS NOT NULL THEN
         
            l_name           := l_savepoint_name;
            l_savepoint_name := NULL;

            l_rolled_back    := DCL.RollBack(l_name);

            IF NOT l_rolled_back THEN
            
               l_log.warn (
                  p_message_text => 'DCL rollback was not performed',
                  p_action_code  => 'rollback_skipped'
               );
               
            END IF;
            
         END IF;
         
      END rollback_Own_Work;


      /* */
      FUNCTION find_Responder_Duplicate
         RETURN BOOLEAN
      IS
      BEGIN
         IF p_original_req_uuid IS NULL THEN
            RETURN FALSE;
         END IF;

         BEGIN
            SELECT REQ_ID,
                   EXTERNAL_UUID,
                   CORRELATION_ID,
                   STATUS_CD
              INTO l_req_id,
                   l_request_uuid,
                   l_correlation_id,
                   l_status_cd
              FROM (
                 SELECT REQ_ID,
                        EXTERNAL_UUID,
                        CORRELATION_ID,
                        STATUS_CD
                   FROM MI_REQ
                  WHERE INF_ID = p_inf_id
                    AND ORIGINAL_REQ_UUID = TRIM(p_original_req_uuid)
                  ORDER BY REQ_ID
              )
             WHERE ROWNUM = 1;

         EXCEPTION
            WHEN NO_DATA_FOUND THEN
               RETURN FALSE;
         END;

         BEGIN
            SELECT ITM_ID,
                   EXTERNAL_UUID
              INTO l_itm_id,
                   l_item_uuid
              FROM MI_0600
             WHERE REQ_ID = l_req_id;

         EXCEPTION
            WHEN NO_DATA_FOUND THEN
               l_itm_id    := NULL;
               l_item_uuid := NULL;
         END;

         l_log.context (
            p_inf_id         => p_inf_id,
            p_req_id         => l_req_id,
            p_itm_id         => l_itm_id,
            p_correlation_id => l_correlation_id
         );

         l_log.info(
            p_message_text => 'Responder request already exists',
            p_action_code  => 'duplicate_original_request'
         );

         l_result :=
            success_Result(
               p_code         => 'MI_0600_REQUEST_EXISTS',
               p_info         => 'Request for original request UUID already exists',
               p_ret_code     => RET_EXISTS,
               p_req_id       => l_req_id,
               p_itm_id       => l_itm_id,
               p_request_uuid => l_request_uuid,
               p_item_uuid    => l_item_uuid,
               p_idempotent   => TRUE
            );

         l_result.parameters('status_cd') := TO_CHAR(l_status_cd);

         RETURN TRUE;

      END find_Responder_Duplicate;


   BEGIN
   
      l_log.context(p_inf_id => p_inf_id);

      l_log.enter_f( p_function_name => 'create_Request', p_message_text  => 'inf_id=' || p_inf_id || ', zip=' || l_czip_name );

      l_czip_name := TRIM(p_czip_name);

      IF p_inf_id IS NULL OR NOT is_Supported_Inf(p_inf_id) THEN
         RETURN failure_Result( 
            p_code => 'MI_0600_INVALID_INF_ID', 
            p_info =>'Unsupported inf_id=' || NVL(TO_CHAR(p_inf_id), '<NULL>') || '; expected 601, 602, 603, 604, 611 or 612' 
         );
      END IF;

      IF l_czip_name IS NULL THEN
         RETURN
            failure_Result (
               p_code => 'MI_0600_INVALID_ZIP_NAME',
               p_info => 'p_czip_name must not be NULL or blank'
            );
      END IF;

      IF p_bzip_data IS NULL THEN
         RETURN
            failure_Result(
               p_code => 'MI_0600_ZIP_REQUIRED',
               p_info => 'p_bzip_data must not be NULL'
            );
      END IF;

      IF p_original_req_uuid IS NOT NULL AND NOT MI_Utils.is_Uuid(p_original_req_uuid)
      THEN
         RETURN
            failure_Result(
               p_code => 'MI_0600_INVALID_ORIGINAL_UUID',
               p_info => 'p_original_req_uuid must be a valid UUID'
            );
      END IF;

      IF p_message_uuid IS NOT NULL AND NOT MI_Utils.is_Uuid(p_message_uuid)
      THEN
         RETURN
            failure_Result(
               p_code => 'MI_0600_INVALID_MESSAGE_UUID',
               p_info => 'p_message_uuid must be a valid UUID'
            );
      END IF;

      IF p_icreate_type IS NULL OR p_icreate_type NOT IN (0, 1) THEN
         RETURN
            failure_Result(
               p_code => 'MI_0600_INVALID_CREATE_TYPE',
               p_info => 'p_icreate_type must be 0 or 1'
            );
      END IF;

      IF p_izip_size < 0 THEN
         RETURN
            failure_Result(
               p_code => 'MI_0600_INVALID_ZIP_SIZE',
               p_info => 'p_izip_size must not be negative'
            );
      END IF;

      IF p_izip_files_count < 0 THEN
         RETURN
            failure_Result(
               p_code => 'MI_0600_INVALID_FILES_COUNT',
               p_info => 'p_izip_files_count must not be negative'
            );
      END IF;

      l_zip_size := p_izip_size;

      IF l_zip_size IS NULL AND p_bzip_data IS NOT NULL THEN
         l_zip_size := DBMS_LOB.getlength(p_bzip_data);
      END IF;

      l_zip_files_count := p_izip_files_count;

      IF l_zip_files_count IS NULL THEN
         BEGIN
            l_zip_files_count := p_file_names.COUNT;
         EXCEPTION
            WHEN COLLECTION_IS_NULL THEN
               NULL;
         END;
      END IF;


      DCL.SavePoint( l_savepoint_name );

      IF archive_Exists(l_czip_name) THEN
         raise_Duplicate_Archive(l_czip_name);
      END IF;

      IF is_Responder_Inf(p_inf_id) AND find_Responder_Duplicate THEN
         l_log.exit_f(
            p_function_name => 'create_Request',
            p_message_text  => l_result.result_code
         );

         RETURN l_result;
      END IF;

      l_request_result :=
         MI_Request_Api.create_Request(
            p_inf_id            => p_inf_id,
            p_original_req_uuid => p_original_req_uuid,
            p_ctaxreq_id        => p_ctaxreq_id,
            p_message_uuid      => p_message_uuid,
            p_status_cd         => MI_Request_Api.STATUS_NEW
         );

      IF MI_ResultCtx.is_Failed(l_request_result) THEN
      
         rollback_Own_Work();

         l_result :=
            MI_ResultCtx.wrap_Exception(
               p_cause => l_request_result,
               p_code  => 'MI_0600_REQUEST_HEADER_FAILED',
               p_info  => 'Не удалось создать MI_REQ для MI_0600'
            );

         l_result.parameters('ret_code') := TO_CHAR(RET_FAIL);
         
         RETURN l_result;
         
      END IF;

      l_req_id         := TO_NUMBER(l_request_result.parameters('req_id'));
      l_request_uuid   := l_request_result.parameters('external_uuid');
      l_correlation_id := l_request_result.parameters('correlation_id');
      l_item_uuid      := MI_Utils.uuid_V7;

      INSERT INTO MI_0600 (
         EXTERNAL_UUID,
         REQ_ID,
         CZIP_NAME,
         BZIP_DATA,
         IZIP_SIZE,
         IZIP_FILES_COUNT,
         ICREATE_TYPE
      )
      VALUES (
         l_item_uuid,
         l_req_id,
         l_czip_name,
         p_bzip_data,
         l_zip_size,
         l_zip_files_count,
         p_icreate_type
      )
      RETURNING ITM_ID
           INTO l_itm_id;

      insert_File_Names(
         p_itm_id     => l_itm_id,
         p_file_names => p_file_names
      );

      l_log.context(
         p_inf_id         => p_inf_id,
         p_req_id         => l_req_id,
         p_itm_id         => l_itm_id,
         p_correlation_id => l_correlation_id
      );

      l_log.info(
         p_message_text => 'MI_0600 request created',
         p_action_code  => 'create'
      );

      l_log.exit_f(
         p_function_name => 'create_Request',
         p_message_text  => 'MI_0600 request created'
      );

      RETURN
         success_Result(
            p_code            => 'MI_0600_REQUEST_CREATED',
            p_info            => 'MI_0600 request created',
            p_ret_code        => RET_OK,
            p_req_id          => l_req_id,
            p_itm_id          => l_itm_id,
            p_request_uuid    => l_request_uuid,
            p_item_uuid       => l_item_uuid,
            p_idempotent      => FALSE,
            p_archive_updated => TRUE
         );

   EXCEPTION
      WHEN e_Duplicate_Archive THEN
         rollback_Own_Work;

         l_log.error(
            p_message_text => 'Duplicate final archive rejected',
            p_action_code  => 'duplicate_archive',
            p_details_text => TO_CLOB('czip_name=' || l_czip_name)
         );

         RAISE;

      WHEN DUP_VAL_ON_INDEX THEN
         l_sqlcode := SQLCODE;
         l_sqlerrm := SQLERRM;

         rollback_Own_Work;

         /* UK_MI_0600__CZIP_NAME closes a concurrent capture race. */
         IF archive_Exists(l_czip_name) THEN
            l_log.error(
               p_message_text => 'Concurrent duplicate archive rejected',
               p_action_code  => 'duplicate_archive',
               p_details_text => TO_CLOB(l_sqlerrm)
            );

            raise_Duplicate_Archive(l_czip_name);
         END IF;

         l_log.error(
            p_message_text => 'create_Request unique constraint failed',
            p_action_code  => 'create',
            p_details_text => TO_CLOB(l_sqlerrm)
         );

         l_result :=
            MI_ResultCtx.from_Exception(
               p_sqlcode => l_sqlcode,
               p_sqlerrm => l_sqlerrm,
               p_code    => 'MI_0600_CREATE_CONFLICT',
               p_info    => 'Конфликт уникальности при создании MI_0600'
            );

         l_result.parameters('ret_code') := TO_CHAR(RET_FAIL);
         RETURN l_result;

      WHEN OTHERS THEN
         l_sqlcode := SQLCODE;
         l_sqlerrm := SQLERRM;

         rollback_Own_Work();

         l_log.error(
            p_message_text => 'create_Request failed',
            p_action_code  => 'create',
            p_details_text => TO_CLOB(l_sqlerrm)
         );

         l_result :=
            MI_ResultCtx.from_Exception(
               p_sqlcode => l_sqlcode,
               p_sqlerrm => l_sqlerrm,
               p_code    => 'MI_0600_CREATE_FAILED',
               p_info    => 'Не удалось создать MI_0600 request'
            );

         l_result.parameters('ret_code') := TO_CHAR(RET_FAIL);
         RETURN l_result;
   END create_Request_Impl;


   /* wrap для вызов через jdbc */
   PROCEDURE create_Request (
      p_inf_id                IN MI_REQ.INF_ID%TYPE,
      p_czip_name             IN MI_0600.CZIP_NAME%TYPE,
      p_bzip_data             IN MI_0600.BZIP_DATA%TYPE,
      p_izip_size             IN MI_0600.IZIP_SIZE%TYPE,
      p_izip_files_count      IN MI_0600.IZIP_FILES_COUNT%TYPE,
      p_file_names            IN SYS.ODCIVARCHAR2LIST,

      p_req_id                OUT MI_REQ.REQ_ID%TYPE,
      p_itm_id                OUT MI_0600.ITM_ID%TYPE,
      p_ret_code              OUT NUMBER,
      p_ret_info              OUT VARCHAR2,

      p_original_req_uuid     IN MI_REQ.ORIGINAL_REQ_UUID%TYPE,
      p_message_uuid          IN MI_REQ.MESSAGE_UUID%TYPE,
      p_ctaxreq_id            IN MI_REQ.CTAXREQ_ID%TYPE,
      p_icreate_type          IN MI_0600.ICREATE_TYPE%TYPE
   )
   IS
      l_result MI_ResultCtx.exec_Result_t;
   BEGIN
      p_req_id   := NULL;
      p_itm_id   := NULL;
      p_ret_code := RET_FAIL;
      p_ret_info := NULL;

      l_result :=
         create_Request_Impl(
            p_inf_id            => p_inf_id,
            p_czip_name         => p_czip_name,
            p_bzip_data         => p_bzip_data,
            p_izip_size         => p_izip_size,
            p_izip_files_count  => p_izip_files_count,
            p_file_names        => p_file_names,
            p_original_req_uuid => p_original_req_uuid,
            p_message_uuid      => p_message_uuid,
            p_ctaxreq_id        => p_ctaxreq_id,
            p_icreate_type      => p_icreate_type
         );

      p_req_id := result_Number(l_result, 'req_id');
      p_itm_id := result_Number(l_result, 'itm_id');

      export_Result(
         p_result   => l_result,
         p_ret_code => p_ret_code,
         p_ret_info => p_ret_info
      );

   EXCEPTION
      WHEN e_Duplicate_Archive THEN
         RAISE;

      WHEN OTHERS THEN
         p_req_id   := NULL;
         p_itm_id   := NULL;
         p_ret_code := RET_FAIL;
         p_ret_info :=
            SUBSTR(
               'MI_0600_JDBC_WRAPPER_FAILED: ' || SQLERRM,
               1,
               4000
            );

         g_log.error(
            p_message_text => 'create_Request JDBC wrapper failed',
            p_action_code  => 'jdbc_wrapper',
            p_details_text => TO_CLOB(SQLERRM)
         );
   END create_Request;


   /*
      Временный Oracle transport stub.

      Java вызывает процедуру в отдельном TaskContext. Явный RET_FAIL нужен,
      чтобы scheduler записал правдивый WARN до появления Multi-Bus API.
   */
   PROCEDURE send_Pending (
      p_ret_code  OUT NUMBER,
      p_ret_info  OUT VARCHAR2
   )
   IS
   BEGIN
      p_ret_code := RET_FAIL;
      p_ret_info :=
         'MI_0600_SEND_PENDING_UNSUPPORTED: '
         || 'Oracle Multi-Bus transport is not configured';
   END send_Pending;


   ---------------------------------------------------------------------------
   PROCEDURE receive_Pinned_Response (
      p_response_queue  IN  VARCHAR2,
      p_correlation_id  IN  VARCHAR2,
      p_result          OUT MI_ResultCtx.exec_Result_t
   )
   IS
      l_response_xml   CLOB;
      l_error_message  VARCHAR2(32767);
      l_bus_result     NUMBER;
      l_response_size  PLS_INTEGER := 0;
   BEGIN
      IF TRIM(p_response_queue) IS NULL
         OR TRIM(p_correlation_id) IS NULL
      THEN
         p_result :=
            failure_Result(
               p_code => 'MI_0600.RECONCILE#INVALID_ROUTE',
               p_info => 'Pinned response queue and correlation are required'
            );
         p_result.parameters('receive_entered') := '0';
         RETURN;
      END IF;

      BEGIN
         l_bus_result :=
            CBS_BUS.QUERY_RECEIVE(
               p_response_queue,
               p_correlation_id,
               0,
               l_response_xml,
               l_error_message
            );
      EXCEPTION
         WHEN OTHERS THEN
            p_result :=
               MI_ResultCtx.from_Exception(
                  p_sqlcode => SQLCODE,
                  p_sqlerrm => SQLERRM,
                  p_code    => 'MI_0600.RECONCILE#RECEIVE_ERROR',
                  p_info    => 'Receive-only Multi-Bus call failed'
               );
            p_result.parameters('receive_entered') := '1';
            p_result.parameters('delivery_outcome') := 'UNKNOWN';
            p_result.parameters('retry_safe') := '0';
            p_result.parameters('bus_correlation_id') :=
               SUBSTR(p_correlation_id, 1, 2000);
            p_result.parameters('response_queue') :=
               SUBSTR(p_response_queue, 1, 2000);
            RETURN;
      END;

      IF l_response_xml IS NOT NULL THEN
         l_response_size := DBMS_LOB.getlength(l_response_xml);
      END IF;

      IF NVL(l_bus_result, -1) <> 0 THEN
         p_result :=
            MI_ResultCtx.failure(
               p_code       => 'MI_0600.RECONCILE#RECEIVE_ERROR',
               p_info       => 'Receive-only Multi-Bus returned an error',
               p_cause_code => 'MBUS_ERROR',
               p_cause_info => SUBSTR(l_error_message, 1, 2000)
            );
         p_result.parameters('delivery_outcome') := 'UNKNOWN';
         p_result.parameters('retry_safe') := '0';
      ELSIF l_response_size = 0
         OR REGEXP_LIKE(
               DBMS_LOB.SUBSTR(l_response_xml, 4000, 1),
               '^[[:space:]]*$'
            )
      THEN
         p_result :=
            failure_Result(
               p_code => 'MI_0600.RECONCILE#EMPTY_RESPONSE',
               p_info => 'No late XXLResponse is available'
            );
         p_result.parameters('delivery_outcome') := 'UNKNOWN';
         p_result.parameters('retry_safe') := '0';
      ELSE
         BEGIN
            p_result :=
               MI_ResultCtx.result_From_Xml(
                  p_xml             => l_response_xml,
                  p_expected_action => 'send'
               );
         EXCEPTION
            WHEN OTHERS THEN
               p_result :=
                  MI_ResultCtx.from_Exception(
                     p_sqlcode => SQLCODE,
                     p_sqlerrm => SQLERRM,
                     p_code    => 'MI_0600.RECONCILE#PARSE_ERROR',
                     p_info    => 'Error parsing late XXLResponse'
                  );
               p_result.parameters('delivery_outcome') := 'UNKNOWN';
               p_result.parameters('retry_safe') := '0';
         END;
      END IF;

      p_result.parameters('receive_entered') := '1';
      p_result.parameters('response_size') := TO_CHAR(l_response_size, 'TM9');

      IF l_bus_result IS NOT NULL THEN
         p_result.parameters('bus_result_code') :=
            TO_CHAR(l_bus_result, 'TM9');
      END IF;

      p_result.parameters('bus_correlation_id') :=
         SUBSTR(p_correlation_id, 1, 2000);
      p_result.parameters('response_queue') :=
         SUBSTR(p_response_queue, 1, 2000);
   END receive_Pinned_Response;


   ---------------------------------------------------------------------------
   FUNCTION confirm_Request_Sent (
      p_req_id           IN  MI_REQ.REQ_ID%TYPE,
      p_transition_info  OUT VARCHAR2
   )
      RETURN BOOLEAN
   IS
      l_status_cd    MI_REQ.STATUS_CD%TYPE;
      l_dsend_stamp  MI_0600.DSEND_STAMP%TYPE;
      l_claimed_at   MI_0600_SEND_ATTEMPT.CLAIMED_AT%TYPE;
   BEGIN
      p_transition_info := NULL;

      SELECT r.STATUS_CD,
             h.DSEND_STAMP,
             a.CLAIMED_AT
        INTO l_status_cd,
             l_dsend_stamp,
             l_claimed_at
        FROM MI_REQ r
        JOIN MI_0600 h
          ON h.REQ_ID = r.REQ_ID
        JOIN MI_0600_SEND_ATTEMPT a
          ON a.REQ_ID = r.REQ_ID
       WHERE r.REQ_ID = p_req_id;

      IF l_status_cd IN (
            MI_Request_Api.STATUS_SENT,
            MI_Request_Api.STATUS_DONE
         )
         AND l_dsend_stamp IS NOT NULL
         AND l_dsend_stamp >= l_claimed_at
      THEN
         RETURN TRUE;
      END IF;

      p_transition_info :=
            'Persisted send evidence is incomplete; business state was not changed: status_cd='
         || NVL(TO_CHAR(l_status_cd, 'TM9'), '<NULL>')
         || '; dsend_stamp='
         || CASE
               WHEN l_dsend_stamp IS NULL THEN '<NULL>'
               ELSE TO_CHAR(
                       l_dsend_stamp,
                       'YYYY-MM-DD"T"HH24:MI:SS.FF3 TZH:TZM'
                    )
            END;
      RETURN FALSE;
   END confirm_Request_Sent;


   ---------------------------------------------------------------------------
   PROCEDURE store_Attempt_Outcome (
      p_req_id        IN MI_REQ.REQ_ID%TYPE,
      p_state_cd      IN CHAR,
      p_result        IN MI_ResultCtx.exec_Result_t,
      p_reconciled    IN BOOLEAN DEFAULT FALSE
   )
   IS
      l_reconciled        NUMBER(1) := 0;
      l_result_code       VARCHAR2(100);
      l_result_info       VARCHAR2(2000);
      l_cause_code        VARCHAR2(100);
      l_cause_info        VARCHAR2(2000);
      l_bus_result_code   NUMBER;
      l_response_size     NUMBER;
      l_delivery_outcome  VARCHAR2(30);
      l_retry_safe        NUMBER;
      l_transport_entered NUMBER;
      l_receive_entered   NUMBER;
      l_current_state     MI_0600_SEND_ATTEMPT.STATE_CD%TYPE;
   BEGIN
      IF p_reconciled THEN
         l_reconciled := 1;
      END IF;

      l_result_code := SUBSTR(p_result.result_code, 1, 100);
      l_result_info := SUBSTR(p_result.result_info, 1, 2000);
      l_cause_code := SUBSTR(p_result.cause_code, 1, 100);
      l_cause_info := SUBSTR(p_result.cause_info, 1, 2000);
      l_bus_result_code := result_Number(p_result, 'bus_result_code');
      l_response_size := result_Number(p_result, 'response_size');
      l_delivery_outcome :=
         SUBSTR(result_Text(p_result, 'delivery_outcome'), 1, 30);
      l_retry_safe := result_Number(p_result, 'retry_safe');
      l_transport_entered :=
         result_Number(p_result, 'transport_entered');
      l_receive_entered :=
         result_Number(p_result, 'receive_entered');

      UPDATE MI_0600_SEND_ATTEMPT
         SET STATE_CD =
                p_state_cd,
             FINISHED_AT =
                CASE
                   WHEN p_state_cd IN ('S', 'U', 'N') THEN SYSTIMESTAMP
                   ELSE FINISHED_AT
                END,
             LAST_RECONCILED_AT =
                CASE
                   WHEN l_reconciled = 1 THEN SYSTIMESTAMP
                   ELSE LAST_RECONCILED_AT
                END,
             RESULT_CODE =
                l_result_code,
             RESULT_INFO =
                l_result_info,
             CAUSE_CODE =
                l_cause_code,
             CAUSE_INFO =
                l_cause_info,
             BUS_RESULT_CODE =
                NVL(
                   l_bus_result_code,
                   BUS_RESULT_CODE
                ),
             RESPONSE_SIZE =
                NVL(
                   l_response_size,
                   RESPONSE_SIZE
                ),
             DELIVERY_OUTCOME =
                l_delivery_outcome,
             RETRY_SAFE =
                l_retry_safe,
             TRANSPORT_ENTERED =
                NVL(
                   l_transport_entered,
                   TRANSPORT_ENTERED
                ),
             RECEIVE_ENTERED =
                NVL(
                   l_receive_entered,
                   RECEIVE_ENTERED
                )
       WHERE REQ_ID = p_req_id
         AND (
                (STATE_CD = 'C' AND p_state_cd IN ('S', 'U', 'N'))
             OR (STATE_CD = 'U' AND p_state_cd IN ('S', 'U'))
             OR (STATE_CD = 'S' AND p_state_cd = 'S')
             OR (STATE_CD = 'N' AND p_state_cd = 'N')
         );

      IF SQL%ROWCOUNT = 0 THEN
         BEGIN
            SELECT STATE_CD
              INTO l_current_state
              FROM MI_0600_SEND_ATTEMPT
             WHERE REQ_ID = p_req_id;
         EXCEPTION
            WHEN NO_DATA_FOUND THEN
               RAISE_APPLICATION_ERROR(
                  -20031,
                  'MI_0600_SEND_ATTEMPT not found for REQ_ID=' || p_req_id
               );
         END;

         IF l_current_state IN ('S', 'N') THEN
            RETURN;
         END IF;

         RAISE_APPLICATION_ERROR(
            -20032,
               'MI_0600_SEND_ATTEMPT transition rejected: REQ_ID='
            || p_req_id
            || '; current_state='
            || l_current_state
            || '; requested_state='
            || p_state_cd
         );
      END IF;
   END store_Attempt_Outcome;


   ---------------------------------------------------------------------------
   PROCEDURE claim_Manual_601 (
      p_req_id              IN  MI_REQ.REQ_ID%TYPE,
      p_call_uuid           OUT VARCHAR2,
      p_bus_correlation_id  OUT VARCHAR2,
      p_ret_code            OUT NUMBER,
      p_ret_info            OUT VARCHAR2
   )
   IS
      l_inf_id             MI_REQ.INF_ID%TYPE;
      l_status_cd          MI_REQ.STATUS_CD%TYPE;
      l_dsend_stamp        MI_0600.DSEND_STAMP%TYPE;
      l_zip_size           PLS_INTEGER;
      l_existing_count     PLS_INTEGER;

      l_gate_alias         MI_0600_SEND_ATTEMPT.GATE_ALIAS%TYPE;
      l_request_queue      MI_0600_SEND_ATTEMPT.REQUEST_QUEUE%TYPE;
      l_response_queue     MI_0600_SEND_ATTEMPT.RESPONSE_QUEUE%TYPE;
      l_timeout_sec        PLS_INTEGER;
      l_lock_id            MI_0600_SEND_ATTEMPT.LOCK_ID%TYPE;
      l_token              VARCHAR2(64);
      l_token_hash         RAW(32);
      l_route_result       MI_ResultCtx.exec_Result_t;

      l_savepoint_name     DCL.T_Name;

      PROCEDURE rollback_Own_Work
      IS
         l_name         DCL.T_Name;
         l_rolled_back  BOOLEAN;
      BEGIN
         IF l_savepoint_name IS NOT NULL THEN
            l_name := l_savepoint_name;
            l_savepoint_name := NULL;
            l_rolled_back := DCL.RollBack(l_name);
         END IF;
      END rollback_Own_Work;

      PROCEDURE fail_Claim (
         p_code IN VARCHAR2,
         p_info IN VARCHAR2
      )
      IS
      BEGIN
         rollback_Own_Work;
         p_ret_code := RET_FAIL;
         p_ret_info := SUBSTR(p_code || ': ' || p_info, 1, 4000);
      END fail_Claim;
   BEGIN
      p_call_uuid := NULL;
      p_bus_correlation_id := NULL;
      p_ret_code := RET_FAIL;
      p_ret_info := NULL;

      /*
         Permanent production safety rule. It precedes sequence allocation,
         savepoint, row locks and DML.
      */
      IF p_req_id = 351 THEN
         p_ret_info :=
            'MI_0600_MANUAL_601#REQ_ID_351_FORBIDDEN: '
            || 'REQ_ID=351 must never be resent';
         RETURN;
      END IF;

      IF p_req_id IS NULL THEN
         p_ret_info :=
            'MI_0600_MANUAL_601#REQ_ID_REQUIRED: p_req_id is required';
         RETURN;
      END IF;

      /*
         A committed capability in this package session must be consumed or
         reconciled before another claim. A token left by caller ROLLBACK is
         stale and may be discarded because no durable attempt exists.
      */
      IF g_dispatch_token IS NOT NULL THEN
         SELECT COUNT(*)
           INTO l_existing_count
           FROM MI_0600_SEND_ATTEMPT
          WHERE REQ_ID = g_dispatch_req_id
            AND TRIM(CALL_UUID) = TRIM(g_dispatch_call_uuid);

         IF l_existing_count > 0 THEN
            p_ret_info :=
               'MI_0600_MANUAL_601#SESSION_CAPABILITY_ACTIVE: '
               || 'this session already owns a committed dispatch capability';
            RETURN;
         END IF;

         clear_Dispatch_Capability;
      END IF;

      DCL.SavePoint(l_savepoint_name);

      BEGIN
         SELECT r.INF_ID,
                r.STATUS_CD,
                h.DSEND_STAMP,
                DBMS_LOB.getlength(h.BZIP_DATA)
           INTO l_inf_id,
                l_status_cd,
                l_dsend_stamp,
                l_zip_size
           FROM MI_REQ r
           JOIN MI_0600 h
             ON h.REQ_ID = r.REQ_ID
          WHERE r.REQ_ID = p_req_id
            FOR UPDATE OF r.STATUS_CD, h.DSEND_STAMP NOWAIT;

      EXCEPTION
         WHEN NO_DATA_FOUND THEN
            fail_Claim(
               'MI_0600_MANUAL_601#REQUEST_NOT_FOUND',
               'request or exactly one MI_0600 item was not found'
            );
            RETURN;
         WHEN OTHERS THEN
            IF SQLCODE = -54 THEN
               fail_Claim(
                  'MI_0600_MANUAL_601#CLAIM_BUSY',
                  'request is locked by another transaction'
               );
               RETURN;
            END IF;
            RAISE;
      END;

      IF NVL(l_inf_id, -1) <> 601 THEN
         fail_Claim(
            'MI_0600_MANUAL_601#NOT_OUTGOING_601',
            'only INF_ID=601 is supported'
         );
         RETURN;
      END IF;

      IF l_status_cd <> MI_Request_Api.STATUS_NEW THEN
         fail_Claim(
            'MI_0600_MANUAL_601#BAD_STATUS',
            'only NEW request may be claimed'
         );
         RETURN;
      END IF;

      IF l_dsend_stamp IS NOT NULL OR NVL(l_zip_size, 0) = 0 THEN
         fail_Claim(
            'MI_0600_MANUAL_601#INVALID_PAYLOAD_STATE',
            'ZIP payload must be nonempty and DSEND_STAMP must be NULL'
         );
         RETURN;
      END IF;

      SELECT COUNT(*)
        INTO l_existing_count
        FROM MI_0600_SEND_ATTEMPT
       WHERE REQ_ID = p_req_id;

      IF l_existing_count > 0 THEN
         fail_Claim(
            'MI_0600_MANUAL_601#ATTEMPT_EXISTS',
            'v1 permits only one attempt ever per REQ_ID'
         );
         RETURN;
      END IF;

      MI_mbus.resolve_Request_Route(
         p_req_id         => p_req_id,
         p_gate_alias     => l_gate_alias,
         p_request_queue  => l_request_queue,
         p_response_queue => l_response_queue,
         p_timeout_sec    => l_timeout_sec,
         p_result         => l_route_result
      );

      IF MI_ResultCtx.is_Failed(l_route_result) THEN
         fail_Claim(
            'MI_0600_MANUAL_601#ROUTE_INVALID',
            SUBSTR(
                  NVL(l_route_result.result_code, '<NULL>')
               || ': '
               || NVL(l_route_result.result_info, '<NULL>'),
               1,
               2000
            )
         );
         RETURN;
      END IF;

      p_call_uuid := MI_Utils.uuid_V7;
      p_bus_correlation_id := 'CBS' || TO_CHAR(CBSBUS_CORID.NEXTVAL, 'FM99999999999999999999999999999999999999');
      l_lock_id :=
         ORA_HASH(
            'MI_0600_MANUAL_601:' || p_call_uuid,
            1073741823
         );
      l_token := RAWTOHEX(DBMS_CRYPTO.RANDOMBYTES(32));

      SELECT STANDARD_HASH(l_token, 'SHA256')
        INTO l_token_hash
        FROM DUAL;

      INSERT INTO MI_0600_SEND_ATTEMPT (
         REQ_ID,
         CALL_UUID,
         BUS_CORRELATION_ID,
         GATE_ALIAS,
         REQUEST_QUEUE,
         RESPONSE_QUEUE,
         TIMEOUT_SEC,
         LOCK_ID,
         TOKEN_HASH,
         STATE_CD
      )
      VALUES (
         p_req_id,
         p_call_uuid,
         p_bus_correlation_id,
         l_gate_alias,
         l_request_queue,
         l_response_queue,
         l_timeout_sec,
         l_lock_id,
         l_token_hash,
         'C'
      );

      g_dispatch_req_id := p_req_id;
      g_dispatch_call_uuid := p_call_uuid;
      g_dispatch_token := l_token;

      p_ret_code := RET_OK;
      p_ret_info :=
         'MI_0600_MANUAL_601_CLAIMED: caller must COMMIT before dispatch';

   EXCEPTION
      WHEN DUP_VAL_ON_INDEX THEN
         rollback_Own_Work;
         clear_Dispatch_Capability;
         p_call_uuid := NULL;
         p_bus_correlation_id := NULL;
         p_ret_code := RET_FAIL;
         p_ret_info :=
            'MI_0600_MANUAL_601#ATTEMPT_EXISTS: '
            || 'v1 permits only one attempt ever per REQ_ID';

      WHEN OTHERS THEN
         rollback_Own_Work;
         clear_Dispatch_Capability;
         p_call_uuid := NULL;
         p_bus_correlation_id := NULL;
         p_ret_code := RET_FAIL;
         p_ret_info :=
            SUBSTR(
               'MI_0600_MANUAL_601#CLAIM_FAILED: ' || SQLERRM,
               1,
               4000
            );
   END claim_Manual_601;


   ---------------------------------------------------------------------------
   PROCEDURE dispatch_Claimed_601 (
      p_req_id    IN  MI_REQ.REQ_ID%TYPE,
      p_call_uuid IN  VARCHAR2,
      p_ret_code  OUT NUMBER,
      p_ret_info  OUT VARCHAR2
   )
   IS
      l_state_cd             MI_0600_SEND_ATTEMPT.STATE_CD%TYPE;
      l_lock_id              MI_0600_SEND_ATTEMPT.LOCK_ID%TYPE;
      l_lock_result          PLS_INTEGER;
      l_token                VARCHAR2(64);
      l_transport_entered    NUMBER;
      l_transition_info      VARCHAR2(2000);
      l_confirmed_sent       BOOLEAN := FALSE;
      l_capability_consumed  BOOLEAN := FALSE;
      l_sqlcode              PLS_INTEGER;
      l_sqlerrm              VARCHAR2(2000);
      l_result               MI_ResultCtx.exec_Result_t;
   BEGIN
      /*
         This must be the first executable check. Claim performs FOR UPDATE
         and INSERT, therefore omitted caller COMMIT is rejected before reads,
         capability consumption, DBMS_LOCK or transport.
      */
      IF DBMS_TRANSACTION.LOCAL_TRANSACTION_ID(FALSE) IS NOT NULL THEN
         p_ret_code := RET_FAIL;
         p_ret_info :=
            'MI_0600_MANUAL_601#CLAIM_COMMIT_REQUIRED: '
            || 'dispatch requires a session with no active local transaction';
         RETURN;
      END IF;

      IF p_req_id IS NULL
         OR p_req_id = 351
         OR TRIM(p_call_uuid) IS NULL
      THEN
         p_ret_code := RET_FAIL;
         p_ret_info :=
            'MI_0600_MANUAL_601#INVALID_DISPATCH_IDENTITY';
         RETURN;
      END IF;

      IF g_dispatch_token IS NULL
         OR g_dispatch_req_id <> p_req_id
         OR TRIM(g_dispatch_call_uuid) <> TRIM(p_call_uuid)
      THEN
         p_ret_code := RET_FAIL;
         p_ret_info :=
            'MI_0600_MANUAL_601#DISPATCH_CAPABILITY_MISSING: '
            || 'claim must be made and committed in this package session';
         RETURN;
      END IF;

      BEGIN
         SELECT LOCK_ID
           INTO l_lock_id
           FROM MI_0600_SEND_ATTEMPT
          WHERE REQ_ID = p_req_id
            AND TRIM(CALL_UUID) = TRIM(p_call_uuid);

      EXCEPTION
         WHEN NO_DATA_FOUND THEN
            clear_Dispatch_Capability;
            p_ret_code := RET_FAIL;
            p_ret_info :=
               'MI_0600_MANUAL_601#ATTEMPT_NOT_COMMITTED: '
               || 'durable claim was not found';
            RETURN;
      END;

      /*
         Read-only validation above must not create a transaction. Repeat the
         proof immediately before the shared dispatch/reconcile user lock.
      */
      IF DBMS_TRANSACTION.LOCAL_TRANSACTION_ID(FALSE) IS NOT NULL THEN
         p_ret_code := RET_FAIL;
         p_ret_info :=
            'MI_0600_MANUAL_601#CLAIM_COMMIT_REQUIRED: '
            || 'validation unexpectedly opened a local transaction';
         RETURN;
      END IF;

      l_lock_result :=
         DBMS_LOCK.REQUEST(
            id                => l_lock_id,
            lockmode          => DBMS_LOCK.X_MODE,
            timeout           => 0,
            release_on_commit => TRUE
         );

      IF l_lock_result <> 0 THEN
         p_ret_code := RET_FAIL;
         p_ret_info :=
            'MI_0600_MANUAL_601#DISPATCH_LOCK_FAILED: result='
            || TO_CHAR(l_lock_result, 'TM9');
         RETURN;
      END IF;

      /*
         State read before DBMS_LOCK would be stale if reconciliation finished
         in the gap. Reload it only after this path owns the shared lock.
      */
      BEGIN
         SELECT STATE_CD
           INTO l_state_cd
           FROM MI_0600_SEND_ATTEMPT
          WHERE REQ_ID = p_req_id
            AND TRIM(CALL_UUID) = TRIM(p_call_uuid);
      EXCEPTION
         WHEN NO_DATA_FOUND THEN
            clear_Dispatch_Capability;
            p_ret_code := RET_FAIL;
            p_ret_info :=
               'MI_0600_MANUAL_601#ATTEMPT_NOT_COMMITTED: '
               || 'durable claim disappeared after lock acquisition';
            RETURN;
      END;

      IF l_state_cd <> 'C' THEN
         clear_Dispatch_Capability;
         p_ret_code := RET_FAIL;
         p_ret_info :=
            'MI_0600_MANUAL_601#ATTEMPT_NOT_CLAIMED: state='
            || NVL(l_state_cd, '<NULL>');
         RETURN;
      END IF;

      /*
         Consume the raw capability only after both transaction checks, durable
         attempt validation and successful acquisition of the shared user lock.
      */
      l_token := g_dispatch_token;
      clear_Dispatch_Capability;
      l_capability_consumed := TRUE;

      MI_mbus.send_Claimed_Request(
         p_req_id         => p_req_id,
         p_call_uuid      => p_call_uuid,
         p_dispatch_token => l_token,
         p_result         => l_result
      );
      l_token := NULL;

      l_transport_entered :=
         result_Number(l_result, 'transport_entered');

      IF MI_ResultCtx.is_Success(l_result)
         AND l_result.result_code = 'SEND_PUBLISHED'
      THEN
         l_confirmed_sent :=
            confirm_Request_Sent(
               p_req_id          => p_req_id,
               p_transition_info => l_transition_info
            );
      END IF;

      IF l_confirmed_sent THEN
         l_result.parameters('delivery_outcome') := 'CONFIRMED_SENT';
         l_result.parameters('retry_safe') := '0';

         store_Attempt_Outcome(
            p_req_id     => p_req_id,
            p_state_cd   => 'S',
            p_result     => l_result,
            p_reconciled => FALSE
         );

         p_ret_code := RET_OK;
         p_ret_info :=
            'MI_0600_MANUAL_601_SENT: exact response and persisted state confirmed';
      ELSIF NVL(l_transport_entered, 0) = 0 THEN
         l_result.parameters('delivery_outcome') := 'NOT_ENQUEUED';
         l_result.parameters('retry_safe') := '0';

         store_Attempt_Outcome(
            p_req_id     => p_req_id,
            p_state_cd   => 'N',
            p_result     => l_result,
            p_reconciled => FALSE
         );

         p_ret_code := RET_FAIL;
         p_ret_info :=
            'MI_0600_MANUAL_601_NOT_ENQUEUED: '
            || NVL(l_result.result_code, '<NULL>')
            || ': '
            || NVL(l_result.result_info, '<NULL>');
      ELSE
         l_result.parameters('delivery_outcome') := 'UNKNOWN';
         l_result.parameters('retry_safe') := '0';

         store_Attempt_Outcome(
            p_req_id     => p_req_id,
            p_state_cd   => 'U',
            p_result     => l_result,
            p_reconciled => FALSE
         );

         p_ret_code := RET_FAIL;
         p_ret_info :=
            SUBSTR(
                  'MI_0600_MANUAL_601_UNKNOWN: '
               || NVL(l_result.result_code, '<NULL>')
               || ': '
               || NVL(l_result.result_info, '<NULL>')
               || CASE
                     WHEN l_transition_info IS NOT NULL
                     THEN '; transition=' || l_transition_info
                  END,
               1,
               4000
            );
      END IF;

   EXCEPTION
      WHEN OTHERS THEN
         l_sqlcode := SQLCODE;
         l_sqlerrm := SQLERRM;
         l_token := NULL;

         IF l_capability_consumed THEN
            l_result :=
               MI_ResultCtx.from_Exception(
                  p_sqlcode => l_sqlcode,
                  p_sqlerrm => l_sqlerrm,
                  p_code    => 'MI_0600_MANUAL_601#DISPATCH_FAILED',
                  p_info    =>
                     'Dispatch failed after capability consumption; outcome is unknown'
               );
            l_result.parameters('delivery_outcome') := 'UNKNOWN';
            l_result.parameters('retry_safe') := '0';

            BEGIN
               store_Attempt_Outcome(
                  p_req_id     => p_req_id,
                  p_state_cd   => 'U',
                  p_result     => l_result,
                  p_reconciled => FALSE
               );
            EXCEPTION
               WHEN OTHERS THEN
                  NULL;
            END;
         END IF;

         p_ret_code := RET_FAIL;
         p_ret_info :=
            SUBSTR(
               'MI_0600_MANUAL_601#DISPATCH_FAILED: ' || l_sqlerrm,
               1,
               4000
            );
   END dispatch_Claimed_601;


   ---------------------------------------------------------------------------
   PROCEDURE reconcile_Manual_601 (
      p_req_id    IN  MI_REQ.REQ_ID%TYPE,
      p_ret_code  OUT NUMBER,
      p_ret_info  OUT VARCHAR2
   )
   IS
      l_state_cd          MI_0600_SEND_ATTEMPT.STATE_CD%TYPE;
      l_lock_id           MI_0600_SEND_ATTEMPT.LOCK_ID%TYPE;
      l_response_queue    MI_0600_SEND_ATTEMPT.RESPONSE_QUEUE%TYPE;
      l_correlation_id    MI_0600_SEND_ATTEMPT.BUS_CORRELATION_ID%TYPE;
      l_saved_result_code MI_0600_SEND_ATTEMPT.RESULT_CODE%TYPE;
      l_lock_result       PLS_INTEGER;
      l_transition_info   VARCHAR2(2000);
      l_confirmed_sent    BOOLEAN := FALSE;
      l_lock_acquired     BOOLEAN := FALSE;
      l_sqlcode           PLS_INTEGER;
      l_sqlerrm           VARCHAR2(2000);
      l_result            MI_ResultCtx.exec_Result_t;
   BEGIN
      /*
         Same transaction boundary as dispatch. Reconcile must not consume an
         immediate-dequeue response while caller row locks are open.
      */
      IF DBMS_TRANSACTION.LOCAL_TRANSACTION_ID(FALSE) IS NOT NULL THEN
         p_ret_code := RET_FAIL;
         p_ret_info :=
            'MI_0600_MANUAL_601#RECONCILE_COMMIT_REQUIRED: '
            || 'reconcile requires no active local transaction';
         RETURN;
      END IF;

      IF p_req_id IS NULL OR p_req_id = 351 THEN
         p_ret_code := RET_FAIL;
         p_ret_info :=
            'MI_0600_MANUAL_601#INVALID_RECONCILE_IDENTITY';
         RETURN;
      END IF;

      BEGIN
         SELECT LOCK_ID
           INTO l_lock_id
           FROM MI_0600_SEND_ATTEMPT
          WHERE REQ_ID = p_req_id;

      EXCEPTION
         WHEN NO_DATA_FOUND THEN
            p_ret_code := RET_FAIL;
            p_ret_info :=
               'MI_0600_MANUAL_601#ATTEMPT_NOT_FOUND';
            RETURN;
      END;

      IF DBMS_TRANSACTION.LOCAL_TRANSACTION_ID(FALSE) IS NOT NULL THEN
         p_ret_code := RET_FAIL;
         p_ret_info :=
            'MI_0600_MANUAL_601#RECONCILE_COMMIT_REQUIRED: '
            || 'validation unexpectedly opened a local transaction';
         RETURN;
      END IF;

      l_lock_result :=
         DBMS_LOCK.REQUEST(
            id                => l_lock_id,
            lockmode          => DBMS_LOCK.X_MODE,
            timeout           => 0,
            release_on_commit => TRUE
         );

      IF l_lock_result <> 0 THEN
         p_ret_code := RET_FAIL;

         IF l_lock_result = 1 THEN
            p_ret_info :=
               'MI_0600_MANUAL_601#DISPATCH_ACTIVE: '
               || 'shared dispatch/reconcile lock is busy';
         ELSE
            p_ret_info :=
               'MI_0600_MANUAL_601#RECONCILE_LOCK_FAILED: result='
               || TO_CHAR(l_lock_result, 'TM9');
         END IF;

         /*
            Critical invariant: no QUERY_RECEIVE call exists on this branch.
         */
         RETURN;
      END IF;

      l_lock_acquired := TRUE;

      /*
         LOCK_ID is immutable and is the only value allowed before DBMS_LOCK.
         State, route and prior evidence are reloaded from committed data after
         the shared lock is owned, so stale C/U cannot downgrade terminal S/N.
      */
      BEGIN
         SELECT STATE_CD,
                RESPONSE_QUEUE,
                BUS_CORRELATION_ID,
                RESULT_CODE
           INTO l_state_cd,
                l_response_queue,
                l_correlation_id,
                l_saved_result_code
           FROM MI_0600_SEND_ATTEMPT
          WHERE REQ_ID = p_req_id;
      EXCEPTION
         WHEN NO_DATA_FOUND THEN
            p_ret_code := RET_FAIL;
            p_ret_info :=
               'MI_0600_MANUAL_601#ATTEMPT_NOT_FOUND_AFTER_LOCK';
            RETURN;
      END;

      IF g_dispatch_req_id = p_req_id THEN
         clear_Dispatch_Capability;
      END IF;

      IF l_state_cd = 'S' THEN
         p_ret_code := RET_OK;
         p_ret_info :=
            'MI_0600_MANUAL_601_ALREADY_CONFIRMED_SENT';
         RETURN;
      ELSIF l_state_cd = 'N' THEN
         p_ret_code := RET_FAIL;
         p_ret_info :=
            'MI_0600_MANUAL_601_CONFIRMED_NOT_ENQUEUED: '
            || 'v1 does not permit retry';
         RETURN;
      END IF;

      /*
         If an exact SEND_PUBLISHED result was persisted before an incomplete
         status transition, it is attributable to this unique attempt. Try the
         DB transition again without consuming another response.
      */
      IF l_saved_result_code = 'SEND_PUBLISHED' THEN
         l_result :=
            MI_ResultCtx.success(
               p_code => 'SEND_PUBLISHED',
               p_info => 'Persisted exact response from this attempt'
            );

         l_confirmed_sent :=
            confirm_Request_Sent(
               p_req_id          => p_req_id,
               p_transition_info => l_transition_info
            );
      ELSE
         /*
            Receive-only path: pinned response queue + saved CBS ID, nWait=0.
            Private package-body entry cannot bypass the shared lock or use an
            arbitrary route through a public MI API.
         */
         receive_Pinned_Response(
            p_response_queue => l_response_queue,
            p_correlation_id => l_correlation_id,
            p_result         => l_result
         );

         IF MI_ResultCtx.is_Success(l_result)
            AND l_result.result_code = 'SEND_PUBLISHED'
         THEN
            l_confirmed_sent :=
               confirm_Request_Sent(
                  p_req_id          => p_req_id,
                  p_transition_info => l_transition_info
               );
         END IF;
      END IF;

      IF l_confirmed_sent THEN
         l_result.parameters('delivery_outcome') := 'CONFIRMED_SENT';
         l_result.parameters('retry_safe') := '0';

         store_Attempt_Outcome(
            p_req_id     => p_req_id,
            p_state_cd   => 'S',
            p_result     => l_result,
            p_reconciled => TRUE
         );

         p_ret_code := RET_OK;
         p_ret_info :=
            'MI_0600_MANUAL_601_RECONCILED_SENT';
      ELSE
         l_result.parameters('delivery_outcome') := 'UNKNOWN';
         l_result.parameters('retry_safe') := '0';

         store_Attempt_Outcome(
            p_req_id     => p_req_id,
            p_state_cd   => 'U',
            p_result     => l_result,
            p_reconciled => TRUE
         );

         p_ret_code := RET_FAIL;
         p_ret_info :=
            SUBSTR(
                  'MI_0600_MANUAL_601_UNKNOWN: '
               || NVL(l_result.result_code, '<NULL>')
               || ': '
               || NVL(l_result.result_info, '<NULL>')
               || CASE
                     WHEN l_transition_info IS NOT NULL
                     THEN '; transition=' || l_transition_info
                  END,
               1,
               4000
            );
      END IF;

   EXCEPTION
      WHEN OTHERS THEN
         l_sqlcode := SQLCODE;
         l_sqlerrm := SQLERRM;

         IF l_lock_acquired THEN
            l_result :=
               MI_ResultCtx.from_Exception(
                  p_sqlcode => l_sqlcode,
                  p_sqlerrm => l_sqlerrm,
                  p_code    => 'MI_0600_MANUAL_601#RECONCILE_FAILED',
                  p_info    => 'Reconciliation outcome is unknown'
               );
            l_result.parameters('delivery_outcome') := 'UNKNOWN';
            l_result.parameters('retry_safe') := '0';

            BEGIN
               store_Attempt_Outcome(
                  p_req_id     => p_req_id,
                  p_state_cd   => 'U',
                  p_result     => l_result,
                  p_reconciled => TRUE
               );
            EXCEPTION
               WHEN OTHERS THEN
                  NULL;
            END;
         END IF;

         p_ret_code := RET_FAIL;
         p_ret_info :=
            SUBSTR(
               'MI_0600_MANUAL_601#RECONCILE_FAILED: ' || l_sqlerrm,
               1,
               4000
            );
   END reconcile_Manual_601;


   /* Для ядра, получить дату обработки файла */
   FUNCTION get_Fns_File_Inqueue_Date (
      p_file_name IN MI_0600_F.CZIP_FILE_NAME%TYPE
   )
      RETURN DATE
   IS
      l_result DATE;
   BEGIN
      IF TRIM(p_file_name) IS NULL THEN
         RETURN NULL;
      END IF;

      SELECT MAX(TRUNC(CAST(h.DSEND_STAMP AS DATE)))
        INTO l_result
        FROM MI_0600 h
        JOIN MI_0600_F f
          ON f.ITM_ID = h.ITM_ID
       WHERE UPPER(TRIM(f.CZIP_FILE_NAME)) = UPPER(TRIM(p_file_name));

      RETURN l_result;
   END get_Fns_File_Inqueue_Date;


   /* */
   FUNCTION apply_Item_Result_Impl (
      p_request_uuid      IN MI_REQ.EXTERNAL_UUID%TYPE,
      p_message_uuid      IN MI_REQ.MESSAGE_UUID%TYPE,
      p_item_uuid         IN MI_0600.EXTERNAL_UUID%TYPE,

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
      l_result MI_ResultCtx.exec_Result_t;
   BEGIN
   
      g_log.enter_f(
         p_function_name => 'apply_Item_Result',
         p_message_text  => 'item_uuid=' || TRIM(p_item_uuid)
      );

      l_result :=
         MI_Item_Result_Api.apply_Item_Result(
            p_item_table        => 'MI_0600',
            p_payload_mapper    => 'MI_0600_API.MAP_ITEM_RESULT',
            p_request_uuid      => p_request_uuid,
            p_message_uuid      => p_message_uuid,
            p_item_uuid         => p_item_uuid,
            p_response_kind     => p_response_kind,
            p_response_code     => p_response_code,
            p_response_info     => p_response_info,
            p_response_details  => p_response_details,
            p_response_time     => p_response_time,
            p_payload_text      => p_payload_text,
            p_payload_type      => p_payload_type
         );

      g_log.exit_f(
         p_function_name => 'apply_Item_Result',
         p_message_text  => NVL(l_result.result_code, '<NULL>')
      );

      RETURN l_result;
   END apply_Item_Result_Impl;


   /* */
   PROCEDURE apply_Item_Result (
      p_request_uuid      IN MI_REQ.EXTERNAL_UUID%TYPE,
      p_message_uuid      IN MI_REQ.MESSAGE_UUID%TYPE,
      p_item_uuid         IN MI_0600.EXTERNAL_UUID%TYPE,

      p_response_kind     IN NUMBER,

      p_response_code     IN MI_REQ.RESULT_CODE%TYPE,
      p_response_info     IN MI_REQ.RESULT_INFO%TYPE,
      p_response_details  IN CLOB,
      p_response_time     IN TIMESTAMP WITH TIME ZONE,

      p_payload_text      IN CLOB,
      p_payload_type      IN VARCHAR2,

      p_ret_code          OUT NUMBER,
      p_ret_info          OUT VARCHAR2
   )
   IS
      l_result MI_ResultCtx.exec_Result_t;
   BEGIN
      p_ret_code := MI_Item_Result_Api.RET_FAIL;
      p_ret_info := NULL;

      l_result :=
         apply_Item_Result_Impl(
            p_request_uuid      => p_request_uuid,
            p_message_uuid      => p_message_uuid,
            p_item_uuid         => p_item_uuid,
            p_response_kind     => p_response_kind,
            p_response_code     => p_response_code,
            p_response_info     => p_response_info,
            p_response_details  => p_response_details,
            p_response_time     => p_response_time,
            p_payload_text      => p_payload_text,
            p_payload_type      => p_payload_type
         );

      export_Result(
         p_result   => l_result,
         p_ret_code => p_ret_code,
         p_ret_info => p_ret_info
      );

   EXCEPTION
      WHEN OTHERS THEN
         p_ret_code := MI_Item_Result_Api.RET_FAIL;
         p_ret_info :=
            SUBSTR(
               'MI_0600_JDBC_WRAPPER_FAILED: ' || SQLERRM,
               1,
               4000
            );

         g_log.error(
            p_message_text => 'apply_Item_Result JDBC wrapper failed',
            p_action_code  => 'jdbc_wrapper',
            p_details_text => TO_CLOB(SQLERRM)
         );
   END apply_Item_Result;


   /* */
   PROCEDURE map_Item_Result (
      p_itm_id        IN  NUMBER,
      p_payload_text  IN  CLOB,
      p_payload_type  IN  VARCHAR2,
      p_ires_code     OUT NUMBER,
      p_cres_info     OUT CLOB
   )
   IS
      l_state       NUMBER;
      l_message     VARCHAR2(2000);
      l_error_code  VARCHAR2(100);
      l_log         MI_Logger_T := g_log;
   BEGIN
      l_log.context(p_itm_id => p_itm_id);

      IF LOWER(TRIM(p_payload_type)) <> 'json' THEN
         RAISE_APPLICATION_ERROR( -20021, 'MI_0600 payload mapper supports JSON only' );
      END IF;

      SELECT JSON_VALUE(
                p_payload_text,
                '$.state' RETURNING NUMBER NULL ON ERROR
             ),
             JSON_VALUE(
                p_payload_text,
                '$.message' RETURNING VARCHAR2(2000) NULL ON ERROR
             ),
             JSON_VALUE(
                p_payload_text,
                '$.errorCode' RETURNING VARCHAR2(100) NULL ON ERROR
             )
        INTO l_state,
             l_message,
             l_error_code
        FROM DUAL;

      IF l_state IS NOT NULL AND l_state >= 0 THEN
         p_ires_code := l_state;
         p_cres_info := TO_CLOB(l_message);

      ELSE
         p_ires_code := MI_Item_Result_Api.RESPONSE_FAIL;
         p_cres_info := TO_CLOB(NVL(l_message, 'Ошибка обработки запроса'));

         IF l_error_code IS NOT NULL THEN
            p_cres_info := p_cres_info || TO_CLOB(' [' || l_error_code || ']');
         END IF;
         
      END IF;

      l_log.debug(
         p_message_text => 'MI_0600 payload mapped',
         p_action_code  => 'map_payload',
         p_details_text => TO_CLOB('ires_code=' || p_ires_code)
      );

   EXCEPTION
      WHEN OTHERS THEN
         l_log.error(
            p_message_text => 'map_Item_Result failed',
            p_action_code  => 'map_payload',
            p_details_text => TO_CLOB(SQLERRM)
         );

         RAISE;
   END map_Item_Result;


   /* При отправке запроса */
   PROCEDURE on_Request_Sent (
      p_req_id IN MI_REQ.REQ_ID%TYPE
   )
   IS
   BEGIN
      UPDATE MI_0600
         SET DSEND_STAMP = SYSTIMESTAMP
       WHERE REQ_ID = p_req_id
         AND DSEND_STAMP IS NULL;

      IF SQL%ROWCOUNT > 0 THEN
         g_log.info(
            p_message_text =>
               'MI_0600 request marked as sent, req_id=' || p_req_id,
            p_action_code  => 'request_sent'
         );
      END IF;
   END on_Request_Sent;

END MI_0600_Api;
/

