//+------------------------------------------------------------------+
//|                                                  TripleStrategy.mq5 |
//| 趋势跟踪均值回归多时间框架协同策略 Combined Trend/MeanReversion/MultiTF EA|
//|                                     Copyright 2023, FXBlueRobot  |
//+------------------------------------------------------------------+

#property copyright "QuantEdge"
#property version   "3.0"
#property strict

#include <Trade\Trade.mql5>
#include <Math\Stat\Math.mqh>
CTrade trade;

//--- 输入参数
input double  RiskPerTrade         = 1.0;       // 每单风险比例 (%)
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
input double  ATR_Multiplier       = 1.5;       // ATR止损乘数
input ulong   MagicNumber          = 20230815;  // 魔术码
input bool    EnableTrailing       = true;      // 启用移动止损
input double  DailyLossLimit       = 3.0;       // 每日最大亏损 (%)
input int     MaxSlippage          = 10;        // 最大允许滑点 (点)
input bool    EnableNewsFilter     = true;      // 启用新闻过滤器
input bool    EnableLiquidityFilter= true;      // 启用流动性过滤器

//--- 全局变量
int    emaFastHandle, emaSlowHandle, bbHandle, rsiHandle, atrHandle, adxHandle;
double lotSize;
datetime lastTradeTime;
double dailyProfit;

//+------------------------------------------------------------------+
//| 专家初始化函数                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // 初始化指标句柄
   emaFastHandle = iMA(_Symbol, TrendPeriod, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   emaSlowHandle = iMA(_Symbol, TrendPeriod, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   bbHandle = iBands(_Symbol, EntryPeriod, BB_Period, 0, BB_Deviation, PRICE_CLOSE);
   rsiHandle = iRSI(_Symbol, EntryPeriod, RSI_Period, PRICE_CLOSE);
   atrHandle = iATR(_Symbol, EntryPeriod, ATR_Period);
   adxHandle = iADX(_Symbol, EntryPeriod, 14);

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

   // 设置定时器
   EventSetTimer(60); // 每60秒更新一次指标
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| 核心交易逻辑                                                    |
//+------------------------------------------------------------------+
void OnTick()
{
   // 避免重复开仓
   if(TimeCurrent() == lastTradeTime) return;

   // 更新指标
   UpdateIndicators();

   // 风险管理
   lotSize = CalculateDynamicLotSize();
   CheckDailyLossLimit();

   // 信号过滤
   if((EnableNewsFilter && IsHighImpactNews()) || 
      (EnableLiquidityFilter && IsLowLiquidityTime())) return;

   // 动态调整策略参数
   AdjustStrategyParameters();

   // 获取信号
   bool trendDirection = GetTrendDirection();
   ENUM_ORDER_TYPE entrySignal = GetEntrySignal();

   // 管理仓位
   ManagePositions(trendDirection, entrySignal);

   // 移动止损
   if(EnableTrailing) TrailingStop();

   // 记录日志
   MonitorPerformance();

   lastTradeTime = TimeCurrent();
}

//+------------------------------------------------------------------+
//| 指标更新函数                                                    |
//+------------------------------------------------------------------+
void UpdateIndicators()
{
   double fastEMA[1], slowEMA[1], upperBand[1], lowerBand[1], rsiVal[1], atrVal[1], adxVal[1];
   CopyBuffer(emaFastHandle, 0, 0, 1, fastEMA);
   CopyBuffer(emaSlowHandle, 0, 0, 1, slowEMA);
   CopyBuffer(bbHandle, 1, 0, 1, upperBand);
   CopyBuffer(bbHandle, 2, 0, 1, lowerBand);
   CopyBuffer(rsiHandle, 0, 0, 1, rsiVal);
   CopyBuffer(atrHandle, 0, 0, 1, atrVal);
   CopyBuffer(adxHandle, 0, 0, 1, adxVal);
}

//+------------------------------------------------------------------+
//| 动态风险调整                                                    |
//+------------------------------------------------------------------+
double CalculateDynamicLotSize()
{
   double atrVal[1];
   CopyBuffer(atrHandle, 0, 0, 1, atrVal);

   // 波动率越大，风险暴露越小
   double riskFactor = 1.0 / (1.0 + atrVal[0] / SymbolInfoDouble(_Symbol, SYMBOL_POINT));
   return CalculateLotSize() * riskFactor;
}

//+------------------------------------------------------------------+
//| 每日亏损熔断                                                    |
//+------------------------------------------------------------------+
void CheckDailyLossLimit()
{
   if(dailyProfit <= -DailyLossLimit)
   {
      CloseAllPositions();
      ExpertRemove(); // 停止EA运行
   }
}

//+------------------------------------------------------------------+
//| 新闻事件过滤器                                                  |
//+------------------------------------------------------------------+
bool IsHighImpactNews()
{
   // 使用经济日历API或外部数据源
   // 示例：假设有一个函数CheckNewsImpact()返回true表示有高影响新闻
   return CheckNewsImpact();
}

//+------------------------------------------------------------------+
//| 流动性过滤器                                                    |
//+------------------------------------------------------------------+
bool IsLowLiquidityTime()
{
   MqlDateTime timeNow;
   TimeCurrent(timeNow);

   // 亚洲早盘（02:00-05:00 GMT）
   if(timeNow.hour >= 2 && timeNow.hour < 5)
      return true;

   return false;
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
      ATR_Multiplier = 2.0; // 放宽止损
      RiskPerTrade = 1.5;   // 增加风险暴露
   }
   else // 震荡市场
   {
      ATR_Multiplier = 1.0; // 收紧止损
      RiskPerTrade = 0.5;   // 减少风险暴露
   }
}

//+------------------------------------------------------------------+
//| 获取趋势方向（大周期）                                          |
//+------------------------------------------------------------------+
bool GetTrendDirection()
{
   double fastEMA[1], slowEMA[1];
   CopyBuffer(emaFastHandle, 0, 0, 1, fastEMA);
   CopyBuffer(emaSlowHandle, 0, 0, 1, slowEMA);
   return fastEMA[0] > slowEMA[0];
}

//+------------------------------------------------------------------+
//| 获取入场信号（小周期均值回归）                                  |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE GetEntrySignal()
{
   double upperBand[1], lowerBand[1], rsiVal[1], close[1];
   CopyBuffer(bbHandle, 1, 0, 1, upperBand);  // Upper band
   CopyBuffer(bbHandle, 2, 0, 1, lowerBand);  // Lower band
   CopyBuffer(rsiHandle, 0, 0, 1, rsiVal);
   CopyClose(_Symbol, EntryPeriod, 0, 1, close);

   if(close[0] <= lowerBand[0] && rsiVal[0] < RSI_OverSold)
      return ORDER_TYPE_BUY;

   if(close[0] >= upperBand[0] && rsiVal[0] > RSI_OverBought)
      return ORDER_TYPE_SELL;

   return WRONG_VALUE;
}

//+------------------------------------------------------------------+
//| 管理仓位                                                        |
//+------------------------------------------------------------------+
void ManagePositions(bool trendDir, ENUM_ORDER_TYPE signal)
{
   if(trendDir == DIRECTION_BUY && signal == ORDER_TYPE_BUY)
   {
      ClosePositions(ORDER_TYPE_SELL);
      if(!PositionExists(ORDER_TYPE_BUY)) OpenPosition(ORDER_TYPE_BUY);
   }
   else if(trendDir == DIRECTION_SELL && signal == ORDER_TYPE_SELL)
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
   double atr[1], price, sl, tp=0;
   MqlTick lastTick;
   SymbolInfoTick(_Symbol, lastTick);

   CopyBuffer(atrHandle, 0, 0, 1, atr);

   if(orderType == ORDER_TYPE_BUY)
   {
      price = lastTick.ask;
      sl = lastTick.bid - atr[0] * ATR_Multiplier;
   }
   else
   {
      price = lastTick.bid;
      sl = lastTick.ask + atr[0] * ATR_Multiplier;
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
//| 风险控制模块 - 计算合理手数                                     |
//+------------------------------------------------------------------+
double CalculateLotSize()
{
   double riskAmount = AccountInfoDouble(ACCOUNT_BALANCE) * RiskPerTrade / 100.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double atrVal[1];

   CopyBuffer(atrHandle, 0, 0, 1, atrVal);
   double riskLots = riskAmount / (atrVal[0] * ATR_Multiplier / _Point * tickValue);

   return NormalizeDouble(riskLots, 2);
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