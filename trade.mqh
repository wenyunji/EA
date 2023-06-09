//+------------------------------------------------------------------+
//|                                                        trade.mq5 |
//|                                  Copyright 2023, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2023, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.00"

//+------------------------------------------------------------------+
//| include                                                          |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| 全局变量                                                          |
//+------------------------------------------------------------------+
enum SIGNAL_MODE
  {
   EXIT_CROSS_NORMAL,
   ENTRY_CROSS_NORMAL,
   EXIT_CROSS_REVERSED,
   ENTRY_CROSS_REVERSED,
  };
int handle;
double bufferMain[];
MqlTick cT;
CTrade trade;

//+------------------------------------------------------------------+
//| inputs                                                           |
//+------------------------------------------------------------------+
input group "==== 普通参数 ====="
static input long InpMagicNumber = 567893;             // 幻数
input double InpLotSize = 0.01;                        // 下单量

input group "==== 交易参数 ====="
input SIGNAL_MODE   InpSignalMode = EXIT_CROSS_NORMAL; //信号模式
input int           InpStopLoss = 200;                 // 止损
input int           InpTakeProfit = 0;                 // 止赢
input bool          InpCloseSignal = false;            // 通过相反的信号关闭交易

input group "==== 随机参数 ====="
input int           InpKPeriod = 21;                   // 周期
input int           InpUpperLevel = 80;                // 上限

input group "==== clear bars filter ====="
input bool          InpClearBarsReversed = false;      //反向透明条过滤器
input int           InpClearBars = 0;                  //clear bars

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
//检查输入参数
   if(!CheckInputs())
     {
      return INIT_PARAMETERS_INCORRECT;
     }

//设置幻数
   trade.SetExpertMagicNumber(InpMagicNumber);
//创建指标
   handle = iStochastic(_Symbol, PERIOD_CURRENT, InpKPeriod, 1, 3, MODE_SMA, STO_LOWHIGH);
   if(handle == INVALID_HANDLE)
     {
      Alert("创建指标失败！");
      return INIT_FAILED;
     }

   ArraySetAsSeries(bufferMain, true);

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(handle != INVALID_HANDLE)
     {
      IndicatorRelease(handle);
     }
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(!IsNewBar())
     {
      return;
     }

   if(!SymbolInfoTick(_Symbol, cT))
     {
      Print("警告：to get current symbol tick");
      return;
     }

   if(CopyBuffer(handle, 0, 0, 3 + InpClearBars, bufferMain) != (3 + InpClearBars))
     {
      Print("警告：to get indicator values");
      return;
     }



   int cntBuy, cntSell;
   if(!CountOpenPositions(cntBuy, cntSell))
     {
      Print("警告：to count open positions");
      return;
     }

   if(CheckSignal(true, cntBuy) && CheckClearBars(true))
     {
      Print("open buy positions");

      if(InpCloseSignal)
        {
         if(!ClosePositions(2))
           {
            return;
           }

        }
      double sl = InpStopLoss == 0 ? 0 : cT.bid + InpStopLoss * _Point;
      double tp = InpTakeProfit == 0 ? 0 : cT.bid - InpTakeProfit * _Point;
      if(!NormalizePrice(sl))
        {
         return;
        }
      if(!NormalizePrice(tp))
        {
         return;
        }
      trade.PositionOpen(_Symbol, ORDER_TYPE_BUY, InpLotSize, cT.ask, sl, tp, "SMA EA");
     }

   if(CheckSignal(false, cntSell) && CheckClearBars(false))
     {
      Print("open sell positions");

      if(InpCloseSignal)
        {
         if(!ClosePositions(1))
           {
            return;
           }

        }
      double sl = InpStopLoss == 0 ? 0 : cT.ask - InpStopLoss * _Point;
      double tp = InpTakeProfit == 0 ? 0 : cT.ask + InpTakeProfit * _Point;
      if(!NormalizePrice(sl))
        {
         return;
        }
      if(!NormalizePrice(tp))
        {
         return;
        }
      trade.PositionOpen(_Symbol, ORDER_TYPE_SELL, InpLotSize, cT.bid, sl, tp, "SMA EA");
     }

  }


//+------------------------------------------------------------------+
//|  检查输入参数                                                         |
//+------------------------------------------------------------------+
bool CheckInputs()
  {
   if(InpMagicNumber <= 0)
     {
      Alert("警告：InpMagicNumber <=0 ");
      return false;
     }
   if(InpLotSize <= 0 || InpLotSize > 10)
     {
      Alert("警告：InpLotSize <=0 或 > 10 ");
      return false;
     }
   if(InpStopLoss < 0)
     {
      Alert("警告：InpStopLoss <0 ");
      return false;
     }
   if(InpTakeProfit < 0)
     {
      Alert("警告：InpTakeProfit <0 ");
      return false;
     }
   if(!InpCloseSignal && InpStopLoss == 0)
     {
      Alert("警告：!InpCloseSignal && InpStopLoss == 0");
      return false;
     }

   if(InpKPeriod <= 0)
     {
      Alert("警告：InpKPeriod<=0");
      return false;
     }
   if(InpUpperLevel <= 50 || InpUpperLevel >= 100)
     {
      Alert("警告：InpUpperLevel <= 50||InpUpperLevel>=100");
      return false;
     }
   if(InpClearBars < 0)
     {
      Alert("警告：Clear Bars < 0");
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| check if we have a bar open tick  查一下我们有没有酒吧开着                                                              |
//+------------------------------------------------------------------+
bool IsNewBar()
  {
   static datetime previousTime = 0;
   datetime currentTme = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(previousTime != currentTme)
     {
      previousTime = currentTme;
      return true;
     }
   return false;
  }


//+------------------------------------------------------------------+
//|  count open positions                                                                |
//+------------------------------------------------------------------+
bool CountOpenPositions(int &cntBuy, int &cntSell)
  {
   cntBuy = 0;
   cntSell = 0;
   int total = PositionsTotal();
   for(int  i = total - 1 ; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0)
        {
         Print("警告： position ticket");
         return false;
        }
      if(!PositionSelectByTicket(ticket))
        {
         Print("警告：Select position");
         return false;
        }
      long magic;
      if(!PositionGetInteger(POSITION_MAGIC, magic))
        {
         Print("警告：get position magic");
         return false;
        }
      if(magic == InpMagicNumber)
        {
         long type;
         if(!PositionGetInteger(POSITION_TYPE, type))
           {
            Print("警告：get position type");
            return false;
           }
         if(type == POSITION_TYPE_BUY)
           {
            cntBuy++;
           }
         if(type == POSITION_TYPE_SELL)
           {
            cntSell++;
           }
        }
     }
   return true;
  }
//+------------------------------------------------------------------+



//+------------------------------------------------------------------+
//|   Normaliz PRICE                                                 |
//+------------------------------------------------------------------+
bool NormalizePrice(double &price)
  {
   double tickSize = 0;
   if(!SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE, tickSize))
     {
      Print("警告：get tick size");
      return false;
     }

   price = NormalizeDouble(MathRound(price / tickSize) * tickSize, _Digits);
   return true;
  }
//+------------------------------------------------------------------+


//+------------------------------------------------------------------+
//|    close position                                                              |
//+------------------------------------------------------------------+
bool ClosePositions(int all_buy_sell)
  {
   int total = PositionsTotal();
   for(int i = total - 1; i  >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0)
        {
         Print("警告： position ticket");
         return false;
        }
      if(!PositionSelectByTicket(ticket))
        {
         Print("警告：Select position");
         return false;
        }
      long magic;
      if(!PositionGetInteger(POSITION_MAGIC, magic))
        {
         Print("警告：get position magic");
         return false;
        }
      if(magic == InpMagicNumber)
        {
         long type;
         if(!PositionGetInteger(POSITION_TYPE, type))
           {
            Print("警告：get position type");
            return false;
           }
         if(all_buy_sell == 1 && type == POSITION_TYPE_SELL)
           {
            continue;
           }
         if(all_buy_sell == 2 && type == POSITION_TYPE_BUY)
           {
            continue;
           }
         trade.PositionClose(ticket);
         if(trade.ResultRetcode() != TRADE_RETCODE_DONE)
           {
            Print("警告：to close position ticket:",
                  (string)ticket, "result:", (string)trade.ResultRetcode(), ":", trade.CheckResultRetcodeDescription());
           }

        }

     }
   return true;
  }


//+------------------------------------------------------------------+
//|  检查新的信号                                                                |
//+------------------------------------------------------------------+
bool CheckSignal(bool buy_sell, int cntBuySell)
  {

   if(cntBuySell > 0)
     {
      return false;
     }

   int lowerlevel = 100 - InpUpperLevel;
   bool upperExitCross = bufferMain[0] >= InpUpperLevel && bufferMain[1] < InpUpperLevel;
   bool upperEentryCross = bufferMain[0] <= InpUpperLevel && bufferMain[1] > InpUpperLevel;
   bool lowerExitCross = bufferMain[0] <= InpUpperLevel && bufferMain[1] > lowerlevel;
   bool lowerEentryCross = bufferMain[0] >= InpUpperLevel && bufferMain[1] < lowerlevel;

   switch(InpSignalMode)
     {
      case EXIT_CROSS_NORMAL:
         return ((buy_sell && lowerExitCross) || (!buy_sell && upperExitCross));
         break;
      case ENTRY_CROSS_NORMAL:
         return ((buy_sell && lowerEentryCross) || (!buy_sell && upperEentryCross));
         break;
      case EXIT_CROSS_REVERSED:
         return ((buy_sell && upperExitCross) || (!buy_sell && lowerExitCross));
         break;
      case ENTRY_CROSS_REVERSED:
         return ((buy_sell && upperEentryCross) || (!buy_sell && lowerEentryCross));
         break;
     }
   return false;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool CheckClearBars(bool buy_sell)
  {

   if(InpClearBars == 0)
     {
      return true;
     }

   bool checkLower = ((buy_sell && (InpSignalMode == EXIT_CROSS_NORMAL || InpSignalMode == ENTRY_CROSS_NORMAL))
                      || (!buy_sell && (InpSignalMode == EXIT_CROSS_REVERSED || InpSignalMode == ENTRY_CROSS_REVERSED)));

   for(int i = 3; i < (3 + InpClearBars); i++)
     {
      if(!checkLower && ((bufferMain[i - 1] > InpUpperLevel && bufferMain[i] <= InpUpperLevel)
                         || (bufferMain[i - 1] < InpUpperLevel && bufferMain[i] >= InpUpperLevel)))
        {
         if(InpClearBarsReversed)
           {
            return true;
           }
         else
           {
            Print("clear bars filter prevented", buy_sell ? "buy" : "sell", "siganal cross of upper level at index", (i - 1), "->", i);
            return false;
           }
        }

      if(checkLower && ((bufferMain[i - 1] < (100 - InpUpperLevel) && bufferMain[i] >= (100 - InpUpperLevel))
                        || (bufferMain[i - 1] > (100 - InpUpperLevel) && bufferMain[i] <= (100 - InpUpperLevel))))
        {
         if(InpClearBarsReversed)
           {
            return true;
           }
         else
           {
            Print("clear bars filter prevented", buy_sell ? "buy" : "sell", "siganal cross of lower level at index", (i - 1), "->", i);
            return false;
           }
        }

     }


   return false;
  }
