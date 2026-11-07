CREATE OR REPLACE PACKAGE MI_Utils
IS

  VERSION CONSTANT VARCHAR2(100) := '$Id: {1.1.0} {07.11.2026} Sulimoff$';


   ----------------------------------------------------------------------------
   -- Набор именованных параметров.
   --
   -- Значения хранятся в строковом представлении.
   ----------------------------------------------------------------------------
   TYPE ParameterList_t IS TABLE OF VARCHAR2(2000)
      INDEX BY VARCHAR2(100);


   ----------------------------------------------------------------------------
   -- Расширенное представление атрибута.
   ----------------------------------------------------------------------------
   TYPE Attribute_Rec_t IS RECORD
   (
      name         VARCHAR2(100),
      value        VARCHAR2(2000),
      data_type    VARCHAR2(50),
      format_mask  VARCHAR2(50)
   );


   TYPE Attribute_List_t IS TABLE OF Attribute_Rec_t;


   ----------------------------------------------------------------------------
   -- Каноническое текстовое представление UUID:
   -- xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
   ----------------------------------------------------------------------------
   SUBTYPE Uuid_t IS VARCHAR2(36);


   ----------------------------------------------------------------------------
   FUNCTION get_Version
      RETURN VARCHAR2;


   ----------------------------------------------------------------------------
   -- ParameterList_t -> Attribute_List_t.
   --
   -- ParameterList_t содержит только строковые значения, поэтому
   -- data_type заполняется значением 'string'.
   ----------------------------------------------------------------------------
   FUNCTION to_Attribute_List (
      p_parameters IN ParameterList_t
   )
      RETURN Attribute_List_t;


   ----------------------------------------------------------------------------
   FUNCTION to_Bool (
      p_value IN PLS_INTEGER
   )
      RETURN BOOLEAN;


   ----------------------------------------------------------------------------
   FUNCTION to_Number (
      p_value IN BOOLEAN
   )
      RETURN PLS_INTEGER;


   ----------------------------------------------------------------------------
   FUNCTION to_Char (
      p_value IN BOOLEAN
   )
      RETURN VARCHAR2;


   ----------------------------------------------------------------------------
   FUNCTION to_Bool (
      p_value IN VARCHAR2
   )
      RETURN BOOLEAN;


   ----------------------------------------------------------------------------
   FUNCTION to_Money (
      p_value IN VARCHAR2
   )
      RETURN NUMBER;


   ----------------------------------------------------------------------------
   -- UUID version 7 согласно RFC 9562.
   --
   -- Первые 48 бит содержат Unix timestamp в миллисекундах UTC.
   -- Остальные биты, кроме version/variant, заполняются случайными данными.
   ----------------------------------------------------------------------------
   FUNCTION uuid_V7
      RETURN Uuid_t;

END MI_Utils;
/
CREATE OR REPLACE PACKAGE BODY MI_Utils
IS

   cFmt_Money     CONSTANT VARCHAR2(50) := 'FM9999999999999990D99999999';

   t_unix_Epoch   CONSTANT TIMESTAMP := TIMESTAMP '1970-01-01 00:00:00';

   /* */
   FUNCTION get_Version
      RETURN VARCHAR2
   IS
   BEGIN
      RETURN VERSION;
   END get_Version;


   /* */
   FUNCTION to_Attribute_List (
      p_parameters IN ParameterList_t
   )
      RETURN Attribute_List_t
   IS
      l_attributes Attribute_List_t := Attribute_List_t();

      l_key        VARCHAR2(100);
      l_attribute  Attribute_Rec_t;
   BEGIN

      IF p_parameters.COUNT = 0 THEN
         RETURN l_attributes;
      END IF;


      l_key := p_parameters.FIRST;

      WHILE l_key IS NOT NULL LOOP

         l_attribute.name        := l_key;
         l_attribute.value       := p_parameters(l_key);
         l_attribute.data_type   := 'string';
         l_attribute.format_mask := NULL;

         l_attributes.EXTEND;
         l_attributes(l_attributes.LAST) := l_attribute;

         l_key := p_parameters.NEXT(l_key);

      END LOOP;


      RETURN l_attributes;

   END to_Attribute_List;


   /* */
   FUNCTION to_Bool (
      p_value IN PLS_INTEGER
   )
      RETURN BOOLEAN
   IS
   BEGIN

      IF p_value IS NULL THEN
         RETURN NULL;
      END IF;

      RETURN p_value <> 0;

   END to_Bool;


   /* */
   FUNCTION to_Number (
      p_value IN BOOLEAN
   )
      RETURN PLS_INTEGER
   IS
   BEGIN

      IF p_value IS NULL THEN
         RETURN NULL;
      END IF;

      IF p_value THEN
         RETURN 1;
      ELSE
         RETURN 0;
      END IF;

   END to_Number;


   /* */
   FUNCTION to_Char (
      p_value IN BOOLEAN
   )
      RETURN VARCHAR2
   IS
   BEGIN

      IF p_value IS NULL THEN
         RETURN NULL;
      END IF;

      IF p_value THEN
         RETURN 'true';
      ELSE
         RETURN 'false';
      END IF;

   END to_Char;


   /* */
   FUNCTION to_Bool (
      p_value IN VARCHAR2
   )
      RETURN BOOLEAN
   IS
      l_value VARCHAR2(100);
   BEGIN

      IF p_value IS NULL THEN
         RETURN NULL;
      END IF;

      l_value := UPPER(TRIM(p_value));

      IF l_value IN ( 'TRUE', '1', 'ON', 'ИСТИНА', 'ДА', 'OK' )
      THEN
         RETURN TRUE;
      END IF;


      IF l_value IN ( 'FALSE', '0', 'OFF', 'ЛОЖЬ', 'НЕТ', 'FAIL' )
      THEN
         RETURN FALSE;
      END IF;

      RAISE VALUE_ERROR;

   END to_Bool;


   /* */
   FUNCTION to_Money (
      p_value IN VARCHAR2
   )
      RETURN NUMBER
   IS
      l_value VARCHAR2(4000);
   BEGIN

      IF p_value IS NULL THEN
         RETURN NULL;
      END IF;

      l_value := REGEXP_REPLACE( p_value, '[^,.0-9-]', '' );

      l_value := REPLACE(l_value, ',', '.');

      RETURN ROUND( STANDARD.TO_NUMBER( l_value, cFmt_Money, 'NLS_NUMERIC_CHARACTERS=''.,''' ), 2 );

   END to_Money;


   ----------------------------------------------------------------------------
   -- NUMBER -> hexadecimal string fixed width.
   --
   -- Нужна только внутри uuid_V7. Реализация не зависит от NLS и
   -- поддерживаемых TO_CHAR number format elements.
   ----------------------------------------------------------------------------
   FUNCTION number_To_Hex (
      p_value IN NUMBER,
      p_width IN PLS_INTEGER
   )
      RETURN VARCHAR2
   IS
      cHex CONSTANT VARCHAR2(16) := '0123456789ABCDEF';

      l_value  NUMBER := TRUNC(p_value);
      l_result VARCHAR2(100);
      l_digit  PLS_INTEGER;
   BEGIN

      IF l_value < 0 THEN
         RAISE VALUE_ERROR;
      END IF;


      FOR i IN 1 .. p_width LOOP

         l_digit := MOD(l_value, 16);

         l_result :=
              SUBSTR(cHex, l_digit + 1, 1)
           || l_result;

         l_value := TRUNC(l_value / 16);

      END LOOP;


      IF l_value <> 0 THEN
         RAISE VALUE_ERROR;
      END IF;


      RETURN l_result;

   END number_To_Hex;


   ----------------------------------------------------------------------------
   FUNCTION uuid_V7
      RETURN Uuid_t
   IS
      l_now_utc       TIMESTAMP(6);
      l_delta         INTERVAL DAY(9) TO SECOND(6);

      l_unix_ms       NUMBER(15,0);
      l_timestamp_hex VARCHAR2(12);

      l_random_hex    VARCHAR2(20);
      l_rand_a        VARCHAR2(3);
      l_rand_b        VARCHAR2(15);

      l_variant_pos   PLS_INTEGER;
      l_variant_hex   VARCHAR2(1);

      l_uuid          Uuid_t;
   BEGIN
      /*
         RFC 9562 UUIDv7:

            unix_ts_ms  48 bit
            version      4 bit = 0111
            rand_a      12 bit
            variant      2 bit = 10
            rand_b      62 bit

         SYS_EXTRACT_UTC исключает зависимость от SESSIONTIMEZONE.
      */
      /*
         SYS_EXTRACT_UTC является SQL-функцией. На Oracle 12.1 вызываем её
         в SQL-контексте, а не как прямое PL/SQL expression.
      */
      SELECT CAST(
                SYS_EXTRACT_UTC(SYSTIMESTAMP)
                AS TIMESTAMP
             )
        INTO l_now_utc
        FROM dual;

      l_delta :=
         l_now_utc
         - t_unix_Epoch;

      l_unix_ms :=
           EXTRACT(DAY    FROM l_delta) * 86400000
         + EXTRACT(HOUR   FROM l_delta) * 3600000
         + EXTRACT(MINUTE FROM l_delta) * 60000
         + TRUNC(EXTRACT(SECOND FROM l_delta) * 1000);

      l_timestamp_hex :=
         number_To_Hex(
            p_value => l_unix_ms,
            p_width => 12
         );


      /*
         Для rand_a + variant/rand_b требуется 74 случайных бита.
         Берём 80 бит из DBMS_CRYPTO.RANDOMBYTES и лишние биты отбрасываем.
      */
      l_random_hex :=
         RAWTOHEX(
            DBMS_CRYPTO.RANDOMBYTES(10)
         );

      /*
         Первые 12 случайных бит -> rand_a.
      */
      l_rand_a :=
         SUBSTR(
            l_random_hex,
            1,
            3
         );


      /*
         Для variant старшие 2 бита должны быть 10.
         Нижние 2 бита hex digit сохраняем случайными:
            00 -> 8
            01 -> 9
            10 -> A
            11 -> B
      */
      l_variant_pos :=
         MOD(
            INSTR(
               '0123456789ABCDEF',
               SUBSTR(l_random_hex, 4, 1)
            ) - 1,
            4
         ) + 1;

      l_variant_hex :=
         SUBSTR(
            '89AB',
            l_variant_pos,
            1
         );


      /*
         После variant используются ещё 60 случайных бит.
      */
      l_rand_b :=
         SUBSTR(
            l_random_hex,
            5,
            15
         );


      l_uuid :=
           SUBSTR(l_timestamp_hex, 1, 8)
         || '-'
         || SUBSTR(l_timestamp_hex, 9, 4)
         || '-7'
         || l_rand_a
         || '-'
         || l_variant_hex
         || SUBSTR(l_rand_b, 1, 3)
         || '-'
         || SUBSTR(l_rand_b, 4, 12);


      RETURN LOWER(l_uuid);

   END uuid_V7;

END MI_Utils;
/
