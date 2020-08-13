#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define MAX_USERMSG_LEN 255

public Plugin myinfo =
{
	name = "[NMRiH] Multilingual Objectives",
	author = "Dysphie",
	description = "Display objective messages in the player's preferred language",
	version = "1.0.6",
	url = "https://forums.alliedmods.net/showthread.php?p=2678257"
};

stock Address operator+(Address base, int off) {
	return base + view_as<Address>(off);
}

methodmap AddressBase {
	property Address addr {
		public get() { 
			return view_as<Address>(this); 
		}
	}
}

methodmap Objective < AddressBase {

	public Objective(Address addr) {
		return view_as<Objective>(addr);
	}

	property int name {
		public get() {
			return LoadFromAddress(this.addr + 0x4, NumberType_Int32);
		}
	}

	public int GetName(char[] buffer, int maxlen) {
		return UTIL_StringtToCharArray(view_as<Address>(this.name), buffer, maxlen);
	}
}

methodmap ObjectiveManager < AddressBase {

	public ObjectiveManager(Address addr) {
		return view_as<ObjectiveManager>(addr);
	}

	property int currentObjectiveIndex {
		public get() {
			return LoadFromAddress(this.addr + 0x70, NumberType_Int32);
		}
	}

	property Objective currentObjective {
		public get() {
			return Objective(view_as<Address>(
				LoadFromAddress(this.addr + 0x78, NumberType_Int32)));
		}
	}
}

ConVar g_hEnabled;
ObjectiveManager g_pObjMgr;
char g_sMapName[PLATFORM_MAX_PATH];

public void OnPluginStart() 
{
	GameData hGameData = new GameData("multilingual-objectives.games");
	if (!hGameData)
		SetFailState("Failed to load gamedata");

	g_pObjMgr = ObjectiveManager(hGameData.GetAddress("CNMRiH_ObjectiveManager"));
	if (!g_pObjMgr)
		SetFailState("Failed to retrieve the objective manager");

	delete hGameData;

	LoadTranslations("multilingual-objectives.phrases");
	g_hEnabled = CreateConVar("sm_translate_objectives", "1", "Toggle the translation of objective messages");
	HookUserMessage(GetUserMessageId("ObjectiveNotify"), OnObjectiveNotification, true);
	RegAdminCmd("sm_oid", OnCmdIdentifyObjective, ADMFLAG_GENERIC, 
		"Output the translation phrase for the current objective");
}

public void OnMapStart()
{
	GetCurrentMap(g_sMapName, sizeof(g_sMapName));
	GetMapDisplayName(g_sMapName, g_sMapName, sizeof(g_sMapName));
}

public Action OnCmdIdentifyObjective(int client, int args)
{
	Objective pCurObj = g_pObjMgr.currentObjective;
	if (!pCurObj)
	{
		ReplyToCommand(client, "No objectives running.");
		return Plugin_Handled;
	}

	char sTransKey[256];
	GetTransKeyForObjective(pCurObj, sTransKey, sizeof(sTransKey));
	ReplyToCommand(client, "\x04\x01Current objective: \x04%s\x01", sTransKey);

	return Plugin_Handled;
}

public Action OnObjectiveNotification(UserMsg msg, BfRead bf, const int[] players, int playersNum, 
	bool reliable, bool init)
{
	if (!g_hEnabled)
		return Plugin_Continue;

	Objective pCurObj = g_pObjMgr.currentObjective;
	if (!pCurObj)
		return Plugin_Continue;

	char sTransKey[216];
	GetTransKeyForObjective(pCurObj, sTransKey, sizeof(sTransKey));

	if (!sTransKey[0] || !TranslationPhraseExists(sTransKey))
		return Plugin_Continue;

	char sObjDescription[MAX_USERMSG_LEN];
	bf.ReadString(sObjDescription, sizeof(sObjDescription));

	DataPack hMsgData = new DataPack();
	hMsgData.WriteString(sObjDescription);
	hMsgData.WriteString(sTransKey);
	hMsgData.WriteCell(playersNum);

	for (int i; i < playersNum; i++)
		hMsgData.WriteCell(GetClientUserId(players[i]));

	RequestFrame(BroadcastTranslatedObjective, hMsgData);
	return Plugin_Handled;
}

void BroadcastTranslatedObjective(DataPack hMsgData)
{
	hMsgData.Reset();

	char sObjDescription[MAX_USERMSG_LEN];
	hMsgData.ReadString(sObjDescription, sizeof(sObjDescription));

	char sTransKey[256];
	hMsgData.ReadString(sTransKey, sizeof(sTransKey));

	char sTransDescription[MAX_USERMSG_LEN];

	int playersNum = hMsgData.ReadCell();
	for (int i; i < playersNum; i++)
	{
		int client = GetClientOfUserId(hMsgData.ReadCell());
		if (!client)
			continue;

		if (IsTranslatedForLanguage(sTransKey, GetClientLanguage(client)))
			FormatEx(sTransDescription, sizeof(sTransDescription), "%T", sTransKey, client);
		else
			sTransDescription[0] = '\0';

		Handle msg = StartMessageOne("ObjectiveNotify", client, USERMSG_RELIABLE|USERMSG_BLOCKHOOKS);
		BfWrite bf = UserMessageToBfWrite(msg);		
		bf.WriteString(sTransDescription[0] ? sTransDescription : sObjDescription);
		EndMessage();
	}

	delete hMsgData;
}

int GetTransKeyForObjective(Objective objective, char[] buffer, int maxlen)
{
	objective.GetName(buffer, maxlen);
	return Format(buffer, maxlen, "%s %s", g_sMapName, buffer);
}

int UTIL_StringtToCharArray(Address pSrc, char[] buffer, int maxlen)
{
	any i;
	while (--maxlen && (buffer[i] = LoadFromAddress(pSrc + i, NumberType_Int8)) != '\0')
		i++;

	buffer[i] = '\0';
	return i;
}