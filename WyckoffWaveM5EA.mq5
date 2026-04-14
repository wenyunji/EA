#property strict
#property version   "1.00"
#property description "M5 Wave + Wyckoff EA"

#include <Trade/Trade.mqh>

enum SignalDirection
  {
   SIGNAL_NONE = 0,
   SIGNAL_BUY,
   SIGNAL_SELL
  };

enum EntryModeType
  {
   ENTRY_AUTO = 0,
   ENTRY_WAVE3_ONLY,
   ENTRY_WAVE5_ONLY,
   ENTRY_RANGE_ONLY,
   ENTRY_WAVE3_AND_5
  };

struct WaveSetup
  {
   bool   valid;
   int    pivot0;
   int    pivot1;
   int    pivot2;
   int    pivot3;
   int    pivot4;
   double breakout_level;
   double stop_anchor;
  };

CTrade   trade;
int      atrHandle      = INVALID_HANDLE;
int      emaFastHandle  = INVALID_HANDLE;
int      emaSlowHandle  = INVALID_HANDLE;
int      htfEmaFastHandle = INVALID_HANDLE;
int      htfEmaSlowHandle = INVALID_HANDLE;
datetime lastBarTime    = 0;
datetime lastEntryTime  = 0;

input group "==== 基础参数 ===="
input ENUM_TIMEFRAMES TradeTimeframe     = PERIOD_M5;    // 交易执行周期，策略默认按 M5 设计
input ulong           MagicNumber        = 20260414;     // EA 魔术号，用于识别本策略订单
input bool            EnableLong         = true;         // 是否允许做多信号与多单开仓
input bool            EnableShort        = true;         // 是否允许做空信号与空单开仓
input bool            CloseOnOpposite    = true;         // 出现反向信号时是否优先平掉现有持仓
input int             MaxPositions       = 1;            // 最大持仓数量，0 表示不限制
input int             MaxSpreadPoints    = 80;           // 最大允许点差，超过后跳过该次开仓判断
input int             TradeDeviation     = 20;           // 下单允许滑点，单位为点

input group "==== 多结构模式 ===="
input EntryModeType   EntryMode          = ENTRY_AUTO;   // 入场模式：自动 / 只做3浪 / 只做5浪 / 只做区间 / 同时做3浪和5浪
input double          Wave3MinStructureATR = 2.0;        // 识别 1-2 结构时所需的最小波幅，单位为 ATR 倍数
input double          TrendGapATR        = 0.12;         // 识别趋势状态时，快慢 EMA 间距至少达到多少 ATR
input double          RangeGapATR        = 0.05;         // 识别区间状态时，快慢 EMA 间距不超过多少 ATR
input double          RangeBreakoutATR   = 0.05;         // 区间反转信号突破确认时，对信号棒高低点增加的 ATR 缓冲

input group "==== 执行过滤 ===="
input bool            UseSessionFilter   = true;         // 是否启用交易时段过滤
input string          SessionStart       = "06:00";    // 允许开仓的开始时间，格式 HH:MM
input string          SessionEnd         = "23:00";    // 允许开仓的结束时间，格式 HH:MM
input int             MinBarsBetweenEntries = 6;        // 两次开仓之间最少间隔多少根 K 线
input int             MaxTradesPerDay    = 3;            // 每日最多允许开仓次数，0 表示不限制
input bool            UseDailyLossLimit  = true;         // 是否启用日内亏损熔断
input double          DailyLossLimitCurrency = 200.0;    // 日内累计亏损达到该金额后停止新开仓

input group "==== 仓位参数 ===="
input bool            UseRiskPercent     = true;         // 是否按账户风险百分比自动计算手数
input double          RiskPercent        = 1.0;          // 单笔交易风险占账户余额的百分比
input double          FixedLots          = 0.10;         // 固定手数模式下使用的下单手数

input group "==== 波浪参数 ===="
input int             BarsToScan         = 260;          // 每次识别波浪结构时回看多少根 K 线
input int             PivotStrength      = 3;            // 分型强度，越大越不敏感，拐点越少
input double          MinStructureATR    = 3.0;          // 最小结构幅度，低于该 ATR 倍数的波浪不参与
input double          Wave2MinRetrace    = 0.20;         // 第 2 浪最小回撤比例
input double          Wave2MaxRetrace    = 0.79;         // 第 2 浪最大回撤比例
input double          Wave3MinRatio      = 1.20;         // 第 3 浪相对第 1 浪的最小延伸倍数
input double          Wave4MinRetrace    = 0.15;         // 第 4 浪最小回撤比例
input double          Wave4MaxRetrace    = 0.62;         // 第 4 浪最大回撤比例
input bool            RequireNoOverlap   = false;        // 是否强制要求第 4 浪不与第 1 浪价格区间重叠
input double          BreakoutBufferATR  = 0.08;         // 突破确认缓冲，按 ATR 的倍数加在突破位上
input double          PivotMatchATR      = 0.80;         // 威科夫假突破与关键 pivot 匹配时允许的 ATR 偏差

input group "==== 威科夫参数 ===="
input int             TradingRangeBars   = 24;           // 识别 spring / upthrust 时参考的震荡区间长度
input int             WyckoffSignalBars  = 12;           // 最近多少根 K 线内查找威科夫信号
input int             VolumeLookback     = 20;           // 成交量均值回看周期
input double          FalseBreakATR      = 0.12;         // 假突破超出区间的最小 ATR 幅度
input double          VolumeMultiplier   = 1.20;         // 当前成交量至少达到均量的多少倍才算有效
input double          CloseStrengthBuy   = 0.60;         // 做多 spring 的收盘强度阈值，越大代表收盘越强
input double          CloseStrengthSell  = 0.40;         // 做空 upthrust 的收盘强度阈值，越小代表收盘越弱

input group "==== 趋势与出场 ===="
input int             EMAFastPeriod      = 34;           // 当前交易周期快 EMA 周期
input int             EMASlowPeriod      = 89;           // 当前交易周期慢 EMA 周期
input bool            UseHTFFilter       = true;         // 是否启用更高周期趋势共振过滤
input ENUM_TIMEFRAMES HTFTimeframe       = PERIOD_M15;   // 更高周期趋势过滤所使用的时间框架
input int             HTFEMAFastPeriod   = 34;           // 更高周期快 EMA 周期
input int             HTFEMASlowPeriod   = 89;           // 更高周期慢 EMA 周期
input int             ATRPeriod          = 14;           // ATR 波动率指标周期
input double          MinATRPoints       = 80.0;         // 最小 ATR 点数，低于该波动阈值不交易
input double          StopBufferATR      = 0.25;         // 止损在结构低点/高点外额外预留的 ATR 缓冲
input double          RewardRisk         = 2.20;         // 固定止盈风险收益比
input bool            EnableBreakEven    = true;         // 是否启用保本止损逻辑
input double          BreakEvenAtRR      = 1.00;         // 浮盈达到多少倍初始风险后把止损推到保本
input bool            EnableTrailing     = true;         // 是否启用 ATR 移动止损
input double          TrailATRMultiplier = 1.00;         // 移动止损距离的 ATR 倍数

int OnInit()
  {
   if(TradeTimeframe != PERIOD_M5)
      Print("提示：该策略按 M5 设计，当前仍允许使用其它周期，但建议保持 PERIOD_M5");

   if(!ValidateInputs())
      return INIT_PARAMETERS_INCORRECT;

   atrHandle = iATR(_Symbol, TradeTimeframe, ATRPeriod);
   emaFastHandle = iMA(_Symbol, TradeTimeframe, EMAFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
   emaSlowHandle = iMA(_Symbol, TradeTimeframe, EMASlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
   htfEmaFastHandle = iMA(_Symbol, HTFTimeframe, HTFEMAFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
   htfEmaSlowHandle = iMA(_Symbol, HTFTimeframe, HTFEMASlowPeriod, 0, MODE_EMA, PRICE_CLOSE);

   if(atrHandle == INVALID_HANDLE ||
      emaFastHandle == INVALID_HANDLE ||
      emaSlowHandle == INVALID_HANDLE ||
      htfEmaFastHandle == INVALID_HANDLE ||
      htfEmaSlowHandle == INVALID_HANDLE)
     {
      Print("指标句柄初始化失败");
      return INIT_FAILED;
     }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(TradeDeviation);

   lastBarTime = iTime(_Symbol, TradeTimeframe, 0);
   lastEntryTime = GetLastEntryTimeFromHistory();
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   if(atrHandle != INVALID_HANDLE)
      IndicatorRelease(atrHandle);
   if(emaFastHandle != INVALID_HANDLE)
      IndicatorRelease(emaFastHandle);
   if(emaSlowHandle != INVALID_HANDLE)
      IndicatorRelease(emaSlowHandle);
   if(htfEmaFastHandle != INVALID_HANDLE)
      IndicatorRelease(htfEmaFastHandle);
   if(htfEmaSlowHandle != INVALID_HANDLE)
      IndicatorRelease(htfEmaSlowHandle);
  }

void OnTick()
  {
   ManageOpenPositions();

   if(!IsNewBar())
      return;

   if(UseSessionFilter && !IsWithinTradingSession(TimeCurrent()))
      return;

   if(CurrentSpreadPoints() > MaxSpreadPoints)
     {
      Print("跳过：当前点差过大 -> ", DoubleToString(CurrentSpreadPoints(), 1));
      return;
     }

   MqlRates rates[];
   if(!LoadRates(rates))
      return;

   double atrValue = 0.0;
   double emaFast = 0.0;
   double emaSlow = 0.0;
   double htfEmaFast = 0.0;
   double htfEmaSlow = 0.0;
   if(!GetIndicatorValue(atrHandle, 1, atrValue) ||
      !GetIndicatorValue(emaFastHandle, 1, emaFast) ||
      !GetIndicatorValue(emaSlowHandle, 1, emaSlow) ||
      !GetIndicatorValue(htfEmaFastHandle, 1, htfEmaFast) ||
      !GetIndicatorValue(htfEmaSlowHandle, 1, htfEmaSlow))
     {
      Print("跳过：无法获取 ATR/EMA 数据");
      return;
     }

   if(atrValue / _Point < MinATRPoints)
     {
      Print("跳过：波动不足，ATR点数=", DoubleToString(atrValue / _Point, 1));
      return;
     }

   bool bullishBias = emaFast > emaSlow;
   bool bearishBias = emaFast < emaSlow;
   double emaGap = MathAbs(emaFast - emaSlow);
   bool trendState = emaGap >= atrValue * TrendGapATR;
   bool rangeState = emaGap <= atrValue * RangeGapATR;

   if(UseHTFFilter)
     {
      bullishBias = bullishBias && (htfEmaFast > htfEmaSlow);
      bearishBias = bearishBias && (htfEmaFast < htfEmaSlow);
     }

   WaveSetup buySetup;
   buySetup.valid = false;
   SignalDirection signalDirection = SIGNAL_NONE;
   string signalComment = "";
   bool hasSignal = SelectTradeSignal(
      rates,
      atrValue,
      bullishBias,
      bearishBias,
      trendState,
      rangeState,
      signalDirection,
      buySetup,
      signalComment
   );

   int managedPositions = CountManagedPositions();
   if(managedPositions > 0 && CloseOnOpposite)
     {
      if(signalDirection == SIGNAL_BUY && HasManagedPosition(POSITION_TYPE_SELL))
         CloseManagedPositions(POSITION_TYPE_SELL);
      else if(signalDirection == SIGNAL_SELL && HasManagedPosition(POSITION_TYPE_BUY))
         CloseManagedPositions(POSITION_TYPE_BUY);

      managedPositions = CountManagedPositions();
     }

   if(managedPositions > 0)
     {
      if(signalDirection == SIGNAL_BUY && HasManagedPosition(POSITION_TYPE_SELL))
         return;
      if(signalDirection == SIGNAL_SELL && HasManagedPosition(POSITION_TYPE_BUY))
         return;
     }

   if(MaxPositions > 0 && managedPositions >= MaxPositions)
      return;

   string blockReason = "";
   if(hasSignal && !CanOpenNewTrade(blockReason))
     {
      Print("跳过开仓：", blockReason);
      return;
     }

   if(hasSignal)
      OpenTrade(signalDirection, buySetup, atrValue, signalComment);
  }

bool ValidateInputs()
  {
   if(FixedLots <= 0.0)
      return false;
   if(UseRiskPercent && RiskPercent <= 0.0)
      return false;
   if(PivotStrength < 2)
      return false;
   if(BarsToScan < 120)
      return false;
   if(TradingRangeBars < 10 || WyckoffSignalBars < 3)
      return false;
   if(RewardRisk <= 0.5)
      return false;
   if(Wave3MinStructureATR <= 0.0)
      return false;
   if(TrendGapATR < 0.0 || RangeGapATR < 0.0 || RangeBreakoutATR < 0.0)
      return false;
   if(TrendGapATR <= RangeGapATR)
      return false;
   if(ATRPeriod <= 1 || EMAFastPeriod <= 1 || EMASlowPeriod <= EMAFastPeriod)
      return false;
   if(HTFEMAFastPeriod <= 1 || HTFEMASlowPeriod <= HTFEMAFastPeriod)
      return false;
   if(UseHTFFilter && PeriodSeconds(HTFTimeframe) < PeriodSeconds(TradeTimeframe))
      return false;
   if(MaxPositions < 0)
      return false;
   if(MinBarsBetweenEntries < 0)
      return false;
   if(MaxTradesPerDay < 0)
      return false;
   if(UseDailyLossLimit && DailyLossLimitCurrency <= 0.0)
      return false;
   if(UseSessionFilter && (!IsValidTimeString(SessionStart) || !IsValidTimeString(SessionEnd)))
      return false;
   if(MinATRPoints < 0.0)
      return false;
   return true;
  }

bool IsNewBar()
  {
   datetime currentBar = iTime(_Symbol, TradeTimeframe, 0);
   if(currentBar == 0)
      return false;
   if(currentBar != lastBarTime)
     {
      lastBarTime = currentBar;
      return true;
     }
   return false;
  }

bool LoadRates(MqlRates &rates[])
  {
   int needBars = BarsToScan + PivotStrength * 4 + 20;
   int copied = CopyRates(_Symbol, TradeTimeframe, 0, needBars, rates);
   if(copied <= 0)
     {
      Print("CopyRates 失败: ", GetLastError());
      return false;
     }

   int minBars = MathMax(80, TradingRangeBars + WyckoffSignalBars + PivotStrength * 4 + 10);
   if(copied < minBars)
     {
      Print("数据不足，至少需要K线数: ", minBars, " 实际: ", copied);
      return false;
     }
   return true;
  }

bool GetIndicatorValue(int handle, int shift, double &value)
  {
   double buffer[];
   ArrayResize(buffer, 1);
   if(CopyBuffer(handle, 0, shift, 1, buffer) != 1)
      return false;
   value = buffer[0];
   return value > 0 || handle != atrHandle;
  }

double CurrentSpreadPoints()
  {
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return 999999.0;
   return (tick.ask - tick.bid) / _Point;
  }

bool IsValidTimeString(string value)
  {
   if(StringLen(value) != 5)
      return false;
   if(StringSubstr(value, 2, 1) != ":")
      return false;

   for(int i = 0; i < 5; ++i)
     {
      if(i == 2)
         continue;
      int ch = StringGetCharacter(value, i);
      if(ch < '0' || ch > '9')
         return false;
     }

   int hour = (int)StringToInteger(StringSubstr(value, 0, 2));
   int minute = (int)StringToInteger(StringSubstr(value, 3, 2));
   return hour >= 0 && hour <= 23 && minute >= 0 && minute <= 59;
  }

int ParseMinutesOfDay(string value)
  {
   int hour = (int)StringToInteger(StringSubstr(value, 0, 2));
   int minute = (int)StringToInteger(StringSubstr(value, 3, 2));
   return hour * 60 + minute;
  }

bool IsWithinTradingSession(datetime currentTime)
  {
   if(!UseSessionFilter)
      return true;

   int startMinutes = ParseMinutesOfDay(SessionStart);
   int endMinutes = ParseMinutesOfDay(SessionEnd);

   MqlDateTime timeStruct;
   TimeToStruct(currentTime, timeStruct);
   int currentMinutes = timeStruct.hour * 60 + timeStruct.min;

   if(startMinutes == endMinutes)
      return true;

   if(startMinutes < endMinutes)
      return currentMinutes >= startMinutes && currentMinutes < endMinutes;

   return currentMinutes >= startMinutes || currentMinutes < endMinutes;
  }

datetime GetStartOfDay(datetime currentTime)
  {
   MqlDateTime timeStruct;
   TimeToStruct(currentTime, timeStruct);
   timeStruct.hour = 0;
   timeStruct.min = 0;
   timeStruct.sec = 0;
   return StructToTime(timeStruct);
  }

double GetTodayRealizedPnL()
  {
   datetime dayStart = GetStartOfDay(TimeCurrent());
   if(!HistorySelect(dayStart, TimeCurrent()))
      return 0.0;

   double pnl = 0.0;
   int totalDeals = HistoryDealsTotal();
   for(int i = 0; i < totalDeals; ++i)
     {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0)
         continue;
      if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol)
         continue;
      if((ulong)HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != MagicNumber)
         continue;

      long entryType = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
      if(entryType != DEAL_ENTRY_OUT && entryType != DEAL_ENTRY_OUT_BY)
         continue;

      pnl += HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
      pnl += HistoryDealGetDouble(dealTicket, DEAL_SWAP);
      pnl += HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
     }
   return pnl;
  }

int GetTodayEntryCount()
  {
   datetime dayStart = GetStartOfDay(TimeCurrent());
   if(!HistorySelect(dayStart, TimeCurrent()))
      return 0;

   int count = 0;
   int totalDeals = HistoryDealsTotal();
   for(int i = 0; i < totalDeals; ++i)
     {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0)
         continue;
      if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol)
         continue;
      if((ulong)HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != MagicNumber)
         continue;
      if(HistoryDealGetInteger(dealTicket, DEAL_ENTRY) == DEAL_ENTRY_IN)
         count++;
     }
   return count;
  }

datetime GetLastEntryTimeFromHistory()
  {
   datetime fromTime = TimeCurrent() - 86400 * 30;
   if(!HistorySelect(fromTime, TimeCurrent()))
      return 0;

   datetime latest = 0;
   int totalDeals = HistoryDealsTotal();
   for(int i = 0; i < totalDeals; ++i)
     {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0)
         continue;
      if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol)
         continue;
      if((ulong)HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != MagicNumber)
         continue;
      if(HistoryDealGetInteger(dealTicket, DEAL_ENTRY) != DEAL_ENTRY_IN)
         continue;

      datetime dealTime = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
      if(dealTime > latest)
         latest = dealTime;
     }
   return latest;
  }

bool IsInCooldown()
  {
   if(MinBarsBetweenEntries <= 0 || lastEntryTime <= 0)
      return false;

   int barsPassed = iBarShift(_Symbol, TradeTimeframe, lastEntryTime, false);
   if(barsPassed < 0)
      return false;

   return barsPassed < MinBarsBetweenEntries;
  }

bool CanOpenNewTrade(string &reason)
  {
   if(UseSessionFilter && !IsWithinTradingSession(TimeCurrent()))
     {
      reason = "当前不在交易时段";
      return false;
     }

   if(IsInCooldown())
     {
      reason = "仍在开仓冷却期";
      return false;
     }

   int todayEntries = GetTodayEntryCount();
   if(MaxTradesPerDay > 0 && todayEntries >= MaxTradesPerDay)
     {
      reason = "已达到当日最大开仓次数";
      return false;
     }

   double todayPnL = GetTodayRealizedPnL();
   if(UseDailyLossLimit && todayPnL <= -DailyLossLimitCurrency)
     {
      reason = "触发日内亏损熔断";
      return false;
     }

   reason = "";
   return true;
  }

bool SelectWave3Signal(const MqlRates &rates[], double atrValue, bool bullishBias, bool bearishBias,
                       SignalDirection &direction, WaveSetup &setup, string &comment)
  {
   WaveSetup signalSetup;
   signalSetup.valid = false;

   if(EnableLong && bullishBias && BuildBullishWave3Signal(rates, atrValue, signalSetup))
     {
      direction = SIGNAL_BUY;
      setup = signalSetup;
      comment = "Wave3 Buy";
      return true;
     }

   signalSetup.valid = false;
   if(EnableShort && bearishBias && BuildBearishWave3Signal(rates, atrValue, signalSetup))
     {
      direction = SIGNAL_SELL;
      setup = signalSetup;
      comment = "Wave3 Sell";
      return true;
     }

   direction = SIGNAL_NONE;
   comment = "";
   return false;
  }

bool SelectWave5Signal(const MqlRates &rates[], double atrValue, bool bullishBias, bool bearishBias,
                       SignalDirection &direction, WaveSetup &setup, string &comment)
  {
   WaveSetup signalSetup;
   signalSetup.valid = false;

   if(EnableLong && bullishBias && BuildBullishWave5Signal(rates, atrValue, signalSetup))
     {
      direction = SIGNAL_BUY;
      setup = signalSetup;
      comment = "Wave5 Buy";
      return true;
     }

   signalSetup.valid = false;
   if(EnableShort && bearishBias && BuildBearishWave5Signal(rates, atrValue, signalSetup))
     {
      direction = SIGNAL_SELL;
      setup = signalSetup;
      comment = "Wave5 Sell";
      return true;
     }

   direction = SIGNAL_NONE;
   comment = "";
   return false;
  }

bool SelectRangeSignal(const MqlRates &rates[], double atrValue,
                       SignalDirection &direction, WaveSetup &setup, string &comment)
  {
   WaveSetup buySetup;
   WaveSetup sellSetup;
   buySetup.valid = false;
   sellSetup.valid = false;

   bool hasBuy = EnableLong && BuildBullishRangeSignal(rates, atrValue, buySetup);
   bool hasSell = EnableShort && BuildBearishRangeSignal(rates, atrValue, sellSetup);

   if(hasBuy && hasSell)
     {
      direction = SIGNAL_NONE;
      comment = "";
      return false;
     }

   if(hasBuy)
     {
      direction = SIGNAL_BUY;
      setup = buySetup;
      comment = "Range Spring Buy";
      return true;
     }

   if(hasSell)
     {
      direction = SIGNAL_SELL;
      setup = sellSetup;
      comment = "Range Upthrust Sell";
      return true;
     }

   direction = SIGNAL_NONE;
   comment = "";
   return false;
  }

bool SelectTradeSignal(const MqlRates &rates[], double atrValue, bool bullishBias, bool bearishBias,
                       bool trendState, bool rangeState,
                       SignalDirection &direction, WaveSetup &setup, string &comment)
  {
   direction = SIGNAL_NONE;
   setup.valid = false;
   comment = "";

   if(EntryMode == ENTRY_WAVE3_ONLY)
      return SelectWave3Signal(rates, atrValue, bullishBias, bearishBias, direction, setup, comment);

   if(EntryMode == ENTRY_WAVE5_ONLY)
      return SelectWave5Signal(rates, atrValue, bullishBias, bearishBias, direction, setup, comment);

   if(EntryMode == ENTRY_RANGE_ONLY)
      return SelectRangeSignal(rates, atrValue, direction, setup, comment);

   if(EntryMode == ENTRY_WAVE3_AND_5)
     {
      if(SelectWave3Signal(rates, atrValue, bullishBias, bearishBias, direction, setup, comment))
         return true;
      return SelectWave5Signal(rates, atrValue, bullishBias, bearishBias, direction, setup, comment);
     }

   if(trendState)
     {
      if(SelectWave3Signal(rates, atrValue, bullishBias, bearishBias, direction, setup, comment))
         return true;
      if(SelectWave5Signal(rates, atrValue, bullishBias, bearishBias, direction, setup, comment))
         return true;
     }

   if(rangeState)
     {
      if(SelectRangeSignal(rates, atrValue, direction, setup, comment))
         return true;
     }

   if(SelectWave3Signal(rates, atrValue, bullishBias, bearishBias, direction, setup, comment))
      return true;
   if(SelectWave5Signal(rates, atrValue, bullishBias, bearishBias, direction, setup, comment))
      return true;
   if(!trendState && SelectRangeSignal(rates, atrValue, direction, setup, comment))
      return true;

   direction = SIGNAL_NONE;
   comment = "";
   return false;
  }

bool BuildBullishWave3Signal(const MqlRates &rates[], double atrValue, WaveSetup &setup)
  {
   if(!FindBullishWave3(rates, atrValue, setup))
      return false;

   int springIndex = -1;
   double springLow = 0.0;
   if(!FindSpring(rates, atrValue, setup.pivot2, springIndex, springLow))
      return false;

   int lastClosed = ArraySize(rates) - 2;
   int prevClosed = lastClosed - 1;
   if(prevClosed < 0)
      return false;

   if(rates[lastClosed].close <= setup.breakout_level)
      return false;
   if(rates[prevClosed].close > setup.breakout_level)
      return false;
   if(rates[lastClosed].close <= rates[lastClosed].open)
      return false;

   setup.stop_anchor = MathMin(setup.stop_anchor, springLow);
   return true;
  }

bool BuildBearishWave3Signal(const MqlRates &rates[], double atrValue, WaveSetup &setup)
  {
   if(!FindBearishWave3(rates, atrValue, setup))
      return false;

   int upthrustIndex = -1;
   double upthrustHigh = 0.0;
   if(!FindUpthrust(rates, atrValue, setup.pivot2, upthrustIndex, upthrustHigh))
      return false;

   int lastClosed = ArraySize(rates) - 2;
   int prevClosed = lastClosed - 1;
   if(prevClosed < 0)
      return false;

   if(rates[lastClosed].close >= setup.breakout_level)
      return false;
   if(rates[prevClosed].close < setup.breakout_level)
      return false;
   if(rates[lastClosed].close >= rates[lastClosed].open)
      return false;

   setup.stop_anchor = MathMax(setup.stop_anchor, upthrustHigh);
   return true;
  }

bool BuildBullishWave5Signal(const MqlRates &rates[], double atrValue, WaveSetup &setup)
  {
   if(!FindBullishWave(rates, atrValue, setup))
      return false;

   int springIndex = -1;
   double springLow = 0.0;
   if(!FindSpring(rates, atrValue, setup.pivot4, springIndex, springLow))
      return false;

   int lastClosed = ArraySize(rates) - 2;
   int prevClosed = lastClosed - 1;
   if(prevClosed < 0)
      return false;

   double breakoutLevel = setup.breakout_level;
   if(rates[lastClosed].close <= breakoutLevel)
      return false;
   if(rates[prevClosed].close > breakoutLevel)
      return false;

   if(rates[lastClosed].close <= rates[lastClosed].open)
      return false;

   setup.stop_anchor = MathMin(setup.stop_anchor, springLow);
   return true;
  }

bool BuildBearishWave5Signal(const MqlRates &rates[], double atrValue, WaveSetup &setup)
  {
   if(!FindBearishWave(rates, atrValue, setup))
      return false;

   int upthrustIndex = -1;
   double upthrustHigh = 0.0;
   if(!FindUpthrust(rates, atrValue, setup.pivot4, upthrustIndex, upthrustHigh))
      return false;

   int lastClosed = ArraySize(rates) - 2;
   int prevClosed = lastClosed - 1;
   if(prevClosed < 0)
      return false;

   double breakoutLevel = setup.breakout_level;
   if(rates[lastClosed].close >= breakoutLevel)
      return false;
   if(rates[prevClosed].close < breakoutLevel)
      return false;

   if(rates[lastClosed].close >= rates[lastClosed].open)
      return false;

   setup.stop_anchor = MathMax(setup.stop_anchor, upthrustHigh);
   return true;
  }

bool BuildBullishRangeSignal(const MqlRates &rates[], double atrValue, WaveSetup &setup)
  {
   int signalIndex = -1;
   double springLow = 0.0;
   if(!FindRangeSpring(rates, atrValue, signalIndex, springLow))
      return false;

   int lastClosed = ArraySize(rates) - 2;
   int prevClosed = lastClosed - 1;
   if(prevClosed < 0 || signalIndex < 0)
      return false;

   double breakoutLevel = rates[signalIndex].high + atrValue * RangeBreakoutATR;
   if(rates[lastClosed].close <= breakoutLevel)
      return false;
   if(rates[prevClosed].close > breakoutLevel)
      return false;
   if(rates[lastClosed].close <= rates[lastClosed].open)
      return false;

   setup.valid = true;
   setup.pivot0 = signalIndex;
   setup.pivot1 = -1;
   setup.pivot2 = -1;
   setup.pivot3 = -1;
   setup.pivot4 = -1;
   setup.breakout_level = breakoutLevel;
   setup.stop_anchor = springLow;
   return true;
  }

bool BuildBearishRangeSignal(const MqlRates &rates[], double atrValue, WaveSetup &setup)
  {
   int signalIndex = -1;
   double upthrustHigh = 0.0;
   if(!FindRangeUpthrust(rates, atrValue, signalIndex, upthrustHigh))
      return false;

   int lastClosed = ArraySize(rates) - 2;
   int prevClosed = lastClosed - 1;
   if(prevClosed < 0 || signalIndex < 0)
      return false;

   double breakoutLevel = rates[signalIndex].low - atrValue * RangeBreakoutATR;
   if(rates[lastClosed].close >= breakoutLevel)
      return false;
   if(rates[prevClosed].close < breakoutLevel)
      return false;
   if(rates[lastClosed].close >= rates[lastClosed].open)
      return false;

   setup.valid = true;
   setup.pivot0 = signalIndex;
   setup.pivot1 = -1;
   setup.pivot2 = -1;
   setup.pivot3 = -1;
   setup.pivot4 = -1;
   setup.breakout_level = breakoutLevel;
   setup.stop_anchor = upthrustHigh;
   return true;
  }

bool FindBullishWave(const MqlRates &rates[], double atrValue, WaveSetup &setup)
  {
   int pivotIndex[];
   double pivotPrice[];
   int pivotType[];
   CollectPivots(rates, pivotIndex, pivotPrice, pivotType);

   int total = ArraySize(pivotIndex);
   if(total < 5)
      return false;

   for(int start = total - 5; start >= 0; --start)
     {
      if(pivotType[start] != -1 || pivotType[start + 1] != 1 || pivotType[start + 2] != -1 || pivotType[start + 3] != 1 || pivotType[start + 4] != -1)
         continue;

      double low0 = pivotPrice[start];
      double high1 = pivotPrice[start + 1];
      double low2 = pivotPrice[start + 2];
      double high3 = pivotPrice[start + 3];
      double low4 = pivotPrice[start + 4];

      double wave1 = high1 - low0;
      double wave2Retrace = wave1 > 0.0 ? (high1 - low2) / wave1 : 0.0;
      double wave3 = high3 - low2;
      double wave4Retrace = wave3 > 0.0 ? (high3 - low4) / wave3 : 0.0;
      double totalRange = high3 - low0;

      if(wave1 <= 0.0 || wave3 <= 0.0)
         continue;
      if(totalRange < atrValue * MinStructureATR)
         continue;
      if(low2 <= low0)
         continue;
      if(high3 <= high1)
         continue;
      if(low4 <= low2)
         continue;
      if(wave2Retrace < Wave2MinRetrace || wave2Retrace > Wave2MaxRetrace)
         continue;
      if(wave3 < wave1 * Wave3MinRatio)
         continue;
      if(wave4Retrace < Wave4MinRetrace || wave4Retrace > Wave4MaxRetrace)
         continue;
      if(RequireNoOverlap && low4 <= high1)
         continue;

      setup.valid = true;
      setup.pivot0 = pivotIndex[start];
      setup.pivot1 = pivotIndex[start + 1];
      setup.pivot2 = pivotIndex[start + 2];
      setup.pivot3 = pivotIndex[start + 3];
      setup.pivot4 = pivotIndex[start + 4];
      setup.breakout_level = high3 + atrValue * BreakoutBufferATR;
      setup.stop_anchor = low4;
      return true;
     }
   return false;
  }

bool FindBearishWave(const MqlRates &rates[], double atrValue, WaveSetup &setup)
  {
   int pivotIndex[];
   double pivotPrice[];
   int pivotType[];
   CollectPivots(rates, pivotIndex, pivotPrice, pivotType);

   int total = ArraySize(pivotIndex);
   if(total < 5)
      return false;

   for(int start = total - 5; start >= 0; --start)
     {
      if(pivotType[start] != 1 || pivotType[start + 1] != -1 || pivotType[start + 2] != 1 || pivotType[start + 3] != -1 || pivotType[start + 4] != 1)
         continue;

      double high0 = pivotPrice[start];
      double low1 = pivotPrice[start + 1];
      double high2 = pivotPrice[start + 2];
      double low3 = pivotPrice[start + 3];
      double high4 = pivotPrice[start + 4];

      double wave1 = high0 - low1;
      double wave2Retrace = wave1 > 0.0 ? (high2 - low1) / wave1 : 0.0;
      double wave3 = high2 - low3;
      double wave4Retrace = wave3 > 0.0 ? (high4 - low3) / wave3 : 0.0;
      double totalRange = high0 - low3;

      if(wave1 <= 0.0 || wave3 <= 0.0)
         continue;
      if(totalRange < atrValue * MinStructureATR)
         continue;
      if(high2 >= high0)
         continue;
      if(low3 >= low1)
         continue;
      if(high4 >= high2)
         continue;
      if(wave2Retrace < Wave2MinRetrace || wave2Retrace > Wave2MaxRetrace)
         continue;
      if(wave3 < wave1 * Wave3MinRatio)
         continue;
      if(wave4Retrace < Wave4MinRetrace || wave4Retrace > Wave4MaxRetrace)
         continue;
      if(RequireNoOverlap && high4 >= low1)
         continue;

      setup.valid = true;
      setup.pivot0 = pivotIndex[start];
      setup.pivot1 = pivotIndex[start + 1];
      setup.pivot2 = pivotIndex[start + 2];
      setup.pivot3 = pivotIndex[start + 3];
      setup.pivot4 = pivotIndex[start + 4];
      setup.breakout_level = low3 - atrValue * BreakoutBufferATR;
      setup.stop_anchor = high4;
      return true;
     }
   return false;
  }

bool FindBullishWave3(const MqlRates &rates[], double atrValue, WaveSetup &setup)
  {
   int pivotIndex[];
   double pivotPrice[];
   int pivotType[];
   CollectPivots(rates, pivotIndex, pivotPrice, pivotType);

   int total = ArraySize(pivotIndex);
   if(total < 3)
      return false;

   for(int start = total - 3; start >= 0; --start)
     {
      if(pivotType[start] != -1 || pivotType[start + 1] != 1 || pivotType[start + 2] != -1)
         continue;

      double low0 = pivotPrice[start];
      double high1 = pivotPrice[start + 1];
      double low2 = pivotPrice[start + 2];
      double wave1 = high1 - low0;
      double wave2Retrace = wave1 > 0.0 ? (high1 - low2) / wave1 : 0.0;

      if(wave1 <= 0.0)
         continue;
      if(wave1 < atrValue * Wave3MinStructureATR)
         continue;
      if(low2 <= low0)
         continue;
      if(wave2Retrace < Wave2MinRetrace || wave2Retrace > Wave2MaxRetrace)
         continue;

      setup.valid = true;
      setup.pivot0 = pivotIndex[start];
      setup.pivot1 = pivotIndex[start + 1];
      setup.pivot2 = pivotIndex[start + 2];
      setup.pivot3 = -1;
      setup.pivot4 = -1;
      setup.breakout_level = high1 + atrValue * BreakoutBufferATR;
      setup.stop_anchor = low2;
      return true;
     }
   return false;
  }

bool FindBearishWave3(const MqlRates &rates[], double atrValue, WaveSetup &setup)
  {
   int pivotIndex[];
   double pivotPrice[];
   int pivotType[];
   CollectPivots(rates, pivotIndex, pivotPrice, pivotType);

   int total = ArraySize(pivotIndex);
   if(total < 3)
      return false;

   for(int start = total - 3; start >= 0; --start)
     {
      if(pivotType[start] != 1 || pivotType[start + 1] != -1 || pivotType[start + 2] != 1)
         continue;

      double high0 = pivotPrice[start];
      double low1 = pivotPrice[start + 1];
      double high2 = pivotPrice[start + 2];
      double wave1 = high0 - low1;
      double wave2Retrace = wave1 > 0.0 ? (high2 - low1) / wave1 : 0.0;

      if(wave1 <= 0.0)
         continue;
      if(wave1 < atrValue * Wave3MinStructureATR)
         continue;
      if(high2 >= high0)
         continue;
      if(wave2Retrace < Wave2MinRetrace || wave2Retrace > Wave2MaxRetrace)
         continue;

      setup.valid = true;
      setup.pivot0 = pivotIndex[start];
      setup.pivot1 = pivotIndex[start + 1];
      setup.pivot2 = pivotIndex[start + 2];
      setup.pivot3 = -1;
      setup.pivot4 = -1;
      setup.breakout_level = low1 - atrValue * BreakoutBufferATR;
      setup.stop_anchor = high2;
      return true;
     }
   return false;
  }

void CollectPivots(const MqlRates &rates[], int &indices[], double &prices[], int &types[])
  {
   ArrayResize(indices, 0);
   ArrayResize(prices, 0);
   ArrayResize(types, 0);

   int totalBars = ArraySize(rates);
   int lastClosed = totalBars - 2;
   int startBar = PivotStrength;
   int endBar = lastClosed - PivotStrength;
   if(endBar <= startBar)
      return;

   for(int bar = startBar; bar <= endBar; ++bar)
     {
      bool isHigh = true;
      bool isLow = true;
      for(int offset = 1; offset <= PivotStrength; ++offset)
        {
         if(rates[bar].high <= rates[bar - offset].high || rates[bar].high < rates[bar + offset].high)
            isHigh = false;
         if(rates[bar].low >= rates[bar - offset].low || rates[bar].low > rates[bar + offset].low)
            isLow = false;
         if(!isHigh && !isLow)
            break;
        }

      if(isHigh && isLow)
         continue;

      if(isHigh)
         AppendPivot(indices, prices, types, bar, rates[bar].high, 1);
      if(isLow)
         AppendPivot(indices, prices, types, bar, rates[bar].low, -1);
     }
  }

void AppendPivot(int &indices[], double &prices[], int &types[], int bar, double price, int type)
  {
   int total = ArraySize(indices);
   if(total == 0)
     {
      ArrayResize(indices, 1);
      ArrayResize(prices, 1);
      ArrayResize(types, 1);
      indices[0] = bar;
      prices[0] = price;
      types[0] = type;
      return;
     }

   int last = total - 1;
   if(types[last] == type)
     {
      bool shouldReplace = (type == 1 && price > prices[last]) || (type == -1 && price < prices[last]);
      if(shouldReplace)
        {
         indices[last] = bar;
         prices[last] = price;
        }
      return;
     }

   ArrayResize(indices, total + 1);
   ArrayResize(prices, total + 1);
   ArrayResize(types, total + 1);
   indices[total] = bar;
   prices[total] = price;
   types[total] = type;
  }

bool FindSpring(const MqlRates &rates[], double atrValue, int pivotIndex, int &signalIndex, double &springLow)
  {
   int lastClosed = ArraySize(rates) - 2;
   int startBar = MathMax(TradingRangeBars, lastClosed - WyckoffSignalBars + 1);
   for(int bar = startBar; bar <= lastClosed; ++bar)
     {
      double support = LowestLow(rates, bar - TradingRangeBars, bar - 1);
      double avgVolume = AverageVolume(rates, MathMax(0, bar - VolumeLookback), bar - 1);
      double barRange = rates[bar].high - rates[bar].low;
      if(barRange <= 0.0)
         continue;

      double closeStrength = (rates[bar].close - rates[bar].low) / barRange;
      bool nearPivot = MathAbs(rates[bar].low - rates[pivotIndex].low) <= atrValue * PivotMatchATR;
      bool hasFalseBreak = rates[bar].low < support - atrValue * FalseBreakATR;
      bool reclaim = rates[bar].close > support;
      bool volumeOk = avgVolume <= 0.0 || GetVolume(rates[bar]) >= avgVolume * VolumeMultiplier;

      if(nearPivot && hasFalseBreak && reclaim && closeStrength >= CloseStrengthBuy && volumeOk)
        {
         signalIndex = bar;
         springLow = rates[bar].low;
         return true;
        }
     }
   return false;
  }

bool FindUpthrust(const MqlRates &rates[], double atrValue, int pivotIndex, int &signalIndex, double &upthrustHigh)
  {
   int lastClosed = ArraySize(rates) - 2;
   int startBar = MathMax(TradingRangeBars, lastClosed - WyckoffSignalBars + 1);
   for(int bar = startBar; bar <= lastClosed; ++bar)
     {
      double resistance = HighestHigh(rates, bar - TradingRangeBars, bar - 1);
      double avgVolume = AverageVolume(rates, MathMax(0, bar - VolumeLookback), bar - 1);
      double barRange = rates[bar].high - rates[bar].low;
      if(barRange <= 0.0)
         continue;

      double closeStrength = (rates[bar].close - rates[bar].low) / barRange;
      bool nearPivot = MathAbs(rates[bar].high - rates[pivotIndex].high) <= atrValue * PivotMatchATR;
      bool hasFalseBreak = rates[bar].high > resistance + atrValue * FalseBreakATR;
      bool reject = rates[bar].close < resistance;
      bool volumeOk = avgVolume <= 0.0 || GetVolume(rates[bar]) >= avgVolume * VolumeMultiplier;

      if(nearPivot && hasFalseBreak && reject && closeStrength <= CloseStrengthSell && volumeOk)
        {
         signalIndex = bar;
         upthrustHigh = rates[bar].high;
         return true;
        }
     }
   return false;
  }

bool FindRangeSpring(const MqlRates &rates[], double atrValue, int &signalIndex, double &springLow)
  {
   int lastClosed = ArraySize(rates) - 2;
   int signalEnd = lastClosed - 1;
   if(signalEnd < TradingRangeBars)
      return false;

   int startBar = MathMax(TradingRangeBars, signalEnd - WyckoffSignalBars + 1);
   for(int bar = startBar; bar <= signalEnd; ++bar)
     {
      double support = LowestLow(rates, bar - TradingRangeBars, bar - 1);
      double avgVolume = AverageVolume(rates, MathMax(0, bar - VolumeLookback), bar - 1);
      double barRange = rates[bar].high - rates[bar].low;
      if(barRange <= 0.0)
         continue;

      double closeStrength = (rates[bar].close - rates[bar].low) / barRange;
      bool hasFalseBreak = rates[bar].low < support - atrValue * FalseBreakATR;
      bool reclaim = rates[bar].close > support;
      bool volumeOk = avgVolume <= 0.0 || GetVolume(rates[bar]) >= avgVolume * VolumeMultiplier;

      if(hasFalseBreak && reclaim && closeStrength >= CloseStrengthBuy && volumeOk)
        {
         signalIndex = bar;
         springLow = rates[bar].low;
         return true;
        }
     }
   return false;
  }

bool FindRangeUpthrust(const MqlRates &rates[], double atrValue, int &signalIndex, double &upthrustHigh)
  {
   int lastClosed = ArraySize(rates) - 2;
   int signalEnd = lastClosed - 1;
   if(signalEnd < TradingRangeBars)
      return false;

   int startBar = MathMax(TradingRangeBars, signalEnd - WyckoffSignalBars + 1);
   for(int bar = startBar; bar <= signalEnd; ++bar)
     {
      double resistance = HighestHigh(rates, bar - TradingRangeBars, bar - 1);
      double avgVolume = AverageVolume(rates, MathMax(0, bar - VolumeLookback), bar - 1);
      double barRange = rates[bar].high - rates[bar].low;
      if(barRange <= 0.0)
         continue;

      double closeStrength = (rates[bar].close - rates[bar].low) / barRange;
      bool hasFalseBreak = rates[bar].high > resistance + atrValue * FalseBreakATR;
      bool reject = rates[bar].close < resistance;
      bool volumeOk = avgVolume <= 0.0 || GetVolume(rates[bar]) >= avgVolume * VolumeMultiplier;

      if(hasFalseBreak && reject && closeStrength <= CloseStrengthSell && volumeOk)
        {
         signalIndex = bar;
         upthrustHigh = rates[bar].high;
         return true;
        }
     }
   return false;
  }

double LowestLow(const MqlRates &rates[], int fromBar, int toBar)
  {
   fromBar = MathMax(0, fromBar);
   toBar = MathMin(ArraySize(rates) - 1, toBar);
   double value = rates[fromBar].low;
   for(int i = fromBar + 1; i <= toBar; ++i)
      value = MathMin(value, rates[i].low);
   return value;
  }

double HighestHigh(const MqlRates &rates[], int fromBar, int toBar)
  {
   fromBar = MathMax(0, fromBar);
   toBar = MathMin(ArraySize(rates) - 1, toBar);
   double value = rates[fromBar].high;
   for(int i = fromBar + 1; i <= toBar; ++i)
      value = MathMax(value, rates[i].high);
   return value;
  }

double AverageVolume(const MqlRates &rates[], int fromBar, int toBar)
  {
   fromBar = MathMax(0, fromBar);
   toBar = MathMin(ArraySize(rates) - 1, toBar);
   if(toBar < fromBar)
      return 0.0;

   double sum = 0.0;
   int count = 0;
   for(int i = fromBar; i <= toBar; ++i)
     {
      sum += GetVolume(rates[i]);
      count++;
     }
   return count > 0 ? sum / count : 0.0;
  }

double GetVolume(const MqlRates &bar)
  {
   if(bar.real_volume > 0)
      return (double)bar.real_volume;
   return (double)bar.tick_volume;
  }

bool OpenTrade(SignalDirection direction, const WaveSetup &setup, double atrValue, string comment)
  {
   if(!setup.valid)
      return false;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   double entryPrice = direction == SIGNAL_BUY ? tick.ask : tick.bid;
   double stopPrice = direction == SIGNAL_BUY ? setup.stop_anchor - atrValue * StopBufferATR
                                              : setup.stop_anchor + atrValue * StopBufferATR;

   double stopDistance = MathAbs(entryPrice - stopPrice);
   if(stopDistance <= _Point * 10)
     {
      Print("放弃开仓：止损距离过小");
      return false;
     }

   double takePrice = direction == SIGNAL_BUY ? entryPrice + stopDistance * RewardRisk
                                              : entryPrice - stopDistance * RewardRisk;
   double volume = CalculateOrderVolume(stopDistance);
   if(volume <= 0.0)
     {
      Print("放弃开仓：手数计算失败");
      return false;
     }

   stopPrice = NormalizePrice(stopPrice);
   takePrice = NormalizePrice(takePrice);

   bool result = false;
   if(direction == SIGNAL_BUY)
      result = trade.Buy(volume, _Symbol, 0.0, stopPrice, takePrice, comment);
   else if(direction == SIGNAL_SELL)
      result = trade.Sell(volume, _Symbol, 0.0, stopPrice, takePrice, comment);

   if(!result)
     {
      Print("下单失败: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      return false;
     }

   lastEntryTime = TimeCurrent();

   Print(comment, " | 手数=", DoubleToString(volume, 2),
         " 入场=", DoubleToString(entryPrice, _Digits),
         " 止损=", DoubleToString(stopPrice, _Digits),
         " 止盈=", DoubleToString(takePrice, _Digits));
   return true;
  }

double CalculateOrderVolume(double stopDistance)
  {
   if(!UseRiskPercent)
      return NormalizeVolume(FixedLots);

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * RiskPercent / 100.0;
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);

   if(riskMoney <= 0.0 || tickSize <= 0.0 || tickValue <= 0.0 || stopDistance <= 0.0)
      return NormalizeVolume(FixedLots);

   double lossPerLot = (stopDistance / tickSize) * tickValue;
   if(lossPerLot <= 0.0)
      return NormalizeVolume(FixedLots);

   double rawVolume = riskMoney / lossPerLot;
   return NormalizeVolume(rawVolume);
  }

double NormalizeVolume(double volume)
  {
   double minVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(step <= 0.0)
      step = 0.01;

   volume = MathMax(minVolume, MathMin(maxVolume, volume));
   volume = minVolume + MathFloor((volume - minVolume) / step + 0.0000001) * step;
   volume = MathMax(minVolume, MathMin(maxVolume, volume));
   return NormalizeDouble(volume, VolumeDigits(step));
  }

int VolumeDigits(double step)
  {
   int digits = 0;
   double scaled = step;
   while(digits < 8 && MathAbs(scaled - MathRound(scaled)) > 0.0000001)
     {
      scaled *= 10.0;
      digits++;
     }
   return digits;
  }

double NormalizePrice(double price)
  {
   return NormalizeDouble(price, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
  }

int CountManagedPositions()
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;
      count++;
     }
   return count;
  }

bool HasManagedPosition(ENUM_POSITION_TYPE positionType)
  {
   for(int i = PositionsTotal() - 1; i >= 0; --i)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == positionType)
         return true;
     }
   return false;
  }

void CloseManagedPositions(ENUM_POSITION_TYPE positionType)
  {
   for(int i = PositionsTotal() - 1; i >= 0; --i)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != positionType)
         continue;

      if(!trade.PositionClose(ticket))
         Print("平仓失败: ", ticket, " ", trade.ResultRetcodeDescription());
     }
  }

void ManageOpenPositions()
  {
   double atrValue = 0.0;
   if(!GetIndicatorValue(atrHandle, 0, atrValue) || atrValue <= 0.0)
      return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      double marketPrice = type == POSITION_TYPE_BUY ? tick.bid : tick.ask;
      double initialRisk = 0.0;

      if(currentTP > 0.0 && RewardRisk > 0.0)
         initialRisk = MathAbs(currentTP - openPrice) / RewardRisk;
      else if(currentSL > 0.0)
         initialRisk = MathAbs(openPrice - currentSL);

      double newSL = currentSL;

      if(EnableBreakEven && initialRisk > 0.0)
        {
         if(type == POSITION_TYPE_BUY && marketPrice - openPrice >= initialRisk * BreakEvenAtRR)
            newSL = MathMax(newSL, openPrice);
         if(type == POSITION_TYPE_SELL && openPrice - marketPrice >= initialRisk * BreakEvenAtRR)
           {
            if(newSL == 0.0)
               newSL = openPrice;
            else
               newSL = MathMin(newSL, openPrice);
           }
        }

      if(EnableTrailing)
        {
         double trailingSL = type == POSITION_TYPE_BUY ? marketPrice - atrValue * TrailATRMultiplier
                                                       : marketPrice + atrValue * TrailATRMultiplier;
         bool inProfit = (type == POSITION_TYPE_BUY && marketPrice > openPrice) ||
                         (type == POSITION_TYPE_SELL && marketPrice < openPrice);
         if(type == POSITION_TYPE_BUY && inProfit)
           {
            if(newSL == 0.0)
               newSL = trailingSL;
            else
               newSL = MathMax(newSL, trailingSL);
           }
         else if(type == POSITION_TYPE_SELL && inProfit)
           {
            if(newSL == 0.0)
               newSL = trailingSL;
            else
               newSL = MathMin(newSL, trailingSL);
           }
        }

      newSL = NormalizePrice(newSL);

      bool shouldModify = false;
      if(type == POSITION_TYPE_BUY && newSL > currentSL + _Point)
         shouldModify = true;
      if(type == POSITION_TYPE_SELL && (currentSL == 0.0 || newSL < currentSL - _Point))
         shouldModify = true;

      if(shouldModify)
        {
         if(!trade.PositionModify(ticket, newSL, currentTP))
            Print("移动止损失败: ", ticket, " ", trade.ResultRetcodeDescription());
        }
     }
  }
