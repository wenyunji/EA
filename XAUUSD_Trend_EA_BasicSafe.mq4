//+------------------------------------------------------------------+
//|                               XAUUSD_Trend_EA_BasicSafe.mq4     |
//|                               FX自動売買EAプロジェクト          |
//+------------------------------------------------------------------+
#property copyright "NiAka"
#property link      "https://github.com/niaka3dayo/MartingaleEA"
#property version   "1.00"
#property strict

// -------------------------------------------------------------------
// --- トレード設定 (XAUUSD用にやや広めに設定) ---
// -------------------------------------------------------------------
extern double InitialLotSize       = 0.1;    // 初期ロットサイズ
extern double MaxLotSize           = 10.0;   // 最大ロットサイズ(例:金は高ボラなので少し余裕を持たせる)
extern bool   UseMoneyManagement   = true;   // 資金管理を使用する
extern double RiskPercent          = 2.0;    // リスク率（％）(例)
extern int    StopLoss             = 500;    // ストップロス（ポイント）(XAUUSD用に大きめ)
extern int    TakeProfit           = 1000;   // 利確（ポイント）
extern int    TrailingStop         = 300;    // トレーリングストップ（ポイント）(例:広め)
extern int    Slippage             = 5;      // スリッページ（ポイント）
extern int    MaxSpread            = 50;     // 最大許容スプレッド（ポイント）(金はスプレッド広め想定)

// -------------------------------------------------------------------
// --- 時間設定 (既存の時間フィルター) ---
// -------------------------------------------------------------------
extern bool   UseTimeFilter        = true;    // 時間フィルター
extern int    StartHour            = 8;       // 開始時刻
extern int    EndHour              = 20;      // 終了時刻
extern bool   MondayFilter         = false;   // 月曜除外
extern bool   FridayFilter         = true;    // 金曜除外
extern bool   CloseAllFriday       = true;    // 金曜に全ポジションを閉じる
extern int    FridayCloseHour      = 20;      // 金曜クローズ時刻

// -------------------------------------------------------------------
// --- トレンド判定設定 (元のまま) ---
// -------------------------------------------------------------------
extern int FastEMA           = 8;   // 短期EMA期間
extern int SlowEMA           = 21;  // 長期EMA期間
extern int RSI_Period        = 14;  // RSI期間
extern int RSI_UpperLevel    = 70;  // RSI上限レベル
extern int RSI_LowerLevel    = 30;  // RSI下限レベル
extern int ADX_Period        = 14;  // ADX期間
extern int ADX_MinLevel      = 25;  // ADX最小レベル
extern int MACD_FastEMA      = 12;  // MACD短期EMA
extern int MACD_SlowEMA      = 26;  // MACD長期EMA
extern int MACD_SignalPeriod = 9;   // MACDシグナル期間

// -------------------------------------------------------------------
// --- その他パラメータ (元のまま) ---
// -------------------------------------------------------------------
extern int  MagicNumber           = 20240602;  // マジックナンバー(XAU用に例として変更)
extern bool EnableDebugLog        = false;     // デバッグログを有効にする
extern bool SendPushNotifications = false;     // プッシュ通知

// -------------------------------------------------------------------
// --- 下記は必要に応じてオンにする追加フィルター(初期OFF) (元のまま) ---
// -------------------------------------------------------------------
extern bool   UseVolatilityFilter       = false;   // ATRで高ボラを判定
extern int    ATRPeriodForVolatility    = 14;      // ATR計算期間
extern double ATRVolatilityThreshold    = 0.50;    // (例) XAUUSDの1Lotあたりポイントを考慮して大きめ
extern bool   LimitHighVolatility       = true;
extern bool   UseDynamicSlippage        = false;
extern double SlippageATRMultiplier     = 0.2;
extern bool   UseDynamicPositionSize    = false;
extern double VolatilityReductionFactor = 0.5;

extern bool   UseNewsFilter    = false;
extern string ImportantNewsTimes = "2025.12.15 15:30";
extern int    PreNewsMinutes   = 30;
extern int    PostNewsMinutes  = 30;

extern bool UseMultiTimeframeConfirmation = false;
extern int  MTFPeriod = PERIOD_H4;

extern bool   UseDailyMaxLossLimit   = false;
extern double DailyMaxLoss           = 100.0;
extern bool   UseMaxTradeCountPerDay = false;
extern int    MaxTradeCountPerDay    = 5;
extern bool   UseMaxConsecutiveLosses= false;
extern int    MaxConsecutiveLosses   = 3;

// -------------------------------------------------------------------
// グローバル変数
// -------------------------------------------------------------------
double   g_point;
int      g_digits;
bool     g_ecnBroker       = false;
datetime g_lastTradeTime   = 0;
int      g_totalOrders     = 0;
double   g_accountBalance  = 0;

// リスク管理用(当日)
double   g_todayLoss       = 0.0;
int      g_todayTrades     = 0;
int      g_consecLoss      = 0;
datetime g_todayDate       = 0;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
    // 通貨ペアチェック（XAUUSD以外は停止）
    if(Symbol() != "XAUUSD")
    {
        Print("このEAはXAUUSDのみで使用できます。現在のチャート: ", Symbol());
        return INIT_FAILED;
    }

    // ポイント設定
    g_digits = Digits;
    g_point  = Point;
    if(g_digits == 3 || g_digits == 5)
        g_point = Point * 10;

    // ECNブローカー判定
    if(MarketInfo(Symbol(), MODE_STOPLEVEL) > 0)
        g_ecnBroker = true;

    // 口座情報
    g_accountBalance = AccountBalance();

    // 今日の日付初期化
    g_todayDate = DateOfDay(TimeCurrent());

    Print("EA 初期化完了: 通貨ペア=", Symbol(), ", Timeframe=", Period());
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    Print("EA 終了: reason=", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    static datetime lastBar = 0;
    datetime currentBar = Time[0];

    // 同じ足であればトレーリングストップのみ
    if(lastBar == currentBar)
    {
        if(TrailingStop > 0)
            ManageTrailingStop();
        return;
    }
    lastBar = currentBar;

    // 1) 毎足でリスク管理情報更新
    RefreshRiskStats();

    // 2) リスク制限超過かチェック
    if(IsRiskExceeded())
    {
        if(EnableDebugLog) Print("リスク制限を超えているためトレード停止");
        return;
    }

    // 3) 時間フィルター
    if(!IsTimeFrameAllowed())
        return;

    // 4) スプレッドチェック
    double currentSpread = MarketInfo(Symbol(), MODE_SPREAD);
    if(currentSpread > MaxSpread)
    {
        if(EnableDebugLog) Print("スプレッド超過: ", currentSpread);
        return;
    }

    // 5) 金曜クローズ
    if(CloseAllFriday && DayOfWeek() == 5 && Hour() >= FridayCloseHour)
    {
        CloseAllPositions();
        return;
    }

    // 6) ボラティリティチェック (ATRフィルター)
    if(UseVolatilityFilter && !IsVolatilityAcceptable())
    {
        if(EnableDebugLog) Print("高ボラまたは低ボラにつき取引回避");
        return;
    }

    // 7) ニュースフィルター
    if(UseNewsFilter && IsNewsTime())
    {
        if(EnableDebugLog) Print("ニュース時間: トレード回避");
        return;
    }

    // 8) 現在のポジション数
    g_totalOrders = CountOrders();

    // 9) トレンド分析
    int trendSignal = AnalyzeTrend();

    //    MTFがオンなら追加で分析
    if(UseMultiTimeframeConfirmation)
    {
        int higherTfSignal = AnalyzeTrendOnTimeframe(MTFPeriod);
        trendSignal += higherTfSignal;
        if(EnableDebugLog) Print("MTF併用 シグナル合計: ", trendSignal);
    }

    // 10) ポジションゼロなら新規エントリー
    if(g_totalOrders == 0)
    {
        if(trendSignal >= 2)
            OpenBuyOrder();
        else if(trendSignal <= -2)
            OpenSellOrder();
    }

    // 11) トレーリングストップ
    if(TrailingStop > 0)
        ManageTrailingStop();
}

//+------------------------------------------------------------------+
//| トレンド分析(現在時間足)                                         |
//+------------------------------------------------------------------+
int AnalyzeTrend()
{
    double fastEMA = iMA(Symbol(), 0, FastEMA, 0, MODE_EMA, PRICE_CLOSE, 0);
    double slowEMA = iMA(Symbol(), 0, SlowEMA, 0, MODE_EMA, PRICE_CLOSE, 0);
    double rsi     = iRSI(Symbol(), 0, RSI_Period, PRICE_CLOSE, 0);
    double adx     = iADX(Symbol(), 0, ADX_Period, PRICE_CLOSE, MODE_MAIN, 0);
    double plusDI  = iADX(Symbol(), 0, ADX_Period, PRICE_CLOSE, MODE_PLUSDI, 0);
    double minusDI = iADX(Symbol(), 0, ADX_Period, PRICE_CLOSE, MODE_MINUSDI, 0);
    double macd    = iMACD(Symbol(), 0, MACD_FastEMA, MACD_SlowEMA, MACD_SignalPeriod,
                           PRICE_CLOSE, MODE_MAIN, 0);
    double macdSig = iMACD(Symbol(), 0, MACD_FastEMA, MACD_SlowEMA, MACD_SignalPeriod,
                           PRICE_CLOSE, MODE_SIGNAL, 0);

    int trendScore = 0;
    // EMAクロス
    if(fastEMA > slowEMA) trendScore++;
    else if(fastEMA < slowEMA) trendScore--;

    // RSI
    if(rsi < RSI_LowerLevel) trendScore++;
    else if(rsi > RSI_UpperLevel) trendScore--;

    // ADX
    if(adx > ADX_MinLevel)
    {
        if(plusDI > minusDI) trendScore++;
        else if(plusDI < minusDI) trendScore--;
    }

    // MACD
    if(macd > macdSig) trendScore++;
    else if(macd < macdSig) trendScore--;

    if(EnableDebugLog) Print("TrendScore=", trendScore);
    return trendScore;
}

//+------------------------------------------------------------------+
//| MTFトレンド分析                                                  |
//+------------------------------------------------------------------+
int AnalyzeTrendOnTimeframe(int timeframe)
{
    double fastEMA = iMA(Symbol(), timeframe, FastEMA, 0, MODE_EMA, PRICE_CLOSE, 0);
    double slowEMA = iMA(Symbol(), timeframe, SlowEMA, 0, MODE_EMA, PRICE_CLOSE, 0);
    double rsi     = iRSI(Symbol(), timeframe, RSI_Period, PRICE_CLOSE, 0);
    double adx     = iADX(Symbol(), timeframe, ADX_Period, PRICE_CLOSE, MODE_MAIN, 0);
    double plusDI  = iADX(Symbol(), timeframe, ADX_Period, PRICE_CLOSE, MODE_PLUSDI, 0);
    double minusDI = iADX(Symbol(), timeframe, ADX_Period, PRICE_CLOSE, MODE_MINUSDI, 0);
    double macd    = iMACD(Symbol(), timeframe, MACD_FastEMA, MACD_SlowEMA,
                           MACD_SignalPeriod, PRICE_CLOSE, MODE_MAIN, 0);
    double macdSig = iMACD(Symbol(), timeframe, MACD_FastEMA, MACD_SlowEMA,
                           MACD_SignalPeriod, PRICE_CLOSE, MODE_SIGNAL, 0);

    int trendScore = 0;
    if(fastEMA > slowEMA) trendScore++;
    else if(fastEMA < slowEMA) trendScore--;

    if(rsi < RSI_LowerLevel) trendScore++;
    else if(rsi > RSI_UpperLevel) trendScore--;

    if(adx > ADX_MinLevel)
    {
        if(plusDI > minusDI) trendScore++;
        else if(plusDI < minusDI) trendScore--;
    }

    if(macd > macdSig) trendScore++;
    else if(macd < macdSig) trendScore--;

    return trendScore;
}

//+------------------------------------------------------------------+
//| BUY                                                             |
//+------------------------------------------------------------------+
void OpenBuyOrder()
{
    double lotSize = CalculateLotSize();
    double stopLossPrice    = Ask - StopLoss * g_point;
    double takeProfitPrice  = Ask + TakeProfit * g_point;
    int    currentSlippage  = Slippage;

    // 動的スリッページ
    if(UseDynamicSlippage)
    {
        double atrVal = iATR(Symbol(), 0, ATRPeriodForVolatility, 0);
        currentSlippage = (int)MathRound(atrVal * SlippageATRMultiplier / g_point);
    }

    int ticket = -1;
    if(g_ecnBroker)
    {
        ticket = OrderSend(Symbol(), OP_BUY, lotSize, Ask, currentSlippage, 0, 0, "EA_BUY", MagicNumber, 0, Blue);
        if(ticket > 0)
        {
            if(OrderSelect(ticket, SELECT_BY_TICKET))
            {
                if(!OrderModify(ticket, OrderOpenPrice(), stopLossPrice, takeProfitPrice, 0, Blue))
                    Print("OrderModifyエラー(Buy/ECN): ", GetLastError());
            }
        }
    }
    else
    {
        ticket = OrderSend(Symbol(), OP_BUY, lotSize, Ask, currentSlippage,
                           stopLossPrice, takeProfitPrice,
                           "EA_BUY", MagicNumber, 0, Blue);
    }

    if(ticket > 0)
    {
        Print("BUY Order発注成功: ticket=", ticket, ", lot=", lotSize);
        g_lastTradeTime = Time[0];
        g_todayTrades++;
        if(SendPushNotifications)
            SendNotification("BUY Order Opened (Lot=" + DoubleToStr(lotSize,2)+")");
    }
    else
    {
        Print("BUY OrderSend失敗: err=", GetLastError());
    }
}

//+------------------------------------------------------------------+
//| SELL                                                            |
//+------------------------------------------------------------------+
void OpenSellOrder()
{
    double lotSize = CalculateLotSize();
    double stopLossPrice   = Bid + StopLoss * g_point;
    double takeProfitPrice = Bid - TakeProfit * g_point;
    int    currentSlippage = Slippage;

    // 動的スリッページ
    if(UseDynamicSlippage)
    {
        double atrVal = iATR(Symbol(), 0, ATRPeriodForVolatility, 0);
        currentSlippage = (int)MathRound(atrVal * SlippageATRMultiplier / g_point);
    }

    int ticket = -1;
    if(g_ecnBroker)
    {
        ticket = OrderSend(Symbol(), OP_SELL, lotSize, Bid, currentSlippage, 0, 0, "EA_SELL", MagicNumber, 0, Red);
        if(ticket > 0)
        {
            if(OrderSelect(ticket, SELECT_BY_TICKET))
            {
                if(!OrderModify(ticket, OrderOpenPrice(), stopLossPrice, takeProfitPrice, 0, Red))
                    Print("OrderModifyエラー(Sell/ECN): ", GetLastError());
            }
        }
    }
    else
    {
        ticket = OrderSend(Symbol(), OP_SELL, lotSize, Bid, currentSlippage,
                           stopLossPrice, takeProfitPrice,
                           "EA_SELL", MagicNumber, 0, Red);
    }

    if(ticket > 0)
    {
        Print("SELL Order発注成功: ticket=", ticket, ", lot=", lotSize);
        g_lastTradeTime = Time[0];
        g_todayTrades++;
        if(SendPushNotifications)
            SendNotification("SELL Order Opened (Lot=" + DoubleToStr(lotSize,2)+")");
    }
    else
    {
        Print("SELL OrderSend失敗: err=", GetLastError());
    }
}

//+------------------------------------------------------------------+
//| ロットサイズ計算                                                |
//+------------------------------------------------------------------+
double CalculateLotSize()
{
    double lotSize = InitialLotSize;

    // 資金管理オンならリスク率に基づいて計算
    if(UseMoneyManagement)
    {
        double accountEquity = AccountEquity();
        double tickValue     = MarketInfo(Symbol(), MODE_TICKVALUE);
        double lotStep       = MarketInfo(Symbol(), MODE_LOTSTEP);

        if(tickValue != 0 && StopLoss != 0 && lotStep > 0)
        {
            lotSize = (accountEquity * RiskPercent / 100.0) / (StopLoss * tickValue);
            lotSize = NormalizeDouble(MathFloor(lotSize / lotStep), 0) * lotStep;

            double minLot = MarketInfo(Symbol(), MODE_MINLOT);
            if(lotSize < minLot)     lotSize = minLot;
            if(lotSize > MaxLotSize) lotSize = MaxLotSize;
        }
    }

    // ボラティリティに応じてロット縮小
    if(UseDynamicPositionSize)
    {
        double atrVal = iATR(Symbol(), 0, ATRPeriodForVolatility, 0);
        if(atrVal > ATRVolatilityThreshold) // 高ボラの場合
        {
            lotSize *= VolatilityReductionFactor;
            if(lotSize < 0.01)
                lotSize = 0.01;
        }
    }

    return NormalizeDouble(lotSize, 2);
}

//+------------------------------------------------------------------+
//| トレーリングストップ                                             |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
    for(int i=OrdersTotal()-1; i>=0; i--)
    {
        if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
        {
            if(OrderSymbol() == Symbol() && OrderMagicNumber() == MagicNumber)
            {
                if(OrderType() == OP_BUY)
                {
                    double newStop = Bid - TrailingStop * g_point;
                    if(Bid - OrderOpenPrice() > TrailingStop * g_point &&
                       OrderStopLoss() < newStop)
                    {
                        bool mod = OrderModify(OrderTicket(), OrderOpenPrice(), newStop,
                                               OrderTakeProfit(), 0, Blue);
                        if(!mod && EnableDebugLog)
                            Print("TrailingStop BUY Modify失敗: err=", GetLastError());
                    }
                }
                else if(OrderType() == OP_SELL)
                {
                    double newStop = Ask + TrailingStop * g_point;
                    if(OrderOpenPrice() - Ask > TrailingStop * g_point &&
                       (OrderStopLoss() > newStop || OrderStopLoss() == 0))
                    {
                        bool mod = OrderModify(OrderTicket(), OrderOpenPrice(), newStop,
                                               OrderTakeProfit(), 0, Red);
                        if(!mod && EnableDebugLog)
                            Print("TrailingStop SELL Modify失敗: err=", GetLastError());
                    }
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| 全ポジションをクローズ                                           |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
    for(int i=OrdersTotal()-1; i>=0; i--)
    {
        if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
        {
            if(OrderSymbol() == Symbol() && OrderMagicNumber() == MagicNumber)
            {
                bool result = false;
                if(OrderType() == OP_BUY)
                    result = OrderClose(OrderTicket(), OrderLots(), Bid, Slippage, Blue);
                else if(OrderType() == OP_SELL)
                    result = OrderClose(OrderTicket(), OrderLots(), Ask, Slippage, Red);

                if(result)
                    Print("ポジションをクローズ: ticket=", OrderTicket());
                else
                    Print("ポジションクローズ失敗: err=", GetLastError());
            }
        }
    }
}

//+------------------------------------------------------------------+
//| 注文数カウント                                                   |
//+------------------------------------------------------------------+
int CountOrders()
{
    int count=0;
    for(int i=0; i<OrdersTotal(); i++)
    {
        if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
        {
            if(OrderSymbol() == Symbol() && OrderMagicNumber() == MagicNumber)
                count++;
        }
    }
    return count;
}

//+------------------------------------------------------------------+
//| 時間フィルター                                                   |
//+------------------------------------------------------------------+
bool IsTimeFrameAllowed()
{
    if(!UseTimeFilter)
        return true;

    if(MondayFilter && DayOfWeek() == 1)
        return false;
    if(FridayFilter && DayOfWeek() == 5)
        return false;

    int currentHour = Hour();
    if(StartHour <= EndHour)
    {
        if(currentHour >= StartHour && currentHour < EndHour)
            return true;
    }
    else
    {
        // 例) StartHour=22, EndHour=5 のようなケース
        if(currentHour >= StartHour || currentHour < EndHour)
            return true;
    }
    return false;
}

//+------------------------------------------------------------------+
//| ATRボラティリティ判定                                            |
//+------------------------------------------------------------------+
bool IsVolatilityAcceptable()
{
    double atrVal = iATR(Symbol(), 0, ATRPeriodForVolatility, 0);
    if(LimitHighVolatility)
    {
        // ATRが閾値を超えたら「高ボラ」とみなして回避
        if(atrVal > ATRVolatilityThreshold)
            return false;
    }
    else
    {
        if(atrVal < ATRVolatilityThreshold)
            return false;
    }
    return true;
}

//+------------------------------------------------------------------+
//| 簡易ニュースフィルター                                           |
//+------------------------------------------------------------------+
bool IsNewsTime()
{
    datetime now = TimeCurrent();
    string strList[];
    int cnt = StringSplit(ImportantNewsTimes, ';', strList);
    for(int i=0; i<cnt; i++)
    {
        datetime newsTime = StringToTime(strList[i]);
        if(newsTime > 0)
        {
            datetime preTime  = newsTime - (PreNewsMinutes*60);
            datetime postTime = newsTime + (PostNewsMinutes*60);
            if(now >= preTime && now <= postTime)
                return true;
        }
    }
    return false;
}

//+------------------------------------------------------------------+
//| リスク情報の更新                                                 |
//+------------------------------------------------------------------+
void RefreshRiskStats()
{
    // 日付が変わればリセット
    datetime today = DateOfDay(TimeCurrent());
    if(today != g_todayDate)
    {
        g_todayDate   = today;
        g_todayLoss   = 0.0;
        g_todayTrades = 0;
        g_consecLoss  = 0;
    }

    // 当日決済の損益合計を計算
    double dailyProfit = 0.0;
    int totalHist = OrdersHistoryTotal();
    for(int i=totalHist-1; i>=0; i--)
    {
        if(OrderSelect(i, SELECT_BY_POS, MODE_HISTORY))
        {
            if(OrderCloseTime() <= 0) continue;
            datetime closeDay = DateOfDay(OrderCloseTime());
            if(closeDay == g_todayDate)
                dailyProfit += (OrderProfit() + OrderSwap() + OrderCommission());
            else if(closeDay < g_todayDate)
                break;
        }
    }
    // 損益がマイナスならその絶対値をtodayLossに
    g_todayLoss = -MathMin(dailyProfit, 0);

    // 連続損失の更新（最新の履歴をざっと見て判定）
    double lastProfit = 0;
    if(OrderSelect(totalHist-1, SELECT_BY_POS, MODE_HISTORY))
        lastProfit = OrderProfit()+OrderSwap()+OrderCommission();

    if(lastProfit < 0.0)  g_consecLoss++;
    else if(lastProfit > 0.0) g_consecLoss = 0;
}

//+------------------------------------------------------------------+
//| リスク制限超過かどうか                                           |
//+------------------------------------------------------------------+
bool IsRiskExceeded()
{
    if(UseDailyMaxLossLimit && g_todayLoss >= DailyMaxLoss)
        return true;

    if(UseMaxTradeCountPerDay && g_todayTrades >= MaxTradeCountPerDay)
        return true;

    if(UseMaxConsecutiveLosses && g_consecLoss >= MaxConsecutiveLosses)
        return true;

    return false;
}

//+------------------------------------------------------------------+
//| ユーティリティ: 日付のみ (00:00:00) を返す                         |
//+------------------------------------------------------------------+
datetime DateOfDay(datetime t)
{
    return StrToTime(TimeToString(t, TIME_DATE)); // "YYYY.MM.DD 00:00:00"
}
//+------------------------------------------------------------------+