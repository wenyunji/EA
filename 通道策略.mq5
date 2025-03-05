#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#property strict
#property copyright "WEN YUNJI"
#property version   "6.3"

//---- 输入参数 -----------------------------------------------------
input int     ChannelPeriod   = 34;       // 改为斐波那契数（原20）
input double  ATRMultiplier   = 1.618;    // 黄金比例系数（原2.0）
input double  Lots            = 0.01;    
input int     StopLoss        = 250;      // 优化后的参数（原400）
input int     TakeProfit      = 800;     
input double  MaxSpread       = 3.0;     
input double  DailyMaxLoss    = 500.0;   
input int     MaxSlippage     = 5;       
input int     MaxOrders       = 1;       
input string  TradingStart    = "06:00"; 
input string  TradingEnd      = "05:00"; 
input bool    EnableTrailing  = true;    
input int     MagicNumber     = 202308;  

//---- 全局变量 -----------------------------------------------------
double upperBand, lowerBand;             
double pointCoefficient;                 
int atrHandle;                           
string tradeSymbol;                      
datetime lastBarTime;                    

//+------------------------------------------------------------------+
//| 专家初始化函数                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    tradeSymbol = Symbol();
    int digits = (int)SymbolInfoInteger(tradeSymbol, SYMBOL_DIGITS);
    pointCoefficient = (digits == 3 || digits == 5) ? 10 * Point() : Point();
    atrHandle = iATR(tradeSymbol, PERIOD_CURRENT, 14);
    
    // 创建通道可视化对象
    ObjectCreate(0,"UpperBand",OBJ_TREND,0,0,0);
    ObjectSetInteger(0,"UpperBand",OBJPROP_COLOR,clrRed);
    ObjectCreate(0,"LowerBand",OBJ_TREND,0,0,0);
    ObjectSetInteger(0,"LowerBand",OBJPROP_COLOR,clrBlue);
    
    return (atrHandle != INVALID_HANDLE) ? INIT_SUCCEEDED : INIT_FAILED;
}

//+------------------------------------------------------------------+
//| Tick事件处理函数                                                 |
//+------------------------------------------------------------------+
void OnTick()
{
    datetime currentBar = iTime(_Symbol, PERIOD_CURRENT, 0);
    if(currentBar == lastBarTime) return;
    lastBarTime = currentBar;

    static int tickCount = 0;
    if(tickCount++ % 100 == 0){
        Print(StringFormat("通道状态 | 上轨:%.5f 下轨:%.5f 现价:%.5f",
            upperBand, lowerBand, SymbolInfoDouble(tradeSymbol,SYMBOL_BID)));
    }

    // 新增报价验证
    if(SymbolInfoDouble(_Symbol,SYMBOL_BID)==0 || SymbolInfoDouble(_Symbol,SYMBOL_ASK)==0){
        Print("无效报价数据，跳过处理");
        return;
    }

    if(!RiskCheck() || !ExecuteChecks()) return;
    
    MqlTick lastTick;
    if(SymbolInfoTick(tradeSymbol, lastTick)){
        CalculateChannel();
        ManageOrders();
        CheckBreakoutSignals(lastTick);
        
        // 新增图表注释
        Comment(StringFormat("Upper: %.5f\nLower: %.5f\nATR: %.5f", 
                 upperBand, lowerBand, GetATRValue()));
    }
}

//+------------------------------------------------------------------+
//| 优化后的通道计算函数                                             |
//+------------------------------------------------------------------+
void CalculateChannel() 
{
    double atrValue = GetATRValue();
    if(atrValue <= 0) return;

    double highs[], lows[];
    ArraySetAsSeries(highs, true);
    ArraySetAsSeries(lows, true);

    // 修正数据获取方式（从当前Bar开始获取）
    int copiedHighs = CopyHigh(tradeSymbol, PERIOD_CURRENT, 0, ChannelPeriod, highs);
    int copiedLows = CopyLow(tradeSymbol, PERIOD_CURRENT, 0, ChannelPeriod, lows);
    
    if(copiedHighs == ChannelPeriod && copiedLows == ChannelPeriod)
    {
        int maxIndex = ArrayMaximum(highs);
        int minIndex = ArrayMinimum(lows);
        double baseHigh = highs[maxIndex];
        double baseLow = lows[minIndex];
        
        // 新增时间有效性验证
        datetime newestTime = iTime(tradeSymbol, PERIOD_CURRENT, 0);
        if(TimeCurrent() - newestTime > PeriodSeconds(PERIOD_CURRENT)*2){
            Print("通道数据过期！最新时间:",TimeToString(newestTime));
            return;
        }

        // 新增通道宽度过滤
        if(baseHigh - baseLow < atrValue*0.5){
            Print("通道宽度不足 ATR:",atrValue," 通道宽度:",baseHigh-baseLow);
            return;
        }
        
        upperBand = NormalizeDouble(baseHigh + ATRMultiplier * atrValue, _Digits);
        lowerBand = NormalizeDouble(baseLow - ATRMultiplier * atrValue, _Digits);
        
        // 增强可视化更新
        ObjectMove(0,"UpperBand",0,TimeCurrent(),upperBand);
        ObjectMove(0,"LowerBand",0,TimeCurrent(),lowerBand);
    }
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
//| 优化后的信号检测函数                                             |
//+------------------------------------------------------------------+
void CheckBreakoutSignals(const MqlTick &tick)
{
    if(PositionsTotal() >= MaxOrders) return;
    
    const double activationRatio = 0.25; // 从0.2放宽到25%
    double atrValue = GetATRValue();
    if(atrValue <= 0) return;
    
    double activationRange = activationRatio * atrValue;
    double currentBid = tick.bid;
    double currentAsk = tick.ask;

    // 优化后的触发条件
    bool sellCondition = (upperBand - currentBid) > 0 && 
                        (upperBand - currentBid) <= activationRange;
    bool buyCondition = (currentAsk - lowerBand) > 0 && 
                       (currentAsk - lowerBand) <= activationRange;

    if(sellCondition && !PositionExist(ORDER_TYPE_SELL)) 
    {
        Print(StringFormat("触发空单 | 距离:%.5f ATR:%.5f", upperBand-currentBid, atrValue));
        OpenPosition(ORDER_TYPE_SELL);
    }
    else if(buyCondition && !PositionExist(ORDER_TYPE_BUY)) 
    {
        Print(StringFormat("触发多单 | 距离:%.5f ATR:%.5f", currentAsk-lowerBand, atrValue));
        OpenPosition(ORDER_TYPE_BUY);
    }
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

    // 动态止损计算（基于ATR）
    double atrValue = GetATRValue();
    double dynamicSL = MathMax(StopLoss, (int)(atrValue/Point()));

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
        "Optimized Channel Strategy"
    );

    if(!success){
        int errorCode = trade.ResultRetcode();
        Print("开单失败:",errorCode," ",trade.ResultRetcodeDescription());
    }
    return success;
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
//| 增强版风控检查                                                   |
//+------------------------------------------------------------------+
bool ExecuteChecks()
{
    // 新增成交量过滤
    long volume = SymbolInfoInteger(tradeSymbol, SYMBOL_VOLUME);
    if(volume < 1000) {
        Print("成交量过低:",volume);
        return false;
    }
    
    return Bars(_Symbol, PERIOD_CURRENT) >= ChannelPeriod*2 && 
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




