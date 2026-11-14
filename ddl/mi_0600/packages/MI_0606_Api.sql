CREATE OR REPLACE PACKAGE MI_0606_Api
IS

   VERSION CONSTANT VARCHAR2(100) :=
      '$Id: {1.0.0} {14.11.2026} Sulimoff$';


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


   FUNCTION get_Version
      RETURN VARCHAR2;


   ---------------------------------------------------------------------------
   /*
      Создаёт исходящий request 606 из одной записи RSD_OUTFILES.

      Одна запись RSD_OUTFILES соответствует:
         одному MI_REQ;
         одному MI_0600 item;
         одному SEND_DOCUMENT.

      Процедура:
         - блокирует RSD_OUTFILES;
         - создаёт MI_REQ со STATUS_NEW;
         - создаёт MI_0600;
         - сохраняет исходное имя в MI_0600_F;
         - переводит RSD_OUTFILES.REC_STATE из '0' в '1'.

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
      Возвращает данные SEND_DOCUMENT для уже зарегистрированного request.

      FILE_BODY является snapshot, сохранённым в MI_0600.BZIP_DATA.
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
      RETURN
            'MI_0606_'
         || TO_CHAR(p_outfile_id);
   END journal_Name;


   ---------------------------------------------------------------------------
   FUNCTION map_Doc_Type (
      p_file_type IN RSD_OUTFILES.FILE_TYPE%TYPE
   )
      RETURN VARCHAR2
   IS
      l_file_type RSD_OUTFILES.FILE_TYPE%TYPE;
   BEGIN
      l_file_type :=
         UPPER(TRIM(p_file_type));

      /*
         Подтверждённый business mapping.

         Остальные mappings должны быть добавлены после согласования
         с разработчиком RD.
      */
      RETURN
         CASE l_file_type
            WHEN 'PB2' THEN 'IMPOSSIBILITY_RESPONSE'
            ELSE NULL
         END;
   END map_Doc_Type;


   ---------------------------------------------------------------------------
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


   ---------------------------------------------------------------------------
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


      IF l_warning <> DBMS_LOB.NO_WARNING THEN
         RAISE_APPLICATION_ERROR(
            -20971,
               'CLOB to UTF-8 BLOB conversion warning='
            || l_warning
         );
      END IF;


      RETURN l_blob;


   EXCEPTION
      WHEN OTHERS THEN
         IF l_blob IS NOT NULL
            AND DBMS_LOB.isTemporary(l_blob) = 1
         THEN
            DBMS_LOB.freeTemporary(l_blob);
         END IF;

         RAISE;
   END clob_To_Utf8_Blob;


   ---------------------------------------------------------------------------
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


   ---------------------------------------------------------------------------
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
       WHERE r.INF_ID = 606
         AND i.CZIP_NAME = l_journal_name;


      RETURN TRUE;


   EXCEPTION
      WHEN NO_DATA_FOUND THEN
         p_req_id := NULL;
         p_itm_id := NULL;

         RETURN FALSE;
   END find_Existing_Source;


   ---------------------------------------------------------------------------
   PROCEDURE create_Request (
      p_outfile_id  IN  RSD_OUTFILES.ID%TYPE,

      p_req_id      OUT MI_REQ.REQ_ID%TYPE,
      p_itm_id      OUT MI_0600.ITM_ID%TYPE,

      p_ret_code    OUT NUMBER,
      p_ret_info    OUT VARCHAR2
   )
   IS
      l_file_type       RSD_OUTFILES.FILE_TYPE%TYPE;
      l_file_name       RSD_OUTFILES.FILENAME%TYPE;
      l_rec_state       RSD_OUTFILES.REC_STATE%TYPE;
      l_file_body       RSD_OUTFILES.FILEBODY%TYPE;
      l_bin_file        RSD_OUTFILES.BINFILE%TYPE;
      l_task_id         RSD_OUTFILES.TASKID%TYPE;
      l_doc_key         RSD_OUTFILES.DOCKEY%TYPE;

      l_doc_type        VARCHAR2(100);
      l_error_code      VARCHAR2(100);

      l_payload         BLOB;
      l_payload_temp    BOOLEAN := FALSE;

      l_journal_name    MI_0600.CZIP_NAME%TYPE;

      l_request_result  MI_ResultCtx.exec_Result_t;

      l_req_id          MI_REQ.REQ_ID%TYPE;
      l_itm_id          MI_0600.ITM_ID%TYPE;

      l_correlation_id  MI_REQ.CORRELATION_ID%TYPE;

      l_savepoint_name  DCL.T_Name;

      l_sqlcode         PLS_INTEGER;
      l_sqlerrm         VARCHAR2(2000);

      l_log             MI_Logger_T := g_log;


      ------------------------------------------------------------------------
      PROCEDURE rollback_Own_Work
      IS
         l_name         DCL.T_Name;
         l_rolled_back  BOOLEAN;
      BEGIN
         IF l_savepoint_name IS NULL THEN
            RETURN;
         END IF;

         l_name           := l_savepoint_name;
         l_savepoint_name := NULL;

         l_rolled_back :=
            DCL.RollBack(l_name);

         IF NOT l_rolled_back THEN
            l_log.warn(
               p_message_text => 'DCL rollback was not performed',
               p_action_code  => 'rollback_skipped'
            );
         END IF;
      END rollback_Own_Work;


      ------------------------------------------------------------------------
      PROCEDURE return_Existing
      IS
      BEGIN
         p_req_id   := l_req_id;
         p_itm_id   := l_itm_id;
         p_ret_code := RET_EXISTS;

         p_ret_info :=
            SUBSTR(
                  'RSD_OUTFILES already registered'
               || '; id='
               || p_outfile_id
               || '; req_id='
               || l_req_id
               || '; itm_id='
               || l_itm_id,
               1,
               4000
            );
      END return_Existing;


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


      ------------------------------------------------------------------------
      -- Идемпотентный повтор уже зарегистрированной source row.
      ------------------------------------------------------------------------
      IF find_Existing_Source(
            p_outfile_id => p_outfile_id,
            p_req_id     => l_req_id,
            p_itm_id     => l_itm_id
         )
      THEN
         return_Existing;
         RETURN;
      END IF;


      l_log.enter_f(
         p_function_name => 'create_Request',
         p_message_text  =>
               'RSD_OUTFILES.id='
            || p_outfile_id
      );


      DCL.SavePoint(l_savepoint_name);


      ------------------------------------------------------------------------
      -- Источник блокируется до COMMIT / ROLLBACK вызывающего кода.
      ------------------------------------------------------------------------
      BEGIN
         SELECT FILE_TYPE,
                FILENAME,
                REC_STATE,
                FILEBODY,
                BINFILE,
                TASKID,
                DOCKEY
           INTO l_file_type,
                l_file_name,
                l_rec_state,
                l_file_body,
                l_bin_file,
                l_task_id,
                l_doc_key
           FROM RSD_OUTFILES
          WHERE ID = p_outfile_id
            FOR UPDATE;

      EXCEPTION
         WHEN NO_DATA_FOUND THEN
            rollback_Own_Work;

            p_ret_code := RET_NO_DATA;
            p_ret_info :=
               'RSD_OUTFILES row not found: id='
               || p_outfile_id;

            RETURN;
      END;


      ------------------------------------------------------------------------
      -- После конкурентного capture строка уже могла сменить REC_STATE.
      ------------------------------------------------------------------------
      IF TRIM(l_rec_state) <> '0' THEN
         rollback_Own_Work;


         IF find_Existing_Source(
               p_outfile_id => p_outfile_id,
               p_req_id     => l_req_id,
               p_itm_id     => l_itm_id
            )
         THEN
            return_Existing;
            RETURN;
         END IF;


         p_ret_code := RET_BAD_STATE;

         p_ret_info :=
            SUBSTR(
                  'RSD_OUTFILES has invalid REC_STATE='
               || NVL(TRIM(l_rec_state), '<NULL>')
               || ', expected 0; id='
               || p_outfile_id,
               1,
               4000
            );

         RETURN;
      END IF;


      l_file_name :=
         TRIM(l_file_name);

      l_task_id :=
         TRIM(l_task_id);

      l_doc_key :=
         TRIM(l_doc_key);


      IF l_file_name IS NULL THEN
         rollback_Own_Work;

         p_ret_code := RET_FAIL;
         p_ret_info := 'RSD_OUTFILES.FILENAME is empty';

         RETURN;
      END IF;


      IF l_task_id IS NULL
         OR NOT MI_Utils.is_Uuid(l_task_id)
      THEN
         rollback_Own_Work;

         p_ret_code := RET_FAIL;

         p_ret_info :=
               'RSD_OUTFILES.TASKID must be UUID: '
            || NVL(l_task_id, '<NULL>');

         RETURN;
      END IF;


      IF l_doc_key IS NULL
         OR NOT MI_Utils.is_Uuid(l_doc_key)
      THEN
         rollback_Own_Work;

         p_ret_code := RET_FAIL;

         p_ret_info :=
               'RSD_OUTFILES.DOCKEY must be UUID: '
            || NVL(l_doc_key, '<NULL>');

         RETURN;
      END IF;


      ------------------------------------------------------------------------
      -- Business mapping RSD -> SEND_DOCUMENT.
      ------------------------------------------------------------------------
      l_doc_type :=
         map_Doc_Type(l_file_type);

      l_error_code :=
         map_Error_Code(l_file_type);


      IF l_doc_type IS NULL
         AND l_error_code IS NULL
      THEN
         rollback_Own_Work;

         p_ret_code :=
            RET_UNSUPPORTED_FILE_TYPE;

         p_ret_info :=
            SUBSTR(
                  'Unsupported RSD_OUTFILES.FILE_TYPE='
               || NVL(TRIM(l_file_type), '<NULL>')
               || '; id='
               || p_outfile_id,
               1,
               4000
            );

         RETURN;
      END IF;


      ------------------------------------------------------------------------
      -- Формируем byte snapshot исходящего документа.
      --
      -- Если business module заполнил BINFILE, используем его.
      -- Иначе FILEBODY конвертируется в UTF-8.
      ------------------------------------------------------------------------
      IF l_bin_file IS NOT NULL
         AND DBMS_LOB.getlength(l_bin_file) > 0
      THEN
         l_payload :=
            l_bin_file;

      ELSIF l_file_body IS NOT NULL
         AND DBMS_LOB.getlength(l_file_body) > 0
      THEN
         l_payload :=
            clob_To_Utf8_Blob(l_file_body);

         l_payload_temp := TRUE;

      ELSE
         rollback_Own_Work;

         p_ret_code := RET_FAIL;
         p_ret_info := 'RSD_OUTFILES contains no document body';

         RETURN;
      END IF;


      ------------------------------------------------------------------------
      -- Создаём MI_REQ исходящего 606.
      ------------------------------------------------------------------------
      l_request_result :=
         MI_Request_Api.create_Request(
            p_inf_id        => 606,
            p_ctaxreq_id    => l_task_id,
            p_status_cd     => MI_Request_Api.STATUS_NEW
         );


      IF MI_ResultCtx.is_Failed(l_request_result) THEN
         MI_ResultCtx.raise_Error(l_request_result);
      END IF;


      l_req_id :=
         TO_NUMBER(
            l_request_result.parameters('req_id')
         );

      l_correlation_id :=
         l_request_result.parameters('correlation_id');


      IF l_req_id IS NULL THEN
         RAISE_APPLICATION_ERROR(
            -20972,
            'MI_Request_Api.create_Request returned NULL req_id'
         );
      END IF;


      ------------------------------------------------------------------------
      -- Один RSD_OUTFILES = один MI_0600 item.
      --
      -- EXTERNAL_UUID намеренно равен DOCKEY.
      -- По нему позже приходит DOCUMENT_STATUS.
      ------------------------------------------------------------------------
      l_journal_name :=
         journal_Name(p_outfile_id);


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
         l_req_id,

         l_journal_name,
         l_payload,
         DBMS_LOB.getlength(l_payload),
         1,

         1
      )
      RETURNING ITM_ID
           INTO l_itm_id;


      ------------------------------------------------------------------------
      -- Реальное business filename.
      ------------------------------------------------------------------------
      INSERT INTO MI_0600_F (
         ITM_ID,
         CZIP_FILE_NAME
      )
      VALUES (
         l_itm_id,
         l_file_name
      );


      ------------------------------------------------------------------------
      -- Source row считается зарегистрированной в MI journal.
      ------------------------------------------------------------------------
      UPDATE RSD_OUTFILES
         SET REC_STATE = '1'
       WHERE ID = p_outfile_id
         AND REC_STATE = '0';


      IF SQL%ROWCOUNT <> 1 THEN
         RAISE_APPLICATION_ERROR(
            -20973,
               'RSD_OUTFILES state update failed: id='
            || p_outfile_id
            || ', rows='
            || SQL%ROWCOUNT
         );
      END IF;


      p_req_id   := l_req_id;
      p_itm_id   := l_itm_id;
      p_ret_code := RET_OK;

      p_ret_info :=
         'SEND_DOCUMENT request created';


      l_log.context(
         p_inf_id         => 606,
         p_req_id         => l_req_id,
         p_itm_id         => l_itm_id,
         p_correlation_id => l_correlation_id
      );


      l_log.info(
         p_message_text => 'SEND_DOCUMENT request created',
         p_action_code  => 'create',
         p_details_text =>
            TO_CLOB(
                  'RSD_OUTFILES.id='
               || p_outfile_id
               || ', docKey='
               || l_doc_key
               || ', fileType='
               || l_file_type
            )
      );


      l_log.exit_f(
         p_function_name => 'create_Request',
         p_message_text  => 'OK'
      );


      IF l_payload_temp THEN
         free_Temporary_Blob(l_payload);
      END IF;


   EXCEPTION
      WHEN OTHERS THEN
         l_sqlcode := SQLCODE;
         l_sqlerrm := SQLERRM;


         rollback_Own_Work;


         IF l_payload_temp THEN
            free_Temporary_Blob(l_payload);
         END IF;


         l_log.error(
            p_message_text => 'create_Request failed',
            p_action_code  => 'create',
            p_details_text =>
               TO_CLOB(
                     l_sqlerrm
                  || CHR(10)
                  || DBMS_UTILITY.format_error_backtrace
               )
         );


         RAISE;
   END create_Request;


   ---------------------------------------------------------------------------
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
      l_file_type RSD_OUTFILES.FILE_TYPE%TYPE;
   BEGIN
      p_task_id    := NULL;
      p_doc_key    := NULL;
      p_doc_type   := NULL;
      p_error_code := NULL;
      p_file_name  := NULL;
      p_file_body  := NULL;

      p_ret_code   := RET_FAIL;
      p_ret_info   := NULL;


      BEGIN
         SELECT TRIM(r.CTAXREQ_ID),
                TRIM(i.EXTERNAL_UUID),
                f.CZIP_FILE_NAME,
                i.BZIP_DATA,
                o.FILE_TYPE
           INTO p_task_id,
                p_doc_key,
                p_file_name,
                p_file_body,
                l_file_type
           FROM MI_REQ r
           JOIN MI_0600 i
             ON i.REQ_ID = r.REQ_ID
           JOIN MI_0600_F f
             ON f.ITM_ID = i.ITM_ID
           JOIN RSD_OUTFILES o
             ON i.CZIP_NAME =
                   'MI_0606_' || TO_CHAR(o.ID)
          WHERE r.REQ_ID = p_req_id
            AND r.INF_ID = 606;

      EXCEPTION
         WHEN NO_DATA_FOUND THEN
            p_ret_code := RET_NO_DATA;

            p_ret_info :=
               'SEND_DOCUMENT source not found: req_id='
               || p_req_id;

            RETURN;
      END;


      p_doc_type :=
         map_Doc_Type(l_file_type);

      p_error_code :=
         map_Error_Code(l_file_type);


      IF p_doc_type IS NULL
         AND p_error_code IS NULL
      THEN
         p_ret_code :=
            RET_UNSUPPORTED_FILE_TYPE;

         p_ret_info :=
               'Unsupported RSD_OUTFILES.FILE_TYPE='
            || NVL(TRIM(l_file_type), '<NULL>');

         RETURN;
      END IF;


      IF p_task_id IS NULL
         OR p_doc_key IS NULL
         OR p_file_name IS NULL
         OR p_file_body IS NULL
         OR DBMS_LOB.getlength(p_file_body) = 0
      THEN
         p_ret_code := RET_FAIL;

         p_ret_info :=
            'SEND_DOCUMENT journal is incomplete';

         RETURN;
      END IF;


      p_ret_code := RET_OK;
      p_ret_info := 'SEND_DOCUMENT prepared';

   END prepare_Send_Document;


   ---------------------------------------------------------------------------
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
      p_current_msg    OUT MI_0600.MESSAGE_UUID%TYPE
   )
   IS
      l_item_uuid MI_0600.EXTERNAL_UUID%TYPE;
   BEGIN
      SELECT REQ_ID,
             STATUS_CD
        INTO p_req_id,
             p_status_cd
        FROM MI_REQ
       WHERE INF_ID = 606
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
         RAISE_APPLICATION_ERROR(
            -20974,
               'SEND_DOCUMENT docKey mismatch: expected='
            || TRIM(l_item_uuid)
            || ', actual='
            || TRIM(p_doc_key)
         );
      END IF;
   END lock_By_Request;


   ---------------------------------------------------------------------------
   PROCEDURE lock_By_Doc_Key (
      p_doc_key        IN  MI_0600.EXTERNAL_UUID%TYPE,

      p_req_id         OUT MI_REQ.REQ_ID%TYPE,
      p_itm_id         OUT MI_0600.ITM_ID%TYPE,
      p_status_cd      OUT MI_REQ.STATUS_CD%TYPE,
      p_current_msg    OUT MI_0600.MESSAGE_UUID%TYPE
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


      SELECT STATUS_CD
        INTO p_status_cd
        FROM MI_REQ
       WHERE REQ_ID = p_req_id
         AND INF_ID = 606
         FOR UPDATE;


      SELECT MESSAGE_UUID
        INTO p_current_msg
        FROM MI_0600
       WHERE ITM_ID = p_itm_id
         AND REQ_ID = p_req_id
         FOR UPDATE;
   END lock_By_Doc_Key;


   ---------------------------------------------------------------------------
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
         IF TRIM(p_current_msg) = TRIM(p_message_uuid) THEN
            p_ret_code :=
               RET_ALREADY_APPLIED;

            p_ret_info :=
               'Terminal result already applied';

            RETURN;
         END IF;


         p_ret_code := RET_FAIL;

         p_ret_info :=
               'Item result already applied by another message: '
            || TRIM(p_current_msg);

         RETURN;
      END IF;


      IF p_status_cd <> MI_Request_Api.STATUS_SENT THEN
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
         RAISE_APPLICATION_ERROR(
            -20975,
               'MI_0600 terminal result update failed: itm_id='
            || p_itm_id
         );
      END IF;


      ------------------------------------------------------------------------
      -- Business result получен, integration lifecycle завершён.
      ------------------------------------------------------------------------
      l_transition :=
         MI_Request_Api.to_Success(p_req_id);


      IF MI_ResultCtx.is_Failed(l_transition) THEN
         MI_ResultCtx.raise_Error(l_transition);
      END IF;


      p_ret_code := RET_OK;
      p_ret_info := 'Terminal result applied';
   END apply_Terminal_Result;


   ---------------------------------------------------------------------------
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
      l_status        VARCHAR2(30);

      l_status_cd     MI_REQ.STATUS_CD%TYPE;
      l_current_msg   MI_0600.MESSAGE_UUID%TYPE;

      l_savepoint     DCL.T_Name;

      l_log           MI_Logger_T := g_log;
   BEGIN
      p_req_id   := NULL;
      p_itm_id   := NULL;
      p_ret_code := RET_FAIL;
      p_ret_info := NULL;


      IF p_request_uuid IS NULL
         OR NOT MI_Utils.is_Uuid(TRIM(p_request_uuid))
      THEN
         p_ret_info := 'Invalid request UUID';
         RETURN;
      END IF;


      IF p_message_uuid IS NULL
         OR NOT MI_Utils.is_Uuid(TRIM(p_message_uuid))
      THEN
         p_ret_info := 'Invalid message UUID';
         RETURN;
      END IF;


      IF p_doc_key IS NULL
         OR NOT MI_Utils.is_Uuid(TRIM(p_doc_key))
      THEN
         p_ret_info := 'Invalid docKey';
         RETURN;
      END IF;


      IF p_response_time IS NULL THEN
         p_ret_info := 'response_time must not be NULL';
         RETURN;
      END IF;


      l_status :=
         UPPER(TRIM(p_status));


      IF l_status NOT IN (
            'SUCCESS',
            'ERROR',
            'VALIDATION_ERROR'
         )
      THEN
         p_ret_info :=
               'Unsupported DOCUMENT_SUBMITTED.status='
            || NVL(l_status, '<NULL>');

         RETURN;
      END IF;


      DCL.SavePoint(l_savepoint);


      BEGIN
         lock_By_Request(
            p_request_uuid => p_request_uuid,
            p_doc_key      => p_doc_key,

            p_req_id       => p_req_id,
            p_itm_id       => p_itm_id,
            p_status_cd    => l_status_cd,
            p_current_msg  => l_current_msg
         );

      EXCEPTION
         WHEN NO_DATA_FOUND THEN
            DCL.RollBack(l_savepoint);

            p_ret_code := RET_NO_DATA;
            p_ret_info := 'SEND_DOCUMENT request/item not found';

            RETURN;
      END;


      l_log.context(
         p_inf_id => 606,
         p_req_id => p_req_id,
         p_itm_id => p_itm_id
      );


      ------------------------------------------------------------------------
      -- SUCCESS является промежуточным ACK.
      ------------------------------------------------------------------------
      IF l_status = 'SUCCESS' THEN
         IF l_status_cd = MI_Request_Api.STATUS_SENT THEN
            p_ret_code := RET_OK;
            p_ret_info := 'DOCUMENT_SUBMITTED SUCCESS accepted';

            l_log.info(
               p_message_text => p_ret_info,
               p_action_code  => 'submitted'
            );

            RETURN;
         END IF;


         IF l_status_cd = MI_Request_Api.STATUS_DONE THEN
            p_ret_code := RET_ALREADY_APPLIED;
            p_ret_info := 'Request already completed';

            RETURN;
         END IF;


         DCL.RollBack(l_savepoint);

         p_ret_code := RET_BAD_STATE;

         p_ret_info :=
               'Request must be SENT for DOCUMENT_SUBMITTED SUCCESS, actual='
            || MI_Request_Api.status_Name(l_status_cd);

         RETURN;
      END IF;


      ------------------------------------------------------------------------
      -- ERROR / VALIDATION_ERROR пока считаются terminal business outcome.
      ------------------------------------------------------------------------
      apply_Terminal_Result(
         p_req_id        => p_req_id,
         p_itm_id        => p_itm_id,
         p_status_cd     => l_status_cd,
         p_current_msg   => l_current_msg,

         p_message_uuid  => p_message_uuid,

         p_ires_code     => RET_FAIL,
         p_error_code    => l_status,
         p_info          =>
            TO_CLOB(
               'DOCUMENT_SUBMITTED status=' || l_status
            ),
         p_response_time => p_response_time,

         p_ret_code      => p_ret_code,
         p_ret_info      => p_ret_info
      );


   EXCEPTION
      WHEN OTHERS THEN
         IF l_savepoint IS NOT NULL THEN
            DCL.RollBack(l_savepoint);
         END IF;

         RAISE;
   END apply_Document_Submitted;


   ---------------------------------------------------------------------------
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
      l_state         VARCHAR2(30);

      l_status_cd     MI_REQ.STATUS_CD%TYPE;
      l_current_msg   MI_0600.MESSAGE_UUID%TYPE;

      l_ires_code     MI_0600.IRES_CODE%TYPE;
      l_error_code    MI_0600.ERROR_CODE%TYPE;

      l_savepoint     DCL.T_Name;
   BEGIN
      p_req_id   := NULL;
      p_itm_id   := NULL;
      p_ret_code := RET_FAIL;
      p_ret_info := NULL;


      IF p_message_uuid IS NULL
         OR NOT MI_Utils.is_Uuid(TRIM(p_message_uuid))
      THEN
         p_ret_info := 'Invalid message UUID';
         RETURN;
      END IF;


      IF p_doc_key IS NULL
         OR NOT MI_Utils.is_Uuid(TRIM(p_doc_key))
      THEN
         p_ret_info := 'Invalid docKey';
         RETURN;
      END IF;


      IF p_response_time IS NULL THEN
         p_ret_info := 'response_time must not be NULL';
         RETURN;
      END IF;


      l_state :=
         UPPER(TRIM(p_state));


      IF l_state NOT IN (
            'PROCESSED',
            'ERROR_STATE',
            'ERROR_INTERNAL',
            'ERROR_PROCESSING'
         )
      THEN
         p_ret_info :=
               'Unsupported DOCUMENT_STATUS.state='
            || NVL(l_state, '<NULL>');

         RETURN;
      END IF;


      DCL.SavePoint(l_savepoint);


      BEGIN
         lock_By_Doc_Key(
            p_doc_key       => p_doc_key,

            p_req_id        => p_req_id,
            p_itm_id        => p_itm_id,
            p_status_cd     => l_status_cd,
            p_current_msg   => l_current_msg
         );

      EXCEPTION
         WHEN NO_DATA_FOUND THEN
            DCL.RollBack(l_savepoint);

            p_ret_code := RET_NO_DATA;
            p_ret_info := 'SEND_DOCUMENT item not found';

            RETURN;
      END;


      IF l_state = 'PROCESSED' THEN
         l_ires_code  := RET_OK;
         l_error_code := NULL;
      ELSE
         l_ires_code  := RET_FAIL;
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


   EXCEPTION
      WHEN OTHERS THEN
         IF l_savepoint IS NOT NULL THEN
            DCL.RollBack(l_savepoint);
         END IF;

         RAISE;
   END apply_Document_Status;


   ---------------------------------------------------------------------------
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
      l_status_cd     MI_REQ.STATUS_CD%TYPE;
      l_current_msg   MI_0600.MESSAGE_UUID%TYPE;

      l_fault_code    VARCHAR2(100);

      l_savepoint     DCL.T_Name;
   BEGIN
      p_req_id   := NULL;
      p_itm_id   := NULL;
      p_ret_code := RET_FAIL;
      p_ret_info := NULL;


      IF p_request_uuid IS NULL
         OR NOT MI_Utils.is_Uuid(TRIM(p_request_uuid))
      THEN
         p_ret_info := 'Invalid request UUID';
         RETURN;
      END IF;


      IF p_message_uuid IS NULL
         OR NOT MI_Utils.is_Uuid(TRIM(p_message_uuid))
      THEN
         p_ret_info := 'Invalid message UUID';
         RETURN;
      END IF;


      IF p_response_time IS NULL THEN
         p_ret_info := 'response_time must not be NULL';
         RETURN;
      END IF;


      l_fault_code :=
         UPPER(TRIM(p_fault_code));


      IF l_fault_code IS NULL THEN
         p_ret_info := 'FAULT.faultCode must not be empty';
         RETURN;
      END IF;


      DCL.SavePoint(l_savepoint);


      BEGIN
         lock_By_Request(
            p_request_uuid => p_request_uuid,
            p_doc_key      => NULL,

            p_req_id       => p_req_id,
            p_itm_id       => p_itm_id,
            p_status_cd    => l_status_cd,
            p_current_msg  => l_current_msg
         );

      EXCEPTION
         WHEN NO_DATA_FOUND THEN
            DCL.RollBack(l_savepoint);

            p_ret_code := RET_NO_DATA;
            p_ret_info := 'SEND_DOCUMENT request not found';

            RETURN;
      END;


      apply_Terminal_Result(
         p_req_id        => p_req_id,
         p_itm_id        => p_itm_id,
         p_status_cd     => l_status_cd,
         p_current_msg   => l_current_msg,

         p_message_uuid  => p_message_uuid,

         p_ires_code     => RET_FAIL,
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


   EXCEPTION
      WHEN OTHERS THEN
         IF l_savepoint IS NOT NULL THEN
            DCL.RollBack(l_savepoint);
         END IF;

         RAISE;
   END apply_Fault;


END MI_0606_Api;
/