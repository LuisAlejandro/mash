# Changelog


## 0.1.1 (2026-10-26)

### Added

* Deliver Linux updates through a signed APT repository. [Luis Alejandro Martínez Faneyth]

* Refresh untouched Mash defaults on upgrade, keep user edits. [Luis Alejandro Martínez Faneyth]

* Opt in to starting the design stack when Mash opens. [Luis Alejandro Martínez Faneyth]

* Give every Mash window its own instance. [Luis Alejandro Martínez Faneyth]

* Prove both GNOME sessions on ordinary runners. [Luis Alejandro Martínez Faneyth]

* Install Linux tools into Mash without elevation. [Luis Alejandro Martínez Faneyth]

* Gate every platform in CI and publish releases as drafts. [Luis Alejandro Martínez Faneyth]

* Give Linux its own keymaps and desktop entry points. [Luis Alejandro Martínez Faneyth]

* Seed ~/.mash from a Linux launcher that shares the seeding code. [Luis Alejandro Martínez Faneyth]

* Stage Fresh, the wizard, the skills and the plugins on Linux. [Luis Alejandro Martínez Faneyth]

* Build a letsmash package from the Ghostty GTK frontend. [Luis Alejandro Martínez Faneyth]

* One validated manifest for every pinned artifact. [Luis Alejandro Martínez Faneyth]

* Copy the current file path with cmd+opt+c. [Luis Alejandro Martínez Faneyth]

* Ignore .mash working directories inside Mash. [Luis Alejandro Martínez Faneyth]

* Give Mash its own icon, from the ANSI header art. [Luis Alejandro Martínez Faneyth]

* Commit the Fresh reveal-in-Finder patch carry.sh applies. [Luis Alejandro Martínez Faneyth]

* Ship pi-voice with a dictation model the wizard can resolve. [Luis Alejandro Martínez Faneyth]

* Show_file: let pi put a result in front of the person. [Luis Alejandro Martínez Faneyth]

* Show an image file in a Herdr popup instead of a hex dump. [Luis Alejandro Martínez Faneyth]

* Port the four personal-config leftovers into Mash. [Luis Alejandro Martínez Faneyth]

* Let users install pi packages in Mash without touching their own pi. [Luis Alejandro Martínez Faneyth]

* Add a version gate and CI that builds the release DMG. [Luis Alejandro Martínez Faneyth]

* Build Ghostty from a fork so Mash owns its menus and About panel. [Luis Alejandro Martínez Faneyth]


### Changed

* Pin the Ghostty fork at 7b8e1f8. [Luis Alejandro Martínez Faneyth]

* Remove Ghostty tabs, splits and palette from Mash Terminal. [Luis Alejandro Martínez Faneyth]

* Cache the expensive build steps instead of redoing them. [Luis Alejandro Martínez Faneyth]

* Make the runtime platform-aware and brand the terminal Mash. [Luis Alejandro Martínez Faneyth]

* Stage the runtimes and bundled tools from one shared module. [Luis Alejandro Martínez Faneyth]

* Give shared payload staging an explicit resource root. [Luis Alejandro Martínez Faneyth]

* Generic wording in the UI instead of internal tool names. [Luis Alejandro Martínez Faneyth]

* Spell the personal agent path as $HOME in session-title. [Luis Alejandro Martínez Faneyth]

* Pin the skills to release tags and wire the local gate. [Luis Alejandro Martínez Faneyth]

* Clone the skills repo anonymously and re-pin it after its history rewrite. [Luis Alejandro Martínez Faneyth]

* Move ~/.mash to a dot-free layout. [Luis Alejandro Martínez Faneyth]


### Fixed

* Make the Linux test lane pass on ordinary Ubuntu runners. [Luis Alejandro Martínez Faneyth]

* Run the seed ownership test on Linux runners too. [Luis Alejandro Martínez Faneyth]

* Make notification clicks raise the right Mash window. [Luis Alejandro Martínez Faneyth]

* Ship the Pi Codemode dependency the runtime actually imports. [Luis Alejandro Martínez Faneyth]

* Name the Mash Dock tile from its bundle folder and keep the seal intact. [Luis Alejandro Martínez Faneyth]

* Relink a carried plugin when its registry copy is stale. [Luis Alejandro Martínez Faneyth]

* Relink only the carried plugins the registry points elsewhere. [Luis Alejandro Martínez Faneyth]

* Keep the bundle sealed and carry image-popup. [Luis Alejandro Martínez Faneyth]

* Mark the Fresh changes and describe both patches. [Luis Alejandro Martínez Faneyth]

* Open the image viewer as a vertical split. [Luis Alejandro Martínez Faneyth]

* Keep forked agents in the right pane of dev tabs. [Luis Alejandro Martínez Faneyth]

* Pin the reranker cache in the Hindsight warm-start too. [Luis Alejandro Martínez Faneyth]

* Move the fork chord off cmd+alt+m (macOS Minimize) [Luis Alejandro Martínez Faneyth]

* Stop the Hindsight warm-start re-creating ~/.mash/.cache. [Luis Alejandro Martínez Faneyth]

* Stop a duplicate ~/.mash/.cache from blocking every launch. [Luis Alejandro Martínez Faneyth]

* Stop naming the build machine in Mash's pi guidance. [Luis Alejandro Martínez Faneyth]

* Put ~/.bun/bin on every pane's PATH. [Luis Alejandro Martínez Faneyth]

* Keep setup running and stop it from looking like an unconfigured Mash. [Luis Alejandro Martínez Faneyth]

* Provide the design-skills checkout in CI. [Luis Alejandro Martínez Faneyth]

* Add the push workflow the release flow waits on. [Luis Alejandro Martínez Faneyth]


### Removed

* Remove the retirement tooling now that the retirement is final. [Luis Alejandro Martínez Faneyth]

* Drop pre-release compatibility leftovers from Mash. [Luis Alejandro Martínez Faneyth]

* Remove pre-release layout migrator from Mash startup. [Luis Alejandro Martínez Faneyth]


### Other

* Remove the retirement runbook now that it is complete. [Luis Alejandro Martínez Faneyth]

* Add session search and package Mash Programming Skills into the app. [Luis Alejandro Martínez Faneyth]

* Add the Mash app build and its shipped setup. [Luis Alejandro Martínez Faneyth]

