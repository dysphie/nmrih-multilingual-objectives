#include <sourcemod>
#include <sdktools>
#pragma semicolon 1
#pragma newdecls required

#define MAX_USERMSG_SIZE 255

ConVar g_cvEnabled;
char g_sMapName[PLATFORM_MAX_PATH];
Address g_ObjMgr;

public Plugin myinfo =
{
	name = "[NMRiH] Multilingual Objectives",
	author = "Dysphie",
	description = "Display objective messages in the player's preferred language",
	version = "1.0.5",
	url = "https://forums.alliedmods.net/showthread.php?p=2678257"
};

public void OnPluginStart() 
{
	GameData hGameConf = new GameData("multilingual-objectives.games");
	if(!hGameConf)
		SetFailState("Failed to load gamedata");

	g_ObjMgr = hGameConf.GetAddress("CNMRiH_ObjectiveManager");
	if(!g_ObjMgr)
		SetFailState("Failed to retrieve the objective manager");
	
	delete hGameConf;
	
	LoadTranslations("multilingual-objectives.phrases");

	g_cvEnabled = CreateConVar("sm_translate_objectives", "1", "Toggle the translation of objective messages");
	HookUserMessage(GetUserMessageId("ObjectiveNotify"), OnObjectiveNotification, true);

	RegAdminCmd("sm_oid", OnCmdIdentifyObjective, ADMFLAG_GENERIC, "Print out the identifier for the current objective");
}

public void OnMapStart()
{
	GetCurrentMap(g_sMapName, sizeof(g_sMapName));
	GetMapDisplayName(g_sMapName, g_sMapName, sizeof(g_sMapName));
}

public Action OnCmdIdentifyObjective(int client, int args)
{
	char sPhrase[PLATFORM_MAX_PATH];
	GetTransPhraseForCurrentObjective(sPhrase, sizeof(sPhrase));

	if(strlen(sPhrase) > 0)
		ReplyToCommand(client, "\x04\x01Current objective: \x04%s\x01", sPhrase);
	else
		ReplyToCommand(client, "Objective identifier could not be determined.");

	return Plugin_Handled;
}

public Action OnObjectiveNotification(UserMsg msg, BfRead bf, const int[] players, int playersNum, bool reliable, bool init)
{
	if(!g_cvEnabled.BoolValue)
		return Plugin_Continue;

	// Get objective sDescription
	char sDescription[MAX_USERMSG_SIZE];
	bf.ReadString(sDescription, sizeof(sDescription));

	DataPack pack = new DataPack();
	pack.WriteString(sDescription);
	pack.WriteCell(playersNum);

	for(int i; i < playersNum; i++)
		pack.WriteCell(GetClientSerial(players[i]));

	// Wait. We cannot send UserMessage inside of a UserMessage Hook
	// and we also need the new objective boundary to become active
	RequestFrame(BroadcastTranslatedObjective, pack);
	return Plugin_Handled;
}

void BroadcastTranslatedObjective(DataPack pack)
{
	pack.Reset();

	char sDescription[MAX_USERMSG_SIZE];
	pack.ReadString(sDescription, sizeof(sDescription));

	char sPhrase[PLATFORM_MAX_PATH];
	GetTransPhraseForCurrentObjective(sPhrase, sizeof(sPhrase));

	int playersNum = pack.ReadCell();

	for(int i; i < playersNum; i++)
	{
		int client = GetClientFromSerial(pack.ReadCell());
		if(!client)
			continue;

		char sBuffer[MAX_USERMSG_SIZE];
		if(strlen(sPhrase) > 0 && IsTranslatedForLanguage(sPhrase, GetClientLanguage(client)))
			Format(sBuffer, sizeof(sBuffer), "%T", sPhrase, client);
	
		Handle msg = StartMessageOne("ObjectiveNotify", client, USERMSG_RELIABLE|USERMSG_BLOCKHOOKS);
		BfWrite bf = UserMessageToBfWrite(msg);
		bf.WriteString(!sBuffer[0] ? sDescription : sBuffer);
		EndMessage();
	}

	delete pack;
}

/* Provide a way to uniquely identify an objective in the translation file */
void GetTransPhraseForCurrentObjective(char[] sBuffer, int maxlength)
{
	Address pObjective = ObjectiveManager_GetCurrentObjective(g_ObjMgr);
	if(!pObjective)
		return;

	char sObjName[64];
	Objective_GetName(pObjective, sObjName, sizeof(sObjName));

	if(sObjName[0])
		FormatEx(sBuffer, maxlength, "%s %s", g_sMapName, sObjName);
}

void Objective_GetName(Address self, char[] sBuffer, int maxlength)
{
	Address psValue = view_as<Address>(
		LoadFromAddress(self + view_as<Address>(0x4), NumberType_Int32));
	if(psValue)
		UTIL_StringtToCharArray(psValue, sBuffer, maxlength);
}

Address ObjectiveManager_GetCurrentObjective(Address self)
{
	return view_as<Address>(LoadFromAddress(self + view_as<Address>(0x78), NumberType_Int32));
}

stock int UTIL_StringtToCharArray(Address stringt, char[] sBuffer, int maxlength)
{
	Address offs; int c;
	while((c = LoadFromAddress(stringt + offs, NumberType_Int8)) != 0)
	{
		Format(sBuffer, maxlength, "%s%c", sBuffer, c);
		offs++;
	}
	return view_as<int>(offs);
}
