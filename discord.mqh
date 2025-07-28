#ifndef DISCORD_MQH
#define DISCORD_MQH

input string webhook_url = "＜ここにDiscordのWebhook URLを入力＞"; // Discordのwebhook URL(http://...)

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
//| 引数: url       - Webhook URL                                   |
//|       message   - Discordに表示するテキスト                      |
//|       filename  - 送信する画像ファイルのパス                     |
//+------------------------------------------------------------------+
void SendImageToDiscord(const string url, const string message, const string filename)
{
  string boundary = "----WebKitFormBoundary7MA4YWxkTrZu0gW";
  string headers = "Content-Type: multipart/form-data; boundary=" + boundary + "\r\n";
  int timeout = 5000;

  // ファイル読み込み
  uchar file_data[];
  int file_size = FileReadImage(filename, file_data);
  if (file_size <= 0)
  {
    Print("画像読み込みに失敗: ", filename);
    return;
  }

  // 表示用にファイル名からパスを除去
  string shortname = filename;
  int lastSlash = FindLastChar(filename, '\\');
  if (lastSlash != -1)
    shortname = StringSubstr(filename, lastSlash + 1);


  // multipart/form-data 各パート構築
  string part1 = "--" + boundary + "\r\n"
               + "Content-Disposition: form-data; name=\"payload_json\"\r\n\r\n"
               + "{\"content\":\"" + message + "\"}\r\n";

  string part2 = "--" + boundary + "\r\n"
               + "Content-Disposition: form-data; name=\"file\"; filename=\"" + shortname + "\"\r\n"
               + "Content-Type: image/png\r\n\r\n";

  string part3 = "\r\n--" + boundary + "--\r\n";

  // 各パートをバイナリで結合
  uchar data[];
  int pos = 0;

  int len = StringToCharArray(part1, data, pos, WHOLE_ARRAY, CP_UTF8);
  pos += len - 1;
  ArrayResize(data, pos + StringLen(part2) + file_size + StringLen(part3) + 256);

  len = StringToCharArray(part2, data, pos, WHOLE_ARRAY, CP_UTF8);
  pos += len - 1;

  for (int i = 0; i < file_size; i++)
    data[pos++] = file_data[i];

  len = StringToCharArray(part3, data, pos, WHOLE_ARRAY, CP_UTF8);
  pos += len - 1;

  ArrayResize(data, pos);

  // 通信送信（SILENT_MODE無効時のみ）
#ifndef SILENT_MODE
  uchar result[];
  string result_headers;
  int status = WebRequest("POST", url, headers, timeout, data, result, result_headers);

  Print("画像送信ステータス: ", status);
  Print("レスポンス内容: ", CharArrayToString(result));

  if (status != 200)
    Print("❌ Discord画像送信失敗 (HTTP ", status, ")");
#endif
}

// 文字列中の最後の文字 ch を探す関数（補助）
int FindLastChar(const string str, const ushort ch)
{
  for (int i = StringLen(str) - 1; i >= 0; i--)
  {
    if (StringGetCharacter(str, i) == ch)
      return i;
  }
  return -1;
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


#endif // DISCORD_MQH