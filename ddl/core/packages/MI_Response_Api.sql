CREATE OR REPLACE PACKAGE MI_Response_Api
IS

   VERSION CONSTANT VARCHAR2(100) :=
      '$Id: {1.0.0} {08.11.2026} Sulimoff$';


   /*
      В MI_RSP constraint допускает также значение 3.
      Текущий response workflow использует только состояния ниже:

         NEW (0) -> READY (1) -> SENT (2)

      ERROR (-1) распознаётся для диагностики существующих данных, но данный
      API не переводит response в ERROR.
   */
   SUBTYPE Status_t IS PLS_INTEGER RANGE -1 .. 3;

   STATUS_ERROR CONSTANT Status_t := -1;
   STATUS_NEW   CONSTANT Status_t :=  0;
   STATUS_READY CONSTANT Status_t :=  1;
   STATUS_SENT  CONSTANT Status_t :=  2;


   FUNCTION get_Version
      RETURN VARCHAR2;


   FUNCTION status_Name (
      p_status_cd IN Status_t
   )
      RETURN VARCHAR2;


   FUNCTION exists_Response (
      p_rsp_id IN MI_RSP.RSP_ID%TYPE
   )
      RETURN BOOLEAN;


   FUNCTION get_Status (
      p_rsp_id IN MI_RSP.RSP_ID%TYPE
   )
      RETURN Status_t;


   FUNCTION get_Rsp_Uuid (
      p_rsp_id IN MI_RSP.RSP_ID%TYPE
   )
      RETURN MI_RSP.RSP_UUID%TYPE;


   /*
      Создаёт response в состоянии NEW.

      RSP_ID заполняется table identity mechanism (sequence + trigger),
      CREATED_AT — default таблицы. RSP_UUID генерируется пакетом всегда.

      ITM_ID является полиморфной ссылкой на item конкретного вида сведений
      (MI_0007, MI_0010, ...), поэтому FK на единую item table отсутствует.
      Согласованность REQ_ID/ITM_ID обеспечивает вызывающий business package.
   */
   FUNCTION create_Response (
      p_req_id       IN MI_RSP.REQ_ID%TYPE,
      p_itm_id       IN MI_RSP.ITM_ID%TYPE,

      p_category_cd  IN MI_RSP.CATEGORY_CD%TYPE,
      p_result_code  IN MI_RSP.RESULT_CODE%TYPE,
      p_result_info  IN MI_RSP.RESULT_INFO%TYPE DEFAULT NULL,

      p_payload      IN MI_RSP.PAYLOAD%TYPE     DEFAULT NULL
   )
      RETURN MI_ResultCtx.exec_Result_t;


   /*
      NEW -> READY
   */
   FUNCTION to_Ready (
      p_rsp_id IN MI_RSP.RSP_ID%TYPE
   )
      RETURN MI_ResultCtx.exec_Result_t;


   /*
      READY -> SENT
   */
   FUNCTION to_Sent (
      p_rsp_id IN MI_RSP.RSP_ID%TYPE
   )
      RETURN MI_ResultCtx.exec_Result_t;

END MI_Response_Api;
/

CREATE OR REPLACE PACKAGE BODY MI_Response_Api
IS

   cLogger CONSTANT VARCHAR2(64) := 'mi.response';


   ---------------------------------------------------------------------------
   FUNCTION get_Version
      RETURN VARCHAR2
   IS
   BEGIN
      RETURN VERSION;
   END get_Version;


   ---------------------------------------------------------------------------
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
            WHEN STATUS_READY THEN 'READY'
            WHEN STATUS_SENT  THEN 'SENT'
            ELSE 'UNKNOWN'
         END;
   END status_Name;


   ---------------------------------------------------------------------------
   FUNCTION exists_Response (
      p_rsp_id IN MI_RSP.RSP_ID%TYPE
   )
      RETURN BOOLEAN
   IS
      l_dummy PLS_INTEGER;
   BEGIN
      SELECT 1
        INTO l_dummy
        FROM MI_RSP
       WHERE RSP_ID = p_rsp_id;

      RETURN TRUE;

   EXCEPTION
      WHEN NO_DATA_FOUND THEN
         RETURN FALSE;
   END exists_Response;


   ---------------------------------------------------------------------------
   FUNCTION get_Status (
      p_rsp_id IN MI_RSP.RSP_ID%TYPE
   )
      RETURN Status_t
   IS
      l_status_cd MI_RSP.STATUS_CD%TYPE;
   BEGIN
      SELECT STATUS_CD
        INTO l_status_cd
        FROM MI_RSP
       WHERE RSP_ID = p_rsp_id;

      RETURN l_status_cd;
   END get_Status;


   ---------------------------------------------------------------------------
   FUNCTION get_Rsp_Uuid (
      p_rsp_id IN MI_RSP.RSP_ID%TYPE
   )
      RETURN MI_RSP.RSP_UUID%TYPE
   IS
      l_rsp_uuid MI_RSP.RSP_UUID%TYPE;
   BEGIN
      SELECT RSP_UUID
        INTO l_rsp_uuid
        FROM MI_RSP
       WHERE RSP_ID = p_rsp_id;

      RETURN l_rsp_uuid;
   END get_Rsp_Uuid;


   ---------------------------------------------------------------------------
   FUNCTION success_Result (
      p_code       IN VARCHAR2,
      p_info       IN VARCHAR2,
      p_rsp_id     IN MI_RSP.RSP_ID%TYPE    DEFAULT NULL,
      p_req_id     IN MI_RSP.REQ_ID%TYPE    DEFAULT NULL,
      p_itm_id     IN MI_RSP.ITM_ID%TYPE    DEFAULT NULL,
      p_rsp_uuid   IN MI_RSP.RSP_UUID%TYPE  DEFAULT NULL,
      p_status_cd  IN Status_t               DEFAULT NULL
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

      IF p_rsp_id IS NOT NULL THEN
         l_result.parameters('rsp_id') := TO_CHAR(p_rsp_id);
      END IF;

      IF p_req_id IS NOT NULL THEN
         l_result.parameters('req_id') := TO_CHAR(p_req_id);
      END IF;

      IF p_itm_id IS NOT NULL THEN
         l_result.parameters('itm_id') := TO_CHAR(p_itm_id);
      END IF;

      IF p_rsp_uuid IS NOT NULL THEN
         l_result.parameters('rsp_uuid') := p_rsp_uuid;
      END IF;

      IF p_status_cd IS NOT NULL THEN
         l_result.parameters('status_cd') := TO_CHAR(p_status_cd);
      END IF;

      RETURN l_result;
   END success_Result;


   ---------------------------------------------------------------------------
   FUNCTION failure_Result (
      p_code       IN VARCHAR2,
      p_info       IN VARCHAR2,
      p_rsp_id     IN MI_RSP.RSP_ID%TYPE   DEFAULT NULL,
      p_req_id     IN MI_RSP.REQ_ID%TYPE   DEFAULT NULL,
      p_itm_id     IN MI_RSP.ITM_ID%TYPE   DEFAULT NULL,
      p_status_cd  IN Status_t              DEFAULT NULL,
      p_details    IN CLOB                  DEFAULT NULL
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

      IF p_rsp_id IS NOT NULL THEN
         l_result.parameters('rsp_id') := TO_CHAR(p_rsp_id);
      END IF;

      IF p_req_id IS NOT NULL THEN
         l_result.parameters('req_id') := TO_CHAR(p_req_id);
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
   FUNCTION current_State_Failure (
      p_rsp_id     IN MI_RSP.RSP_ID%TYPE,
      p_operation  IN VARCHAR2,
      p_expected   IN VARCHAR2
   )
      RETURN MI_ResultCtx.exec_Result_t
   IS
      l_req_id     MI_RSP.REQ_ID%TYPE;
      l_itm_id     MI_RSP.ITM_ID%TYPE;
      l_status_cd  MI_RSP.STATUS_CD%TYPE;
   BEGIN
      SELECT REQ_ID,
             ITM_ID,
             STATUS_CD
        INTO l_req_id,
             l_itm_id,
             l_status_cd
        FROM MI_RSP
       WHERE RSP_ID = p_rsp_id;

      RETURN
         failure_Result(
            p_code      => 'RESPONSE_BAD_STATUS',
            p_info      =>
               p_operation
               || ': недопустимый статус '
               || status_Name(l_status_cd)
               || ' ('
               || l_status_cd
               || '), ожидается '
               || p_expected,
            p_rsp_id    => p_rsp_id,
            p_req_id    => l_req_id,
            p_itm_id    => l_itm_id,
            p_status_cd => l_status_cd
         );

   EXCEPTION
      WHEN NO_DATA_FOUND THEN
         RETURN
            failure_Result(
               p_code   => 'RESPONSE_NOT_FOUND',
               p_info   => 'Не найден response с rsp_id=' || p_rsp_id,
               p_rsp_id => p_rsp_id
            );
   END current_State_Failure;


   ---------------------------------------------------------------------------
   FUNCTION create_Response (
      p_req_id       IN MI_RSP.REQ_ID%TYPE,
      p_itm_id       IN MI_RSP.ITM_ID%TYPE,

      p_category_cd  IN MI_RSP.CATEGORY_CD%TYPE,
      p_result_code  IN MI_RSP.RESULT_CODE%TYPE,
      p_result_info  IN MI_RSP.RESULT_INFO%TYPE DEFAULT NULL,

      p_payload      IN MI_RSP.PAYLOAD%TYPE     DEFAULT NULL
   )
      RETURN MI_ResultCtx.exec_Result_t
   IS
      l_rsp_id    MI_RSP.RSP_ID%TYPE;
      l_rsp_uuid  MI_RSP.RSP_UUID%TYPE;

      l_result    MI_ResultCtx.exec_Result_t;
      l_sqlcode   PLS_INTEGER;
      l_sqlerrm   VARCHAR2(2000);
   BEGIN
      IF p_req_id IS NULL THEN
         RETURN
            failure_Result(
               p_code => 'RESPONSE_INVALID_REQ_ID',
               p_info => 'p_req_id must not be NULL'
            );
      END IF;

      IF p_itm_id IS NULL THEN
         RETURN
            failure_Result(
               p_code   => 'RESPONSE_INVALID_ITM_ID',
               p_info   => 'p_itm_id must not be NULL',
               p_req_id => p_req_id
            );
      END IF;

      IF TRIM(p_category_cd) IS NULL THEN
         RETURN
            failure_Result(
               p_code   => 'RESPONSE_INVALID_CATEGORY',
               p_info   => 'p_category_cd must not be NULL or blank',
               p_req_id => p_req_id,
               p_itm_id => p_itm_id
            );
      END IF;

      IF TRIM(p_result_code) IS NULL THEN
         RETURN
            failure_Result(
               p_code   => 'RESPONSE_INVALID_RESULT_CODE',
               p_info   => 'p_result_code must not be NULL or blank',
               p_req_id => p_req_id,
               p_itm_id => p_itm_id
            );
      END IF;

      IF NOT MI_Request_Api.exists_Request(p_req_id) THEN
         RETURN
            failure_Result(
               p_code   => 'RESPONSE_REQUEST_NOT_FOUND',
               p_info   => 'Не найден request с req_id=' || p_req_id,
               p_req_id => p_req_id,
               p_itm_id => p_itm_id
            );
      END IF;


      l_rsp_uuid := MI_Utils.uuid_V7;


      INSERT INTO MI_RSP (
         REQ_ID,
         ITM_ID,
         RSP_UUID,
         CATEGORY_CD,
         RESULT_CODE,
         RESULT_INFO,
         PAYLOAD,
         STATUS_CD
      )
      VALUES (
         p_req_id,
         p_itm_id,
         l_rsp_uuid,
         p_category_cd,
         p_result_code,
         p_result_info,
         p_payload,
         STATUS_NEW
      )
      RETURNING RSP_ID
           INTO l_rsp_id;


      MI_Logger.info(
         p_logger_name  => cLogger,
         p_message_text => 'Response created',
         p_req_id       => p_req_id,
         p_itm_id       => p_itm_id,
         p_rsp_id       => l_rsp_id,
         p_action_code  => 'create'
      );


      l_result :=
         success_Result(
            p_code      => 'RESPONSE_CREATED',
            p_info      => 'Response created',
            p_rsp_id    => l_rsp_id,
            p_req_id    => p_req_id,
            p_itm_id    => p_itm_id,
            p_rsp_uuid  => l_rsp_uuid,
            p_status_cd => STATUS_NEW
         );

      RETURN l_result;

   EXCEPTION
      WHEN OTHERS THEN
         l_sqlcode := SQLCODE;
         l_sqlerrm := SQLERRM;

         MI_Logger.error(
            p_logger_name  => cLogger,
            p_message_text => 'create_Response failed',
            p_req_id       => p_req_id,
            p_itm_id       => p_itm_id,
            p_rsp_id       => l_rsp_id,
            p_action_code  => 'create',
            p_details_text => TO_CLOB(l_sqlerrm)
         );

         l_result :=
            MI_ResultCtx.from_Exception(
               p_sqlcode => l_sqlcode,
               p_sqlerrm => l_sqlerrm,
               p_code    => 'RESPONSE_CREATE_FAILED',
               p_info    => 'Не удалось создать response'
            );

         IF p_req_id IS NOT NULL THEN
            l_result.parameters('req_id') := TO_CHAR(p_req_id);
         END IF;

         IF p_itm_id IS NOT NULL THEN
            l_result.parameters('itm_id') := TO_CHAR(p_itm_id);
         END IF;

         RETURN l_result;
   END create_Response;


   ---------------------------------------------------------------------------
   FUNCTION to_Ready (
      p_rsp_id IN MI_RSP.RSP_ID%TYPE
   )
      RETURN MI_ResultCtx.exec_Result_t
   IS
      l_req_id    MI_RSP.REQ_ID%TYPE;
      l_itm_id    MI_RSP.ITM_ID%TYPE;

      l_sqlcode   PLS_INTEGER;
      l_sqlerrm   VARCHAR2(2000);
   BEGIN
      IF p_rsp_id IS NULL THEN
         RETURN
            failure_Result(
               p_code => 'RESPONSE_INVALID_RSP_ID',
               p_info => 'p_rsp_id must not be NULL'
            );
      END IF;


      UPDATE MI_RSP
         SET STATUS_CD = STATUS_READY
       WHERE RSP_ID = p_rsp_id
         AND STATUS_CD = STATUS_NEW
      RETURNING REQ_ID,
                ITM_ID
           INTO l_req_id,
                l_itm_id;


      IF SQL%ROWCOUNT = 1 THEN
         MI_Logger.info(
            p_logger_name  => cLogger,
            p_message_text => 'Response moved to READY',
            p_req_id       => l_req_id,
            p_itm_id       => l_itm_id,
            p_rsp_id       => p_rsp_id,
            p_action_code  => 'to_ready'
         );

         RETURN
            success_Result(
               p_code      => 'RESPONSE_READY',
               p_info      => 'Response moved to READY',
               p_rsp_id    => p_rsp_id,
               p_req_id    => l_req_id,
               p_itm_id    => l_itm_id,
               p_status_cd => STATUS_READY
            );
      END IF;


      RETURN
         current_State_Failure(
            p_rsp_id    => p_rsp_id,
            p_operation => 'to_Ready',
            p_expected  => 'NEW'
         );

   EXCEPTION
      WHEN OTHERS THEN
         l_sqlcode := SQLCODE;
         l_sqlerrm := SQLERRM;

         MI_Logger.error(
            p_logger_name  => cLogger,
            p_message_text => 'to_Ready failed',
            p_req_id       => l_req_id,
            p_itm_id       => l_itm_id,
            p_rsp_id       => p_rsp_id,
            p_action_code  => 'to_ready',
            p_details_text => TO_CLOB(l_sqlerrm)
         );

         RETURN
            MI_ResultCtx.from_Exception(
               p_sqlcode => l_sqlcode,
               p_sqlerrm => l_sqlerrm,
               p_code    => 'RESPONSE_TO_READY_FAILED',
               p_info    => 'Ошибка перевода response в READY'
            );
   END to_Ready;


   ---------------------------------------------------------------------------
   FUNCTION to_Sent (
      p_rsp_id IN MI_RSP.RSP_ID%TYPE
   )
      RETURN MI_ResultCtx.exec_Result_t
   IS
      l_req_id    MI_RSP.REQ_ID%TYPE;
      l_itm_id    MI_RSP.ITM_ID%TYPE;

      l_sqlcode   PLS_INTEGER;
      l_sqlerrm   VARCHAR2(2000);
   BEGIN
      IF p_rsp_id IS NULL THEN
         RETURN
            failure_Result(
               p_code => 'RESPONSE_INVALID_RSP_ID',
               p_info => 'p_rsp_id must not be NULL'
            );
      END IF;


      UPDATE MI_RSP
         SET STATUS_CD = STATUS_SENT,
             SENT_AT   = SYSTIMESTAMP
       WHERE RSP_ID = p_rsp_id
         AND STATUS_CD = STATUS_READY
      RETURNING REQ_ID,
                ITM_ID
           INTO l_req_id,
                l_itm_id;


      IF SQL%ROWCOUNT = 1 THEN
         MI_Logger.info(
            p_logger_name  => cLogger,
            p_message_text => 'Response moved to SENT',
            p_req_id       => l_req_id,
            p_itm_id       => l_itm_id,
            p_rsp_id       => p_rsp_id,
            p_action_code  => 'to_sent'
         );

         RETURN
            success_Result(
               p_code      => 'RESPONSE_SENT',
               p_info      => 'Response moved to SENT',
               p_rsp_id    => p_rsp_id,
               p_req_id    => l_req_id,
               p_itm_id    => l_itm_id,
               p_status_cd => STATUS_SENT
            );
      END IF;


      RETURN
         current_State_Failure(
            p_rsp_id    => p_rsp_id,
            p_operation => 'to_Sent',
            p_expected  => 'READY'
         );

   EXCEPTION
      WHEN OTHERS THEN
         l_sqlcode := SQLCODE;
         l_sqlerrm := SQLERRM;

         MI_Logger.error(
            p_logger_name  => cLogger,
            p_message_text => 'to_Sent failed',
            p_req_id       => l_req_id,
            p_itm_id       => l_itm_id,
            p_rsp_id       => p_rsp_id,
            p_action_code  => 'to_sent',
            p_details_text => TO_CLOB(l_sqlerrm)
         );

         RETURN
            MI_ResultCtx.from_Exception(
               p_sqlcode => l_sqlcode,
               p_sqlerrm => l_sqlerrm,
               p_code    => 'RESPONSE_TO_SENT_FAILED',
               p_info    => 'Ошибка перевода response в SENT'
            );
   END to_Sent;

END MI_Response_Api;
/
