CREATE OR REPLACE PACKAGE MI_Logger
AS

   -- Уровни логирования.
   --
   -- LEVEL_ALL / LEVEL_OFF используются как значения порога.
   -- В log() допустимыми уровнями события являются TRACE .. FATAL.
   SUBTYPE Level_t IS PLS_INTEGER RANGE 0 .. 7;

   LEVEL_ALL   CONSTANT Level_t := 0;
   LEVEL_TRACE CONSTANT Level_t := 1;
   LEVEL_DEBUG CONSTANT Level_t := 2;
   LEVEL_INFO  CONSTANT Level_t := 3;
   LEVEL_WARN  CONSTANT Level_t := 4;
   LEVEL_ERROR CONSTANT Level_t := 5;
   LEVEL_FATAL CONSTANT Level_t := 6;
   LEVEL_OFF   CONSTANT Level_t := 7;


   FUNCTION get_Version
      RETURN VARCHAR2;


   PROCEDURE enable_Log;

   PROCEDURE disable_Log;


   /*
      Минимальный уровень записи.

      trc < dbg < inf < wrn < err

      По умолчанию: dbg.
   */
   PROCEDURE set_Min_Level (
      p_level IN Level_t
   );


   FUNCTION is_Enabled (
      p_level IN Level_t
   )
      RETURN BOOLEAN;


   /*
      Универсальная точка записи.

      Все context-id являются диагностическими correlation keys.
      MI_LOG намеренно не содержит FK.
   */
   PROCEDURE log (
      p_logger_name    IN VARCHAR2,
      p_message_text   IN VARCHAR2,

      p_level          IN Level_t  DEFAULT LEVEL_DEBUG,

      p_wsp_id         IN NUMBER   DEFAULT NULL,
      p_inf_id         IN NUMBER   DEFAULT NULL,

      p_req_id         IN NUMBER   DEFAULT NULL,
      p_itm_id         IN NUMBER   DEFAULT NULL,
      p_rsp_id         IN NUMBER   DEFAULT NULL,

      p_correlation_id IN VARCHAR2 DEFAULT NULL,

      p_person_id      IN NUMBER   DEFAULT NULL,
      p_icusnum        IN NUMBER   DEFAULT NULL,

      p_action_code    IN VARCHAR2 DEFAULT NULL,
      p_details_text   IN CLOB     DEFAULT NULL
   );


   PROCEDURE trace (
      p_logger_name    IN VARCHAR2,
      p_message_text   IN VARCHAR2,

      p_wsp_id         IN NUMBER   DEFAULT NULL,
      p_inf_id         IN NUMBER   DEFAULT NULL,
      p_req_id         IN NUMBER   DEFAULT NULL,
      p_itm_id         IN NUMBER   DEFAULT NULL,
      p_rsp_id         IN NUMBER   DEFAULT NULL,
      p_correlation_id IN VARCHAR2 DEFAULT NULL,
      p_person_id      IN NUMBER   DEFAULT NULL,
      p_icusnum        IN NUMBER   DEFAULT NULL,

      p_action_code    IN VARCHAR2 DEFAULT NULL,
      p_details_text   IN CLOB     DEFAULT NULL
   );


   PROCEDURE debug (
      p_logger_name    IN VARCHAR2,
      p_message_text   IN VARCHAR2,

      p_wsp_id         IN NUMBER   DEFAULT NULL,
      p_inf_id         IN NUMBER   DEFAULT NULL,
      p_req_id         IN NUMBER   DEFAULT NULL,
      p_itm_id         IN NUMBER   DEFAULT NULL,
      p_rsp_id         IN NUMBER   DEFAULT NULL,
      p_correlation_id IN VARCHAR2 DEFAULT NULL,
      p_person_id      IN NUMBER   DEFAULT NULL,
      p_icusnum        IN NUMBER   DEFAULT NULL,

      p_action_code    IN VARCHAR2 DEFAULT NULL,
      p_details_text   IN CLOB     DEFAULT NULL
   );


   PROCEDURE info (
      p_logger_name    IN VARCHAR2,
      p_message_text   IN VARCHAR2,

      p_wsp_id         IN NUMBER   DEFAULT NULL,
      p_inf_id         IN NUMBER   DEFAULT NULL,
      p_req_id         IN NUMBER   DEFAULT NULL,
      p_itm_id         IN NUMBER   DEFAULT NULL,
      p_rsp_id         IN NUMBER   DEFAULT NULL,
      p_correlation_id IN VARCHAR2 DEFAULT NULL,
      p_person_id      IN NUMBER   DEFAULT NULL,
      p_icusnum        IN NUMBER   DEFAULT NULL,

      p_action_code    IN VARCHAR2 DEFAULT NULL,
      p_details_text   IN CLOB     DEFAULT NULL
   );


   PROCEDURE warn (
      p_logger_name    IN VARCHAR2,
      p_message_text   IN VARCHAR2,

      p_wsp_id         IN NUMBER   DEFAULT NULL,
      p_inf_id         IN NUMBER   DEFAULT NULL,
      p_req_id         IN NUMBER   DEFAULT NULL,
      p_itm_id         IN NUMBER   DEFAULT NULL,
      p_rsp_id         IN NUMBER   DEFAULT NULL,
      p_correlation_id IN VARCHAR2 DEFAULT NULL,
      p_person_id      IN NUMBER   DEFAULT NULL,
      p_icusnum        IN NUMBER   DEFAULT NULL,

      p_action_code    IN VARCHAR2 DEFAULT NULL,
      p_details_text   IN CLOB     DEFAULT NULL
   );


   PROCEDURE error (
      p_logger_name    IN VARCHAR2,
      p_message_text   IN VARCHAR2,

      p_wsp_id         IN NUMBER   DEFAULT NULL,
      p_inf_id         IN NUMBER   DEFAULT NULL,
      p_req_id         IN NUMBER   DEFAULT NULL,
      p_itm_id         IN NUMBER   DEFAULT NULL,
      p_rsp_id         IN NUMBER   DEFAULT NULL,
      p_correlation_id IN VARCHAR2 DEFAULT NULL,
      p_person_id      IN NUMBER   DEFAULT NULL,
      p_icusnum        IN NUMBER   DEFAULT NULL,

      p_action_code    IN VARCHAR2 DEFAULT NULL,
      p_details_text   IN CLOB     DEFAULT NULL
   );


   PROCEDURE fatal (
      p_logger_name    IN VARCHAR2,
      p_message_text   IN VARCHAR2,

      p_wsp_id         IN NUMBER   DEFAULT NULL,
      p_inf_id         IN NUMBER   DEFAULT NULL,
      p_req_id         IN NUMBER   DEFAULT NULL,
      p_itm_id         IN NUMBER   DEFAULT NULL,
      p_rsp_id         IN NUMBER   DEFAULT NULL,
      p_correlation_id IN VARCHAR2 DEFAULT NULL,
      p_person_id      IN NUMBER   DEFAULT NULL,
      p_icusnum        IN NUMBER   DEFAULT NULL,

      p_action_code    IN VARCHAR2 DEFAULT NULL,
      p_details_text   IN CLOB     DEFAULT NULL
   );


   ----------------------------------------------------------------------------
   -- Синтаксический сахар.
   --
   -- Эти процедуры не имеют собственной логики записи и являются только
   -- тонкими wrappers над trace/debug/info.
   ----------------------------------------------------------------------------
   PROCEDURE enter_f (
      p_logger_name    IN VARCHAR2,
      p_function_name  IN VARCHAR2,
      p_message_text   IN VARCHAR2 DEFAULT NULL,
      p_parameters     IN CLOB     DEFAULT NULL,

      p_wsp_id         IN NUMBER   DEFAULT NULL,
      p_inf_id         IN NUMBER   DEFAULT NULL,
      p_req_id         IN NUMBER   DEFAULT NULL,
      p_itm_id         IN NUMBER   DEFAULT NULL,
      p_rsp_id         IN NUMBER   DEFAULT NULL,
      p_correlation_id IN VARCHAR2 DEFAULT NULL,
      p_person_id      IN NUMBER   DEFAULT NULL,
      p_icusnum        IN NUMBER   DEFAULT NULL
   );


   PROCEDURE exit_f (
      p_logger_name    IN VARCHAR2,
      p_function_name  IN VARCHAR2,
      p_message_text   IN VARCHAR2 DEFAULT NULL,
      p_details_text   IN CLOB     DEFAULT NULL,

      p_wsp_id         IN NUMBER   DEFAULT NULL,
      p_inf_id         IN NUMBER   DEFAULT NULL,
      p_req_id         IN NUMBER   DEFAULT NULL,
      p_itm_id         IN NUMBER   DEFAULT NULL,
      p_rsp_id         IN NUMBER   DEFAULT NULL,
      p_correlation_id IN VARCHAR2 DEFAULT NULL,
      p_person_id      IN NUMBER   DEFAULT NULL,
      p_icusnum        IN NUMBER   DEFAULT NULL
   );


   PROCEDURE variable_Value (
      p_logger_name    IN VARCHAR2,
      p_variable_name  IN VARCHAR2,
      p_value_text     IN VARCHAR2,

      p_wsp_id         IN NUMBER   DEFAULT NULL,
      p_inf_id         IN NUMBER   DEFAULT NULL,
      p_req_id         IN NUMBER   DEFAULT NULL,
      p_itm_id         IN NUMBER   DEFAULT NULL,
      p_rsp_id         IN NUMBER   DEFAULT NULL,
      p_correlation_id IN VARCHAR2 DEFAULT NULL,
      p_person_id      IN NUMBER   DEFAULT NULL,
      p_icusnum        IN NUMBER   DEFAULT NULL,

      p_details_text   IN CLOB     DEFAULT NULL
   );


   PROCEDURE label (
      p_logger_name    IN VARCHAR2,
      p_message_text   IN VARCHAR2,

      p_wsp_id         IN NUMBER   DEFAULT NULL,
      p_inf_id         IN NUMBER   DEFAULT NULL,
      p_req_id         IN NUMBER   DEFAULT NULL,
      p_itm_id         IN NUMBER   DEFAULT NULL,
      p_rsp_id         IN NUMBER   DEFAULT NULL,
      p_correlation_id IN VARCHAR2 DEFAULT NULL,
      p_person_id      IN NUMBER   DEFAULT NULL,
      p_icusnum        IN NUMBER   DEFAULT NULL,

      p_details_text   IN CLOB     DEFAULT NULL
   );


   PROCEDURE call_Stack (
      p_logger_name    IN VARCHAR2,
      p_message_text   IN VARCHAR2 DEFAULT NULL,

      p_wsp_id         IN NUMBER   DEFAULT NULL,
      p_inf_id         IN NUMBER   DEFAULT NULL,
      p_req_id         IN NUMBER   DEFAULT NULL,
      p_itm_id         IN NUMBER   DEFAULT NULL,
      p_rsp_id         IN NUMBER   DEFAULT NULL,
      p_correlation_id IN VARCHAR2 DEFAULT NULL,
      p_person_id      IN NUMBER   DEFAULT NULL,
      p_icusnum        IN NUMBER   DEFAULT NULL
   );


   PROCEDURE version (
      p_logger_name   IN VARCHAR2,
      p_object_name   IN VARCHAR2,
      p_version_text  IN VARCHAR2,

      p_wsp_id        IN NUMBER   DEFAULT NULL,
      p_inf_id        IN NUMBER   DEFAULT NULL
   );

END MI_Logger;
/
CREATE OR REPLACE PACKAGE BODY MI_Logger
AS

   cVersion CONSTANT VARCHAR2(100) := 'MI_Logger 1.2.0';

   g_log_enabled BOOLEAN     := TRUE;
   
   g_min_level   Level_t := LEVEL_DEBUG;


/* */
FUNCTION get_Version
   RETURN VARCHAR2
IS
BEGIN
   RETURN cVersion;
END get_Version;


FUNCTION level_Code (
   p_level IN Level_t
)
   RETURN VARCHAR2
IS
BEGIN
   RETURN CASE p_level
             WHEN LEVEL_TRACE THEN 'trc'
             WHEN LEVEL_DEBUG THEN 'dbg'
             WHEN LEVEL_INFO  THEN 'inf'
             WHEN LEVEL_WARN  THEN 'wrn'
             WHEN LEVEL_ERROR THEN 'err'

             /*
                MI_LOG v1 физически хранит только trc/dbg/inf/wrn/err.
                Пока FATAL сохраняем как err, чтобы не требовать изменения DDL
                и не терять запись из-за CHECK constraint.
             */
             WHEN LEVEL_FATAL THEN 'err'

             ELSE NULL
          END;
END level_Code;


   ---------------------------------------------------------------------------
   PROCEDURE enable_Log
   IS
   BEGIN
      g_log_enabled := TRUE;
   END enable_Log;


   ---------------------------------------------------------------------------
   PROCEDURE disable_Log
   IS
   BEGIN
      g_log_enabled := FALSE;
   END disable_Log;


   ---------------------------------------------------------------------------
   PROCEDURE set_Min_Level (
      p_level IN Level_t
   )
   IS
   BEGIN
      IF p_level IS NULL THEN
         RAISE_APPLICATION_ERROR(
            -20000,
            'MI_Logger: log level must not be NULL'
         );
      END IF;

      g_min_level := p_level;
   END set_Min_Level;


   ---------------------------------------------------------------------------
   FUNCTION is_Enabled (
      p_level IN Level_t
   )
      RETURN BOOLEAN
   IS
   BEGIN
      IF NOT g_log_enabled THEN
         RETURN FALSE;
      END IF;

      IF p_level IS NULL
         OR p_level <= LEVEL_ALL
         OR p_level >= LEVEL_OFF
      THEN
         RETURN FALSE;
      END IF;

      IF g_min_level = LEVEL_OFF THEN
         RETURN FALSE;
      END IF;

      RETURN p_level >= g_min_level;
   END is_Enabled;


   /*
      Единственная зависимость MI_Logger от корпоративного системного аудита.

      Если Oracle API системного аудита называется иначе,
      меняется только эта функция.
   */
   FUNCTION current_Au_Session_Id
      RETURN NUMBER
   IS
   BEGIN
      RETURN Auditing.V_ID_Session;

   EXCEPTION
      WHEN OTHERS THEN
         RETURN NULL;
   END current_Au_Session_Id;


   /*
      IMPORTANT:

      Выполняется В ОСНОВНОЙ транзакции, до AUTONOMOUS_TRANSACTION.

      Поэтому видит в том числе MI_REQ, созданный текущей транзакцией
      и ещё не закоммиченный.

      Явно переданные значения имеют приоритет.
   */
   PROCEDURE resolve_Context (
      
      p_wsp_id         IN  NUMBER,
      p_inf_id         IN  NUMBER,
      p_req_id         IN  NUMBER,
      
      p_correlation_id IN  VARCHAR2,

      p_wsp_od         OUT NUMBER,
      p_inf_od         OUT NUMBER,
      p_correlation_od OUT VARCHAR2
   )
   IS
      l_inf_id         NUMBER;
      l_wsp_id         NUMBER;
      l_correlation_id VARCHAR2(36);
   BEGIN

      p_wsp_od         := p_wsp_id;
      p_inf_od         := p_inf_id;
      p_correlation_od := p_correlation_id;


      /*
         REQ_ID является наиболее информативным ключом.
         Из него можем получить INF/WSP/CORRELATION.
      */
      IF p_req_id IS NOT NULL
         AND (
               p_inf_od         IS NULL
            OR p_wsp_od         IS NULL
            OR p_correlation_od IS NULL
         )
      THEN
         BEGIN

            SELECT r.inf_id,
                   i.wsp_id,
                   r.correlation_id
              INTO l_inf_id,
                   l_wsp_id,
                   l_correlation_id
              FROM MI_REQ r
              LEFT JOIN MI_INF i
                ON i.inf_id = r.inf_id
             WHERE r.req_id = p_req_id;

            IF p_inf_od IS NULL THEN
               p_inf_od := l_inf_id;
            END IF;

            IF p_wsp_od IS NULL THEN
               p_wsp_od := l_wsp_id;
            END IF;

            IF p_correlation_od IS NULL THEN
               p_correlation_od := l_correlation_id;
            END IF;

         EXCEPTION
            WHEN NO_DATA_FOUND THEN
               NULL;

            WHEN OTHERS THEN
               NULL;
         END;
      END IF;


      /*
         REQ_ID мог отсутствовать, но INF_ID известен.
      */
      IF p_wsp_od IS NULL
         AND p_inf_od IS NOT NULL
      THEN
         BEGIN

            SELECT i.wsp_id
              INTO p_wsp_od
              FROM MI_INF i
             WHERE i.inf_id = p_inf_od;

         EXCEPTION
            WHEN NO_DATA_FOUND THEN
               NULL;

            WHEN OTHERS THEN
               NULL;
         END;
      END IF;

   END resolve_Context;


   /*
      Единственная процедура, создающая автономную транзакцию.

      Никаких SELECT из MI_REQ / MI_INF здесь нет.

      MI_LOG не имеет FK, поэтому autonomous insert не зависит от
      commit state бизнес-транзакции.
   */
   PROCEDURE insert_Row_AT (
      p_au_session_id   IN NUMBER,

      p_level            IN Level_t,
      p_logger_name     IN VARCHAR2,
      p_action_code     IN VARCHAR2,
      p_message_text    IN VARCHAR2,
      p_details_text    IN CLOB,

      p_wsp_id          IN NUMBER,
      p_inf_id          IN NUMBER,

      p_req_id          IN NUMBER,
      p_itm_id          IN NUMBER,
      p_rsp_id          IN NUMBER,

      p_correlation_id  IN VARCHAR2,

      p_person_id       IN NUMBER,
      p_icusnum         IN NUMBER
   )
   IS
      PRAGMA AUTONOMOUS_TRANSACTION;

      l_level_code VARCHAR2(3);
   BEGIN
      l_level_code := level_Code(p_level);

      IF l_level_code IS NULL THEN
         RETURN;
      END IF;

      INSERT INTO MI_LOG (
         au_session_id,

         level_code,
         logger_name,
         action_code,
         message_text,
         details_text,

         wsp_id,
         inf_id,

         req_id,
         itm_id,
         rsp_id,

         correlation_id,

         person_id,
         icusnum
      )
      VALUES (
         p_au_session_id,

         l_level_code,
         SUBSTR(NVL(p_logger_name, '-'),       1, 64),
         SUBSTR(p_action_code,                  1, 64),
         SUBSTR(NVL(p_message_text, '<empty>'),1, 2000),
         p_details_text,

         p_wsp_id,
         p_inf_id,

         p_req_id,
         p_itm_id,
         p_rsp_id,

         SUBSTR(p_correlation_id, 1, 36),

         p_person_id,
         p_icusnum
      );

      COMMIT;

   EXCEPTION
      WHEN OTHERS THEN
         ROLLBACK;

         /*
            Никогда не вызываем MI_Logger отсюда:
            иначе получим рекурсивное логирование ошибки logger.
         */
         NULL;

   END insert_Row_AT;


   /* */
   PROCEDURE log (
      p_logger_name    IN VARCHAR2,
      p_message_text   IN VARCHAR2,

      p_level          IN Level_t  DEFAULT LEVEL_DEBUG,

      p_wsp_id         IN NUMBER   DEFAULT NULL,
      p_inf_id         IN NUMBER   DEFAULT NULL,

      p_req_id         IN NUMBER   DEFAULT NULL,
      p_itm_id         IN NUMBER   DEFAULT NULL,
      p_rsp_id         IN NUMBER   DEFAULT NULL,

      p_correlation_id IN VARCHAR2 DEFAULT NULL,

      p_person_id      IN NUMBER   DEFAULT NULL,
      p_icusnum        IN NUMBER   DEFAULT NULL,

      p_action_code    IN VARCHAR2 DEFAULT NULL,
      p_details_text   IN CLOB     DEFAULT NULL
   )
   IS
      l_au_session_id  NUMBER;

      l_wsp_id         NUMBER;
      l_inf_id         NUMBER;
      l_correlation_id VARCHAR2(36);
   BEGIN

      IF NOT is_Enabled(p_level) THEN
         RETURN;
      END IF;


      /*
         Важно: всё разрешение контекста выполняется ДО AT.
      */
      resolve_Context(
         p_wsp_id         => p_wsp_id,
         p_inf_id         => p_inf_id,
         p_req_id         => p_req_id,
         p_correlation_id => p_correlation_id,

         p_wsp_od         => l_wsp_id,
         p_inf_od         => l_inf_id,
         p_correlation_od => l_correlation_id
      );


      /*
         Получаем audit session тоже до автономной записи.
      */
      l_au_session_id := current_Au_Session_Id;


      /*
         AU_SESSION_ID является обязательным корпоративным contract.
         Фальшивый -1 не подставляем.
      */
      IF l_au_session_id IS NULL THEN
         RETURN;
      END IF;

      insert_Row_AT(
         p_au_session_id  => l_au_session_id,

         p_level          => p_level,
         p_logger_name    => p_logger_name,
         p_action_code    => p_action_code,
         p_message_text   => p_message_text,
         p_details_text   => p_details_text,

         p_wsp_id         => l_wsp_id,
         p_inf_id         => l_inf_id,

         p_req_id         => p_req_id,
         p_itm_id         => p_itm_id,
         p_rsp_id         => p_rsp_id,

         p_correlation_id => l_correlation_id,

         p_person_id      => p_person_id,
         p_icusnum        => p_icusnum
      );

   EXCEPTION
      WHEN OTHERS THEN
         /*
            Публичный logger никогда не ломает business flow.
         */
         NULL;

   END log;


   PROCEDURE trace (
      p_logger_name    IN VARCHAR2,
      p_message_text   IN VARCHAR2,
      p_wsp_id         IN NUMBER   DEFAULT NULL,
      p_inf_id         IN NUMBER   DEFAULT NULL,
      p_req_id         IN NUMBER   DEFAULT NULL,
      p_itm_id         IN NUMBER   DEFAULT NULL,
      p_rsp_id         IN NUMBER   DEFAULT NULL,
      p_correlation_id IN VARCHAR2 DEFAULT NULL,
      p_person_id      IN NUMBER   DEFAULT NULL,
      p_icusnum        IN NUMBER   DEFAULT NULL,
      p_action_code    IN VARCHAR2 DEFAULT NULL,
      p_details_text   IN CLOB     DEFAULT NULL
   )
   IS
   BEGIN
      log(
         p_logger_name, p_message_text, LEVEL_TRACE,
         p_wsp_id, p_inf_id,
         p_req_id, p_itm_id, p_rsp_id,
         p_correlation_id,
         p_person_id, p_icusnum,
         p_action_code, p_details_text
      );
   END trace;


   PROCEDURE debug (
      p_logger_name    IN VARCHAR2,
      p_message_text   IN VARCHAR2,
      p_wsp_id         IN NUMBER   DEFAULT NULL,
      p_inf_id         IN NUMBER   DEFAULT NULL,
      p_req_id         IN NUMBER   DEFAULT NULL,
      p_itm_id         IN NUMBER   DEFAULT NULL,
      p_rsp_id         IN NUMBER   DEFAULT NULL,
      p_correlation_id IN VARCHAR2 DEFAULT NULL,
      p_person_id      IN NUMBER   DEFAULT NULL,
      p_icusnum        IN NUMBER   DEFAULT NULL,
      p_action_code    IN VARCHAR2 DEFAULT NULL,
      p_details_text   IN CLOB     DEFAULT NULL
   )
   IS
   BEGIN
      log(
         p_logger_name, p_message_text, LEVEL_DEBUG,
         p_wsp_id, p_inf_id,
         p_req_id, p_itm_id, p_rsp_id,
         p_correlation_id,
         p_person_id, p_icusnum,
         p_action_code, p_details_text
      );
   END debug;


   PROCEDURE info (
      p_logger_name    IN VARCHAR2,
      p_message_text   IN VARCHAR2,
      p_wsp_id         IN NUMBER   DEFAULT NULL,
      p_inf_id         IN NUMBER   DEFAULT NULL,
      p_req_id         IN NUMBER   DEFAULT NULL,
      p_itm_id         IN NUMBER   DEFAULT NULL,
      p_rsp_id         IN NUMBER   DEFAULT NULL,
      p_correlation_id IN VARCHAR2 DEFAULT NULL,
      p_person_id      IN NUMBER   DEFAULT NULL,
      p_icusnum        IN NUMBER   DEFAULT NULL,
      p_action_code    IN VARCHAR2 DEFAULT NULL,
      p_details_text   IN CLOB     DEFAULT NULL
   )
   IS
   BEGIN
      log(
         p_logger_name, p_message_text, LEVEL_INFO,
         p_wsp_id, p_inf_id,
         p_req_id, p_itm_id, p_rsp_id,
         p_correlation_id,
         p_person_id, p_icusnum,
         p_action_code, p_details_text
      );
   END info;


   PROCEDURE warn (
      p_logger_name    IN VARCHAR2,
      p_message_text   IN VARCHAR2,
      p_wsp_id         IN NUMBER   DEFAULT NULL,
      p_inf_id         IN NUMBER   DEFAULT NULL,
      p_req_id         IN NUMBER   DEFAULT NULL,
      p_itm_id         IN NUMBER   DEFAULT NULL,
      p_rsp_id         IN NUMBER   DEFAULT NULL,
      p_correlation_id IN VARCHAR2 DEFAULT NULL,
      p_person_id      IN NUMBER   DEFAULT NULL,
      p_icusnum        IN NUMBER   DEFAULT NULL,
      p_action_code    IN VARCHAR2 DEFAULT NULL,
      p_details_text   IN CLOB     DEFAULT NULL
   )
   IS
   BEGIN
      log(
         p_logger_name, p_message_text, LEVEL_WARN,
         p_wsp_id, p_inf_id,
         p_req_id, p_itm_id, p_rsp_id,
         p_correlation_id,
         p_person_id, p_icusnum,
         p_action_code, p_details_text
      );
   END warn;


   PROCEDURE error (
      p_logger_name    IN VARCHAR2,
      p_message_text   IN VARCHAR2,
      p_wsp_id         IN NUMBER   DEFAULT NULL,
      p_inf_id         IN NUMBER   DEFAULT NULL,
      p_req_id         IN NUMBER   DEFAULT NULL,
      p_itm_id         IN NUMBER   DEFAULT NULL,
      p_rsp_id         IN NUMBER   DEFAULT NULL,
      p_correlation_id IN VARCHAR2 DEFAULT NULL,
      p_person_id      IN NUMBER   DEFAULT NULL,
      p_icusnum        IN NUMBER   DEFAULT NULL,
      p_action_code    IN VARCHAR2 DEFAULT NULL,
      p_details_text   IN CLOB     DEFAULT NULL
   )
   IS
   BEGIN
      log(
         p_logger_name, p_message_text, LEVEL_ERROR,
         p_wsp_id, p_inf_id,
         p_req_id, p_itm_id, p_rsp_id,
         p_correlation_id,
         p_person_id, p_icusnum,
         p_action_code, p_details_text
      );
   END error;


   PROCEDURE fatal (
      p_logger_name    IN VARCHAR2,
      p_message_text   IN VARCHAR2,
      p_wsp_id         IN NUMBER   DEFAULT NULL,
      p_inf_id         IN NUMBER   DEFAULT NULL,
      p_req_id         IN NUMBER   DEFAULT NULL,
      p_itm_id         IN NUMBER   DEFAULT NULL,
      p_rsp_id         IN NUMBER   DEFAULT NULL,
      p_correlation_id IN VARCHAR2 DEFAULT NULL,
      p_person_id      IN NUMBER   DEFAULT NULL,
      p_icusnum        IN NUMBER   DEFAULT NULL,
      p_action_code    IN VARCHAR2 DEFAULT NULL,
      p_details_text   IN CLOB     DEFAULT NULL
   )
   IS
   BEGIN
      log(
         p_logger_name, p_message_text, LEVEL_FATAL,
         p_wsp_id, p_inf_id,
         p_req_id, p_itm_id, p_rsp_id,
         p_correlation_id,
         p_person_id, p_icusnum,
         p_action_code, p_details_text
      );
   END fatal;


   ----------------------------------------------------------------------------
   PROCEDURE enter_f (
      p_logger_name    IN VARCHAR2,
      p_function_name  IN VARCHAR2,
      p_message_text   IN VARCHAR2 DEFAULT NULL,
      p_parameters     IN CLOB     DEFAULT NULL,

      p_wsp_id         IN NUMBER   DEFAULT NULL,
      p_inf_id         IN NUMBER   DEFAULT NULL,
      p_req_id         IN NUMBER   DEFAULT NULL,
      p_itm_id         IN NUMBER   DEFAULT NULL,
      p_rsp_id         IN NUMBER   DEFAULT NULL,
      p_correlation_id IN VARCHAR2 DEFAULT NULL,
      p_person_id      IN NUMBER   DEFAULT NULL,
      p_icusnum        IN NUMBER   DEFAULT NULL
   )
   IS
      l_message VARCHAR2(32767);
   BEGIN
      l_message := NVL(p_function_name, '-');

      IF p_message_text IS NOT NULL THEN
         l_message :=
            l_message
            || ': '
            || p_message_text;
      END IF;

      trace(
         p_logger_name    => p_logger_name,
         p_message_text   => l_message,

         p_wsp_id         => p_wsp_id,
         p_inf_id         => p_inf_id,
         p_req_id         => p_req_id,
         p_itm_id         => p_itm_id,
         p_rsp_id         => p_rsp_id,
         p_correlation_id => p_correlation_id,
         p_person_id      => p_person_id,
         p_icusnum        => p_icusnum,

         p_action_code    => 'enter_f',
         p_details_text   => p_parameters
      );
   END enter_f;


   ----------------------------------------------------------------------------
   PROCEDURE exit_f (
      p_logger_name    IN VARCHAR2,
      p_function_name  IN VARCHAR2,
      p_message_text   IN VARCHAR2 DEFAULT NULL,
      p_details_text   IN CLOB     DEFAULT NULL,

      p_wsp_id         IN NUMBER   DEFAULT NULL,
      p_inf_id         IN NUMBER   DEFAULT NULL,
      p_req_id         IN NUMBER   DEFAULT NULL,
      p_itm_id         IN NUMBER   DEFAULT NULL,
      p_rsp_id         IN NUMBER   DEFAULT NULL,
      p_correlation_id IN VARCHAR2 DEFAULT NULL,
      p_person_id      IN NUMBER   DEFAULT NULL,
      p_icusnum        IN NUMBER   DEFAULT NULL
   )
   IS
      l_message VARCHAR2(32767);
   BEGIN
      l_message := NVL(p_function_name, '-');

      IF p_message_text IS NOT NULL THEN
         l_message :=
            l_message
            || ': '
            || p_message_text;
      END IF;

      trace(
         p_logger_name    => p_logger_name,
         p_message_text   => l_message,

         p_wsp_id         => p_wsp_id,
         p_inf_id         => p_inf_id,
         p_req_id         => p_req_id,
         p_itm_id         => p_itm_id,
         p_rsp_id         => p_rsp_id,
         p_correlation_id => p_correlation_id,
         p_person_id      => p_person_id,
         p_icusnum        => p_icusnum,

         p_action_code    => 'exit_f',
         p_details_text   => p_details_text
      );
   END exit_f;


   ----------------------------------------------------------------------------
   PROCEDURE variable_Value (
      p_logger_name    IN VARCHAR2,
      p_variable_name  IN VARCHAR2,
      p_value_text     IN VARCHAR2,

      p_wsp_id         IN NUMBER   DEFAULT NULL,
      p_inf_id         IN NUMBER   DEFAULT NULL,
      p_req_id         IN NUMBER   DEFAULT NULL,
      p_itm_id         IN NUMBER   DEFAULT NULL,
      p_rsp_id         IN NUMBER   DEFAULT NULL,
      p_correlation_id IN VARCHAR2 DEFAULT NULL,
      p_person_id      IN NUMBER   DEFAULT NULL,
      p_icusnum        IN NUMBER   DEFAULT NULL,

      p_details_text   IN CLOB     DEFAULT NULL
   )
   IS
   BEGIN
      trace(
         p_logger_name    => p_logger_name,
         p_message_text   =>
              NVL(p_variable_name, '-')
           || ' = '
           || NVL(p_value_text, '<NULL>'),

         p_wsp_id         => p_wsp_id,
         p_inf_id         => p_inf_id,
         p_req_id         => p_req_id,
         p_itm_id         => p_itm_id,
         p_rsp_id         => p_rsp_id,
         p_correlation_id => p_correlation_id,
         p_person_id      => p_person_id,
         p_icusnum        => p_icusnum,

         p_action_code    => 'val',
         p_details_text   => p_details_text
      );
   END variable_Value;


   ----------------------------------------------------------------------------
   PROCEDURE label (
      p_logger_name    IN VARCHAR2,
      p_message_text   IN VARCHAR2,

      p_wsp_id         IN NUMBER   DEFAULT NULL,
      p_inf_id         IN NUMBER   DEFAULT NULL,
      p_req_id         IN NUMBER   DEFAULT NULL,
      p_itm_id         IN NUMBER   DEFAULT NULL,
      p_rsp_id         IN NUMBER   DEFAULT NULL,
      p_correlation_id IN VARCHAR2 DEFAULT NULL,
      p_person_id      IN NUMBER   DEFAULT NULL,
      p_icusnum        IN NUMBER   DEFAULT NULL,

      p_details_text   IN CLOB     DEFAULT NULL
   )
   IS
   BEGIN
      debug(
         p_logger_name    => p_logger_name,
         p_message_text   => p_message_text,

         p_wsp_id         => p_wsp_id,
         p_inf_id         => p_inf_id,
         p_req_id         => p_req_id,
         p_itm_id         => p_itm_id,
         p_rsp_id         => p_rsp_id,
         p_correlation_id => p_correlation_id,
         p_person_id      => p_person_id,
         p_icusnum        => p_icusnum,

         p_action_code    => 'label',
         p_details_text   => p_details_text
      );
   END label;


   ----------------------------------------------------------------------------
   PROCEDURE call_Stack (
      p_logger_name    IN VARCHAR2,
      p_message_text   IN VARCHAR2 DEFAULT NULL,

      p_wsp_id         IN NUMBER   DEFAULT NULL,
      p_inf_id         IN NUMBER   DEFAULT NULL,
      p_req_id         IN NUMBER   DEFAULT NULL,
      p_itm_id         IN NUMBER   DEFAULT NULL,
      p_rsp_id         IN NUMBER   DEFAULT NULL,
      p_correlation_id IN VARCHAR2 DEFAULT NULL,
      p_person_id      IN NUMBER   DEFAULT NULL,
      p_icusnum        IN NUMBER   DEFAULT NULL
   )
   IS
   BEGIN
      debug(
         p_logger_name    => p_logger_name,
         p_message_text   => NVL(p_message_text, 'call stack'),

         p_wsp_id         => p_wsp_id,
         p_inf_id         => p_inf_id,
         p_req_id         => p_req_id,
         p_itm_id         => p_itm_id,
         p_rsp_id         => p_rsp_id,
         p_correlation_id => p_correlation_id,
         p_person_id      => p_person_id,
         p_icusnum        => p_icusnum,

         p_action_code    => 'call_stack',
         p_details_text   => DBMS_UTILITY.format_call_stack
      );
   END call_Stack;


   ----------------------------------------------------------------------------
   PROCEDURE version (
      p_logger_name   IN VARCHAR2,
      p_object_name   IN VARCHAR2,
      p_version_text  IN VARCHAR2,

      p_wsp_id        IN NUMBER   DEFAULT NULL,
      p_inf_id        IN NUMBER   DEFAULT NULL
   )
   IS
   BEGIN
      info(
         p_logger_name  => p_logger_name,
         p_message_text =>
              NVL(p_object_name, '-')
           || ': '
           || NVL(p_version_text, '<NULL>'),

         p_wsp_id       => p_wsp_id,
         p_inf_id       => p_inf_id,

         p_action_code  => 'version'
      );
   END version;

END MI_Logger;
/
