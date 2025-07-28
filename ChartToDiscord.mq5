#property script_show_inputs
#property strict

//#define SILENT_MODE

#include "discord.mqh"
input bool screenshot_post_enable = true; // スクリーンショットの投稿を有効化

//+------------------------------------------------------------------+
//| 入力パラメータ: ボタンの名前と表示テキスト                     |
//+------------------------------------------------------------------+
string button_name = "chart_to_discord_button";
string button_text = "Discordへポスト";


//+------------------------------------------------------------------+
//| 決済理由コード → 日本語ラベルへの変換                          |
//+------------------------------------------------------------------+
#define DEAL_REASON_CLIENT     0
#define DEAL_REASON_MOBILE     1
#define DEAL_REASON_WEB        2
#define DEAL_REASON_EXPERT     3
#define DEAL_REASON_SL         4
#define DEAL_REASON_TP         5
#define DEAL_REASON_SO         6
#define DEAL_REASON_ROLLOVER   7
#define DEAL_REASON_VMARGIN    8
#define DEAL_REASON_SPLIT      9

//+------------------------------------------------------------------+
//| チャート左上にボタンを作成（既にあれば作らない）              |
//+------------------------------------------------------------------+
bool CreateButton()
{
   if (ObjectFind(0, button_name) >= 0)
   {
      Print("❌ ボタン作成に失敗しました。同名のボタンがすでに存在しています。");
      return false;
   }

   if (!ObjectCreate(0, button_name, OBJ_BUTTON, 0, 0, 0))
   {
      Print("❌ ボタン作成に失敗しました。チャートの状態を確認してください。");
      return false;
   }
   ObjectSetInteger(0, button_name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, button_name, OBJPROP_XDISTANCE, 20);
   ObjectSetInteger(0, button_name, OBJPROP_YDISTANCE, 20);
   ObjectSetInteger(0, button_name, OBJPROP_XSIZE, 140);
   ObjectSetInteger(0, button_name, OBJPROP_YSIZE, 30);
   ObjectSetInteger(0, button_name, OBJPROP_BORDER_TYPE, BORDER_RAISED);
   ObjectSetInteger(0, button_name, OBJPROP_FONTSIZE, 10);
   ObjectSetString(0, button_name, OBJPROP_TEXT, button_text);
   ObjectSetInteger(0, button_name, OBJPROP_COLOR, clrDodgerBlue);
   ObjectSetInteger(0, button_name, OBJPROP_HIDDEN, false);
   ObjectSetInteger(0, button_name, OBJPROP_SELECTABLE, true);
   ObjectSetInteger(0, button_name, OBJPROP_SELECTED, false);
   
   Print("🟢 ボタンが生成されました。");
   return true;
}

//+------------------------------------------------------------------+
//| 初期化処理（起動時）                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   CreateButton(); // ボタン生成
   Print("DL_MT5_C2D 初期化完了");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| 終了時処理（チャートから削除時）                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   ObjectDelete(0, button_name); // ボタン削除
}

//+------------------------------------------------------------------+
//| ティック毎の処理（このスクリプトでは未使用）                   |
//+------------------------------------------------------------------+
void OnTick() {}

//+------------------------------------------------------------------+
//| チャート上のイベント処理（ボタンクリック判定）                 |
//+------------------------------------------------------------------+
void OnChartEvent(const int id,
                  const long &lparam,
                  const double &dparam,
                  const string &sparam)
{
   if (id == CHARTEVENT_OBJECT_CLICK && sparam == button_name)
   {      
      int total = PositionsTotal();
      if (total == 0)
      {
         Print("📭 ポジションを保有していません。");
         return;
      }
   
      datetime now = TimeLocal();
      string msg = "";

      Print("📊 保有ポジション一覧:");
      for (int i = 0; i < total; i++)
      {
         ulong ticket = PositionGetTicket(i);
         if (!PositionSelectByTicket(ticket)) continue;
   
         string symbol    = PositionGetString(POSITION_SYMBOL);
         int type         = PositionGetInteger(POSITION_TYPE);
         double lots      = PositionGetDouble(POSITION_VOLUME);
         double price     = PositionGetDouble(POSITION_PRICE_OPEN);
         double sl        = PositionGetDouble(POSITION_SL);
         double tp        = PositionGetDouble(POSITION_TP);
         double profit    = PositionGetDouble(POSITION_PROFIT);
         string type_str  = (type == POSITION_TYPE_BUY ? "Long" : "Short");
         string type_jp   = (type == POSITION_TYPE_BUY ? "買い" : "売り");
                        
         msg = StringFormat("%s\\n[**%s**] **%s**(%s) @%.3f SL=**%.3f** TP=%.3f",
                     TimeToString(now, TIME_DATE | TIME_MINUTES),
                     symbol, type_str, type_jp, price, sl, tp);
   
         Print(msg);
      }

      if (total > 0)
      {
         if (screenshot_post_enable)
         {
            string filename = "chart.png";
            if (ChartScreenShot(0, filename, 1024, 768, ALIGN_RIGHT))
            {
            SendImageToDiscord(webhook_url, msg, filename);
            }
            else
            {
            Print("スクリーンショットに失敗しました");
            }
         }
         else
         {
            SendMessageToDiscord(webhook_url, msg);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| トレードトランザクションイベント（決済検出とDiscord通知）       |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if (trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      ulong deal_ticket = trans.deal;
      if (!HistoryDealSelect(deal_ticket)) return;

      int entry_type = (int)HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);
      if (entry_type != DEAL_ENTRY_OUT) return; // 決済でなければ対象外

      string symbol = HistoryDealGetString(deal_ticket, DEAL_SYMBOL);
      double volume = HistoryDealGetDouble(deal_ticket, DEAL_VOLUME);
      double price  = HistoryDealGetDouble(deal_ticket, DEAL_PRICE);
      double profit = HistoryDealGetDouble(deal_ticket, DEAL_PROFIT);
      datetime time = (datetime)HistoryDealGetInteger(deal_ticket, DEAL_TIME);
      int reason    = (int)HistoryDealGetInteger(deal_ticket, DEAL_REASON);

      string reason_str = "";
      switch (reason)
      {
         case DEAL_REASON_CLIENT: reason_str = (profit >= 0) ? "利確" : "損切り"; break;
         case DEAL_REASON_SL: reason_str = "逆指値"; break;
         case DEAL_REASON_TP: reason_str = "利確指値"; break;
         case DEAL_REASON_SO: reason_str = "強制決済"; break;
         case DEAL_REASON_EXPERT: reason_str = "EA"; break;
         case DEAL_REASON_MOBILE: reason_str = "モバイル"; break;
         case DEAL_REASON_WEB: reason_str = "Web"; break;
         default: reason_str = "その他"; break;
      }
      datetime now = TimeLocal();

      string msg = StringFormat("%s\\n[**%s**] 決済[**%s**] @%.3f",
                                TimeToString(now, TIME_DATE | TIME_MINUTES),
                                symbol, reason_str, price);

      Print(msg);
      SendMessageToDiscord(webhook_url, msg); // Discord通知
   }
}
