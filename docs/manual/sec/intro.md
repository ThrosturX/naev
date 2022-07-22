# Introduction

Welcome to the Naev development manual! This manual is meant to cover all aspects of Naev development. It is currently a work in progress. The source code for the manual can be found on the [naev github](https://github.com/naev/naev/tree/main/docs/manual) with pull requests and issues being welcome.

While this document does cover the Naev engine in general, many sections refer to customs and properties specific to the **Sea of Darkness** default Naev universe. These are marked with \naev.

## Getting Started

This document assumes you have access to the Naev data. This can be either from downloading the game directly from a distribution platform, or getting directly the [naev source code](https://github.com/naev/naev). Either way it is possible to modify the game data and change many aspects of the game. It is also possible to create plugins that add or replace content from the game without touching the core data to be compatible with updates.

| Operating System | Data Location |
| --- | --- |
| Linux | `/usr/share/naev/dat` |
| Mac OS X | `/Applications/Naev.app/Contents/Resources/dat` |
| Windows | TODO |

Most changes will only take place when you restart Naev, although it is possible to force Naev to reload a mission or event with `naev.missionReload` or `naev.eventReload`.

## Plugins

Naev supports arbitrary plugins. These are implemented with a virtual filesystem based on [PHYSFS](https://icculus.org/physfs/). The plugin files are therefore "combined" with existing files in the virtual filesystem, with plugin files taking priority. So if you add a mission in a plugin, it gets added to the pool of available missions. However, if the mission file has the same name as an existing mission, it will overwrite it. This allows the plugin to change core features such as boarding or communication mechanics or simply add more compatible content.

Plugins are found at the following locations by default, and are automatically loaded if found.

| Operating System | Data Location |
| --- | --- |
| Linux | `~/.local/share/naev/plugins` |
| Mac OS X |  `~/Library/Application Support/org.naev.Naev/plugins` |
| Windows | `%APPDATA%\naev\plugins` |

Note that plugins can use either a directory structure or be compressed as zip files (while still having the appropriate directory structure). For example, it is possible to add a single mission by creating a plugin with the follow structure:

```
missions/
   my_mission.xml
```

This will cause `my_mission.xml` to be loaded as an extra mission.
