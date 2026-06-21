#pragma once

#include "quick-setting.h"

G_BEGIN_DECLS

#define PHOSH_TYPE_HIDE_KEYBOARD_QUICK_SETTING phosh_hide_keyboard_quick_setting_get_type ()

G_DECLARE_FINAL_TYPE (PhoshHideKeyboardQuickSetting,
                      phosh_hide_keyboard_quick_setting,
                      PHOSH, HIDE_KEYBOARD_QUICK_SETTING, PhoshQuickSetting)

G_END_DECLS
