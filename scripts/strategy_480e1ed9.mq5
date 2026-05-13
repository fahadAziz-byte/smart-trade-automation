#property copyright "OpenAI"
#property link      ""
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

input string InpSymbol = "XAUUSD";
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_H1;
input int    InpRSIPeriod = 14;
input double InpBuyRSILevel = 46.0;
input double InpExitRSILevel = 70.0;
input double InpLots = 0.01;
input int    InpStopLossPoints = 100;
input int    InpTakeProfitPoints = 200;
input int    InpMaxTradesPerDay = 1;
input ulong  InpMagicNumber = 480e1ed9;
input int    InpDeviationPoints = 10;

CTrade trade;
int rsi_handle = INVALID_HANDLE;
datetime last_bar_time = 0;

// Track daily trade count
int trades_today = 0;
int last_day_of_year = -1;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   if(Symbol() == NULL || InpSymbol == "")
      return(INIT_FAILED);

   trade.SetExpertMagicNumber((int)InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);

   rsi_handle = iRSI(InpSymbol, InpTimeframe, InpRSIPeriod, PRICE_CLOSE);
   if(rsi_handle == INVALID_HANDLE)
   {
      Print("Failed to create RSI handle. Error: ", GetLastError());
      return(INIT_FAILED);
   }

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(rsi_handle != INVALID_HANDLE)
   {
      IndicatorRelease(rsi_handle);
      rsi_handle = INVALID_HANDLE;
   }
}

//+------------------------------------------------------------------+
//| Reset daily counters if new day                                  |
//+------------------------------------------------------------------+
void ResetDailyCounterIfNeeded()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   if(last_day_of_year != dt.day_of_year)
   {
      last_day_of_year = dt.day_of_year;
      trades_today = 0;
   }
}

//+------------------------------------------------------------------+
//| Check if there is an open position for this symbol/magic          |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionSelectByIndex(i))
      {
         string pos_symbol = PositionGetString(POSITION_SYMBOL);
         long pos_magic = PositionGetInteger(POSITION_MAGIC);

         if(pos_symbol == InpSymbol && pos_magic == (long)InpMagicNumber)
            return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Close positions if RSI exit condition is met                      |
//+------------------------------------------------------------------+
void CheckExitCondition(double rsi_value)
{
   if(rsi_value > InpExitRSILevel)
   {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         if(PositionSelectByIndex(i))
         {
            string pos_symbol = PositionGetString(POSITION_SYMBOL);
            long pos_magic = PositionGetInteger(POSITION_MAGIC);

            if(pos_symbol == InpSymbol && pos_magic == (long)InpMagicNumber)
            {
               trade.PositionClose(pos_symbol);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Open BUY position                                                 |
//+------------------------------------------------------------------+
void OpenBuy()
{
   double ask = 0.0, bid = 0.0;
   if(!SymbolInfoDouble(InpSymbol, SYMBOL_ASK, ask) || !SymbolInfoDouble(InpSymbol, SYMBOL_BID, bid))
      return;

   double point = SymbolInfoDouble(InpSymbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(InpSymbol, SYMBOL_DIGITS);

   double sl = 0.0;
   double tp = 0.0;

   if(InpStopLossPoints > 0)
      sl = NormalizeDouble(ask - InpStopLossPoints * point, digits);
   if(InpTakeProfitPoints > 0)
      tp = NormalizeDouble(ask + InpTakeProfitPoints * point, digits);

   trade.Buy(InpLots, InpSymbol, ask, sl, tp, "RSI BUY");
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   if(rsi_handle == INVALID_HANDLE)
      return;

   ResetDailyCounterIfNeeded();

   // Run logic only on a new bar of the selected timeframe
   datetime current_bar_time = iTime(InpSymbol, InpTimeframe, 0);
   if(current_bar_time == 0 || current_bar_time == last_bar_time)
      return;
   last_bar_time = current_bar_time;

   double rsi_buffer[2];
   ArraySetAsSeries(rsi_buffer, true);

   if(CopyBuffer(rsi_handle, 0, 0, 2, rsi_buffer) < 2)
   {
      Print("Failed to copy RSI data. Error: ", GetLastError());
      return;
   }

   double rsi_current = rsi_buffer[0];

   // Exit condition first
   CheckExitCondition(rsi_current);

   // Entry condition: RSI < 46 and max trades/day not exceeded
   if(rsi_current < InpBuyRSILevel && trades_today < InpMaxTradesPerDay)
   {
      if(!HasOpenPosition())
      {
         OpenBuy();
         if(trade.ResultRetcode() == TRADE_RETCODE_DONE)
            trades_today++;
      }
   }
}