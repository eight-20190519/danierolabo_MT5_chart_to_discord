//+------------------------------------------------------------------+
//| グローバル変数へulong（64bit符号なし整数）を保存                 |
//+------------------------------------------------------------------+
void SaveUlongToGlobal(const string name, const ulong value)
{
   // 下位32bit
   uint lo = (uint)( value & 0xFFFFFFFF );
   // 上位32bit
   uint hi = (uint)( value >> 32 );
   // double にキャストして GlobalVariable に格納
   GlobalVariableSet(name + "_LO", (double)lo);
   GlobalVariableSet(name + "_HI", (double)hi);
}

//+------------------------------------------------------------------+
//| グローバル変数からulong（64bit符号なし整数）を読み込む          |
//+------------------------------------------------------------------+
ulong LoadUlongFromGlobal(const string name)
{
   string loName = name + "_LO";
   string hiName = name + "_HI";
   if(!GlobalVariableCheck(loName) || !GlobalVariableCheck(hiName))
   {
      Print("Error: GlobalVariable が存在しません: ", loName, " or ", hiName);
      return(0);
   }
   uint lo = (uint)GlobalVariableGet(loName);
   uint hi = (uint)GlobalVariableGet(hiName);
   // 上位32bitをシフトして OR 結合
   return (((ulong)hi) << 32) | (ulong)lo;
}

//+------------------------------------------------------------------+
//| グローバル変数から保存したulongを削除                            |
//+------------------------------------------------------------------+
void RemoveUlongFromGlobal(const string name)
{
   string loName = name + "_LO";
   string hiName = name + "_HI";
   if(GlobalVariableCheck(loName))
      GlobalVariableDel(loName);
   if(GlobalVariableCheck(hiName))
      GlobalVariableDel(hiName);
}

bool CheckUlongFromGlobal(const string name)
{
   string loName = name + "_LO";
   string hiName = name + "_HI";
   if(!GlobalVariableCheck(loName) || !GlobalVariableCheck(hiName))
   {
      RemoveUlongFromGlobal(name);
      return false;
   }

   return true;
}