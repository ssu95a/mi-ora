CREATE OR REPLACE PACKAGE MI_0607_Api
IS

   VERSION CONSTANT VARCHAR2(100) := '$Id: {1.0.2} {14.11.2026} Sulimoff$';


   RET_FAIL               CONSTANT PLS_INTEGER := -1;
   RET_OK                 CONSTANT PLS_INTEGER :=  0;

   RET_CREATE_BASE_FAILED CONSTANT PLS_INTEGER :=  1;
   RET_DOC_TYPE_MISMATCH  CONSTANT PLS_INTEGER :=  2;
   RET_PARSING_FAILED     CONSTANT PLS_INTEGER :=  3;

   -- Идемпотентный повтор уже принятого DOCUMENT_RECEIVED.
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
      p_file_body         IN  BLOB,

      p_req_id            OUT MI_REQ.REQ_ID%TYPE,
      p_itm_id            OUT MI_0600.ITM_ID%TYPE,

      p_base_id           OUT RSD_BASES.ID%TYPE,
      p_file_type         OUT RSD_BASES.FILE_TYPE%TYPE,
      p_parse_result      OUT NUMBER,

      p_ret_code          OUT NUMBER,
      p_ret_info          OUT VARCHAR2
   );

END MI_0607_Api;
/
CREATE OR REPLACE PACKAGE BODY MI_0607_Api
IS


   cLogger CONSTANT VARCHAR2(64) := 'mi.0607';

   /* глобальный логгер */
   g_log CONSTANT MI_Logger_T := MI_Logger_T( p_logger_name  => cLogger, p_package_name => $$PLSQL_UNIT );

   /* версия */
   FUNCTION get_Version
      RETURN VARCHAR2
   IS
   BEGIN
      RETURN VERSION;
   END get_Version;


   /* */
   FUNCTION journal_Name (
      p_message_uuid IN MI_REQ.MESSAGE_UUID%TYPE
   )
      RETURN MI_0600.CZIP_NAME%TYPE
   IS
   BEGIN
      /*
         MI_0600.CZIP_NAME имеет глобальный UNIQUE constraint.

         Для 607 это не имя ZIP, а технический ключ входящего сообщения.
         Исходное имя документа хранится в MI_0600_F.
      */
      RETURN 'MI_0607_' || LOWER(TRIM(p_message_uuid));
      
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
       WHERE 
             ITM_ID = p_itm_id;

      IF SQL%ROWCOUNT <> 1 THEN
         RAISE_APPLICATION_ERROR( -20960, 'MI_0600 result update failed: itm_id=' || p_itm_id || ', rows=' || SQL%ROWCOUNT );
      END IF;
      
   END set_Item_Result;


   /* */
   FUNCTION find_Existing (
      p_journal_name  IN  MI_0600.CZIP_NAME%TYPE,

      p_req_id        OUT MI_REQ.REQ_ID%TYPE,
      p_itm_id        OUT MI_0600.ITM_ID%TYPE,
      p_ires_code     OUT MI_0600.IRES_CODE%TYPE,
      p_error_code    OUT MI_0600.ERROR_CODE%TYPE
   )
      RETURN BOOLEAN
   IS
   BEGIN
      p_req_id     := NULL;
      p_itm_id     := NULL;
      p_ires_code  := NULL;
      p_error_code := NULL;

      SELECT r.REQ_ID,
             i.ITM_ID,
             i.IRES_CODE,
             i.ERROR_CODE
        INTO p_req_id,
             p_itm_id,
             p_ires_code,
             p_error_code
        FROM MI_REQ r
        JOIN MI_0600 i
          ON i.REQ_ID = r.REQ_ID
       WHERE r.INF_ID = 607
         AND i.CZIP_NAME = p_journal_name;

      RETURN TRUE;

   EXCEPTION
      WHEN NO_DATA_FOUND THEN
         p_req_id     := NULL;
         p_itm_id     := NULL;
         p_ires_code  := NULL;
         p_error_code := NULL;

         RETURN FALSE;
   END find_Existing;


   /* */
   PROCEDURE process_Document_Received (
      p_original_req_uuid IN  MI_REQ.ORIGINAL_REQ_UUID%TYPE,
      p_message_uuid      IN  MI_REQ.MESSAGE_UUID%TYPE,
      p_correlation_id    IN  MI_REQ.CORRELATION_ID%TYPE,

      p_task_id           IN  RSD_BASES.TASKID%TYPE,
      p_doc_type          IN  RSD_BASES.FILE_TYPE%TYPE,
      p_doc_date          IN  RSD_BASES.DOCDATE%TYPE,

      p_file_name         IN  RSD_BASES.FILE_NAME%TYPE,
      p_file_body         IN  BLOB,

      p_req_id            OUT MI_REQ.REQ_ID%TYPE,
      p_itm_id            OUT MI_0600.ITM_ID%TYPE,

      p_base_id           OUT RSD_BASES.ID%TYPE,
      p_file_type         OUT RSD_BASES.FILE_TYPE%TYPE,
      p_parse_result      OUT NUMBER,

      p_ret_code          OUT NUMBER,
      p_ret_info          OUT VARCHAR2
   )
   IS
      l_doc_type            RSD_BASES.FILE_TYPE%TYPE;
      l_file_name           RSD_BASES.FILE_NAME%TYPE;
      l_journal_name        MI_0600.CZIP_NAME%TYPE;

      l_request_result      MI_ResultCtx.exec_Result_t;

      l_req_id              MI_REQ.REQ_ID%TYPE;
      l_itm_id              MI_0600.ITM_ID%TYPE;

      l_request_uuid        MI_REQ.EXTERNAL_UUID%TYPE;
      l_item_uuid           MI_0600.EXTERNAL_UUID%TYPE;
      l_correlation_id      MI_REQ.CORRELATION_ID%TYPE;

      l_base_id             RSD_BASES.ID%TYPE;
      l_file_type           RSD_BASES.FILE_TYPE%TYPE;
      l_parse_result        NUMBER;

      l_err                 VARCHAR2(4000);

      l_existing_ires       MI_0600.IRES_CODE%TYPE;
      l_existing_error      MI_0600.ERROR_CODE%TYPE;

      l_own_savepoint       DCL.T_Name;
      l_business_savepoint  DCL.T_Name;

      l_sqlcode             PLS_INTEGER;
      l_sqlerrm             VARCHAR2(2000);

      l_log                 MI_Logger_T := g_log;


      PROCEDURE rollback_Savepoint (
         p_name IN OUT DCL.T_Name
      )
      IS
         l_name         DCL.T_Name;
         l_rolled_back  BOOLEAN;
      BEGIN
         IF p_name IS NULL THEN
            RETURN;
         END IF;

         l_name := p_name;
         p_name := NULL;

         l_rolled_back := DCL.RollBack(l_name);

         IF NOT l_rolled_back THEN
            l_log.warn(
               p_message_text => 'DCL rollback was not performed',
               p_action_code  => 'rollback_skipped'
            );
         END IF;
      END rollback_Savepoint;


      PROCEDURE rollback_Own_Work
      IS
      BEGIN
         rollback_Savepoint(l_own_savepoint);
         /*
            После rollback до внешнего savepoint внутренний savepoint
            гарантированно больше использовать нельзя.
         */
         l_business_savepoint := NULL;
         
      END rollback_Own_Work;


      PROCEDURE rollback_Business_Work
      IS
      BEGIN
         rollback_Savepoint(l_business_savepoint);
      END rollback_Business_Work;


      PROCEDURE return_Existing
      IS
      BEGIN
         p_req_id       := l_req_id;
         p_itm_id       := l_itm_id;
         p_base_id      := NULL;
         p_file_type    := NULL;
         p_parse_result := NULL;

         p_ret_code := RET_EXISTS;

         p_ret_info :=
            SUBSTR(
                  'DOCUMENT_RECEIVED already processed'
               || '; req_id='
               || l_req_id
               || '; itm_id='
               || l_itm_id
               || CASE
                     WHEN l_existing_ires IS NOT NULL
                     THEN '; ires_code=' || l_existing_ires
                     ELSE NULL
                  END
               || CASE
                     WHEN l_existing_error IS NOT NULL
                     THEN '; error_code=' || l_existing_error
                     ELSE NULL
                  END,
               1,
               4000
            );

         l_log.context(
            p_inf_id         => 607,
            p_req_id         => l_req_id,
            p_itm_id         => l_itm_id,
            p_correlation_id => p_correlation_id
         );

         l_log.info(
            p_message_text => 'DOCUMENT_RECEIVED replay detected',
            p_action_code  => 'already_processed',
            p_details_text => TO_CLOB(p_ret_info)
         );
      END return_Existing;


   BEGIN

      -- OUT defaults
      p_req_id       := NULL;
      p_itm_id       := NULL;

      p_base_id      := NULL;
      p_file_type    := NULL;
      p_parse_result := NULL;

      p_ret_code     := RET_FAIL;
      p_ret_info     := NULL;


      -- Validate transport contract before any DML.
      IF p_message_uuid IS NULL OR NOT MI_Utils.is_Uuid(TRIM(p_message_uuid))
      THEN
         RAISE_APPLICATION_ERROR(  -20961, 'DOCUMENT_RECEIVED.message_uuid must be a valid UUID' );
      END IF;


      IF p_original_req_uuid IS NOT NULL
         AND NOT MI_Utils.is_Uuid(TRIM(p_original_req_uuid))
      THEN
         RAISE_APPLICATION_ERROR(
            -20962,
            'DOCUMENT_RECEIVED.original_request_uuid must be a valid UUID'
         );
      END IF;


      IF p_correlation_id IS NOT NULL
         AND NOT MI_Utils.is_Uuid(TRIM(p_correlation_id))
      THEN
         RAISE_APPLICATION_ERROR(
            -20963,
            'DOCUMENT_RECEIVED.correlation_id must be a valid UUID'
         );
      END IF;


      IF p_task_id IS NULL
         OR NOT MI_Utils.is_Uuid(TRIM(p_task_id))
      THEN
         RAISE_APPLICATION_ERROR(
            -20964,
            'DOCUMENT_RECEIVED.taskId must be a valid UUID'
         );
      END IF;


      l_doc_type :=
         UPPER(TRIM(p_doc_type));

      IF l_doc_type NOT IN ('UNO', 'UPO') THEN
         RAISE_APPLICATION_ERROR(
            -20965,
               'Unsupported DOCUMENT_RECEIVED.docType='
            || NVL(l_doc_type, '<NULL>')
            || '; expected UNO or UPO'
         );
      END IF;


      IF p_doc_date IS NULL THEN
         RAISE_APPLICATION_ERROR(
            -20966,
            'DOCUMENT_RECEIVED.docDate must not be NULL'
         );
      END IF;


      l_file_name :=
         TRIM(p_file_name);

      IF l_file_name IS NULL THEN
         RAISE_APPLICATION_ERROR(
            -20967,
            'DOCUMENT_RECEIVED.fileName must not be empty'
         );
      END IF;


      IF p_file_body IS NULL
         OR DBMS_LOB.getlength(p_file_body) = 0
      THEN
         RAISE_APPLICATION_ERROR(
            -20968,
            'DOCUMENT_RECEIVED.file must not be empty'
         );
      END IF;


      l_journal_name :=
         journal_Name(p_message_uuid);


      ------------------------------------------------------------------------
      -- Idempotent replay before any DML.
      ------------------------------------------------------------------------
      IF find_Existing(
            p_journal_name => l_journal_name,
            p_req_id       => l_req_id,
            p_itm_id       => l_itm_id,
            p_ires_code    => l_existing_ires,
            p_error_code   => l_existing_error
         )
      THEN
         return_Existing;
         RETURN;
      END IF;


      ------------------------------------------------------------------------
      -- Everything created by this API belongs to one caller transaction.
      ------------------------------------------------------------------------
      l_log.enter_f(
         p_function_name => 'process_Document_Received',
         p_message_text  =>
               'task_id='
            || TRIM(p_task_id)
            || ', file='
            || l_file_name
      );


      DCL.SavePoint(l_own_savepoint);


      ------------------------------------------------------------------------
      -- 1. MI_REQ: durable integration journal header.
      ------------------------------------------------------------------------
      l_request_result :=
         MI_Request_Api.create_Request(
            p_inf_id            => 607,
            p_correlation_id    => p_correlation_id,
            p_original_req_uuid => p_original_req_uuid,
            p_ctaxreq_id        => TRIM(p_task_id),
            p_message_uuid      => p_message_uuid,

            /*
               Входящий business request уже принят транспортом.
               Business result хранится на item.
            */
            p_status_cd         => MI_Request_Api.STATUS_DONE
         );


      IF MI_ResultCtx.is_Failed(l_request_result) THEN
         MI_ResultCtx.raise_Error(l_request_result);
      END IF;


      l_req_id :=
         TO_NUMBER(
            l_request_result.parameters('req_id')
         );

      l_request_uuid :=
         l_request_result.parameters('external_uuid');

      l_correlation_id :=
         l_request_result.parameters('correlation_id');


      IF l_req_id IS NULL THEN
         RAISE_APPLICATION_ERROR(
            -20969,
            'MI_Request_Api.create_Request returned NULL req_id'
         );
      END IF;


      ------------------------------------------------------------------------
      -- 2. MI_0600: durable integration item + original payload.
      ------------------------------------------------------------------------
      l_item_uuid :=
         MI_Utils.uuid_V7;


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
         DBMS_LOB.getlength(p_file_body),
         1,

         0,

         TRIM(p_message_uuid)
      )
      RETURNING ITM_ID
           INTO l_itm_id;


      ------------------------------------------------------------------------
      -- Исходное имя входящего файла сохраняем отдельно.
      ------------------------------------------------------------------------
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
         p_inf_id         => 607,
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


      ------------------------------------------------------------------------
      -- 3. Business module: create RSD_BASES.
      ------------------------------------------------------------------------
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


      ------------------------------------------------------------------------
      -- CreateBase business failure.
      ------------------------------------------------------------------------
      IF NVL(l_base_id, 0) = 0 THEN
         rollback_Business_Work;


         set_Item_Result(
            p_itm_id     => l_itm_id,
            p_ires_code  => RET_FAIL,
            p_error_code => 'CREATE_BASE_FAILED',
            p_info       =>
               TO_CLOB(
                  NVL(
                     l_err,
                     'RD_PKG.CreateBase failed'
                  )
               )
         );


         p_base_id      := NULL;
         p_file_type    := l_file_type;
         p_parse_result := NULL;

         p_ret_code :=
            RET_CREATE_BASE_FAILED;

         p_ret_info :=
            SUBSTR(
               NVL(
                  l_err,
                  'RD_PKG.CreateBase failed'
               ),
               1,
               4000
            );


         l_log.warn(
            p_message_text => 'RD_PKG.CreateBase rejected DOCUMENT_RECEIVED',
            p_action_code  => 'create_base_failed',
            p_details_text => TO_CLOB(p_ret_info)
         );


         l_log.exit_f(
            p_function_name => 'process_Document_Received',
            p_message_text  => 'CREATE_BASE_FAILED'
         );

         RETURN;
      END IF;


      ------------------------------------------------------------------------
      -- 4. Payload docType must match the type detected from JSON content.
      ------------------------------------------------------------------------
      l_file_type :=
         UPPER(TRIM(l_file_type));


      IF l_file_type IS NULL
         OR l_file_type <> l_doc_type
      THEN
         rollback_Business_Work;


         set_Item_Result(
            p_itm_id     => l_itm_id,
            p_ires_code  => RET_FAIL,
            p_error_code => 'DOC_TYPE_MISMATCH',
            p_info       =>
               TO_CLOB(
                     'DOCUMENT_RECEIVED docType='
                  || l_doc_type
                  || ', detected fileType='
                  || NVL(l_file_type, '<NULL>')
               )
         );


         /*
            RSD_BASES was rolled back, therefore p_base_id must not expose
            an identifier of a row that no longer exists.
         */
         p_base_id      := NULL;
         p_file_type    := l_file_type;
         p_parse_result := NULL;

         p_ret_code :=
            RET_DOC_TYPE_MISMATCH;

         p_ret_info :=
            SUBSTR(
                  'DOCUMENT_RECEIVED docType='
               || l_doc_type
               || ', detected fileType='
               || NVL(l_file_type, '<NULL>'),
               1,
               4000
            );


         l_log.warn(
            p_message_text => 'DOCUMENT_RECEIVED docType mismatch',
            p_action_code  => 'doc_type_mismatch',
            p_details_text => TO_CLOB(p_ret_info)
         );


         l_log.exit_f(
            p_function_name => 'process_Document_Received',
            p_message_text  => 'DOC_TYPE_MISMATCH'
         );

         RETURN;
      END IF;


      ------------------------------------------------------------------------
      -- 5. CreateBase currently does not persist transport metadata.
      ------------------------------------------------------------------------
      UPDATE RSD_BASES
         SET TASKID  = TRIM(p_task_id),
             DOCDATE = p_doc_date
       WHERE ID = l_base_id;


      IF SQL%ROWCOUNT <> 1 THEN
         RAISE_APPLICATION_ERROR(
            -20970,
               'RSD_BASES metadata update failed: id='
            || l_base_id
            || ', rows='
            || SQL%ROWCOUNT
         );
      END IF;


      ------------------------------------------------------------------------
      -- 6. Run RSD business processing.
      ------------------------------------------------------------------------
      l_err          := NULL;
      l_parse_result := NULL;


      l_parse_result :=
         RD_PKG.Parsing(
            pErr         => l_err,
            ppID         => l_base_id,
            pOutFilename => NULL
         );


      ------------------------------------------------------------------------
      -- Parsing business failure.
      ------------------------------------------------------------------------
      IF l_parse_result IS NULL THEN
         rollback_Business_Work;


         set_Item_Result(
            p_itm_id     => l_itm_id,
            p_ires_code  => RET_FAIL,
            p_error_code => 'PARSING_FAILED',
            p_info       =>
               TO_CLOB(
                  NVL(
                     l_err,
                     'RD_PKG.Parsing failed'
                  )
               )
         );


         /*
            RSD_BASES and all RSD_OUTFILES produced after the business
            savepoint are rolled back.
         */
         p_base_id      := NULL;
         p_file_type    := l_file_type;
         p_parse_result := NULL;

         p_ret_code :=
            RET_PARSING_FAILED;

         p_ret_info :=
            SUBSTR(
               NVL(
                  l_err,
                  'RD_PKG.Parsing failed'
               ),
               1,
               4000
            );


         l_log.warn(
            p_message_text => 'RD_PKG.Parsing rejected DOCUMENT_RECEIVED',
            p_action_code  => 'parsing_failed',
            p_details_text => TO_CLOB(p_ret_info)
         );


         l_log.exit_f(
            p_function_name => 'process_Document_Received',
            p_message_text  => 'PARSING_FAILED'
         );

         RETURN;
      END IF;


      ------------------------------------------------------------------------
      -- 7. Successful business result.
      ------------------------------------------------------------------------
      set_Item_Result(
         p_itm_id     => l_itm_id,
         p_ires_code  => RET_OK,
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

      p_ret_info :=
         'DOCUMENT_RECEIVED processed successfully';


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
      -- Concurrent replay.
      --
      -- CZIP_NAME is protected by global UNIQUE constraint. If another
      -- transaction created this message concurrently, rollback our own
      -- header/item and return the committed existing journal.
      ------------------------------------------------------------------------
      WHEN DUP_VAL_ON_INDEX THEN
         l_sqlcode := SQLCODE;
         l_sqlerrm := SQLERRM;


         rollback_Own_Work;


         IF find_Existing(
               p_journal_name => l_journal_name,
               p_req_id       => l_req_id,
               p_itm_id       => l_itm_id,
               p_ires_code    => l_existing_ires,
               p_error_code   => l_existing_error
            )
         THEN
            return_Existing;
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
         l_sqlcode := SQLCODE;
         l_sqlerrm := SQLERRM;


         rollback_Own_Work;


         l_log.error(
            p_message_text => 'process_Document_Received failed',
            p_action_code  => 'process',
            p_details_text =>
               TO_CLOB(
                     l_sqlerrm
                  || CHR(10)
                  || DBMS_UTILITY.format_error_backtrace
               )
         );


         RAISE;
   END process_Document_Received;


END MI_0607_Api;
/
