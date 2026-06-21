#include "phosh-plugin.h"
#include "hide-keyboard-quick-setting.h"


char **g_io_phosh_plugin_hide_keyboard_quick_setting_query (void);


void
g_io_module_load (GIOModule *module)
{
  g_type_module_use (G_TYPE_MODULE (module));

  g_io_extension_point_implement (PHOSH_PLUGIN_EXTENSION_POINT_QUICK_SETTING_WIDGET,
                                  PHOSH_TYPE_HIDE_KEYBOARD_QUICK_SETTING,
                                  PLUGIN_NAME,
                                  10);
}


void
g_io_module_unload (GIOModule *module)
{
}


char **
g_io_phosh_plugin_hide_keyboard_quick_setting_query (void)
{
  char *extension_points[] = {PHOSH_PLUGIN_EXTENSION_POINT_QUICK_SETTING_WIDGET, NULL};

  return g_strdupv (extension_points);
}
