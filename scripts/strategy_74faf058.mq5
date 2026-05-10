#property strict
#property version   "1.00"
#property description "RSI strategy EA for XAUUSD H1"
#property script_show_inputs

#include <Trade/Trade.mqh>

input string InpSymbol                  = "XAUUSD";
input ENUM_TIMEFRAMES InpTimeframe      = PERIOD_H1;
input int    InpRSIPeriod               = 14;
input double InpBuyLevel                = 30.0;
input double InpExitLevel               = 70.0;
input double InpLotSize                 = 0.01;
input int    InpStopLossPoints          = 50;
input int    InpTakeProfitPoints        = 150;
input int    InpMaxTradesPerDay         = 3;
input double InpMaxDrawdownPercent      = 5.0;
input int    InpMaxConsecutiveLosses    = 3;
input int    InpTrailingStopPoints      = 100;
input int    InpSlippagePoints          = 30;
input ulong  InpMagicNumber             = 74058058;

CTrade trade;

int rsi_handle = INVALID_HANDLE;
datetime last_bar_time = 0;
int trades_today = 0;
int consecutive_losses = 0;
double day_start_equity = 0.0;
int day_of_year_cached = -1;

bool IsNewBar()
{
   datetime current_bar_time = iTime(InpSymbol, InpTimeframe, 0);
   if(current_bar_time == 0)
      return false;
   if(current_bar_time != last_bar_time)
   {
      last_bar_time = current_bar_time;
      return true;
   }
   return false;
}

void ResetDailyCountersIfNeeded()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_year != day_of_year_cached)
   {
      day_of_year_cached = dt.day_of_year;
      trades_today = 0;
      day_start_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   }
}

bool IsDrawdownExceeded()
{
   if(day_start_equity <= 0.0)
      return false;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double dd_percent = 0.0;
   if(day_start_equity > equity)
      dd_percent = (day_start_equity - equity) / day_start_equity * 100.0;

   return (dd_percent >= InpMaxDrawdownPercent);
}

bool HasOpenPosition()
{
   if(!PositionSelect(InpSymbol))
      return false;
   long magic = (long)PositionGetInteger(POSITION_MAGIC);
   return ((ulong)magic == InpMagicNumber);
}

void ManageTrailingStop()
{
   if(!PositionSelect(InpSymbol))
      return;

   long magic = (long)PositionGetInteger(POSITION_MAGIC);
   if((ulong)magic != InpMagicNumber)
      return;

   double point = SymbolInfoDouble(InpSymbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(InpSymbol, SYMBOL_DIGITS);

   long type = PositionGetInteger(POSITION_TYPE);
   double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl = PositionGetDouble(POSITION_SL);
   double tp = PositionGetDouble(POSITION_TP);

   MqlTick tick;
   if(!SymbolInfoTick(InpSymbol, tick))
      return;

   if(type == POSITION_TYPE_BUY)
   {
      double profit_points = (tick.bid - open_price) / point;
      if(profit_points > InpTrailingStopPoints)
      {
         double new_sl = tick.bid - InpTrailingStopPoints * point;
         new_sl = NormalizeDouble(new_sl, digits);
         if(sl == 0.0 || new_sl > sl)
            trade.PositionModify(InpSymbol, new_sl, tp);
      }
   }
   else if(type == POSITION_TYPE_SELL)
   {
      double profit_points = (open_price - tick.ask) / point;
      if(profit_points > InpTrailingStopPoints)
      {
         double new_sl = tick.ask + InpTrailingStopPoints * point;
         new_sl = NormalizeDouble(new_sl, digits);
         if(sl == 0.0 || new_sl < sl)
            trade.PositionModify(InpSymbol, new_sl, tp);
      }
   }
}

bool GetRSI(double &rsi_value)
{
   if(rsi_handle == INVALID_HANDLE)
      return false;

   double buffer[];
   ArraySetAsSeries(buffer, true);

   if(CopyBuffer(rsi_handle, 0, 0, 2, buffer) < 2)
      return false;

   rsi_value = buffer[1];
   return true;
}

bool OpenBuy()
{
   if(trades_today >= InpMaxTradesPerDay)
      return false;

   if(IsDrawdownExceeded())
      return false;

   if(consecutive_losses >= InpMaxConsecutiveLosses)
      return false;

   MqlTick tick;
   if(!SymbolInfoTick(InpSymbol, tick))
      return false;

   double point = SymbolInfoDouble(InpSymbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(InpSymbol, SYMBOL_DIGITS);

   double sl = tick.ask - InpStopLossPoints * point;
   double tp = tick.ask + InpTakeProfitPoints * point;

   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetExpertMagicNumber(InpMagicNumber);

   bool ok = trade.Buy(InpLotSize, InpSymbol, tick.ask, sl, tp, "RSI Buy");
   if(ok)
      trades_today++;

   return ok;
}

void CheckExitByRSI()
{
   if(!PositionSelect(InpSymbol))
      return;

   long magic = (long)PositionGetInteger(POSITION_MAGIC);
   if((ulong)magic != InpMagicNumber)
      return;

   double rsi_value = 0.0;
   if(!GetRSI(rsi_value))
      return;

   long type = PositionGetInteger(POSITION_TYPE);

   if(type == POSITION_TYPE_BUY && rsi_value > InpExitLevel)
   {
      trade.SetDeviationInPoints(InpSlippagePoints);
      trade.SetExpertMagicNumber(InpMagicNumber);
      trade.PositionClose(InpSymbol);
   }
}

int OnInit()
{
   if(_Symbol != InpSymbol)
   {
      // EA is intended for the specified symbol but can still run on other charts
   }

   if(!SymbolSelect(InpSymbol, true))
      return INIT_FAILED;

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);

   rsi_handle = iRSI(InpSymbol, InpTimeframe, InpRSIPeriod, PRICE_CLOSE);
   if(rsi_handle == INVALID_HANDLE)
      return INIT_FAILED;

   day_start_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   day_of_year_cached = dt.day_of_year;

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
   ResetDailyCountersIfNeeded();

   if(IsDrawdownExceeded())
      return;

   ManageTrailingStop();
   CheckExitByRSI();

   if(!IsNewBar())
      return;

   if(HasOpenPosition())
      return;

   double rsi_value = 0.0;
   if(!GetRSI(rsi_value))
      return;

   if(rsi_value < InpBuyLevel)
      OpenBuy();
}