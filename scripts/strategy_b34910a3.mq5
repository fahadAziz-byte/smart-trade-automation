#property script_show_inputs
#property strict

#include <Trade/Trade.mqh>

input string InpSymbol              = "XAUUSD";
input ENUM_TIMEFRAMES InpTimeframe   = PERIOD_H1;
input int    InpRSIPeriod           = 14;
input double InpBuyLevel            = 46.0;
input double InpExitLevel           = 70.0;
input double InpLots                = 0.01;
input int    InpStopLossPoints      = 100;
input int    InpTakeProfitPoints    = 200;
input int    InpMaxTradesPerDay     = 1;
input int    InpMagicNumber         = 34910;
input int    InpDeviationPoints     = 10;

CTrade trade;
int rsi_handle = INVALID_HANDLE;
datetime last_bar_time = 0;

//+------------------------------------------------------------------+
//| Count trades opened today for the symbol and magic                |
//+------------------------------------------------------------------+
int CountTodayTrades(const string symbol, const int magic)
{
   datetime day_start = (datetime)StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   if(day_start <= 0)
      day_start = TimeCurrent() - 86400;

   int total = HistoryDealsTotal();
   int count = 0;

   for(int i = total - 1; i >= 0; i--)
   {
      ulong deal_ticket = HistoryDealGetTicket(i);
      if(deal_ticket == 0)
         continue;

      string deal_symbol = HistoryDealGetString(deal_ticket, DEAL_SYMBOL);
      long deal_magic = HistoryDealGetInteger(deal_ticket, DEAL_MAGIC);
      datetime deal_time = (datetime)HistoryDealGetInteger(deal_ticket, DEAL_TIME);
      long entry_type = HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);

      if(deal_symbol == symbol && deal_magic == magic && deal_time >= day_start && entry_type == DEAL_ENTRY_IN)
         count++;
   }

   return count;
}

//+------------------------------------------------------------------+
//| Check if there is an open position for the symbol and magic      |
//+------------------------------------------------------------------+
bool HasOpenPosition(const string symbol, const int magic)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      string pos_symbol = PositionGetString(POSITION_SYMBOL);
      long pos_magic = PositionGetInteger(POSITION_MAGIC);

      if(pos_symbol == symbol && pos_magic == magic)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Close all positions for symbol/magic                             |
//+------------------------------------------------------------------+
void ClosePositions(const string symbol, const int magic)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      string pos_symbol = PositionGetString(POSITION_SYMBOL);
      long pos_magic = PositionGetInteger(POSITION_MAGIC);

      if(pos_symbol == symbol && pos_magic == magic)
      {
         trade.PositionClose(ticket);
      }
   }
}

//+------------------------------------------------------------------+
//| Main script entry                                                |
//+------------------------------------------------------------------+
void OnStart()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);

   if(!SymbolSelect(InpSymbol, true))
      return;

   rsi_handle = iRSI(InpSymbol, InpTimeframe, InpRSIPeriod, PRICE_CLOSE);
   if(rsi_handle == INVALID_HANDLE)
      return;

   double rsi_buffer[];
   ArraySetAsSeries(rsi_buffer, true);

   while(!IsStopped())
   {
      if(SymbolInfoInteger(InpSymbol, SYMBOL_TRADE_MODE) != SYMBOL_TRADE_MODE_FULL)
      {
         Sleep(1000);
         continue;
      }

      MqlRates rates[];
      ArraySetAsSeries(rates, true);
      if(CopyRates(InpSymbol, InpTimeframe, 0, 2, rates) < 2)
      {
         Sleep(1000);
         continue;
      }

      // Process only once per new bar
      if(rates[0].time == last_bar_time)
      {
         Sleep(1000);
         continue;
      }
      last_bar_time = rates[0].time;

      if(CopyBuffer(rsi_handle, 0, 1, 1, rsi_buffer) < 1)
      {
         Sleep(1000);
         continue;
      }

      double rsi_value = rsi_buffer[0];
      bool have_position = HasOpenPosition(InpSymbol, InpMagicNumber);

      // Exit logic: close any open position when RSI > exit level
      if(have_position && rsi_value > InpExitLevel)
      {
         ClosePositions(InpSymbol, InpMagicNumber);
         Sleep(1000);
         continue;
      }

      // Entry logic: buy when RSI < buy level, limited by daily trade count
      if(!have_position && rsi_value < InpBuyLevel)
      {
         if(CountTodayTrades(InpSymbol, InpMagicNumber) >= InpMaxTradesPerDay)
         {
            Sleep(1000);
            continue;
         }

         double ask = SymbolInfoDouble(InpSymbol, SYMBOL_ASK);
         double point = SymbolInfoDouble(InpSymbol, SYMBOL_POINT);
         int digits = (int)SymbolInfoInteger(InpSymbol, SYMBOL_DIGITS);

         if(ask <= 0.0 || point <= 0.0)
         {
            Sleep(1000);
            continue;
         }

         double sl = NormalizeDouble(ask - InpStopLossPoints * point, digits);
         double tp = NormalizeDouble(ask + InpTakeProfitPoints * point, digits);

         trade.Buy(InpLots, InpSymbol, ask, sl, tp, "RSI BUY");
      }

      Sleep(1000);
   }

   if(rsi_handle != INVALID_HANDLE)
      IndicatorRelease(rsi_handle);
}