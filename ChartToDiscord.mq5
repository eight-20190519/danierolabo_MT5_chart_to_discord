#property script_show_inputs
#property strict

//#define SILENT_MODE

//+------------------------------------------------------------------+
//| 入力パラメータ: ボタンの名前と表示テキスト                     |
//+------------------------------------------------------------------+
string button_name = "chart_to_discord_button";
string button_text = "Discordへポスト";

input string webhook_url = "＜ここにDiscordのWebhook URLを入力＞"; // Discordのwebhook URL(http://...)
input bool screenshot_post_enable = true; // スクリーンショットの投稿を有効化

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
//| Discordへテキスト送信                                            |
//+------------------------------------------------------------------+
void SendMessageToDiscord(const string url, const string message)
{
  string headers = "Content-Type: application/json\r\n";
  int timeout = 5000;

  string json = "{\"content\":\"" + message + "\"}";
  char data[];
  int size = StringToCharArray(json, data, 0, WHOLE_ARRAY, CP_UTF8);
  ArrayResize(data, size - 1); // Null終端削除

 #ifndef SILENT_MODE
  char result[];
  string result_headers;
  int status = WebRequest("POST", url, headers, timeout, data, result, result_headers);

  Print("テキスト送信ステータス: ", status);
  Print("レスポンス内容: ", CharArrayToString(result));
 #endif
}

//+------------------------------------------------------------------+
//| Discordへ画像送信（multipart/form-data）                        |
//+------------------------------------------------------------------+
void SendImageToDiscord(const string url, const string filename)
{
  string boundary = "----WebKitFormBoundary7MA4YWxkTrZu0gW";
  string headers = "Content-Type: multipart/form-data; boundary=" + boundary + "\r\n";
  int timeout = 5000;

  uchar file_data[];
  int file_size = FileReadImage(filename, file_data);
  if (file_size <= 0)
  {
    Print("画像読み込みに失敗");
    return;
  }

  // フォーム構成
  string part1 = "--" + boundary + "\r\n"
               + "Content-Disposition: form-data; name=\"payload_json\"\r\n\r\n"
               + "{\"content\":\"ScreenShot\"}\r\n";

  string part2 = "--" + boundary + "\r\n"
               + "Content-Disposition: form-data; name=\"file\"; filename=\"" + filename + "\"\r\n"
               + "Content-Type: image/png\r\n\r\n";

  string part3 = "\r\n--" + boundary + "--\r\n";

  uchar data[];
  int pos = 0;

  // 各パート結合
  int len = StringToCharArray(part1, data, pos, WHOLE_ARRAY, CP_UTF8);
  pos += len - 1;
  ArrayResize(data, pos + StringLen(part2) + file_size + StringLen(part3) + 256);

  len = StringToCharArray(part2, data, pos, WHOLE_ARRAY, CP_UTF8);
  pos += len - 1;

  for (int i = 0; i < file_size; i++) data[pos++] = file_data[i];

  len = StringToCharArray(part3, data, pos, WHOLE_ARRAY, CP_UTF8);
  pos += len - 1;

  ArrayResize(data, pos);

 #ifndef SILENT_MODE
  uchar result[];
  string result_headers;
  int status = WebRequest("POST", url, headers, timeout, data, result, result_headers);

  Print("画像送信ステータス: ", status);
  Print("レスポンス内容: ", CharArrayToString(result));
 #endif // SILENT_MODE
}

//+------------------------------------------------------------------+
//| チャートのスクリーンショットを保存（未使用だが汎用可）       |
//+------------------------------------------------------------------+
bool TakeScreenshot(const string filename)
{
  return ChartScreenShot(0, filename, 1024, 768, ALIGN_RIGHT);
}

//+------------------------------------------------------------------+
//| ファイルを読み込み、バイナリデータを uchar 配列に読み込む     |
//+------------------------------------------------------------------+
int FileReadImage(const string filename, uchar &buffer[])
{
  int handle = FileOpen(filename, FILE_READ | FILE_BIN);
  if (handle == INVALID_HANDLE)
  {
    Print("FileOpen失敗: ", filename);
    return -1;
  }

  int size = (int)FileSize(handle);
  ArrayResize(buffer, size);
  FileReadArray(handle, buffer, 0, size);
  FileClose(handle);
  return size;
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
   
         //string msg = StringFormat("#%I64u [%s] %s %.2f lot @ %.5f SL=%.5f TP=%.5f 利益=%.2f円",
         //            ticket, symbol, type_str, lots, price, sl, tp, profit);
                     
         string msg = StringFormat("%s\\n[**%s**] **%s**(%s) @%.3f SL=**%.3f** TP=%.3f",
                     TimeToString(now, TIME_DATE | TIME_MINUTES),
                     symbol, type_str, type_jp, price, sl, tp);
   
         Print(msg);
         SendMessageToDiscord(webhook_url, msg); // Discordへ送信
      }

      if (total > 0 && screenshot_post_enable)
      {
         string filename = "chart.png";
         if (TakeScreenshot(filename))
         {
           SendImageToDiscord(webhook_url, filename);
         }
         else
         {
           Print("スクリーンショットに失敗しました");
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
         case DEAL_REASON_CLIENT:
            reason_str = (profit >= 0) ? "利確" : "損切り";
            break;
      
         case DEAL_REASON_SL:
            reason_str = "逆指値";
            break;
      
         case DEAL_REASON_TP:
            reason_str = "利確指値";
            break;
      
         case DEAL_REASON_SO:
            reason_str = "強制決済";
            break;
      
         case DEAL_REASON_EXPERT:
            reason_str = "EA";
            break;
      
         case DEAL_REASON_MOBILE:
            reason_str = "モバイル";
            break;
      
         case DEAL_REASON_WEB:
            reason_str = "Web";
            break;
      
         default:
            reason_str = "その他";
            break;
      }

      //string msg = StringFormat("💸 決済[%s]: [%s] %.2f lot @ %.5f 利益=%.2f円 時刻=%s",
      //                          reason_str, symbol, volume, price, profit,
      //                          TimeToString(time, TIME_DATE | TIME_MINUTES));
      
      string msg = StringFormat("%s\\n[**%s**] 決済[**%s**] @%.3f",
                                TimeToString(time, TIME_DATE | TIME_MINUTES),
                                symbol, reason_str, price);

      Print(msg);
      SendMessageToDiscord(webhook_url, msg); // Discord通知
   }
}
