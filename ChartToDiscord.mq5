#property script_show_inputs
#property strict

//#define SILENT_MODE

#include <Trade\PositionInfo.mqh>

#include "global_ulong.mqh"
#include "discord.mqh"

input bool isScreenShotEnable = true; // スクリーンショット添付
input int sl_config_timeout = 60; // StopLoss編集タイムアウト

#include "Logger.mqh"

datetime g_timeout_deadline = 0;
bool     g_timeout_triggered = false;

ulong g_pos_id;
string g_symbol = "";
int g_pos_type;
double g_price; 
double g_sl;   
double g_tp;

string BuildEntryMessage(const Grade grade,
                         const string symbol,
                         const int type,
                         double price,
                         double sl,
                         double tp,
                         datetime timestamp = 0)
{
   string type_str  = (type == POSITION_TYPE_BUY ? "Long" : "Short");
   string type_jp   = (type == POSITION_TYPE_BUY ? "買い" : "売り");

   string sl_str = StringFormat("%.3f", sl);
   string tp_str = (tp > 0.0) ? StringFormat("%.3f", tp) : "未設定";
   string time_str = TimeToString((timestamp == 0) ? TimeLocal() : timestamp, TIME_DATE | TIME_MINUTES);

   double risk_jp = ConvertToJPY(MathAbs(g_price - g_sl));
   
   double lotSize;
   if(!SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE, lotSize))
   {
      PrintFormat("❌ %s の取引単位が取得できませんでした。", _Symbol);
      if (grade == Bronze_Silver_Omni)
      {
         return StringFormat("%s\\n[**%s**] **%s**(%s) SL=**%s** TP=%s",
                           time_str, symbol, type_str, type_jp, sl_str, tp_str);
      }
      
      return StringFormat("%s\\n[**%s**] **%s**(%s) @%.3f SL=**%s** TP=%s",
                           time_str, symbol, type_str, type_jp, price, sl_str, tp_str);      
   }

   double lot = 10000 / (risk_jp * lotSize);
   string broker = TerminalInfoString(TERMINAL_COMPANY);
   
   if (grade == Bronze_Silver_Omni)
   {
      return StringFormat("%s\\n[**%s**] **%s**(%s) SL=**%s** TP=%s\\nLot=**%.3f**/10,000yen (On %s)",
                        time_str, symbol, type_str, type_jp, sl_str, tp_str, lot, broker);
   }
   
   return StringFormat("%s\\n[**%s**] **%s**(%s) @%.3f SL=**%s** TP=%s\\nLot=**%.3f**/10,000yen (On %s)",
                        time_str, symbol, type_str, type_jp, price, sl_str, tp_str, lot, broker);      
}

string BuildExitMessage(const Grade grade, const string symbol,
                        const int reason,
                        double price,
                        double profit,
                        datetime timestamp = 0)
{
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

   double reward = price - g_price;
   double risk = g_price - g_sl;
   string time_str = TimeToString((timestamp == 0) ? TimeLocal() : timestamp, TIME_DATE | TIME_MINUTES);

   PrintFormat("reowrd %.3f, risk %.3f, g_price %.3f, g_sl %.3f", reward, risk, g_price, g_sl);

   if (grade == Bronze_Silver_Omni)
   {
      return StringFormat("%s\\n[**%s**] 決済[**%s**]",
                          time_str, symbol, reason_str);
   }
   else if (grade == Silver_Omni)
   {
      return StringFormat("%s\\n[**%s**] 決済[**%s**] @%.3f",
                           time_str, symbol, reason_str, price);
   }

   return StringFormat("%s\\n[**%s**] 決済[**%s**] @%.3f RR=**%.3f**",
                        time_str, symbol, reason_str, price, reward/risk);
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

      string lock_key = g_symbol;

      if (!CheckUlongFromGlobal(lock_key))
      {
         if (!PositionSelectByTicket(g_pos_id)) return;

         if (!(g_sl > 0.0))
         {
            PrintFormat("🔸 無視：symbol=%s, pos_id=%I64u", g_symbol, g_pos_id);
            return;
         }

         SaveUlongToGlobal(lock_key, g_pos_id);
         PrintFormat("✅ エントリ記録：symbol=%s, pos_id=%I64u", g_symbol, g_pos_id);
         
         string msg_omni = BuildEntryMessage(Omni, g_symbol, g_pos_type, g_price, g_sl, g_tp);
         string msg_silver = BuildEntryMessage(Silver_Omni, g_symbol, g_pos_type, g_price, g_sl, g_tp);
         string msg_bronze = BuildEntryMessage(Bronze_Silver_Omni, g_symbol, g_pos_type, g_price, g_sl, g_tp);
         
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

   if (!CheckUlongFromGlobal(lock_key))
   {
      g_pos_id  = pos_id;
      g_symbol  = symbol;
      //g_price   = PositionGetDouble(POSITION_PRICE_OPEN);
      g_sl      = PositionGetDouble(POSITION_SL);
      g_tp      = PositionGetDouble(POSITION_TP);
      g_pos_type = (int)PositionGetInteger(POSITION_TYPE);

      if (!(g_sl > 0.0))
      {
         PrintFormat("🔸 無視：symbol=%s, pos_id=%I64u", symbol, pos_id);
         return;
      }

      g_timeout_deadline = TimeLocal() + sl_config_timeout;
      g_timeout_triggered = false;

      PrintFormat("⏱ 修正タイマーを%d秒にリセット（期限：%s）",
                  sl_config_timeout,
                  TimeToString(g_timeout_deadline, TIME_SECONDS));
   }
   else
   {
      ulong stored = LoadUlongFromGlobal(lock_key);
      PrintFormat("🔸 無視：symbol=%s, pos_id=%I64u (記録=%I64u)", symbol, pos_id, stored);
   }
}

void HandleDealEntryIn(const MqlTradeTransaction &trans)
{
   ulong pos_id  = trans.position;
   ulong deal_id = trans.deal;

   string symbol   = HistoryDealGetString(deal_id, DEAL_SYMBOL);
   string lock_key = symbol;

   if (!CheckUlongFromGlobal(lock_key))
   {
      if (!PositionSelectByTicket(pos_id)) return;

      g_pos_id  = pos_id;
      g_symbol  = symbol;
      g_price   = PositionGetDouble(POSITION_PRICE_OPEN);
      g_sl      = PositionGetDouble(POSITION_SL);
      g_tp      = PositionGetDouble(POSITION_TP);
      g_pos_type = (int)PositionGetInteger(POSITION_TYPE);

      if (!(g_sl > 0.0))
      {
         PrintFormat("🔸 無視：symbol=%s, pos_id=%I64u", symbol, pos_id);
         return;
      }

      SaveUlongToGlobal(lock_key, pos_id);
      PrintFormat("✅ エントリ記録：symbol=%s, pos_id=%I64u", symbol, pos_id);

      string msg_omni = BuildEntryMessage(Omni, g_symbol, g_pos_type, g_price, g_sl, g_tp);
      string msg_silver = BuildEntryMessage(Silver_Omni, g_symbol, g_pos_type, g_price, g_sl, g_tp);
      string msg_bronze = BuildEntryMessage(Bronze_Silver_Omni, g_symbol, g_pos_type, g_price, g_sl, g_tp);
      
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
      ulong stored = LoadUlongFromGlobal(lock_key);
      PrintFormat("🚫 ロック中のためエントリ抑制：symbol=%s pos_id=%I64u (記録=%I64u)", symbol, pos_id, stored);
   }
}

void HandleDealEntryOut(const MqlTradeTransaction &trans)
{
   ulong pos_id  = trans.position;
   ulong deal_id = trans.deal;

   string symbol   = HistoryDealGetString(deal_id, DEAL_SYMBOL);
   string lock_key = symbol;

   if (CheckUlongFromGlobal(lock_key) && LoadUlongFromGlobal(lock_key) == pos_id)
   {
      if (!HistoryDealSelect(deal_id)) return;

      RemoveUlongFromGlobal(lock_key);
      PrintFormat("💢 ワンキル成立：symbol=%s, pos_id=%I64u", symbol, pos_id);
      
      int reason = (int)HistoryDealGetInteger(deal_id, DEAL_REASON);
      double price = HistoryDealGetDouble(deal_id, DEAL_PRICE);
      double profit = HistoryDealGetDouble(deal_id, DEAL_PROFIT);

      string msg_omni = BuildExitMessage(Omni, symbol, reason, price, profit);
      string msg_silver = BuildExitMessage(Silver_Omni, symbol, reason, price, profit);
      string msg_bronze = BuildExitMessage(Bronze_Silver_Omni, symbol, reason, price, profit);

      DiscordAnnounce(msg_omni, msg_silver, msg_bronze);
      Print(msg_omni);
   }
   else
   {
      ulong stored = LoadUlongFromGlobal(lock_key);
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
   if (!CheckUlongFromGlobal(lock_key))
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

   ulong pos_id = LoadUlongFromGlobal(lock_key);

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
   RemoveUlongFromGlobal(lock_key);
}

// 任意の損益（通貨口座建て）をJPYに変換
double ConvertToJPY(double amountInAccountCurrency)
{
   string accountCurrency = AccountInfoString(ACCOUNT_CURRENCY);
   if (accountCurrency == "JPY")
      return amountInAccountCurrency;

   string symbol1 = accountCurrency + "JPY";
   string symbol2 = "JPY" + accountCurrency;

   double rate;

   if (SymbolInfoDouble(symbol1, SYMBOL_ASK, rate))
      return amountInAccountCurrency * rate;
   else if (SymbolInfoDouble(symbol2, SYMBOL_BID, rate))
      return amountInAccountCurrency / rate;
   else
   {
      PrintFormat("❌ 換算レート取得失敗: %s↔JPY", accountCurrency);
      return 0.0;
   }
}
