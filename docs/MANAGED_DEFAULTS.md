# Managed defaults

`DefaultPreferences.plist` remains the source for ordinary defaults. The app bundles a curated `ManagedDefaults.json` subset so a YINA release can correct values already stored in a user's preferences. It applies that subset before settings pages are created, then checks `https://raw.githubusercontent.com/metalnakls/yina/meh/yina/ManagedDefaults.json` at launch and when YINA becomes active, at most once per day. Valid updates are cached in Application Support for offline launches.

Sparkle still distributes the YINA app itself. Managed defaults use the separate HTTPS JSON feed, so a defaults tune does not need a new app release. Cached remote values are ignored when the installed app version changes; that version starts with its bundled defaults and then fetches the current feed.

The debug build adds **Export Current Settings as Defaults…** to the app menu. Adjust the settings in the debug app, export `ManagedDefaults.json`, review it, then run:

```sh
other/publish_defaults.py /path/to/ManagedDefaults.json
```

That validates and updates the checked-in feed without publishing. After review, run the same command with `--publish`; it commits only the defaults file on `meh` and pushes it to `yina/meh` at an allowed even minute. This publishes defaults only; a Sparkle release remains a separate operation.

The remotely managed list excludes update-channel selection, device-specific audio and hardware choices, languages, volume levels, window geometry, custom control-bar layout, screenshot choices, and the Live Text privacy setting. Updates intentionally replace saved values for the remaining managed keys, as they represent the shared tuning baseline. `--clean-start` never reads, fetches, or writes managed defaults.
