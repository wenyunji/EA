#property copyright "TONGYI Lingma"
#property version   "5.0"  // 终极优化版
#property strict
#property show_inputs

//---- 通道参数
input int     ChannelPeriod   = 20;       // 计算周期
input double  ATRMultiplier   = 2.0;      // 波动系数

//---- 风险参数  
input double  Lots            = 0.01;     // 交易手数
input int     StopLoss        = 400;      // 止损点数
input int     TakeProfit      = 800;      // 止盈点数
input double  MaxSpread       = 3.0;      // 最大允许点差(点)
input double  DailyMaxLoss    = 500.0;    // 单日最大亏损(USD)

//---- 执行参数
input int     MaxSlippage     = 5;        // 最大滑点
input int     MaxOrders       = 1;        // 最大订单数
input string  ExpirationDate  = "2024-12-31"; // 挂单有效期
input string  TradingStart    = "02:00";  // 交易时段开始
input string  TradingEnd      = "22:00";  // 交易时段结束
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
    
    // 增强版品种校验
    string baseCurrency = SymbolInfoString(tradeSymbol, SYMBOL_CURRENCY_BASE);
    string quoteCurrency = SymbolInfoString(tradeSymbol, SYMBOL_CURRENCY_PROFIT);
    if((baseCurrency != "XAU" || quoteCurrency != "USD") && 
       (baseCurrency != "EUR" || quoteCurrency != "USD")){
        Alert("仅支持XAUUSD/EURUSD");
        return(INIT_FAILED);
    }
    
    // 特殊报价处理
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
//| 主交易逻辑                                                      |
//+------------------------------------------------------------------+
void OnTick()
{
    // 基础校验
    if(IsStopped() || Bars < ChannelPeriod+10 || IsTradeContextBusy()) return;
    
    // 每日亏损检查
    if(CheckDailyLoss() >= DailyMaxLoss){
        CloseAllOrders();
        return;
    }
    
    // 时段过滤
    if(!IsTradeTime(TradingStart, TradingEnd) && OrdersTotal() == 0) return;
    
    // NewBar检测
    if(!IsNewBar()) return;
    
    // 同步报价
    MqlTick lastTick;
    if(!SymbolInfoTick(tradeSymbol, lastTick)) {
        Print("报价获取失败!");
        return;
    }
    
    // 点差过滤
    double currentSpread = (lastTick.ask - lastTick.bid)/Point();
    if(currentSpread > MaxSpread){
        Comment("点差过大:",DoubleToString(currentSpread,1));
        return;
    }
    
    // 计算通道
    CalculateChannel();
    
    // 订单管理
    ManageOrders();
    CleanExpiredOrders();
    
    // 交易信号
    if(CurrentOrders() < MaxOrders){
        CheckBreakoutSignals(lastTick);
    }
    
    // 显示面板
    if(IsVisualMode()) ShowInfoPanel();
}

//+------------------------------------------------------------------+
//| 动态通道计算函数（增强版）                                      |
//+------------------------------------------------------------------+
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
//| 辅助函数 - 计算数组平均值                                        |
//+------------------------------------------------------------------+
double ArrayAverage(const double &arr[])
{
    double sum = 0;
    int count = 0;
    for(int i=0; i<ArraySize(arr); i++){
        if(arr[i] > 0){
            sum += arr[i];
            count++;
        }
    }
    return (count>0) ? sum/count : 0;
}

//+------------------------------------------------------------------+
//| 智能订单管理（增强版）                                          |
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
            
            // 回撤保护
            if(OrderProfit() < -AccountEquity()*0.02){
                CloseOrder(OrderTicket());
            }
        }
    }
}

//+------------------------------------------------------------------+
//| 突破信号检测（带新闻过滤）                                      |
//+------------------------------------------------------------------+
void CheckBreakoutSignals(const MqlTick &tick)
{
    if(IsHighImpactNews()) return;
    
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
//| 移动止损函数                                                    |
//+------------------------------------------------------------------+
void TrailStopLoss()
{
    if(!OrderSelect(OrderTicket(), SELECT_BY_TICKET)) return;
    
    double newStop = 0;
    double currentPrice = 0;
    
    if(OrderType() == OP_BUY) {
        currentPrice = NormalizeBid();
        newStop = currentPrice - StopLoss*pointCoefficient;
        newStop = MathMax(newStop, OrderStopLoss());
    }
    else if(OrderType() == OP_SELL) {
        currentPrice = NormalizeAsk();
        newStop = currentPrice + StopLoss*pointCoefficient;
        newStop = MathMin(newStop, OrderStopLoss());
    }
    
    if(MathAbs(newStop - OrderStopLoss()) > Point()/2){
        if(!OrderModify(OrderTicket(), OrderOpenPrice(), 
           NormalizePrice(newStop), OrderTakeProfit(), 0)){
            LogError("移动止损失败", GetLastError());
        }
    }
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
//| 清理过期订单函数                                                |
//+------------------------------------------------------------------+
void CleanExpiredOrders()
{
    for(int i=OrdersTotal()-1; i>=0; i--)
    {
        if(OrderSelect(i, SELECT_BY_POS) && 
           OrderMagicNumber() == MagicNumber &&
           OrderSymbol() == tradeSymbol &&
           OrderType() > OP_SELL)
        {
            datetime expiration = OrderExpiration();
            if(expiration != 0 && expiration < TimeCurrent())
                OrderDelete(OrderTicket());
        }
    }
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

//+------------------------------------------------------------------+
//| 交易时段判断函数                                                |
//+------------------------------------------------------------------+
bool IsTradeTime(string start, string end)
{
    datetime now = TimeCurrent();
    datetime startTime = StringToTime(TimeToString(now,TIME_DATE)+" "+start);
    datetime endTime = StringToTime(TimeToString(now,TIME_DATE)+" "+end);
    
    if(endTime < startTime) endTime += 86400; // 处理跨天
    
    return (now >= startTime) && (now <= endTime);
}
//+------------------------------------------------------------------+