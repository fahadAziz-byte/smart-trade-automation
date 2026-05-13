#property strict
#property version   "1.00"
#property description "RSI-based EA for XAUUSD on H1"
#property description "Entry: RSI < 46 BUY, Exit: RSI > 70 CLOSE"

#include <Trade/Trade.mqh>

input string           InpSymbol                  = "XAUUSD";
input ENUM_TIMEFRAMES  InpTimeframe               = PERIOD_H1;
input int              InpRSIPeriod               = 14;
input double           InpBuyRSILevel             = 46.0;
input double           InpExitRSILevel            = 70.0;
input double           InpLotSize                 = 0.01;
input int              InpStopLossPoints          = 100;
input int              InpTakeProfitPoints        = 200;
input int              InpMaxTradesPerDay         = 1;
input ulong            InpMagicNumber             = 40417217;

CTrade trade;
int rsi_handle = INVALID_HANDLE;
datetime last_bar_time = 0;
datetime current_day_start = 0;
int trades_today = 0;

datetime GetDayStart(datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   return StructToTime(dt);
}

bool IsNewBar()
{
   datetime bar_time = iTime(InpSymbol, InpTimeframe, 0);
   if(bar_time <= 0)
      return false;

   if(bar_time != last_bar_time)
   {
      last_bar_time = bar_time;
      return true;
   }
   return false;
}

int CountOpenPositionsBySymbolMagic(string symbol, ulong magic)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionSelectByIndex(i))
      {
         if(PositionGetString(POSITION_SYMBOL) == symbol &&
            (ulong)PositionGetInteger(POSITION_MAGIC) == magic)
         {
            count++;
         }
      }
   }
   return count;
}

bool ClosePositionsBySymbolMagic(string symbol, ulong magic)
{
   bool all_closed = true;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionSelectByIndex(i))
      {
         string pos_symbol = PositionGetString(POSITION_SYMBOL);
         ulong pos_magic = (ulong)PositionGetInteger(POSITION_MAGIC);
         if(pos_symbol == symbol && pos_magic == magic)
         {
            ulong ticket = (ulong)PositionGetInteger(POSITION_TICKET);
            if(!trade.PositionClose(ticket))
               all_closed = false;
         }
      }
   }
   return all_closed;
}

bool OpenBuy()
{
   double ask = SymbolInfoDouble(InpSymbol, SYMBOL_ASK);
   double point = SymbolInfoDouble(InpSymbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(InpSymbol, SYMBOL_DIGITS);

   double sl = 0.0, tp = 0.0;
   if(InpStopLossPoints > 0)
      sl = NormalizeDouble(ask - InpStopLossPoints * point, digits);
   if(InpTakeProfitPoints > 0)
      tp = NormalizeDouble(ask + InpTakeProfitPoints * point, digits);

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(20);

   return trade.Buy(InpLotSize, InpSymbol, 0.0, sl, tp, "RSI Buy");
}

bool GetRSIValue(double &rsi_value)
{
   double buffer[];
   ArraySetAsSeries(buffer, true);
   if(CopyBuffer(rsi_handle, 0, 0, 3, buffer) < 0)
      return false;

   rsi_value = buffer[1];
   return true;
}

int OnInit()
{
   if(!SymbolSelect(InpSymbol, true))
      return INIT_FAILED;

   rsi_handle = iRSI(InpSymbol, InpTimeframe, InpRSIPeriod, PRICE_CLOSE);
   if(rsi_handle == INVALID_HANDLE)
      return INIT_FAILED;

   trade.SetExpertMagicNumber(InpMagicNumber);

   current_day_start = GetDayStart(TimeCurrent());
   trades_today = 0;
   last_bar_time = iTime(InpSymbol, InpTimeframe, 0);

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
   if(_Symbol != InpSymbol)
   {
      if(!SymbolInfoInteger(InpSymbol, SYMBOL_SELECT))
         SymbolSelect(InpSymbol, true);
   }

   datetime now = TimeCurrent();
   datetime day_start = GetDayStart(now);
   if(day_start != current_day_start)
   {
      current_day_start = day_start;
      trades_today = 0;
   }

   if(Bars(InpSymbol, InpTimeframe) < InpRSIPeriod + 10)
      return;

   double rsi_value;
   if(!GetRSIValue(rsi_value))
      return;

   int open_positions = CountOpenPositionsBySymbolMagic(InpSymbol, InpMagicNumber);

   if(open_positions > 0)
   {
      if(rsi_value > InpExitRSILevel)
         ClosePositionsBySymbolMagic(InpSymbol, InpMagicNumber);
      return;
   }

   if(!IsNewBar())
      return;

   if(trades_today >= InpMaxTradesPerDay)
      return;

   if(rsi_value < InpBuyRSILevel)
   {
      if(OpenBuy())
         trades_today++;
   }
}