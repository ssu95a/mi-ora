CREATE OR REPLACE PACKAGE MI_Prp
IS

   /* MI. Служба системных, workspace- и INF-свойств */

   VERSION CONSTANT VARCHAR2(100) :=
      '$Id: {1.0.2} {15.11.2026} Sulimoff$';


   FUNCTION get_Version
      RETURN VARCHAR2;


   /* Получение свойства workspace. */
   FUNCTION get_Wsp_Property (
      p_wsp_id     IN MI_WSP.WSP_ID%TYPE,
      p_prp_id     IN VARCHAR2,
      p_def_value  IN VARCHAR2 DEFAULT NULL
   )
      RETURN VARCHAR2;


   /* Установка свойства workspace. */
   PROCEDURE set_Wsp_Property (
      p_wsp_id  IN MI_WSP.WSP_ID%TYPE,
      p_prp_id  IN VARCHAR2,
      p_value   IN VARCHAR2
   );


   /* Получение свойства вида сведений. */
   FUNCTION get_Inf_Property (
      p_inf_id     IN MI_INF.INF_ID%TYPE,
      p_prp_id     IN VARCHAR2,
      p_def_value  IN VARCHAR2 DEFAULT NULL
   )
      RETURN VARCHAR2;


   /* Установка свойства вида сведений. */
   PROCEDURE set_Inf_Property (
      p_inf_id  IN MI_INF.INF_ID%TYPE,
      p_prp_id  IN VARCHAR2,
      p_value   IN VARCHAR2
   );


   /* Получение системного свойства. */
   FUNCTION get_Sys_Property (
      p_prp_id     IN VARCHAR2,
      p_def_value  IN VARCHAR2 DEFAULT NULL
   )
      RETURN VARCHAR2;


   /* Установка системного свойства. */
   PROCEDURE set_Sys_Property (
      p_prp_id  IN VARCHAR2,
      p_value   IN VARCHAR2
   );

END MI_Prp;
/

CREATE OR REPLACE PACKAGE BODY MI_Prp
IS

   /* Формирует имя свойства в корпоративном PREF. */
   FUNCTION make_Property_Name (
      p_obj_id  IN NUMBER,
      p_prp_id  IN VARCHAR2
   )
      RETURN VARCHAR2
   IS
      l_wsp_id MI_INF.WSP_ID%TYPE;
   BEGIN
      IF p_obj_id IS NULL OR p_prp_id IS NULL THEN
         RETURN p_prp_id;
      END IF;

      IF p_obj_id = 0 THEN
         RETURN 'mi_sys_' || p_prp_id;
      END IF;

      IF p_obj_id < 0 THEN
         RETURN
               'mi_w'
            || ABS(p_obj_id)
            || '_#_'
            || p_prp_id;
      END IF;

      SELECT WSP_ID
        INTO l_wsp_id
        FROM MI_INF
       WHERE INF_ID = p_obj_id;

      RETURN
            'mi_w_'
         || l_wsp_id
         || '_i_'
         || p_obj_id
         || '_'
         || p_prp_id;
   END make_Property_Name;


   /* Базовое получение свойства. */
   FUNCTION get_Property (
      p_obj_id     IN NUMBER,
      p_prp_id     IN VARCHAR2,
      p_def_value  IN VARCHAR2 DEFAULT NULL
   )
      RETURN VARCHAR2
   IS
      l_value VARCHAR2(32767);
   BEGIN
      l_value :=
         PREF.Get_Global_Preference(
            make_Property_Name(
               p_obj_id => p_obj_id,
               p_prp_id => p_prp_id
            )
         );

      RETURN NVL(l_value, p_def_value);
   END get_Property;


   /* Базовая установка свойства. */
   PROCEDURE set_Property (
      p_obj_id  IN NUMBER,
      p_prp_id  IN VARCHAR2,
      p_value   IN VARCHAR2
   )
   IS
   BEGIN
      PREF.Set_Global_Preference(
         make_Property_Name(
            p_obj_id => p_obj_id,
            p_prp_id => p_prp_id
         ),
         p_value
      );
   END set_Property;


   /* */
   FUNCTION get_Version
      RETURN VARCHAR2
   IS
   BEGIN
      RETURN VERSION;
   END get_Version;


   /* */
   FUNCTION get_Wsp_Property (
      p_wsp_id     IN MI_WSP.WSP_ID%TYPE,
      p_prp_id     IN VARCHAR2,
      p_def_value  IN VARCHAR2 DEFAULT NULL
   )
      RETURN VARCHAR2
   IS
   BEGIN
      RETURN
         get_Property(
            p_obj_id    => -p_wsp_id,
            p_prp_id    => p_prp_id,
            p_def_value => p_def_value
         );
   END get_Wsp_Property;


   /* */
   PROCEDURE set_Wsp_Property (
      p_wsp_id  IN MI_WSP.WSP_ID%TYPE,
      p_prp_id  IN VARCHAR2,
      p_value   IN VARCHAR2
   )
   IS
   BEGIN
      set_Property(
         p_obj_id => -p_wsp_id,
         p_prp_id => p_prp_id,
         p_value  => p_value
      );
   END set_Wsp_Property;


   /* */
   FUNCTION get_Inf_Property (
      p_inf_id     IN MI_INF.INF_ID%TYPE,
      p_prp_id     IN VARCHAR2,
      p_def_value  IN VARCHAR2 DEFAULT NULL
   )
      RETURN VARCHAR2
   IS
   BEGIN
      RETURN
         get_Property(
            p_obj_id    => p_inf_id,
            p_prp_id    => p_prp_id,
            p_def_value => p_def_value
         );
   END get_Inf_Property;


   /* */
   PROCEDURE set_Inf_Property (
      p_inf_id  IN MI_INF.INF_ID%TYPE,
      p_prp_id  IN VARCHAR2,
      p_value   IN VARCHAR2
   )
   IS
   BEGIN
      set_Property(
         p_obj_id => p_inf_id,
         p_prp_id => p_prp_id,
         p_value  => p_value
      );
   END set_Inf_Property;


   /* */
   FUNCTION get_Sys_Property (
      p_prp_id     IN VARCHAR2,
      p_def_value  IN VARCHAR2 DEFAULT NULL
   )
      RETURN VARCHAR2
   IS
   BEGIN
      RETURN
         get_Property(
            p_obj_id    => 0,
            p_prp_id    => p_prp_id,
            p_def_value => p_def_value
         );
   END get_Sys_Property;


   /* */
   PROCEDURE set_Sys_Property (
      p_prp_id  IN VARCHAR2,
      p_value   IN VARCHAR2
   )
   IS
   BEGIN
      set_Property(
         p_obj_id => 0,
         p_prp_id => p_prp_id,
         p_value  => p_value
      );
   END set_Sys_Property;

END MI_Prp;
/
