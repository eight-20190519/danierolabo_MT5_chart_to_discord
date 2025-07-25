#property strict

input string WEBHOOK_URL = "https://discord.com/api/webhooks/1398244815480553543/76k3Y6kujDEEbKk1PKG8Gzn_IF04V_4gpL1BqHALIhtNg32FcnO79Xu94UFOLBNRv6Ld";

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
  string message = "チャート画像を送信します 📷";
  SendToDiscord(WEBHOOK_URL, message);

  string filename = "chart.png";
  if (TakeScreenshot(filename))
  {
    SendImageToDiscord(WEBHOOK_URL, filename);
  }
  else
  {
    Print("スクリーンショットに失敗しました");
  }

  return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| チャートのスクリーンショットを保存                             |
//+------------------------------------------------------------------+
bool TakeScreenshot(const string filename)
{
  // エキスパートの Files フォルダに保存（FILE_COMMON を使わない）
  return ChartScreenShot(0, filename, 1024, 768, ALIGN_RIGHT);
}

//+------------------------------------------------------------------+
//| Discord にテキストメッセージ送信                                |
//+------------------------------------------------------------------+
void SendToDiscord(const string url, const string message)
{
  string headers = "Content-Type: application/json\r\n";
  int timeout = 5000;

  string json = "{\"content\":\"" + message + "\"}";
  char data[];
  int size = StringToCharArray(json, data, 0, WHOLE_ARRAY, CP_UTF8);
  ArrayResize(data, size - 1);

  char result[];
  string result_headers;
  int status = WebRequest("POST", url, headers, timeout, data, result, result_headers);

  Print("テキスト送信ステータス: ", status);
  Print("レスポンス内容: ", CharArrayToString(result));
}

//+------------------------------------------------------------------+
//| Discord に画像ファイルを送信                                    |
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

  // multipart/form-data 構成: payload_json + file + 終端
  string part1 = "--" + boundary + "\r\n"
               + "Content-Disposition: form-data; name=\"payload_json\"\r\n\r\n"
               + "{\"content\":\"チャート画像\"}\r\n";

  string part2 = "--" + boundary + "\r\n"
               + "Content-Disposition: form-data; name=\"file\"; filename=\"" + filename + "\"\r\n"
               + "Content-Type: image/png\r\n\r\n";

  string part3 = "\r\n--" + boundary + "--\r\n";

  uchar data[];
  int pos = 0;

  int len = StringToCharArray(part1, data, pos, WHOLE_ARRAY, CP_UTF8);
  pos += len - 1;

  ArrayResize(data, pos + StringLen(part2) + file_size + StringLen(part3) + 256);

  len = StringToCharArray(part2, data, pos, WHOLE_ARRAY, CP_UTF8);
  pos += len - 1;

  for (int i = 0; i < file_size; i++) data[pos++] = file_data[i];

  len = StringToCharArray(part3, data, pos, WHOLE_ARRAY, CP_UTF8);
  pos += len - 1;

  ArrayResize(data, pos);

  uchar result[];
  string result_headers;
  int status = WebRequest("POST", url, headers, timeout, data, result, result_headers);

  Print("画像送信ステータス: ", status);
  Print("レスポンス内容: ", CharArrayToString(result));
}

//+------------------------------------------------------------------+
//| ファイル読み込み（画像を uchar[] に）                          |
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
void OnTick() {}
void OnDeinit(const int reason) {}
