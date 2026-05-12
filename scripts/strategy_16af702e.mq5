#property strict
#property version   "1.10"
#property description "RSI Strategy EA for XAUUSD"

#include <Trade/Trade.mqh>

input string          InpSymbol           = "XAUUSD";
input ENUM_TIMEFRAMES InpTimeframe        = PERIOD_H1;
input int             InpRSIPeriod        = 14;
input double          InpRSIEntryLevel    = 30.0;
input double          InpRSIExitLevel     = 70.0;
input double          InpLots             = 0.01;
input int             InpStopLossPoints   = 1000;   // 1000 points/pips as requested
input int             InpTakeProfitPoints = 10000;  // 10000 points/pips as requested
input int             InpMaxTradesPerDay  = 1;
input ulong           InpMagicNumber      = 160702;
input int             InpDeviationPoints  = 10;

CTrade trade;

int      rsi_handle = INVALID_HANDLE;
datetime last_bar_time = 0;
int      trades_today = 0;
int      day_of_year_cached = -1;

string EA_SYMBOL;
ENUM_TIMEFRAMES EA_TF;
ulong EA_MAGIC;

int GetDayOfYear(datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return dt.day_of_year;
}

void UpdateDailyCounter()
{
   datetime now = TimeCurrent();
   int doy = GetDayOfYear(now);
   if(doy != day_of_year_cached)
   {
      day_of_year_cached = doy;
      trades_today = 0;
   }
}

bool IsSymbolReady()
{
   if(!SymbolSelect(EA_SYMBOL, true))
      return false;

   long trade_mode = SYMBOL_TRADE_MODE_DISABLED;
   if(!SymbolInfoInteger(EA_SYMBOL, SYMBOL_TRADE_MODE, trade_mode))
      return false;

   return (trade_mode != SYMBOL_TRADE_MODE_DISABLED);
}

bool IsNewBar()
{
   datetime bar_time = iTime(EA_SYMBOL, EA_TF, 0);
   if(bar_time != last_bar_time)
   {
      last_bar_time = bar_time;
      return true;
   }
   return false;
}

bool GetRSIValue(double &rsi_value)
{
   double buffer[];
   ArraySetAsSeries(buffer, true);

   if(CopyBuffer(rsi_handle, 0, 1, 1, buffer) != 1)
      return false;

   rsi_value = buffer[0];
   return true;
}

int CountOpenPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionSelectByTicket(ticket))
      {
         string sym = PositionGetString(POSITION_SYMBOL);
         long magic = PositionGetInteger(POSITION_MAGIC);
         if(sym == EA_SYMBOL && (ulong)magic == EA_MAGIC)
            count++;
      }
   }
   return count;
}

bool OpenBuy()
{
   double ask = 0.0;
   if(!SymbolInfoDouble(EA_SYMBOL, SYMBOL_ASK, ask))
      return false;

   double point = SymbolInfoDouble(EA_SYMBOL, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(EA_SYMBOL, SYMBOL_DIGITS);

   double sl = 0.0;
   double tp = 0.0;

   if(InpStopLossPoints > 0)
      sl = NormalizeDouble(ask - InpStopLossPoints * point, digits);
   if(InpTakeProfitPoints > 0)
      tp = NormalizeDouble(ask + InpTakeProfitPoints * point, digits);

   trade.SetExpertMagicNumber(EA_MAGIC);
   trade.SetDeviationInPoints(InpDeviationPoints);

   return trade.Buy(InpLots, EA_SYMBOL, 0.0, sl, tp, "RSI Buy");
}

void CloseBuyPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionSelectByTicket(ticket))
      {
         string sym = PositionGetString(POSITION_SYMBOL);
         long magic = PositionGetInteger(POSITION_MAGIC);
         long type = PositionGetInteger(POSITION_TYPE);

         if(sym == EA_SYMBOL && (ulong)magic == EA_MAGIC && type == POSITION_TYPE_BUY)
         {
            trade.SetExpertMagicNumber(EA_MAGIC);
            trade.PositionClose(ticket);
         }
      }
   }
}

int OnInit()
{
   EA_SYMBOL = InpSymbol;
   EA_TF = InpTimeframe;
   EA_MAGIC = InpMagicNumber;

   if(!IsSymbolReady())
      return INIT_FAILED;

   rsi_handle = iRSI(EA_SYMBOL, EA_TF, InpRSIPeriod, PRICE_CLOSE);
   if(rsi_handle == INVALID_HANDLE)
      return INIT_FAILED;

   last_bar_time = iTime(EA_SYMBOL, EA_TF, 0);
   day_of_year_cached = GetDayOfYear(TimeCurrent());
   trades_today = 0;

   trade.SetExpertMagicNumber(EA_MAGIC);
   trade.SetDeviationInPoints(InpDeviationPoints);

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(rsi_handle != INVALID_HANDLE)
   {
      IndicatorRelease(rsi_handle);
      rsi_handle = INVALID_HANDLE;
   }
}

void OnTick()
{
   if(!IsSymbolReady())
      return;

   UpdateDailyCounter();

   if(!IsNewBar())
      return;

   double rsi = 0.0;
   if(!GetRSIValue(rsi))
      return;

   if(rsi > InpRSIExitLevel)
      CloseBuyPositions();

   if(rsi < InpRSIEntryLevel)
   {
      if(trades_today >= InpMaxTradesPerDay)
         return;

      if(CountOpenPositions() == 0)
      {
         if(OpenBuy())
            trades_today++;
      }
   }
}