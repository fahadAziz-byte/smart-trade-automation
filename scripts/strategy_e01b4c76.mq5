#property strict
#property version   "1.00"
#property description "RSI-based EA for XAUUSD H1"

// Input parameters
input string           InpSymbol                 = "XAUUSD";
input ENUM_TIMEFRAMES  InpTimeframe              = PERIOD_H1;
input int              InpRSIPeriod              = 14;
input double           InpRSIEntryLevel          = 46.0;
input double           InpRSIExitLevel           = 70.0;
input double           InpLotSize                = 0.01;
input int              InpStopLossPoints         = 100;
input int              InpTakeProfitPoints       = 200;
input int              InpMaxTradesPerDay        = 1;
input int              InpMagicNumber             = 184476;
input int              InpDeviationPoints         = 20;

// Global variables
int      g_rsi_handle = INVALID_HANDLE;
datetime g_last_bar_time = 0;
int      g_trades_today = 0;
int      g_day_of_year = -1;

//+------------------------------------------------------------------+
//| Utility: normalize lot size                                      |
//+------------------------------------------------------------------+
double NormalizeLots(double lots)
{
   double min_lot = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_MIN);
   double max_lot = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_MAX);
   double step    = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_STEP);

   if(step <= 0.0)
      step = 0.01;

   lots = MathMax(min_lot, MathMin(max_lot, lots));
   lots = MathFloor(lots / step) * step;

   int digits = 2;
   if(step < 0.1) digits = 2;
   if(step < 0.01) digits = 3;
   if(step < 0.001) digits = 4;

   return NormalizeDouble(lots, digits);
}

//+------------------------------------------------------------------+
//| Utility: check if new bar                                         |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime bar_time = iTime(InpSymbol, InpTimeframe, 0);
   if(bar_time == 0)
      return false;

   if(bar_time != g_last_bar_time)
   {
      g_last_bar_time = bar_time;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Utility: reset daily trade counter                                |
//+------------------------------------------------------------------+
void UpdateDailyCounter()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   if(g_day_of_year != dt.day_of_year)
   {
      g_day_of_year = dt.day_of_year;
      g_trades_today = 0;
   }
}

//+------------------------------------------------------------------+
//| Utility: count open positions for this symbol and magic           |
//+------------------------------------------------------------------+
int CountOpenPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionSelectByTicket(ticket))
      {
         string sym = PositionGetString(POSITION_SYMBOL);
         long magic = PositionGetInteger(POSITION_MAGIC);

         if(sym == InpSymbol && magic == InpMagicNumber)
            count++;
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Utility: close all positions for this symbol and magic           |
//+------------------------------------------------------------------+
void ClosePositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      long magic = PositionGetInteger(POSITION_MAGIC);

      if(sym != InpSymbol || magic != InpMagicNumber)
         continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double volume = PositionGetDouble(POSITION_VOLUME);

      MqlTradeRequest request;
      MqlTradeResult  result;
      ZeroMemory(request);
      ZeroMemory(result);

      request.action   = TRADE_ACTION_DEAL;
      request.symbol   = InpSymbol;
      request.magic    = InpMagicNumber;
      request.volume   = volume;
      request.deviation= InpDeviationPoints;
      request.position = ticket;
      request.type     = (type == POSITION_TYPE_BUY ? ORDER_TYPE_SELL : ORDER_TYPE_BUY);
      request.price    = (type == POSITION_TYPE_BUY ? SymbolInfoDouble(InpSymbol, SYMBOL_BID)
                                                     : SymbolInfoDouble(InpSymbol, SYMBOL_ASK));

      if(!OrderSend(request, result))
      {
         Print("Close order failed. Error: ", GetLastError());
      }
   }
}

//+------------------------------------------------------------------+
//| Open buy order                                                    |
//+------------------------------------------------------------------+
bool OpenBuy()
{
   double lots = NormalizeLots(InpLotSize);
   if(lots <= 0.0)
      return false;

   double ask = SymbolInfoDouble(InpSymbol, SYMBOL_ASK);
   double point = SymbolInfoDouble(InpSymbol, SYMBOL_POINT);

   double sl = 0.0;
   double tp = 0.0;

   if(InpStopLossPoints > 0)
      sl = ask - InpStopLossPoints * point;
   if(InpTakeProfitPoints > 0)
      tp = ask + InpTakeProfitPoints * point;

   MqlTradeRequest request;
   MqlTradeResult  result;
   ZeroMemory(request);
   ZeroMemory(result);

   request.action   = TRADE_ACTION_DEAL;
   request.symbol   = InpSymbol;
   request.magic    = InpMagicNumber;
   request.volume   = lots;
   request.type     = ORDER_TYPE_BUY;
   request.price    = ask;
   request.sl       = sl;
   request.tp       = tp;
   request.deviation= InpDeviationPoints;
   request.comment  = "RSI BUY";

   if(!OrderSend(request, result))
   {
      Print("Buy order failed. Error: ", GetLastError());
      return false;
   }

   return (result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED);
}

//+------------------------------------------------------------------+
//| Initialize                                                        |
//+------------------------------------------------------------------+
int OnInit()
{
   if(!SymbolSelect(InpSymbol, true))
   {
      Print("Failed to select symbol: ", InpSymbol);
      return INIT_FAILED;
   }

   g_rsi_handle = iRSI(InpSymbol, InpTimeframe, InpRSIPeriod, PRICE_CLOSE);
   if(g_rsi_handle == INVALID_HANDLE)
   {
      Print("Failed to create RSI handle. Error: ", GetLastError());
      return INIT_FAILED;
   }

   UpdateDailyCounter();
   g_last_bar_time = iTime(InpSymbol, InpTimeframe, 0);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Deinitialize                                                      |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_rsi_handle != INVALID_HANDLE)
   {
      IndicatorRelease(g_rsi_handle);
      g_rsi_handle = INVALID_HANDLE;
   }
}

//+------------------------------------------------------------------+
//| Tick processing                                                   |
//+------------------------------------------------------------------+
void OnTick()
{
   UpdateDailyCounter();

   if(!IsNewBar())
      return;

   if(g_rsi_handle == INVALID_HANDLE)
      return;

   double rsi_values[3];
   ArraySetAsSeries(rsi_values, true);

   if(CopyBuffer(g_rsi_handle, 0, 0, 3, rsi_values) < 3)
   {
      Print("Failed to copy RSI buffer. Error: ", GetLastError());
      return;
   }

   double current_rsi = rsi_values[0];

   int open_positions = CountOpenPositions();

   // Exit condition: RSI > 70 => close existing positions
   if(open_positions > 0 && current_rsi > InpRSIExitLevel)
   {
      ClosePositions();
      return;
   }

   // Entry condition: RSI < 46 => buy if no positions and daily limit not exceeded
   if(open_positions == 0 && g_trades_today < InpMaxTradesPerDay && current_rsi < InpRSIEntryLevel)
   {
      if(OpenBuy())
         g_trades_today++;
   }
}