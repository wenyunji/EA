#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

#property copyright "WEN YUNJI"
#property version   "6.6.1"  // 版本升级

//---- 输入参数 -----------------------------------------------------
input int     ChannelPeriod   = 34;       // 通道周期（斐波那契数）
input double  ATRMultiplier   = 1.618;    // ATR乘数（黄金比例）
input double  Lots            = 0.01;     // 交易手数
input int     StopLoss        = 250;      // 基础止损点数
input int     TakeProfit      = 800;      // 固定止盈点数
input double  MaxSpread       = 4.0;      // 最大允许点差
input double  DailyMaxLoss    = 500.0;    // 单日最大亏损
input int     MaxSlippage     = 5;        // 最大滑点
input int     MaxOrders       = 1;        // 最大持仓数
input string  TradingStart    = "06:00";  // 交易时段开始
input string  TradingEnd      = "05:00";  // 交易时段结束
input bool    EnableTrailing  = true;     // 启用移动止损
input int     MagicNumber     = 202308;   // 魔术码
input double  MinVolumeLevel  = 0.35;     // 成交量阈值
input bool    UseBarVolume    = true;     // 使用K线成交量（新增参数）

//---- 全局变量 -----------------------------------------------------
double upperBand, lowerBand;
double pointCoefficient;
int atrHandle;
string tradeSymbol;
datetime lastBarTime;
double volumeMA;

//+------------------------------------------------------------------+
//| 检查结果枚举类型                                                 |
//+------------------------------------------------------------------+
enum CHECK_RESULT {
    CHECK_PASS = 0,
    CHECK_RISK_FAIL,
    CHECK_TICK_FAIL,
    CHECK_VOLUME_FAIL,
    CHECK_SPREAD_FAIL,
    CHECK_TIME_FAIL
};

//+------------------------------------------------------------------+
//| 专家初始化函数                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    // 网络连接检查
    if(!TerminalInfoInteger(TERMINAL_CONNECTED)) {
        Alert("网络连接异常：请检查互联网连接");
        return INIT_FAILED;
    }

    tradeSymbol = Symbol();
    int digits = (int)SymbolInfoInteger(tradeSymbol, SYMBOL_DIGITS);
    pointCoefficient = (digits == 3 || digits == 5) ? 10 * Point() : Point();
    
    // ATR指标初始化
    atrHandle = iATR(tradeSymbol, PERIOD_CURRENT, 14);
    if(atrHandle == INVALID_HANDLE) {
        Alert("ATR指标初始化失败");
        return INIT_FAILED;
    }

    // 可视化通道初始化
    ObjectCreate(0,"UpperBand",OBJ_TREND,0,0,0);
    ObjectSetInteger(0,"UpperBand",OBJPROP_COLOR,clrRed);
    ObjectCreate(0,"LowerBand",OBJ_TREND,0,0,0);
    ObjectSetInteger(0,"LowerBand",OBJPROP_COLOR,clrBlue);

    // 成交量数据初始化
    volumeMA = CalculateVolumeMA();
    if(volumeMA <= 0) {
        volumeMA = GetDefaultVolume();
        Print("使用默认成交量MA值:",volumeMA);
    }
    
    Print("EA初始化成功");
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| 成交量MA计算函数（已修复）                                       |
//+------------------------------------------------------------------+
double CalculateVolumeMA()
{
    long volumes[];
    int copied = 0;
    
    if(UseBarVolume) {
        // 使用K线成交量（回测兼容）
        copied = CopyRealVolume(tradeSymbol, PERIOD_CURRENT, 0, 20, volumes);
    } else {
        // 使用Tick成交量（实时交易）
        copied = CopyTickVolume(tradeSymbol, PERIOD_CURRENT, COPY_TICKS_ALL, 0, 20, volumes);
    }

    if(copied <= 0) {
        Print("成交量数据获取失败，使用最后有效值");
        return volumeMA > 0 ? volumeMA : GetDefaultVolume();
    }

    // 数据有效性过滤
    double sum = 0.0;
    int validCount = 0;
    for(int i=0; i<copied; i++) {
        if(volumes[i] > 0) {
            sum += (double)volumes[i];
            validCount++;
        }
    }
    
    if(validCount == 0) {
        Print("警告：全部成交量数据异常");
        return volumeMA > 0 ? volumeMA : GetDefaultVolume();
    }
    
    return NormalizeDouble(sum / validCount, 2);
}

//+------------------------------------------------------------------+
//| 增强风控检查函数（已修复参数）                                   |
//+------------------------------------------------------------------+
CHECK_RESULT ExecuteChecks() 
{
    // 时间过滤检查
    if(!IsTradeTime(TradingStart, TradingEnd)) {
        return CHECK_TIME_FAIL;
    }

    if(!RiskCheck()) return CHECK_RISK_FAIL;
    
    MqlTick last_tick;
    if(!SymbolInfoTick(tradeSymbol, last_tick)) {
        Print("实时报价获取失败");
        return CHECK_TICK_FAIL;
    }
    
    // 成交量检查（修正版）
    double currentVol = 0.0;
    double requiredVolume = volumeMA * MinVolumeLevel;
    
    if(UseBarVolume) {
        // 使用当前K线成交量
        MqlRates rates[];
        if(CopyRates(tradeSymbol, PERIOD_CURRENT, 0, 1, rates) == 1) {
            currentVol = (double)rates[0].tick_volume;
        }
    } else {
        // 使用Tick成交量
        currentVol = (double)last_tick.volume;
    }

    if(currentVol < requiredVolume) {
        Print(StringFormat("成交量过滤 | 模式:%s 当前:%.1f < 要求:%.1f (MA %.1f * %.2f)", 
              UseBarVolume?"K线":"Tick", currentVol, requiredVolume, volumeMA, MinVolumeLevel));
        return CHECK_VOLUME_FAIL;
    }
    
    // 点差检查
    double currentSpread = GetCurrentSpread();
    if(currentSpread > MaxSpread) {
        Print(StringFormat("点差过滤 | 当前:%.1f > 限制:%.1f", currentSpread, MaxSpread));
        return CHECK_SPREAD_FAIL;
    }
    
    return CHECK_PASS;
}

// ...（其他函数保持与之前提供的完整代码一致，包括：RiskCheck、CalculateChannel、CheckBreakoutSignals、OpenPosition、DebugOutput等所有函数）...

// 确保包含所有辅助函数实现：
// - GetDefaultVolume
// - IsTradeTime
// - ArrayAverage
// - UpdateChannelDisplay
// - PrintTradeError
// - PositionExist
// - TrailStopLoss
// - ManageOrders
// - CloseAllOrders
// - GetATRValue
// - NormalizePrice
// - GetCurrentSpread

//+------------------------------------------------------------------+
//| 成交量MA计算函数（完整修正版）                                   |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| 获取品种典型成交量值                                             |
//+------------------------------------------------------------------+
double GetDefaultVolume()
{
    // 主要品种的典型成交量基准值
    string symbol = Symbol();
    if(StringFind(symbol, "XAUUSD") != -1) return 1000.0;
    if(StringFind(symbol, "EURUSD") != -1) return 100000.0;
    if(StringFind(symbol, "GBPUSD") != -1) return 80000.0;
    return 50000.0; // 默认值
}

//+------------------------------------------------------------------+
//| 时间过滤函数（完整实现）                                         |
//+------------------------------------------------------------------+
bool IsTradeTime(string start, string end)
{
    datetime now = TimeCurrent();
    datetime st = StringToTime(start);
    datetime ed = StringToTime(end);
    
    // 处理跨日情况
    if(st >= ed) ed += 86400;
    
    datetime nowTime = now % 86400;
    st = st % 86400;
    ed = ed % 86400;

    if(ed > st) {
        return (nowTime >= st) && (nowTime < ed);
    } else {
        return (nowTime >= st) || (nowTime < ed);
    }
}


//+------------------------------------------------------------------+
//| 智能风控检查（详细日志版）                                       |
//+------------------------------------------------------------------+
bool RiskCheck()
{
    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    double equity = AccountInfoDouble(ACCOUNT_EQUITY);
    bool isConnected = TerminalInfoInteger(TERMINAL_CONNECTED);

    // 净值比例计算
    double equityRatio = (balance > 0.01) ? equity / balance : 0;
    
    // 调试日志
    Print(StringFormat("风控状态 | 净值比:%.1f%% 连接:%d", equityRatio*100, isConnected));

    if(equity < (balance - DailyMaxLoss)) {
        Print(StringFormat("单日亏损限额触发 | 已亏损:%.1f", balance - equity));
        CloseAllOrders();
        return false;
    }
    
    if(equityRatio < 0.7) {
        Print(StringFormat("净值保护触发 | 当前:%.1f%% < 70%%", equityRatio*100));
        return false;
    }
    
    if(!isConnected) {
        Print("交易终端离线");
        return false;
    }
    
    return true;
}


//+------------------------------------------------------------------+
//| 通道计算函数                                                     |
//+------------------------------------------------------------------+
void CalculateChannel() 
{
    double atrValue = GetATRValue();
    if(atrValue <= 0) return;

    double highs[], lows[];
    ArraySetAsSeries(highs, true);
    ArraySetAsSeries(lows, true);

    int copiedHighs = CopyHigh(tradeSymbol, PERIOD_CURRENT, 0, ChannelPeriod, highs);
    int copiedLows = CopyLow(tradeSymbol, PERIOD_CURRENT, 0, ChannelPeriod, lows);
    
    if(copiedHighs == ChannelPeriod && copiedLows == ChannelPeriod)
    {
        int maxIndex = ArrayMaximum(highs);
        int minIndex = ArrayMinimum(lows);
        
        // 数据时效性检查
        datetime newestTime = iTime(tradeSymbol, PERIOD_CURRENT, 0);
        if(TimeCurrent() - newestTime > PeriodSeconds(PERIOD_CURRENT)*2) {
            Print("通道数据过期");
            return;
        }
        
        // 动态通道计算
        double widthFactor = MathMax(0.5, MathMin(2.0, atrValue/(50*Point())));
        upperBand = NormalizeDouble(highs[maxIndex] + ATRMultiplier * atrValue * widthFactor, _Digits);
        lowerBand = NormalizeDouble(lows[minIndex] - ATRMultiplier * atrValue * widthFactor, _Digits);
        
        // 更新通道显示
        UpdateChannelDisplay();
    }
}

//+------------------------------------------------------------------+
//| 信号检测函数                                                     |
//+------------------------------------------------------------------+
void CheckBreakoutSignals(const MqlTick &tick)
{
    if(PositionsTotal() >= MaxOrders) return;
    
    double atrValue = GetATRValue();
    if(atrValue <= 0) return;
    
    double activationRange = 0.25 * atrValue;
    double bufferZone = 3 * Point();
    
    bool sellCondition = tick.bid > (upperBand - activationRange) && 
                       tick.bid < (upperBand + bufferZone);
    bool buyCondition = tick.ask < (lowerBand + activationRange) && 
                      tick.ask > (lowerBand - bufferZone);

    if(sellCondition && !PositionExist(ORDER_TYPE_SELL)) {
        OpenPosition(ORDER_TYPE_SELL);
    }
    else if(buyCondition && !PositionExist(ORDER_TYPE_BUY)) {
        OpenPosition(ORDER_TYPE_BUY);
    }
}

//+------------------------------------------------------------------+
//| 开仓函数（增强版）                                               |
//+------------------------------------------------------------------+
bool OpenPosition(ENUM_ORDER_TYPE orderType)
{
    CTrade trade;
    trade.SetDeviationInPoints(MaxSlippage);

    double price = (orderType == ORDER_TYPE_SELL) ? 
                   SymbolInfoDouble(tradeSymbol, SYMBOL_BID) : 
                   SymbolInfoDouble(tradeSymbol, SYMBOL_ASK);

    // 动态止损计算
    double atrValue = GetATRValue();
    double dynamicSL = MathMax(StopLoss, (int)(1.5*atrValue/Point()));
    
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
        "智能通道策略"
    );

    if(!success){
        PrintTradeError(trade);
    }
    return success;
}

//+------------------------------------------------------------------+
//| 调试信息输出                                                     |
//+------------------------------------------------------------------+
void DebugOutput()
{
    Print(StringFormat("[监控] 点差:%.1f ATR:%.3f 通道[%.5f/%.5f] 成交量MA:%.1f",
          GetCurrentSpread(), GetATRValue(),
          upperBand, lowerBand, volumeMA));
}


double ArrayAverage(const long &arr[], int count)
{
    if(count <= 0) return 0.0;
    long sum = 0;
    for(int i=0; i<count; i++) sum += arr[i];
    return (double)sum/count;
}

void UpdateChannelDisplay()
{
    ObjectMove(0,"UpperBand",0,TimeCurrent(),upperBand);
    ObjectMove(0,"LowerBand",0,TimeCurrent(),lowerBand);
    Comment(StringFormat("Upper: %.5f\nLower: %.5f\nATR: %.5f\n成交量MA: %.2f", 
             upperBand, lowerBand, GetATRValue(), volumeMA));
}

void PrintTradeError(CTrade &trade)
{
    int errorCode = trade.ResultRetcode();
    string errorDesc = trade.ResultRetcodeDescription();
    Print("开单失败 ",errorCode,":",errorDesc);
    if(errorCode == 10014) {
        Print("建议调整止损点数，当前计算值：",StopLoss," (",StopLoss*pointCoefficient,"点)");
    }
}


//+------------------------------------------------------------------+
//| 持仓检查函数（精准版）                                           |
//+------------------------------------------------------------------+
bool PositionExist(ENUM_ORDER_TYPE checkType)
{
    for(int i = PositionsTotal()-1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket) && 
           PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
           PositionGetString(POSITION_SYMBOL) == tradeSymbol &&
           PositionGetInteger(POSITION_TYPE) == checkType)
        {
            return true;
        }
    }
    return false;
}


//+------------------------------------------------------------------+
//| 移动止损函数                       |
//+------------------------------------------------------------------+
void TrailStopLoss(ulong ticket)
{
    CTrade trade;
    trade.SetDeviationInPoints(MaxSlippage);
    
    if(!PositionSelectByTicket(ticket)) return;
    
    ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    double currentPrice = type == POSITION_TYPE_BUY ? SymbolInfoDouble(tradeSymbol, SYMBOL_BID) 
                                                    : SymbolInfoDouble(tradeSymbol, SYMBOL_ASK);
    double newStop = type == POSITION_TYPE_BUY 
        ? currentPrice - StopLoss*pointCoefficient 
        : currentPrice + StopLoss*pointCoefficient;

    if(MathAbs(newStop - PositionGetDouble(POSITION_SL)) > Point()/2)
    {
        trade.PositionModify(ticket, newStop, PositionGetDouble(POSITION_TP));
    }
}

//+------------------------------------------------------------------+
//| 订单管理函数                                            |
//+------------------------------------------------------------------+
void ManageOrders()
{
    for(int i=PositionsTotal()-1; i>=0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket) && 
           PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
           PositionGetString(POSITION_SYMBOL) == tradeSymbol)
        {
            if(EnableTrailing) TrailStopLoss(ticket);
        }
    }
}

void CloseAllOrders()
{
    CTrade trade;
    for(int i=PositionsTotal()-1; i>=0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket) && 
           PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
           PositionGetString(POSITION_SYMBOL) == tradeSymbol)
        {
            trade.PositionClose(ticket);
        }
    }
}

double GetATRValue()
{
    double atrBuffer[1];
    return CopyBuffer(atrHandle, 0, 0, 1, atrBuffer) == 1 ? atrBuffer[0] : 0.0;
}

double NormalizePrice(double price) 
{
    return NormalizeDouble(price, (int)SymbolInfoInteger(tradeSymbol, SYMBOL_DIGITS));
}

double GetCurrentSpread()
{
    return SymbolInfoInteger(tradeSymbol, SYMBOL_SPREAD) * Point();
}




