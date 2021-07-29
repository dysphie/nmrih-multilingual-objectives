# [NMRiH] Multilingual Objectives

### Important note

If this is your first time trying to install this I'd urge you to use my other plugin [Map Translator](https://github.com/dysphie/nmrih-map-translator) instead.
It provides support for a wider variety of messages and can auto-generate translation files for you.

### Description 
This plugin adds localization support for native objective messages. 
It differs from [\[NMRiH\]Multilingual Objective Beta 1.41]("https://forums.alliedmods.net/showthread.php?p=2305894") in that it overrides the actual screen pop-up, rather than displaying additional game text.

After you've included the translated text, players in your server will see objective descriptions in their preferred language. If a value for the preferred language does not exist, the original message will be shown. A client's language is determined by either the language that they have Steam set to, or any -language override on the game's launch options.

### Adding translations

Each objective has a unique identifier associated with it, with the format "`map name` `objective name`".
To translate an objective message into multiple languages, you must add its identifier to *translations/multilingual-objectives.phrases.txt*

This is what the translation file might look like:

```c	
"Phrases"
{
	"nmo_cabin objStart"
	{
		"fr"      "Sors du grenier"
		"de"      "Finde einen Weg, um aus dem Dachboden auszubrechen!"
		"nl"      "Ontsnap van de zolder"

		// You can also override the default English message
		"en"      "Hello world"
	}
}
```

[List of country codes]("https://www.iban.com/country-codes").

You can get a list of all objective names for a map using the `dump_objectives` console command and looking at the second argument:

```
] sv_cheats 1; dump_objectives
24: objStart - Break out of the attic.
21: ObjA - Find keys to unlock door.
25: ObjC - Family is the answer, find the secret book.
23: ObjB - Break planks to proceed.
26: ObjD - Release stair gate.
33: ObjI - Find the car battery, power up the generator and call for help!
30: ObjE - Blast through cabin wall.
```

Admins can also use the helper command `sm_oid` to fetch the translation phrase for the current objective.
```
Admin: /oid
Current objective: nmo_cabin objStart 
```
### ConVars

* **sm_translate_objectives** (1/0) (Default: 1)
    * Toggle the translation of objective messages.
