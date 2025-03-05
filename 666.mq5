#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#property strict
#property copyright "WEN YUNJI"
#property version   "6.3"

//---- 输入参数 -----------------------------------------------------
input int     ChannelPeriod   = 20;       // 计算周期
input double  ATRMultiplier   = 2.0;      // 波动系数
input double  Lots            = 0.01;     // 交易手数
input int     StopLoss        = 400;      // 止损点数
input int     TakeProfit      = 800;      // 止盈点数
input double  MaxSpread       = 3.0;      // 最大点差
input double  DailyMaxLoss    = 500.0;    // 单日最大亏损
input int     MaxSlippage     = 5;        // 最大滑点
input int     MaxOrders       = 1;        // 最大订单数
input string  TradingStart    = "06:00";  
input string  TradingEnd      = "05:00";  
input bool    EnableTrailing  = true;     
input int     MagicNumber     = 202308;   

//---- 全局变量 -----------------------------------------------------
double upperBand, lowerBand, pointCoefficient, dailyLoss;
int atrHandle;
string tradeSymbol;
datetime lastBarTime;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    tradeSymbol = Symbol();
    dailyLoss = 0;
    int digits = (int)SymbolInfoInteger(tradeSymbol, SYMBOL_DIGITS);
    pointCoefficient = (digits == 3 || digits == 5) ? 10 * Point() : Point();
    atrHandle = iATR(tradeSymbol, PERIOD_CURRENT, 14);
    return atrHandle != INVALID_HANDLE ? INIT_SUCCEEDED : INIT_FAILED;
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    if(iTime(_Symbol, PERIOD_CURRENT, 0) == lastBarTime) return;
    lastBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
    if(!RiskCheck() || !ExecuteChecks()) return;
    MqlTick lastTick;
    if(SymbolInfoTick(tradeSymbol, lastTick)){
        CalculateChannel();
        ManageOrders();
        CheckBreakoutSignals(lastTick); // 需要实现该函数
    }
}

//+------------------------------------------------------------------+
//| 通道计算函数                                                     |
//+------------------------------------------------------------------+
void CalculateChannel() 
{
    static datetime lastCalcTime = 0;
    datetime currentTime = iTime(_Symbol, PERIOD_CURRENT, 0);
    if(currentTime == lastCalcTime) return;
    lastCalcTime = currentTime;

    double atrValue = GetATRValue();
    double highs[], lows[];
    ArraySetAsSeries(highs, true);
    ArraySetAsSeries(lows, true);

    if(CopyHigh(tradeSymbol, PERIOD_CURRENT, 1, ChannelPeriod, highs) > 0 && 
       CopyLow(tradeSymbol, PERIOD_CURRENT, 1, ChannelPeriod, lows) > 0)
    {
        double baseHigh = highs[ArrayMaximum(highs)];
        double baseLow = lows[ArrayMinimum(lows)];
        
        upperBand = NormalizeDouble(baseHigh + ATRMultiplier * atrValue, _Digits);
        lowerBand = NormalizeDouble(baseLow - ATRMultiplier * atrValue, _Digits);
    }
}

//+------------------------------------------------------------------+
//| 风险检查函数                                                     |
//+------------------------------------------------------------------+
bool RiskCheck()
{
    return AccountInfoDouble(ACCOUNT_EQUITY)/MathMax(AccountInfoDouble(ACCOUNT_BALANCE),0.01) >= 0.7 
           && TerminalInfoInteger(TERMINAL_CONNECTED);
}

//+------------------------------------------------------------------+
//| 执行检查函数                                                     |
//+------------------------------------------------------------------+
bool ExecuteChecks()
{
    return Bars(_Symbol, PERIOD_CURRENT) >= ChannelPeriod+10 && 
           IsTradeTime(TradingStart, TradingEnd) && 
           GetCurrentSpread() <= MaxSpread;
}

//+------------------------------------------------------------------+
//| 订单管理函数                                                     |
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


//+------------------------------------------------------------------+
//| 移动止损函数                                                     |
//+------------------------------------------------------------------+
void TrailStopLoss(ulong ticket)
{
    CTrade trade;  // 声明在函数内部
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
//| 关闭所有订单函数                                                 |
//+------------------------------------------------------------------+
void CloseAllOrders()
{
    CTrade trade;  // 声明在函数内部
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

// 检查是否已有同方向持仓
if(PositionExist(orderType)) return;

// 辅助函数
bool PositionExist(ENUM_ORDER_TYPE checkType)
{
    for(int i=PositionsTotal()-1; i>=0; i--)
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
//| 突破信号检测函数                                                 |
//+------------------------------------------------------------------+
void CheckBreakoutSignals(const MqlTick &tick)
{
    // 检测当前持仓数量
    if(PositionsTotal() >= MaxOrders) return;

    // 获取当前价格
    double currentBid = tick.bid;
    double currentAsk = tick.ask;

    // 突破上轨做多
    if(currentAsk > upperBand + 0.5 * _Point)
    {
        OpenPosition(ORDER_TYPE_BUY);
    }
    // 突破下轨做空
    else if(currentBid < lowerBand + 0.5 * _Point)
    {
        OpenPosition(ORDER_TYPE_SELL);
    }
}

//+------------------------------------------------------------------+
//| 开仓函数                                                         |
//+------------------------------------------------------------------+
bool OpenPosition(ENUM_ORDER_TYPE orderType)
{
    CTrade trade;
    double price      = (orderType == ORDER_TYPE_BUY) ? SymbolInfoDouble(tradeSymbol, SYMBOL_ASK) 
                                                     : SymbolInfoDouble(tradeSymbol, SYMBOL_BID);
    double slPrice    = (orderType == ORDER_TYPE_BUY) ? price - StopLoss * pointCoefficient 
                                                     : price + StopLoss * pointCoefficient;
    double tpPrice    = (orderType == ORDER_TYPE_BUY) ? price + TakeProfit * pointCoefficient 
                                                     : price - TakeProfit * pointCoefficient;

    // 执行交易
    bool success = trade.PositionOpen(
        tradeSymbol,                    // 交易品种
        orderType,                      // 方向
        Lots,                           // 手数
        price,                          // 开仓价
        NormalizePrice(slPrice),        // 止损价
        NormalizePrice(tpPrice),        // 止盈价
        "ChannelBreakout Strategy"      // 注释
    );

    // 错误处理
    if(!success)
    {
        Print("Order failed: ", trade.ResultRetcodeDescription());
    }
    return success;
}

//+------------------------------------------------------------------+
//| 辅助函数                                                         |
//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
//| 交易时间检查函数                                                 |
//+------------------------------------------------------------------+
bool IsTradeTime(string start, string end)
{
    datetime st = StringToTime(start), ed = StringToTime(end), now = TimeCurrent();
    return (st < ed) ? (now >= st && now < ed) : (now >= st || now < ed);
}
