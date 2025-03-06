#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#property strict
#property copyright "WEN YUNJI"
#property version   "6.3"

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
double volumeMA;  // 成交量移动平均

//+------------------------------------------------------------------+
//| 专家初始化函数                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    tradeSymbol = Symbol();
    int digits = (int)SymbolInfoInteger(tradeSymbol, SYMBOL_DIGITS);
    pointCoefficient = (digits == 3 || digits == 5) ? 10 * Point() : Point();
    atrHandle = iATR(tradeSymbol, PERIOD_CURRENT, 14);
    
    // 初始化通道可视化
    ObjectCreate(0,"UpperBand",OBJ_TREND,0,0,0);
    ObjectSetInteger(0,"UpperBand",OBJPROP_COLOR,clrRed);
    ObjectCreate(0,"LowerBand",OBJ_TREND,0,0,0);
    ObjectSetInteger(0,"LowerBand",OBJPROP_COLOR,clrBlue);
    
    // 初始化成交量数据
    volumeMA = CalculateVolumeMA();
    
    return (atrHandle != INVALID_HANDLE) ? INIT_SUCCEEDED : INIT_FAILED;
}

//+------------------------------------------------------------------+
//| Tick事件处理函数                                                 |
//+------------------------------------------------------------------+
void OnTick()
{
    static datetime lastAlert = 0;
    datetime currentBar = iTime(_Symbol, PERIOD_CURRENT, 0);
    
    // 新K线验证
    if(currentBar != lastBarTime) {
        lastBarTime = currentBar;
        volumeMA = 0.7*volumeMA + 0.3*CalculateVolumeMA(); // 更新成交量MA
    }

    // 实时监控输出（每100tick）
    static int tickCount = 0;
    if(tickCount++ % 100 == 0) {
        DebugOutput();
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
}

//+------------------------------------------------------------------+
//| 增强版通道计算函数                                               |
//+------------------------------------------------------------------+
void CalculateChannel() 
{
    double atrValue = GetATRValue();
    if(atrValue <= 0) return;

    double highs[], lows[];
    ArraySetAsSeries(highs, true);
    ArraySetAsSeries(lows, true);

    // 获取历史数据（包含当前Bar）
    int copiedHighs = CopyHigh(tradeSymbol, PERIOD_CURRENT, 0, ChannelPeriod, highs);
    int copiedLows = CopyLow(tradeSymbol, PERIOD_CURRENT, 0, ChannelPeriod, lows);
    
    if(copiedHighs == ChannelPeriod && copiedLows == ChannelPeriod)
    {
        int maxIndex = ArrayMaximum(highs);
        int minIndex = ArrayMinimum(lows);
        double baseHigh = highs[maxIndex];
        double baseLow = lows[minIndex];
        
        // 数据有效性检查
        datetime newestTime = iTime(tradeSymbol, PERIOD_CURRENT, 0);
        if(TimeCurrent() - newestTime > PeriodSeconds(PERIOD_CURRENT)*2) return;
        
        // 动态通道调整
        double widthFactor = MathMax(0.5, MathMin(2.0, atrValue/(50*Point())));
        upperBand = NormalizeDouble(baseHigh + ATRMultiplier * atrValue * widthFactor, _Digits);
        lowerBand = NormalizeDouble(baseLow - ATRMultiplier * atrValue * widthFactor, _Digits);
        
        // 更新可视化
        UpdateChannelDisplay();
    }
}

//+------------------------------------------------------------------+
//| 智能信号检测函数                                                 |
//+------------------------------------------------------------------+
void CheckBreakoutSignals(const MqlTick &tick)
{
    if(PositionsTotal() >= MaxOrders) return;
    
    double atrValue = GetATRValue();
    if(atrValue <= 0) return;
    
    double activationRange = 0.25 * atrValue;  // ATR的25%作为激活区
    double bufferZone = 3 * Point();          // 3点缓冲带
    
    // 动态触发条件
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
//| 动态止损止盈开仓函数                                             |
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
        "Smart Channel Strategy"
    );

    if(!success){
        PrintTradeError(trade);
    }
    return success;
}

//+------------------------------------------------------------------+
//| 增强风控检查                                                     |
//+------------------------------------------------------------------+
bool ExecuteChecks()
{
    // 基础检查
    if(!RiskCheck()) return false;
    
    // 获取实时数据
    MqlTick last_tick;
    if(!SymbolInfoTick(tradeSymbol, last_tick)) return false;
    
    // 动态成交量检查
    double currentVol = last_tick.volume;
    if(currentVol < volumeMA * MinVolumeLevel) {
        Print(StringFormat("成交量过滤 | 当前:%.2f 要求:%.2f", currentVol, volumeMA*MinVolumeLevel));
        return false;
    }
    
    // 点差检查
    if(GetCurrentSpread() > MaxSpread) return false;
    
    return true;
}

//+------------------------------------------------------------------+
//| 辅助函数集                                                      |
//+------------------------------------------------------------------+
double CalculateVolumeMA()
{
    long volumes[];
    ArraySetAsSeries(volumes, true);
    int copied = CopyTickVolume(tradeSymbol, PERIOD_CURRENT, 0, 20, volumes);
    
    // 调试输出
    if(copied > 0){
        Print(StringFormat("成交量数据样本[0]:%d [5]:%d [19]:%d",
              volumes[0],volumes[5],volumes[19]));
    }
    
    return (copied > 0) ? NormalizeDouble(ArrayAverage(volumes, copied),2) : 0.0;
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

void DebugOutput()
{
    Print(StringFormat("[Debug] 时间:%s 上轨:%.5f 下轨:%.5f ATR:%.5f 成交量MA:%.2f",
          TimeToString(TimeCurrent()), upperBand, lowerBand, GetATRValue(), volumeMA));
}


//+------------------------------------------------------------------+
//| 风险检查函数（唯一实现）                                         |
//+------------------------------------------------------------------+
bool RiskCheck()
{
    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    double equity = AccountInfoDouble(ACCOUNT_EQUITY);
    
    if(equity < balance - DailyMaxLoss) 
    {
        CloseAllOrders();
        return false;
    }
    return (equity / MathMax(balance, 0.01)) >= 0.7 
           && TerminalInfoInteger(TERMINAL_CONNECTED);
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
//| 优化后的时间过滤函数                                             |
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




