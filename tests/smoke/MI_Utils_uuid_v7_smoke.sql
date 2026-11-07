SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK ON
SET VERIFY OFF

PROMPT ============================================================
PROMPT MI_Utils UUIDv7 smoke test
PROMPT ============================================================

DECLARE
   TYPE uuid_set_t IS TABLE OF PLS_INTEGER
      INDEX BY VARCHAR2(36);

   l_seen        uuid_set_t;
   l_uuid        MI_Utils.Uuid_t;
   l_ts_ms       NUMBER;
   l_now_ms      NUMBER;
   l_prev_ts_ms  NUMBER;


   PROCEDURE fail (
      p_message IN VARCHAR2
   )
   IS
   BEGIN
      RAISE_APPLICATION_ERROR(
         -20990,
         'MI_Utils UUIDv7 smoke test failed: ' || p_message
      );
   END fail;


   PROCEDURE assert_True (
      p_condition IN BOOLEAN,
      p_message   IN VARCHAR2
   )
   IS
   BEGIN
      IF p_condition IS NULL OR NOT p_condition THEN
         fail(p_message);
      END IF;
   END assert_True;


   FUNCTION hex_To_Number (
      p_hex IN VARCHAR2
   )
      RETURN NUMBER
   IS
      l_result NUMBER := 0;
      l_digit  PLS_INTEGER;
      l_char   VARCHAR2(1);
   BEGIN
      FOR i IN 1 .. LENGTH(p_hex) LOOP
         l_char :=
            UPPER(
               SUBSTR(
                  p_hex,
                  i,
                  1
               )
            );

         l_digit :=
            INSTR(
               '0123456789ABCDEF',
               l_char
            ) - 1;

         IF l_digit < 0 THEN
            fail(
               'invalid hexadecimal digit: '
               || l_char
            );
         END IF;

         l_result := l_result * 16 + l_digit;
      END LOOP;

      RETURN l_result;
   END hex_To_Number;


   FUNCTION current_Unix_Millis
      RETURN NUMBER
   IS
      l_now_utc TIMESTAMP(6);
      l_delta   INTERVAL DAY(9) TO SECOND(6);
   BEGIN
      SELECT CAST(
                SYS_EXTRACT_UTC(SYSTIMESTAMP)
                AS TIMESTAMP
             )
        INTO l_now_utc
        FROM dual;

      l_delta :=
         l_now_utc
         - TIMESTAMP '1970-01-01 00:00:00';

      RETURN
           EXTRACT(DAY    FROM l_delta) * 86400000
         + EXTRACT(HOUR   FROM l_delta) * 3600000
         + EXTRACT(MINUTE FROM l_delta) * 60000
         + TRUNC(EXTRACT(SECOND FROM l_delta) * 1000);
   END current_Unix_Millis;


   FUNCTION uuid_Timestamp_Millis (
      p_uuid IN VARCHAR2
   )
      RETURN NUMBER
   IS
      l_hex VARCHAR2(12);
   BEGIN
      /*
         UUIDv7 timestamp occupies the first 48 bits:
            xxxxxxxx-xxxx
      */
      l_hex :=
           SUBSTR(p_uuid, 1, 8)
         || SUBSTR(p_uuid, 10, 4);

      RETURN hex_To_Number(l_hex);
   END uuid_Timestamp_Millis;


BEGIN
   DBMS_OUTPUT.put_line('1. format / version / variant');

   l_uuid := MI_Utils.uuid_V7;

   DBMS_OUTPUT.put_line('   sample = ' || l_uuid);

   assert_True(
      LENGTH(l_uuid) = 36,
      'length must be 36'
   );

   assert_True(
      REGEXP_LIKE(
         l_uuid,
         '^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
      ),
      'canonical UUIDv7 format'
   );

   assert_True(
      SUBSTR(l_uuid, 15, 1) = '7',
      'version nibble must be 7'
   );

   assert_True(
      SUBSTR(l_uuid, 20, 1) IN ('8', '9', 'a', 'b'),
      'variant must be RFC 4122 / RFC 9562 variant 10xx'
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('2. embedded Unix millisecond timestamp');

   l_ts_ms  := uuid_Timestamp_Millis(l_uuid);
   l_now_ms := current_Unix_Millis;

   assert_True(
      ABS(l_now_ms - l_ts_ms) <= 5000,
      'embedded timestamp differs from current UTC by more than 5 seconds'
   );

   DBMS_OUTPUT.put_line(
      '   timestamp_ms = '
      || TO_CHAR(l_ts_ms)
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('3. uniqueness / timestamp ordering for 1000 UUIDs');

   l_seen.DELETE;
   l_prev_ts_ms := NULL;

   FOR i IN 1 .. 1000 LOOP
      l_uuid := MI_Utils.uuid_V7;

      assert_True(
         REGEXP_LIKE(
            l_uuid,
            '^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
         ),
         'invalid UUIDv7 at iteration ' || i
      );

      IF l_seen.EXISTS(l_uuid) THEN
         fail(
            'duplicate UUID at iteration '
            || i
            || ': '
            || l_uuid
         );
      END IF;

      l_seen(l_uuid) := 1;

      l_ts_ms := uuid_Timestamp_Millis(l_uuid);

      IF l_prev_ts_ms IS NOT NULL THEN
         assert_True(
            l_ts_ms >= l_prev_ts_ms,
            'timestamp moved backwards at iteration ' || i
         );
      END IF;

      l_prev_ts_ms := l_ts_ms;
   END LOOP;

   assert_True(
      l_seen.COUNT = 1000,
      'expected 1000 unique UUIDs'
   );

   DBMS_OUTPUT.put_line('   unique UUIDs = ' || l_seen.COUNT);
   DBMS_OUTPUT.put_line('   OK');


   DBMS_OUTPUT.put_line('');
   DBMS_OUTPUT.put_line('============================================================');
   DBMS_OUTPUT.put_line('MI_Utils UUIDv7 smoke test PASSED');
   DBMS_OUTPUT.put_line('============================================================');
END;
/
