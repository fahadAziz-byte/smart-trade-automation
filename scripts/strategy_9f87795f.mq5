//+------------------------------------------------------------------+
//| strategy_9f87795f.mq5                                            |
//+------------------------------------------------------------------+
#property copyright "OWL"
#property link      ""
#property version   "1.00"
#property script_show_inputs

#include <Trade\Trade.mqh>

//--- Input parameters
input string         InpSymbol              = "XAUUSD";
input ENUM_TIMEFRAMES InpTimeframe          = PERIOD_H1;
input int            InpRSIPeriod           = 14;
input double         InpRSIBuyLevel         = 30.0;
input double         InpRSISellLevel        = 70.0;
input double         InpLotSize             = 0.01;
input int            InpStopLossPoints      = 300;
input int            InpTakeProfitPoints    = 450;
input int            InpMaxTradesPerDay     = 1;
input double         InpMaxDrawdownPercent  = 5.0;
input int            InpMaxConsecutiveLosses = 3;
input int            InpTrailingStopPoints  = 100;
input int            InpSlippagePoints      = 30;
input ulong          InpMagicNumber         = 9877951;

//--- Global variables
CTrade         trade;
int            rsiHandle;
double         rsiBuffer[];
int            dailyTradeCount        = 0;
int            consecutiveLossCount    = 0;
double         dayStartBalance        = 0.0;
datetime       lastTradeDate          = 0;
bool           trailingActive         = false;
double         currentTrailingSL       = 0.0;

//+------------------------------------------------------------------+
//| Script program start function                                      |
//+------------------------------------------------------------------+
void OnStart()
  {
   //--- Validate symbol
   if(!SymbolSelect(InpSymbol, true))
     {
      Print("ERROR: Failed to select symbol ", InpSymbol);
      return;
     }

   //--- Check if market is open
   if(SymbolInfoInteger(InpSymbol, SYMBOL_TRADE_MODE) != SYMBOL_TRADE_MODE_FULL)
     {
      Print("ERROR: Market is not open for trading on ", InpSymbol);
      return;
     }

   //--- Create RSI indicator handle
   rsiHandle = iRSI(InpSymbol, InpTimeframe, InpRSIPeriod, PRICE_CLOSE);
   if(rsiHandle == INVALID_HANDLE)
     {
      Print("ERROR: Failed to create RSI indicator handle. Error: ", GetLastError());
      return;
     }

   //--- Set buffer as series
   ArraySetAsSeries(rsiBuffer, true);

   //--- Initialize trade object
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFilling(ORDER_FILLING_FOK);

   //--- Initialize daily tracking
   dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   lastTradeDate = StringToTime(IntegerToString(dt.year) + "." +
                                IntegerToString(dt.mon) + "." +
                                IntegerToString(dt.day));

   Print("Strategy started on ", InpSymbol, " (", EnumToString(InpTimeframe), ")");
   Print("RSI Period: ", InpRSIPeriod, " | Buy<", InpRSIBuyLevel, " | Sell>", InpRSISellLevel);
   Print("SL: ", InpStopLossPoints, " pts | TP: ", InpTakeProfitPoints, " pts | Lot: ", InpLotSize);
   Print("Max trades/day: ", InpMaxTradesPerDay, " | Max DD: ", InpMaxDrawdownPercent, "%");

   //--- Main loop
   while(!IsStopped())
     {
      //--- Check market availability
      if(SymbolInfoInteger(InpSymbol, SYMBOL_TRADE_MODE) != SYMBOL_TRADE_MODE_FULL)
        {
         Sleep(1000);
         continue;
        }

      //--- Reset daily counters
      MqlDateTime currentDt;
      TimeToStruct(TimeCurrent(), currentDt);
      datetime currentDate = StringToTime(IntegerToString(currentDt.year) + "." +
                                          IntegerToString(currentDt.mon) + "." +
                                          IntegerToString(currentDt.day));
      if(currentDate != lastTradeDate)
        {
         lastTradeDate = currentDate;
         dailyTradeCount = 0;
         dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
         Print("New trading day started. Counters reset.");
        }

      //--- Check max drawdown
      double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      double drawdownPercent = 0.0;
      if(dayStartBalance > 0)
         drawdownPercent = ((dayStartBalance - currentEquity) / dayStartBalance) * 100.0;

      if(drawdownPercent >= InpMaxDrawdownPercent)
        {
         Print("Max drawdown reached: ", DoubleToString(drawdownPercent, 2), "%. Pausing new trades.");
         Sleep(1000);
         continue;
        }

      //--- Check max consecutive losses
      if(consecutiveLossCount >= InpMaxConsecutiveLosses)
        {
         Print("Max consecutive losses reached: ", consecutiveLossCount, ". Pausing new trades.");
         Sleep(1000);
         continue;
        }

      //--- Copy RSI data
      if(CopyBuffer(rsiHandle, 0, 0, 3, rsiBuffer) < 3)
        {
         Sleep(1000);
         continue;
        }

      double rsiCurrent = rsiBuffer[1];  // Most recent completed candle
      double rsiPrev    = rsiBuffer[2];  // Previous candle

      //--- Manage trailing stop on open positions
      ManageTrailingStop();

      //--- Check if we can trade today
      if(dailyTradeCount >= InpMaxTradesPerDay)
        {
         Sleep(1000);
         continue;
        }

      //--- Count open positions for this script
      int openPositions = CountOpenPositions();

      //--- ENTRY: RSI < 30 => BUY
      if(rsiCurrent < InpRSIBuyLevel && openPositions == 0)
        {
         double ask = SymbolInfoDouble(InpSymbol, SYMBOL_ASK);
         if(ask <= 0)
           {
            Sleep(1000);
            continue;
           }

         //--- Calculate SL and TP
         double point = SymbolInfoDouble(InpSymbol, SYMBOL_POINT);
         int    digits = (int)SymbolInfoInteger(InpSymbol, SYMBOL_DIGITS);

         double sl = 0.0;
         double tp = 0.0;

         if(InpStopLossPoints > 0)
            sl = NormalizeDouble(ask - InpStopLossPoints * point, digits);

         if(InpTakeProfitPoints > 0)
            tp = NormalizeDouble(ask + InpTakeProfitPoints * point, digits);

         //--- Validate lot size
         double minLot  = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_MIN);
         double maxLot  = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_MAX);
         double lotStep = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_STEP);
         double lot = InpLotSize;
         if(lot < minLot) lot = minLot;
         if(lot > maxLot) lot = maxLot;
         lot = MathFloor(lot / lotStep) * lotStep;
         lot = NormalizeDouble(lot, 2);

         //--- Check free margin
         double margin = 0.0;
         if(!OrderCalcMargin(ORDER_TYPE_BUY, InpSymbol, lot, ask, margin))
           {
            Print("ERROR: OrderCalcMargin failed.");
            Sleep(1000);
            continue;
           }

         if(margin > AccountInfoDouble(ACCOUNT_FREE_MARGIN))
           {
            Print("ERROR: Insufficient free margin. Required: ", DoubleToString(margin, 2),
                  " Available: ", DoubleToString(AccountInfoDouble(ACCOUNT_FREE_MARGIN), 2));
            Sleep(1000);
            continue;
           }

         //--- Open BUY trade
         bool result = trade.Buy(lot, InpSymbol, ask, sl, tp, "RSI Buy Signal");
         if(result)
           {
            dailyTradeCount++;
            Print("BUY opened successfully. Price: ", DoubleToString(ask, digits),
                  " SL: ", DoubleToString(sl, digits),
                  " TP: ", DoubleToString(tp, digits),
                  " Lot: ", DoubleToString(lot, 2),
                  " Trade #", dailyTradeCount, " today");
           }
         else
           {
            Print("ERROR: BUY order failed. Error: ", trade.ResultRetcode(),
                  " - ", trade.ResultRetcodeDescription());
           }
        }

      //--- EXIT: RSI > 70 => CLOSE all positions
      if(rsiCurrent > InpRSISellLevel && openPositions > 0)
        {
         CloseAllPositions("RSI Exit Signal");
         Print("EXIT triggered: RSI > ", InpRSISellLevel, ". All positions closed.");
        }

      //--- Check if last trade was a loss for consecutive loss tracking
      CheckConsecutiveLosses();

      //--- Sleep to prevent CPU overload
      Sleep(1000);
     }

   //--- Cleanup
   if(rsiHandle != INVALID_HANDLE)
      IndicatorRelease(rsiHandle);

   Print("Script stopped. All positions remain open (manual management required).");
  }

//+------------------------------------------------------------------+
//| Count open positions for this symbol and magic number             |
//+------------------------------------------------------------------+
int CountOpenPositions()
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
        {
         if(PositionGetString(POSITION_SYMBOL) == InpSymbol &&
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
           {
            count++;
           }
        }
     }
   return count;
  }

//+------------------------------------------------------------------+
//| Close all positions for this symbol and magic number              |
//+------------------------------------------------------------------+
void CloseAllPositions(string reason)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
        {
         if(PositionGetString(POSITION_SYMBOL) == InpSymbol &&
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
           {
            trade.PositionClose(ticket);
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Manage trailing stop on open positions                             |
//+------------------------------------------------------------------+
void ManageTrailingStop()
  {
   if(InpTrailingStopPoints <= 0)
      return;

   double point = SymbolInfoDouble(InpSymbol, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(InpSymbol, SYMBOL_DIGITS);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != InpSymbol ||
         PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      double openPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL  = PositionGetDouble(POSITION_SL);
      double currentTP  = PositionGetDouble(POSITION_TP);
      long   posType    = PositionGetInteger(POSITION_TYPE);

      if(posType == POSITION_TYPE_BUY)
        {
         double bid = SymbolInfoDouble(InpSymbol, SYMBOL_BID);
         if(bid <= 0) continue;

         double newSL = NormalizeDouble(bid - InpTrailingStopPoints * point, digits);

         //--- Only move SL up, never down
         if(newSL > currentSL && newSL > openPrice)
           {
            if(newSL < bid)
              {
               trade.PositionModify(ticket, newSL, currentTP);
              }
           }
        }
      else if(posType == POSITION_TYPE_SELL)
        {
         double ask = SymbolInfoDouble(InpSymbol, SYMBOL_ASK);
         if(ask <= 0) continue;

         double newSL = NormalizeDouble(ask + InpTrailingStopPoints * point, digits);

         //--- Only move SL down, never up
         if((newSL < currentSL || currentSL == 0) && newSL < openPrice)
           {
            if(newSL > ask)
              {
               trade.PositionModify(ticket, newSL, currentTP);
              }
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Check and update consecutive loss count by examining trade history |
//+------------------------------------------------------------------+
void CheckConsecutiveLosses()
  {
   //--- Check the most recent closed position result
   static ulong lastCheckedTicket = 0;
   static int  lastDealsTotal    = 0;

   int currentDealsTotal = DealsTotal();
   if(currentDealsTotal == lastDealsTotal)
      return;

   //--- Look at the last deal
   ulong dealTicket = DealGetTicket(currentDealsTotal - 1);
   if(dealTicket == 0)
      return;

   if(DealGetString(deal_SYMBOL) == InpSymbol &&
      DealGetInteger(deal_MAGIC) == InpMagicNumber)
     {
      long dealEntry = DealGetInteger(deal_ENTRY);
      if(dealEntry == DEAL_ENTRY_OUT || dealEntry == DEAL_ENTRY_INOUT)
        {
         double profit = DealGetDouble(deal_PROFIT);
         double commission = DealGetDouble(deal_COMMISSION);
         double swap = DealGetDouble(deal_SWAP);
         double netResult = profit + commission + swap;

         if(netResult < 0)
           {
            consecutiveLossCount++;
            Print("Consecutive loss #", consecutiveLossCount,
                  " | Loss: ", DoubleToString(netResult, 2));
           }
         else
           {
            consecutiveLossCount = 0;
            Print("Trade closed with profit. Consecutive loss count reset.");
           }
        }
     }

   lastDealsTotal = currentDealsTotal;
  }
//+------------------------------------------------------------------+