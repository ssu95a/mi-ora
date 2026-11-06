CREATE OR REPLACE PACKAGE MI_Utils
IS

   VERSION CONSTANT VARCHAR2(100) :=
      '$Id: {1.0.0} {06.11.2026} Sulimoff$';


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

END MI_Utils;
/
CREATE OR REPLACE PACKAGE BODY MI_Utils
IS

cFmt_Money CONSTANT VARCHAR2(50) := 'FM9999999999999990D99999999';


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

   IF l_value IN (
      'TRUE',
      '1',
      'ON',
      'ИСТИНА',
      'ДА',
      'OK'
   )
   THEN
      RETURN TRUE;
   END IF;


   IF l_value IN (
      'FALSE',
      '0',
      'OFF',
      'ЛОЖЬ',
      'НЕТ',
      'FAIL'
   )
   THEN
      RETURN FALSE;
   END IF;

   RAISE VALUE_ERROR;

END to_Bool;


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


   /*
      Убираем всё, кроме:
         цифр
         знака минус
         точки / запятой

      После этого приводим decimal separator к точке и явно задаём NLS,
      чтобы результат не зависел от NLS_NUMERIC_CHARACTERS сессии.
   */
   l_value :=
      REGEXP_REPLACE(
         p_value,
         '[^,.0-9-]',
         ''
      );

   l_value := REPLACE(l_value, ',', '.');


   RETURN ROUND(
      STANDARD.TO_NUMBER(
         l_value,
         cFmt_Money,
         'NLS_NUMERIC_CHARACTERS=''.,'''
      ),
      2
   );

END to_Money;

END MI_Utils;
/
