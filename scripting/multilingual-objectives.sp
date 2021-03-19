#include <profiler>
#include <sdktools>

#define PREFIX "[Multilingual Objectives] "
#define MAX_CODE_LEN 10
#define MAX_USERMSG_LEN 255
#define MAX_GAMETEXT_LEN MAX_USERMSG_LEN - 34
#define MAX_TARGETNAME_LEN 64
#define MAXPLAYERS_NMRIH 9

public Plugin myinfo = {
	name        = "Multilingual Objectives",
	author      = "Dysphie",
	description = "",
	version     = "2.0.0-beta",
	url         = "https://steamcommunity.com/profiles/76561198118327091"
};



char langOverride[MAXPLAYERS_NMRIH+1][MAX_CODE_LEN];

FeatureStatus smapContainsKey;
ConVar cvFallback;

methodmap Translator < StringMap
{
	public Translator() 
	{
		return view_as<Translator>(new StringMap());
	}

	public void UnloadTranslations()
	{
		if (!this.Size)
			return;
		
		StringMapSnapshot snap = this.Snapshot();
		char key[MAX_USERMSG_LEN];
		for (int i; i < snap.Length; i++)
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

		char phrase[MAX_USERMSG_LEN];
		char langCode[MAX_CODE_LEN];
		char translation[MAX_USERMSG_LEN];

		do
		{
			if (!kv.GetSectionName(phrase, sizeof(phrase)))
				continue;

			if (!kv.GotoFirstSubKey(.keyOnly=false))
				continue;

			// Build inner langs stringmap
			StringMap langs = new StringMap();
			do
			{
				if (!kv.GetSectionName(langCode, sizeof(langCode)))
					continue;

				if (GetLanguageByCode(langCode) == -1)
					continue;

				if (!kv.GetString(NULL_STRING, translation, sizeof(translation)) || !translation[0])
					continue;

				strtolower(langCode);
				langs.SetString(langCode, translation);

			} while (kv.GotoNextKey(.keyOnly=false));

			if (!langs.Size)
			{
				delete langs;
			}
			else
			{
				strtolower(phrase);
				this.SetValue(phrase, langs);
			}

			kv.GoBack();

		} while (kv.GotoNextKey());

		kv.Rewind();
	}

	public bool CanTranslate(const char[] phrase)
	{
		if (smapContainsKey == FeatureStatus_Available)
		{
			return this.ContainsKey(phrase);
		}
		
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
			char langCode[MAX_CODE_LEN];
			cvFallback.GetString(langCode, sizeof(langCode));
			if (langCode[0] != '\0')
			{
				translated = langs.GetString(langCode, buffer, maxlen);
			}
		}

		return translated;
	}
}

ConVar cvAutoLangs;
ConVar cvTransPath;
ConVar cvVerbose;

Profiler prof;

Translator gameTextTranslator;		// Holds gametext translations
Translator objectiveTranslator;		// Holds objective translations
StringMap objDescToObjName;			// Used to find objectives off their description

char cachedMapName[PLATFORM_MAX_PATH];
char cachedTransPath[PLATFORM_MAX_PATH];

ArrayList cachedAutoLangs;			// List of language codes to autogenerate translations for

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	MarkNativeAsOptional("StringMap.ContainsKey");
	return APLRes_Success;
}

public void OnPluginStart()
{
	smapContainsKey = GetFeatureStatus(FeatureType_Native, "StringMap.ContainsKey");
	objDescToObjName = new StringMap();
	gameTextTranslator = new Translator();
	objectiveTranslator = new Translator();

	prof = new Profiler();

	cachedAutoLangs = new ArrayList(ByteCountToCells(MAX_CODE_LEN));

	RegAdminCmd("mo_learn_maps", OnCmdBuildTranslations, ADMFLAG_ROOT,
			"Attempts to generate a translation file for every map in your server."
		... "mp_autolearn_languages must be set beforehand."
		... "The generated files will not include a \"GameText\" section."
		... "If a translation file for a map already exists, it may add new entries but never override existing ones."
		... "It has the potential to briefly freeze your server when issued.");

	cvVerbose = CreateConVar("mo_debug_verbose", "1", "Prints autolearn verbose when enabled");
	
	cvAutoLangs = CreateConVar("mo_autolearn_languages", "",
		"Space-separated list of language codes to autogenerate translation phrases for.");

	cvTransPath = CreateConVar("mo_translations_directory", "configs/multilingual-objectives");

	cvFallback = CreateConVar("mo_fallback_language", "", 
		"Language to display if a client's preferred language isn't translated. Leave empty to not translate.");


	RegAdminCmd("mo_forcelang", OnCmdForceLanguage, ADMFLAG_ROOT);

	cvAutoLangs.AddChangeHook(OnAutoLangsChanged);

	AutoExecConfig(.name="plugin.multilingual-objectives");

	RegAdminCmd("mo_migrate_old", OnCmdMigrate, ADMFLAG_ROOT);

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

public Action OnCmdForceLanguage(int client, int args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "Usage: mo_forcelang <language code>");
		return Plugin_Handled;
	}

	char langCode[MAX_CODE_LEN];
	GetCmdArg(1, langCode, sizeof(langCode));
	strcopy(langOverride[client], sizeof(langOverride[]), langCode);
	ReplyToCommand(client, "Displaying \"%s\" translations for your client until mapchange", langCode);
	return Plugin_Handled;
}

public void OnConfigsExecuted()
{
	GetCurrentMap(cachedMapName, sizeof(cachedMapName));

	char buffer[512];
	cvAutoLangs.GetString(buffer, sizeof(buffer));
	CacheAutoLangs(buffer);

	cvTransPath.GetString(buffer, sizeof(buffer));
	CacheTransPath(buffer);

	if (cachedMapName[0] != '\0') // Ensure we are playing a map
	{
		ParseMap(cachedMapName, .isActiveMap = true);
	}
}

public void OnAutoLangsChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	CacheAutoLangs(newValue);
}

public void OnTransPathChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	CacheTransPath(newValue);
}

void CacheTransPath(const char[] path)
{
	BuildPath(Path_SM, cachedTransPath, sizeof(cachedTransPath), path);
	
	if (!EnsurePath(cachedTransPath))
	{
		cachedTransPath[0] = '\0';
		PrintToServer(PREFIX ... "Failed to create directory: \"%s\", "
			... "you must create it manually.", cachedTransPath);
	}
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

bool EnsurePath(const char[] path)
{
	char dir[PLATFORM_MAX_PATH];

	for (int i = 0; i < strlen(path); i++)
		if (path[i] == '/' || path[i] == '\\')
			if (strcopy(dir, i+1, path) && !DirExists(dir) && !CreateDirectory(dir, 511))
				return false;

	return DirExists(path) || CreateDirectory(path, 511);
}

public void OnMapEnd()
{
	objectiveTranslator.UnloadTranslations();
	gameTextTranslator.UnloadTranslations();
	objDescToObjName.Clear();
}

public Action OnCmdBuildTranslations(int client, int args)
{
	if (!cachedAutoLangs.Length)
	{
		ReplyToCommand(client, PREFIX ... "\"mo_autolearn_languages\" must be set first.");
		return Plugin_Handled;
	}

	if (cachedTransPath[0] == '\0' || !DirExists(cachedTransPath)) 
	{
		ReplyToCommand(client, PREFIX ... 
			"Dir \"%s\" doesn't exist. Please validate it and re-run the command.", 
			cachedTransPath);
		return Plugin_Handled;
	}

	if (args < 1)
	{
		ReplyToCommand(client, PREFIX ... "Usage: mo_build_translations <mapcycle|@all>");
		return Plugin_Handled;
	}

	int flags = MAPLIST_FLAG_NO_DEFAULT;

	char mapcycle[128];
	GetCmdArg(1, mapcycle, sizeof(mapcycle));
	bool all = StrEqual(mapcycle, "@all");
	if (all)
		flags |= MAPLIST_FLAG_MAPSFOLDER;

	// Get list of active maps
	ArrayList maps;
	maps = view_as<ArrayList>(ReadMapList(.str=mapcycle, .flags=flags));
	if (!maps)
	{
		ReplyToCommand(client, PREFIX ... "No maps were found at location");
		return Plugin_Handled;
	}

	DataPack data = new DataPack();
	data.WriteCell(0);		// cursor
	data.WriteCell(maps);
	data.WriteCell(client ? GetClientUserId(client) : -1);

	LearnAllObjectivesThink(data);

	ReplyToCommand(client, PREFIX ... "Generating translation phrases for %d maps in \"%s\" %s", 
		maps.Length, all ? "maps" : mapcycle, all ? "directory" : "mapcycle");
	return Plugin_Handled;
}

void LearnAllObjectivesThink(DataPack data)
{
	data.Reset();
	int cursor = data.ReadCell();
	ArrayList maps = data.ReadCell();
	int caller = data.ReadCell();

	if (cursor >= maps.Length)
	{
		delete maps;
		delete data;

		char doneMsg[] = PREFIX ... "Finished generating translations.";

		if (caller == -1)
		{
			PrintToServer(doneMsg);
		}
		else
		{
			int client = GetClientOfUserId(caller);
			if (client)
				PrintToChat(client, doneMsg);
		}
	}
	else
	{
		char mapName[PLATFORM_MAX_PATH];
		maps.GetString(cursor, mapName, sizeof(mapName));
		
		ParseMap(mapName);

		data.Reset();
		data.WriteCell(++cursor);
		RequestFrame(LearnAllObjectivesThink, data);
	}
}

bool ParseMap(const char[] mapName, char[] error = "", int maxlen = 0, bool isActiveMap = false)
{
	char transPath[PLATFORM_MAX_PATH];
	GetMapTranslationsPath(mapName, transPath, sizeof(transPath));

	KeyValues kv = new KeyValues("Phrases");
	kv.SetEscapeSequences(true);
	kv.ImportFromFile(transPath);

	// Load learned
	if (isActiveMap)
	{
		gameTextTranslator.LoadTranslations(kv, "GameText");
		objectiveTranslator.LoadTranslations(kv, "Objectives");
	}

	// Learn. Do this after loading as there's no point in loading dummy values
	int objCount, gametextCount;

	objCount += LearnObjectives(kv, mapName, .hashDescriptions=isActiveMap);

	if (isActiveMap)
		gametextCount += LearnGameText(kv);
	
	// Don't save if count is 0, as nothing should've changed
	bool result = true;
	if (gametextCount | objCount)
	{
		if (cvVerbose.BoolValue)
		{
			PrintToServer(PREFIX ... "Generating translations for \"%s\" (Objectives: %d, GameText: %d)", 
				mapName, objCount, gametextCount);
		}

		result = kv.ExportToFile(transPath);
		if (!result)
			strcopy(error, maxlen, "Failed to export translations file");
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
	
	char objectiveDescription[MAX_USERMSG_LEN];
	char objectiveName[MAX_USERMSG_LEN];
	int count;

	for (int o; o < objectivesCount; o++)
	{
		// Skip objective ID
		file.Seek(4, SEEK_CUR); 

		ReadFileString2(file, objectiveName, sizeof(objectiveName));
		ReadFileString2(file, objectiveDescription, sizeof(objectiveDescription));

		if (objectiveName[0] != '\0')
		{
			CreatePhraseBlock(kv, objectiveName, objectiveDescription);
			count++;	

			if (hashDescriptions)
			{
				strtolower(objectiveName);
				objDescToObjName.SetString(objectiveDescription, objectiveName);
			}
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

	char targetname[MAX_TARGETNAME_LEN];
	char description[MAX_GAMETEXT_LEN];

	int entity = -1;
	int count;

	while ((entity = FindEntityByClassname(entity, "game_text")) != -1)
	{
		GetEntityTargetname(entity, targetname, sizeof(targetname));
		GetEntPropString(entity, Prop_Data, "m_iszMessage", description, sizeof(description));

		if (!targetname[0]) // Use hammer ID if targetname is unavailable
		{
			int hammerID = GetEntProp(entity, Prop_Data, "m_iHammerID");
			FormatEx(targetname, sizeof(targetname), "#%d", hammerID);
		}

		CreatePhraseBlock(kv, targetname, description);
		count++;
	}
	
	kv.GoBack();
	return count;
}


int GetEntityTargetname(int entity, char[] buffer, int maxlen)
{
	return GetEntPropString(entity, Prop_Send, "m_iName", buffer, maxlen);
}

void CreatePhraseBlock(KeyValues kv, const char[] phrase, const char[] dummyTrans)
{
	kv.JumpToKey(phrase, .create=true);

	char code[MAX_CODE_LEN];
	int max = cachedAutoLangs.Length;
	for (int i; i < max; i++)
	{
		cachedAutoLangs.GetString(i, code, sizeof(code));
		KvSetStringIfNotExists(kv, code, dummyTrans);
	}

	kv.GoBack();
	return;
}

int GetMapTranslationsPath(const char[] mapName, char[] buffer, int maxlen)
{
	FormatEx(buffer, maxlen, "%s/%s.txt", cachedTransPath, mapName);
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
		ReplyToCommand(client, "Migration failed. \"%s\" not found, or empty.", oldPath);

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

	ReplyToCommand(client, "Migration completed. Created %d files in \"%s\"", 
		count, cachedTransPath);
	return Plugin_Handled;
}

bool ExportTranslationFile(KeyValues kv, const char[] mapName)
{
	char path[PLATFORM_MAX_PATH];
	GetMapTranslationsPath(mapName, path, sizeof(path));

	kv.Rewind();
	return kv.ExportToFile(path);
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

	// Find the game text entity that triggered this
	char buffer[MAX_GAMETEXT_LEN];
	
	int gameText = -1;
	while ((gameText = FindEntityByClassname(gameText, "game_text")) != -1)
	{
		GetEntPropString(gameText, Prop_Data, "m_iszMessage", buffer, sizeof(buffer));

		if (!StrEqual(buffer, activeText))
			continue;
		
		// We found our entity, check if we translate for it
		char targetname[MAX_TARGETNAME_LEN];
		GetEntPropString(gameText, Prop_Send, "m_iName", targetname, sizeof(targetname));
		strtolower(targetname);

		if (!gameTextTranslator.CanTranslate(targetname))
		{
			// Check by #hammerID as well
			int hammerID = GetEntProp(gameText, Prop_Data, "m_iHammerID");
			FormatEx(targetname, sizeof(targetname), "#%d", hammerID);

			if (!gameTextTranslator.CanTranslate(targetname))
				return Plugin_Continue;
		}

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
		textParams.WriteString(targetname);

		RequestFrame(TranslateGameText, textParams);

		// Cancel the original usermsg
		return Plugin_Handled;
	}

	return Plugin_Continue;
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
	{
		return Plugin_Continue;
	}

	// No need to lowercase, objDescToObjName already returns so

	if (!objectiveTranslator.CanTranslate(objName))
	{
		return Plugin_Continue;
	}

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
	int len = strlen(str);
	for (int i; i < len; i++)
		str[i] = CharToLower(str[i]);
}