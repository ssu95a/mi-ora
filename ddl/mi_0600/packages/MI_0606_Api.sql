CREATE OR REPLACE PACKAGE MI_0606_Api
IS

   VERSION CONSTANT VARCHAR2(100) :=
      '$Id: {1.2.1} {19.11.2026} Sulimoff$';


   ---------------------------------------------------------------------------
   -- Коды результата JDBC boundary.
   ---------------------------------------------------------------------------
   RET_FAIL                  CONSTANT PLS_INTEGER := -1;
   RET_OK                    CONSTANT PLS_INTEGER :=  0;
   RET_NO_DATA               CONSTANT PLS_INTEGER :=  1;
   RET_BAD_STATE             CONSTANT PLS_INTEGER :=  2;
   RET_UNSUPPORTED_FILE_TYPE CONSTANT PLS_INTEGER :=  3;
   RET_EXISTS                CONSTANT PLS_INTEGER :=  4;
   RET_ALREADY_APPLIED       CONSTANT PLS_INTEGER :=  5;
   RET_OTHER_APPLIED         CONSTANT PLS_INTEGER :=  6;

   /*
      RET_* describes expected source/protocol outcomes at the JDBC boundary.
      DB, transaction and internal-contract failures are raised as exceptions;
      the caller must roll back the whole transaction.
   */


   FUNCTION get_Version
      RETURN VARCHAR2;


   ---------------------------------------------------------------------------
   /*
      Создаёт исходящий request 606 из одной записи RSD_OUTFILES.

      Одна запись RSD_OUTFILES соответствует:
         одному MI_REQ;
         одному MI_0600 item;
         одному SEND_DOCUMENT.

      TASKID является повторяемым correlation identifier.
      Идентичность конкретного файла задаёт DOCKEY.
      Payload берётся только из FILEBODY; BINFILE не используется.

      Процедура:
         - блокирует RSD_OUTFILES;
         - создаёт MI_REQ со STATUS_NEW;
         - создаёт MI_0600;
         - сохраняет исходное имя в MI_0600_F;
         - переводит RSD_OUTFILES.REC_STATE из '0' в '2'.

      COMMIT процедура не выполняет.
   */
   PROCEDURE create_Request (
      p_outfile_id  IN  RSD_OUTFILES.ID%TYPE,

      p_req_id      OUT MI_REQ.REQ_ID%TYPE,
      p_itm_id      OUT MI_0600.ITM_ID%TYPE,

      p_ret_code    OUT NUMBER,
      p_ret_info    OUT VARCHAR2
   );

   ---------------------------------------------------------------------------
   /*
      Регистрирует pending RSD_OUTFILES для исходящего вида сведений 606.

      Все настройки читаются из MI_Prp для INF_ID=606:

         ENABLED            default 1
         CAPTURE_MAX_FILES  default 10
         CAPTURE_SCAN_MAX   default 1000

      CAPTURE_MAX_FILES ограничивает количество реально зарегистрированных
      SEND_DOCUMENT за один вызов.

      CAPTURE_SCAN_MAX ограничивает количество просмотренных source rows,
      чтобы ошибочные записи в начале очереди не блокировали обработку
      последующих документов и одновременно не было неограниченного scan.

      Конкурентные worker'ы разделяют source rows через
      FOR UPDATE SKIP LOCKED.

      COMMIT процедура не выполняет.
   */
   PROCEDURE capture_Pending (
      p_captured_count  OUT PLS_INTEGER,
      p_skipped_count   OUT PLS_INTEGER,

      p_ret_code        OUT NUMBER,
      p_ret_info        OUT VARCHAR2
   );

   ---------------------------------------------------------------------------
   /*
      Возвращает данные SEND_DOCUMENT для уже зарегистрированного request.

      FILE_BODY является snapshot, сохранённым в MI_0600.BZIP_DATA.
      Mutable RSD_OUTFILES при retry не перечитывается.
   */
   PROCEDURE prepare_Send_Document (
      p_req_id       IN  MI_REQ.REQ_ID%TYPE,

      p_task_id      OUT VARCHAR2,
      p_doc_key      OUT VARCHAR2,
      p_doc_type     OUT VARCHAR2,
      p_error_code   OUT VARCHAR2,
      p_file_name    OUT VARCHAR2,
      p_file_body    OUT BLOB,

      p_ret_code     OUT NUMBER,
      p_ret_info     OUT VARCHAR2
   );


   ---------------------------------------------------------------------------
   /*
      Ответ DOCUMENT_SUBMITTED на SEND_DOCUMENT.

      SUCCESS является промежуточным ACK:
         request остаётся SENT.

      ERROR / VALIDATION_ERROR считаются терминальным business outcome:
         item -> FAIL;
         request -> DONE.

      Переход RSD_OUTFILES.REC_STATE из 2 в 5 здесь пока не выполняется:
      terminal semantics source row требует отдельного подтверждения.
   */
   PROCEDURE apply_Document_Submitted (
      p_request_uuid   IN  MI_REQ.EXTERNAL_UUID%TYPE,
      p_message_uuid   IN  MI_REQ.MESSAGE_UUID%TYPE,
      p_doc_key        IN  MI_0600.EXTERNAL_UUID%TYPE,

      p_status         IN  VARCHAR2,
      p_response_time  IN  TIMESTAMP WITH TIME ZONE,

      p_req_id         OUT MI_REQ.REQ_ID%TYPE,
      p_itm_id         OUT MI_0600.ITM_ID%TYPE,

      p_ret_code       OUT NUMBER,
      p_ret_info       OUT VARCHAR2
   );


   ---------------------------------------------------------------------------
   /*
      Терминальный DOCUMENT_STATUS.

      PROCESSED:
         item -> OK;
         request -> DONE.

      ERROR_STATE / ERROR_INTERNAL / ERROR_PROCESSING:
         item -> FAIL;
         request -> DONE.

      Переход RSD_OUTFILES.REC_STATE из 2 в 5 пока не выполняется.
   */
   PROCEDURE apply_Document_Status (
      p_message_uuid   IN  MI_REQ.MESSAGE_UUID%TYPE,
      p_doc_key        IN  MI_0600.EXTERNAL_UUID%TYPE,

      p_state          IN  VARCHAR2,
      p_message        IN  VARCHAR2,
      p_response_time  IN  TIMESTAMP WITH TIME ZONE,

      p_req_id         OUT MI_REQ.REQ_ID%TYPE,
      p_itm_id         OUT MI_0600.ITM_ID%TYPE,

      p_ret_code       OUT NUMBER,
      p_ret_info       OUT VARCHAR2
   );


   ---------------------------------------------------------------------------
   /*
      Терминальный protocol FAULT.

      FAULT является валидным business/protocol outcome:
         item -> FAIL;
         request -> DONE.

      Это не MI_REQ.STATUS_ERROR.

      Переход RSD_OUTFILES.REC_STATE из 2 в 5 пока не выполняется.
   */
   PROCEDURE apply_Fault (
      p_request_uuid   IN  MI_REQ.EXTERNAL_UUID%TYPE,
      p_message_uuid   IN  MI_REQ.MESSAGE_UUID%TYPE,

      p_fault_code     IN  VARCHAR2,
      p_details        IN  VARCHAR2,
      p_response_time  IN  TIMESTAMP WITH TIME ZONE,

      p_req_id         OUT MI_REQ.REQ_ID%TYPE,
      p_itm_id         OUT MI_0600.ITM_ID%TYPE,

      p_ret_code       OUT NUMBER,
      p_ret_info       OUT VARCHAR2
   );

END MI_0606_Api;
/
CREATE OR REPLACE PACKAGE BODY MI_0606_Api
IS

   cLogger CONSTANT VARCHAR2(64) := 'mi.0606';
   cInfId  CONSTANT MI_REQ.INF_ID%TYPE := 606;

   cFileTypePb2 CONSTANT RSD_OUTFILES.FILE_TYPE%TYPE := 'PB2';
   cDocTypePb2  CONSTANT VARCHAR2(100) := 'IMPOSSIBILITY_RESPONSE';

   /* Глобальный logger для простых операций без локального context. */
   g_log CONSTANT MI_Logger_T := MI_Logger_T( p_logger_name => cLogger, p_package_name => $$PLSQL_UNIT );


   ---------------------------------------------------------------------------
   TYPE source_Row_t IS RECORD (
      id         RSD_OUTFILES.ID%TYPE,
      file_type  RSD_OUTFILES.FILE_TYPE%TYPE,
      file_name  RSD_OUTFILES.FILENAME%TYPE,
      rec_state  RSD_OUTFILES.REC_STATE%TYPE,
      file_body  RSD_OUTFILES.FILEBODY%TYPE,
      task_id    RSD_OUTFILES.TASKID%TYPE,
      doc_key    RSD_OUTFILES.DOCKEY%TYPE
   );
   
   
   /* */
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

   ---------------------------------------------------------------------------
   FUNCTION capture_Int_Property (
      p_name          IN VARCHAR2,
      p_default_value IN PLS_INTEGER,
      p_min_value     IN PLS_INTEGER,
      p_max_value     IN PLS_INTEGER
   )
      RETURN PLS_INTEGER
   IS
      l_raw    VARCHAR2(32767);
      l_value  NUMBER;
   BEGIN
      l_raw :=
         MI_Prp.get_Inf_Property(
            p_inf_id    => cInfId,
            p_prp_id    => p_name,
            p_def_value => TO_CHAR(p_default_value)
         );


      BEGIN
         l_value := TO_NUMBER(TRIM(l_raw));

      EXCEPTION
         WHEN VALUE_ERROR THEN
            raise_Technical_Error(
               p_code => 'MI_0606_INVALID_CAPTURE_PROPERTY',
               p_info =>
                     'Invalid '
                  || p_name
                  || '='
                  || NVL(l_raw, '<NULL>')
            );
      END;


      IF l_value <> TRUNC(l_value)
         OR l_value < p_min_value
         OR l_value > p_max_value
      THEN
         raise_Technical_Error(
            p_code => 'MI_0606_INVALID_CAPTURE_PROPERTY',
            p_info =>
                  'Invalid '
               || p_name
               || '='
               || NVL(l_raw, '<NULL>')
               || '; expected integer '
               || p_min_value
               || '..'
               || p_max_value
         );
      END IF;


      RETURN TRUNC(l_value);
   END capture_Int_Property;


   ---------------------------------------------------------------------------
   FUNCTION capture_Enabled
      RETURN BOOLEAN
   IS
      l_value VARCHAR2(32767);
   BEGIN
      l_value :=
         TRIM(
            MI_Prp.get_Inf_Property(
               p_inf_id    => cInfId,
               p_prp_id    => 'ENABLED',
               p_def_value => '1'
            )
         );


      IF l_value = '1' THEN
         RETURN TRUE;
      END IF;


      IF l_value = '0' THEN
         RETURN FALSE;
      END IF;


      raise_Technical_Error(
         p_code => 'MI_0606_INVALID_CAPTURE_PROPERTY',
         p_info =>
               'Invalid ENABLED='
            || NVL(l_value, '<NULL>')
            || '; expected 0 or 1'
      );


      RETURN FALSE; -- unreachable
   END capture_Enabled;



   /* */
   PROCEDURE rollback_Or_Raise (
      p_name  IN OUT DCL.T_Name,
      p_code  IN     VARCHAR2,
      p_info  IN     VARCHAR2
   )
   IS
   BEGIN
      IF NOT MI_Transaction.rollback_Savepoint(
                p_name => p_name,
                p_log  => g_log
             )
      THEN
         raise_Technical_Error(
            p_code => p_code,
            p_info => p_info
         );
      END IF;
   END rollback_Or_Raise;


   /* */
   FUNCTION journal_Name (
      p_outfile_id IN RSD_OUTFILES.ID%TYPE
   )
      RETURN MI_0600.CZIP_NAME%TYPE
   IS
   BEGIN
      /*
         CZIP_NAME исторически является именем ZIP и имеет global UNIQUE.

         Для 606 используем его как технический ключ source row.
         Исходное имя документа хранится в MI_0600_F.
      */
      RETURN 'MI_0606_'  || TO_CHAR(p_outfile_id);
      
   END journal_Name;


   /* */
   FUNCTION map_Doc_Type (
      p_file_type IN RSD_OUTFILES.FILE_TYPE%TYPE
   )
      RETURN VARCHAR2
   IS
      l_file_type RSD_OUTFILES.FILE_TYPE%TYPE;
   BEGIN
      l_file_type := UPPER(TRIM(p_file_type));

      /*
         Подтверждённый business mapping.

         Остальные mappings должны быть добавлены после согласования
         с разработчиком RD и после добавления в MI journal поля
         для snapshot разрешённого protocol mapping.
      */
      RETURN
         CASE l_file_type
            WHEN cFileTypePb2 THEN cDocTypePb2
            ELSE NULL
         END;
         
   END map_Doc_Type;


   /* */
   FUNCTION map_Error_Code (
      p_file_type IN RSD_OUTFILES.FILE_TYPE%TYPE
   )
      RETURN VARCHAR2
   IS
   BEGIN
      /*
         В первой версии подтверждённого mapping
         RSD_OUTFILES -> SEND_DOCUMENT.errorCode пока нет.
      */
      RETURN NULL;
   END map_Error_Code;


   /* */
   FUNCTION clob_To_Utf8_Blob (
      p_value IN CLOB
   )
      RETURN BLOB
   IS
      l_blob          BLOB;
      l_dest_offset   INTEGER := 1;
      l_src_offset    INTEGER := 1;
      l_lang_context  INTEGER := DBMS_LOB.DEFAULT_LANG_CTX;
      l_warning       INTEGER;
   BEGIN
      IF p_value IS NULL
         OR DBMS_LOB.getlength(p_value) = 0
      THEN
         RETURN NULL;
      END IF;


      DBMS_LOB.createTemporary(
         l_blob,
         TRUE,
         DBMS_LOB.CALL
      );


      DBMS_LOB.convertToBlob(
         dest_lob     => l_blob,
         src_clob     => p_value,
         amount       => DBMS_LOB.LOBMAXSIZE,
         dest_offset  => l_dest_offset,
         src_offset   => l_src_offset,
         blob_csid    => NLS_CHARSET_ID('AL32UTF8'),
         lang_context => l_lang_context,
         warning      => l_warning
      );


      IF l_warning IS NULL OR l_warning <> DBMS_LOB.NO_WARNING
      THEN
         raise_Technical_Error(
            p_code => 'MI_0606_CLOB_CONVERSION_WARNING',
            p_info => 'CLOB to UTF-8 BLOB conversion warning=' || l_warning
         );
      END IF;

      RETURN l_blob;


   EXCEPTION
      WHEN OTHERS THEN
         IF l_blob IS NOT NULL AND DBMS_LOB.isTemporary(l_blob) = 1
         THEN
            DBMS_LOB.freeTemporary(l_blob);
         END IF;

         RAISE;
         
   END clob_To_Utf8_Blob;


   /* */
   PROCEDURE free_Temporary_Blob (
      p_blob IN OUT NOCOPY BLOB
   )
   IS
   BEGIN
      IF p_blob IS NOT NULL
         AND DBMS_LOB.isTemporary(p_blob) = 1
      THEN
         DBMS_LOB.freeTemporary(p_blob);
      END IF;

      p_blob := NULL;
   END free_Temporary_Blob;


   /* */
   FUNCTION find_Existing_Source (
      p_outfile_id  IN  RSD_OUTFILES.ID%TYPE,

      p_req_id      OUT MI_REQ.REQ_ID%TYPE,
      p_itm_id      OUT MI_0600.ITM_ID%TYPE
   )
      RETURN BOOLEAN
   IS
      l_journal_name MI_0600.CZIP_NAME%TYPE;
   BEGIN
      p_req_id := NULL;
      p_itm_id := NULL;

      l_journal_name :=
         journal_Name(p_outfile_id);


      SELECT r.REQ_ID,
             i.ITM_ID
        INTO p_req_id,
             p_itm_id
        FROM MI_REQ r
        JOIN MI_0600 i
          ON i.REQ_ID = r.REQ_ID
       WHERE r.INF_ID = cInfId
         AND i.CZIP_NAME = l_journal_name;


      RETURN TRUE;


   EXCEPTION
      WHEN NO_DATA_FOUND THEN
         p_req_id := NULL;
         p_itm_id := NULL;

         RETURN FALSE;
   END find_Existing_Source;




   /* */
   PROCEDURE prepare_Send_Document (
      p_req_id       IN  MI_REQ.REQ_ID%TYPE,

      p_task_id      OUT VARCHAR2,
      p_doc_key      OUT VARCHAR2,
      p_doc_type     OUT VARCHAR2,
      p_error_code   OUT VARCHAR2,
      p_file_name    OUT VARCHAR2,
      p_file_body    OUT BLOB,

      p_ret_code     OUT NUMBER,
      p_ret_info     OUT VARCHAR2
   )
   IS
      l_journal_name MI_0600.CZIP_NAME%TYPE;
   BEGIN
      p_task_id    := NULL;
      p_doc_key    := NULL;
      p_doc_type   := NULL;
      p_error_code := NULL;
      p_file_name  := NULL;
      p_file_body  := NULL;

      p_ret_code   := RET_FAIL;
      p_ret_info   := NULL;


      IF p_req_id IS NULL THEN
         raise_Technical_Error(
            p_code => 'MI_0606_INVALID_REQUEST_ID',
            p_info => 'p_req_id must not be NULL'
         );
      END IF;


      BEGIN
         SELECT TRIM(r.CTAXREQ_ID),
                TRIM(i.EXTERNAL_UUID),
                TRIM(f.CZIP_FILE_NAME),
                i.BZIP_DATA,
                i.CZIP_NAME
           INTO p_task_id,
                p_doc_key,
                p_file_name,
                p_file_body,
                l_journal_name
           FROM MI_REQ r
           JOIN MI_0600 i
             ON i.REQ_ID = r.REQ_ID
           JOIN MI_0600_F f
             ON f.ITM_ID = i.ITM_ID
          WHERE r.REQ_ID = p_req_id
            AND r.INF_ID = cInfId;

      EXCEPTION
         WHEN NO_DATA_FOUND THEN
            p_ret_code := RET_NO_DATA;

            p_ret_info :=
               'SEND_DOCUMENT source not found: req_id='
               || p_req_id;

            RETURN;

         WHEN TOO_MANY_ROWS THEN
            raise_Technical_Error(
               p_code => 'MI_0606_MULTIPLE_FILES',
               p_info =>
                     'SEND_DOCUMENT journal contains multiple files: req_id='
                  || p_req_id
            );
      END;


      IF l_journal_name IS NULL
         OR SUBSTR(l_journal_name, 1, LENGTH('MI_0606_')) <> 'MI_0606_'
      THEN
         raise_Technical_Error(
            p_code => 'MI_0606_INVALID_JOURNAL_LINK',
            p_info =>
                  'Invalid SEND_DOCUMENT journal link: req_id='
               || p_req_id
         );
      END IF;


      IF p_task_id IS NULL
         OR NOT MI_Utils.is_Uuid(p_task_id)
         OR p_doc_key IS NULL
         OR NOT MI_Utils.is_Uuid(p_doc_key)
         OR p_file_name IS NULL
         OR p_file_body IS NULL
         OR DBMS_LOB.getlength(p_file_body) = 0
      THEN
         raise_Technical_Error(
            p_code => 'MI_0606_INCOMPLETE_JOURNAL',
            p_info =>
                  'SEND_DOCUMENT journal is incomplete: req_id='
               || p_req_id
         );
      END IF;


      /*
         Capture currently accepts only PB2. Therefore the resolved protocol
         value is immutable and does not require rereading mutable
         RSD_OUTFILES. Before another FILE_TYPE is accepted, the model must
         get a dedicated snapshot field for docType/errorCode.
      */
      p_doc_type   := cDocTypePb2;
      p_error_code := NULL;


      p_ret_code := RET_OK;
      p_ret_info := 'SEND_DOCUMENT prepared';

      g_log.debug(
         p_message_text => 'SEND_DOCUMENT prepared',
         p_action_code  => 'prepare',
         p_details_text => TO_CLOB('req_id=' || p_req_id)
      );

   EXCEPTION
      WHEN OTHERS THEN
         g_log.error(
            p_message_text => 'prepare_Send_Document failed',
            p_action_code  => 'prepare',
            p_details_text =>
               TO_CLOB(
                     SQLERRM
                  || CHR(10)
                  || DBMS_UTILITY.format_error_backtrace
               )
         );

         RAISE;
   END prepare_Send_Document;


   /*
      Находит request/item по request UUID и проверяет docKey.

      Lock order:
         MI_REQ
         MI_0600
   */
   PROCEDURE lock_By_Request (
      p_request_uuid   IN  MI_REQ.EXTERNAL_UUID%TYPE,
      p_doc_key        IN  MI_0600.EXTERNAL_UUID%TYPE,

      p_req_id         OUT MI_REQ.REQ_ID%TYPE,
      p_itm_id         OUT MI_0600.ITM_ID%TYPE,
      p_status_cd      OUT MI_REQ.STATUS_CD%TYPE,
      p_current_msg    OUT MI_0600.MESSAGE_UUID%TYPE,
      p_correlation_id OUT MI_REQ.CORRELATION_ID%TYPE
   )
   IS
      l_item_uuid MI_0600.EXTERNAL_UUID%TYPE;
   BEGIN
      SELECT REQ_ID,
             STATUS_CD,
             CORRELATION_ID
        INTO p_req_id,
             p_status_cd,
             p_correlation_id
        FROM MI_REQ
       WHERE INF_ID = cInfId
         AND EXTERNAL_UUID = TRIM(p_request_uuid)
         FOR UPDATE;


      SELECT ITM_ID,
             EXTERNAL_UUID,
             MESSAGE_UUID
        INTO p_itm_id,
             l_item_uuid,
             p_current_msg
        FROM MI_0600
       WHERE REQ_ID = p_req_id
         FOR UPDATE;


      IF p_doc_key IS NOT NULL
         AND TRIM(l_item_uuid) <> TRIM(p_doc_key)
      THEN
         raise_Technical_Error(
            p_code => 'MI_0606_DOC_KEY_MISMATCH',
            p_info =>
                  'SEND_DOCUMENT docKey mismatch: expected='
               || TRIM(l_item_uuid)
               || ', actual='
               || TRIM(p_doc_key)
         );
      END IF;
   END lock_By_Request;


   /* */
   PROCEDURE lock_By_Doc_Key (
      p_doc_key        IN  MI_0600.EXTERNAL_UUID%TYPE,

      p_req_id         OUT MI_REQ.REQ_ID%TYPE,
      p_itm_id         OUT MI_0600.ITM_ID%TYPE,
      p_status_cd      OUT MI_REQ.STATUS_CD%TYPE,
      p_current_msg    OUT MI_0600.MESSAGE_UUID%TYPE,
      p_correlation_id OUT MI_REQ.CORRELATION_ID%TYPE
   )
   IS
   BEGIN
      /*
         Сначала только разрешаем req_id.
         Блокировка request всегда должна быть первой.
      */
      SELECT REQ_ID,
             ITM_ID
        INTO p_req_id,
             p_itm_id
        FROM MI_0600
       WHERE EXTERNAL_UUID = TRIM(p_doc_key);


      SELECT STATUS_CD,
             CORRELATION_ID
        INTO p_status_cd,
             p_correlation_id
        FROM MI_REQ
       WHERE REQ_ID = p_req_id
         AND INF_ID = cInfId
         FOR UPDATE;


      SELECT MESSAGE_UUID
        INTO p_current_msg
        FROM MI_0600
       WHERE ITM_ID = p_itm_id
         AND REQ_ID = p_req_id
         FOR UPDATE;
   END lock_By_Doc_Key;


   /* */
   PROCEDURE apply_Terminal_Result (
      p_req_id          IN MI_REQ.REQ_ID%TYPE,
      p_itm_id          IN MI_0600.ITM_ID%TYPE,
      p_status_cd       IN MI_REQ.STATUS_CD%TYPE,
      p_current_msg     IN MI_0600.MESSAGE_UUID%TYPE,

      p_message_uuid    IN MI_REQ.MESSAGE_UUID%TYPE,

      p_ires_code       IN MI_0600.IRES_CODE%TYPE,
      p_error_code      IN MI_0600.ERROR_CODE%TYPE,
      p_info            IN CLOB,
      p_response_time   IN TIMESTAMP WITH TIME ZONE,

      p_ret_code        OUT NUMBER,
      p_ret_info        OUT VARCHAR2
   )
   IS
      l_transition MI_ResultCtx.exec_Result_t;
   BEGIN
      ------------------------------------------------------------------------
      -- Уже применённый terminal result.
      ------------------------------------------------------------------------
      IF p_current_msg IS NOT NULL THEN
         IF p_status_cd <> MI_Request_Api.STATUS_DONE THEN
            raise_Technical_Error(
               p_code => 'MI_0606_INCONSISTENT_RESULT',
               p_info =>
                  'Item has terminal MESSAGE_UUID but request is not DONE'
            );
         END IF;

         IF TRIM(p_current_msg) = TRIM(p_message_uuid) THEN
            p_ret_code :=
               RET_ALREADY_APPLIED;

            p_ret_info :=
               'Terminal result already applied';

            RETURN;
         END IF;


         p_ret_code := RET_OTHER_APPLIED;

         p_ret_info :=
               'Item result already applied by another message: '
            || TRIM(p_current_msg);

         RETURN;
      END IF;


      IF p_status_cd <> MI_Request_Api.STATUS_SENT THEN
         IF p_status_cd = MI_Request_Api.STATUS_DONE THEN
            raise_Technical_Error(
               p_code => 'MI_0606_INCONSISTENT_RESULT',
               p_info =>
                  'Request is DONE but item has no terminal MESSAGE_UUID'
            );
         END IF;

         p_ret_code := RET_BAD_STATE;

         p_ret_info :=
               'Request must be SENT, actual='
            || MI_Request_Api.status_Name(p_status_cd);

         RETURN;
      END IF;


      UPDATE MI_0600
         SET IRES_CODE    = p_ires_code,
             ERROR_CODE   = p_error_code,
             CRES_INFO    = p_info,
             TRES_TIME    = p_response_time,
             MESSAGE_UUID = TRIM(p_message_uuid)
       WHERE ITM_ID = p_itm_id
         AND MESSAGE_UUID IS NULL;


      IF SQL%ROWCOUNT <> 1 THEN
         raise_Technical_Error(
            p_code => 'MI_0606_ITEM_RESULT_NOT_UPDATED',
            p_info =>
                  'MI_0600 terminal result update failed: itm_id='
               || p_itm_id
         );
      END IF;


      /*
         MI request/item lifecycle завершён. RSD_OUTFILES.REC_STATE=5 здесь
         намеренно не устанавливается до подтверждения terminal source rules.
      */
      l_transition := MI_Request_Api.to_Success(p_req_id);


      IF MI_ResultCtx.is_Failed(l_transition) THEN
         MI_ResultCtx.raise_Error(
            MI_ResultCtx.wrap_Exception(
               p_cause => l_transition,
               p_code  => 'MI_0606_REQUEST_COMPLETE_FAILED',
               p_info  =>
                  'Не удалось завершить request после terminal response'
            )
         );
      END IF;


      p_ret_code := RET_OK;
      p_ret_info := 'Terminal result applied';
      
   END apply_Terminal_Result;


   /* */
   PROCEDURE apply_Document_Submitted (
      p_request_uuid   IN  MI_REQ.EXTERNAL_UUID%TYPE,
      p_message_uuid   IN  MI_REQ.MESSAGE_UUID%TYPE,
      p_doc_key        IN  MI_0600.EXTERNAL_UUID%TYPE,

      p_status         IN  VARCHAR2,
      p_response_time  IN  TIMESTAMP WITH TIME ZONE,

      p_req_id         OUT MI_REQ.REQ_ID%TYPE,
      p_itm_id         OUT MI_0600.ITM_ID%TYPE,

      p_ret_code       OUT NUMBER,
      p_ret_info       OUT VARCHAR2
   )
   IS
      l_status          VARCHAR2(30);

      l_status_cd       MI_REQ.STATUS_CD%TYPE;
      l_current_msg     MI_0600.MESSAGE_UUID%TYPE;
      l_correlation_id  MI_REQ.CORRELATION_ID%TYPE;

      l_savepoint       DCL.T_Name;
      l_rollback_ok     BOOLEAN;

      l_log             MI_Logger_T := g_log;


      PROCEDURE rollback_For_Result
      IS
      BEGIN
         rollback_Or_Raise(
            p_name => l_savepoint,
            p_code => 'MI_0606_SUBMITTED_ROLLBACK_FAILED',
            p_info => 'Не удалось завершить DOCUMENT_SUBMITTED без изменений; требуется полный rollback транзакции'
         );
      END rollback_For_Result;
      
   BEGIN
   
      p_req_id   := NULL;
      p_itm_id   := NULL;
      p_ret_code := RET_FAIL;
      p_ret_info := NULL;


      IF p_request_uuid IS NULL OR NOT MI_Utils.is_Uuid(TRIM(p_request_uuid))
      THEN
         raise_Technical_Error(
            p_code => 'MI_0606_INVALID_REQUEST_UUID',
            p_info => 'DOCUMENT_SUBMITTED request UUID must be valid'
         );
      END IF;


      IF p_message_uuid IS NULL OR NOT MI_Utils.is_Uuid(TRIM(p_message_uuid))
      THEN
         raise_Technical_Error(
            p_code => 'MI_0606_INVALID_MESSAGE_UUID',
            p_info => 'DOCUMENT_SUBMITTED message UUID must be valid'
         );
      END IF;


      IF p_doc_key IS NULL OR NOT MI_Utils.is_Uuid(TRIM(p_doc_key))
      THEN
         raise_Technical_Error(
            p_code => 'MI_0606_INVALID_DOC_KEY',
            p_info => 'DOCUMENT_SUBMITTED docKey must be valid'
         );
      END IF;


      IF p_response_time IS NULL THEN 
         raise_Technical_Error(
            p_code => 'MI_0606_RESPONSE_TIME_REQUIRED',
            p_info => 'DOCUMENT_SUBMITTED response_time must not be NULL'
         );
      END IF;


      l_status := UPPER(TRIM(p_status));


      IF l_status IS NULL OR l_status NOT IN ( 'SUCCESS', 'ERROR', 'VALIDATION_ERROR' )
      THEN
         raise_Technical_Error(
            p_code => 'MI_0606_UNSUPPORTED_SUBMITTED_STATUS',
            p_info => 'Unsupported DOCUMENT_SUBMITTED.status=' || NVL(l_status, '<NULL>')
         );
      END IF;


      DCL.SavePoint(l_savepoint);

      IF l_savepoint IS NULL THEN
         raise_Technical_Error(
            p_code => 'MI_0606_SUBMITTED_SAVEPOINT_UNAVAILABLE',
            p_info => 'DCL did not create the DOCUMENT_SUBMITTED savepoint'
         );
      END IF;


      BEGIN
      
         lock_By_Request(
            p_request_uuid => p_request_uuid,
            p_doc_key      => p_doc_key,

            p_req_id       => p_req_id,
            p_itm_id       => p_itm_id,
            p_status_cd    => l_status_cd,
            p_current_msg  => l_current_msg,
            p_correlation_id => l_correlation_id
         );

      EXCEPTION
         WHEN NO_DATA_FOUND THEN
         
            rollback_For_Result();

            p_ret_code := RET_NO_DATA;
            p_ret_info := 'SEND_DOCUMENT request/item not found';

            RETURN;
      END;


      l_log.context(
         p_inf_id         => cInfId,
         p_req_id         => p_req_id,
         p_itm_id         => p_itm_id,
         p_correlation_id => l_correlation_id
      );


      -- SUCCESS является промежуточным ACK.
      IF l_status = 'SUCCESS' THEN IF l_status_cd = MI_Request_Api.STATUS_SENT THEN

            rollback_For_Result();

            p_ret_code := RET_OK;
            p_ret_info := 'DOCUMENT_SUBMITTED SUCCESS accepted';

            l_log.info(
               p_message_text => p_ret_info,
               p_action_code  => 'submitted'
            );

            RETURN;
            
         END IF;


         IF l_status_cd = MI_Request_Api.STATUS_DONE THEN

            rollback_For_Result();

            p_ret_code := RET_ALREADY_APPLIED;
            p_ret_info := 'Request already completed';

            RETURN;
            
         END IF;

         rollback_For_Result();

         p_ret_code := RET_BAD_STATE;

         p_ret_info := 'Request must be SENT for DOCUMENT_SUBMITTED SUCCESS, actual=' || MI_Request_Api.status_Name(l_status_cd);

         RETURN;
         
      END IF;


      -- ERROR / VALIDATION_ERROR: текущий provisional terminal contract.
      apply_Terminal_Result(
         p_req_id        => p_req_id,
         p_itm_id        => p_itm_id,
         p_status_cd     => l_status_cd,
         p_current_msg   => l_current_msg,

         p_message_uuid  => p_message_uuid,

         p_ires_code     => MI_Item_Result_Api.RESPONSE_FAIL,
         p_error_code    => l_status,
         p_info          => TO_CLOB( 'DOCUMENT_SUBMITTED status=' || l_status ),
         p_response_time => p_response_time,

         p_ret_code      => p_ret_code,
         p_ret_info      => p_ret_info
      );


      IF p_ret_code IS NULL OR p_ret_code <> RET_OK 
      THEN         
         rollback_For_Result();
      ELSE
         l_log.info(
            p_message_text => 'DOCUMENT_SUBMITTED terminal result applied',
            p_action_code  => 'submitted_terminal',
            p_details_text => TO_CLOB('status=' || l_status)
         );
      END IF;


   EXCEPTION
      WHEN OTHERS THEN
         l_rollback_ok :=
            MI_Transaction.rollback_Savepoint(
               p_name => l_savepoint,
               p_log  => l_log
            );

         l_log.error(
            p_message_text => 'apply_Document_Submitted failed',
            p_action_code  => 'submitted',
            p_details_text => TO_CLOB( SQLERRM || CHR(10) || DBMS_UTILITY.format_error_backtrace || CHR(10) || 'own_rollback=' || MI_Utils.to_Char(l_rollback_ok) )
         );

         RAISE;
         
   END apply_Document_Submitted;


   /* */
   PROCEDURE apply_Document_Status (
      p_message_uuid   IN  MI_REQ.MESSAGE_UUID%TYPE,
      p_doc_key        IN  MI_0600.EXTERNAL_UUID%TYPE,

      p_state          IN  VARCHAR2,
      p_message        IN  VARCHAR2,
      p_response_time  IN  TIMESTAMP WITH TIME ZONE,

      p_req_id         OUT MI_REQ.REQ_ID%TYPE,
      p_itm_id         OUT MI_0600.ITM_ID%TYPE,

      p_ret_code       OUT NUMBER,
      p_ret_info       OUT VARCHAR2
   )
   IS
      l_state           VARCHAR2(30);

      l_status_cd       MI_REQ.STATUS_CD%TYPE;
      l_current_msg     MI_0600.MESSAGE_UUID%TYPE;
      l_correlation_id  MI_REQ.CORRELATION_ID%TYPE;

      l_ires_code       MI_0600.IRES_CODE%TYPE;
      l_error_code      MI_0600.ERROR_CODE%TYPE;

      l_savepoint       DCL.T_Name;
      l_rollback_ok     BOOLEAN;

      l_log             MI_Logger_T := g_log;


      PROCEDURE rollback_For_Result
      IS
      BEGIN
         rollback_Or_Raise(
            p_name => l_savepoint,
            p_code => 'MI_0606_STATUS_ROLLBACK_FAILED',
            p_info => 'Не удалось завершить DOCUMENT_STATUS без изменений; требуется полный rollback транзакции'
         );
      END rollback_For_Result;
      
   BEGIN
   
      p_req_id   := NULL;
      p_itm_id   := NULL;
      p_ret_code := RET_FAIL;
      p_ret_info := NULL;


      IF p_message_uuid IS NULL
         OR NOT MI_Utils.is_Uuid(TRIM(p_message_uuid))
      THEN
         raise_Technical_Error(
            p_code => 'MI_0606_INVALID_MESSAGE_UUID',
            p_info => 'DOCUMENT_STATUS message UUID must be valid'
         );
      END IF;


      IF p_doc_key IS NULL
         OR NOT MI_Utils.is_Uuid(TRIM(p_doc_key))
      THEN
         raise_Technical_Error(
            p_code => 'MI_0606_INVALID_DOC_KEY',
            p_info => 'DOCUMENT_STATUS docKey must be valid'
         );
      END IF;


      IF p_response_time IS NULL THEN
         raise_Technical_Error(
            p_code => 'MI_0606_RESPONSE_TIME_REQUIRED',
            p_info => 'DOCUMENT_STATUS response_time must not be NULL'
         );
      END IF;


      l_state :=
         UPPER(TRIM(p_state));


      IF l_state IS NULL
         OR l_state NOT IN (
            'PROCESSED',
            'ERROR_STATE',
            'ERROR_INTERNAL',
            'ERROR_PROCESSING'
         )
      THEN
         raise_Technical_Error(
            p_code => 'MI_0606_UNSUPPORTED_DOCUMENT_STATE',
            p_info =>
                  'Unsupported DOCUMENT_STATUS.state='
               || NVL(l_state, '<NULL>')
         );
      END IF;


      DCL.SavePoint(l_savepoint);

      IF l_savepoint IS NULL THEN
         raise_Technical_Error(
            p_code => 'MI_0606_STATUS_SAVEPOINT_UNAVAILABLE',
            p_info => 'DCL did not create the DOCUMENT_STATUS savepoint'
         );
      END IF;


      BEGIN
         lock_By_Doc_Key(
            p_doc_key       => p_doc_key,

            p_req_id        => p_req_id,
            p_itm_id        => p_itm_id,
            p_status_cd     => l_status_cd,
            p_current_msg   => l_current_msg,
            p_correlation_id => l_correlation_id
         );

      EXCEPTION
         WHEN NO_DATA_FOUND THEN
            rollback_For_Result;

            p_ret_code := RET_NO_DATA;
            p_ret_info := 'SEND_DOCUMENT item not found';

            RETURN;
      END;


      l_log.context(
         p_inf_id         => cInfId,
         p_req_id         => p_req_id,
         p_itm_id         => p_itm_id,
         p_correlation_id => l_correlation_id
      );


      IF l_state = 'PROCESSED' THEN
         l_ires_code  := MI_Item_Result_Api.RESPONSE_OK;
         l_error_code := NULL;
      ELSE
         l_ires_code  := MI_Item_Result_Api.RESPONSE_FAIL;
         l_error_code := l_state;
      END IF;


      apply_Terminal_Result(
         p_req_id        => p_req_id,
         p_itm_id        => p_itm_id,
         p_status_cd     => l_status_cd,
         p_current_msg   => l_current_msg,

         p_message_uuid  => p_message_uuid,

         p_ires_code     => l_ires_code,
         p_error_code    => l_error_code,
         p_info          =>
            CASE
               WHEN TRIM(p_message) IS NULL
               THEN TO_CLOB(l_state)
               ELSE TO_CLOB(TRIM(p_message))
            END,
         p_response_time => p_response_time,

         p_ret_code      => p_ret_code,
         p_ret_info      => p_ret_info
      );


      IF p_ret_code IS NULL OR p_ret_code <> RET_OK THEN
         rollback_For_Result;
      ELSE
         l_log.info(
            p_message_text => 'DOCUMENT_STATUS applied',
            p_action_code  => 'document_status',
            p_details_text => TO_CLOB('state=' || l_state)
         );
      END IF;


   EXCEPTION
      WHEN OTHERS THEN
         l_rollback_ok :=
            MI_Transaction.rollback_Savepoint(
               p_name => l_savepoint,
               p_log  => l_log
            );

         l_log.error(
            p_message_text => 'apply_Document_Status failed',
            p_action_code  => 'document_status',
            p_details_text =>
               TO_CLOB(
                     SQLERRM
                  || CHR(10)
                  || DBMS_UTILITY.format_error_backtrace
                  || CHR(10)
                  || 'own_rollback='
                  || MI_Utils.to_Char(l_rollback_ok)
               )
         );

         RAISE;
   END apply_Document_Status;


   /* */
   PROCEDURE apply_Fault (
      p_request_uuid   IN  MI_REQ.EXTERNAL_UUID%TYPE,
      p_message_uuid   IN  MI_REQ.MESSAGE_UUID%TYPE,

      p_fault_code     IN  VARCHAR2,
      p_details        IN  VARCHAR2,
      p_response_time  IN  TIMESTAMP WITH TIME ZONE,

      p_req_id         OUT MI_REQ.REQ_ID%TYPE,
      p_itm_id         OUT MI_0600.ITM_ID%TYPE,

      p_ret_code       OUT NUMBER,
      p_ret_info       OUT VARCHAR2
   )
   IS
      l_status_cd       MI_REQ.STATUS_CD%TYPE;
      l_current_msg     MI_0600.MESSAGE_UUID%TYPE;
      l_correlation_id  MI_REQ.CORRELATION_ID%TYPE;

      l_fault_code      VARCHAR2(100);

      l_savepoint       DCL.T_Name;
      l_rollback_ok     BOOLEAN;

      l_log             MI_Logger_T := g_log;


      PROCEDURE rollback_For_Result
      IS
      BEGIN
         rollback_Or_Raise(
            p_name => l_savepoint,
            p_code => 'MI_0606_FAULT_ROLLBACK_FAILED',
            p_info =>
               'Не удалось завершить FAULT без изменений; '
               || 'требуется полный rollback транзакции'
         );
      END rollback_For_Result;
   BEGIN
      p_req_id   := NULL;
      p_itm_id   := NULL;
      p_ret_code := RET_FAIL;
      p_ret_info := NULL;


      IF p_request_uuid IS NULL
         OR NOT MI_Utils.is_Uuid(TRIM(p_request_uuid))
      THEN
         raise_Technical_Error(
            p_code => 'MI_0606_INVALID_REQUEST_UUID',
            p_info => 'FAULT request UUID must be valid'
         );
      END IF;


      IF p_message_uuid IS NULL
         OR NOT MI_Utils.is_Uuid(TRIM(p_message_uuid))
      THEN
         raise_Technical_Error(
            p_code => 'MI_0606_INVALID_MESSAGE_UUID',
            p_info => 'FAULT message UUID must be valid'
         );
      END IF;


      IF p_response_time IS NULL THEN
         raise_Technical_Error(
            p_code => 'MI_0606_RESPONSE_TIME_REQUIRED',
            p_info => 'FAULT response_time must not be NULL'
         );
      END IF;


      l_fault_code :=
         UPPER(TRIM(p_fault_code));


      IF l_fault_code IS NULL THEN
         raise_Technical_Error(
            p_code => 'MI_0606_FAULT_CODE_REQUIRED',
            p_info => 'FAULT.faultCode must not be empty'
         );
      END IF;


      DCL.SavePoint(l_savepoint);

      IF l_savepoint IS NULL THEN
         raise_Technical_Error(
            p_code => 'MI_0606_FAULT_SAVEPOINT_UNAVAILABLE',
            p_info => 'DCL did not create the FAULT savepoint'
         );
      END IF;


      BEGIN
         lock_By_Request(
            p_request_uuid => p_request_uuid,
            p_doc_key      => NULL,

            p_req_id       => p_req_id,
            p_itm_id       => p_itm_id,
            p_status_cd    => l_status_cd,
            p_current_msg  => l_current_msg,
            p_correlation_id => l_correlation_id
         );

      EXCEPTION
         WHEN NO_DATA_FOUND THEN
            rollback_For_Result;

            p_ret_code := RET_NO_DATA;
            p_ret_info := 'SEND_DOCUMENT request not found';

            RETURN;
      END;


      l_log.context(
         p_inf_id         => cInfId,
         p_req_id         => p_req_id,
         p_itm_id         => p_itm_id,
         p_correlation_id => l_correlation_id
      );


      apply_Terminal_Result(
         p_req_id        => p_req_id,
         p_itm_id        => p_itm_id,
         p_status_cd     => l_status_cd,
         p_current_msg   => l_current_msg,

         p_message_uuid  => p_message_uuid,

         p_ires_code     => MI_Item_Result_Api.RESPONSE_FAIL,
         p_error_code    => l_fault_code,
         p_info          =>
            CASE
               WHEN TRIM(p_details) IS NULL
               THEN TO_CLOB(l_fault_code)
               ELSE TO_CLOB(TRIM(p_details))
            END,
         p_response_time => p_response_time,

         p_ret_code      => p_ret_code,
         p_ret_info      => p_ret_info
      );


      IF p_ret_code IS NULL OR p_ret_code <> RET_OK THEN
         rollback_For_Result;
      ELSE
         l_log.info(
            p_message_text => 'FAULT applied',
            p_action_code  => 'fault',
            p_details_text => TO_CLOB('fault_code=' || l_fault_code)
         );
      END IF;


   EXCEPTION
      WHEN OTHERS THEN
         l_rollback_ok :=
            MI_Transaction.rollback_Savepoint(
               p_name => l_savepoint,
               p_log  => l_log
            );

         l_log.error(
            p_message_text => 'apply_Fault failed',
            p_action_code  => 'fault',
            p_details_text => TO_CLOB( SQLERRM || CHR(10)  || DBMS_UTILITY.format_error_backtrace || CHR(10) || 'own_rollback=' || MI_Utils.to_Char(l_rollback_ok)  )
         );

         RAISE;
   END apply_Fault;


   ---------------------------------------------------------------------------
   PROCEDURE create_Request_Impl (
      p_source    IN  source_Row_t,

      p_req_id    OUT MI_REQ.REQ_ID%TYPE,
      p_itm_id    OUT MI_0600.ITM_ID%TYPE,

      p_ret_code  OUT NUMBER,
      p_ret_info  OUT VARCHAR2
   )
   IS
      l_file_name       RSD_OUTFILES.FILENAME%TYPE;
      l_task_id         RSD_OUTFILES.TASKID%TYPE;
      l_doc_key         RSD_OUTFILES.DOCKEY%TYPE;

      l_doc_type        VARCHAR2(100);
      l_error_code      VARCHAR2(100);

      l_payload         BLOB;
      l_payload_temp    BOOLEAN := FALSE;

      l_journal_name    MI_0600.CZIP_NAME%TYPE;

      l_request_result  MI_ResultCtx.exec_Result_t;
      l_correlation_id  MI_REQ.CORRELATION_ID%TYPE;

      l_log             MI_Logger_T := g_log;
   BEGIN
      p_req_id   := NULL;
      p_itm_id   := NULL;
      p_ret_code := RET_FAIL;
      p_ret_info := NULL;


      ------------------------------------------------------------------------
      -- Expected source-data failures должны определяться ДО первого DML.
      ------------------------------------------------------------------------
      IF p_source.id IS NULL THEN
         raise_Technical_Error(
            p_code => 'MI_0606_SOURCE_ID_MISSING',
            p_info => 'Internal source row has NULL ID'
         );
      END IF;


      IF p_source.rec_state IS NULL
         OR TRIM(p_source.rec_state) <> '0'
      THEN
         p_ret_code := RET_BAD_STATE;

         p_ret_info :=
               'RSD_OUTFILES has invalid REC_STATE='
            || NVL(TRIM(p_source.rec_state), '<NULL>')
            || ', expected 0; id='
            || p_source.id;

         RETURN;
      END IF;


      l_file_name := TRIM(p_source.file_name);
      l_task_id   := TRIM(p_source.task_id);
      l_doc_key   := TRIM(p_source.doc_key);


      IF l_file_name IS NULL THEN
         p_ret_code := RET_FAIL;
         p_ret_info := 'RSD_OUTFILES.FILENAME is empty; id=' || p_source.id;
         RETURN;
      END IF;


      IF l_task_id IS NULL
         OR NOT MI_Utils.is_Uuid(l_task_id)
      THEN
         p_ret_code := RET_FAIL;

         p_ret_info :=
               'RSD_OUTFILES.TASKID must be UUID: '
            || NVL(l_task_id, '<NULL>')
            || '; id='
            || p_source.id;

         RETURN;
      END IF;


      IF l_doc_key IS NULL
         OR NOT MI_Utils.is_Uuid(l_doc_key)
      THEN
         p_ret_code := RET_FAIL;

         p_ret_info :=
               'RSD_OUTFILES.DOCKEY must be UUID: '
            || NVL(l_doc_key, '<NULL>')
            || '; id='
            || p_source.id;

         RETURN;
      END IF;


      ------------------------------------------------------------------------
      -- Business mapping RSD -> SEND_DOCUMENT.
      ------------------------------------------------------------------------
      l_doc_type :=
         map_Doc_Type(p_source.file_type);

      l_error_code :=
         map_Error_Code(p_source.file_type);


      IF l_doc_type IS NULL
         AND l_error_code IS NULL
      THEN
         p_ret_code := RET_UNSUPPORTED_FILE_TYPE;

         p_ret_info :=
               'Unsupported RSD_OUTFILES.FILE_TYPE='
            || NVL(TRIM(p_source.file_type), '<NULL>')
            || '; id='
            || p_source.id;

         RETURN;
      END IF;


      /*
         Пока journal умеет без повторного чтения mutable RSD_OUTFILES
         воспроизвести только подтверждённый PB2 mapping.
      */
      IF l_doc_type IS NULL
         OR l_doc_type <> cDocTypePb2
         OR l_error_code IS NOT NULL
      THEN
         p_ret_code := RET_UNSUPPORTED_FILE_TYPE;

         p_ret_info :=
               'FILE_TYPE mapping has no durable MI journal snapshot'
            || '; id='
            || p_source.id;

         RETURN;
      END IF;


      ------------------------------------------------------------------------
      -- Payload snapshot.
      ------------------------------------------------------------------------
      IF p_source.file_body IS NOT NULL
         AND DBMS_LOB.getlength(p_source.file_body) > 0
      THEN
         l_payload :=
            clob_To_Utf8_Blob(p_source.file_body);

         l_payload_temp := TRUE;

      ELSE
         p_ret_code := RET_FAIL;

         p_ret_info :=
               'RSD_OUTFILES.FILEBODY is empty; id='
            || p_source.id;

         RETURN;
      END IF;


      ------------------------------------------------------------------------
      -- Всё ниже является единым durable DML.
      -- Ошибка здесь уже technical и должна RAISE.
      ------------------------------------------------------------------------
      l_request_result :=
         MI_Request_Api.create_Request(
            p_inf_id     => cInfId,
            p_ctaxreq_id => l_task_id,
            p_status_cd  => MI_Request_Api.STATUS_NEW
         );


      IF MI_ResultCtx.is_Failed(l_request_result) THEN
         MI_ResultCtx.raise_Error(
            MI_ResultCtx.wrap_Exception(
               p_cause => l_request_result,
               p_code  => 'MI_0606_REQUEST_HEADER_FAILED',
               p_info  => 'Не удалось создать MI_REQ для SEND_DOCUMENT'
            )
         );
      END IF;


      p_req_id :=
         TO_NUMBER(
            l_request_result.parameters('req_id')
         );

      l_correlation_id :=
         l_request_result.parameters('correlation_id');


      IF p_req_id IS NULL THEN
         raise_Technical_Error(
            p_code => 'MI_0606_REQUEST_ID_MISSING',
            p_info => 'MI_Request_Api.create_Request returned NULL req_id'
         );
      END IF;


      l_journal_name :=
         journal_Name(p_source.id);


      /*
         DOCKEY является business identity SEND_DOCUMENT.
         Поэтому MI_0600.EXTERNAL_UUID = DOCKEY.
      */
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
         l_doc_key,
         p_req_id,

         l_journal_name,
         l_payload,
         DBMS_LOB.getlength(l_payload),
         1,

         1
      )
      RETURNING ITM_ID
           INTO p_itm_id;


      INSERT INTO MI_0600_F (
         ITM_ID,
         CZIP_FILE_NAME
      )
      VALUES (
         p_itm_id,
         l_file_name
      );


      ------------------------------------------------------------------------
      -- Source становится captured только после создания полного MI journal.
      ------------------------------------------------------------------------
      UPDATE RSD_OUTFILES
         SET REC_STATE = '2'
       WHERE ID = p_source.id
         AND REC_STATE = '0';


      IF SQL%ROWCOUNT <> 1 THEN
         raise_Technical_Error(
            p_code => 'MI_0606_SOURCE_STATE_NOT_UPDATED',
            p_info =>
                  'RSD_OUTFILES state update failed: id='
               || p_source.id
               || ', rows='
               || SQL%ROWCOUNT
         );
      END IF;


      p_ret_code := RET_OK;
      p_ret_info := 'SEND_DOCUMENT request created';


      l_log.context(
         p_inf_id         => cInfId,
         p_req_id         => p_req_id,
         p_itm_id         => p_itm_id,
         p_correlation_id => l_correlation_id
      );


      l_log.info(
         p_message_text => 'SEND_DOCUMENT request created',
         p_action_code  => 'create',
         p_details_text =>
            TO_CLOB(
                  'RSD_OUTFILES.id='
               || p_source.id
               || ', docKey='
               || l_doc_key
               || ', fileType='
               || p_source.file_type
            )
      );


      IF l_payload_temp THEN
         free_Temporary_Blob(l_payload);
      END IF;


   EXCEPTION
      WHEN OTHERS THEN
         IF l_payload_temp THEN
            free_Temporary_Blob(l_payload);
         END IF;

         RAISE;
   END create_Request_Impl;


      ---------------------------------------------------------------------------
   PROCEDURE create_Request (
      p_outfile_id  IN  RSD_OUTFILES.ID%TYPE,

      p_req_id      OUT MI_REQ.REQ_ID%TYPE,
      p_itm_id      OUT MI_0600.ITM_ID%TYPE,

      p_ret_code    OUT NUMBER,
      p_ret_info    OUT VARCHAR2
   )
   IS
      l_source          source_Row_t;

      l_existing_req    MI_REQ.REQ_ID%TYPE;
      l_existing_itm    MI_0600.ITM_ID%TYPE;

      l_savepoint_name  DCL.T_Name;
      l_rollback_ok     BOOLEAN;

      l_sqlerrm         VARCHAR2(2000);
   BEGIN
      p_req_id   := NULL;
      p_itm_id   := NULL;
      p_ret_code := RET_FAIL;
      p_ret_info := NULL;


      IF p_outfile_id IS NULL THEN
         p_ret_code := RET_NO_DATA;
         p_ret_info := 'p_outfile_id must not be NULL';
         RETURN;
      END IF;


      DCL.SavePoint(l_savepoint_name);

      IF l_savepoint_name IS NULL THEN
         raise_Technical_Error(
            p_code => 'MI_0606_SAVEPOINT_UNAVAILABLE',
            p_info => 'DCL did not create the create_Request savepoint'
         );
      END IF;


      ------------------------------------------------------------------------
      -- Direct/manual call waits for the requested source row.
      ------------------------------------------------------------------------
      BEGIN
         SELECT ID,
                FILE_TYPE,
                FILENAME,
                REC_STATE,
                FILEBODY,
                TASKID,
                DOCKEY
           INTO l_source.id,
                l_source.file_type,
                l_source.file_name,
                l_source.rec_state,
                l_source.file_body,
                l_source.task_id,
                l_source.doc_key
           FROM RSD_OUTFILES
          WHERE ID = p_outfile_id
            FOR UPDATE;

      EXCEPTION
         WHEN NO_DATA_FOUND THEN
            rollback_Or_Raise(
               p_name => l_savepoint_name,
               p_code => 'MI_0606_CREATE_ROLLBACK_FAILED',
               p_info => 'Не удалось откатить create_Request'
            );

            p_ret_code := RET_NO_DATA;
            p_ret_info :=
               'RSD_OUTFILES row not found: id='
               || p_outfile_id;

            RETURN;
      END;


      ------------------------------------------------------------------------
      -- The source row is locked before replay classification. This prevents
      -- a REC_STATE=0 row with an existing journal from being silently
      -- accepted as an ordinary replay.
      ------------------------------------------------------------------------
      IF find_Existing_Source(
            p_outfile_id => p_outfile_id,
            p_req_id     => l_existing_req,
            p_itm_id     => l_existing_itm
         )
      THEN
         IF l_source.rec_state IS NULL
            OR TRIM(l_source.rec_state) NOT IN ('2', '5')
         THEN
            raise_Technical_Error(
               p_code => 'MI_0606_SOURCE_JOURNAL_INCONSISTENT',
               p_info =>
                     'MI journal exists for source with invalid REC_STATE'
                  || '; outfile_id='
                  || p_outfile_id
                  || '; rec_state='
                  || NVL(TRIM(l_source.rec_state), '<NULL>')
                  || '; req_id='
                  || l_existing_req
                  || '; itm_id='
                  || l_existing_itm
            );
         END IF;

         rollback_Or_Raise(
            p_name => l_savepoint_name,
            p_code => 'MI_0606_CREATE_ROLLBACK_FAILED',
            p_info => 'Не удалось откатить concurrent create_Request replay'
         );

         p_req_id   := l_existing_req;
         p_itm_id   := l_existing_itm;
         p_ret_code := RET_EXISTS;

         p_ret_info :=
               'RSD_OUTFILES already registered'
            || '; id='
            || p_outfile_id
            || '; req_id='
            || l_existing_req
            || '; itm_id='
            || l_existing_itm;

         RETURN;
      END IF;


      IF TRIM(l_source.rec_state) IN ('2', '5') THEN
         raise_Technical_Error(
            p_code => 'MI_0606_SOURCE_JOURNAL_INCONSISTENT',
            p_info =>
                  'Captured/completed source has no MI journal'
               || '; outfile_id='
               || p_outfile_id
               || '; rec_state='
               || TRIM(l_source.rec_state)
         );
      END IF;


      create_Request_Impl(
         p_source   => l_source,

         p_req_id   => p_req_id,
         p_itm_id   => p_itm_id,

         p_ret_code => p_ret_code,
         p_ret_info => p_ret_info
      );


      /*
         Expected source rejection не должен оставлять даже случайных
         изменений внутри wrapper.
      */
      IF p_ret_code <> RET_OK THEN
         rollback_Or_Raise(
            p_name => l_savepoint_name,
            p_code => 'MI_0606_CREATE_ROLLBACK_FAILED',
            p_info => 'Не удалось откатить rejected create_Request'
         );
      END IF;


   EXCEPTION
      WHEN OTHERS THEN
         l_sqlerrm := SQLERRM;

         l_rollback_ok :=
            MI_Transaction.rollback_Savepoint(
               p_name => l_savepoint_name,
               p_log  => g_log
            );


         g_log.error(
            p_message_text => 'create_Request failed',
            p_action_code  => 'create',
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
   END create_Request;


   ---------------------------------------------------------------------------
   PROCEDURE capture_Pending (
      p_captured_count  OUT PLS_INTEGER,
      p_skipped_count   OUT PLS_INTEGER,

      p_ret_code        OUT NUMBER,
      p_ret_info        OUT VARCHAR2
   )
   IS
      l_source            source_Row_t;

      l_req_id            MI_REQ.REQ_ID%TYPE;
      l_itm_id            MI_0600.ITM_ID%TYPE;

      l_existing_req_id   MI_REQ.REQ_ID%TYPE;
      l_existing_itm_id   MI_0600.ITM_ID%TYPE;

      l_row_ret_code      NUMBER;
      l_row_ret_info      VARCHAR2(4000);

      l_max_count         PLS_INTEGER;
      l_scan_max          PLS_INTEGER;

      l_scanned_count     PLS_INTEGER := 0;

      l_savepoint_name    DCL.T_Name;
      l_rollback_ok       BOOLEAN;
      l_sqlerrm           VARCHAR2(2000);

      l_log               MI_Logger_T := g_log;


      /*
         Не используем row limiting clause вместе с FOR UPDATE:
         Oracle 12.1 имеет ограничения на такую комбинацию.

         Cursor идёт по pending rows в ID order.
         CAPTURE_SCAN_MAX ограничивает реальное число FETCH.
      */
      CURSOR c_source
      IS
         SELECT ID,
                FILE_TYPE,
                FILENAME,
                REC_STATE,
                FILEBODY,
                TASKID,
                DOCKEY
           FROM RSD_OUTFILES
          WHERE REC_STATE = '0'
          ORDER BY ID
            FOR UPDATE SKIP LOCKED;


   BEGIN
      p_captured_count := 0;
      p_skipped_count  := 0;
      p_ret_code       := RET_FAIL;
      p_ret_info       := NULL;


      ------------------------------------------------------------------------
      -- Вся operational configuration находится в БД.
      ------------------------------------------------------------------------
      IF NOT capture_Enabled THEN
         p_ret_code := RET_OK;
         p_ret_info := 'MI_0606 capture disabled';

         RETURN;
      END IF;


      l_max_count :=
         capture_Int_Property(
            p_name          => 'CAPTURE_MAX_FILES',
            p_default_value => 10,
            p_min_value     => 1,
            p_max_value     => 1000
         );


      l_scan_max :=
         capture_Int_Property(
            p_name          => 'CAPTURE_SCAN_MAX',
            p_default_value => 1000,
            p_min_value     => 1,
            p_max_value     => 100000
         );


      /*
         Scan limit не должен быть меньше количества документов,
         которое разрешено capture.
      */
      IF l_scan_max < l_max_count THEN
         raise_Technical_Error(
            p_code => 'MI_0606_INVALID_CAPTURE_PROPERTY',
            p_info =>
                  'CAPTURE_SCAN_MAX='
               || l_scan_max
               || ' must be >= CAPTURE_MAX_FILES='
               || l_max_count
         );
      END IF;


      l_log.enter_f(
         p_function_name => 'capture_Pending',
         p_message_text  =>
               'max_count='
            || l_max_count
            || ', scan_max='
            || l_scan_max
      );


      ------------------------------------------------------------------------
      -- Technical failure должен удалить весь batch этого вызова.
      ------------------------------------------------------------------------
      DCL.SavePoint(l_savepoint_name);

      IF l_savepoint_name IS NULL THEN
         raise_Technical_Error(
            p_code => 'MI_0606_CAPTURE_SAVEPOINT_UNAVAILABLE',
            p_info => 'DCL did not create the capture_Pending savepoint'
         );
      END IF;


      OPEN c_source;


      LOOP
         EXIT WHEN l_scanned_count >= l_scan_max;


         FETCH c_source
          INTO l_source.id,
               l_source.file_type,
               l_source.file_name,
               l_source.rec_state,
               l_source.file_body,
               l_source.task_id,
               l_source.doc_key;


         EXIT WHEN c_source%NOTFOUND;


         l_scanned_count :=
            l_scanned_count + 1;


         ---------------------------------------------------------------------
         -- REC_STATE=0 + existing MI journal является нарушением атомарности.
         -- Не лечим данные молча.
         ---------------------------------------------------------------------
         IF find_Existing_Source(
               p_outfile_id => l_source.id,
               p_req_id     => l_existing_req_id,
               p_itm_id     => l_existing_itm_id
            )
         THEN
            raise_Technical_Error(
               p_code => 'MI_0606_SOURCE_JOURNAL_INCONSISTENT',
               p_info =>
                     'RSD_OUTFILES remains pending but MI journal exists'
                  || '; outfile_id='
                  || l_source.id
                  || '; req_id='
                  || l_existing_req_id
                  || '; itm_id='
                  || l_existing_itm_id
            );
         END IF;


         l_req_id       := NULL;
         l_itm_id       := NULL;
         l_row_ret_code := RET_FAIL;
         l_row_ret_info := NULL;


         create_Request_Impl(
            p_source   => l_source,

            p_req_id   => l_req_id,
            p_itm_id   => l_itm_id,

            p_ret_code => l_row_ret_code,
            p_ret_info => l_row_ret_info
         );


         IF l_row_ret_code = RET_OK THEN
            p_captured_count :=
               p_captured_count + 1;


            EXIT WHEN p_captured_count >= l_max_count;


         ELSIF l_row_ret_code IN (
                  RET_FAIL,
                  RET_UNSUPPORTED_FILE_TYPE
               )
         THEN
            /*
               Ошибка конкретной business source row.

               Она остаётся REC_STATE=0.
               Другие документы batch продолжают обрабатываться.

               CAPTURE_SCAN_MAX не позволяет бесконечно обходить
               произвольное количество плохих записей.
            */
            p_skipped_count :=
               p_skipped_count + 1;


            l_log.warn(
               p_message_text => 'RSD_OUTFILES row skipped',
               p_action_code  => 'capture_skip',
               p_details_text =>
                  TO_CLOB(
                        'outfile_id='
                     || l_source.id
                     || '; ret_code='
                     || l_row_ret_code
                     || '; ret_info='
                     || l_row_ret_info
                  )
            );


         ELSE
            /*
               Для строки, полученной самим cursor
               WHERE REC_STATE='0' FOR UPDATE,
               остальные RET_* означают внутреннее рассогласование.
            */
            raise_Technical_Error(
               p_code => 'MI_0606_CAPTURE_UNEXPECTED_RESULT',
               p_info =>
                     'Unexpected create result'
                  || '; outfile_id='
                  || l_source.id
                  || '; ret_code='
                  || NVL(TO_CHAR(l_row_ret_code), '<NULL>')
                  || '; ret_info='
                  || NVL(l_row_ret_info, '<NULL>')
            );
         END IF;
      END LOOP;


      CLOSE c_source;


      p_ret_code := RET_OK;

      p_ret_info :=
         SUBSTR(
               'MI_0606 capture completed'
            || '; captured='
            || p_captured_count
            || '; skipped='
            || p_skipped_count
            || '; scanned='
            || l_scanned_count,
            1,
            4000
         );


      l_log.info(
         p_message_text => 'MI_0606 capture completed',
         p_action_code  => 'capture',
         p_details_text =>
            TO_CLOB(
                  'captured='
               || p_captured_count
               || ', skipped='
               || p_skipped_count
               || ', scanned='
               || l_scanned_count
            )
      );


      l_log.exit_f(
         p_function_name => 'capture_Pending',
         p_message_text  => p_ret_info
      );


   EXCEPTION
      WHEN OTHERS THEN
         l_sqlerrm := SQLERRM;


         IF c_source%ISOPEN THEN
            CLOSE c_source;
         END IF;


         l_rollback_ok :=
            MI_Transaction.rollback_Savepoint(
               p_name => l_savepoint_name,
               p_log  => l_log
            );


         l_log.error(
            p_message_text => 'capture_Pending failed',
            p_action_code  => 'capture',
            p_details_text =>
               TO_CLOB(
                     l_sqlerrm
                  || CHR(10)
                  || DBMS_UTILITY.format_error_backtrace
                  || CHR(10)
                  || 'captured_before_failure='
                  || p_captured_count
                  || CHR(10)
                  || 'own_rollback='
                  || MI_Utils.to_Char(l_rollback_ok)
               )
         );


         RAISE;
   END capture_Pending;

END MI_0606_Api;
/
