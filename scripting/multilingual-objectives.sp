#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#pragma semicolon 1
#pragma newdecls required

#define PREFIX "[Multilingual Objectives] "
#define MAX_CODE_LEN 10							// Maximum length of language codes
#define MAX_USERMSG_LEN 255						// Maximum length of network messages
#define MAX_PHRASE_LEN MAX_USERMSG_LEN * 2 - 1	// Max phrase len after escaping
#define MAX_GAMETEXT_LEN MAX_USERMSG_LEN - 34	// Max len of gametext description
#define MAX_TARGETNAME_LEN 64
#define MAXPLAYERS_NMRIH 9


public Plugin myinfo = {
	name        = "Multilingual Objectives",
	author      = "Dysphie",
	description = "",
	version     = "2.0.1-beta",
	url         = "https://steamcommunity.com/profiles/76561198118327091"
};


char langOverride[MAXPLAYERS_NMRIH+1][MAX_CODE_LEN];

FeatureStatus smapContainsKey;

// Nested stringmap structure where translations get loaded into
methodmap Translator < StringMap
{
	public Translator() 
	{
		return view_as<Translator>(new StringMap());
	}

	public void UnloadTranslations()
	{
		int numLoaded = this.Size;
		if (!numLoaded)	// Nothing to unload
			return;
		
		char key[MAX_USERMSG_LEN];
		StringMapSnapshot snap = this.Snapshot();
		for (int i; i < numLoaded; i++)
		{
			snap.GetKey(i, key, sizeof(key));

			StringMap langs;
			this.GetValue(key, langs);
			delete langs;
		}

		delete snap;
		this.Clear();
	}

	public void LoadTranslations(KeyValues kv, const char[] rootKey) 
	{
		this.UnloadTranslations();

		if (!kv.JumpToKey(rootKey))
			return;

		if (!kv.GotoFirstSubKey())
		{
			kv.GoBack();
			return;
		}

		char langCode[MAX_CODE_LEN];
		char phrase[MAX_PHRASE_LEN];
		char translation[MAX_PHRASE_LEN];

		do
		{
			if (!kv.GetSectionName(phrase, sizeof(phrase)))
				continue;

			if (!kv.GotoFirstSubKey(false))
				continue;

			// Build inner langs stringmap
			StringMap langs = new StringMap();
			do
			{
				if (!kv.GetSectionName(langCode, sizeof(langCode)))
					continue;

				if (!StrEqual(langCode, "default") && GetLanguageByCode(langCode) == -1)
					continue;

				if (!kv.GetString(NULL_STRING, translation, sizeof(translation)))
					continue;

				strtolower(langCode);
				langs.SetString(langCode, translation);

			} while (kv.GotoNextKey(false));

			if (!langs.Size)
			{
				delete langs;
			}
			else
			{
				PhraseKeyToString(phrase, sizeof(phrase));
				this.SetValue(phrase, langs);
			}

			kv.GoBack();

		} while (kv.GotoNextKey());

		kv.Rewind();
	}

	public bool CanTranslate(const char[] phrase)
	{
		if (smapContainsKey == FeatureStatus_Available)
			return this.ContainsKey(phrase);
		
		// SM 1.10 and lower
		any val;
		return this.GetValue(phrase, val);
	}

	public bool TranslateForClient(int client, const char[] phrase, char[] buffer, int maxlen)
	{
		strcopy(buffer, maxlen, phrase);

		StringMap langs;
		this.GetValue(phrase, langs);

		if (!langs)
			return false;

		bool override = langOverride[client][0] != '\0';
		bool translated;

		if (override)
		{
			translated = langs.GetString(langOverride[client], buffer, maxlen);
		}
		else
		{
			char langCode[MAX_CODE_LEN];
			int langId = GetClientLanguage(client);
			GetLanguageInfo(langId, langCode, sizeof(langCode));
			translated = langs.GetString(langCode, buffer, maxlen);
		}

		if (!translated)
		{
			translated = langs.GetString("default", buffer, maxlen);
		}

		return translated;
	}
}

enum struct GameTextInfo
{
	char id[512];
	char text[1024];
}

ConVar cvAutoLangs;

bool loadedGametextPhrases;			// Whether gametextTranslator.LoadTranslations has been called
ArrayStack lateSpawnedGameText;		// Late spawning gametexts scheduled for saving on map end

Translator gameTextTranslator;		// Holds gametext translations
Translator objectiveTranslator;		// Holds objective translations
StringMap objDescToObjName;			// Used to find objectives by their description
StringMap gtDescToGtIndex;			// Used to find gametext by their description


char cachedMapName[PLATFORM_MAX_PATH];
char fullTransPath[PLATFORM_MAX_PATH];

ArrayList cachedAutoLangs;			// List of language codes to autogenerate translations for

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	MarkNativeAsOptional("StringMap.ContainsKey");
	return APLRes_Success;
}

public void OnPluginStart()
{
	BuildPath(Path_SM, fullTransPath, sizeof(fullTransPath), "configs/multilingual-objectives");
	smapContainsKey = GetFeatureStatus(FeatureType_Native, "StringMap.ContainsKey");

	lateSpawnedGameText = new ArrayStack(sizeof(GameTextInfo));
	objDescToObjName = new StringMap();
	gtDescToGtIndex = new StringMap();
	gameTextTranslator = new Translator();
	objectiveTranslator = new Translator();
	cachedAutoLangs = new ArrayList(ByteCountToCells(MAX_CODE_LEN));

	RegAdminCmd("mo_build_translations", OnCmdBuildTranslations, ADMFLAG_ROOT);
	
	cvAutoLangs = CreateConVar("mo_autolearn_languages", "",
		"Space-separated list of language codes to autogenerate translation phrases for.");

	RegAdminCmd("mo_forcelang", OnCmdForceLanguage, ADMFLAG_ROOT);
	RegAdminCmd("mo_reload_translations", OnCmdReloadTranslations, ADMFLAG_ROOT);
	RegAdminCmd("mo_migrate_old", OnCmdMigrate, ADMFLAG_ROOT);

	cvAutoLangs.AddChangeHook(OnAutoLangsChanged);

	AutoExecConfig(.name="plugin.multilingual-objectives");

	UserMsg msg = GetUserMessageId("ObjectiveNotify");
	if (msg == INVALID_MESSAGE_ID)
		SetFailState("Failed to find ObjectiveNotify user message");
	HookUserMessage(msg, OnObjectiveMsg, true);

	msg = GetUserMessageId("HudMsg");
	if (msg == INVALID_MESSAGE_ID)
		SetFailState("Failed to find HudMsg user message");
	HookUserMessage(msg, OnGameText, true);
}

public void OnClientConnected(int client)
{
	langOverride[client][0] = '\0';
}

public Action OnCmdReloadTranslations(int client, int args)
{
	char transPath[PLATFORM_MAX_PATH];
	GetMapTranslationsPath(cachedMapName, transPath, sizeof(transPath));

	KeyValues kv = new KeyValues("Phrases");
	kv.SetEscapeSequences(true);
	kv.ImportFromFile(transPath);

	gameTextTranslator.LoadTranslations(kv, "GameText");
	objectiveTranslator.LoadTranslations(kv, "Objectives");
	delete kv;

	ReplyToCommand(client, PREFIX ... "Reloaded map translations");
	return Plugin_Handled;
}

public Action OnCmdForceLanguage(int client, int args)
{
	if (args < 1)
	{
		ReplyToCommand(client, PREFIX ... "Usage: mo_forcelang <language code>");
		return Plugin_Handled;
	}

	char langCode[MAX_CODE_LEN];
	GetCmdArg(1, langCode, sizeof(langCode));
	strcopy(langOverride[client], sizeof(langOverride[]), langCode);
	ReplyToCommand(client, PREFIX ... "Forcing \"%s\" translations for your client until mapchange", langCode);
	return Plugin_Handled;
}

public void OnConfigsExecuted()
{
	GetCurrentMap(cachedMapName, sizeof(cachedMapName));

	char buffer[512];
	cvAutoLangs.GetString(buffer, sizeof(buffer));
	CacheAutoLangs(buffer);

	if (cachedMapName[0] != '\0') // Ensure we are playing a map
		ParseMap(cachedMapName, .isActiveMap = true);
}

public void OnAutoLangsChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	CacheAutoLangs(newValue);
}

void CacheAutoLangs(const char[] langs)
{
	cachedAutoLangs.Clear();

	if (langs[0] == '\0')
		return;

	int maxLangs = GetLanguageCount();
	char[][] buffer = new char[maxLangs][MAX_CODE_LEN];

	int numLangs = ExplodeString(langs, " ", buffer, maxLangs, MAX_CODE_LEN);

	for (int i; i < numLangs; i++)
	{
		TrimString(buffer[i]);

		if (buffer[i][0] == '\0')
			continue;

		if (GetLanguageByCode(buffer[i]) == -1)
		{
			PrintToServer(PREFIX ... "Language code \"%s\" is invalid, it will be ignored", buffer[i]);
			continue;
		}
		
		cachedAutoLangs.PushString(buffer[i]);
	}
}

public void OnMapEnd()
{
	objectiveTranslator.UnloadTranslations();
	gameTextTranslator.UnloadTranslations();
	objDescToObjName.Clear();

	// TODO: Should we also clean this on map reset? The invalid indexes should get
	// overwritten by the respawned gametext with the same description so..
	gtDescToGtIndex.Clear();

	// If we collected any new gametext mid-game, write them to the translations file
	if (!lateSpawnedGameText.Empty)
	{
		char transPath[PLATFORM_MAX_PATH];
		GetMapTranslationsPath(cachedMapName, transPath, sizeof(transPath));

		KeyValues kv = new KeyValues("Phrases");
		kv.SetEscapeSequences(true);
		kv.ImportFromFile(transPath);
		kv.JumpToKey("GameText", true);

		while (!lateSpawnedGameText.Empty)
		{
			GameTextInfo gti;
			lateSpawnedGameText.PopArray(gti);
			CreatePhraseBlock(kv, gti.id, gti.text);	
		}

		kv.GoBack();
		kv.ExportToFile(transPath);
		delete kv;
	}

	loadedGametextPhrases = false;
}

public Action OnCmdBuildTranslations(int client, int args)
{
	if (!IsServerProcessing()) // We need multiple frames
	{
		ReplyToCommand(client, PREFIX ... "Can't build translations while server is hibernating. "
			... "Ensure at least one person is on the server.");
		return Plugin_Handled;
	}

	if (!DirExists(fullTransPath)) 
	{
		ReplyToCommand(client, PREFIX ... 
			"Dir \"%s\" doesn't exist. Please validate it and re-run the command.", 
			fullTransPath);
		return Plugin_Handled;
	}


	if (args < 1)
	{
		ReplyToCommand(client, PREFIX ... "Usage: mo_build_translations <map names|mapcycle name|@all>");
		return Plugin_Handled;
	}
	
	char targets[PLATFORM_MAX_PATH];
	char source[32];
	GetCmdArg(1, targets, sizeof(targets));

	ArrayList mapsToLearn = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));

	if (targets[0] == '#' && strlen(targets) > 1)
	{
		ReadMapList(mapsToLearn, .str=targets[1], .flags=MAPLIST_FLAG_NO_DEFAULT);
		FormatEx(source, sizeof(source), "\"%s\" mapcycle", targets[1]);
	}
	else if (StrEqual(targets, "@all"))
	{
		ReadMapList(mapsToLearn, .str="", .flags=MAPLIST_FLAG_NO_DEFAULT|MAPLIST_FLAG_MAPSFOLDER);
		strcopy(source, sizeof(source), "\"maps\" folder");
	}
	else
	{
		char mapName[PLATFORM_MAX_PATH];
		for (int i = 1; i <= args; i++)
		{
			GetCmdArg(i, mapName, sizeof(mapName));
			FindMapResult find = FindMap(mapName, mapName, sizeof(mapName));
			if (find == FindMap_Found || find == FindMap_FuzzyMatch)
				mapsToLearn.PushString(mapName);
			else
				ReplyToCommand(client, "No matches for \"%s\"", mapName);
		}

		strcopy(source, sizeof(source), "custom list");
	}

	if (!mapsToLearn.Length)
	{
		ReplyToCommand(client, PREFIX ... "No maps found for given argument (%s)", source);
		return Plugin_Handled;
	}

	DataPack data = new DataPack();
	data.WriteCell(0);										// cursor in mapsToLearn
	data.WriteCell(mapsToLearn);							// maps to learn
	data.WriteCell(client ? GetClientSerial(client) : -1);	// serial of client who issued the command, -1 for server
	data.WriteCell(GetCmdReplySource());					// reply source of the command
	LearnAllObjectivesThink(data);

	ReplyToCommand(client, PREFIX ... "Building translations for %d maps (%s)", mapsToLearn.Length, source);
	return Plugin_Handled;
}

void LearnAllObjectivesThink(DataPack data)
{
	data.Reset();
	int cursor = data.ReadCell();		// cursor in mapsToLearn
	ArrayList maps = data.ReadCell();	// maps to learn

	int client;
	int serial = data.ReadCell();			// serial of client who issued the command, -1 for server
	if (serial != -1)
		client = GetClientFromSerial(serial);

	ReplySource source = data.ReadCell();

	if (cursor >= maps.Length)
	{
		ReplySource oldSource = GetCmdReplySource();		
		SetCmdReplySource(source);
		ReplyToCommand(client, PREFIX ... "Finished generating translations.");
		SetCmdReplySource(oldSource);				// API says to restore the old source

		delete maps;
		delete data;
		return;
	}

	char mapName[PLATFORM_MAX_PATH];
	maps.GetString(cursor, mapName, sizeof(mapName));

	ReplySource oldSource = GetCmdReplySource();		
	SetCmdReplySource(source);
	ReplyToCommand(client, PREFIX ... "Generating translations for \"%s\"", mapName);
	SetCmdReplySource(oldSource);				// API says to restore the old source

	ParseMap(mapName);

	data.Reset();
	data.WriteCell(++cursor);
	RequestFrame(LearnAllObjectivesThink, data);
}

bool ParseMap(const char[] mapName, char[] error = "", int maxlen = 0, bool isActiveMap = false)
{
	char transPath[PLATFORM_MAX_PATH];
	GetMapTranslationsPath(mapName, transPath, sizeof(transPath));

	KeyValues kv = new KeyValues("Phrases");
	kv.SetEscapeSequences(true);
	kv.ImportFromFile(transPath);

	// Learn.
	int objCount, gametextCount;

	objCount = LearnObjectives(kv, mapName, .hashDescriptions=isActiveMap);

	if (isActiveMap)
		gametextCount = LearnGameText(kv);

	// Don't save if count is 0, as nothing should've changed
	bool result = true;
	if (gametextCount | objCount)
	{
		result = kv.ExportToFile(transPath);
		if (!result)
			strcopy(error, maxlen, "Failed to export translations file");
	}

	// Load learned. Yes this will load the dummy values we just built
	// but it's needed to know which game_text to ignore on spawn
	if (isActiveMap)
	{
		gameTextTranslator.LoadTranslations(kv, "GameText");
		objectiveTranslator.LoadTranslations(kv, "Objectives");
	}


	delete kv;
	return result;
}

int LearnObjectives(KeyValues kv, const char[] mapName, char[] error = "", int maxlen = 0, bool hashDescriptions)
{
	// Open the .nmo file for reading
	char path[PLATFORM_MAX_PATH];
	FormatEx(path, sizeof(path), "maps/%s.nmo", mapName);

	// Starts here
	File file = OpenFile(path, "rb", true, NULL_STRING);
	if (!file)
	{
		FormatEx(error, maxlen, "No NMO file exists at %s", path);
		return 0;
	}

	int header, version;

	if (!file.ReadInt8(header) || header != 'v' || 
		!file.ReadInt32(version) || version != 1) 
	{
		strcopy(error, maxlen, "Bad NMO format");
		delete file;
		return 0;	
	}

	int objectivesCount;
	file.ReadInt32(objectivesCount);

	// skip antiObjectivesCount and extractionCount
	file.Seek(8, SEEK_CUR); 

	if (objectivesCount < 0)
	{
		strcopy(error, maxlen, "Bad NMO format");
		delete file;
		return 0;
	}

	kv.JumpToKey("Objectives", true);
	
	char objectiveDescription[MAX_USERMSG_LEN * 2];
	char objectiveName[MAX_USERMSG_LEN * 2];
	int count;

	for (int o; o < objectivesCount; o++)
	{
		// Skip objective ID
		file.Seek(4, SEEK_CUR); 

		ReadFileString2(file, objectiveName, sizeof(objectiveName));
		ReadFileString2(file, objectiveDescription, sizeof(objectiveDescription));

		if (objectiveName[0] != '\0')
		{
			if (hashDescriptions)
			{
				strtolower(objectiveName);
				objDescToObjName.SetString(objectiveDescription, objectiveName);
			}

			StringToPhraseKey(objectiveName, sizeof(objectiveName));
			StringToPhraseValue(objectiveDescription, sizeof(objectiveDescription));
			CreatePhraseBlock(kv, objectiveName, objectiveDescription);
			count++;	

		}

		SeekFileTillChar(file, '\0');
		
		// Skip item names
		int itemCount;
		file.ReadInt32(itemCount);
		if (itemCount > 0)
			while (itemCount--)
				SeekFileTillChar(file, '\0');		

		// Skip objective links
		int linksCount;
		file.ReadInt32(linksCount);
		if (linksCount > 0) 
			file.Seek(linksCount * 4, SEEK_CUR);
	}
	
	delete file;
	kv.GoBack();
	return count;
}

int LearnGameText(KeyValues kv)
{
	kv.JumpToKey("GameText", true);

	int entity = -1;
	int count = 0;

	while ((entity = FindEntityByClassname(entity, "game_text")) != -1)
	{
		GameTextInfo gti;
		GetEntPropString(entity, Prop_Data, "m_iszMessage", gti.text, sizeof(gti.text));

		if (!gti.text[0])
			continue;

		gtDescToGtIndex.SetValue(gti.text, EntIndexToEntRef(entity));

		StringToPhraseValue(gti.text, sizeof(gti.text));
		if (GetGameTextIdentifier(entity, gti.id, sizeof(gti.id)))
		{
			CreatePhraseBlock(kv, gti.id, gti.text);
			count++;
		}
	}
	
	kv.GoBack();
	loadedGametextPhrases = true;

	return count;
}

int GetEntityTargetname(int entity, char[] buffer, int maxlen)
{
	return GetEntPropString(entity, Prop_Send, "m_iName", buffer, maxlen);
}

void CreatePhraseBlock(KeyValues kv, const char[] phrase, const char[] dummyTrans)
{
	kv.JumpToKey(phrase, .create=true);

	// Write default translation
	KvSetStringIfNotExists(kv, "default", dummyTrans);

	// If user specified lang codes, add those as well
	char code[MAX_CODE_LEN];
	int maxLangs = cachedAutoLangs.Length;
	for (int i; i < maxLangs; i++)
	{
		cachedAutoLangs.GetString(i, code, sizeof(code));
		KvSetStringIfNotExists(kv, code, dummyTrans);
	}

	kv.GoBack();
	return;
}

int GetMapTranslationsPath(const char[] mapName, char[] buffer, int maxlen)
{
	FormatEx(buffer, maxlen, "%s/%s.txt", fullTransPath, mapName);
}

void KvSetStringIfNotExists(KeyValues kv, const char[] key, const char[] value)
{
	if (kv.JumpToKey(key))
		kv.GoBack();
	else
		kv.SetString(key, value);
}

/* Similar to ReadFileString, but the file position always ends up at the 
 * null terminator (https://github.com/alliedmodders/sourcemod/issues/1430)
 */
void ReadFileString2(File file, char[] buffer, int maxlen)
{
	file.ReadString(buffer, maxlen, -1);

	// Ensure we've consumed the full string..
	file.Seek(-1, SEEK_CUR);
	SeekFileTillChar(file, '\0');
}

void SeekFileTillChar(File file, char c)
{
	int i;
	do {
		file.ReadInt8(i);
	} while (i != c);	
}

public Action OnCmdMigrate(int client, int args)
{
	// Import the legacy CFG
	char oldPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, oldPath, sizeof(oldPath), "translations/multilingual-objectives.phrases.txt");
	KeyValues oldkv = new KeyValues("");
	oldkv.SetEscapeSequences(true);

	if (!oldkv.ImportFromFile(oldPath) || !oldkv.GotoFirstSubKey())
	{
		ReplyToCommand(client, PREFIX ... "Migration failed. \"%s\" not found, or empty.", oldPath);

		delete oldkv;
		return Plugin_Handled;
	}

	char mapNameOld[255], mapName[255];
	KeyValues kv;

	any count;

	do
	{
		// Split old-style "<mapname> <objname>" section names
		char section[256];
		oldkv.GetSectionName(section, sizeof(section));
		StringToPhraseKey(section, sizeof(section));


		int objNameIdx = SplitString(section, " ", mapName, sizeof(mapName));
		if (objNameIdx == -1)
			continue;

		if (kv && mapNameOld[0] && !StrEqual(mapName, mapNameOld))
		{
			count += ExportTranslationFile(kv, mapNameOld);
			delete kv;
		}

		if (!kv)
		{
			kv = new KeyValues("Phrases");
			kv.SetEscapeSequences(true);
			kv.JumpToKey("Objectives", true);
		}

		kv.JumpToKey(section[objNameIdx], true);
		kv.Import(oldkv);
		kv.GoBack();

		strcopy(mapNameOld, sizeof(mapNameOld), mapName);

	} while (oldkv.GotoNextKey());

	// Copy last key.
	if (kv)
	{
		count += ExportTranslationFile(kv, mapName);
		delete kv;
	}

	delete oldkv;

	ReplyToCommand(client, PREFIX ... "Migration completed. Created %d files in \"%s\"", 
		count, fullTransPath);
	return Plugin_Handled;
}

bool ExportTranslationFile(KeyValues kv, const char[] mapName)
{
	char path[PLATFORM_MAX_PATH];
	GetMapTranslationsPath(mapName, path, sizeof(path));

	kv.Rewind();
	return kv.ExportToFile(path);
}

public void OnEntitySpawned(int entity, const char[] classname)
{
	// Bail if we haven't load file objectives yet / not gametext
	if (loadedGametextPhrases && StrEqual(classname, "game_text"))
	{
		GameTextInfo info;
		GetEntPropString(entity, Prop_Data, "m_iszMessage", info.text, sizeof(info.text));
		if (!info.text[0])	// Nothing to translate..
			return;

		// If game_text has neither text nor hammerID then there's nothing we can do
		if (!GetGameTextIdentifier(entity, info.id, sizeof(info.id)))
			return;

		// Already translated, we don't care
		if (gameTextTranslator.CanTranslate(info.id))
		{
			gtDescToGtIndex.SetValue(info.text, EntIndexToEntRef(entity));
			return;
		}

		// We caught a new unknown gametext! Schedule for saving on map end
		lateSpawnedGameText.PushArray(info);
	}
}


bool GetGameTextIdentifier(int gametext, char[] buffer, int maxlen)
{
	int hammerID = GetEntProp(gametext, Prop_Data, "m_iHammerID");
	if (hammerID)
	{
		FormatEx(buffer, maxlen, "#%d", hammerID);
	}
	else
	{
		GetEntityTargetname(gametext, buffer, maxlen);
		strtolower(buffer);
	}

	return buffer[0];
}

public Action OnGameText(UserMsg msg_id, BfRead msg, const int[] players, int playersNum, bool reliable, bool init)
{
	// Can't escape reading these
	int channel = msg.ReadByte();
	float x = msg.ReadFloat();
	float y = msg.ReadFloat();
	int effect = msg.ReadByte();
	int r1 = msg.ReadByte();
	int g1 = msg.ReadByte();
	int b1 = msg.ReadByte();
	int a1 = msg.ReadByte();
	int r2 = msg.ReadByte();
	int g2 = msg.ReadByte();
	int b2 = msg.ReadByte();	
	int a2 = msg.ReadByte();
	float fadeIn = msg.ReadFloat();
	float fadeOut = msg.ReadFloat();
	float holdTime = msg.ReadFloat();
	float fxTime = msg.ReadFloat();

	// We can finally read the message
	char activeText[MAX_GAMETEXT_LEN];
	msg.ReadString(activeText, sizeof(activeText));

	int gameTextRef = -1;
	gtDescToGtIndex.GetValue(activeText, gameTextRef);
	int gameText = EntRefToEntIndex(gameTextRef);
	if (gameTextRef == -1)
		return Plugin_Continue;

	// We found our entity, check if we translate for it
	GameTextInfo gti;
	if (!GetGameTextIdentifier(gameText, gti.id, sizeof(gti.id)))
		return Plugin_Continue;

	if (!gameTextTranslator.CanTranslate(gti.id))
		return Plugin_Continue;

	// So we do, but we can't edit the usermsg, we must wait a frame and send our own.
	// Can't pass the BfRead around either since we don't own it
	
	DataPack textParams = new DataPack();

	textParams.WriteCell(playersNum);
	for(int i; i < playersNum; i++)
		textParams.WriteCell(GetClientUserId(players[i]));

	textParams.WriteCell(channel);
	textParams.WriteFloat(x);
	textParams.WriteFloat(y);
	textParams.WriteCell(effect);
	textParams.WriteCell(r1);
	textParams.WriteCell(g1);
	textParams.WriteCell(b1);
	textParams.WriteCell(a1);
	textParams.WriteCell(r2);
	textParams.WriteCell(g2);
	textParams.WriteCell(b2);
	textParams.WriteCell(a2);
	textParams.WriteFloat(fadeIn);
	textParams.WriteFloat(fadeOut);
	textParams.WriteFloat(holdTime);
	textParams.WriteFloat(fxTime);
	textParams.WriteString(gti.id);

	RequestFrame(TranslateGameText, textParams);

	// Cancel the original usermsg
	return Plugin_Handled;
} 

void TranslateGameText(DataPack textParams)
{
	textParams.Reset();
	
	int playersNum = textParams.ReadCell();
	int[] userIds = new int[playersNum];

	for (int i; i < playersNum; i++)
		userIds[i] = textParams.ReadCell();

	// The pain continues
	int channel = textParams.ReadCell();
	float x = textParams.ReadFloat();
	float y = textParams.ReadFloat();
	int r1 = textParams.ReadCell();
	int g1 = textParams.ReadCell();
	int b1 = textParams.ReadCell();
	int a1 = textParams.ReadCell();
	int r2 = textParams.ReadCell();
	int g2 = textParams.ReadCell();
	int b2 = textParams.ReadCell();
	int a2 = textParams.ReadCell();
	int effect = textParams.ReadCell();
	float fadeIn = textParams.ReadFloat();
	float fadeOut = textParams.ReadFloat();
	float holdTime = textParams.ReadFloat();
	float fxTime = textParams.ReadFloat();

	char text[MAX_USERMSG_LEN-34];
	textParams.ReadString(text, sizeof(text));

	delete textParams;

	char transDesc[MAX_USERMSG_LEN-34];

	for (int i; i < playersNum; i++)
	{
		int client = GetClientOfUserId(userIds[i]);
		if (client)
		{
			gameTextTranslator.TranslateForClient(client, text, transDesc, sizeof(transDesc));

			Handle msg = StartMessageOne("HudMsg", client, USERMSG_RELIABLE|USERMSG_BLOCKHOOKS);
			BfWrite bf = UserMessageToBfWrite(msg);

			// So much pain
			bf.WriteByte(channel);
			bf.WriteFloat(x);
			bf.WriteFloat(y);
			bf.WriteByte(r1);
			bf.WriteByte(g1);
			bf.WriteByte(b1);
			bf.WriteByte(a1);
			bf.WriteByte(r2);
			bf.WriteByte(g2);
			bf.WriteByte(b2);
			bf.WriteByte(a2);
			bf.WriteByte(effect);
			bf.WriteFloat(fadeIn);
			bf.WriteFloat(fadeOut);
			bf.WriteFloat(holdTime);
			bf.WriteFloat(fxTime);
			bf.WriteString(transDesc);
			EndMessage();
		}
	}
}

public Action OnObjectiveMsg(UserMsg msg_id, BfRead msg, const int[] players, int playersNum, bool reliable, bool init)
{
	char objDesc[MAX_USERMSG_LEN];
	msg.ReadString(objDesc, sizeof(objDesc));

	char objName[MAX_USERMSG_LEN];

	if (!objDescToObjName.GetString(objDesc, objName, sizeof(objName)))
		return Plugin_Continue;

	// No need to lowercase, objDescToObjName already returns so
	if (!objectiveTranslator.CanTranslate(objName))
		return Plugin_Continue;

	DataPack pack = new DataPack();
	pack.WriteString(objName);
	pack.WriteString(objDesc);
	pack.WriteCell(playersNum);

	for (int i; i < playersNum; i++)
		pack.WriteCell(GetClientUserId(players[i]));

	RequestFrame(BroadcastTranslatedObjective, pack);		
	return Plugin_Handled;
}

void BroadcastTranslatedObjective(DataPack pack)
{
	pack.Reset();

	char objName[MAX_USERMSG_LEN]; // already lowercased
	pack.ReadString(objName, sizeof(objName));

	char objDesc[MAX_USERMSG_LEN];
	pack.ReadString(objDesc, sizeof(objDesc));

	int playersNum = pack.ReadCell();

	char transDesc[MAX_USERMSG_LEN];

	for (int i; i < playersNum; i++)
	{
		int client = GetClientOfUserId(pack.ReadCell());
		if (!client)
			continue;

		bool translated = objectiveTranslator.TranslateForClient(client, objName, transDesc, sizeof(transDesc));

		Handle msg = StartMessageOne("ObjectiveNotify", client, USERMSG_RELIABLE|USERMSG_BLOCKHOOKS);
		BfWrite bf = UserMessageToBfWrite(msg);
		bf.WriteString(translated ? transDesc : objDesc);
		EndMessage();
	}

	delete pack;
}

void strtolower(char[] str)
{
	int i = 0;
	while (str[i] != '\0')
	{
		str[i] = CharToLower(str[i]);
		i++;
	}
}

// Ugly hack to prevent '/' from being interpreted as a new section
// Also insert new lines as '\n' instead of an actual newline, wtf Valve?
void PhraseKeyToString(char[] phrase, int maxlen)
{
	ReplaceString(phrase, maxlen, "||", "/");
	strtolower(phrase);
}

void StringToPhraseKey(char[] phrase, int maxlen)
{
	ReplaceString(phrase, maxlen, "/", "||");
	ReplaceString(phrase, maxlen, "\n", "\\n");
}

void StringToPhraseValue(char[] phrase, int maxlen)
{
	ReplaceString(phrase, maxlen, "\n", "\\n");
}

