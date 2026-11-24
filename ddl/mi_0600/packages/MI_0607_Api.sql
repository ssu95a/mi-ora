CREATE OR REPLACE PACKAGE MI_0607_Api
IS

   /* MI-edo. DOCUMENT_RECEIVED видов сведений 607 и 608 */

   VERSION CONSTANT VARCHAR2(100) :=
      '$Id: {1.4.0} {24.11.2026} Sulimoff$';


   RET_FAIL               CONSTANT PLS_INTEGER := -1;
   RET_OK                 CONSTANT PLS_INTEGER :=  0;

   RET_CREATE_BASE_FAILED CONSTANT PLS_INTEGER :=  1;
   RET_DOC_TYPE_MISMATCH  CONSTANT PLS_INTEGER :=  2;
   RET_PARSING_FAILED     CONSTANT PLS_INTEGER :=  3;

   /* Legacy ABI constant. DOCUMENT_RECEIVED duplicates return RET_FAIL. */
   RET_EXISTS             CONSTANT PLS_INTEGER :=  4;


   /* */
   FUNCTION get_Version
      RETURN VARCHAR2;


   /*
      Приём DOCUMENT_RECEIVED вида сведений 607.

      Операция атомарно:

         1. журналирует входящее сообщение в MI_REQ;
         2. создаёт item в MI_0600;
         3. сохраняет исходное имя файла в MI_0600_F;
         4. вызывает RD_PKG.CreateBase;
         5. дополняет RSD_BASES транспортными metadata;
         6. вызывает RD_PKG.Parsing;
         7. записывает бизнес-результат в MI_0600.

      При business failure изменения RSD откатываются до внутреннего
      savepoint, но MI_REQ / MI_0600 остаются в текущей транзакции.

      При unexpected exception откатывается вся работа этой процедуры.

      ORIGINAL_REQ_UUID содержит requestId входящего документа и является
      ключом регистрации. Повторный requestId возвращает RET_FAIL; ранее
      созданные journal и business-данные не изменяются.

      При успешном RD_PKG.Parsing параметр p_parse_result содержит
      RSD_OUTFILES.ID созданного исходящего документа.

      COMMIT процедура не выполняет.
   */
   PROCEDURE process_Document_Received (
      p_original_req_uuid IN  MI_REQ.ORIGINAL_REQ_UUID%TYPE,
      p_message_uuid      IN  MI_REQ.MESSAGE_UUID%TYPE,
      p_correlation_id    IN  MI_REQ.CORRELATION_ID%TYPE,

      p_task_id           IN  RSD_BASES.TASKID%TYPE,
      p_doc_type          IN  RSD_BASES.FILE_TYPE%TYPE,
      p_doc_date          IN  RSD_BASES.DOCDATE%TYPE,

      p_file_name         IN  RSD_BASES.FILE_NAME%TYPE,
      p_file_body         IN  MI_0600.BZIP_DATA%TYPE,

      p_req_id            OUT MI_REQ.REQ_ID%TYPE,
      p_itm_id            OUT MI_0600.ITM_ID%TYPE,

      p_base_id           OUT RSD_BASES.ID%TYPE,
      p_file_type         OUT RSD_BASES.FILE_TYPE%TYPE,
      p_parse_result      OUT NUMBER,

      p_ret_code          OUT NUMBER,
      p_ret_info          OUT VARCHAR2
   );

   /* Общая обработка входящих ВС 607 и 608. */
   PROCEDURE process_Document_Received (
      p_original_req_uuid IN  MI_REQ.ORIGINAL_REQ_UUID%TYPE,
      p_message_uuid      IN  MI_REQ.MESSAGE_UUID%TYPE,
      p_correlation_id    IN  MI_REQ.CORRELATION_ID%TYPE,

      p_task_id           IN  RSD_BASES.TASKID%TYPE,
      p_doc_type          IN  RSD_BASES.FILE_TYPE%TYPE,
      p_doc_date          IN  RSD_BASES.DOCDATE%TYPE,

      p_file_name         IN  RSD_BASES.FILE_NAME%TYPE,
      p_file_body         IN  MI_0600.BZIP_DATA%TYPE,

      p_req_id            OUT MI_REQ.REQ_ID%TYPE,
      p_itm_id            OUT MI_0600.ITM_ID%TYPE,

      p_base_id           OUT RSD_BASES.ID%TYPE,
      p_file_type         OUT RSD_BASES.FILE_TYPE%TYPE,
      p_parse_result      OUT NUMBER,

      p_ret_code          OUT NUMBER,
      p_ret_info          OUT VARCHAR2,
      p_inf_id            IN  MI_REQ.INF_ID%TYPE
   );

END MI_0607_Api;
/
CREATE OR REPLACE PACKAGE BODY MI_0607_Api
IS

   cLogger CONSTANT VARCHAR2(64)        := 'mi.0607';
   cInf607 CONSTANT MI_REQ.INF_ID%TYPE := 607;
   cInf608 CONSTANT MI_REQ.INF_ID%TYPE := 608;

   /* глобальный логгер */
   g_log CONSTANT MI_Logger_T :=
      MI_Logger_T(
         p_logger_name  => cLogger,
         p_package_name => $$PLSQL_UNIT
      );

   /* версия */
   FUNCTION get_Version
      RETURN VARCHAR2
   IS
   BEGIN
      RETURN VERSION;
   END get_Version;


   /* Бросает именованную technical error через общий result context. */
   PROCEDURE raise_Technical_Error (
      p_code     IN VARCHAR2,
      p_info     IN VARCHAR2,
      p_details  IN CLOB DEFAULT NULL
   )
   IS
   BEGIN
      MI_ResultCtx.raise_Error(
         p_code    => p_code,
         p_info    => p_info,
         p_details => p_details
      );
   END raise_Technical_Error;


   /* */
   FUNCTION journal_Name (
      p_inf_id            IN MI_REQ.INF_ID%TYPE,
      p_original_req_uuid IN MI_REQ.ORIGINAL_REQ_UUID%TYPE
   )
      RETURN MI_0600.CZIP_NAME%TYPE
   IS
   BEGIN
      /*
         MI_0600.CZIP_NAME имеет глобальный UNIQUE constraint.

         Это технический ключ requestId входящего
         документа. Исходное имя документа хранится в MI_0600_F.
      */
      RETURN CASE p_inf_id WHEN cInf608 THEN 'MI_0608_' ELSE 'MI_0607_' END
             || LOWER(TRIM(p_original_req_uuid));
   END journal_Name;


   /* */
   PROCEDURE set_Item_Result (
      p_itm_id      IN MI_0600.ITM_ID%TYPE,
      p_ires_code   IN MI_0600.IRES_CODE%TYPE,
      p_error_code  IN MI_0600.ERROR_CODE%TYPE,
      p_info        IN CLOB
   )
   IS
   BEGIN
   
      UPDATE MI_0600
         SET IRES_CODE  = p_ires_code,
             ERROR_CODE = p_error_code,
             CRES_INFO  = p_info,
             TRES_TIME  = SYSTIMESTAMP
       WHERE ITM_ID = p_itm_id;

      IF SQL%ROWCOUNT <> 1 THEN
         raise_Technical_Error(
            p_code => 'MI_0607_ITEM_RESULT_NOT_UPDATED',
            p_info =>
                  'MI_0600 result update failed: itm_id='
               || p_itm_id
               || ', rows='
               || SQL%ROWCOUNT
         );
      END IF;
   END set_Item_Result;


   /* Проверяет регистрацию requestId входящего DOCUMENT_RECEIVED. */
   FUNCTION duplicate_Request_Exists (
      p_inf_id            IN MI_REQ.INF_ID%TYPE,
      p_original_req_uuid IN MI_REQ.ORIGINAL_REQ_UUID%TYPE
   )
      RETURN BOOLEAN
   IS
      l_request_count PLS_INTEGER;
   BEGIN
      SELECT COUNT(*)
        INTO l_request_count
        FROM MI_REQ r
       WHERE r.INF_ID = p_inf_id
         AND LOWER(TRIM(r.ORIGINAL_REQ_UUID)) = p_original_req_uuid;

      RETURN l_request_count > 0;
   END duplicate_Request_Exists;


   /* */
   PROCEDURE process_Document_Received (
      p_original_req_uuid IN  MI_REQ.ORIGINAL_REQ_UUID%TYPE,
      p_message_uuid      IN  MI_REQ.MESSAGE_UUID%TYPE,
      p_correlation_id    IN  MI_REQ.CORRELATION_ID%TYPE,

      p_task_id           IN  RSD_BASES.TASKID%TYPE,
      p_doc_type          IN  RSD_BASES.FILE_TYPE%TYPE,
      p_doc_date          IN  RSD_BASES.DOCDATE%TYPE,

      p_file_name         IN  RSD_BASES.FILE_NAME%TYPE,
      p_file_body         IN  MI_0600.BZIP_DATA%TYPE,

      p_req_id            OUT MI_REQ.REQ_ID%TYPE,
      p_itm_id            OUT MI_0600.ITM_ID%TYPE,

      p_base_id           OUT RSD_BASES.ID%TYPE,
      p_file_type         OUT RSD_BASES.FILE_TYPE%TYPE,
      p_parse_result      OUT NUMBER,

      p_ret_code          OUT NUMBER,
      p_ret_info          OUT VARCHAR2,
      p_inf_id            IN  MI_REQ.INF_ID%TYPE
   )
   IS
      l_doc_type            RSD_BASES.FILE_TYPE%TYPE;
      l_file_name           RSD_BASES.FILE_NAME%TYPE;
      l_journal_name        MI_0600.CZIP_NAME%TYPE;
      l_file_size           MI_0600.IZIP_SIZE%TYPE;

      l_message_uuid        MI_REQ.MESSAGE_UUID%TYPE;
      l_original_req_uuid   MI_REQ.ORIGINAL_REQ_UUID%TYPE;
      l_input_correlation   MI_REQ.CORRELATION_ID%TYPE;
      l_task_id             RSD_BASES.TASKID%TYPE;

      l_request_result      MI_ResultCtx.exec_Result_t;

      l_req_id              MI_REQ.REQ_ID%TYPE;
      l_itm_id              MI_0600.ITM_ID%TYPE;

      l_item_uuid           MI_0600.EXTERNAL_UUID%TYPE;
      l_correlation_id      MI_REQ.CORRELATION_ID%TYPE;

      l_base_id             RSD_BASES.ID%TYPE;
      l_file_type           RSD_BASES.FILE_TYPE%TYPE;
      l_parse_result        RSD_OUTFILES.ID%TYPE;

      l_err                 VARCHAR2(32767);

      l_own_savepoint       DCL.T_Name;
      l_business_savepoint  DCL.T_Name;

      l_sqlerrm             VARCHAR2(2000);
      l_rollback_ok         BOOLEAN;

      l_log                 MI_Logger_T := g_log;


      PROCEDURE return_Duplicate_Request
      IS
      BEGIN
         p_req_id       := NULL;
         p_itm_id       := NULL;
         p_base_id      := NULL;
         p_file_type    := NULL;
         p_parse_result := NULL;

         p_ret_code := RET_FAIL;
         p_ret_info :=
            SUBSTR(
                  'MI_0607_DUPLICATE_REQUEST: '
               || 'DOCUMENT_RECEIVED requestId already registered'
               || '; requestId='
               || l_original_req_uuid,
               1,
               4000
            );

         l_log.context(
            p_inf_id         => p_inf_id,
            p_correlation_id => l_input_correlation
         );

         l_log.warn(
            p_message_text => 'Duplicate DOCUMENT_RECEIVED rejected',
            p_action_code  => 'duplicate_request',
            p_details_text => TO_CLOB(p_ret_info)
         );

         l_log.exit_f(
            p_function_name => 'process_Document_Received',
            p_message_text  => 'MI_0607_DUPLICATE_REQUEST'
         );
      END return_Duplicate_Request;


      PROCEDURE return_Business_Failure (
         p_ret_code_value  IN PLS_INTEGER,
         p_error_code      IN MI_0600.ERROR_CODE%TYPE,
         p_info            IN VARCHAR2,
         p_log_message     IN VARCHAR2,
         p_action_code     IN VARCHAR2
      )
      IS
      BEGIN
         IF NOT MI_Transaction.rollback_Savepoint(
                   p_name => l_business_savepoint,
                   p_log  => l_log
                )
         THEN
            raise_Technical_Error(
               p_code => 'MI_0607_BUSINESS_ROLLBACK_FAILED',
               p_info =>
                  'Не удалось откатить изменения RSD; '
                  || 'требуется полный rollback транзакции'
            );
         END IF;

         set_Item_Result(
            p_itm_id     => l_itm_id,
            p_ires_code  => MI_Item_Result_Api.RESPONSE_FAIL,
            p_error_code => p_error_code,
            p_info       => TO_CLOB(p_info)
         );

         /* RSD_BASES откатан и его identifier больше не существует. */
         p_base_id      := NULL;
         p_file_type    := l_file_type;
         p_parse_result := NULL;

         p_ret_code := p_ret_code_value;
         p_ret_info := SUBSTR(p_info, 1, 4000);

         l_log.warn(
            p_message_text => p_log_message,
            p_action_code  => p_action_code,
            p_details_text => TO_CLOB(p_ret_info)
         );

         l_log.exit_f(
            p_function_name => 'process_Document_Received',
            p_message_text  => p_error_code
         );
      END return_Business_Failure;


   BEGIN

      -- OUT defaults
      p_req_id       := NULL;
      p_itm_id       := NULL;

      p_base_id      := NULL;
      p_file_type    := NULL;
      p_parse_result := NULL;

      p_ret_code     := RET_FAIL;
      p_ret_info     := NULL;

      IF p_inf_id IS NULL OR p_inf_id NOT IN (cInf607, cInf608) THEN
         p_ret_info := 'MI_0607_INVALID_INF_ID: expected 607 or 608';
         RETURN;
      END IF;

      l_message_uuid      := TRIM(p_message_uuid);
      l_original_req_uuid := LOWER(TRIM(p_original_req_uuid));
      l_input_correlation := TRIM(p_correlation_id);
      l_task_id           := TRIM(p_task_id);
      l_doc_type          := UPPER(TRIM(p_doc_type));
      l_file_name         := TRIM(p_file_name);


      l_log.context(
         p_inf_id         => p_inf_id,
         p_correlation_id => l_input_correlation
      );


      l_log.enter_f(
         p_function_name => 'process_Document_Received',
         p_message_text  =>
               'task_id='
            || l_task_id
            || ', file='
            || l_file_name
      );

      /* Проверяем transport contract до любого DML. */
      IF l_message_uuid IS NULL
         OR NOT MI_Utils.is_Uuid(l_message_uuid)
      THEN
         raise_Technical_Error(
            p_code => 'MI_0607_INVALID_MESSAGE_UUID',
            p_info => 'DOCUMENT_RECEIVED.message_uuid must be a valid UUID'
         );
      END IF;


      IF l_original_req_uuid IS NULL
         OR NOT MI_Utils.is_Uuid(l_original_req_uuid)
      THEN
         raise_Technical_Error(
            p_code => 'MI_0607_INVALID_ORIGINAL_UUID',
            p_info =>
               'DOCUMENT_RECEIVED.original_request_uuid must be a valid UUID'
         );
      END IF;


      IF l_input_correlation IS NOT NULL
         AND NOT MI_Utils.is_Uuid(l_input_correlation)
      THEN
         raise_Technical_Error(
            p_code => 'MI_0607_INVALID_CORRELATION_UUID',
            p_info => 'DOCUMENT_RECEIVED.correlation_id must be a valid UUID'
         );
      END IF;


      IF l_task_id IS NULL
         OR NOT MI_Utils.is_Uuid(l_task_id)
      THEN
         raise_Technical_Error(
            p_code => 'MI_0607_INVALID_TASK_ID',
            p_info => 'DOCUMENT_RECEIVED.taskId must be a valid UUID'
         );
      END IF;


      IF l_doc_type IS NULL OR l_doc_type NOT IN ('UNO', 'UPO') THEN
         raise_Technical_Error(
            p_code => 'MI_0607_INVALID_DOC_TYPE',
            p_info =>
                  'Unsupported DOCUMENT_RECEIVED.docType='
               || NVL(l_doc_type, '<NULL>')
               || '; expected UNO or UPO'
         );
      END IF;


      IF p_doc_date IS NULL THEN
         raise_Technical_Error(
            p_code => 'MI_0607_DOC_DATE_REQUIRED',
            p_info => 'DOCUMENT_RECEIVED.docDate must not be NULL'
         );
      END IF;


      IF l_file_name IS NULL THEN
         raise_Technical_Error(
            p_code => 'MI_0607_FILE_NAME_REQUIRED',
            p_info => 'DOCUMENT_RECEIVED.fileName must not be empty'
         );
      END IF;


      IF p_file_body IS NULL THEN
         raise_Technical_Error(
            p_code => 'MI_0607_FILE_REQUIRED',
            p_info => 'DOCUMENT_RECEIVED.file must not be empty'
         );
      END IF;

      l_file_size := DBMS_LOB.getlength(p_file_body);

      IF l_file_size = 0 THEN
         raise_Technical_Error(
            p_code => 'MI_0607_FILE_REQUIRED',
            p_info => 'DOCUMENT_RECEIVED.file must not be empty'
         );
      END IF;

      l_journal_name := journal_Name(p_inf_id, l_original_req_uuid);

      IF duplicate_Request_Exists(p_inf_id, l_original_req_uuid) THEN
         return_Duplicate_Request;
         RETURN;
      END IF;

      DCL.SavePoint(l_own_savepoint);


      -- 1. MI_REQ: durable integration journal header.
      l_request_result :=
         MI_Request_Api.create_Request(
            p_inf_id            => p_inf_id,
            p_correlation_id    => l_input_correlation,
            p_original_req_uuid => l_original_req_uuid,
            p_ctaxreq_id        => l_task_id,
            p_message_uuid      => l_message_uuid,

            /*
               Входящий business request уже принят транспортом.
               Business result хранится на item.
            */
            p_status_cd         => MI_Request_Api.STATUS_DONE
         );


      IF MI_ResultCtx.is_Failed(l_request_result) THEN
         /* MI_Request_Api converts INSERT failures to MI_ResultCtx. */
         l_rollback_ok :=
            MI_Transaction.rollback_Savepoint(
               p_name => l_own_savepoint,
               p_log  => l_log
            );
         l_business_savepoint := NULL;

         IF NOT l_rollback_ok THEN
            raise_Technical_Error(
               p_code => 'MI_0607_ROLLBACK_FAILED',
               p_info =>
                  'Не удалось откатить собственную работу после ошибки MI_REQ'
            );
         END IF;


         IF duplicate_Request_Exists(p_inf_id, l_original_req_uuid) THEN
            return_Duplicate_Request;
            RETURN;
         END IF;


         MI_ResultCtx.raise_Error(
            MI_ResultCtx.wrap_Exception(
               p_cause => l_request_result,
               p_code  => 'MI_0607_REQUEST_HEADER_FAILED',
               p_info  => 'Не удалось создать MI_REQ для DOCUMENT_RECEIVED'
            )
         );
      END IF;


      l_req_id :=
         TO_NUMBER(
            l_request_result.parameters('req_id')
         );

      l_correlation_id := l_request_result.parameters('correlation_id');


      IF l_req_id IS NULL THEN
         raise_Technical_Error(
            p_code => 'MI_0607_REQUEST_ID_MISSING',
            p_info => 'MI_Request_Api.create_Request returned NULL req_id'
         );
      END IF;


      -- 2. MI_0600: durable integration item + original payload.
      l_item_uuid := MI_Utils.uuid_V7;


      INSERT INTO MI_0600 (
         EXTERNAL_UUID,
         REQ_ID,

         CZIP_NAME,
         BZIP_DATA,
         IZIP_SIZE,
         IZIP_FILES_COUNT,

         ICREATE_TYPE,

         /*
            Для входящего DOCUMENT_RECEIVED это UUID transport message,
            которым item был создан и обработан.
         */
         MESSAGE_UUID
      )
      VALUES (
         l_item_uuid,
         l_req_id,

         l_journal_name,
         p_file_body,
         l_file_size,
         1,

         0,

         l_message_uuid
      )
      RETURNING ITM_ID
           INTO l_itm_id;


      -- Исходное имя входящего файла сохраняем отдельно.
      INSERT INTO MI_0600_F (
         ITM_ID,
         CZIP_FILE_NAME
      )
      VALUES (
         l_itm_id,
         l_file_name
      );


      p_req_id := l_req_id;
      p_itm_id := l_itm_id;


      l_log.context(
         p_inf_id         => p_inf_id,
         p_req_id         => l_req_id,
         p_itm_id         => l_itm_id,
         p_correlation_id => l_correlation_id
      );


      l_log.info(
         p_message_text => 'DOCUMENT_RECEIVED journal created',
         p_action_code  => 'journal'
      );


      ------------------------------------------------------------------------
      -- Everything below is business work.
      --
      -- Business failure must not remove MI_REQ / MI_0600.
      ------------------------------------------------------------------------
      DCL.SavePoint(l_business_savepoint);


      -- 3. Business module: create RSD_BASES.
      l_err       := NULL;
      l_file_type := NULL;


      l_base_id :=
         RD_PKG.CreateBase(
            pErr      => l_err,
            pFileType => l_file_type,
            pFName    => l_file_name,
            pFileBody => p_file_body,
            pStatus   => '4'
         );


      -- CreateBase business failure.
      IF l_base_id IS NULL THEN
         return_Business_Failure(
            p_ret_code_value => RET_CREATE_BASE_FAILED,
            p_error_code     => 'CREATE_BASE_FAILED',
            p_info           => NVL(l_err, 'RD_PKG.CreateBase failed'),
            p_log_message    => 'RD_PKG.CreateBase rejected DOCUMENT_RECEIVED', 
            p_action_code    => 'create_base_failed'
         );

         RETURN;
      END IF;


      -- 4. Payload docType must match the type detected from JSON content.
      l_file_type := UPPER(TRIM(l_file_type));


      IF l_file_type IS NULL OR l_file_type <> l_doc_type
      THEN
         return_Business_Failure(
            p_ret_code_value => RET_DOC_TYPE_MISMATCH,
            p_error_code     => 'DOC_TYPE_MISMATCH',
            p_info           =>
                  'DOCUMENT_RECEIVED docType='
               || l_doc_type
               || ', detected fileType='
               || NVL(l_file_type, '<NULL>'),
            p_log_message    => 'DOCUMENT_RECEIVED docType mismatch',
            p_action_code    => 'doc_type_mismatch'
         );

         RETURN;
         
      END IF;


      -- 5. CreateBase currently does not persist transport metadata.
      UPDATE RSD_BASES
         SET TASKID  = l_task_id,
             DOCDATE = p_doc_date
       WHERE ID = l_base_id;


      IF SQL%ROWCOUNT <> 1 THEN
         raise_Technical_Error(
            p_code => 'MI_0607_BASE_NOT_UPDATED',
            p_info =>
                  'RSD_BASES metadata update failed: id='
               || l_base_id
               || ', rows='
               || SQL%ROWCOUNT
         );
      END IF;


      -- 6. Run RSD business processing; result is created RSD_OUTFILES.ID.
      l_err          := NULL;
      l_parse_result := NULL;


      l_parse_result :=
         RD_PKG.Parsing (
            pErr         => l_err,
            ppID         => l_base_id,
            pOutFilename => NULL
         );


      -- Parsing business failure.
      IF l_parse_result IS NULL THEN
         return_Business_Failure(
            p_ret_code_value => RET_PARSING_FAILED,
            p_error_code     => 'PARSING_FAILED',
            p_info           => NVL(l_err, 'RD_PKG.Parsing failed'),
            p_log_message    => 'RD_PKG.Parsing rejected DOCUMENT_RECEIVED',
            p_action_code    => 'parsing_failed'
         );

         RETURN;
         
      END IF;


      -- 7. Successful business result.
      set_Item_Result(
         p_itm_id     => l_itm_id,
         p_ires_code  => MI_Item_Result_Api.RESPONSE_OK,
         p_error_code => NULL,
         p_info       =>
            CASE
               WHEN l_err IS NULL
               THEN NULL
               ELSE TO_CLOB(l_err)
            END
      );


      p_base_id      := l_base_id;
      p_file_type    := l_file_type;
      p_parse_result := l_parse_result;

      p_ret_code := RET_OK;

      p_ret_info := 'DOCUMENT_RECEIVED processed successfully';

      l_log.info(
         p_message_text => 'DOCUMENT_RECEIVED processed',
         p_action_code  => 'processed',
         p_details_text =>
            TO_CLOB(
                  'base_id='
               || l_base_id
               || ', file_type='
               || l_file_type
               || ', parse_result='
               || l_parse_result
            )
      );

      l_log.exit_f(
         p_function_name => 'process_Document_Received',
         p_message_text  => 'OK'
      );


   EXCEPTION
      ------------------------------------------------------------------------
      -- Concurrent duplicate requestId.
      --
      -- CZIP_NAME is derived from ORIGINAL_REQ_UUID and protected by a global
      -- UNIQUE constraint. Roll back our own header/item before reporting the
      -- duplicate through the JDBC return contract.
      ------------------------------------------------------------------------
      WHEN DUP_VAL_ON_INDEX THEN
      
         l_sqlerrm     := SQLERRM;
         l_rollback_ok :=
            MI_Transaction.rollback_Savepoint(
               p_name => l_own_savepoint,
               p_log  => l_log
            );
         l_business_savepoint := NULL;

         IF NOT l_rollback_ok THEN
            raise_Technical_Error(
               p_code    => 'MI_0607_ROLLBACK_FAILED',
               p_info    => 'Не удалось откатить собственную работу после unique conflict',
               p_details => TO_CLOB(l_sqlerrm)
            );
         END IF;


         IF duplicate_Request_Exists(p_inf_id, l_original_req_uuid) THEN
            return_Duplicate_Request;
            RETURN;
         END IF;


         l_log.error(
            p_message_text => 'Unexpected unique constraint conflict',
            p_action_code  => 'duplicate_conflict',
            p_details_text => TO_CLOB(l_sqlerrm)
         );


         RAISE;


      ------------------------------------------------------------------------
      -- Any unexpected Oracle failure is technical.
      --
      -- It must not be converted to a normal ret_code because the Java
      -- repository must perform full transaction rollback and retry/terminal
      -- classification at the integration layer.
      ------------------------------------------------------------------------
      WHEN OTHERS THEN
         l_sqlerrm     := SQLERRM;
         l_rollback_ok :=
            MI_Transaction.rollback_Savepoint(
               p_name => l_own_savepoint,
               p_log  => l_log
            );
         l_business_savepoint := NULL;

         l_log.error(
            p_message_text => 'process_Document_Received failed',
            p_action_code  => 'process',
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

         RAISE;
   END process_Document_Received;


   PROCEDURE process_Document_Received (
      p_original_req_uuid IN  MI_REQ.ORIGINAL_REQ_UUID%TYPE,
      p_message_uuid      IN  MI_REQ.MESSAGE_UUID%TYPE,
      p_correlation_id    IN  MI_REQ.CORRELATION_ID%TYPE,

      p_task_id           IN  RSD_BASES.TASKID%TYPE,
      p_doc_type          IN  RSD_BASES.FILE_TYPE%TYPE,
      p_doc_date          IN  RSD_BASES.DOCDATE%TYPE,

      p_file_name         IN  RSD_BASES.FILE_NAME%TYPE,
      p_file_body         IN  MI_0600.BZIP_DATA%TYPE,

      p_req_id            OUT MI_REQ.REQ_ID%TYPE,
      p_itm_id            OUT MI_0600.ITM_ID%TYPE,

      p_base_id           OUT RSD_BASES.ID%TYPE,
      p_file_type         OUT RSD_BASES.FILE_TYPE%TYPE,
      p_parse_result      OUT NUMBER,

      p_ret_code          OUT NUMBER,
      p_ret_info          OUT VARCHAR2
   )
   IS
   BEGIN
      process_Document_Received(
         p_original_req_uuid => p_original_req_uuid,
         p_message_uuid      => p_message_uuid,
         p_correlation_id    => p_correlation_id,
         p_task_id           => p_task_id,
         p_doc_type          => p_doc_type,
         p_doc_date          => p_doc_date,
         p_file_name         => p_file_name,
         p_file_body         => p_file_body,
         p_req_id            => p_req_id,
         p_itm_id            => p_itm_id,
         p_base_id           => p_base_id,
         p_file_type         => p_file_type,
         p_parse_result      => p_parse_result,
         p_ret_code          => p_ret_code,
         p_ret_info          => p_ret_info,
         p_inf_id            => cInf607
      );
   END process_Document_Received;

END MI_0607_Api;
/
