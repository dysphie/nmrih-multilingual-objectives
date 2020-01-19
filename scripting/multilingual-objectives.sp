#include <sourcemod>
#include <sdktools>
#pragma semicolon 1
#pragma newdecls required

#define MAX_USERMSG_SIZE 255

Handle hGameConf;
ConVar cvEnabled;
char mapName[PLATFORM_MAX_PATH];
Address g_ObjectiveManager;

public Plugin myinfo =
{
	name = "[NMRiH] Multilingual Objectives",
	author = "Dysphie",
	description = "Display objective messages in the player's preferred language",
	version = "1.0.3",
	url = ""
};

stock Address operator+(Address l, int r)
{
	return l + view_as<Address>(r);
}

public void OnPluginStart() 
{
	hGameConf = LoadGameConfigFile("multilingual-objectives.games");
	if(!hGameConf)
		SetFailState("Failed to load gamedata (multilingual-objectives.games.txt)");

	g_ObjectiveManager = GameConfGetAddress(hGameConf, "CNMRiH_ObjectiveManager");
	if(g_ObjectiveManager == Address_Null)
		SetFailState("Failed to retrieve the objective manager. Check your gamedata.");

	LoadTranslations("multilingual-objectives.phrases");

	cvEnabled = CreateConVar("sm_translate_objectives", "1", "Toggle the translation of objective messages");
	HookUserMessage(GetUserMessageId("ObjectiveNotify"), OnObjectiveNotification, true);

	RegAdminCmd("sm_oid", OnCmdIdentifyObjective, ADMFLAG_GENERIC, "Print out the identifier for the current objective");
}

public void OnMapStart()
{
	GetCurrentMap(mapName, sizeof(mapName));
	GetMapDisplayName(mapName, mapName, sizeof(mapName));
}

public Action OnCmdIdentifyObjective(int client, int args)
{
	char phrase[PLATFORM_MAX_PATH];
	GetTranslationPhraseForObjective(phrase, sizeof(phrase));
	if(strlen(phrase) > 0)
		ReplyToCommand(client, "\x04\x01Current objective: \x04%s\x01", phrase);
	else
		ReplyToCommand(client, "Objective identifier could not be determined.");

	return Plugin_Handled;
}

public Action OnObjectiveNotification(UserMsg msg, BfRead bf, const int[] players, int playersNum, bool reliable, bool init)
{
	if(!cvEnabled.BoolValue)
		return Plugin_Continue;

	// Get objective description
	char description[MAX_USERMSG_SIZE];
	bf.ReadString(description, sizeof(description));

	// Wait. We cannot send UserMessage inside of a UserMessage Hook
	// and we also need the new objective boundary to become active
	DataPack data = new DataPack();
	data.WriteString(description);
	RequestFrame(TranslateObjectiveNotification, data);

	// Prevent the original UserMessage from firing 
	return Plugin_Handled;
}

void TranslateObjectiveNotification(DataPack data)
{
	// Retrieve packed objective description
	data.Reset();
	char description[MAX_USERMSG_SIZE];
	data.ReadString(description, sizeof(description));
	CloseHandle(data);

	char phrase[PLATFORM_MAX_PATH];
	GetTranslationPhraseForObjective(phrase, sizeof(phrase));

	// Relay the message to each client in their preferred language, if available
	for(int client = 1; client <= MaxClients; client++)
	{
		if(!IsClientInGame(client))
			continue;

		char buffer[MAX_USERMSG_SIZE];
		if(strlen(phrase) > 0 && IsTranslatedForLanguage(phrase, GetClientLanguage(client)))
			Format(buffer, sizeof(buffer), "%T", phrase, client);
		else
			buffer = description;

		Handle msg = StartMessageOne("ObjectiveNotify", client, USERMSG_RELIABLE|USERMSG_BLOCKHOOKS);
		BfWrite bf = UserMessageToBfWrite(msg);
		bf.WriteString(buffer);
		EndMessage();
	}
}

/* Provide a way to uniquely identify an objective in the translation file */
void GetTranslationPhraseForObjective(char[] buffer, int maxlength)
{
	Address pObjective = GetCurrentObjective();
	if(pObjective)
	{
		char objectiveName[64];
		GetObjectiveName(pObjective, objectiveName, sizeof(objectiveName));

		if(!IsNullString(objectiveName))
			FormatEx(buffer, maxlength, "%s %s", mapName, objectiveName);	
	}
}

void GetObjectiveName(Address pObjective, char[] buffer, int maxlength)
{
	Address pszValue = Addr(Deref(pObjective + 0x4));
	if(pszValue)
		GetCharArray(pszValue, buffer, maxlength);
}

Address GetCurrentObjective()
{
	return g_ObjectiveManager ? Addr(Deref(g_ObjectiveManager + Addr(0x78))) : Address_Null;
}

stock void GetCharArray(Address ptrCharArray, char[] buffer, int maxlength)
{
	Address current = Addr(0x0);
	int c;
	while((c = LoadFromAddress(ptrCharArray + current, NumberType_Int8)) != 0)
	{
		Format(buffer, maxlength, "%s%c", buffer, view_as<char>(c));
		current += 0x1;
	}
}

stock Address Addr(any value)
{
	return view_as<Address>(value);
}

stock int Deref(Address addr)
{
	return LoadFromAddress(addr, NumberType_Int32);
}
