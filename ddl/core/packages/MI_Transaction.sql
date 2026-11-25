CREATE OR REPLACE PACKAGE MI_Transaction
IS

   /*
      Сервисный пакет по работе с транзакцией и savepoint
   
   */

   /* */
   VERSION CONSTANT VARCHAR2(100) := '$Id: {1.0.0} {19.11.2026} Sulimoff$';

   /* */
   FUNCTION get_Version
      RETURN VARCHAR2;


   /*
      Откатывает только работу после указанного DCL savepoint.

      Имя очищается до вызова DCL.RollBack, чтобы ошибка самого DCL не
      инициировала повторную попытку rollback из внешнего exception handler.
      NULL savepoint считается успешно обработанным.

      Функция не выполняет COMMIT или полный ROLLBACK.
   */
   FUNCTION rollback_Savepoint (
      p_name  IN OUT NOCOPY DCL.T_Name,
      p_log   IN            MI_Logger_T
   )
      RETURN BOOLEAN;


   /*
      Вариант для веток, где rollback является best effort и результат
      сообщается через вызывающий business API.

      FALSE/NULL протоколируется как warning. Исключение DCL не подавляется:
      вызывающий exception handler сохраняет прежний контроль над ним.
   */
   PROCEDURE rollback_And_Warn (
      p_name  IN OUT NOCOPY DCL.T_Name,
      p_log   IN            MI_Logger_T
   );

END MI_Transaction;
/
CREATE OR REPLACE PACKAGE BODY MI_Transaction
IS

   /* */
   FUNCTION get_Version
      RETURN VARCHAR2
   IS
   BEGIN
      RETURN VERSION;
   END get_Version;


   /* */
   FUNCTION rollback_Savepoint_Impl (
      p_name IN OUT NOCOPY DCL.T_Name
   )
      RETURN BOOLEAN
   IS
      l_name DCL.T_Name;
   BEGIN
      IF p_name IS NULL THEN
         RETURN TRUE;
      END IF;

      l_name := p_name;
      p_name := NULL;

      RETURN DCL.RollBack(l_name);
   END rollback_Savepoint_Impl;



   /* */
   FUNCTION rollback_Savepoint (
      p_name  IN OUT NOCOPY DCL.T_Name,
      p_log   IN            MI_Logger_T
   )
      RETURN BOOLEAN
   IS
      l_name DCL.T_Name;
      l_result BOOLEAN;
   BEGIN
      l_name := p_name;
      l_result := rollback_Savepoint_Impl(p_name);

      RETURN l_result IS NOT NULL AND l_result;

   EXCEPTION
      WHEN OTHERS THEN
         p_log.error (
            p_message_text => 'DCL rollback failed',
            p_action_code  => 'rollback',
            p_details_text => TO_CLOB( 'savepoint=' || l_name || '; error='  || SQLERRM )
         );

         RETURN FALSE;
   END rollback_Savepoint;


   /* */
   PROCEDURE rollback_And_Warn (
      p_name  IN OUT NOCOPY DCL.T_Name,
      p_log   IN            MI_Logger_T
   )
   IS
      l_result BOOLEAN;
   BEGIN
      l_result := rollback_Savepoint_Impl(p_name);

      IF l_result IS NULL OR NOT l_result THEN
         p_log.warn(
            p_message_text => 'DCL rollback was not performed',
            p_action_code  => 'rollback_skipped'
         );
      END IF;
   END rollback_And_Warn;

END MI_Transaction;
/
