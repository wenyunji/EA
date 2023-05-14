//+------------------------------------------------------------------+
//|                                                 图形图象检测.mq5 |
//|                                  Copyright 2023, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2023, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.00"


#include <Trade/Trade.mqh>

input bool isHammer = false; //是否使用锤子线
input bool isEngulfingr = false; //是否使用吞没形态
input bool isStar = false; //是否使用黄昏之星

input double Lots = 0.1;
input int TpPoints = 100;
input int SlPoints = 50;

CTrade trade;

int totalBars;


//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   totalBars = iBars(_Symbol, PERIOD_CURRENT);
   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {

  }
//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   int bars = iBars(_Symbol, PERIOD_CURRENT);
   if(bars > totalBars)
     {
      totalBars = bars;

      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      ask = NormalizeDouble(ask, _Digits);
      bid = NormalizeDouble(bid, _Digits);

      double tpBuy = ask + TpPoints * _Point;
      double slBuy = ask - SlPoints * _Point;
      tpBuy = NormalizeDouble(tpBuy, _Digits);
      slBuy = NormalizeDouble(slBuy, _Digits);

      double tpSell = NormalizeDouble(bid - TpPoints * _Point, _Digits);
      double slSell  = NormalizeDouble(bid + SlPoints * _Point, _Digits);


      if(isHammer)
        {
         int hammerSignal = getHammerSignal(0.05, 0.7);
         if(hammerSignal > 0)
           {
            Print(__FUNCTION__, "> New hammer buy signal...");
            trade.Buy(Lots, _Symbol, ask, slBuy, tpBuy, "锤子线");
           }
         else
            if(hammerSignal < 0)
              {
               Print(__FUNCTION__, "> New hammer sell signal...");
               trade.Sell(Lots, _Symbol, bid, slSell, tpSell, "锤子线");
              }
        }


      if(isEngulfingr)
        {
         int engulfingSignal =  getEngulfingSignal();
         if(engulfingSignal > 0)
           {
            Print(__FUNCTION__, "> New  engulfing buy signal...");
            trade.Buy(Lots, _Symbol, ask, slBuy, tpBuy, "吞没形态");
           }
         else
            if(engulfingSignal < 0)
              {
               Print(__FUNCTION__, "> New  engulfing sell signal...");
               trade.Sell(Lots, _Symbol, bid, slSell, tpSell, "吞没形态");
              }
        }


      if(isStar)
        {
         int starSignal =  getStarSignal(0.5);
         if(starSignal > 0)
           {
            Print(__FUNCTION__, "> New star buy signal...");
            trade.Buy(Lots, _Symbol, ask, slBuy, tpBuy, "黄昏之星");
           }
         else
            if(starSignal < 0)
              {
               Print(__FUNCTION__, "> New star sell signal...");
               trade.Sell(Lots, _Symbol, bid, slSell, tpSell, "黄昏之星");
              }
        }

     }
  }

//+------------------------------------------------------------------+
//| 黄昏之星                                                                |
//+------------------------------------------------------------------+
int getStarSignal(double maxMiddleCandleRation)
  {
   datetime  time = iTime(_Symbol, PERIOD_CURRENT, 1);
//第1根K线
   double high1 = iHigh(_Symbol, PERIOD_CURRENT, 1);
   double low1 = iLow(_Symbol, PERIOD_CURRENT, 1);
   double open1 = iOpen(_Symbol, PERIOD_CURRENT, 1);
   double close1 = iClose(_Symbol, PERIOD_CURRENT, 1);
//第2根K线
   double high2 = iHigh(_Symbol, PERIOD_CURRENT, 2);
   double low2 = iLow(_Symbol, PERIOD_CURRENT, 2);
   double open2 = iOpen(_Symbol, PERIOD_CURRENT, 2);
   double close2 = iClose(_Symbol, PERIOD_CURRENT, 2);
//第3根K线
   double high3 = iHigh(_Symbol, PERIOD_CURRENT, 3);
   double low3 = iLow(_Symbol, PERIOD_CURRENT, 3);
   double open3 = iOpen(_Symbol, PERIOD_CURRENT, 3);
   double close3 = iClose(_Symbol, PERIOD_CURRENT, 3);

   double size1 = high1 - low1;
   double size2 = high2 - low2;
   double size3 = high3 - low3;

   if(open1 < close1)
     {
      if(open3 > close3)
        {
         if(size2 < size1 * maxMiddleCandleRation && size2 < size3 * maxMiddleCandleRation)
           {
            createObj(time, low2, 200, 1, clrGreen, "晨星");
            return 1;
           }
        }
     }

   if(open1 > close1)
     {
      if(open3 < close3)
        {
         if(size2 < size1 * maxMiddleCandleRation && size2 < size3 * maxMiddleCandleRation)
           {
            createObj(time, high1, 201, 1, clrRed, "晚星");
            return -1;
           }
        }
     }
   return 0;
  }

//+------------------------------------------------------------------+
//|  吞没形态                                                                |
//+------------------------------------------------------------------+
int getEngulfingSignal()
  {
   datetime  time = iTime(_Symbol, PERIOD_CURRENT, 1);
//第1根K线
   double high1 = iHigh(_Symbol, PERIOD_CURRENT, 1);
   double low1 = iLow(_Symbol, PERIOD_CURRENT, 1);
   double open1 = iOpen(_Symbol, PERIOD_CURRENT, 1);
   double close1 = iClose(_Symbol, PERIOD_CURRENT, 1);
//第2根K线
   double high2 = iHigh(_Symbol, PERIOD_CURRENT, 2);
   double low2 = iLow(_Symbol, PERIOD_CURRENT, 2);
   double open2 = iOpen(_Symbol, PERIOD_CURRENT, 2);
   double close2 = iClose(_Symbol, PERIOD_CURRENT, 2);

//bullish engulfing formation
   if(open1 < close1)
     {
      if(open2 > close2)
        {
         if(high1 > high2 && low1 < low2)
           {
            if(close1 > open2 && open1 < close2)
              {
               createObj(time, low2, 217, 1, clrGreen, "吞没形态");
               return 1;
              }
           }
        }
     }

   if(open1 > close1)
     {
      if(open2 < close2)
        {
         if(high1 > high2 && low1 < low2)
           {
            if(close1 < open2 && open1 > close2)
              {
               createObj(time, high1, 218, -1, clrRed, "吞没形态");
               return -1;
              }
           }
        }
     }

   return 0;
  }

//+------------------------------------------------------------------+
//| 获得锤击信号                                                                 |
//+------------------------------------------------------------------+
int getHammerSignal(double maxRationShorShaow, double minRationLongShadow)
  {

   datetime  time = iTime(_Symbol, PERIOD_CURRENT, 1);
   double high = iHigh(_Symbol, PERIOD_CURRENT, 1);
   double low = iLow(_Symbol, PERIOD_CURRENT, 1);
   double open = iOpen(_Symbol, PERIOD_CURRENT, 1);
   double close = iClose(_Symbol, PERIOD_CURRENT, 1);

   double candleSize = high - low;

//green hammer buy formation
   if(open < close)
     {
      if(high - close < candleSize * maxRationShorShaow)
        {
         if(open - low > candleSize * minRationLongShadow)
           {
            createObj(time, low, 233, 1, clrGreen, "锤子线");
            return 1;
           }
        }
     }

//red hammer buy formation
   if(open > close)
     {
      if(high - open < candleSize * maxRationShorShaow)
        {
         if(close - low > candleSize * minRationLongShadow)
           {
            createObj(time, low, 233, 1, clrGreen, "锤子线");
            return 1;
           }
        }
     }

//green hammer sell formation
   if(open < close)
     {
      if(open - low < candleSize * maxRationShorShaow)
        {
         if(high - close > candleSize * minRationLongShadow)
           {
            createObj(time, high, 234, -1, clrRed, "锤子线");
            return -1;
           }
        }
     }

//red hammer sell formation
   if(close > open)
     {
      if(close - low < candleSize * maxRationShorShaow)
        {
         if(high - open > candleSize * minRationLongShadow)
           {
            createObj(time, high, 234, -1, clrRed, "锤子线");
            return -1;
           }
        }
     }

   return 0;
  }

//+------------------------------------------------------------------+
//| 创建箭头对象                                                                  |
//+------------------------------------------------------------------+
void createObj(datetime time, double price, int arrowCode, int direction, color clr, string txt)
  {
   string objName = "";
   StringConcatenate(objName, "Signal@", time, "at", DoubleToString(price, _Digits), "(", arrowCode, ")");
   if(ObjectCreate(0, objName, OBJ_ARROW, 0, time, price))
     {
      ObjectSetInteger(0, objName, OBJPROP_ARROWCODE, arrowCode);
      ObjectSetInteger(0, objName, OBJPROP_COLOR, clr);
      if(direction > 0)
        {
         ObjectSetInteger(0, objName, OBJPROP_ANCHOR, ANCHOR_TOP);
        }
      if(direction < 0)
        {
         ObjectSetInteger(0, objName, OBJPROP_ANCHOR, ANCHOR_BOTTOM);
        }
     }

   string objNameDesc = objName + txt;
   if(ObjectCreate(0, objNameDesc, OBJ_TEXT, 0, time, price))
     {
      ObjectSetString(0, objNameDesc, OBJPROP_TEXT, "  " + txt);
      ObjectSetInteger(0, objNameDesc, OBJPROP_COLOR, clr);
      if(direction > 0)
        {
         ObjectSetInteger(0, objNameDesc, OBJPROP_ANCHOR, ANCHOR_TOP);
        }
      if(direction < 0)
        {
         ObjectSetInteger(0, objNameDesc, OBJPROP_ANCHOR, ANCHOR_BOTTOM);
        }
     }

  }
//+------------------------------------------------------------------+
