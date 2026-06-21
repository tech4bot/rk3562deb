project('phosh-hide-keyboard-quick-setting', 'c')

gnome = import('gnome')

plugin_name = 'hide-keyboard-quick-setting'
plugins_dir = join_paths(get_option('prefix'), get_option('libdir'), 'phosh', 'plugins')

plugin_dep = dependency('phosh-plugins')
libphosh_dep = dependency('libphosh-0.45')
gio_dep = dependency('gio-2.0')

plugin_resources = gnome.compile_resources(
  'phosh-plugin-hide-keyboard-quick-setting-resources',
  'phosh-plugin-hide-keyboard-quick-setting.gresources.xml',
  c_name: 'phosh_plugin_hide_keyboard_quick_setting',
)

plugin_sources = files(
  'phosh-plugin-hide-keyboard-quick-setting.c',
  'hide-keyboard-quick-setting.c',
)

shared_module(
  'phosh-plugin-hide-keyboard-quick-setting',
  plugin_sources,
  plugin_resources,
  c_args: [
    '-DG_LOG_DOMAIN="phosh-plugin-@0@"'.format(plugin_name),
    '-DPLUGIN_NAME="@0@"'.format(plugin_name),
  ],
  dependencies: [plugin_dep, libphosh_dep, gio_dep],
  install: true,
  install_dir: plugins_dir,
)

pluginconf = configuration_data()
pluginconf.set('name', plugin_name)
pluginconf.set('plugins_dir', plugins_dir)

configure_file(
  input: plugin_name + '.plugin.in',
  output: plugin_name + '.plugin',
  configuration: pluginconf,
  install: true,
  install_dir: plugins_dir,
)
