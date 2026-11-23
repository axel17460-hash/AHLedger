-- luacheck : vérification statique du code de l'addon (lancée par GitHub à chaque push)
std = "lua51"
max_line_length = false
exclude_files = { "tests/", ".luarocks/", "lua_modules/" }
ignore = {
  "212", -- arguments inutilisés (signatures d'événements)
  "213", -- variables de boucle inutilisées
  "211/_", "211/ADDON",
}
-- Variables globales que l'addon crée
globals = { "AHLedgerDB", "SlashCmdList", "SLASH_AHLEDGER1", "UISpecialFrames" }
-- API du jeu lues par l'addon (Classic et Retail, selon le client)
read_globals = {
  "_G", "CreateFrame", "UIParent", "GameTooltip", "ItemRefTooltip", "DEFAULT_CHAT_FRAME", "C_Timer", "time", "date",
  "GetTime", "GetBuildInfo", "GetRealmName", "GetNormalizedRealmName", "UnitFactionGroup", "UnitName", "UnitLevel",
  "UnitClass", "GetZoneText", "GetMoney", "LibStub", "PlaySound", "SOUNDKIT", "ITEM_QUALITY_COLORS", "ChatFontNormal",
  "ChatEdit_InsertLink", "IsModifiedClick", "TooltipDataProcessor", "Enum", "C_EventUtils",
  "C_Item", "GetItemInfo",
  "C_AuctionHouse", "QueryAuctionItems", "CanSendAuctionQuery", "GetNumAuctionItems", "GetAuctionItemInfo",
  "GetAuctionItemTimeLeft", "GetAuctionItemLink", "AuctionFrame", "AuctionHouseFrame", "AuctionHouseFrameDisplayMode", "AuctionFrameTab1",
  "AuctionFrameTab_OnClick", "BrowseName", "GetFramesRegisteredForEvent", "Auctionator",
  "GetMerchantNumItems", "GetMerchantItemInfo", "GetMerchantItemLink", "C_MerchantFrame",
  "C_Container", "GetContainerNumSlots", "GetContainerItemInfo",
  "GetInboxNumItems", "GetInboxHeaderInfo", "GetInboxInvoiceInfo", "GetInboxItem", "GetInboxItemLink",
  "AUCTION_EXPIRED_MAIL_SUBJECT",
  "GetNumSkillLines", "GetSkillLineInfo", "GetProfessions", "GetProfessionInfo",
  "GetNumTradeSkills", "GetTradeSkillLine", "GetTradeSkillInfo", "GetTradeSkillItemLink", "GetTradeSkillNumMade",
  "GetTradeSkillNumReagents", "GetTradeSkillReagentInfo", "GetTradeSkillReagentItemLink", "C_TradeSkillUI",
  "LOOT_ITEM_SELF", "LOOT_ITEM_SELF_MULTIPLE", "LOOT_ITEM_PUSHED_SELF", "LOOT_ITEM_PUSHED_SELF_MULTIPLE",
  "GetLootSlotLink", "GetNumLootItems", "GetLootSlotInfo",
  "DaylightUI", "OneForAll", "C_AddOns", "IsAddOnLoaded",
  "IsShiftKeyDown", "Settings", "InterfaceOptions_AddCategory",
}
