#property strict
#property script_show_inputs
#property version   "1.00"
#property description "RSI live-trading script for XAUUSD H1"
#property script_show_inputs

input string         InpSymbol                = "XAUUSD";
input ENUM_TIMEFRAMES InpTimeframe            = PERIOD_H1;
input int            InpRSIPeriod             = 14;
input double         InpEntryLevel            = 46.0;
input double         InpExitLevel             = 70.0;
input double         InpLotSize               = 0.01;
input int            InpStopLossPoints        = 100;
input int            InpTakeProfitPoints      = 200;
input int            InpMaxTradesPerDay       = 1;
input int            InpMagicNumber           = 106492a;
input int            InpDeviationPoints       = 10;

#include <Trade/Trade.mqh>

CTrade trade;
int rsi_handle = INVALID_HANDLE;
datetime last_bar_time = 0;

int trades_today = 0;
int current_day_of_year = -1;

bool HasOpenPosition(const string symbol)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) == symbol)
            return true;
      }
   }
   return false;
}

bool ClosePositionsBySymbol(const string symbol)
{
   bool closed_any = false;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionSelectByTicket(ticket))
      {
         string pos_symbol = PositionGetString(POSITION_SYMBOL);
         if(pos_symbol == symbol)
         {
            if(trade.PositionClose(ticket))
               closed_any = true;
         }
      }
   }
   return closed_any;
}

double NormalizeVolumeBySymbol(const string symbol, double volume)
{
   double min_lot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double max_lot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double lot_step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   if(volume < min_lot) volume = min_lot;
   if(volume > max_lot) volume = max_lot;

   if(lot_step > 0.0)
      volume = MathFloor(volume / lot_step) * lot_step;

   int vol_digits = 2;
   if(lot_step < 1.0)
   {
      vol_digits = (int)MathCeil(-MathLog10(lot_step));
      if(vol_digits < 0) vol_digits = 2;
   }

   return NormalizeDouble(volume, vol_digits);
}

bool IsNewBar(const string symbol, ENUM_TIMEFRAMES tf)
{
   datetime t[1];
   if(CopyTime(symbol, tf, 0, 1, t) != 1)
      return false;

   if(t[0] != last_bar_time)
   {
      last_bar_time = t[0];
      return true;
   }
   return false;
}

void ResetDailyCountersIfNeeded()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   if(current_day_of_year != dt.day_of_year)
   {
      current_day_of_year = dt.day_of_year;
      trades_today = 0;
   }
}

void OnStart()
{
   string symbol = InpSymbol;

   if(!SymbolSelect(symbol, true))
   {
      Print("Failed to select symbol: ", symbol);
      return;
   }

   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetExpertMagicNumber((ulong)InpMagicNumber);

   rsi_handle = iRSI(symbol, InpTimeframe, InpRSIPeriod, PRICE_CLOSE);
   if(rsi_handle == INVALID_HANDLE)
   {
      Print("Failed to create RSI handle");
      return;
   }

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   current_day_of_year = dt.day_of_year;
   trades_today = 0;

   while(!IsStopped())
   {
      ResetDailyCountersIfNeeded();

      if(IsNewBar(symbol, InpTimeframe))
      {
         double rsi_buffer[3];
         ArraySetAsSeries(rsi_buffer, true);

         if(CopyBuffer(rsi_handle, 0, 1, 2, rsi_buffer) == 2)
         {
            double current_rsi = rsi_buffer[0];

            bool buy_signal = (current_rsi < InpEntryLevel);
            bool exit_signal = (current_rsi > InpExitLevel);

            if(HasOpenPosition(symbol))
            {
               if(exit_signal)
               {
                  ClosePositionsBySymbol(symbol);
               }
            }
            else
            {
               if(buy_signal && trades_today < InpMaxTradesPerDay)
               {
                  double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
                  double point = SymbolInfoDouble(symbol, SYMBOL_POINT);

                  if(ask > 0.0 && point > 0.0)
                  {
                     double sl = ask - (InpStopLossPoints * point);
                     double tp = ask + (InpTakeProfitPoints * point);
                     double volume = NormalizeVolumeBySymbol(symbol, InpLotSize);

                     if(trade.Buy(volume, symbol, ask, sl, tp, "RSI BUY"))
                     {
                        trades_today++;
                     }
                  }
               }
            }
         }
      }

      Sleep(1000);
   }

   if(rsi_handle != INVALID_HANDLE)
      IndicatorRelease(rsi_handle);
}