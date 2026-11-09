CREATE OR REPLACE TYPE MI_Logger_T FORCE AS OBJECT
(
   /*
      Lightweight contextual wrapper над MI_Logger core.

      SQL object type не поддерживает private attributes: Oracle требует
      объявлять все attributes в type specification и делает их публичными.
      Поэтому encapsulation обеспечивается контрактом использования:

      - package-level экземпляр объявляется только в PACKAGE BODY;
      - logger_name, package_name и wsp_id задаются конструктором;
      - изменяемый correlation context задаётся только через context();
      - read-only методы объявляют SELF IN и могут вызываться прямо на
        package-level CONSTANT; context()/clear_Context() сохраняют SELF IN OUT;
      - persistence, context resolution, filtering и autonomous transaction
        остаются исключительно в MI_Logger package.
   */
   logger_name     VARCHAR2(64),
   package_name    VARCHAR2(50),

   wsp_id          NUMBER,
   inf_id          NUMBER,

   req_id          NUMBER,
   itm_id          NUMBER,
   rsp_id          NUMBER,

   correlation_id  VARCHAR2(36),

   person_id       NUMBER,
   icusnum         NUMBER,


   CONSTRUCTOR FUNCTION MI_Logger_T (
      p_logger_name     IN VARCHAR2,
      p_package_name    IN VARCHAR2,
      p_wsp_id          IN NUMBER DEFAULT NULL
   )
      RETURN SELF AS RESULT,


   /*
      Полностью заменяет operation context. Неуказанные параметры становятся
      NULL, поэтому context предыдущего вызова не может протечь в следующий.
   */
   MEMBER PROCEDURE context (
      p_inf_id          IN NUMBER   DEFAULT NULL,
      p_req_id          IN NUMBER   DEFAULT NULL,
      p_itm_id          IN NUMBER   DEFAULT NULL,
      p_rsp_id          IN NUMBER   DEFAULT NULL,
      p_correlation_id  IN VARCHAR2 DEFAULT NULL,
      p_person_id       IN NUMBER   DEFAULT NULL,
      p_icusnum         IN NUMBER   DEFAULT NULL
   ),


   MEMBER PROCEDURE clear_Context,


   /*
      INTEGER используется в SQL object contract, потому что package subtype
      MI_Logger.Level_t не является schema-level SQL type.
   */
   MEMBER PROCEDURE log (
      SELF             IN MI_Logger_T,
      p_level         IN INTEGER,
      p_message_text  IN VARCHAR2,
      p_action_code   IN VARCHAR2 DEFAULT NULL,
      p_details_text  IN CLOB     DEFAULT NULL
   ),


   MEMBER PROCEDURE trace (
      SELF             IN MI_Logger_T,
      p_message_text  IN VARCHAR2,
      p_action_code   IN VARCHAR2 DEFAULT NULL,
      p_details_text  IN CLOB     DEFAULT NULL
   ),


   MEMBER PROCEDURE debug (
      SELF             IN MI_Logger_T,
      p_message_text  IN VARCHAR2,
      p_action_code   IN VARCHAR2 DEFAULT NULL,
      p_details_text  IN CLOB     DEFAULT NULL
   ),


   MEMBER PROCEDURE info (
      SELF             IN MI_Logger_T,
      p_message_text  IN VARCHAR2,
      p_action_code   IN VARCHAR2 DEFAULT NULL,
      p_details_text  IN CLOB     DEFAULT NULL
   ),


   MEMBER PROCEDURE warn (
      SELF             IN MI_Logger_T,
      p_message_text  IN VARCHAR2,
      p_action_code   IN VARCHAR2 DEFAULT NULL,
      p_details_text  IN CLOB     DEFAULT NULL
   ),


   MEMBER PROCEDURE error (
      SELF             IN MI_Logger_T,
      p_message_text  IN VARCHAR2,
      p_action_code   IN VARCHAR2 DEFAULT NULL,
      p_details_text  IN CLOB     DEFAULT NULL
   ),


   MEMBER PROCEDURE fatal (
      SELF             IN MI_Logger_T,
      p_message_text  IN VARCHAR2,
      p_action_code   IN VARCHAR2 DEFAULT NULL,
      p_details_text  IN CLOB     DEFAULT NULL
   ),


   MEMBER PROCEDURE enter_f (
      SELF             IN MI_Logger_T,
      p_function_name  IN VARCHAR2,
      p_message_text   IN VARCHAR2 DEFAULT NULL,
      p_parameters     IN CLOB     DEFAULT NULL
   ),


   MEMBER PROCEDURE exit_f (
      SELF             IN MI_Logger_T,
      p_function_name  IN VARCHAR2,
      p_message_text   IN VARCHAR2 DEFAULT NULL,
      p_details_text   IN CLOB     DEFAULT NULL
   ),


   MEMBER PROCEDURE variable_Value (
      SELF             IN MI_Logger_T,
      p_variable_name  IN VARCHAR2,
      p_value_text     IN VARCHAR2,
      p_details_text   IN CLOB     DEFAULT NULL
   ),


   MEMBER PROCEDURE label (
      SELF            IN MI_Logger_T,
      p_message_text  IN VARCHAR2,
      p_details_text  IN CLOB DEFAULT NULL
   ),


   MEMBER PROCEDURE call_Stack (
      SELF            IN MI_Logger_T,
      p_message_text  IN VARCHAR2 DEFAULT NULL
   ),


   MEMBER PROCEDURE version (
      SELF             IN MI_Logger_T,
      p_object_name   IN VARCHAR2,
      p_version_text  IN VARCHAR2
   )
);
/

CREATE OR REPLACE TYPE BODY MI_Logger_T
IS

   ---------------------------------------------------------------------------
   CONSTRUCTOR FUNCTION MI_Logger_T (
      p_logger_name     IN VARCHAR2,
      p_package_name    IN VARCHAR2,
      p_wsp_id          IN NUMBER DEFAULT NULL
   )
      RETURN SELF AS RESULT
   IS
   BEGIN
      SELF.logger_name    := SUBSTR(NVL(p_logger_name, '-'), 1, 64);
      SELF.package_name   := SUBSTR(NVL(p_package_name, '-'), 1, 50);

      SELF.wsp_id         := p_wsp_id;
      SELF.inf_id         := NULL;

      SELF.req_id         := NULL;
      SELF.itm_id         := NULL;
      SELF.rsp_id         := NULL;

      SELF.correlation_id := NULL;

      SELF.person_id      := NULL;
      SELF.icusnum        := NULL;

      RETURN;
   END MI_Logger_T;


   ---------------------------------------------------------------------------
   MEMBER PROCEDURE context (
      p_inf_id          IN NUMBER   DEFAULT NULL,
      p_req_id          IN NUMBER   DEFAULT NULL,
      p_itm_id          IN NUMBER   DEFAULT NULL,
      p_rsp_id          IN NUMBER   DEFAULT NULL,
      p_correlation_id  IN VARCHAR2 DEFAULT NULL,
      p_person_id       IN NUMBER   DEFAULT NULL,
      p_icusnum         IN NUMBER   DEFAULT NULL
   )
   IS
   BEGIN
      SELF.inf_id         := p_inf_id;

      SELF.req_id         := p_req_id;
      SELF.itm_id         := p_itm_id;
      SELF.rsp_id         := p_rsp_id;

      SELF.correlation_id := SUBSTR(p_correlation_id, 1, 36);

      SELF.person_id      := p_person_id;
      SELF.icusnum        := p_icusnum;
   END context;


   ---------------------------------------------------------------------------
   MEMBER PROCEDURE clear_Context
   IS
   BEGIN
      SELF.inf_id         := NULL;

      SELF.req_id         := NULL;
      SELF.itm_id         := NULL;
      SELF.rsp_id         := NULL;

      SELF.correlation_id := NULL;

      SELF.person_id      := NULL;
      SELF.icusnum        := NULL;
   END clear_Context;


   ---------------------------------------------------------------------------
   MEMBER PROCEDURE log (
      SELF             IN MI_Logger_T,
      p_level         IN INTEGER,
      p_message_text  IN VARCHAR2,
      p_action_code   IN VARCHAR2 DEFAULT NULL,
      p_details_text  IN CLOB     DEFAULT NULL
   )
   IS
   BEGIN
      MI_Logger.log(
         p_logger_name    => SELF.logger_name,
         p_message_text   => p_message_text,
         p_level          => p_level,

         p_wsp_id         => SELF.wsp_id,
         p_inf_id         => SELF.inf_id,

         p_req_id         => SELF.req_id,
         p_itm_id         => SELF.itm_id,
         p_rsp_id         => SELF.rsp_id,

         p_correlation_id => SELF.correlation_id,

         p_person_id      => SELF.person_id,
         p_icusnum        => SELF.icusnum,

         p_action_code    => p_action_code,
         p_details_text   => p_details_text
      );

   EXCEPTION
      WHEN OTHERS THEN
         /*
            Wrapper сохраняет базовый contract MI logging subsystem:
            logging никогда не ломает business flow.
         */
         NULL;
   END log;


   ---------------------------------------------------------------------------
   MEMBER PROCEDURE trace (
      SELF             IN MI_Logger_T,
      p_message_text  IN VARCHAR2,
      p_action_code   IN VARCHAR2 DEFAULT NULL,
      p_details_text  IN CLOB     DEFAULT NULL
   )
   IS
   BEGIN
      SELF.log(
         p_level        => MI_Logger.LEVEL_TRACE,
         p_message_text => p_message_text,
         p_action_code  => p_action_code,
         p_details_text => p_details_text
      );
   END trace;


   ---------------------------------------------------------------------------
   MEMBER PROCEDURE debug (
      SELF             IN MI_Logger_T,
      p_message_text  IN VARCHAR2,
      p_action_code   IN VARCHAR2 DEFAULT NULL,
      p_details_text  IN CLOB     DEFAULT NULL
   )
   IS
   BEGIN
      SELF.log(
         p_level        => MI_Logger.LEVEL_DEBUG,
         p_message_text => p_message_text,
         p_action_code  => p_action_code,
         p_details_text => p_details_text
      );
   END debug;


   ---------------------------------------------------------------------------
   MEMBER PROCEDURE info (
      SELF             IN MI_Logger_T,
      p_message_text  IN VARCHAR2,
      p_action_code   IN VARCHAR2 DEFAULT NULL,
      p_details_text  IN CLOB     DEFAULT NULL
   )
   IS
   BEGIN
      SELF.log(
         p_level        => MI_Logger.LEVEL_INFO,
         p_message_text => p_message_text,
         p_action_code  => p_action_code,
         p_details_text => p_details_text
      );
   END info;


   ---------------------------------------------------------------------------
   MEMBER PROCEDURE warn (
      SELF             IN MI_Logger_T,
      p_message_text  IN VARCHAR2,
      p_action_code   IN VARCHAR2 DEFAULT NULL,
      p_details_text  IN CLOB     DEFAULT NULL
   )
   IS
   BEGIN
      SELF.log(
         p_level        => MI_Logger.LEVEL_WARN,
         p_message_text => p_message_text,
         p_action_code  => p_action_code,
         p_details_text => p_details_text
      );
   END warn;


   ---------------------------------------------------------------------------
   MEMBER PROCEDURE error (
      SELF             IN MI_Logger_T,
      p_message_text  IN VARCHAR2,
      p_action_code   IN VARCHAR2 DEFAULT NULL,
      p_details_text  IN CLOB     DEFAULT NULL
   )
   IS
   BEGIN
      SELF.log(
         p_level        => MI_Logger.LEVEL_ERROR,
         p_message_text => p_message_text,
         p_action_code  => p_action_code,
         p_details_text => p_details_text
      );
   END error;


   ---------------------------------------------------------------------------
   MEMBER PROCEDURE fatal (
      SELF             IN MI_Logger_T,
      p_message_text  IN VARCHAR2,
      p_action_code   IN VARCHAR2 DEFAULT NULL,
      p_details_text  IN CLOB     DEFAULT NULL
   )
   IS
   BEGIN
      SELF.log(
         p_level        => MI_Logger.LEVEL_FATAL,
         p_message_text => p_message_text,
         p_action_code  => p_action_code,
         p_details_text => p_details_text
      );
   END fatal;


   ---------------------------------------------------------------------------
   MEMBER PROCEDURE enter_f (
      SELF             IN MI_Logger_T,
      p_function_name  IN VARCHAR2,
      p_message_text   IN VARCHAR2 DEFAULT NULL,
      p_parameters     IN CLOB     DEFAULT NULL
   )
   IS
      l_function_name VARCHAR2(32767);
      l_message       VARCHAR2(32767);
   BEGIN
      l_function_name := NVL(p_function_name, '-');

      IF SELF.package_name IS NOT NULL
         AND INSTR(l_function_name, '.') = 0
      THEN
         l_function_name := SELF.package_name || '.' || l_function_name;
      END IF;

      l_message := l_function_name;

      IF p_message_text IS NOT NULL THEN
         l_message :=
            l_message
            || ': '
            || p_message_text;
      END IF;

      SELF.log(
         p_level        => MI_Logger.LEVEL_TRACE,
         p_message_text => l_message,
         p_action_code  => 'enter_f',
         p_details_text => p_parameters
      );
   END enter_f;


   ---------------------------------------------------------------------------
   MEMBER PROCEDURE exit_f (
      SELF             IN MI_Logger_T,
      p_function_name  IN VARCHAR2,
      p_message_text   IN VARCHAR2 DEFAULT NULL,
      p_details_text   IN CLOB     DEFAULT NULL
   )
   IS
      l_function_name VARCHAR2(32767);
      l_message       VARCHAR2(32767);
   BEGIN
      l_function_name := NVL(p_function_name, '-');

      IF SELF.package_name IS NOT NULL
         AND INSTR(l_function_name, '.') = 0
      THEN
         l_function_name := SELF.package_name || '.' || l_function_name;
      END IF;

      l_message := l_function_name;

      IF p_message_text IS NOT NULL THEN
         l_message :=
            l_message
            || ': '
            || p_message_text;
      END IF;

      SELF.log(
         p_level        => MI_Logger.LEVEL_TRACE,
         p_message_text => l_message,
         p_action_code  => 'exit_f',
         p_details_text => p_details_text
      );
   END exit_f;


   ---------------------------------------------------------------------------
   MEMBER PROCEDURE variable_Value (
      SELF             IN MI_Logger_T,
      p_variable_name  IN VARCHAR2,
      p_value_text     IN VARCHAR2,
      p_details_text   IN CLOB     DEFAULT NULL
   )
   IS
   BEGIN
      SELF.log(
         p_level        => MI_Logger.LEVEL_TRACE,
         p_message_text =>
              NVL(p_variable_name, '-')
           || ' = '
           || NVL(p_value_text, '<NULL>'),
         p_action_code  => 'val',
         p_details_text => p_details_text
      );
   END variable_Value;


   ---------------------------------------------------------------------------
   MEMBER PROCEDURE label (
      SELF            IN MI_Logger_T,
      p_message_text  IN VARCHAR2,
      p_details_text  IN CLOB DEFAULT NULL
   )
   IS
   BEGIN
      SELF.log(
         p_level        => MI_Logger.LEVEL_DEBUG,
         p_message_text => p_message_text,
         p_action_code  => 'label',
         p_details_text => p_details_text
      );
   END label;


   ---------------------------------------------------------------------------
   MEMBER PROCEDURE call_Stack (
      SELF            IN MI_Logger_T,
      p_message_text  IN VARCHAR2 DEFAULT NULL
   )
   IS
   BEGIN
      SELF.log(
         p_level        => MI_Logger.LEVEL_DEBUG,
         p_message_text => NVL(p_message_text, 'call stack'),
         p_action_code  => 'call_stack',
         p_details_text => DBMS_UTILITY.format_call_stack
      );
   END call_Stack;


   ---------------------------------------------------------------------------
   MEMBER PROCEDURE version (
      SELF             IN MI_Logger_T,
      p_object_name   IN VARCHAR2,
      p_version_text  IN VARCHAR2
   )
   IS
   BEGIN
      SELF.log(
         p_level        => MI_Logger.LEVEL_INFO,
         p_message_text =>
              NVL(p_object_name, SELF.package_name)
           || ': '
           || NVL(p_version_text, '<NULL>'),
         p_action_code  => 'version'
      );
   END version;

END;
/
