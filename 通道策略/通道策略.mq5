#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

#property copyright "WEN YUNJI"
#property version   "6.4"  // 版本号升级

//---- 输入参数 -----------------------------------------------------
input int     ChannelPeriod   = 34;       // 通道周期（斐波那契数）
input double  ATRMultiplier   = 1.618;    // ATR乘数（黄金比例）
input double  Lots            = 0.01;     // 交易手数
input int     StopLoss        = 250;      // 基础止损点数
input int     TakeProfit      = 800;      // 固定止盈点数
input double  MaxSpread       = 3.0;      // 最大允许点差
input double  DailyMaxLoss    = 500.0;    // 单日最大亏损
input int     MaxSlippage     = 5;        // 最大滑点
input int     MaxOrders       = 1;        // 最大持仓数
input string  TradingStart    = "06:00";  // 交易时段开始
input string  TradingEnd      = "05:00";  // 交易时段结束
input bool    EnableTrailing  = true;     // 启用移动止损
input int     MagicNumber     = 202308;   // 魔术码
input double  MinVolumeLevel  = 0.5;      // 最低成交量阈值（相对于近期均值）

//---- 全局变量 -----------------------------------------------------
double upperBand, lowerBand;
double pointCoefficient;
int atrHandle;
string tradeSymbol;
datetime lastBarTime;
double volumeMA;
double cachedSpread;  // 缓存点差
double cachedATR;     // 缓存ATR值

//+------------------------------------------------------------------+
//| 专家初始化函数                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    tradeSymbol = Symbol();
    pointCoefficient = CalculatePointCoefficient();
    atrHandle = iATR(tradeSymbol, PERIOD_CURRENT, 14);
    
    // 初始化通道
    if(!InitializeChannelObjects()) return INIT_FAILED;
    
    // 初始化成交量MA
    volumeMA = CalculateVolumeMA();
    if(volumeMA == 0) volumeMA = GetMinimalVolume();  // 容错处理
    
    return (atrHandle != INVALID_HANDLE) ? INIT_SUCCEEDED : INIT_FAILED;
}

double CalculatePointCoefficient()
{
    int digits = (int)SymbolInfoInteger(tradeSymbol, SYMBOL_DIGITS);
    return (digits == 3 || digits == 5) ? 10 * Point() : Point();
}

//+------------------------------------------------------------------+
//| Tick事件处理函数                                                 |
//+------------------------------------------------------------------+
void OnTick()
{
    static datetime lastAlert = 0;
    datetime currentBar = iTime(_Symbol, PERIOD_CURRENT, 0);
    
    // 更新缓存数据
    cachedSpread = SymbolInfoInteger(tradeSymbol, SYMBOL_SPREAD) * Point();
    cachedATR = GetATRValue();

    // 新K线处理
    if(currentBar != lastBarTime) {
        lastBarTime = currentBar;
        UpdateVolumeMA();
    }

    // 核心逻辑执行
    if(ExecuteChecks()) {
        MqlTick lastTick;
        if(SymbolInfoTick(tradeSymbol, lastTick)) {
            CalculateChannel();
            ManageOrders();
            CheckBreakoutSignals(lastTick);
        }
    }
    
    // 调试输出
    static int tickCount = 0;
    if(tickCount++ % 100 == 0) DebugOutput();
}

//+------------------------------------------------------------------+
//| 增强版通道计算函数                                               |
//+------------------------------------------------------------------+
void CalculateChannel() 
{
    if(cachedATR <= 0) return;

    double highs[], lows[];
    ArraySetAsSeries(highs, true);
    ArraySetAsSeries(lows, true);

    int copiedHighs = CopyHigh(tradeSymbol, PERIOD_CURRENT, 0, ChannelPeriod, highs);
    int copiedLows = CopyLow(tradeSymbol, PERIOD_CURRENT, 0, ChannelPeriod, lows);
    
    if(copiedHighs == ChannelPeriod && copiedLows == ChannelPeriod)
    {
        int maxIndex = ArrayMaximum(highs);
        int minIndex = ArrayMinimum(lows);
        double baseHigh = highs[maxIndex];
        double baseLow = lows[minIndex];
        
        // 动态通道调整
        double widthFactor = MathMax(0.5, MathMin(2.0, cachedATR/(50*Point())));
        upperBand = NormalizeDouble(baseHigh + ATRMultiplier * cachedATR * widthFactor, _Digits);
        lowerBand = NormalizeDouble(baseLow - ATRMultiplier * cachedATR * widthFactor, _Digits);
        
        UpdateChannelDisplay();
    }
}

//+------------------------------------------------------------------+
//| 优化后的风险检查                                                 |
//+------------------------------------------------------------------+
bool ExecuteChecks()
{
    // 基础检查
    if(!RiskCheck()) return false;
    if(!IsTradeTime(TradingStart, TradingEnd)) return false;  // 新增时段检查
    
    MqlTick last_tick;
    if(!SymbolInfoTick(tradeSymbol, last_tick)) return false;
    
    // 动态成交量检查
    if(last_tick.volume < volumeMA * MinVolumeLevel) {
        Print(StringFormat("成交量过滤 | 当前:%.2f 要求:%.2f", 
              last_tick.volume, volumeMA*MinVolumeLevel));
        return false;
    }
    
    return cachedSpread <= MaxSpread;
}

//+------------------------------------------------------------------+
//| 增强版移动平均计算                                               |
//+------------------------------------------------------------------+
void UpdateVolumeMA()
{
    double newMA = CalculateVolumeMA();
    if(newMA > 0) {
        volumeMA = 0.7*volumeMA + 0.3*newMA;
    } else {
        volumeMA *= 0.7;  // 衰减处理
    }
}

double CalculateVolumeMA()
{
    long volumes[];
    ArraySetAsSeries(volumes, true);
    int copied = CopyTickVolume(tradeSymbol, PERIOD_CURRENT, 0, 20, volumes);
    
    if(copied <= 0) return 0.0;
    
    // 安全访问数组
    int validSamples = MathMin(copied, 20);
    return NormalizeDouble(ArrayAverage(volumes, validSamples), 2);
}

double ArrayAverage(const long &arr[], int count)
{
    if(count <= 0) return 0.0;
    double sum = 0.0;  // 改为double防止溢出
    for(int i=0; i<count; i++) sum += (double)arr[i];
    return sum/count;
}

//+------------------------------------------------------------------+
//| 优化后的开仓函数                                                 |
//+------------------------------------------------------------------+
bool OpenPosition(ENUM_ORDER_TYPE orderType)
{
    CTrade trade;
    trade.SetDeviationInPoints(MaxSlippage);

    double price = (orderType == ORDER_TYPE_SELL) ? 
                   SymbolInfoDouble(tradeSymbol, SYMBOL_BID) : 
                   SymbolInfoDouble(tradeSymbol, SYMBOL_ASK);

    // 动态止损计算
    double atrPoints = cachedATR/Point();
    int dynamicSL = (int)MathMax(StopLoss, 1.5*atrPoints);
    
    double sl = (orderType == ORDER_TYPE_SELL) ? 
                upperBand + dynamicSL * pointCoefficient : 
                lowerBand - dynamicSL * pointCoefficient;

    double tp = (orderType == ORDER_TYPE_SELL) ? 
                lowerBand - TakeProfit * pointCoefficient : 
                upperBand + TakeProfit * pointCoefficient;

    bool success = trade.PositionOpen(
        tradeSymbol,
        orderType,
        Lots,
        price,
        NormalizePrice(sl),
        NormalizePrice(tp),
        "Smart Channel Strategy"
    );

    if(!success) PrintTradeError(trade);
    return success;
}

//+------------------------------------------------------------------+
//| 其他辅助函数保持不变，确保功能一致性                             |
//+------------------------------------------------------------------+

// ...（其余函数保持原有逻辑，重点优化重复调用和冗余计算部分）

double GetMinimalVolume()
{
    MqlTick tick;
    return SymbolInfoTick(tradeSymbol, tick) ? tick.volume : 1.0;
}

bool InitializeChannelObjects()
{
    if(!ObjectCreate(0,"UpperBand",OBJ_TREND,0,0,0)) return false;
    ObjectSetInteger(0,"UpperBand",OBJPROP_COLOR,clrRed);
    
    if(!ObjectCreate(0,"LowerBand",OBJ_TREND,0,0,0)) return false;
    ObjectSetInteger(0,"LowerBand",OBJPROP_COLOR,clrBlue);
    
    return true;
}