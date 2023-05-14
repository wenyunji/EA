//+------------------------------------------------------------------+
//|                                                winningSystem.mq5 |
//|                                  Copyright 2023, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2023, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.00"

#include <Trade/Trade.mqh>

input double Lots = 0.01;
input double LotFactor = 2;
input int TpPoints = 100;
input int SlPoints = 100;
input int Magic = 111;

CTrade trade;
bool isTradeAllowed = true;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(Magic);
   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
//---

  }
//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(isTradeAllowed)
     {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double tp = ask + TpPoints * _Point;
      double sl = ask - SlPoints * _Point;

      ask = NormalizeDouble(ask, _Digits);
      tp == NormalizeDouble(tp, _Digits);
      sl == NormalizeDouble(sl, _Digits);

      if(trade.Buy(Lots, _Symbol, ask, sl, tp))
        {
         isTradeAllowed = false;
        }
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void  OnTradeTransaction(
   const MqlTradeTransaction&    trans,     // 交易事务结构
   const MqlTradeRequest&        request,   // 请求结构
   const MqlTradeResult&         result     // 回应结构
)
  {

   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
     {
      CDealInfo deal;
      deal.Ticket(trans.deal);
      HistorySelect(TimeCurrent() - PeriodSeconds(PERIOD_D1), TimeCurrent() + 10);
      if(deal.Magic() == Magic && deal.Symbol() == _Symbol)
        {

         if(deal.Entry() == DEAL_ENTRY_OUT)
           {
            Print(__FUNCTION__, "> closrd pos #", trans.position);
            if(deal.Profit() > 0)
              {
               isTradeAllowed = true;
              }
            else
              {
               if(deal.DealType() == DEAL_TYPE_BUY)
                 {
                  double Lots = deal.Volume() * LotFactor;
                  Lots = NormalizeDouble(Lots, 2);

                  double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
                  double tp = ask + TpPoints * _Point;
                  double sl = ask - SlPoints * _Point;

                  ask = NormalizeDouble(ask, _Digits);
                  tp == NormalizeDouble(tp, _Digits);
                  sl == NormalizeDouble(sl, _Digits);

                  trade.Buy(Lots, _Symbol, ask, sl, tp);
                 }
               else
                  if(deal.DealType() == DEAL_TYPE_SELL)
                    {
                     double Lots = deal.Volume() * LotFactor;
                     Lots = NormalizeDouble(Lots, 2);

                     double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
                     double tp = bid - TpPoints * _Point;
                     double sl = bid + SlPoints * _Point;

                     bid = NormalizeDouble(bid, _Digits);
                     tp == NormalizeDouble(tp, _Digits);
                     sl == NormalizeDouble(sl, _Digits);

                     trade.Sell(Lots, _Symbol, bid, sl, tp);
                    }
              }
           }
        }
     }
  }


//+------------------------------------------------------------------+
