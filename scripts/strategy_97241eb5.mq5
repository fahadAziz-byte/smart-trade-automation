#property strict
#property version   "1.00"
#property description "RSI strategy EA for XAUUSD H1"
#property description "Buy when RSI < 30, close when RSI > 70"
#property description "Includes risk controls: SL, TP, daily trade limit, drawdown filter, consecutive loss filter, trailing stop"

#include <Trade/Trade.mqh>

input string         InpTradeSymbol              = "XAUUSD";
input ENUM_TIMEFRAMES InpTimeframe               = PERIOD_H1;
input int            InpRSIPeriod                = 14;
input double         InpBuyLevel                 = 30.0;
input double         InpExitLevel                = 70.0;
input double         InpLotSize                  = 0.01;
input int            InpStopLossPoints           = 50;
input int            InpTakeProfitPoints         = 100;
input int            InpMaxTradesPerDay          = 1;
input double         InpMaxDrawdownPercent       = 4.0;
input int            InpMaxConsecutiveLosses     = 3;
input int            InpTrailingStopPoints       = 100;
input int            InpSlippagePoints           = 30;
input ulong          InpMagicNumber              = 97241;
input bool           InpUseTrailingStop          = true;

CTrade trade;

int rsi_handle = INVALID_HANDLE;
datetime last_bar_time = 0;

// Daily tracking
int trades_today = 0;
int day_of_year_cached = -1;
double day_start_equity = 0.0;
int consecutive_losses = 0;

datetime last_history_check = 0;

bool IsCorrectSymbol()
{
   return (_Symbol == InpTradeSymbol);
}

int GetDayOfYear(datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return dt.day_of_year;
}

void ResetDailyCountersIfNeeded()
{
   datetime now = TimeCurrent();
   int doy = GetDayOfYear(now);
   if(doy != day_of_year_cached)
   {
      day_of_year_cached = doy;
      trades_today = 0;
      day_start_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   }
}

void UpdateConsecutiveLosses()
{
   datetime from_time = last_history_check;
   datetime to_time = TimeCurrent();
   if(from_time == 0)
      from_time = to_time - 86400 * 30;

   if(!HistorySelect(from_time, to_time))
   {
      last_history_check = to_time;
      return;
   }

   int total = HistoryDealsTotal();
   datetime newest_time = last_history_check;

   for(int i = total - 1; i >= 0; i--)
   {
      ulong deal_ticket = HistoryDealGetTicket(i);
      if(deal_ticket == 0)
         continue;

      string sym = HistoryDealGetString(deal_ticket, DEAL_SYMBOL);
      ulong magic = (ulong)HistoryDealGetInteger(deal_ticket, DEAL_MAGIC);
      if(sym != InpTradeSymbol || magic != InpMagicNumber)
         continue;

      datetime deal_time = (datetime)HistoryDealGetInteger(deal_ticket, DEAL_TIME);
      if(deal_time <= last_history_check)
         continue;

      if(deal_time > newest_time)
         newest_time = deal_time;

      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT)
         continue;

      double profit = HistoryDealGetDouble(deal_ticket, DEAL_PROFIT)
                    + HistoryDealGetDouble(deal_ticket, DEAL_SWAP)
                    + HistoryDealGetDouble(deal_ticket, DEAL_COMMISSION);

      if(profit < 0.0)
         consecutive_losses++;
      else if(profit > 0.0)
         consecutive_losses = 0;
   }

   last_history_check = newest_time;
}

bool DrawdownExceeded()
{
   if(day_start_equity <= 0.0)
      return false;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double dd_percent = 0.0;
   if(day_start_equity > 0.0)
      dd_percent = (day_start_equity - equity) / day_start_equity * 100.0;

   return (dd_percent >= InpMaxDrawdownPercent);
}

bool HasOpenPosition()
{
   if(!PositionSelect(InpTradeSymbol))
      return false;

   ulong magic = (ulong)PositionGetInteger(POSITION_MAGIC);
   return (magic == InpMagicNumber);
}

bool NewBar()
{
   datetime current_bar_time = iTime(InpTradeSymbol, InpTimeframe, 0);
   if(current_bar_time == 0)
      return false;

   if(current_bar_time != last_bar_time)
   {
      last_bar_time = current_bar_time;
      return true;
   }
   return false;
}

double GetRSI(int shift)
{
   double buffer[];
   ArraySetAsSeries(buffer, true);
   if(CopyBuffer(rsi_handle, 0, shift, 1, buffer) <= 0)
      return EMPTY_VALUE;
   return buffer[0];
}

void ApplyTrailingStop()
{
   if(!InpUseTrailingStop || InpTrailingStopPoints <= 0)
      return;

   if(!PositionSelect(InpTradeSymbol))
      return;

   ulong magic = (ulong)PositionGetInteger(POSITION_MAGIC);
   if(magic != InpMagicNumber)
      return;

   long type = PositionGetInteger(POSITION_TYPE);
   double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl = PositionGetDouble(POSITION_SL);
   double tp = PositionGetDouble(POSITION_TP);

   MqlTick tick;
   if(!SymbolInfoTick(InpTradeSymbol, tick))
      return;

   double point = SymbolInfoDouble(InpTradeSymbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(InpTradeSymbol, SYMBOL_DIGITS);

   if(type == POSITION_TYPE_BUY)
   {
      double new_sl = tick.bid - InpTrailingStopPoints * point;
      new_sl = NormalizeDouble(new_sl, digits);

      if(tick.bid - open_price > InpTrailingStopPoints * point)
      {
         if(sl == 0.0 || new_sl > sl)
            trade.PositionModify(InpTradeSymbol, new_sl, tp);
      }
   }
   else if(type == POSITION_TYPE_SELL)
   {
      double new_sl = tick.ask + InpTrailingStopPoints * point;
      new_sl = NormalizeDouble(new_sl, digits);

      if(open_price - tick.ask > InpTrailingStopPoints * point)
      {
         if(sl == 0.0 || new_sl < sl)
            trade.PositionModify(InpTradeSymbol, new_sl, tp);
      }
   }
}

int OnInit()
{
   if(!SymbolSelect(InpTradeSymbol, true))
      return INIT_FAILED;

   rsi_handle = iRSI(InpTradeSymbol, InpTimeframe, InpRSIPeriod, PRICE_CLOSE);
   if(rsi_handle == INVALID_HANDLE)
      return INIT_FAILED;

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);

   day_of_year_cached = GetDayOfYear(TimeCurrent());
   day_start_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   last_history_check = TimeCurrent() - 60;

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(rsi_handle != INVALID_HANDLE)
      IndicatorRelease(rsi_handle);
}

void OnTick()
{
   if(!IsCorrectSymbol())
      return;

   ResetDailyCountersIfNeeded();
   UpdateConsecutiveLosses();

   if(DrawdownExceeded())
      return;

   if(consecutive_losses >= InpMaxConsecutiveLosses)
      return;

   ApplyTrailingStop();

   if(!NewBar())
      return;

   double rsi_current = GetRSI(1);
   if(rsi_current == EMPTY_VALUE)
      return;

   bool has_position = HasOpenPosition();

   if(has_position)
   {
      if(rsi_current > InpExitLevel)
      {
         if(PositionSelect(InpTradeSymbol))
         {
            ulong magic = (ulong)PositionGetInteger(POSITION_MAGIC);
            if(magic == InpMagicNumber)
            {
               trade.PositionClose(InpTradeSymbol);
            }
         }
      }
      return;
   }

   if(trades_today >= InpMaxTradesPerDay)
      return;

   if(rsi_current < InpBuyLevel)
   {
      MqlTick tick;
      if(!SymbolInfoTick(InpTradeSymbol, tick))
         return;

      double point = SymbolInfoDouble(InpTradeSymbol, SYMBOL_POINT);
      int digits = (int)SymbolInfoInteger(InpTradeSymbol, SYMBOL_DIGITS);

      double price = tick.ask;
      double sl = 0.0;
      double tp = 0.0;

      if(InpStopLossPoints > 0)
         sl = NormalizeDouble(price - InpStopLossPoints * point, digits);
      if(InpTakeProfitPoints > 0)
         tp = NormalizeDouble(price + InpTakeProfitPoints * point, digits);

      bool ok = trade.Buy(InpLotSize, InpTradeSymbol, price, sl, tp, "RSI BUY");
      if(ok)
         trades_today++;
   }
}