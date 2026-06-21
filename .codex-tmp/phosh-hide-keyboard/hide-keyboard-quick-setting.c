#include "hide-keyboard-quick-setting.h"

#include <gio/gio.h>

struct _PhoshHideKeyboardQuickSetting {
  PhoshQuickSetting parent;

  PhoshStatusIcon *info;
  GtkLabel *label;
  GDBusProxy *osk_proxy;
};

G_DEFINE_TYPE (PhoshHideKeyboardQuickSetting,
               phosh_hide_keyboard_quick_setting,
               PHOSH_TYPE_QUICK_SETTING);


static void
set_status (PhoshHideKeyboardQuickSetting *self,
            const char                    *info_text,
            const char                    *detail_text)
{
  phosh_status_icon_set_icon_name (self->info, "input-keyboard-symbolic");
  phosh_status_icon_set_info (self->info, info_text);
  gtk_label_set_label (self->label, detail_text);
  phosh_quick_setting_set_active (PHOSH_QUICK_SETTING (self), FALSE);
}


static GDBusProxy *
ensure_osk_proxy (PhoshHideKeyboardQuickSetting *self,
                  GError                       **error)
{
  if (self->osk_proxy)
    return self->osk_proxy;

  self->osk_proxy = g_dbus_proxy_new_for_bus_sync (G_BUS_TYPE_SESSION,
                                                   G_DBUS_PROXY_FLAGS_NONE,
                                                   NULL,
                                                   "sm.puri.OSK0",
                                                   "/sm/puri/OSK0",
                                                   "sm.puri.OSK0",
                                                   NULL,
                                                   error);
  return self->osk_proxy;
}


static gboolean
hide_keyboard (PhoshHideKeyboardQuickSetting *self,
               GError                       **error)
{
  GDBusProxy *proxy;
  g_autoptr (GVariant) reply = NULL;

  proxy = ensure_osk_proxy (self, error);
  if (!proxy)
    return FALSE;

  reply = g_dbus_proxy_call_sync (proxy,
                                  "SetVisible",
                                  g_variant_new ("(b)", FALSE),
                                  G_DBUS_CALL_FLAGS_NONE,
                                  -1,
                                  NULL,
                                  error);

  return reply != NULL;
}


static void
on_clicked (PhoshHideKeyboardQuickSetting *self)
{
  g_autoptr (GError) error = NULL;

  if (hide_keyboard (self, &error)) {
    set_status (self, "Hide Keyboard", "On-screen keyboard hidden.");
    return;
  }

  g_warning ("Failed to hide the on-screen keyboard: %s", error->message);
  set_status (self, "Hide Keyboard", error->message);
}


static void
on_footer_clicked (PhoshHideKeyboardQuickSetting *self)
{
  on_clicked (self);
}


static void
phosh_hide_keyboard_quick_setting_dispose (GObject *object)
{
  PhoshHideKeyboardQuickSetting *self = PHOSH_HIDE_KEYBOARD_QUICK_SETTING (object);

  g_clear_object (&self->osk_proxy);

  G_OBJECT_CLASS (phosh_hide_keyboard_quick_setting_parent_class)->dispose (object);
}


static void
phosh_hide_keyboard_quick_setting_class_init (PhoshHideKeyboardQuickSettingClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS (klass);
  GtkWidgetClass *widget_class = GTK_WIDGET_CLASS (klass);

  object_class->dispose = phosh_hide_keyboard_quick_setting_dispose;

  gtk_widget_class_set_template_from_resource (widget_class,
                                               "/mobi/phosh/plugins/hide-keyboard-quick-setting/qs.ui");

  gtk_widget_class_bind_template_child (widget_class, PhoshHideKeyboardQuickSetting, info);
  gtk_widget_class_bind_template_child (widget_class, PhoshHideKeyboardQuickSetting, label);

  gtk_widget_class_bind_template_callback (widget_class, on_clicked);
  gtk_widget_class_bind_template_callback (widget_class, on_footer_clicked);
}


static void
phosh_hide_keyboard_quick_setting_init (PhoshHideKeyboardQuickSetting *self)
{
  gtk_widget_init_template (GTK_WIDGET (self));
  set_status (self, "Hide Keyboard", "Tap to hide the on-screen keyboard.");
}
