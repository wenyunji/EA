#property copyright "TONGYI Lingma"
#property version   "6.2"  // 终极稳定版
#property strict
#property show_inputs

//---- 通道参数
input int     ChannelPeriod   = 20;       // 计算周期(20-50)
input double  ATRMultiplier   = 2.0;      // 波动系数(0.5-3.0)

//---- 风险参数  
input double  Lots            = 0.01;     // 交易手数
input int     StopLoss        = 400;      // 止损点数(50-1000)
input int     TakeProfit      = 800;      // 止盈点数
input double  MaxSpread       = 3.0;      // 最大点差
input double  DailyMaxLoss    = 500.0;    // 单日最大亏损(USD)

//---- 执行参数
input int     MaxSlippage     = 5;        // 最大滑点
input int     MaxOrders       = 1;        // 最大订单数
input string  ExpirationDate  = "2028-12-31"; // 挂单有效期
input string  TradingStart    = "06:00";  // 交易时段开始
input string  TradingEnd      = "05:00";  // 交易时段结束
input bool    EnableTrailing  = true;     // 启用移动止损

//---- 系统参数
input int     MagicNumber     = 202308;   // 订单魔数

//---- 全局变量
double upperBand, lowerBand, pointCoefficient, dailyLoss;
int atrHandle;
string tradeSymbol;
datetime lastBarTime;

//+------------------------------------------------------------------+
//| 专家初始化函数                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    tradeSymbol = Symbol();
    dailyLoss = 0;
    
    // 参数验证
    if(Lots <= 0 || StopLoss <= 0 || TakeProfit <= 0){
        Alert("参数错误：手数/止损/止盈必须>0");
        return(INIT_FAILED);
    }
    
    if(!IsTradeAllowed()) {
        Alert("自动交易未启用!");
        return(INIT_FAILED);
    }
    
    // 品种校验
    string baseCurrency = SymbolInfoString(tradeSymbol, SYMBOL_CURRENCY_BASE);
    string quoteCurrency = SymbolInfoString(tradeSymbol, SYMBOL_CURRENCY_PROFIT);
    if((baseCurrency != "XAU" || quoteCurrency != "USD") && 
       (baseCurrency != "EUR" || quoteCurrency != "USD")){
        Alert("仅支持XAUUSD/EURUSD");
        return(INIT_FAILED);
    }
    
    // 报价处理
    int digits = (int)SymbolInfoInteger(tradeSymbol, SYMBOL_DIGITS);
    pointCoefficient = (digits == 3 || digits == 5) ? 10 * Point() : Point();
    
    // 初始化ATR指标
    atrHandle = iATR(tradeSymbol, 0, 14);
    if(atrHandle == INVALID_HANDLE) {
        Print("ATR初始化失败! 错误:", GetLastError());
        return(INIT_FAILED);
    }
    
    // 挂单有效期校验
    datetime expiration = StringToTime(ExpirationDate);
    if(expiration == 0 && ExpirationDate != ""){
        Alert("有效期格式错误! 使用YYYY.MM.DD");
    }
    
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| 核心交易逻辑                                                    |
//+------------------------------------------------------------------+
void OnTick()
{
    if(!RiskCheck()) {
        CloseAllOrders();
        return;
    }
    
    if(!ExecuteChecks()) return;
    
    MqlTick lastTick;
    if(!GetMarketData(lastTick)) return;
    
    CalculateChannel();
    ManageOrders();
    CheckBreakoutSignals(lastTick);
    
    if(IsVisualMode()) ShowInfoPanel();
}

//+------------------------------------------------------------------+
//| 统一校验系统                                                    |
//+------------------------------------------------------------------+
bool ExecuteChecks()
{
    static datetime lastCheckTime = 0;
    if(TimeCurrent() - lastCheckTime < 1) return true;
    
    bool pass = true;
    pass &= !IsStopped();
    pass &= (Bars >= ChannelPeriod+10);
    pass &= (CheckDailyLoss() < DailyMaxLoss);
    pass &= IsTradeTime(TradingStart, TradingEnd);
    pass &= IsNewBar();
    pass &= (GetCurrentSpread() <= MaxSpread);
    
    lastCheckTime = TimeCurrent();
    return pass;
}

//+------------------------------------------------------------------+
//| 安全订单发送函数                                                |
//+------------------------------------------------------------------+
bool SafeOrderSend(int cmd, double price, double sl, double tp)
{
    int retry = 0;
    while(retry < 3) {
        if(IsTradeAllowed() && !IsTradeContextBusy()) {
            MqlTradeRequest request={0};
            MqlTradeResult result={0};
            
            request.action = TRADE_ACTION_PENDING;
            request.symbol = tradeSymbol;
            request.volume = Lots;
            request.type = (ENUM_ORDER_TYPE)cmd;
            request.price = NormalizePrice(price);
            request.sl = NormalizePrice(sl);
            request.tp = NormalizePrice(tp);
            request.deviation = MaxSlippage;
            request.magic = MagicNumber;
            request.expiration = StringToTime(ExpirationDate);
            
            if(OrderSend(request, result)) {
                Log(StringFormat("订单成功 类型:%d 价格:%.5f",cmd,price));
                return true;
            }
            LogError("订单失败", GetLastError());
        }
        Sleep(300 + MathRand()%200);
        retry++;
    }
    return false;
}

//+------------------------------------------------------------------+
//| 智能参数优化系统                                                |
//+------------------------------------------------------------------+
void OptimizeParameters()
{
    static datetime lastOptimize = 0;
    if(TimeCurrent() - lastOptimize < 3600) return;
    
    double atr = GetATRValue();
    if(atr > 0.0003 && atr < 0.005) {
        double ratio = MathMin(atr/0.0015, 2.0);
        StopLoss = (int)MathCeil(StopLoss * ratio);
        StopLoss = MathMin(StopLoss, 1000); // 硬性限制
        TakeProfit = StopLoss * 2;
        ATRMultiplier = NormalizeDouble(2.5 - (atr*800), 1);
        ATRMultiplier = MathClamp(ATRMultiplier, 0.5, 3.0);
    }
    lastOptimize = TimeCurrent();
}

//+------------------------------------------------------------------+
//| 增强风控系统                                                   |
//+------------------------------------------------------------------+
bool RiskCheck()
{
    // 净值保护
    if(AccountBalance() <= 0 || (AccountEquity()/MathMax(AccountBalance(),0.01)) < 0.7) {
        Log("账户净值异常");
        return false;
    }
    
    // 流动性检测
    if(MarketInfo(tradeSymbol, MODE_SPREAD) > MaxSpread*2) {
        Log("市场流动性不足");
        return false;
    }
    
    // 波动率过滤
    if(IsMarketAbnormal()) {
        Log("市场波动异常");
        return false;
    }
    
    return true;
}

//+------------------------------------------------------------------+
//| 核心功能函数实现                                               |
//+------------------------------------------------------------------+
double NormalizePrice(double price) {
    return NormalizeDouble(price, (int)SymbolInfoInteger(tradeSymbol, SYMBOL_DIGITS));
}

void CalculateChannel() 
{
    static datetime lastCalcTime = 0;
    if(Time[0] == lastCalcTime) return;
    lastCalcTime = Time[0];
    
    // 获取ATR值（带错误重试机制）
    double atrValue = 0;
    for(int attempt=0; attempt<3; attempt++){
        atrValue = GetATRValue();
        if(atrValue > 0) break;
        Sleep(200);
    }
    
    // 长期波动率过滤（100周期ATR均值）
    static double longATR = 0;
    if(longATR == 0){
        double atrBuffer[100];
        if(CopyBuffer(atrHandle, 0, 0, 100, atrBuffer) == 100){
            longATR = NormalizeDouble(ArrayAverage(atrBuffer), _Digits);
        }
    }
    
    // 波动率双重验证
    if(atrValue < 0.0005 || atrValue < longATR*0.5){ 
        upperBand = 0;
        lowerBand = 0;
        Print("波动率不足暂停交易，当前ATR:",atrValue," 长期ATR:",longATR);
        return;
    }
    
    // 获取K线数据（带容错机制）
    double highs[], lows[];
    ArraySetAsSeries(highs, true);
    ArraySetAsSeries(lows, true);
    
    int retryCount = 0;
    while(retryCount < 3 && 
         (CopyHigh(tradeSymbol, PERIOD_CURRENT, 1, ChannelPeriod, highs) <=0 || 
          CopyLow(tradeSymbol, PERIOD_CURRENT, 1, ChannelPeriod, lows) <=0))
    {
        Print("K线数据获取失败，重试中...");
        Sleep(300);
        retryCount++;
    }
    
    // 数据有效性验证
    if(ArraySize(highs)==0 || ArraySize(lows)==0 || 
       highs[0]==0 || lows[0]==0 || highs[ArrayMaximum(highs)] <= lows[ArrayMinimum(lows)])
    {
        Print("无效K线数据");
        return;
    }
    
    // 动态通道计算（带异常值过滤）
    double baseHigh = highs[ArrayMaximum(highs)];
    double baseLow = lows[ArrayMinimum(lows)];
    
    // 防止极端值干扰
    double prevUpper = upperBand;
    double prevLower = lowerBand;
    double maxDeviation = 3 * atrValue; // 最大允许偏移
    
    upperBand = NormalizeDouble(baseHigh + ATRMultiplier * atrValue, _Digits);
    lowerBand = NormalizeDouble(baseLow - ATRMultiplier * atrValue, _Digits);
    
    // 平滑处理（防止剧烈波动）
    if(prevUpper != 0 && prevLower != 0){
        upperBand = (upperBand + prevUpper*0.3)/1.3;
        lowerBand = (lowerBand + prevLower*0.3)/1.3;
    }
    
    // 通道异常检测
    if(MathAbs(upperBand - prevUpper) > maxDeviation || 
       MathAbs(lowerBand - prevLower) > maxDeviation)
    {
        upperBand = prevUpper;
        lowerBand = prevLower;
        Print("通道值异常波动，维持前值");
    }
}

//+------------------------------------------------------------------+
//| 市场数据获取函数                                                |
//+------------------------------------------------------------------+
bool GetMarketData(MqlTick &tick)
{
    static datetime lastGetTime = 0;
    if(TimeCurrent() - lastGetTime < 1) return true;
    
    bool success = SymbolInfoTick(tradeSymbol, tick);
    if(success) lastGetTime = TimeCurrent();
    return success;
}

//+------------------------------------------------------------------+
//| 订单管理增强版                                                  |
//+------------------------------------------------------------------+
void ManageOrders()
{
    for(int i=OrdersTotal()-1; i>=0; i--)
    {
        if(OrderSelect(i, SELECT_BY_POS) && 
           OrderMagicNumber() == MagicNumber &&
           OrderSymbol() == tradeSymbol)
        {
            // 移动止损逻辑
            if(EnableTrailing) TrailStopLoss();
            
            // 回撤保护（动态阈值）
            double equityRatio = MathAbs(OrderProfit()/AccountEquity());
            if(equityRatio > 0.02 && equityRatio < 0.05){
                CloseOrder(OrderTicket());
                Log("触发动态回撤保护");
            }
        }
    }
}

//+------------------------------------------------------------------+
//| 移动止损函数（带滑点保护）                                      |
//+------------------------------------------------------------------+
void TrailStopLoss()
{
    if(!OrderSelect(OrderTicket(), SELECT_BY_TICKET)) return;
    
    double newStop = 0;
    double currentPrice = 0;
    double slippage = Point() * MaxSlippage;
    
    if(OrderType() == OP_BUY) {
        currentPrice = NormalizeBid();
        newStop = currentPrice - StopLoss*pointCoefficient;
        newStop = MathMax(newStop, OrderStopLoss() + slippage);
    }
    else if(OrderType() == OP_SELL) {
        currentPrice = NormalizeAsk();
        newStop = currentPrice + StopLoss*pointCoefficient;
        newStop = MathMin(newStop, OrderStopLoss() - slippage);
    }
    
    if(MathAbs(newStop - OrderStopLoss()) > Point()/2){
        if(!OrderModify(OrderTicket(), OrderOpenPrice(), 
           NormalizePrice(newStop), OrderTakeProfit(), 0)){
            LogError("移动止损失败", GetLastError());
        }
    }
}

//+------------------------------------------------------------------+
//| 突破信号检测（带成交量过滤）                                    |
//+------------------------------------------------------------------+
void CheckBreakoutSignals(const MqlTick &tick)
{
    if(IsHighImpactNews()) return;
    
    // 成交量验证
    if(iVolume(tradeSymbol, PERIOD_CURRENT, 0) < 100) {
        Print("成交量不足跳过交易");
        return;
    }
    
    double ask = NormalizePrice(tick.ask);
    double bid = NormalizePrice(tick.bid);
    
    // 买突破信号
    if(bid > upperBand && (upperBand - lowerBand) > (2 * GetATRValue()))
    {
        double triggerPrice = NormalizePrice(upperBand + 3*Point());
        double sl = triggerPrice - StopLoss*pointCoefficient;
        double tp = triggerPrice + TakeProfit*pointCoefficient;
        SafeOrderSend(OP_BUYSTOP, triggerPrice, sl, tp);
    }
    
    // 卖突破信号
    if(ask < lowerBand && (upperBand - lowerBand) > (2 * GetATRValue()))
    {
        double triggerPrice = NormalizePrice(lowerBand - 3*Point());
        double sl = triggerPrice + StopLoss*pointCoefficient;
        double tp = triggerPrice - TakeProfit*pointCoefficient;
        SafeOrderSend(OP_SELLSTOP, triggerPrice, sl, tp);
    }
}

//+------------------------------------------------------------------+
//|                 核心功能函数实现                                |
//+------------------------------------------------------------------+
double GetATRValue()
{
    double atrBuffer[];
    if(CopyBuffer(atrHandle, 0, 0, 1, atrBuffer) == 1)
        return atrBuffer[0];
    Print("获取ATR值失败!");
    return 0.0;
}

//+------------------------------------------------------------------+
//| 每日亏损检查函数                                                |
//+------------------------------------------------------------------+
double CheckDailyLoss()
{
    if(TimeDay(TimeCurrent()) != TimeDay(dailyLoss)) // 新交易日重置
        dailyLoss = 0;
    
    for(int i=OrdersHistoryTotal()-1; i>=0; i--)
    {
        if(OrderSelect(i, SELECT_BY_POS, MODE_HISTORY) &&
           OrderMagicNumber() == MagicNumber &&
           OrderSymbol() == tradeSymbol &&
           TimeDay(OrderCloseTime()) == TimeDay(TimeCurrent()))
        {
            if(OrderProfit() < 0)
                dailyLoss += MathAbs(OrderProfit());
        }
    }
    return dailyLoss;
}


//+------------------------------------------------------------------+
//| 关闭所有订单函数                                                |
//+------------------------------------------------------------------+
void CloseAllOrders()
{
    for(int i=OrdersTotal()-1; i>=0; i--)
    {
        if(OrderSelect(i, SELECT_BY_POS) && 
           OrderMagicNumber() == MagicNumber &&
           OrderSymbol() == tradeSymbol)
        {
            if(OrderType() <= OP_SELL) // 市价单
                CloseOrder(OrderTicket());
            else // 挂单
                OrderDelete(OrderTicket());
        }
    }
}

//+------------------------------------------------------------------+
//| 关闭单个订单函数                                                |
//+------------------------------------------------------------------+
bool CloseOrder(int ticket)
{
    if(OrderSelect(ticket, SELECT_BY_TICKET)){
        double price = OrderType()==OP_BUY ? Bid : Ask;
        return OrderClose(ticket, OrderLots(), price, 3);
    }
    return false;
}

//+------------------------------------------------------------------+
//| 重大新闻检测函数（示例实现）                                    |
//+------------------------------------------------------------------+
bool IsHighImpactNews()
{
    // 此处可接入新闻API，示例仅检测美东时间08:30-09:30
    datetime now = TimeCurrent();
    int hour = TimeHour(now);
    int mins = TimeMinute(now);
    
    // 检测NFP等重大新闻时段
    if((hour == 8 && mins >= 30) || (hour == 9 && mins < 30))
        return true;
        
    return false;
}

//+------------------------------------------------------------------+
//| NewBar检测函数                                                  |
//+------------------------------------------------------------------+
bool IsNewBar()
{
    static datetime lastBar = 0;
    if(Time[0] != lastBar){
        lastBar = Time[0];
        return true;
    }
    return false;
}

//+------------------------------------------------------------------+
//| 信息显示面板函数                                                |
//+------------------------------------------------------------------+
void ShowInfoPanel()
{
    string info = StringFormat(
        "【策略监控】品种: %s\n"+
        "通道范围: %.5f - %.5f\n"+
        "ATR波动率: %.5f\n"+
        "活跃订单: %d/%d\n"+
        "当日亏损: %.2f/%s\n"+
        "最后错误: [%d] %s",
        tradeSymbol,
        upperBand,
        lowerBand,
        GetATRValue(),
        CurrentOrders(),
        MaxOrders,
        dailyLoss,
        DoubleToString(DailyMaxLoss,0),
        GetLastError(),
        ErrorDescription(GetLastError())
    );
    Comment(info);
}

//+------------------------------------------------------------------+
//| 增强版订单统计函数                                              |
//+------------------------------------------------------------------+
int CurrentOrders()
{
    int count = 0;
    for(int i=OrdersTotal()-1; i>=0; i--)
    {
        if(OrderSelect(i, SELECT_BY_POS) && 
           OrderMagicNumber() == MagicNumber &&
           OrderSymbol() == tradeSymbol)
        {
            count++;
        }
    }
    return count;
}

//+------------------------------------------------------------------+
//| 错误日志函数                                                    |
//+------------------------------------------------------------------+
void LogError(string message, int errorCode)
{
    Print(TimeToString(TimeCurrent(),TIME_SECONDS)," 错误 ",errorCode,": ",message);
}

