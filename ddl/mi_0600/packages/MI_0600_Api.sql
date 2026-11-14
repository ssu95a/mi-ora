CREATE OR REPLACE PACKAGE MI_0600_Api
IS

   VERSION CONSTANT VARCHAR2(100) :=
      '$Id: {1.1.1} {14.11.2026} Sulimoff$';


   RET_FAIL     CONSTANT NUMBER := -1;
   RET_OK       CONSTANT NUMBER :=  0;
   RET_NO_DATA  CONSTANT NUMBER :=  1;
   RET_EXISTS   CONSTANT NUMBER :=  4;


   FUNCTION get_Version
      RETURN VARCHAR2;


   /*
      Атомарно создаёт MI_REQ, один MI_0600 item и список имён файлов.

      Для инициаторов 601/603/611 CZIP_NAME является ключом
      идемпотентности. Повторный capture возвращает существующие REQ_ID и
      ITM_ID. Пока request находится в NEW/ERROR, архив и список файлов
      обновляются; после начала обработки существующий item не изменяется.

      Для ответчиков 602/604/612 дополнительно распознаётся повтор по
      ORIGINAL_REQ_UUID внутри того же INF_ID.

      JDBC boundary не содержит PL/SQL records. Список файлов передаётся как
      schema-level SQL collection SYS.ODCIVARCHAR2LIST, поддерживаемая Oracle
      JDBC через java.sql.Array/OracleArray.

      Package не выполняет COMMIT. При ошибке откатывает только собственную
      работу через DCL.SavePoint/RollBack.
   */
   PROCEDURE create_Request (
      p_inf_id                IN MI_REQ.INF_ID%TYPE,
      p_czip_name             IN MI_0600.CZIP_NAME%TYPE,
      p_bzip_data             IN MI_0600.BZIP_DATA%TYPE,
      p_izip_size             IN MI_0600.IZIP_SIZE%TYPE,
      p_izip_files_count      IN MI_0600.IZIP_FILES_COUNT%TYPE,
      p_file_names            IN SYS.ODCIVARCHAR2LIST,

      p_original_req_uuid     IN MI_REQ.ORIGINAL_REQ_UUID%TYPE,
      p_message_uuid          IN MI_REQ.MESSAGE_UUID%TYPE,
      p_ctaxreq_id            IN MI_REQ.CTAXREQ_ID%TYPE,
      p_icreate_type          IN MI_0600.ICREATE_TYPE%TYPE,

      p_req_id                OUT MI_REQ.REQ_ID%TYPE,
      p_itm_id                OUT MI_0600.ITM_ID%TYPE,
      p_ret_code              OUT NUMBER,
      p_ret_info              OUT VARCHAR2
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

   cLogger CONSTANT VARCHAR2(64) := 'mi.0600';


   g_log CONSTANT MI_Logger_T :=
      MI_Logger_T(
         p_logger_name  => cLogger,
         p_package_name => $$PLSQL_UNIT
      );


   ---------------------------------------------------------------------------
   FUNCTION get_Version
      RETURN VARCHAR2
   IS
   BEGIN
      RETURN VERSION;
   END get_Version;


   ---------------------------------------------------------------------------
   FUNCTION is_Supported_Inf (
      p_inf_id IN MI_REQ.INF_ID%TYPE
   )
      RETURN BOOLEAN
   IS
   BEGIN
      RETURN p_inf_id IN (601, 602, 603, 604, 611, 612);
   END is_Supported_Inf;


   ---------------------------------------------------------------------------
   FUNCTION is_Initiator_Inf (
      p_inf_id IN MI_REQ.INF_ID%TYPE
   )
      RETURN BOOLEAN
   IS
   BEGIN
      RETURN p_inf_id IN (601, 603, 611);
   END is_Initiator_Inf;


   ---------------------------------------------------------------------------
   FUNCTION is_Responder_Inf (
      p_inf_id IN MI_REQ.INF_ID%TYPE
   )
      RETURN BOOLEAN
   IS
   BEGIN
      RETURN p_inf_id IN (602, 604, 612);
   END is_Responder_Inf;


   ---------------------------------------------------------------------------
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
      l_result :=
         MI_ResultCtx.success(
            p_code => p_code,
            p_info => p_info
         );

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
         l_result.parameters('idempotent') :=
            MI_Utils.to_Char(p_idempotent);
      END IF;

      IF p_archive_updated IS NOT NULL THEN
         l_result.parameters('archive_updated') :=
            MI_Utils.to_Char(p_archive_updated);
      END IF;

      RETURN l_result;
   END success_Result;


   ---------------------------------------------------------------------------
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


   ---------------------------------------------------------------------------
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


   ---------------------------------------------------------------------------
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

      p_ret_info :=
         SUBSTR(
               NVL(p_result.result_code, '<NO_RESULT_CODE>')
            || ': '
            || NVL(p_result.result_info, '<NO_RESULT_INFO>')
            || CASE
                  WHEN p_result.cause_code IS NOT NULL
                     OR p_result.cause_info IS NOT NULL
                  THEN
                        '; cause='
                     || NVL(p_result.cause_code, '<NO_CAUSE_CODE>')
                     || ': '
                     || NVL(p_result.cause_info, '<NO_CAUSE_INFO>')
                  ELSE NULL
               END,
            1,
            4000
         );
   END export_Result;


   ---------------------------------------------------------------------------
   PROCEDURE replace_File_Names (
      p_itm_id      IN MI_0600.ITM_ID%TYPE,
      p_file_names  IN SYS.ODCIVARCHAR2LIST
   )
   IS
      l_index      PLS_INTEGER;
      l_file_name  MI_0600_F.CZIP_FILE_NAME%TYPE;
   BEGIN
      DELETE FROM MI_0600_F
       WHERE ITM_ID = p_itm_id;

      IF p_file_names.COUNT = 0 THEN
         RETURN;
      END IF;

      l_index := p_file_names.FIRST;

      WHILE l_index IS NOT NULL LOOP
         l_file_name := TRIM(p_file_names(l_index));

         IF l_file_name IS NOT NULL THEN
            BEGIN
               INSERT INTO MI_0600_F (
                  ITM_ID,
                  CZIP_FILE_NAME
               )
               VALUES (
                  p_itm_id,
                  l_file_name
               );

            EXCEPTION
               /* Duplicate names in one supplied list do not duplicate a link. */
               WHEN DUP_VAL_ON_INDEX THEN
                  NULL;
            END;
         END IF;

         l_index := p_file_names.NEXT(l_index);
      END LOOP;

   EXCEPTION
      /* An omitted SQL collection is atomically NULL. */
      WHEN COLLECTION_IS_NULL THEN
         NULL;
   END replace_File_Names;


   ---------------------------------------------------------------------------
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


      ------------------------------------------------------------------------
      PROCEDURE rollback_Own_Work
      IS
         l_name         DCL.T_Name;
         l_rolled_back  BOOLEAN;
      BEGIN
         IF l_savepoint_name IS NOT NULL THEN
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
      FUNCTION reuse_Archive
         RETURN BOOLEAN
      IS
         l_existing_req_id     MI_REQ.REQ_ID%TYPE;
         l_existing_itm_id     MI_0600.ITM_ID%TYPE;
         l_existing_inf_id     MI_REQ.INF_ID%TYPE;
         l_existing_status_cd  MI_REQ.STATUS_CD%TYPE;
         l_existing_req_uuid   MI_REQ.EXTERNAL_UUID%TYPE;
         l_existing_item_uuid  MI_0600.EXTERNAL_UUID%TYPE;
         l_archive_updated     BOOLEAN := FALSE;
         l_reset_result        MI_ResultCtx.exec_Result_t;
      BEGIN
         BEGIN
            SELECT REQ_ID,
                   ITM_ID
              INTO l_existing_req_id,
                   l_existing_itm_id
              FROM MI_0600
             WHERE CZIP_NAME = l_czip_name;

         EXCEPTION
            WHEN NO_DATA_FOUND THEN
               RETURN FALSE;
         END;

         /* Match the global lock order used by MI_Item_Result_Api. */
         SELECT INF_ID,
                STATUS_CD,
                EXTERNAL_UUID,
                CORRELATION_ID
           INTO l_existing_inf_id,
                l_existing_status_cd,
                l_existing_req_uuid,
                l_correlation_id
           FROM MI_REQ
          WHERE REQ_ID = l_existing_req_id
            FOR UPDATE;

         SELECT EXTERNAL_UUID
           INTO l_existing_item_uuid
           FROM MI_0600
          WHERE ITM_ID = l_existing_itm_id
            AND REQ_ID = l_existing_req_id
            AND CZIP_NAME = l_czip_name
            FOR UPDATE;

         /*
            Never rewrite an archive already being processed or sent.
            Capture retry may refresh only a still-pending/failed request.
         */
         IF l_existing_status_cd IN (
               MI_Request_Api.STATUS_NEW,
               MI_Request_Api.STATUS_ERROR
            )
         THEN
            UPDATE MI_0600
               SET BZIP_DATA        = p_bzip_data,
                   IZIP_SIZE        = l_zip_size,
                   IZIP_FILES_COUNT = l_zip_files_count,
                   ICREATE_TYPE     = NVL(p_icreate_type, 0)
             WHERE ITM_ID = l_existing_itm_id;

            replace_File_Names(
               p_itm_id     => l_existing_itm_id,
               p_file_names => p_file_names
            );

            IF l_existing_status_cd = MI_Request_Api.STATUS_ERROR THEN
               l_reset_result :=
                  MI_Request_Api.reset(
                     p_req_id => l_existing_req_id,
                     p_info   => 'MI_0600 archive recaptured'
                  );

               MI_ResultCtx.raise_Error(l_reset_result);
               l_existing_status_cd := MI_Request_Api.STATUS_NEW;
            END IF;

            l_archive_updated := TRUE;
         END IF;

         l_req_id       := l_existing_req_id;
         l_itm_id       := l_existing_itm_id;
         l_request_uuid := l_existing_req_uuid;
         l_item_uuid    := l_existing_item_uuid;
         l_status_cd    := l_existing_status_cd;

         l_log.context(
            p_inf_id         => l_existing_inf_id,
            p_req_id         => l_existing_req_id,
            p_itm_id         => l_existing_itm_id,
            p_correlation_id => l_correlation_id
         );

         l_log.info(
            p_message_text => 'Existing archive request reused',
            p_action_code  => 'reuse_archive',
            p_details_text =>
               TO_CLOB(
                     'status_cd='
                  || l_existing_status_cd
                  || ', archive_updated='
                  || MI_Utils.to_Char(l_archive_updated)
               )
         );

         l_result :=
            success_Result(
               p_code            => 'MI_0600_REQUEST_REUSED',
               p_info            => 'Existing archive request reused',
               p_ret_code        => RET_OK,
               p_req_id          => l_existing_req_id,
               p_itm_id          => l_existing_itm_id,
               p_request_uuid    => l_existing_req_uuid,
               p_item_uuid       => l_existing_item_uuid,
               p_idempotent      => TRUE,
               p_archive_updated => l_archive_updated
            );

         l_result.parameters('status_cd') :=
            TO_CHAR(l_existing_status_cd);

         RETURN TRUE;
      END reuse_Archive;


      ------------------------------------------------------------------------
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

         l_log.context(
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

      l_czip_name := TRIM(p_czip_name);

      IF p_inf_id IS NULL OR NOT is_Supported_Inf(p_inf_id) THEN
         RETURN
            failure_Result(
               p_code => 'MI_0600_INVALID_INF_ID',
               p_info =>
                     'Unsupported inf_id='
                  || NVL(TO_CHAR(p_inf_id), '<NULL>')
                  || '; expected 601, 602, 603, 604, 611 or 612'
            );
      END IF;

      IF l_czip_name IS NULL THEN
         RETURN
            failure_Result(
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

      IF p_original_req_uuid IS NOT NULL
         AND NOT MI_Utils.is_Uuid(p_original_req_uuid)
      THEN
         RETURN
            failure_Result(
               p_code => 'MI_0600_INVALID_ORIGINAL_UUID',
               p_info => 'p_original_req_uuid must be a valid UUID'
            );
      END IF;

      IF p_message_uuid IS NOT NULL
         AND NOT MI_Utils.is_Uuid(p_message_uuid)
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

      l_log.enter_f(
         p_function_name => 'create_Request',
         p_message_text  =>
               'inf_id='
            || p_inf_id
            || ', zip='
            || l_czip_name
      );

      DCL.SavePoint(l_savepoint_name);

      IF is_Initiator_Inf(p_inf_id) AND reuse_Archive THEN
         l_log.exit_f(
            p_function_name => 'create_Request',
            p_message_text  => l_result.result_code
         );

         RETURN l_result;
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
         rollback_Own_Work;

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

      replace_File_Names(
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
      WHEN DUP_VAL_ON_INDEX THEN
         l_sqlcode := SQLCODE;
         l_sqlerrm := SQLERRM;

         rollback_Own_Work;

         /*
            The unique CZIP_NAME constraint closes the race between two
            concurrent initiator capture workers. After the conflicting
            transaction commits, reuse the row it created.
         */
         IF is_Initiator_Inf(p_inf_id) THEN
            DCL.SavePoint(l_savepoint_name);

            IF reuse_Archive THEN
               l_log.exit_f(
                  p_function_name => 'create_Request',
                  p_message_text  => l_result.result_code
               );

               RETURN l_result;
            END IF;
         END IF;

         rollback_Own_Work;

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

         rollback_Own_Work;

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


   ---------------------------------------------------------------------------
   PROCEDURE create_Request (
      p_inf_id                IN MI_REQ.INF_ID%TYPE,
      p_czip_name             IN MI_0600.CZIP_NAME%TYPE,
      p_bzip_data             IN MI_0600.BZIP_DATA%TYPE,
      p_izip_size             IN MI_0600.IZIP_SIZE%TYPE,
      p_izip_files_count      IN MI_0600.IZIP_FILES_COUNT%TYPE,
      p_file_names            IN SYS.ODCIVARCHAR2LIST,

      p_original_req_uuid     IN MI_REQ.ORIGINAL_REQ_UUID%TYPE,
      p_message_uuid          IN MI_REQ.MESSAGE_UUID%TYPE,
      p_ctaxreq_id            IN MI_REQ.CTAXREQ_ID%TYPE,
      p_icreate_type          IN MI_0600.ICREATE_TYPE%TYPE,

      p_req_id                OUT MI_REQ.REQ_ID%TYPE,
      p_itm_id                OUT MI_0600.ITM_ID%TYPE,
      p_ret_code              OUT NUMBER,
      p_ret_info              OUT VARCHAR2
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


   ---------------------------------------------------------------------------
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


   ---------------------------------------------------------------------------
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


   ---------------------------------------------------------------------------
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


   ---------------------------------------------------------------------------
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
         RAISE_APPLICATION_ERROR(
            -20021,
            'MI_0600 payload mapper supports JSON only'
         );
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
         p_cres_info :=
            TO_CLOB(NVL(l_message, 'Ошибка обработки запроса'));

         IF l_error_code IS NOT NULL THEN
            p_cres_info :=
               p_cres_info || TO_CLOB(' [' || l_error_code || ']');
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


   ---------------------------------------------------------------------------
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
