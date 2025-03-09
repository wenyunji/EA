//+------------------------------------------------------------------+
//|                                         TripleStrategy_Fixed.mq5 |
//|                趋势跟踪均值回归多时间框架协同策略（修正编译错误版）|
//|                                     Copyright 2023, QuantEdge    |
//+------------------------------------------------------------------+

#property copyright "QuantEdge"
#property version   "3.1"  // 版本升级
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
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
double dynamicATRMultiplier;  // 动态ATR乘数
double dynamicRiskPerTrade;   // 动态风险比例

//+------------------------------------------------------------------+
//| 专家初始化函数                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // 初始化动态参数
   dynamicATRMultiplier = ATR_Multiplier;
   dynamicRiskPerTrade = RiskPerTrade;

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
      Alert("错误：入场周期必须小于趋势周期!");
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
   bool trendIsBullish = GetTrendDirection(); // 改为布尔值判断
   ENUM_ORDER_TYPE entrySignal = GetEntrySignal();

   // 管理仓位
   ManagePositions(trendIsBullish, entrySignal);

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
//| 新闻事件过滤器（临时禁用）                                      |
//+------------------------------------------------------------------+
bool IsHighImpactNews()
{
   //return CheckNewsImpact(); // 需要实现此函数
   return false; // 暂时禁用
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
      dynamicATRMultiplier = 2.0;
      dynamicRiskPerTrade = 1.5;
   }
   else // 震荡市场
   {
      dynamicATRMultiplier = 1.0;
      dynamicRiskPerTrade = 0.5;
   }
}

//+------------------------------------------------------------------+
//| 获取趋势方向（true=看涨，false=看跌）                           |
//+------------------------------------------------------------------+
bool GetTrendDirection()
{
   double fastEMA[1], slowEMA[1];
   CopyBuffer(emaFastHandle, 0, 0, 1, fastEMA);
   CopyBuffer(emaSlowHandle, 0, 0, 1, slowEMA);
   return fastEMA[0] > slowEMA[0];
}

//+------------------------------------------------------------------+
//| 获取入场信号                                                    |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE GetEntrySignal()
{
   double upperBand[1], lowerBand[1], rsiVal[1], close[1];
   CopyBuffer(bbHandle, 1, 0, 1, upperBand);
   CopyBuffer(bbHandle, 2, 0, 1, lowerBand);
   CopyBuffer(rsiHandle, 0, 0, 1, rsiVal);
   CopyClose(_Symbol, EntryPeriod, 0, 1, close);

   if(close[0] <= lowerBand[0] && rsiVal[0] < RSI_OverSold)
      return ORDER_TYPE_BUY;

   if(close[0] >= upperBand[0] && rsiVal[0] > RSI_OverBought)
      return ORDER_TYPE_SELL;

   return WRONG_VALUE;
}

//+------------------------------------------------------------------+
//| 管理仓位（使用布尔值判断趋势方向）                              |
//+------------------------------------------------------------------+
void ManagePositions(bool trendIsBullish, ENUM_ORDER_TYPE signal)
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
//| 开仓函数（使用动态参数）                                        |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| 增强版开仓函数                                                  |
//+------------------------------------------------------------------+
void OpenPosition(ENUM_ORDER_TYPE orderType)
{
   // 获取最新报价
   MqlTick lastTick;
   if(!SymbolInfoTick(_Symbol, lastTick)){
      Print("获取报价失败!");
      return;
   }

   // 获取ATR值
   double atr[1];
   if(CopyBuffer(atrHandle, 0, 0, 1, atr) != 1){
      Print("获取ATR值失败!");
      return;
   }

   // 计算止损价格
   double price, sl, tp=0;
   if(orderType == ORDER_TYPE_BUY){
      price = lastTick.ask;
      sl = lastTick.bid - atr[0] * dynamicATRMultiplier;
   } else {
      price = lastTick.bid;
      sl = lastTick.ask + atr[0] * dynamicATRMultiplier;
   }

   // 验证手数有效性
   if(lotSize < SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN)){
      PrintFormat("手数过小: %.6f < %.2f", lotSize, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN));
      return;
   }

   // 执行交易
   if(!trade.PositionOpen(_Symbol, orderType, lotSize, price, sl, tp)){
      Print("开仓失败! 错误代码:", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| 移动止损逻辑                                                    |
//+------------------------------------------------------------------+
void TrailingStop()
{
   if(!PositionSelect(_Symbol)) return;

   double newSl, atr[1];
   CopyBuffer(atrHandle, 0, 0, 1, atr);
   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

   if(posType == POSITION_TYPE_BUY)
   {
      newSl = SymbolInfoDouble(_Symbol, SYMBOL_BID) - atr[0] * dynamicATRMultiplier;
      if(newSl > PositionGetDouble(POSITION_SL))
         trade.PositionModify(_Symbol, newSl, PositionGetDouble(POSITION_TP));
   }
   else if(posType == POSITION_TYPE_SELL)
   {
      newSl = SymbolInfoDouble(_Symbol, SYMBOL_ASK) + atr[0] * dynamicATRMultiplier;
      if(newSl < PositionGetDouble(POSITION_SL) || PositionGetDouble(POSITION_SL) == 0)
         trade.PositionModify(_Symbol, newSl, PositionGetDouble(POSITION_TP));
   }
}

//+------------------------------------------------------------------+
//| 平仓所有仓位                                                    |
//+------------------------------------------------------------------+
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
//|风险控制模块 - 计算合理手数  增强版手数计算函数                                              |
//+------------------------------------------------------------------+
double CalculateLotSize()
{
   // 获取品种交易规则
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   // 计算风险金额
   double riskAmount = AccountInfoDouble(ACCOUNT_BALANCE) * dynamicRiskPerTrade / 100.0;
   
   // 获取ATR值和点值
   double atrVal[1], tickValue;
   CopyBuffer(atrHandle, 0, 0, 1, atrVal);
   tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   
   // 计算理论手数
   double riskLots = riskAmount / (atrVal[0] * dynamicATRMultiplier / _Point * tickValue);
   
   // 应用风控限制
   riskLots = fmax(riskLots, minLot); // 不低于最小手数
   riskLots = fmin(riskLots, maxLot); // 不超过最大手数
   
   // 按手数步长规范化
   riskLots = round(riskLots / lotStep) * lotStep;
   
   // 调试输出
   PrintFormat("手数计算 | 理论值:%.6f 最小:%.2f 步长:%.2f 最终值:%.2f",
               riskLots, minLot, lotStep, riskLots);
               
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
//| 辅助函数 - 平指定类型仓位                                       |
//+------------------------------------------------------------------+
void ClosePositions(ENUM_ORDER_TYPE type)
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket>0 && 
         PositionGetString(POSITION_SYMBOL)==_Symbol &&
         PositionGetInteger(POSITION_MAGIC)==MagicNumber &&
         PositionGetInteger(POSITION_TYPE)==type)
      {
         trade.PositionClose(ticket);
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
   Print("当前浮动盈亏：", totalProfit, "，持仓数量：", totalTrades);
}
//+------------------------------------------------------------------+