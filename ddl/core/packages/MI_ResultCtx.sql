CREATE OR REPLACE PACKAGE MI_ResultCtx
IS
   PRAGMA SERIALLY_REUSABLE;


   VERSION CONSTANT VARCHAR2(100) :=
      '$Id: {1.0.0} {07.11.2026} Sulimoff$';


   cResult_Success CONSTANT VARCHAR2(100) := 'SUCCESS';
   cResult_Error   CONSTANT VARCHAR2(100) := 'ERROR';

   /*
      Технический код transport exception.

      Он не является бизнес-кодом ошибки.
      Реальный код результата хранится в exec_Result_t.result_code.
   */
   cResult_Failed_Code CONSTANT PLS_INTEGER := -20002;


   /*
      Результат выполнения операции.

      parameters — произвольный набор именованных строковых параметров.
      Тип объявлен в MI_Utils, чтобы использовать единый контракт
      во всём MI Core.
   */
   TYPE exec_Result_t IS RECORD
   (
      is_success      BOOLEAN,

      result_code     VARCHAR2(100),
      result_info     VARCHAR2(300),
      result_details  CLOB,

      cause_code      VARCHAR2(100),
      cause_info      VARCHAR2(2000),
      cause_details   CLOB,

      parameters      MI_Utils.ParameterList_t
   );


   /*
      Исключение-транспорт для exec_Result_t.

      Структурированный результат хранится во внутреннем package state
      и существует только в пределах текущего server call.
   */
   result_Failed_Exc EXCEPTION;

   PRAGMA EXCEPTION_INIT(
      result_Failed_Exc,
      -20002
   );


   FUNCTION get_Version
      RETURN VARCHAR2;


   FUNCTION success (
      p_code     IN VARCHAR2 DEFAULT NULL,
      p_info     IN VARCHAR2 DEFAULT 'Завершено успешно',
      p_details  IN CLOB     DEFAULT NULL
   )
      RETURN exec_Result_t;


   FUNCTION failure (
      p_code          IN VARCHAR2 DEFAULT NULL,
      p_info          IN VARCHAR2 DEFAULT 'Операция завершилась ошибкой',
      p_details       IN CLOB     DEFAULT NULL,

      p_cause_code    IN VARCHAR2 DEFAULT NULL,
      p_cause_info    IN VARCHAR2 DEFAULT NULL,
      p_cause_details IN CLOB     DEFAULT NULL
   )
      RETURN exec_Result_t;


   FUNCTION is_Success (
      p_result IN exec_Result_t
   )
      RETURN BOOLEAN;


   FUNCTION is_Failed (
      p_result IN exec_Result_t
   )
      RETURN BOOLEAN;


   /*
      Доступ к текущему structured result, сохранённому transport exception.
   */
   FUNCTION has_Current_Result
      RETURN BOOLEAN;


   FUNCTION current_Result
      RETURN exec_Result_t;


   PROCEDURE clear_Current;


   /*
      Бросить structured error.

      Если p_result успешный, процедура ничего не делает.
   */
   PROCEDURE raise_Error (
      p_result IN exec_Result_t
   );


   PROCEDURE raise_Error (
      p_code          IN VARCHAR2,
      p_info          IN VARCHAR2 DEFAULT 'Операция завершилась ошибкой',
      p_details       IN CLOB     DEFAULT NULL,

      p_cause_code    IN VARCHAR2 DEFAULT NULL,
      p_cause_info    IN VARCHAR2 DEFAULT NULL,
      p_cause_details IN CLOB     DEFAULT NULL
   );


   /*
      Преобразовать пойманное Oracle exception в exec_Result_t.

      Вызывать из EXCEPTION handler:

         l_result := MI_ResultCtx.from_Exception(
            p_sqlcode => SQLCODE,
            p_sqlerrm => SQLERRM
         );

      SQLCODE/SQLERRM передаются явно, потому что вне exception handler
      SQLCODE возвращает 0.

      Если p_sqlcode = cResult_Failed_Code и package содержит current result,
      исходный structured result возвращается без потери данных.
   */
   FUNCTION from_Exception (
      p_sqlcode IN PLS_INTEGER,
      p_sqlerrm IN VARCHAR2,

      p_code    IN VARCHAR2 DEFAULT NULL,
      p_info    IN VARCHAR2 DEFAULT NULL,
      p_details IN CLOB     DEFAULT NULL
   )
      RETURN exec_Result_t;


   /*
      Обернуть существующий result новым уровнем ошибки.

      Исходный result становится cause.
      Его parameters сохраняются.
   */
   FUNCTION wrap_Exception (
      p_cause   IN exec_Result_t,

      p_code    IN VARCHAR2,
      p_info    IN VARCHAR2 DEFAULT 'Операция завершилась ошибкой',
      p_details IN CLOB     DEFAULT NULL
   )
      RETURN exec_Result_t;

END MI_ResultCtx;
/

CREATE OR REPLACE PACKAGE BODY MI_ResultCtx
IS
   PRAGMA SERIALLY_REUSABLE;


   g_exec_result exec_Result_t;
   g_has_current BOOLEAN := FALSE;


   ---------------------------------------------------------------------------
   FUNCTION get_Version
      RETURN VARCHAR2
   IS
   BEGIN
      RETURN VERSION;
   END get_Version;


   ---------------------------------------------------------------------------
   PROCEDURE clear_Current
   IS
   BEGIN
      g_exec_result.is_success     := NULL;

      g_exec_result.result_code    := NULL;
      g_exec_result.result_info    := NULL;
      g_exec_result.result_details := NULL;

      g_exec_result.cause_code     := NULL;
      g_exec_result.cause_info     := NULL;
      g_exec_result.cause_details  := NULL;

      g_exec_result.parameters.DELETE;

      g_has_current := FALSE;
   END clear_Current;


   ---------------------------------------------------------------------------
   PROCEDURE set_Current (
      p_result IN exec_Result_t
   )
   IS
   BEGIN
      g_exec_result.is_success     := p_result.is_success;

      g_exec_result.result_code    := p_result.result_code;
      g_exec_result.result_info    := p_result.result_info;
      g_exec_result.result_details := p_result.result_details;

      g_exec_result.cause_code     := p_result.cause_code;
      g_exec_result.cause_info     := p_result.cause_info;
      g_exec_result.cause_details  := p_result.cause_details;

      g_exec_result.parameters := p_result.parameters;

      g_has_current := TRUE;
   END set_Current;


   ---------------------------------------------------------------------------
   FUNCTION has_Current_Result
      RETURN BOOLEAN
   IS
   BEGIN
      RETURN g_has_current;
   END has_Current_Result;


   ---------------------------------------------------------------------------
   FUNCTION current_Result
      RETURN exec_Result_t
   IS
   BEGIN
      RETURN g_exec_result;
   END current_Result;


   ---------------------------------------------------------------------------
   FUNCTION success (
      p_code     IN VARCHAR2 DEFAULT NULL,
      p_info     IN VARCHAR2 DEFAULT 'Завершено успешно',
      p_details  IN CLOB     DEFAULT NULL
   )
      RETURN exec_Result_t
   IS
      l_result exec_Result_t;
   BEGIN
      l_result.is_success := TRUE;

      l_result.result_code :=
         SUBSTR(
            NVL(p_code, cResult_Success),
            1,
            100
         );

      l_result.result_info :=
         SUBSTR(
            p_info,
            1,
            300
         );

      l_result.result_details := p_details;

      RETURN l_result;
   END success;


   ---------------------------------------------------------------------------
   FUNCTION failure (
      p_code          IN VARCHAR2 DEFAULT NULL,
      p_info          IN VARCHAR2 DEFAULT 'Операция завершилась ошибкой',
      p_details       IN CLOB     DEFAULT NULL,

      p_cause_code    IN VARCHAR2 DEFAULT NULL,
      p_cause_info    IN VARCHAR2 DEFAULT NULL,
      p_cause_details IN CLOB     DEFAULT NULL
   )
      RETURN exec_Result_t
   IS
      l_result exec_Result_t;
   BEGIN
      l_result.is_success := FALSE;

      l_result.result_code :=
         SUBSTR(
            NVL(p_code, cResult_Error),
            1,
            100
         );

      l_result.result_info :=
         SUBSTR(
            p_info,
            1,
            300
         );

      l_result.result_details := p_details;

      l_result.cause_code :=
         SUBSTR(
            p_cause_code,
            1,
            100
         );

      l_result.cause_info :=
         SUBSTR(
            p_cause_info,
            1,
            2000
         );

      l_result.cause_details := p_cause_details;

      RETURN l_result;
   END failure;


   ---------------------------------------------------------------------------
   FUNCTION is_Success (
      p_result IN exec_Result_t
   )
      RETURN BOOLEAN
   IS
   BEGIN
      IF p_result.is_success THEN
         RETURN TRUE;
      END IF;

      RETURN FALSE;
   END is_Success;


   ---------------------------------------------------------------------------
   FUNCTION is_Failed (
      p_result IN exec_Result_t
   )
      RETURN BOOLEAN
   IS
   BEGIN
      RETURN NOT is_Success(p_result);
   END is_Failed;


   ---------------------------------------------------------------------------
   FUNCTION oracle_Error_Code (
      p_sqlcode IN PLS_INTEGER
   )
      RETURN VARCHAR2
   IS
   BEGIN
      IF p_sqlcode = 1 THEN
         RETURN 'USER_DEFINED_EXCEPTION';
      ELSIF p_sqlcode = 100 THEN
         RETURN 'ORA-01403';
      ELSIF p_sqlcode < 0 THEN
         RETURN 'ORA-' || LPAD(TO_CHAR(ABS(p_sqlcode)), 5, '0');
      ELSIF p_sqlcode = 0 THEN
         RETURN NULL;
      ELSE
         RETURN 'ORA-' || TO_CHAR(p_sqlcode);
      END IF;
   END oracle_Error_Code;


   ---------------------------------------------------------------------------
   FUNCTION current_Error_Details
      RETURN CLOB
   IS
      l_stack      VARCHAR2(4000);
      l_backtrace  VARCHAR2(4000);
      l_details    CLOB;
   BEGIN
      l_stack     := DBMS_UTILITY.format_error_stack;
      l_backtrace := DBMS_UTILITY.format_error_backtrace;

      IF l_stack IS NOT NULL THEN
         l_details := l_stack;
      END IF;

      IF l_backtrace IS NOT NULL THEN
         IF l_details IS NOT NULL THEN
            l_details := l_details || CHR(10);
         END IF;

         l_details :=
            l_details
            || 'BACKTRACE:'
            || CHR(10)
            || l_backtrace;
      END IF;

      RETURN l_details;
   END current_Error_Details;


   ---------------------------------------------------------------------------
   FUNCTION wrapped_Cause_Details (
      p_result IN exec_Result_t
   )
      RETURN CLOB
   IS
      l_details CLOB;
   BEGIN
      l_details := p_result.result_details;

      IF p_result.cause_code IS NOT NULL
         OR p_result.cause_info IS NOT NULL
         OR p_result.cause_details IS NOT NULL
      THEN
         IF l_details IS NOT NULL THEN
            l_details := l_details || CHR(10);
         END IF;

         l_details := l_details || 'CAUSE:';

         IF p_result.cause_code IS NOT NULL THEN
            l_details :=
               l_details
               || ' '
               || p_result.cause_code;
         END IF;

         IF p_result.cause_info IS NOT NULL THEN
            l_details :=
               l_details
               || CHR(10)
               || p_result.cause_info;
         END IF;

         IF p_result.cause_details IS NOT NULL THEN
            l_details :=
               l_details
               || CHR(10)
               || p_result.cause_details;
         END IF;
      END IF;

      RETURN l_details;
   END wrapped_Cause_Details;


   ---------------------------------------------------------------------------
   PROCEDURE raise_Error (
      p_result IN exec_Result_t
   )
   IS
      l_result  exec_Result_t;
      l_message VARCHAR2(2000);
   BEGIN
      /*
         raise_Error(success) является no-op.
      */
      IF is_Success(p_result) THEN
         RETURN;
      END IF;


      l_result := p_result;

      l_result.is_success := FALSE;

      IF l_result.result_code IS NULL THEN
         l_result.result_code := cResult_Error;
      ELSE
         l_result.result_code :=
            SUBSTR(
               l_result.result_code,
               1,
               100
            );
      END IF;

      l_result.result_info :=
         SUBSTR(
            l_result.result_info,
            1,
            300
         );

      l_result.cause_code :=
         SUBSTR(
            l_result.cause_code,
            1,
            100
         );

      l_result.cause_info :=
         SUBSTR(
            l_result.cause_info,
            1,
            2000
         );


      set_Current(l_result);


      l_message := l_result.result_code;

      IF l_result.result_info IS NOT NULL THEN
         l_message :=
            l_message
            || ': '
            || l_result.result_info;
      END IF;


      RAISE_APPLICATION_ERROR(
         cResult_Failed_Code,
         SUBSTR(l_message, 1, 2000)
      );

   END raise_Error;


   ---------------------------------------------------------------------------
   PROCEDURE raise_Error (
      p_code          IN VARCHAR2,
      p_info          IN VARCHAR2 DEFAULT 'Операция завершилась ошибкой',
      p_details       IN CLOB     DEFAULT NULL,

      p_cause_code    IN VARCHAR2 DEFAULT NULL,
      p_cause_info    IN VARCHAR2 DEFAULT NULL,
      p_cause_details IN CLOB     DEFAULT NULL
   )
   IS
      l_result exec_Result_t;
   BEGIN
      l_result :=
         failure(
            p_code          => p_code,
            p_info          => p_info,
            p_details       => p_details,
            p_cause_code    => p_cause_code,
            p_cause_info    => p_cause_info,
            p_cause_details => p_cause_details
         );

      raise_Error(l_result);
   END raise_Error;


   ---------------------------------------------------------------------------
   FUNCTION from_Exception (
      p_sqlcode IN PLS_INTEGER,
      p_sqlerrm IN VARCHAR2,

      p_code    IN VARCHAR2 DEFAULT NULL,
      p_info    IN VARCHAR2 DEFAULT NULL,
      p_details IN CLOB     DEFAULT NULL
   )
      RETURN exec_Result_t
   IS
      l_result exec_Result_t;
   BEGIN
      /*
         Наш transport exception: возвращаем исходный structured result.
      */
      IF p_sqlcode = cResult_Failed_Code
         AND g_has_current
      THEN
         RETURN g_exec_result;
      END IF;


      l_result :=
         failure(
            p_code          => NVL(p_code, 'UNEXPECTED_ERROR'),
            p_info          => NVL(p_info, 'Внутренняя ошибка системы'),
            p_details       => p_details,

            p_cause_code    => oracle_Error_Code(p_sqlcode),
            p_cause_info    => p_sqlerrm,
            p_cause_details => current_Error_Details
         );


      l_result.parameters('sqlcode') := TO_CHAR(p_sqlcode);

      RETURN l_result;
   END from_Exception;


   ---------------------------------------------------------------------------
   FUNCTION wrap_Exception (
      p_cause   IN exec_Result_t,

      p_code    IN VARCHAR2,
      p_info    IN VARCHAR2 DEFAULT 'Операция завершилась ошибкой',
      p_details IN CLOB     DEFAULT NULL
   )
      RETURN exec_Result_t
   IS
      l_result exec_Result_t;
   BEGIN
      l_result :=
         failure(
            p_code          => p_code,
            p_info          => p_info,
            p_details       => p_details,

            p_cause_code    => p_cause.result_code,
            p_cause_info    => p_cause.result_info,
            p_cause_details => wrapped_Cause_Details(p_cause)
         );


      /*
         Технический контекст исходной ошибки не теряем.
      */
      l_result.parameters := p_cause.parameters;


      RETURN l_result;
   END wrap_Exception;

END MI_ResultCtx;
/
