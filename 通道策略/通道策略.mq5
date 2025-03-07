//+------------------------------------------------------------------+
//|                                     ChannelBreakoutStrategy.mq5 |
//|                                     Copyright 2024, YourCompany |
//|                                             https://www.yoursite |
//+------------------------------------------------------------------+
#property copyright "ChannelBreakoutStrategy"
#property version   "1.0"
#property strict

#include <Trade\Trade.mqh>
#include <Math\Stat\Math.mqh> // 添加数学库

CTrade trade;

//--- 输入参数
input int      ChannelPeriod    = 50;       // 通道计算周期（根K线）
input int      EntryThreshold   = 200;      // 入场阈值（点）[优化范围]
input int      ExitThreshold    = 100;      // 平仓阈值（点）
input int      StopLoss         = 500;      // 止损点数
input double   RiskPercent      = 2.0;      // 每单风险比例（%）
input int      ATR_Period       = 14;       // ATR波动率周期
input double   VolatilityFilter = 1.5;      // 最大允许波动（ATR倍数）
input int      VolumeFilter     = 80;       // 成交量放大阈值（%）[优化范围]

//--- 全局变量
double upperChannel, lowerChannel;
datetime lastBarTime;
ulong magicNumber = 123456;
int atrHandle;

//+------------------------------------------------------------------+
//| 专家初始化函数                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(magicNumber);
   trade.SetMarginMode();
   trade.SetTypeFillingBySymbol(Symbol());
   
   // 正确初始化ATR句柄（修复点1）
   atrHandle = iATR(Symbol(), PERIOD_CURRENT, ATR_Period);
   if(atrHandle == INVALID_HANDLE){
      Alert("ATR指标初始化失败!");
      return(INIT_FAILED);
   }
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| 主交易逻辑                                                      |
//+------------------------------------------------------------------+
void OnTick()
{
   // 正确的新K线检测逻辑（修复点2）
   datetime currentBarTime = iTime(Symbol(), PERIOD_CURRENT, 0);
   if(currentBarTime == lastBarTime) return;
   lastBarTime = currentBarTime;

   // 更新通道值
   UpdateChannel();

   // 管理现有仓位
   ManagePositions();

   // 检查开仓条件
   CheckEntryConditions();
}

//+------------------------------------------------------------------+
//| 更新通道值（修复版）                                            |
//+------------------------------------------------------------------+
void UpdateChannel()
{
   double highs[], lows[];
   // 获取已闭合K线数据（修复点3）
   if(CopyHigh(Symbol(), PERIOD_CURRENT, 1, ChannelPeriod, highs) < ChannelPeriod || 
      CopyLow(Symbol(), PERIOD_CURRENT, 1, ChannelPeriod, lows) < ChannelPeriod)
   {
      Print("通道数据不足");
      return;
   }
   
   upperChannel = highs[ArrayMaximum(highs)];
   lowerChannel = lows[ArrayMinimum(lows)];
   
   // 调试输出（新增点）
   Print(StringFormat("通道值更新：Upper=%.5f Lower=%.5f", upperChannel, lowerChannel));
   
   upperChannel = NormalizeDouble(upperChannel, _Digits);
   lowerChannel = NormalizeDouble(lowerChannel, _Digits);
}

//+------------------------------------------------------------------+
//| 检查入场条件（优化版）                                          |
//+------------------------------------------------------------------+
void CheckEntryConditions()
{
   double currentPrice = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   long volume = iVolume(Symbol(), PERIOD_CURRENT, 0);
   
   double atrValues[3];
   if(CopyBuffer(atrHandle, 0, 0, 3, atrValues) < 3){
      Print("获取ATR数据失败");
      return;
   }

   // 优化波动率过滤（修复点4）
   double atrAverage = MathMean(atrValues);
   if(atrValues[0] > VolatilityFilter * atrAverage){
      Print("波动率过滤触发：当前ATR(",atrValues[0],") > 过滤值(",VolatilityFilter * atrAverage,")");
      return;
   }

   // 优化成交量过滤
   long prevVolume = iVolume(Symbol(), PERIOD_CURRENT, 1);
   if(volume < (prevVolume * VolumeFilter / 100)){
      Print(StringFormat("成交量过滤：当前量%d < 前量%d的%d%%", volume, prevVolume, VolumeFilter));
      return;
   }

   double entryUpper = upperChannel + EntryThreshold * _Point;
   double entryLower = lowerChannel - EntryThreshold * _Point;
   
   // 调试输出（新增点）
   Print(StringFormat("当前价:%.5f 上轨突破点:%.5f 下轨突破点:%.5f", 
         currentPrice, entryUpper, entryLower));

   if(currentPrice <= entryLower && !PositionExists(POSITION_TYPE_BUY))
      OpenPosition(ORDER_TYPE_BUY);
      
   if(currentPrice >= entryUpper && !PositionExists(POSITION_TYPE_SELL))
      OpenPosition(ORDER_TYPE_SELL);
}


//+------------------------------------------------------------------+
//| 开仓函数（类型修复版）                                          |
//+------------------------------------------------------------------+
void OpenPosition(ENUM_ORDER_TYPE orderType)
{
   double price = (orderType == ORDER_TYPE_BUY) ? 
                 SymbolInfoDouble(Symbol(), SYMBOL_ASK) : 
                 SymbolInfoDouble(Symbol(), SYMBOL_BID);
                 
   double sl = (orderType == ORDER_TYPE_BUY) ? 
              lowerChannel - StopLoss * _Point : 
              upperChannel + StopLoss * _Point;
   
   double lotSize = CalculateLotSize(sl);
   
   if(!trade.PositionOpen(Symbol(), orderType, lotSize, price, sl, 0))
      Print("开仓失败：", GetLastError());
}

//+------------------------------------------------------------------+
//| 仓位管理                                                        |
//+------------------------------------------------------------------+
void ManagePositions()
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
      
      double currentPrice = PositionGetDouble(POSITION_PRICE_CURRENT);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      
      // 计算平仓阈值
      double exitLevel = (posType == POSITION_TYPE_BUY) 
                         ? upperChannel - ExitThreshold * _Point
                         : lowerChannel + ExitThreshold * _Point;

      // 平仓逻辑
      if((posType == POSITION_TYPE_BUY && currentPrice >= exitLevel) ||
         (posType == POSITION_TYPE_SELL && currentPrice <= exitLevel))
      {
         trade.PositionClose(ticket);
      }
   }
}

//+------------------------------------------------------------------+
//| 计算手数大小                                                    |
//+------------------------------------------------------------------+
double CalculateLotSize(double slPrice)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance <= 0) return 0;

   double tickValue = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
   if(tickValue == 0) return 0;
   
   double riskPoints = MathAbs(SymbolInfoDouble(Symbol(), SYMBOL_BID) - slPrice) / _Point;
   if(riskPoints == 0) return 0;

   double lot = NormalizeDouble((balance * RiskPercent / 100) / (riskPoints * tickValue), 2);
   
   // 添加交易品种限制
   double minLot = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX);
   return MathMin(MathMax(lot, minLot), maxLot);
}

//+------------------------------------------------------------------+
//| 检查仓位是否存在                                                |
//+------------------------------------------------------------------+
bool PositionExists(ENUM_POSITION_TYPE type)
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(PositionGetTicket(i) && 
         PositionGetString(POSITION_SYMBOL) == Symbol() &&
         PositionGetInteger(POSITION_MAGIC) == magicNumber &&
         PositionGetInteger(POSITION_TYPE) == type)
      {
         return true;
      }
   }
   return false;
}
//+------------------------------------------------------------------+