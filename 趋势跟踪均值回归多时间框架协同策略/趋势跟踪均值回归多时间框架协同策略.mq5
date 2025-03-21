//+------------------------------------------------------------------+
//|                                                  TripleStrategy.mq5 |
//| 趋势跟踪均值回归多时间框架协同策略 Combined Trend/MeanReversion/MultiTF EA|
//|                                     Copyright 2023, FXBlueRobot  |
//+------------------------------------------------------------------+

#property copyright "QuantEdge"
#property version   "3.1"
#property strict

#include <Trade\Trade.mqh>  
#include <Trade\PositionInfo.mqh> 
#include <Math\Stat\Math.mqh>  

CTrade trade;

//--- 输入参数
input double  RiskPerTrade         = 0.5;       // 每单风险比例 (%)
input ENUM_TIMEFRAMES TrendPeriod  = PERIOD_D1; // 趋势周期
input ENUM_TIMEFRAMES EntryPeriod  = PERIOD_H1; // 入场周期
input int     EMA_Fast             = 50;        // 快线EMA周期
input int     EMA_Slow             = 200;       // 慢线EMA周期
input int     BB_Period            = 20;        // 布林带周期
input double  BB_Deviation         = 2.0;       // 布林带标准差
input int     RSI_Period           = 14;        // RSI周期
input int     RSI_OverSold         = 30;        // 超卖阈值
input int     RSI_OverBought       = 70;        // 超买阈值
input int     ATR_Period           = 14;        // ATR周期
input double  ATR_Multiplier       = 3;       // ATR止损乘数
input ulong   MagicNumber          = 20230815;  // 魔术码
input bool    EnableTrailing       = true;      // 启用移动止损
input double  DailyLossLimit       = 3.0;       // 每日最大亏损 (%)
input int     MaxSlippage          = 10;        // 最大允许滑点 (点)
input bool    EnableNewsFilter     = true;      // 启用新闻过滤器
input bool    EnableLiquidityFilter= true;      // 启用流动性过滤器
double dynamicATRMultiplier = ATR_Multiplier; // 动态ATR乘数
double dynamicRiskPerTrade = RiskPerTrade;    // 动态风险比例

//--- 全局变量
int    emaFastHandle, emaSlowHandle, bbHandle, rsiHandle, atrHandle, adxHandle;
double lotSize;
datetime lastTradeTime;
double dailyBalance;

//+------------------------------------------------------------------+
//| 专家初始化函数                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // 初始化指标句柄
   dynamicATRMultiplier = ATR_Multiplier;
   dynamicRiskPerTrade = RiskPerTrade;
   emaFastHandle = iMA(_Symbol, TrendPeriod, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   emaSlowHandle = iMA(_Symbol, TrendPeriod, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   bbHandle = iBands(_Symbol, EntryPeriod, BB_Period, 0, BB_Deviation, PRICE_CLOSE);
   rsiHandle = iRSI(_Symbol, EntryPeriod, RSI_Period, PRICE_CLOSE);
   atrHandle = iATR(_Symbol, EntryPeriod, ATR_Period);
   adxHandle = iADX(_Symbol, EntryPeriod, 14);

   // 添加指标到图表
   ChartIndicatorAdd(0, 0, emaFastHandle);
   ChartIndicatorAdd(0, 0, bbHandle);

   // 设置交易对象参数
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetMarginMode();
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(MaxSlippage);

   // 验证时间框架组合
   if(PeriodSeconds(EntryPeriod) >= PeriodSeconds(TrendPeriod))
   {
      Alert("入场周期必须小于趋势周期!");
      return(INIT_FAILED);
   }
Print(StringFormat("品种验证：点值=%.5f 最小手数=%.2f 手数步长=%.2f 报价精度=%d",
                  SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS),
                  SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN),
                  SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP),
                  (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
   // 初始化每日余额
   dailyBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   EventSetTimer(60);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| 核心交易逻辑                                                    |
//+------------------------------------------------------------------+
void OnTick()
{
   if(TimeCurrent() == lastTradeTime) return;

   UpdateIndicators();
   lotSize = CalculateDynamicLotSize();
   CheckDailyLossLimit();

   if((EnableNewsFilter && IsHighImpactNews()) || 
      (EnableLiquidityFilter && IsLowLiquidityTime())) return;

   AdjustStrategyParameters();

   bool trendDirection = GetTrendDirection();
   ENUM_ORDER_TYPE entrySignal = GetEntrySignal();

   ManagePositions(trendDirection, entrySignal);
   if(EnableTrailing) TrailingStop();
   MonitorPerformance();

   lastTradeTime = TimeCurrent();
}

//+------------------------------------------------------------------+
//| 指标更新函数                                                    |
//+------------------------------------------------------------------+
void UpdateIndicators()
{
   double dummy[1];
   CopyBuffer(emaFastHandle, 0, 0, 1, dummy);
   CopyBuffer(emaSlowHandle, 0, 0, 1, dummy);
   CopyBuffer(bbHandle, 1, 0, 1, dummy);
   CopyBuffer(bbHandle, 2, 0, 1, dummy);
   CopyBuffer(rsiHandle, 0, 0, 1, dummy);
   CopyBuffer(atrHandle, 0, 0, 1, dummy);
   CopyBuffer(adxHandle, 0, 0, 1, dummy);
}

//+------------------------------------------------------------------+
//| 获取趋势方向（大周期）                                          |
//+------------------------------------------------------------------+
bool GetTrendDirection()
{
   double fastEMA[3], slowEMA[3];
   CopyBuffer(emaFastHandle, 0, 0, 3, fastEMA);
   CopyBuffer(emaSlowHandle, 0, 0, 3, slowEMA);
   return (fastEMA[0] > slowEMA[0]) && (fastEMA[1] > slowEMA[1]);
}

//+------------------------------------------------------------------+
//| 获取入场信号（增强版）                                          |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE GetEntrySignal()
{
   double upperBand[1], lowerBand[1], rsiVal[1], close[1], closePrices[3];
   
   CopyBuffer(bbHandle, 1, 0, 1, upperBand);
   CopyBuffer(bbHandle, 2, 0, 1, lowerBand);
   CopyBuffer(rsiHandle, 0, 0, 1, rsiVal);
   CopyClose(_Symbol, EntryPeriod, 0, 1, close);
   CopyClose(_Symbol, EntryPeriod, 0, 3, closePrices);

   // 多头信号：价格触及布林下轨且RSI超卖，同时出现价格回升
   if(close[0] <= lowerBand[0] && rsiVal[0] < RSI_OverSold && closePrices[0] > closePrices[1])
      return ORDER_TYPE_BUY;

   // 空头信号：价格触及布林上轨且RSI超买，同时出现价格回落
   if(close[0] >= upperBand[0] && rsiVal[0] > RSI_OverBought && closePrices[0] < closePrices[1])
      return ORDER_TYPE_SELL;

   return WRONG_VALUE;
}

//+------------------------------------------------------------------+
//| 风险管理模块                                                    |
//+------------------------------------------------------------------+
double CalculateDynamicLotSize()
{
   double atrVal[1];
   CopyBuffer(atrHandle, 0, 0, 1, atrVal);
   
   double riskFactor = 1.0 / (1.0 + atrVal[0]/SymbolInfoDouble(_Symbol,SYMBOL_POINT));
   double riskAmount = AccountInfoDouble(ACCOUNT_BALANCE)*dynamicRiskPerTrade/100.0;
   double tickValue = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   
   double riskLots = riskAmount/(atrVal[0]*dynamicATRMultiplier/_Point*tickValue)*riskFactor;
   riskLots = NormalizeDouble(riskLots,2);

   Print("手数计算：ATR=",atrVal[0]," 乘数=",dynamicATRMultiplier," 风险=",riskAmount," 手数=",riskLots);
   return riskLots;
}


void CloseAllPositions()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket>0 && 
         PositionGetString(POSITION_SYMBOL)==_Symbol &&
         PositionGetInteger(POSITION_MAGIC)==MagicNumber)
      {
         trade.PositionClose(ticket);
      }
   }
}

//+------------------------------------------------------------------+
//| 每日亏损熔断                                                    |
//+------------------------------------------------------------------+
void CheckDailyLossLimit()
{
   double currentProfit = AccountInfoDouble(ACCOUNT_PROFIT);
   if(currentProfit <= -DailyLossLimit)
   {
      Print("触发日亏损熔断：", currentProfit);
      CloseAllPositions();
      ExpertRemove();
   }
}

//+------------------------------------------------------------------+
//| 新闻事件过滤器                                                  |
//+------------------------------------------------------------------+
bool IsHighImpactNews()
{
   //return CheckNewsImpact(); // 暂时注释未实现的功能
   return false; // 暂时禁用新闻过滤器
}

//+------------------------------------------------------------------+
//| 流动性过滤器                                                    |
//+------------------------------------------------------------------+
bool IsLowLiquidityTime()
{
   MqlDateTime timeNow;
   TimeCurrent(timeNow);
   Print("当前时间：", timeNow.hour, ":", timeNow.min); // 添加调试输出
   return (timeNow.hour >= 2 && timeNow.hour < 5);
}

//+------------------------------------------------------------------+
//| 动态调整策略参数                                                |
//+------------------------------------------------------------------+
void AdjustStrategyParameters()
{
   double adxVal[1];
   CopyBuffer(adxHandle, 0, 0, 1, adxVal);

   if(adxVal[0] > 25) // 趋势市场
   {
      dynamicATRMultiplier = 2.0; // 使用动态变量
      dynamicRiskPerTrade = 1.5;  
   }
   else // 震荡市场
   {
      dynamicATRMultiplier = 1.0;
      dynamicRiskPerTrade = 0.5;  
   }
}


//+------------------------------------------------------------------+
//| 管理仓位                                                        |
//+------------------------------------------------------------------+
void ManagePositions(bool trendIsBullish, ENUM_ORDER_TYPE signal) // 使用布尔值判断趋势
{
   if(trendIsBullish && signal == ORDER_TYPE_BUY)
   {
      ClosePositions(ORDER_TYPE_SELL);
      if(!PositionExists(ORDER_TYPE_BUY)) OpenPosition(ORDER_TYPE_BUY);
   }
   else if(!trendIsBullish && signal == ORDER_TYPE_SELL)
   {
      ClosePositions(ORDER_TYPE_BUY);
      if(!PositionExists(ORDER_TYPE_SELL)) OpenPosition(ORDER_TYPE_SELL);
   }
}

//+------------------------------------------------------------------+
//| 开仓函数                                                        |
//+------------------------------------------------------------------+
void OpenPosition(ENUM_ORDER_TYPE orderType)
{
   if(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE) != SYMBOL_TRADE_MODE_FULL)
   {
      Print("交易被禁止：", GetLastError());
      return;
   }
   double atr[1], price, sl, tp=0;
   MqlTick lastTick;
   SymbolInfoTick(_Symbol, lastTick);

   CopyBuffer(atrHandle, 0, 0, 1, atr);

   if(orderType == ORDER_TYPE_BUY)
   {
      price = lastTick.ask;
      sl = lastTick.bid - atr[0] * dynamicATRMultiplier; // 使用动态变量
   }
   else
   {
      price = lastTick.bid;
      sl = lastTick.ask + atr[0] * dynamicATRMultiplier; // 使用动态变量
   }

   trade.PositionOpen(_Symbol, orderType, lotSize, price, sl, tp);
}

//+------------------------------------------------------------------+
//| 移动止损逻辑                                                     |
//+------------------------------------------------------------------+
void TrailingStop()
{
   if(!PositionSelect(_Symbol)) return;

   double newSl, atr[1];
   CopyBuffer(atrHandle, 0, 0, 1, atr);
   ulong posType = PositionGetInteger(POSITION_TYPE);

   if(posType == POSITION_TYPE_BUY)
   {
      newSl = SymbolInfoDouble(_Symbol, SYMBOL_BID) - atr[0] * ATR_Multiplier;
      if(newSl > PositionGetDouble(POSITION_SL))
         trade.PositionModify(_Symbol, newSl, PositionGetDouble(POSITION_TP));
   }
   else if(posType == POSITION_TYPE_SELL)
   {
      newSl = SymbolInfoDouble(_Symbol, SYMBOL_ASK) + atr[0] * ATR_Multiplier;
      if(newSl < PositionGetDouble(POSITION_SL) || PositionGetDouble(POSITION_SL) == 0)
         trade.PositionModify(_Symbol, newSl, PositionGetDouble(POSITION_TP));
   }
}

//+------------------------------------------------------------------+
//| 风险控制模块 - 最终黄金手数计算                                 |
//+------------------------------------------------------------------+
double CalculateLotSize()
{
   // 获取交易品种属性
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   // 获取ATR值
   double atrVal[1];
   if(!CopyBuffer(atrHandle, 0, 0, 1, atrVal) || atrVal[0] == 0)
      return minLot;

   // 计算关键参数（MQL5标准方式）
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS) 
                    * MathPow(10, digits-2); // 适应不同报价精度
   double riskAmount = AccountInfoDouble(ACCOUNT_BALANCE) * dynamicRiskPerTrade / 100.0;
   double stopLossPoints = (atrVal[0] * dynamicATRMultiplier) / point;

   // 手数核心计算公式
   double riskLots = 0.0;
   if(stopLossPoints > 0 && tickValue > 0)
      riskLots = riskAmount / (stopLossPoints * tickValue);

   // 规范化处理
   riskLots = MathMax(riskLots, minLot);
   riskLots = NormalizeDouble(riskLots, 2);
   
   // 精确阶梯化处理
   double stepAdjusted = floor(riskLots / lotStep) * lotStep;
   double finalLot = NormalizeDouble(stepAdjusted, 2);

   // 强制最低手数保护
   if(finalLot < minLot) finalLot = minLot;

   Print(StringFormat("最终计算：ATR=%.2f 止损点=%.1f 点值=%.5f 风险$=%.2f => 手数=%.2f",
                     atrVal[0], stopLossPoints, tickValue, riskAmount, finalLot));
   
   return finalLot;
}
  

//+------------------------------------------------------------------+
//| 辅助函数 - 检查持仓                                             |
//+------------------------------------------------------------------+
bool PositionExists(ENUM_ORDER_TYPE type)
{
   return PositionSelect(_Symbol) && 
          PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
          PositionGetInteger(POSITION_TYPE) == type;
}

//+------------------------------------------------------------------+
//| 辅助函数 - 平仓                                                 |
//+------------------------------------------------------------------+
void ClosePositions(ENUM_ORDER_TYPE type)
{
   for(int i=0; i<PositionsTotal(); i++)
   {
      if(PositionGetTicket(i) && 
         PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
         PositionGetInteger(POSITION_TYPE) == type)
      {
         trade.PositionClose(PositionGetInteger(POSITION_TICKET));
      }
   }
}

//+------------------------------------------------------------------+
//| 日志记录与监控                                                  |
//+------------------------------------------------------------------+
void MonitorPerformance()
{
   double totalProfit = AccountInfoDouble(ACCOUNT_PROFIT);
   int totalTrades = PositionsTotal();

   Print("Total Profit: ", totalProfit, ", Total Trades: ", totalTrades);
}
//+------------------------------------------------------------------+