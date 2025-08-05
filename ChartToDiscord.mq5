
#property description "danierolabo_MT5_chart_to_discord"
#property description "20250805R001"
//#property version     "001.000"
//#property link        "https://..."
#property copyright   "Copyright 2025, "
#property script_show_inputs
#property strict

#define SILENT_MODE

#include <Trade\PositionInfo.mqh>

#include "global_ulong.mqh"
#include "discord.mqh"

input bool isScreenShotEnable = true; // スクリーンショット添付
input int sl_config_timeout = 60; // StopLoss編集タイムアウト

#include "Logger.mqh"

datetime g_timeout_deadline = 0;
bool     g_timeout_triggered = false;

string g_symbol = "";
ulong g_pos_id;
int g_pos_type;
double g_price; 
double g_sl;
double g_tp;

//+------------------------------------------------------------------+
//| 文字列の末尾に 'z' があれば取り除いて返す                      |
//+------------------------------------------------------------------+
string RemoveTrailingZ(string str)
{
   int len = StringLen(str);
   if(len > 0 && StringSubstr(str, len - 1, 1) == "z")
      return StringSubstr(str, 0, len - 1);
   return str;
}

string BuildEntryMessage(const Grade grade,
                         const string symbol,
                         const int type,
                         double price,
                         double sl,
                         double tp,
                         datetime timestamp = 0)
{
   string symbol_ = RemoveTrailingZ(symbol);

   string type_str  = (type == POSITION_TYPE_BUY ? "Long" : "Short");
   string type_jp   = (type == POSITION_TYPE_BUY ? "買い" : "売り");

   string sl_str = StringFormat("%.3f", sl);
   string tp_str = (tp > 0.0) ? StringFormat("%.3f", tp) : "未設定";
   string time_str = TimeToString((timestamp == 0) ? TimeLocal() : timestamp, TIME_DATE | TIME_MINUTES);

   double risk_jp = ConvertToJPY_FromSymbol(MathAbs(price - sl));
   
   double lotSize;
   if(!SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE, lotSize))
   {
      PrintFormat("❌ %s の取引単位が取得できませんでした。", _Symbol);
      if (grade == Bronze_Silver_Omni)
      {
         return StringFormat("%s\\n[**%s**] **%s**(%s) SL=**%s** TP=%s",
                           time_str, symbol_, type_str, type_jp, sl_str, tp_str);
      }
      
      return StringFormat("%s\\n[**%s**] **%s**(%s) @%.3f SL=**%s** TP=%s",
                           time_str, symbol_, type_str, type_jp, price, sl_str, tp_str);      
   }

   double lot = 10000 / (risk_jp * lotSize);
   string broker = TerminalInfoString(TERMINAL_COMPANY);

   if (grade == Bronze_Silver_Omni)
   {
      return StringFormat("%s\\n[**%s**] **%s**(%s) SL=**%s** TP=%s\\nLot=**%.3f**/10,000yen (On %s)",
                        time_str, symbol_, type_str, type_jp, sl_str, tp_str, lot, broker);
   }
   
   return StringFormat("%s\\n[**%s**] **%s**(%s) @%.3f SL=**%s** TP=%s\\nLot=**%.3f**/10,000yen (On %s)",
                        time_str, symbol_, type_str, type_jp, price, sl_str, tp_str, lot, broker);      
}

string BuildExitMessage(const Grade grade, const string symbol,
                        const int reason,
                        double price,
                        double profit,
                        double reward,
                        double risk,
                        datetime timestamp = 0)
{
   string symbol_ = RemoveTrailingZ(symbol);

   string reason_str;
   switch (reason)
   {
      case DEAL_REASON_CLIENT:  reason_str = (profit >= 0) ? "利確" : "損切り"; break;
      case DEAL_REASON_SL:      reason_str = "逆指値"; break;
      case DEAL_REASON_TP:      reason_str = "利確指値"; break;
      case DEAL_REASON_SO:      reason_str = "強制決済"; break;
      case DEAL_REASON_EXPERT:  reason_str = "EA"; break;
      case DEAL_REASON_MOBILE:  reason_str = "モバイル"; break;
      case DEAL_REASON_WEB:     reason_str = "Web"; break;
      default:                  reason_str = "その他"; break;
   }

   string time_str = TimeToString((timestamp == 0) ? TimeLocal() : timestamp, TIME_DATE | TIME_MINUTES);

   if (grade == Bronze_Silver_Omni)
   {
      return StringFormat("%s\\n[**%s**] 決済[**%s**]",
                          time_str, symbol_, reason_str);
   }
   else if (grade == Silver_Omni)
   {
      return StringFormat("%s\\n[**%s**] 決済[**%s**] @%.3f",
                           time_str, symbol_, reason_str, price);
   }

   return StringFormat("%s\\n[**%s**] 決済[**%s**] @%.3f RR=**%.3f**",
                        time_str, symbol_, reason_str, price, reward/risk);
}

int OnInit()
{
  PrintFormat("通貨シンボル: %s", _Symbol);
  CleanupLockKey();
  PrintFormat("LAST PING=%.f ms", TerminalInfoInteger(TERMINAL_PING_LAST)/1000.0);
  EventSetTimer(1);
  Print("✅ 初期化完了");
  return(INIT_SUCCEEDED);
}

void OnTick()
{
    // 何もしない
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if (trans.symbol != _Symbol)
      return;

   switch (trans.type)
   {
      case TRADE_TRANSACTION_POSITION:
         HandlePositionModified(trans);
         break;

      case TRADE_TRANSACTION_DEAL_ADD:
         {
            ulong deal_ticket = trans.deal;
            if (!HistoryDealSelect(deal_ticket))
               return;

            int entry_type = (int)HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);
            switch (entry_type)
            {
               case DEAL_ENTRY_IN:
                  HandleDealEntryIn(trans);
                  break;
               case DEAL_ENTRY_OUT:
                  HandleDealEntryOut(trans);
                  break;
               default:
                  PrintFormat("⚠ 未対応のDEAL_ENTRY: %d", entry_type);
                  break;
            }
         }
         break;
   }
}

void OnTimer()
{
   if (g_timeout_deadline == 0 || g_timeout_triggered)
      return;

   if (TimeLocal() >= g_timeout_deadline)
   {
      g_timeout_triggered = true;
      PrintFormat("🔔 タイムアウト：%d秒間ポジション修正がありませんでした。", sl_config_timeout);

      string symbol = _Symbol;
      string lock_key = symbol;

      if (!CheckGlobalUlong(lock_key))
      {
         ulong pos_id = g_pos_id;
         if (!PositionSelectByTicket(pos_id)) return;

         int pos_type = (int)PositionGetInteger(POSITION_TYPE);
         double price_open   = PositionGetDouble(POSITION_PRICE_OPEN);
         double sl    = PositionGetDouble(POSITION_SL);
         double tp    = PositionGetDouble(POSITION_TP);
         
         if (sl == 0.0)
         {
            PrintFormat("🔸 無視：symbol=%s, pos_id=%I64u", symbol, pos_id);
            return;
         }

         g_price = price_open;
         g_sl = sl;

         SetGlobalUlong(lock_key, pos_id);
         PrintFormat("✅ エントリ記録：symbol=%s, pos_id=%I64u", symbol, pos_id);
         
         string msg_omni = BuildEntryMessage(Omni, symbol, pos_type, price_open, sl, tp);
         string msg_silver = BuildEntryMessage(Silver_Omni, symbol, pos_type, price_open, sl, tp);
         string msg_bronze = BuildEntryMessage(Bronze_Silver_Omni, symbol, pos_type, price_open, sl, tp);
         
         if (isScreenShotEnable)
         {
            DiscordAnnounceWithScreenShot(msg_omni, msg_silver, msg_bronze);
         }
         else
         {
            DiscordAnnounce(msg_omni, msg_silver, msg_bronze);
         }
         Print(msg_omni);
      }
   }
}

void HandlePositionModified(const MqlTradeTransaction &trans)
{
   ulong pos_id = trans.position;
   if (!PositionSelectByTicket(pos_id))
   {
      Print("⚠ PositionSelectByTicket failed");
      return;
   }

   string symbol = PositionGetString(POSITION_SYMBOL);
   string lock_key = symbol;

   if (!CheckGlobalUlong(lock_key))
   {
      double sl   = PositionGetDouble(POSITION_SL);
      if (sl == 0.0)
      {
         PrintFormat("🔸 無視：symbol=%s, pos_id=%I64u", symbol, pos_id);
         return;
      }
      
      g_pos_id = pos_id;
      g_sl = sl;

      g_timeout_deadline = TimeLocal() + sl_config_timeout;
      g_timeout_triggered = false;

      PrintFormat("⏱ 修正タイマーを%d秒にリセット（期限：%s）",
                  sl_config_timeout,
                  TimeToString(g_timeout_deadline, TIME_SECONDS));
   }
   else
   {
      ulong stored = GetGlobalUlong(lock_key);
      PrintFormat("🔸 無視：symbol=%s, pos_id=%I64u (記録=%I64u)", symbol, pos_id, stored);
   }
}

void HandleDealEntryIn(const MqlTradeTransaction &trans)
{
   ulong pos_id  = trans.position;
   ulong deal_id = trans.deal;

   string symbol   = HistoryDealGetString(deal_id, DEAL_SYMBOL);
   string lock_key = symbol;

   if (!CheckGlobalUlong(lock_key))
   {
      if (!PositionSelectByTicket(pos_id)) return;

      double price_open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl  = PositionGetDouble(POSITION_SL);
      double tp  = PositionGetDouble(POSITION_TP);
      int pos_type = (int)PositionGetInteger(POSITION_TYPE);

      if (sl == 0.0)
      {
         PrintFormat("🔸 無視：symbol=%s, pos_id=%I64u", symbol, pos_id);
         return;
      }

      g_price = price_open;
      g_sl = sl;

      SetGlobalUlong(lock_key, pos_id);
      PrintFormat("✅ エントリ記録：symbol=%s, pos_id=%I64u", symbol, pos_id);

      string msg_omni = BuildEntryMessage(Omni, symbol, pos_type, price_open, sl, tp);
      string msg_silver = BuildEntryMessage(Silver_Omni, symbol, pos_type, price_open, sl, tp);
      string msg_bronze = BuildEntryMessage(Bronze_Silver_Omni, symbol, pos_type, price_open, sl, tp);
      
      if (isScreenShotEnable)
      {
         DiscordAnnounceWithScreenShot(msg_omni, msg_silver, msg_bronze);
      }
      else
      {
         DiscordAnnounce(msg_omni, msg_silver, msg_bronze);
      }
      Print(msg_omni);
   }
   else
   {
      ulong stored = GetGlobalUlong(lock_key);
      PrintFormat("🚫 ロック中のためエントリ抑制：symbol=%s pos_id=%I64u (記録=%I64u)", symbol, pos_id, stored);
   }
}

void HandleDealEntryOut(const MqlTradeTransaction &trans)
{
   ulong pos_id  = trans.position;
   ulong deal_id = trans.deal;

   string symbol   = HistoryDealGetString(deal_id, DEAL_SYMBOL);
   string lock_key = symbol;

   if (CheckGlobalUlong(lock_key) && GetGlobalUlong(lock_key) == pos_id)
   {
      if (!HistoryDealSelect(deal_id)) return;

      DeleteGlobalUlong(lock_key);
      PrintFormat("💢 ワンキル成立：symbol=%s, pos_id=%I64u", symbol, pos_id);
      
      int reason = (int)HistoryDealGetInteger(deal_id, DEAL_REASON);
      double price = HistoryDealGetDouble(deal_id, DEAL_PRICE);
      double profit = HistoryDealGetDouble(deal_id, DEAL_PROFIT);

      double reward = price - g_price;
      double risk = g_price - g_sl;
      
      string msg_omni = BuildExitMessage(Omni, symbol, reason, price, profit, reward, risk);
      string msg_silver = BuildExitMessage(Silver_Omni, symbol, reason, price, profit, reward, risk);
      string msg_bronze = BuildExitMessage(Bronze_Silver_Omni, symbol, reason, price, profit, reward, risk);

      DiscordAnnounce(msg_omni, msg_silver, msg_bronze);
      Print(msg_omni);
   }
   else
   {
      ulong stored = GetGlobalUlong(lock_key);
      PrintFormat("🔸 無視：symbol=%s, pos_id=%I64u (記録=%I64u)", symbol, pos_id, stored);
   }
}

void DiscordAnnounce(string msg_omni, string msg_silver, string msg_bronze)
{
   if (laboGrade == Bronze_Silver_Omni)
   {
      SendMessageToDiscord(webhook_url_omni, msg_omni);
      SendMessageToDiscord(webhook_url_silver, msg_silver);
      SendMessageToDiscord(webhook_url_bronze, msg_bronze);
   }
   else if (laboGrade == Silver_Omni)
   {
      SendMessageToDiscord(webhook_url_omni, msg_omni);
      SendMessageToDiscord(webhook_url_silver, msg_silver);
   }
   else
   {
      SendMessageToDiscord(webhook_url_omni, msg_omni);
   }
}

void DiscordAnnounceWithScreenShot(string msg_omni, string msg_silver, string msg_bronze)
{
   string filename = "chart.png";
   if (!ChartScreenShot(0, filename, 1024, 768, ALIGN_RIGHT))
   {
      return;
   }
   
   if (laboGrade == Bronze_Silver_Omni)
   {
      SendImageToDiscord(webhook_url_omni, msg_omni, filename);
      SendImageToDiscord(webhook_url_silver, msg_silver, filename);
      SendImageToDiscord(webhook_url_bronze, msg_bronze, filename);
   }
   else if (laboGrade == Silver_Omni)
   {
      SendImageToDiscord(webhook_url_omni, msg_omni, filename);
      SendImageToDiscord(webhook_url_silver, msg_silver, filename);
   }
   else
   {
      SendImageToDiscord(webhook_url_omni, msg_omni, filename);
   }
}

// トランザクションを探査してポジションIDが見つからなければGlobalVariableを削除
void CleanupLockKey()
{
   string lock_key = _Symbol;
   if (!CheckGlobalUlong(lock_key))
   {
      int total = GlobalVariablesTotal();
      PrintFormat("=== GlobalVariablesTotal() = %d ===", total);

      for(int i = 0; i < total; ++i)
      {
         string   name  = GlobalVariableName(i);
         double   value = 0.0;
         bool ok       = GlobalVariableGet(name, value);   // 参照渡し版
         datetime ts   = GlobalVariableTime(name);         // 最終アクセス時刻

         if(ok)
            PrintFormat("%3d) %-30s = %.*f  [%s]",
                        i,
                        name,
                        _Digits,                                   // 口座の小数桁
                        value,
                        TimeToString(ts, TIME_DATE|TIME_MINUTES));
         else
            PrintFormat("%3d) %-30s  <error %d>", i, name, GetLastError());
      }
      Print("=== End of list ===");
      return;
   }

   ulong pos_id = GetGlobalUlong(lock_key);

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      CPositionInfo posInfo;
      if (!posInfo.SelectByIndex(i))continue;
      if (posInfo.Identifier() == pos_id)
      {
         PrintFormat("有効なlock_key(%s)を確認しました。", lock_key);
         return;
      }
   }

   PrintFormat("不要なlock_key(%s)を削除しました。", lock_key);
   DeleteGlobalUlong(lock_key);
}

// 任意シンボルの損益（シンボルの損益通貨建て）を JPY に換算
double ConvertToJPY_FromSymbol(double amount)
{
   // 分母通貨を取得（例：XAUUSD→"USD", EURCAD→"CAD", EURJPY→"JPY"）
   string quote = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);

   // すでに JPY 建てならそのまま
   if(quote == "JPY")
      return amount;

   // 変換ペアを組み立て
   string pair1 = quote + "JPY"; // USDJPY, CADJPY など
   if(SymbolSelect(pair1, true))
   {
      double bid = SymbolInfoDouble(pair1, SYMBOL_BID);
      if(bid > 0.0)
         return amount * bid;  // XXX→JPY は掛け算
   }

   // 逆ペア（JPYXXX）が必要なら同様に SYMBOL_ASK で割り算
   string pair2 = "JPY" + quote;
   if(SymbolSelect(pair2, true))
   {
      double ask = SymbolInfoDouble(pair2, SYMBOL_ASK);
      if(ask > 0.0)
         return amount / ask;
   }

   // 取得失敗時
   PrintFormat("❌ 換算レート取得失敗: %s↔JPY", quote);
   return 0.0;
}
