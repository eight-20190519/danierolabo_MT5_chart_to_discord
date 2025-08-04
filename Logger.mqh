//+------------------------------------------------------------------+
//| ロガーモジュール（Logger.mqh）                                  |
//+------------------------------------------------------------------+
#ifndef LOGGER_MQH
#define LOGGER_MQH

// ログレベル定義
enum LogLevel
{
   LOG_TRACE = 0,
   LOG_DEBUG,
   LOG_INFO,
   LOG_WARNING,
   LOG_ERROR,
   LOG_FATAL
};

// ログレベル文字列化
string LogLevelToString(LogLevel level)
{
   switch (level)
   {
      case LOG_TRACE:   return "TRACE";
      case LOG_DEBUG:   return "DEBUG";
      case LOG_INFO:    return "INFO";
      case LOG_WARNING: return "WARNING";
      case LOG_ERROR:   return "ERROR";
      case LOG_FATAL:   return "FATAL";
      default:          return "UNKNOWN";
   }
}

// 現在の閾値（inputで外から変更可能）
input int LogThreshold = LOG_INFO;

void Log(LogLevel level, const string message)
{
   if (level < LogThreshold)
      return;

   // タイムスタンプ作成
   datetime now = TimeLocal();  // または TimeCurrent() でもOK
   string timestamp = TimeToString(now, TIME_DATE | TIME_SECONDS);
   string log_msg = "[" + timestamp + "][" + LogLevelToString(level) + "] " + message;

   // 日付別ログファイル名生成
   string day = TimeToString(now, TIME_DATE);
   StringReplace(day, ".", "");  // "2025.07.29" → "20250729"
   string log_filename = "danierolabo_" + day + ".log";

   // ターミナル出力
   Print(log_msg);

   // ファイル出力（追記・Shift-JIS）
   int handle = FileOpen(log_filename, FILE_READ | FILE_WRITE | FILE_TXT | FILE_COMMON | FILE_ANSI);

   if (handle != INVALID_HANDLE)
   {
      FileSeek(handle, 0, SEEK_END);
      FileWrite(handle, log_msg);
      FileClose(handle);
   }
   else
   {
      Print("⚠ FileOpen失敗: ", GetLastError());
   }
}

#endif // LOGGER_MQH
