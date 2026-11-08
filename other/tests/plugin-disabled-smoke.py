#!/usr/bin/env python3
"""Check that plugin entry points reject work before touching plugin data or JS."""
from pathlib import Path

plugin = Path('yina/JavascriptPlugin.swift').read_text()
instance = Path('yina/JavascriptPluginInstance.swift').read_text()
app = Path('yina/AppDelegate.swift').read_text()
manager = Path('yina/PluginManager.swift').read_text()
cli = Path('yina-cli/main.swift').read_text()

assert 'let IINA_ENABLE_PLUGIN_SYSTEM = false' in app

def before(source, start, guard, effect):
    body = source[source.index(start):]
    assert body.index(guard) < body.index(effect), start

before(plugin, 'static private func loadPlugins()', 'guard IINA_ENABLE_PLUGIN_SYSTEM', 'contentsOfDirectory')
before(plugin, 'static func recreateAllPlugins()', 'guard IINA_ENABLE_PLUGIN_SYSTEM', 'plugins = loadPlugins()')
before(plugin, 'static func loadGlobalInstances()', 'guard IINA_ENABLE_PLUGIN_SYSTEM', 'plugins.forEach')
before(plugin, 'func reloadGlobalInstance(', 'guard IINA_ENABLE_PLUGIN_SYSTEM', 'globalInstance =')
before(plugin, 'static func create(fromPackageURL', 'guard IINA_ENABLE_PLUGIN_SYSTEM', 'FileManager.default')
before(plugin, 'static func create(fromGitURL', 'guard IINA_ENABLE_PLUGIN_SYSTEM', 'Logger.log')
before(plugin, 'init?(filename:', 'guard IINA_ENABLE_PLUGIN_SYSTEM', 'Utility.pluginsURL')
before(instance, 'init(player:', 'guard IINA_ENABLE_PLUGIN_SYSTEM', 'evaluateFile(')
before(instance, 'func evaluateFile(', 'guard IINA_ENABLE_PLUGIN_SYSTEM', 'String(contentsOf:')
before(manager, 'func install(gitHubString', 'guard IINA_ENABLE_PLUGIN_SYSTEM', 'JavascriptPlugin.create')
before(app, '// Install plugins', 'if IINA_ENABLE_PLUGIN_SYSTEM', 'FirstRunManager.isFirstRun')
before(app, '@objc func reloadAllPlugins', 'guard IINA_ENABLE_PLUGIN_SYSTEM', 'clearPlugins()')
assert 'Plugins are currently disabled in YINA' in cli
print('PASS: disabled startup, reload, instance execution and installation gates')
