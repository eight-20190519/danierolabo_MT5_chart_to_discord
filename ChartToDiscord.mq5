
#property description "danierolabo_MT5_chart_to_discord"
#property description "20250807R001"
//#property version     "001.000"
//#property link        "https://..."
#property copyright   "Copyright 2025, "
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
ulong    g_pos_id;

string g_keyPriceOpen = "_PRICE_OPEN";
string g_keySl = "_FIRST_SL";
string g_keyActiveSl = "_ACTIVE_SL";
string g_noticeMsg = "\\n※本データは資料提供を目的とし、投資勧誘や助言を意図するものではありません。";

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

// 小物: シンボルに合わせて丸める
string FmtBySymbol(const string symbol, const double v)
{
   int d = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   return (v > 0.0) ? DoubleToString(v, d) : "未設定";
}

string BuildEntryMessage(const Grade grade,
                         const string symbol,
                         const int type,
                         double price,
                         double sl,
                         double tp,
                         datetime timestamp = 0)
{
   // 前処理
   const string symbol_  = RemoveTrailingZ(symbol);
   const bool   isBuy    = (type == POSITION_TYPE_BUY);
   const string type_str = isBuy ? "Long" : "Short";
   const string type_jp  = isBuy ? "買い"  : "売り";
   const string time_str = TimeToString(timestamp == 0 ? TimeLocal() : timestamp,
                                        TIME_DATE | TIME_MINUTES);

   // 桁数依存の表記は一括で
   const string sl_str  = FmtBySymbol(symbol, sl);
   const string tp_str  = FmtBySymbol(symbol, tp);
   const string price_open_str = (grade == Bronze_Silver_Omni) ? "" : (" @" + FmtBySymbol(symbol, price));

   // 本体
   string baseMsg = StringFormat("%s\\n[**%s**] **%s**(%s)%s SL=**%s** TP=%s",
                                 time_str, symbol_, type_str, type_jp,
                                 price_open_str, sl_str, tp_str);

   // ロット計算（契約サイズは _Symbol ではなく引数の symbol を見る）
   double contract_size = 0.0;
   bool ok = SymbolInfoDouble(symbol, SYMBOL_TRADE_CONTRACT_SIZE, contract_size);

   double lot = 0.0;
   if (ok)
   {
      // 価格差→JPY換算（実装依存）：1単位あたりのリスク額を想定
      double risk_jpy_per_unit = ConvertToJPY_FromSymbol(MathAbs(price - sl));
      if (risk_jpy_per_unit > 0.0 && contract_size > 0.0)
      {
         lot = 10000.0 / (risk_jpy_per_unit * contract_size);   // 1万円リスク
      }
      else
      {
         ok = false;
         PrintFormat("risk_jpy_per_unit(%f), contract_size(%f)",risk_jpy_per_unit, contract_size);
         PrintFormat("❌ %s のJPY換算に失敗しました。", symbol);
      }
   }
   else
   {
      int err = GetLastError();
      PrintFormat("SymbolInfoDouble(%s,SYMBOL_TRADE_CONTRACT_SIZE) failed. err=%d", symbol, err);
      PrintFormat("❌ %s の取引単位が取得できませんでした。", symbol);
   }

   if (!ok) return baseMsg + g_noticeMsg;

   // 取引単位の表示（整数っぽければ整数で、そうでなければ小数2桁）
   string unit_str = (MathAbs(contract_size - (double)(long)contract_size) < 1e-7)
                   ? IntegerToString((int)contract_size)
                   : DoubleToString(contract_size, 2);

   string broker = TerminalInfoString(TERMINAL_COMPANY);
   string suffix = StringFormat("\\nLot=**%.3f**/1万円 (%s 取引単位=%s)", lot, broker, unit_str);

   return baseMsg + suffix + g_noticeMsg;
}

// 理由文字列（SL/TP/強制決済を優先。該当なければ profit で利確/損切）
string GetExitReasonString(const int reason, const double profit)
{
   if (reason == DEAL_REASON_SL)     return "逆指値";
   if (reason == DEAL_REASON_TP)     return "利確指値";
   if (reason == DEAL_REASON_SO)     return "強制決済";
   if (reason == DEAL_REASON_EXPERT) return "EA";
   if (reason == DEAL_REASON_MOBILE) return "モバイル";
   if (reason == DEAL_REASON_WEB)    return "Web";
   if (reason == DEAL_REASON_CLIENT) return (profit >= 0.0 ? "利確" : "損切り");
   return "その他";
}

string BuildExitMessage(const Grade grade,
                        const string symbol,
                        const int reason,
                        const double price,
                        const double profit,
                        const double reward,
                        const double risk,
                        datetime timestamp = 0)
{
   // 前処理
   const string symbol_   = RemoveTrailingZ(symbol);
   const string time_str  = TimeToString(timestamp == 0 ? TimeLocal() : timestamp,
                                         TIME_DATE | TIME_MINUTES);
   const string reason_str = GetExitReasonString(reason, profit);

   // ベース
   string baseMsg = StringFormat("%s\\n[**%s**] 決済[**%s**]",
                                 time_str, symbol_, reason_str);

   // 価格表示（桁は銘柄依存で自動整形）
   const string price_close_str =
       (grade <= Silver_Omni) ? (" @" + FmtBySymbol(symbol, price)) : "";

   // RR 表示（0 除算ガード）
   string rr_fmt = "";
   if (grade < Silver_Omni && risk != 0.0)
      rr_fmt = StringFormat(" RR=**%.3f**", reward / risk);

   return baseMsg + price_close_str + rr_fmt + g_noticeMsg;
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

         GlobalVariableSet(symbol + g_keyPriceOpen, price_open);
         GlobalVariableSet(symbol + g_keySl, sl);
         GlobalVariableSet(symbol + g_keyActiveSl, sl);
         
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
      
      g_timeout_deadline = TimeLocal() + sl_config_timeout;
      g_timeout_triggered = false;

      g_pos_id = pos_id;

      PrintFormat("⏱ 修正タイマーを%d秒にリセット（期限：%s）",
                  sl_config_timeout,
                  TimeToString(g_timeout_deadline, TIME_SECONDS));
   }
   else if (GetGlobalUlong(lock_key) == pos_id)
   {
      double active_sl   = PositionGetDouble(POSITION_SL);

      double first_sl = 0.0;
      string key_first_sl = symbol + g_keySl;
      if (GlobalVariableCheck(key_first_sl))
      {
         first_sl = GlobalVariableGet(key_first_sl);
      }
      if (active_sl != first_sl)
      {
         GlobalVariableSet(symbol + g_keyActiveSl, active_sl);
         PrintFormat("SLの更新を検出 from %.3f to %.3f", GlobalVariableGet(key_first_sl), GlobalVariableGet(symbol + g_keyActiveSl));
      }
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

      GlobalVariableSet(symbol + g_keyPriceOpen, price_open);
      GlobalVariableSet(symbol + g_keySl, sl);
      GlobalVariableSet(symbol + g_keyActiveSl, sl);

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
      
      double price_open = 0.0;
      string key_price_open = symbol + g_keyPriceOpen;
      if (GlobalVariableCheck(key_price_open))
      {
         price_open = GlobalVariableGet(key_price_open);
         GlobalVariableDel(key_price_open);
      }

      double first_sl = 0.0;
      string key_first_sl = symbol + g_keySl;
      if (GlobalVariableCheck(key_first_sl))
      {
         first_sl = GlobalVariableGet(key_first_sl);
         GlobalVariableDel(key_first_sl);
      }

      double active_sl = 0.0;
      string key_active_sl = symbol + g_keyActiveSl;
      if (GlobalVariableCheck(key_active_sl))
      {
         active_sl = GlobalVariableGet(key_active_sl);
         GlobalVariableDel(key_active_sl);
      }

      int reason = (int)HistoryDealGetInteger(deal_id, DEAL_REASON);
      if (reason == DEAL_REASON_SL && active_sl != first_sl)
      {
         PrintFormat("SLと初期SLの相違を検出 from %.3f to %.3f", first_sl, active_sl);
         reason = DEAL_REASON_CLIENT;
      }

      double price = HistoryDealGetDouble(deal_id, DEAL_PRICE);
      double profit = HistoryDealGetDouble(deal_id, DEAL_PROFIT);

      double reward = price - price_open;
      double risk = first_sl == 0.0 ? 0.0 : price_open - first_sl;
      
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
   else if(SymbolSelect(pair1 + "z", true))
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
   else if(SymbolSelect(pair2 + "z", true))
   {
      double ask = SymbolInfoDouble(pair2, SYMBOL_ASK);
      if(ask > 0.0)
         return amount / ask;
   }

   // 取得失敗時
   PrintFormat("❌ 換算レート取得失敗: %s↔JPY", quote);
   return 0.0;
}
