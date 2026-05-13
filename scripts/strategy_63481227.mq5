#property strict
#property version   "1.00"
#property description "strategy_63481227 - RSI entry/exit EA for XAUUSD H1"

#include <Trade/Trade.mqh>

input string           InpTradeSymbol              = "XAUUSD";
input ENUM_TIMEFRAMES  InpTimeframe                = PERIOD_H1;
input int              InpRSIPeriod                = 14;
input double           InpRSIBuyBelow              = 30.0;
input double           InpRSICloseAbove            = 70.0;

input double           InpLots                     = 0.01;
input int              InpStopLossPoints           = 1000;
input int              InpTakeProfitPoints         = 10000;
input int              InpMaxTradesPerDay          = 1;
input int              InpSlippagePoints           = 20;

input ulong            InpMagicNumber              = 63481227;

CTrade trade;

int rsiHandle = INVALID_HANDLE;
datetime lastBarTime = 0;

int tradesToday = 0;
int currentDay = -1;

double initialBalance = 0.0;
bool tradingDisabled = false;

datetime GetBarTime(const string symbol, ENUM_TIMEFRAMES tf)
{
   return (datetime)iTime(symbol, tf, 0);
}

int DayOfYearFromTime(datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return dt.day_of_year;
}

bool IsNewBar()
{
   datetime bt = GetBarTime(InpTradeSymbol, InpTimeframe);
   if(bt == 0)
      return false;

   if(bt != lastBarTime)
   {
      lastBarTime = bt;
      return true;
   }
   return false;
}

bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) == InpTradeSymbol &&
            (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         {
            return true;
         }
      }
   }
   return false;
}

bool ClosePositionsBySignal()
{
   bool closed = false;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) == InpTradeSymbol &&
            (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         {
            if(trade.PositionClose(ticket))
               closed = true;
         }
      }
   }
   return closed;
}

double GetRSIValue(int shift)
{
   double buffer[];
   ArraySetAsSeries(buffer, true);

   if(CopyBuffer(rsiHandle, 0, shift, 1, buffer) <= 0)
      return EMPTY_VALUE;

   return buffer[0];
}

void UpdateDailyCounters()
{
   datetime now = TimeCurrent();
   int day = DayOfYearFromTime(now);

   if(currentDay != day)
   {
      currentDay = day;
      tradesToday = 0;
   }
}

bool CheckDrawdownLimit()
{
   if(initialBalance <= 0.0)
      return false;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double drawdown = (initialBalance - equity) / initialBalance * 100.0;

   if(drawdown <= 0.0)
      return false;

   return false;
}

double NormalizeLots(double lots)
{
   double minLot = SymbolInfoDouble(InpTradeSymbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(InpTradeSymbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(InpTradeSymbol, SYMBOL_VOLUME_STEP);

   if(lots < minLot) lots = minLot;
   if(lots > maxLot) lots = maxLot;

   if(step > 0)
      lots = MathFloor(lots / step) * step;

   int digits = (int)MathRound(-MathLog10(step));
   if(digits < 0) digits = 2;

   return NormalizeDouble(lots, digits);
}

bool OpenBuy()
{
   if(tradesToday >= InpMaxTradesPerDay)
      return false;

   if(HasOpenPosition())
      return false;

   double ask = SymbolInfoDouble(InpTradeSymbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(InpTradeSymbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0)
      return false;

   double point = SymbolInfoDouble(InpTradeSymbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(InpTradeSymbol, SYMBOL_DIGITS);

   double sl = 0.0, tp = 0.0;
   if(InpStopLossPoints > 0)
      sl = NormalizeDouble(ask - InpStopLossPoints * point, digits);
   if(InpTakeProfitPoints > 0)
      tp = NormalizeDouble(ask + InpTakeProfitPoints * point, digits);

   double lots = NormalizeLots(InpLots);

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);

   bool ok = trade.Buy(lots, InpTradeSymbol, ask, sl, tp, "RSI Buy");
   if(ok)
      tradesToday++;

   return ok;
}

int OnInit()
{
   if(_Symbol != InpTradeSymbol)
   {
      Print("Attach EA to ", InpTradeSymbol, " chart or change input symbol.");
   }

   initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   currentDay = DayOfYearFromTime(TimeCurrent());
   tradesToday = 0;

   rsiHandle = iRSI(InpTradeSymbol, InpTimeframe, InpRSIPeriod, PRICE_CLOSE);
   if(rsiHandle == INVALID_HANDLE)
   {
      Print("Failed to create RSI handle");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(rsiHandle != INVALID_HANDLE)
   {
      IndicatorRelease(rsiHandle);
      rsiHandle = INVALID_HANDLE;
   }
}

void OnTick()
{
   UpdateDailyCounters();

   if(tradingDisabled)
      return;

   if(CheckDrawdownLimit())
      return;

   if(!IsNewBar())
      return;

   double rsiCurrent = GetRSIValue(1);
   if(rsiCurrent == EMPTY_VALUE)
      return;

   // Exit logic: close buy positions when RSI is above 70
   if(rsiCurrent > InpRSICloseAbove)
   {
      ClosePositionsBySignal();
      return;
   }

   // Entry logic: buy when RSI is below 30
   if(rsiCurrent < InpRSIBuyBelow)
   {
      OpenBuy();
      return;
   }
}