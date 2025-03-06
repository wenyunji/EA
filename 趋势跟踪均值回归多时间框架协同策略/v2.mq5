//+------------------------------------------------------------------+
//|                                                  TripleStrategy.mq5 |
//| 趋势跟踪均值回归多时间框架协同策略 Combined Trend/MeanReversion/MultiTF EA|
//|                                     Copyright 2023, FXBlueRobot  |
//+------------------------------------------------------------------+

#property copyright "QuantEdge"
#property version   "3.1"  // 版本号升级
#property strict

#include <Trade\Trade.mql5>
#include <Math\Stat\Math.mqh>
CTrade trade;

//--- 输入参数
input double  RiskPerTrade         = 1.0;       // 基准风险比例 (%)
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
input double  ATR_Multiplier       = 1.5;       // 基准ATR乘数
input ulong   MagicNumber          = 20230815;  // 魔术码
input bool    EnableTrailing       = true;      // 启用移动止损
input double  DailyLossLimit       = 3.0;       // 每日最大亏损 (%)
input int     MaxSlippage          = 10;        // 最大允许滑点 (点)
input bool    EnableNewsFilter     = true;      // 启用新闻过滤器
input bool    EnableLiquidityFilter= true;      // 启用流动性过滤器

//--- 全局变量
int    emaFastHandle, emaSlowHandle, bbHandle, rsiHandle, atrHandle, adxHandle;
double lotSize, dynamic_ATR_Multiplier, dynamic_RiskPerTrade;
datetime lastTradeTime;
double dailyProfit;
double minLot, maxLot, lotStep; // 交易品种属性

//+------------------------------------------------------------------+
//| 专家初始化函数                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // 获取交易品种属性
   minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   // 初始化指标句柄（带错误检查）
   if((emaFastHandle = iMA(_Symbol,TrendPeriod,EMA_Fast,0,MODE_EMA,PRICE_CLOSE)) == INVALID_HANDLE ||
      (emaSlowHandle = iMA(_Symbol,TrendPeriod,EMA_Slow,0,MODE_EMA,PRICE_CLOSE)) == INVALID_HANDLE ||
      (bbHandle = iBands(_Symbol,EntryPeriod,BB_Period,0,BB_Deviation,PRICE_CLOSE)) == INVALID_HANDLE ||
      (rsiHandle = iRSI(_Symbol,EntryPeriod,RSI_Period,PRICE_CLOSE)) == INVALID_HANDLE ||
      (atrHandle = iATR(_Symbol,EntryPeriod,ATR_Period)) == INVALID_HANDLE ||
      (adxHandle = iADX(_Symbol,EntryPeriod,14)) == INVALID_HANDLE)
   {
      Alert("指标初始化失败!");
      return INIT_FAILED;
   }

   // 初始化动态参数
   dynamic_ATR_Multiplier = ATR_Multiplier;
   dynamic_RiskPerTrade = RiskPerTrade;

   // 设置交易对象参数
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetMarginMode();
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(MaxSlippage);

   // 验证时间框架组合
   if(PeriodSeconds(EntryPeriod) >= PeriodSeconds(TrendPeriod))
   {
      Alert("入场周期必须小于趋势周期!");
      return INIT_FAILED;
   }

   // 设置定时器
   EventSetTimer(60);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| 核心交易逻辑                                                    |
//+------------------------------------------------------------------+
void OnTick()
{
   if(TimeCurrent() == lastTradeTime) return;

   if(!UpdateIndicators()) return; // 指标更新失败时中止

   lotSize = CalculateDynamicLotSize();
   if(lotSize <= 0) return;

   CheckDailyLossLimit();

   if((EnableNewsFilter && IsHighImpactNews()) || 
      (EnableLiquidityFilter && IsLowLiquidityTime())) return;

   AdjustStrategyParameters();

   bool trendDirection = GetTrendDirection();
   ENUM_ORDER_TYPE entrySignal = GetEntrySignal();

   if(entrySignal != WRONG_VALUE) {
      ManagePositions(trendDirection, entrySignal);
   }

   if(EnableTrailing) TrailingStop();

   MonitorPerformance();

   lastTradeTime = TimeCurrent();
}

//+------------------------------------------------------------------+
//| 增强版指标更新函数（带错误处理和性能优化）                      |
//+------------------------------------------------------------------+
bool UpdateIndicators()
{
   static datetime lastBarTime = 0;
   datetime currentBarTime = iTime(_Symbol, EntryPeriod, 0);
   
   // 仅在新K线或定时器触发时更新指标
   if(lastBarTime == currentBarTime && !IsTimerEvent()) 
      return true;
   
   lastBarTime = currentBarTime;

   // 使用结构体组织数据
   struct IndicatorData {
      double fastEMA;
      double slowEMA;
      double upperBand;
      double lowerBand;
      double rsiVal;
      double atrVal;
      double adxVal;
      bool   isValid;
   };
   
   static IndicatorData data;
   int copied = 0;
   
   // 批量获取指标数据（减少重复调用）
   copied += CopyBuffer(emaFastHandle, 0, 0, 1, data.fastEMA);
   copied += CopyBuffer(emaSlowHandle, 0, 0, 1, data.slowEMA);
   copied += CopyBuffer(bbHandle, 1, 0, 1, data.upperBand);
   copied += CopyBuffer(bbHandle, 2, 0, 1, data.lowerBand);
   copied += CopyBuffer(rsiHandle, 0, 0, 1, data.rsiVal);
   copied += CopyBuffer(atrHandle, 0, 0, 1, data.atrVal);
   copied += CopyBuffer(adxHandle, 0, 0, 1, data.adxVal);

   // 验证数据完整性
   if(copied != 7 || 
      data.fastEMA == 0 || data.slowEMA == 0 ||
      data.upperBand == 0 || data.lowerBand == 0)
   {
      Print("指标数据不完整，错误代码：", GetLastError());
      data.isValid = false;
      return false;
   }
   
   // 检查指标逻辑有效性
   if(data.upperBand <= data.lowerBand || 
      data.rsiVal < 0 || data.rsiVal > 100 ||
      data.atrVal <= 0)
   {
      Print("指标逻辑异常：upper=",data.upperBand," lower=",data.lowerBand,
            " RSI=",data.rsiVal," ATR=",data.atrVal);
      data.isValid = false;
      return false;
   }
   
   data.isValid = true;
   return true;
}

//+------------------------------------------------------------------+
//| 判断是否为定时器事件                                            |
//+------------------------------------------------------------------+
bool IsTimerEvent()
{
   static datetime prevTime = 0;
   datetime current = TimeCurrent();
   
   if(MathAbs(current - prevTime) >= 60) {
      prevTime = current;
      return true;
   }
   return false;
}

