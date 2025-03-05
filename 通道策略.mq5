
#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#property strict
#property copyright "WEN YUNJI"
#property version   "6.3"

//---- 输入参数 -----------------------------------------------------
input int     ChannelPeriod   = 20;       // 通道计算周期
input double  ATRMultiplier   = 2.0;      // ATR波动系数
input double  Lots            = 0.01;     // 交易手数
input int     StopLoss        = 400;      // 止损点数（基于Point计算）
input int     TakeProfit      = 800;      // 止盈点数
input double  MaxSpread       = 3.0;      // 允许的最大点差
input double  DailyMaxLoss    = 500.0;    // 单日最大亏损金额
input int     MaxSlippage     = 5;        // 最大滑点容忍度
input int     MaxOrders       = 1;        // 最大同时持仓订单数
input string  TradingStart    = "06:00";  // 交易时段开始时间
input string  TradingEnd      = "05:00";  // 交易时段结束时间（支持跨日）
input bool    EnableTrailing  = true;     // 启用移动止损
input int     MagicNumber     = 202308;   // 魔术码（订单标识）

//---- 全局变量 -----------------------------------------------------
double upperBand, lowerBand;              // 通道上下轨
double pointCoefficient;                  // 点值计算系数
int atrHandle;                            // ATR指标句柄
string tradeSymbol;                       // 交易品种
datetime lastBarTime;                     // 最后K线时间戳

//+------------------------------------------------------------------+
//| 专家初始化函数                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    tradeSymbol = Symbol();
    int digits = (int)SymbolInfoInteger(tradeSymbol, SYMBOL_DIGITS);
    pointCoefficient = (digits == 3 || digits == 5) ? 10 * Point() : Point();
    atrHandle = iATR(tradeSymbol, PERIOD_CURRENT, 14);
    return (atrHandle != INVALID_HANDLE) ? INIT_SUCCEEDED : INIT_FAILED;
}

//+------------------------------------------------------------------+
//| Tick事件处理函数                                                 |
//+------------------------------------------------------------------+
void OnTick()
{
    // 新K线验证机制
    datetime currentBar = iTime(_Symbol, PERIOD_CURRENT, 0);
    if(currentBar == lastBarTime) return;
    lastBarTime = currentBar;

    // 实时监控输出
    static int tickCount = 0;
    if(tickCount++ % 100 == 0){
        Print(StringFormat("通道状态 | 上轨:%.5f 下轨:%.5f 现价:%.5f",
            upperBand, lowerBand, SymbolInfoDouble(tradeSymbol,SYMBOL_BID)));
    }

    if(!RiskCheck() || !ExecuteChecks()) return;
    
    MqlTick lastTick;
    if(SymbolInfoTick(tradeSymbol, lastTick)){
        CalculateChannel();
        ManageOrders();
        CheckBreakoutSignals(lastTick);
    }
}

//+------------------------------------------------------------------+
//| 通道区间交易信号检测（关键修改）                                 |
//+------------------------------------------------------------------+
void CheckBreakoutSignals(const MqlTick &tick)
{
    if(PositionsTotal() >= MaxOrders) return;
    
    const double activationRatio = 0.2; // 激活范围比例（ATR的20%）
    double atrValue = GetATRValue();
    double activationRange = activationRatio * atrValue;
    
    double currentBid = tick.bid;
    double currentAsk = tick.ask;

    // 计算到通道边界的距离
    double upperDistance = upperBand - currentBid; // 当前价到上轨的距离
    double lowerDistance = currentAsk - lowerBand; // 当前价到下轨的距离

    // 上轨附近开空（价格在上轨下方1个ATR范围内）
    if(upperDistance > 0 && upperDistance < activationRange && !PositionExist(ORDER_TYPE_SELL)) 
    {
        Print(StringFormat("上轨附近开空 | 距离:%.5f ATR:%.5f", upperDistance, atrValue));
        OpenPosition(ORDER_TYPE_SELL);
    }
    // 下轨附近开多（价格在下轨上方1个ATR范围内）
    else if(lowerDistance > 0 && lowerDistance < activationRange && !PositionExist(ORDER_TYPE_BUY)) 
    {
        Print(StringFormat("下轨附近开多 | 距离:%.5f ATR:%.5f", lowerDistance, atrValue));
        OpenPosition(ORDER_TYPE_BUY);
    }
}

//+------------------------------------------------------------------+
//| 动态止损止盈设置（基于通道位置）                                 |
//+------------------------------------------------------------------+
bool OpenPosition(ENUM_ORDER_TYPE orderType)
{
    CTrade trade;
    trade.SetDeviationInPoints(MaxSlippage);

    double price = (orderType == ORDER_TYPE_SELL) ? 
                   SymbolInfoDouble(tradeSymbol, SYMBOL_BID) : 
                   SymbolInfoDouble(tradeSymbol, SYMBOL_ASK);

    // 动态止损止盈设置
    double sl = (orderType == ORDER_TYPE_SELL) ? 
                upperBand + StopLoss * pointCoefficient :  // 空单止损设在上轨上方
                lowerBand - StopLoss * pointCoefficient;   // 多单止损设在下轨下方

    double tp = (orderType == ORDER_TYPE_SELL) ? 
                lowerBand - TakeProfit * pointCoefficient : // 空单止盈设在下轨附近
                upperBand + TakeProfit * pointCoefficient;  // 多单止盈设在上轨附近

    bool success = trade.PositionOpen(
        tradeSymbol,
        orderType,
        Lots,
        price,
        NormalizePrice(sl),
        NormalizePrice(tp),
        "Channel Range Trading"
    );

    if(!success){
        // 增强错误处理
        int errorCode = trade.ResultRetcode();
        Print("开单失败:",errorCode," ",trade.ResultRetcodeDescription());
        
        // 特定错误处理
        if(errorCode == 10014) { // ERR_TRADE_INVALID_STOPS
            Print("建议调整止损点数，当前参数：",
                  "StopLoss=",StopLoss," (",StopLoss*pointCoefficient,"点) ",
                  "通道范围:",upperBand,"-",lowerBand);
        }
    }
    return success;
}

//+------------------------------------------------------------------+
//| 增强版通道计算（带有效性检查）                                   |
//+------------------------------------------------------------------+
void CalculateChannel() 
{
    double atrValue = GetATRValue();
    if(atrValue <= 0) {
        Print("ATR值无效:",atrValue);
        return;
    }

    double highs[], lows[];
    ArraySetAsSeries(highs, true);
    ArraySetAsSeries(lows, true);

    int copiedHighs = CopyHigh(tradeSymbol, PERIOD_CURRENT, 1, ChannelPeriod, highs);
    int copiedLows = CopyLow(tradeSymbol, PERIOD_CURRENT, 1, ChannelPeriod, lows);
    
    if(copiedHighs == ChannelPeriod && copiedLows == ChannelPeriod)
    {
        double baseHigh = highs[ArrayMaximum(highs)];
        double baseLow = lows[ArrayMinimum(lows)];
        
        // 验证价格合理性
        if(baseHigh <= baseLow || baseHigh <= 0 || baseLow <= 0) {
            Print("通道计算异常 High:",baseHigh," Low:",baseLow);
            return;
        }
        
        upperBand = NormalizeDouble(baseHigh + ATRMultiplier * atrValue, _Digits);
        lowerBand = NormalizeDouble(baseLow - ATRMultiplier * atrValue, _Digits);
        
        // 更新通道可视化
        ObjectMove(0,"UpperBand",0,TimeCurrent(),upperBand);
        ObjectMove(0,"LowerBand",0,TimeCurrent(),lowerBand);
    }
    else {
        Print("历史数据获取失败 Highs:",copiedHighs," Lows:",copiedLows);
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
//| 移动止损函数（唯一实现）                                         |
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
//| 其他保持不变的函数                                               |
//+------------------------------------------------------------------+
bool ExecuteChecks()
{
    return Bars(_Symbol, PERIOD_CURRENT) >= ChannelPeriod+10 && 
           IsTradeTime(TradingStart, TradingEnd) && 
           GetCurrentSpread() <= MaxSpread;
}

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

bool IsTradeTime(string start, string end)
{
    datetime st = StringToTime(start), ed = StringToTime(end), now = TimeCurrent();
    return (st < ed) ? (now >= st && now < ed) : (now >= st || now < ed);
}