//+------------------------------------------------------------------+
//|                                               VGridABCD.mq5       |
//|     Lưới chờ ảo: Buy A / Buy B / Sell C / Sell D (cả + và − gốc).   |
//+------------------------------------------------------------------+
// Allow wrapper versions to reuse this file while overriding #property fields.
#ifndef VDUALGRID_SKIP_PROPERTIES
#property copyright "VGrid ABCD"
#property version   "1.00"
#property description "VGridABCD: chờ ảo Buy A/B, Sell C/D (+/− gốc)."
#endif
#include <Trade\Trade.mqh>

#ifndef VDUALGRID_ENABLE_TELEGRAM
#define VDUALGRID_ENABLE_TELEGRAM
#endif

//+------------------------------------------------------------------+
//| Quy ước NẠP/RÚT (các nhóm input bên dưới — nạp/rút không đổi logic EA): |
//| — EA không đọc ACCOUNT_BALANCE sau khi gắn (trừ dòng hiện số dư thông báo nếu bật). |
//| — attachBalance = số dư ledger snapshot một lần lúc OnInit; nạp/rút không cập nhật. |
//| — initialCapitalBaselineUSD = TEV snapshot một lần lúc OnInit — mốc % P/L trong tin (reset phiên không đổi mốc). |
//| — P/L tích lũy chỉ từ deal BUY/SELL OUT cùng magic+symbol biểu đồ (bỏ deal balance). |
//| — Mọi quét vị thế/lệnh chờ/lịch sử: chỉ magic MagicNumber + _Symbol chart (không gộp magic khác). |
//| — Lưới/lot/TP: theo input.                                        |
//| — Thông báo/lịch: không đổi lưới/lot/ngưỡng.                      |
//| — Carry (EnableCompoundCarry): deal OUT âm → carry; ngưỡng 6B1 = gốc+carry; tắt = không cộng. |
//+------------------------------------------------------------------+

//--- Kiểu tăng lot theo bậc lưới: 0=Cố định mọi bậc; 1=Cộng thêm mỗi bậc; 2=Nhân mỗi bậc.
enum ENUM_LOT_SCALE { LOT_FIXED = 0, LOT_ARITHMETIC = 1, LOT_GEOMETRIC = 2 };

// 4 chân chờ ảo — Buy A/B, Sell C/D; mỗi chân chạy cả bậc + và −.
enum ENUM_VGRID_LEG
{
   VGRID_LEG_BUY_ABOVE = 0,    // Buy A — bậc dương (+)
   VGRID_LEG_SELL_BELOW = 1,   // Sell C — bậc âm (−)
   VGRID_LEG_SELL_ABOVE = 2,   // Sell C — bậc dương (+)
   VGRID_LEG_BUY_BELOW = 3,    // Buy A — bậc âm (−)
   VGRID_LEG_BUY_ABOVE_E = 4,   // Buy B — bậc dương (+)
   VGRID_LEG_SELL_BELOW_F = 5, // Sell D — bậc âm (−)
   VGRID_LEG_SELL_ABOVE_G = 6, // Sell D — bậc dương (+)
   VGRID_LEG_BUY_BELOW_H = 7   // Buy B — bậc âm (−)
};

// 6b: ngưỡng gồng lãi tổng — chỉ 2 chế độ (nhãn hiện trong dropdown input).
enum ENUM_COMPOUND_TRIGGER_PROGRESS_MODE
{
   COMPOUND_PROGRESS_OPEN_SESSION_ONLY = 0,              // Ngưỡng tổng các lệnh đang mở trong phiên
   COMPOUND_PROGRESS_OPEN_PLUS_SESSION_CLOSED_SL_TP = 1  // Ngưỡng tổng lệnh mở + lệnh đóng SL/TP trong phiên
};

// 6B1: khi đặt SL chung gồng lãi tổng — xử lý chờ ảo/broker.
enum ENUM_COMPOUND_CLEAR_PENDING_MODE
{
   COMPOUND_CLEAR_PENDING = 0,    // Xóa lệnh chờ ảo
   COMPOUND_KEEP_PENDING = 1      // Giữ nguyên lệnh chờ ảo
};

// 6B1: chế độ xác định điểm A (2 chế độ lưới).
enum ENUM_COMPOUND_POINT_A_MODE
{
   COMPOUND_POINT_A_MODE_1 = 0, // Chế độ 1: Buy lưới trên giá / Sell lưới dưới giá (gần nhất)
   COMPOUND_POINT_A_MODE_2 = 1  // Chế độ 2: Buy lưới dưới giá / Sell lưới trên giá (gần nhất)
};

// 6b: chế độ lọc chiều EMA.
enum ENUM_EMA_DIRECTION_MODE
{
   EMA_DIRECTION_CLOSE = 0,    // Nến đóng vs EMA(Close) — khóa chiều đến reset EA
   EMA_DIRECTION_HIGH_LOW = 1  // Close>EMA(High)=Buy / Close<EMA(Low)=Sell; khóa chiều lúc đặt gốc đến reset EA
};

input group "1) GRID —"
input double GridDistancePips = 1000.0;         // Bước lưới D (pip) từ bậc 2+
input double GridFirstLevelOffsetPips = 500.0; // Khoảng cách bậc ±1 so với gốc (pip)
input int MaxGridLevels = 80;                   // Số bậc mỗi phía

input group "2) CHUNG (MAGIC / COMMENT) —"
input int MagicNumber = 2084750;                // Magic của EA VGridABCD
input string CommentOrder = "VPGrid";           // Comment lệnh market

enum ENUM_GRID_PENDING_ENTRY_MODE
{
   GRID_PENDING_MODE_VIRTUAL = 0, // Chờ ảo — EA mô phỏng khớp khi giá chạm (mặc định)
   GRID_PENDING_MODE_BROKER  = 1  // Lệnh chờ broker — Buy/Sell Stop/Limit trên thị trường
};
input ENUM_GRID_PENDING_ENTRY_MODE GridPendingEntryMode = GRID_PENDING_MODE_VIRTUAL; // Chế độ vào lệnh chờ

input group "3) CHỜ ẢO A/B/C/D (mỗi chân: + và − gốc) —"

input group "3a - Buy A (+/−) — lot / TP / Trading Stop —"
input bool   EnableLegBuyA = true;               // Bật/tắt chân Buy A (trên + dưới gốc)
input double VGridL1BuyA = 0.01;
input ENUM_LOT_SCALE VGridScaleBuyA = LOT_ARITHMETIC;
input double VGridLotAddBuyA = 0.01;
input double VGridLotMultBuyA = 1.5;
input double VGridMaxLotBuyA = 1.0;
input bool   VGridTpNextBuyA = false;
input double VGridTpPipsBuyA = 0.0;
input double VGridTradingStopTriggerPipsBuyA = 0.0; // Trading Stop 3a: đạt lãi X pip thì kích hoạt (0 = tắt)
input double VGridTradingStopLockPipsBuyA = 0.0;    // Trading Stop 3a: khi kích hoạt đặt SL dương +X1 pip từ giá mở
input double VGridTradingStopStepPipsBuyA = 0.0;    // Trading Stop 3a: cứ đi thêm X pip thuận lợi thì dời SL thêm X pip

input group "3b - Buy B (+/−) — lot / TP / Trading Stop —"
input bool   EnableLegBuyB = true;               // Bật/tắt chân Buy B (trên + dưới gốc)
input double VGridL1BuyB = 0.01;
input ENUM_LOT_SCALE VGridScaleBuyB = LOT_ARITHMETIC;
input double VGridLotAddBuyB = 0.01;
input double VGridLotMultBuyB = 0.3;
input double VGridMaxLotBuyB = 1.0;
input bool   VGridTpNextBuyB = true;
input double VGridTpPipsBuyB = 0.0;
input double VGridTradingStopTriggerPipsBuyB = 0.0; // Trading Stop 3b: đạt lãi X pip thì kích hoạt (0 = tắt)
input double VGridTradingStopLockPipsBuyB = 0.0;    // Trading Stop 3b: khi kích hoạt đặt SL dương +X1 pip từ giá mở
input double VGridTradingStopStepPipsBuyB = 0.0;    // Trading Stop 3b: cứ đi thêm X pip thuận lợi thì dời SL thêm X pip

input group "3c - Sell C (+/−) — lot / TP / Trading Stop —"
input bool   EnableLegSellC = true;              // Bật/tắt chân Sell C (trên + dưới gốc)
input double VGridL1SellC = 0.01;
input ENUM_LOT_SCALE VGridScaleSellC = LOT_ARITHMETIC;
input double VGridLotAddSellC = 0.01;
input double VGridLotMultSellC = 1.5;
input double VGridMaxLotSellC = 1.0;
input bool   VGridTpNextSellC = false;
input double VGridTpPipsSellC = 0.0;
input double VGridTradingStopTriggerPipsSellC = 0.0; // Trading Stop 3c: đạt lãi X pip thì kích hoạt (0 = tắt)
input double VGridTradingStopLockPipsSellC = 0.0;  // Trading Stop 3c: khi kích hoạt đặt SL dương +X1 pip từ giá mở
input double VGridTradingStopStepPipsSellC = 0.0;  // Trading Stop 3c: cứ đi thêm X pip thuận lợi thì dời SL thêm X pip

input group "3d - Sell D (+/−) — lot / TP / Trading Stop —"
input bool   EnableLegSellD = true;              // Bật/tắt chân Sell D (trên + dưới gốc)
input double VGridL1SellD = 0.01;
input ENUM_LOT_SCALE VGridScaleSellD = LOT_ARITHMETIC;
input double VGridLotAddSellD = 0.01;
input double VGridLotMultSellD = 0.3;
input double VGridMaxLotSellD = 1.0;
input bool   VGridTpNextSellD = true;
input double VGridTpPipsSellD = 0.0;
input double VGridTradingStopTriggerPipsSellD = 0.0; // Trading Stop 3d: đạt lãi X pip thì kích hoạt (0 = tắt)
input double VGridTradingStopLockPipsSellD = 0.0;  // Trading Stop 3d: khi kích hoạt đặt SL dương +X1 pip từ giá mở
input double VGridTradingStopStepPipsSellD = 0.0;  // Trading Stop 3d: cứ đi thêm X pip thuận lợi thì dời SL thêm X pip

input group "3Z - Auto lot đầu (float phiên âm) —"
input bool   EnableSessionFloatLossAutoFirstLot = false;  // Bật: float lệnh mở phiên ≤ −X USD → L1 chờ ảo = lot đầu (các bậc theo gấp thếp chân)
input double SessionFloatLossAutoFirstLotThresholdUSD = 2000.0; // X USD chung (3Z): float phiên ≤ −X → kích hoạt auto lot / ngưỡng gồng (nếu bật)
input double SessionFloatLossAutoFirstLotL1 = 0.02;    // Lot bậc 1 chờ ảo khi kích hoạt (lệnh market đang mở giữ nguyên lot)
input bool   EnableSessionFloatLossCompoundTriggerAdjust = true; // Bật: float phiên ≤ −X → ngưỡng gốc gồng lãi tổng = ngưỡng mới (vẫn + carry)
input double SessionFloatLossCompoundTriggerUSD = 500.0; // Ngưỡng gốc gồng lãi tổng (USD) khi kích hoạt 3Z; thực = gốc + carry

input group "4) SL CHUNG LƯỚI (chân A/B/C/D) —"
input bool   EnableGridCommonStopLoss = false; // Bật: SL chung Buy dưới gốc / Sell trên gốc (X pip); lỗ khi chạm SL → carry (nếu bật carry)
input double GridCommonSlPipsFromBase = 3000.0; // X pip: Buy SL = gốc − X; Sell SL = gốc + X (một mức cho cả phía)

input group "5) GỒNG LÃI TỔNG (6B1) —"
input bool   EnableCompoundCarry = false; // Bật: deal OUT âm cộng carry → ngưỡng gồng = gốc + carry; tắt = không cộng carry
input bool   EnableCompoundTotalFloatingProfit = true; // Bật gồng lãi tổng 6b1 (Stop)
input ENUM_COMPOUND_TRIGGER_PROGRESS_MODE CompoundTriggerProgressMode = COMPOUND_PROGRESS_OPEN_PLUS_SESSION_CLOSED_SL_TP; // Chế độ ngưỡng gồng lãi tổng
input double CompoundTotalProfitTriggerUSD = 10.0; // Ngưỡng gốc (USD); ngưỡng thực = gốc (+ carry nếu bật carry)
input bool   CompoundResetOnCommonSlHit = true; // Chạm SL chung thì reset
input ENUM_COMPOUND_CLEAR_PENDING_MODE CompoundClearPendingOnCommonSl = COMPOUND_CLEAR_PENDING; // Khi đặt SL chung gồng: chờ ảo/broker
input bool   EnableCompoundSlPauseUntilNextServerDay = false; // Bật: gồng lãi tổng chạm SL chung → tạm dừng EA tới ngày server kế tiếp mới cho khởi động
input ENUM_COMPOUND_POINT_A_MODE CompoundPointAMode = COMPOUND_POINT_A_MODE_2; // Chế độ xác định điểm A (1 hoặc 2)

input group "6) RSI — khởi động EA —"
input bool   EnableStartupRsiCrossUpFilter = false;      // Bật: chờ RSI cắt lên X1 và/hoặc cắt xuống X2 (nến đóng) rồi mới đặt gốc
input ENUM_TIMEFRAMES StartupRsiTimeframe = PERIOD_M1;   // Khung RSI; PERIOD_CURRENT = khung chart
input int    StartupRsiPeriod = 14;                      // Chu kỳ RSI
input double StartupRsiCrossUpLevel = 70.0;              // X1 cắt lên (RSI shift1 > X1 và shift2 ≤ X1); 0 = không dùng
input int    StartupRsiPreCrossUpBarsBelowX1 = 0;        // Trước cắt lên X1: X nến đóng liên tiếp RSI < X1; 0 = bỏ
input double StartupRsiCrossDownLevel = 30.0;            // X2 cắt xuống (RSI shift1 < X2 và shift2 ≥ X2); 0 = không dùng
input int    StartupRsiPreCrossDownBarsAboveX2 = 0;      // Trước cắt xuống X2: X nến đóng liên tiếp RSI > X2; 0 = bỏ

input group "6b · EMA — lọc chiều lưới —"
input bool   EnableEmaDirectionFilter = true; // Bật: khóa chiều Buy/Sell theo nến đóng vs EMA (đến khi EA reset)
input ENUM_EMA_DIRECTION_MODE EmaDirectionMode = EMA_DIRECTION_HIGH_LOW; // Chế độ lọc EMA
input ENUM_TIMEFRAMES EmaDirectionTimeframe = PERIOD_M15; // Khung EMA; PERIOD_CURRENT = khung chart
input int    EmaDirectionPeriod = 50;        // Chu kỳ EMA

input group "7) THÔNG BÁO —"
input bool EnableResetNotification = true;     // Gửi thông báo MT5
input bool EnableTelegram = true;              // Gửi Telegram
input bool TelegramDeletePreviousBotMessagesOnNotify = true; // Xóa tin bot cũ trước khi gửi tin mới
input string TelegramBotToken = "";            // Telegram bot token
input string TelegramChatID = "";              // Telegram chat id

// Cấu hình Telegram nâng cao giữ nguyên mặc định, không cho chỉnh bằng input.
bool EnableTelegramResetNotification = true;
bool EnableTelegramStartupScreenshot = true;
int  TelegramScreenshotWidth = 1280;
int  TelegramScreenshotHeight = 720;

input group "8) PANEL BIỂU ĐỒ —"
input bool   EnableMonthlyProfitPanel = true;        // Hiện panel lợi nhuận tháng
input bool   EnableEaAutoResetCountPanel = true;     // Hiện số lần EA reset tự động trong bảng lợi nhuận tháng
input bool   EnableBaseLineAndEaStartMarker = true;  // Hiện đường gốc + mốc thời gian bắt đầu EA

//--- Global variables
CTrade trade;
double pnt;
int dgt;
double basePrice;                               // Base price (base line)
double gridLevels[];                            // Giá từng mức (khoảng đều theo D)
double gridStep;                                // Bước tham chiếu (price): dung sai / khớp mức; khởi tạo trong InitializeGridLevels
double lastTickBid = 0.0;
double lastTickAsk = 0.0;
double attachBalance = 0.0;                    // Số dư ledger lúc gắn EA — không cập nhật khi nạp/rút; thành phần trong TEV
double initialCapitalBaselineUSD = 0.0;        // TEV một lần lúc OnInit — mốc % trong tin (không đổi mỗi reset phiên)
datetime eaAttachTime = 0;                     // OnInit time: chỉ cộng deal OUT vào eaCumulativeTradingPL khi deal >= thời điểm này
double eaCumulativeTradingPL = 0.0;            // Tổng (profit+swap+comm) deal OUT cùng magic symbol từ lúc gắn EA — không nạp/rút
double sessionPeakTradingEquityView = 0.0;   // Cao nhất (attachBalance + eaCumulativeTradingPL + float magic) trong phiên lưới
double sessionMinTradingEquityView = 0.0;     // Thấp nhất — cùng công thức; không tính nạp/rút
double globalPeakTradingEquityView = 0.0;    // Cao nhất kể từ gắn EA
double globalMinTradingEquityView = 0.0;       // Thấp nhất kể từ gắn EA
double sessionMaxSingleLot = 0.0;              // Largest single position lot in session
double sessionTotalLotAtMaxLot = 0.0;         // Total open lot when that max single lot occurred
double globalMaxSingleLot = 0.0;              // Largest single lot since EA attach (not reset)
double globalTotalLotAtMaxLot = 0.0;          // Total open lot at that time since EA attach (not reset)
datetime sessionStartTime = 0;                // Current session: starts when EA attached or EA reset. Only P/L and orders from this time.
double sessionStartBalance = 0.0;             // TEV (vốn giao dịch quan sát) lúc bắt đầu phiên lưới — không phản ánh nạp/rút đơn thuần
int MagicAA = 0;                              // Strategy magic (= MagicNumber in OnInit)
bool g_runtimeSessionActive = true;           // false: tạm dừng sau SL gồng lãi tổng (chờ ngày server kế)
bool g_compoundTotalProfitActive = false;     // Chế độ gồng lãi tổng (nhóm 6b): SL chung, không nạp chờ ảo, SL trượt
bool g_compoundBuyBasketMode = false;         // true = giá Bid≥gốc: giữ BUY, SL chung buy; false = dưới gốc: giữ SELL
double g_compoundCommonSlLine = 0.0;          // Giá SL chung (0 = chưa đặt bước đầu); Buy: SL dưới giá; Sell: SL trên giá
bool g_compoundAfterClearWaitGrid = false;    // true: đã khóa A lúc đạt ngưỡng — chờ ≥1 bậc lưới
double g_compoundFrozenRefPx = 0.0;           // Điểm A (khóa khi đạt ngưỡng; reset khi dưới ngưỡng)
bool g_compoundPointASessionLocked = false;   // true: đã đặt SL chung — giữ A đến hết phiên lưới
bool g_compoundActivationBuyBasket = false; // (legacy, không dùng)
bool g_compoundArmed = false;                 // (legacy, không dùng)
bool g_compoundArmBuyBasket = false;          // (legacy, không dùng)
bool g_compoundThresholdReached = false;      // (legacy, không dùng)
double g_balanceCompoundCarryUsd = 0.0;       // Carry tổng (cộng dồn): mọi deal OUT âm sau gắn EA → +|lỗ|; ngưỡng 6B1 = gốc + carry (1:1, không trần)
bool     g_compoundCommonSlCarrySuppress = false; // true: deal OUT SL âm từ SL chung gồng → không cộng carry
bool     g_compoundCommonSlHitPendingReset = false; // broker khớp SL chung → reset EA khi hết vị thế
double g_carryTotalUsdAtGridSessionStart = 0.0; // Mốc carry tại bắt đầu phiên lưới — chỉ hiển thị carry phiên / reset 6h; không trừ khỏi ngưỡng gồng
double g_compoundSessionClosedSlTpProfitSwapUsd = 0.0; // 6b: Σ(profit+swap) deal OUT SL/TP trong phiên hiện tại (magic+symbol), không commission
double g_gridCommonSlBuyLine = 0.0;            // SL chung mọi Buy: gốc − X pip
double g_gridCommonSlSellLine = 0.0;           // SL chung mọi Sell: gốc + X pip
string g_baseLineObjectName = "VGridABCD_BaseLine";
#define VGRIDABCD_EA_START_VLINE "VGridABCD_EAStart_V"
#define VGRIDABCD_EA_START_TEXT "VGridABCD_EAStart_T"
#define VGRIDABCD_COMPOUND_POINT_A_LINE "VGridABCD_CompoundPointA"
datetime g_mpViewMonthStart = 0;               // 10: ngày 1 00:00:00 (server) của tháng đang xem trên panel
ulong    g_mpLastRedrawTick = 0;               // hạn chế vẽ lại panel (ms)
bool     g_mpPanelWasEnabled = false;          // tránh gọi DeleteAll lặp khi input tắt
bool     g_mpAutoFollowCurrentMonth = true;    // true: tự nhảy sang tháng hiện tại khi qua tháng mới (server)
datetime g_mpLastSeenServerMonthStart = 0;     // theo dõi mốc tháng server để reset panel khi sang tháng
bool     g_isOnInitBootstrap = false;          // true trong lúc OnInit để tránh gửi Telegram reset trùng với tin ảnh lúc vừa gắn EA
long     g_telegramNotifyMsgIds[];             // lưu message_id Telegram bot để tùy chọn xóa tin cũ
long     g_compoundSlPauseDateKey = 0;         // ngày server khóa sau SL chung gồng lãi tổng (0 = không khóa)
long     g_compoundSlPauseLoggedDateKey = 0;   // tránh log lặp khi đang khóa SL chung gồng
int      g_startupRsiHandle = INVALID_HANDLE;  // iRSI chờ tín hiệu khởi động trước khi đặt gốc
bool     g_startupRsiCrossLatch = false;       // đã thấy RSI cắt lên X1 / cắt xuống X2 → cho phép đặt gốc
datetime g_startupRsiLastCheckedBar1 = 0;    // nến đóng shift1 đã quét gần nhất
int      g_emaDirectionHandle = INVALID_HANDLE; // iMA EMA(Close) lọc chiều — chế độ Close
int      g_emaDirectionHandleHigh = INVALID_HANDLE; // iMA EMA(High) — chế độ High/Low
int      g_emaDirectionHandleLow = INVALID_HANDLE;  // iMA EMA(Low) — chế độ High/Low
int      g_emaDirectionLock = 0;               // 0=chưa khóa; +1=phiên Buy; −1=phiên Sell (khóa lúc đặt gốc đến reset EA)
datetime g_emaHighLowWaitLoggedBar = 0;        // nến shift1 đã log "chờ vùng EMA" (High/Low)
long     g_eaAutoResetCount = 0;               // Số lần EA reset tự động — cộng dồn từ lúc gắn EA
bool     g_sessionFloatLossAutoFirstLotActive = false; // auto lot đầu chờ ảo đã kích hoạt trong phiên
bool     g_sessionFloatLossCompoundTriggerActive = false; // ngưỡng gồng lãi tổng đã điều chỉnh trong phiên
//--- Sau khi chờ ảo khớp market: chặn bổ sung lại chờ ảo cùng phía/mức cho tới khi vị thế hiện hoặc hết hạn
#define VPGRID_VIRTUAL_EXEC_COOLDOWN_SEC 5
struct VirtualExecCooldownEntry
{
   double   priceLevel;
   bool     isBuy;
   ENUM_VGRID_LEG leg;
   datetime expireUtc;
};
VirtualExecCooldownEntry g_virtualExecCooldown[];

//--- Virtual pending: do not place broker pending orders; when price touches level -> Market + TP
struct VirtualPendingEntry
{
   long              magic;
   ENUM_ORDER_TYPE   orderType;
   ENUM_VGRID_LEG    leg;
   double            priceLevel;
   int               levelNum;
   double            tpPrice;
   double            lot;
};
VirtualPendingEntry g_virtualPending[];

//--- Snapshot TP trước khi gỡ (điểm A active) — khôi phục khi reset điểm A
#define COMPOUND_TP_RESTORE_POSITION 0
#define COMPOUND_TP_RESTORE_VIRTUAL  1
#define COMPOUND_TP_RESTORE_BROKER   2
struct CompoundTpRestoreEntry
{
   int               kind;
   ulong             ticket;
   long              magic;
   ENUM_ORDER_TYPE   orderType;
   ENUM_VGRID_LEG    leg;
   double            priceLevel;
   double            tpPrice;
   double            slPrice;
};
CompoundTpRestoreEntry g_compoundTpRestore[];
bool g_compoundTpSnapshotTaken = false;

void VirtualPendingClear();
void GridPendingEntryModeSync();
bool GridUsesVirtualPendingMode();
bool GridUsesBrokerPendingMode();
bool OrderCommentIsGridPending(const string cmt);
void BrokerPendingClearAll();
bool BrokerPendingFindAtLevel(ENUM_ORDER_TYPE orderType,
                              ENUM_VGRID_LEG leg,
                              double priceLevel,
                              ulong &ticket,
                              double &orderPrice,
                              long whichMagic);
void PlacePendingOrder(ENUM_ORDER_TYPE orderType, ENUM_VGRID_LEG leg, double priceLevel, int levelNum);
void ManageGridOrders();
void CompoundResetAfterCommonSlHit();
bool CompoundPriceTouchesCommonSlLine();
bool CompoundDealOutIsCommonSlHit(const ulong deal);
void CompoundTryResetAfterCommonSlHit(const string reason);
double GridPriceTolerance();
double GetCompoundBaseTriggerUsd();
double GetCompoundFloatingTriggerThresholdUsd();
double GetCompoundCarryContributionUsd();
void CompoundCarryUsdSetTotal(const double newTotalUsd);
void CompoundCarryApplyFromDealOut(const double profitSwapUsd);
double GetCarryInSessionUsd(void);
void UpdateBaseLineOnChart();
void UpdateCompoundPointALineOnChart();
void EaStartTimeObjectsApplyOrRemove();
void ProcessGridCommonStopLoss();
bool GridCommonSlBlockedByCompoundMode();
bool IsVirtualGridLegEnabled(const ENUM_VGRID_LEG leg);
bool TryPlaceBaseAfterStartupFilters();
void StartupRsiCrossResetLatch();
void StartupRsiReleaseHandle();
bool StartupRsiInitHandle();
bool StartupRsiPollCrossLatch(const bool forceRecheck);
bool StartupRsiAllowsBasePlacement();
void EmaDirectionClearLock();
void EmaDirectionReleaseHandle();
bool EmaDirectionInitHandle();
void EmaDirectionSnapshotLockAtSessionStart();
void EmaDirectionSnapshotHighLowAtSessionStart();
bool EmaDirectionTrySetLockFromClosedBar();
void EmaDirectionPollLockIfNeeded();
void EmaDirectionLogHighLowWaitIfNeeded();
bool EmaDirectionAllowsLeg(const ENUM_VGRID_LEG leg);
bool EmaDirectionAllowsBasePlacement();
void EmaDirectionPurgeBlockedSidePendings();
void SessionFloatLossAdjustReset();
void SessionFloatLossAdjustPoll();
double VirtualGridResolvedTradingStopTriggerPips(const ENUM_VGRID_LEG leg);
double VirtualGridResolvedTradingStopLockPips(const ENUM_VGRID_LEG leg);
double VirtualGridResolvedTradingStopStepPips(const ENUM_VGRID_LEG leg);
bool VirtualGridLegTradingStopEnabled(const ENUM_VGRID_LEG leg);
void ProcessVirtualGridLegTradingStops();
long ServerDateKey(const datetime t);
bool IsCompoundSlPauseActiveNow(const datetime nowSrv);
void MonthlyProfitPanelDeleteAll();
void MonthlyProfitPanelRedrawIfNeeded(const bool force);
void MonthlyProfitPanelOnInitState();
void MonthlyProfitPanelOnTradeRefresh();
void EaAutoResetCountPanelDeleteAll();
void EaAutoResetCountPanelUpdate();
void EaRecordAutoResetCount(const string reason);
void CompoundFloatThrHudDeleteAll();
void CompoundFloatThrHudUpdate(const bool isEaGridReset);
void SendStartupTelegramScreenshot(const string reason);

//+------------------------------------------------------------------+
//| True if magic belongs to this EA                                   |
//+------------------------------------------------------------------+
bool IsOurMagic(long magic)
{
   return (magic == MagicAA);
}

//+------------------------------------------------------------------+
//| Vị thế / lệnh chờ: đúng magic EA (MagicAA) + symbol chart này     |
//+------------------------------------------------------------------+
bool PositionIsOurSymbolAndMagic(const ulong ticket)
{
   if(ticket == 0) return false;
   if(!PositionSelectByTicket(ticket)) return false;
   return IsOurMagic(PositionGetInteger(POSITION_MAGIC)) && PositionGetString(POSITION_SYMBOL) == _Symbol;
}

bool OrderIsOurSymbolAndMagic(const ulong ticket)
{
   if(ticket == 0) return false;
   if(!OrderSelect(ticket)) return false;
   return IsOurMagic(OrderGetInteger(ORDER_MAGIC)) && OrderGetString(ORDER_SYMBOL) == _Symbol;
}

//+------------------------------------------------------------------+
//| Swap helpers for sort by distance                                |
//+------------------------------------------------------------------+
string VirtualGridLegCode(const ENUM_VGRID_LEG leg)
{
   switch(leg)
   {
      case VGRID_LEG_BUY_ABOVE:
      case VGRID_LEG_BUY_BELOW: return "A";
      case VGRID_LEG_BUY_ABOVE_E:
      case VGRID_LEG_BUY_BELOW_H: return "B";
      case VGRID_LEG_SELL_ABOVE:
      case VGRID_LEG_SELL_BELOW: return "C";
      case VGRID_LEG_SELL_ABOVE_G:
      case VGRID_LEG_SELL_BELOW_F: return "D";
   }
   return "A";
}

bool VirtualGridLegIsAboveBaseSide(const ENUM_VGRID_LEG leg)
{
   return (leg == VGRID_LEG_BUY_ABOVE || leg == VGRID_LEG_BUY_ABOVE_E
        || leg == VGRID_LEG_SELL_ABOVE || leg == VGRID_LEG_SELL_ABOVE_G);
}

bool VirtualGridLegMatchesLevelSide(const ENUM_VGRID_LEG leg, const int signedLevelNum)
{
   if(signedLevelNum > 0)
      return VirtualGridLegIsAboveBaseSide(leg);
   if(signedLevelNum < 0)
      return !VirtualGridLegIsAboveBaseSide(leg);
   return false;
}

bool OurSymbolMagicHasAnyOpenPosition()
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      const ulong t = PositionGetTicket(i);
      if(t > 0 && PositionIsOurSymbolAndMagic(t))
         return true;
   }
   return false;
}

bool OurSymbolMagicHasOpenBuyPosition()
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      const ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t))
         continue;
      if(!PositionIsOurSymbolAndMagic(t))
         continue;
      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
         return true;
   }
   return false;
}

bool OurSymbolMagicHasOpenSellPosition()
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      const ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t))
         continue;
      if(!PositionIsOurSymbolAndMagic(t))
         continue;
      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)
         return true;
   }
   return false;
}

string BuildOrderCommentWithLevel(const ENUM_VGRID_LEG leg, const int levelNum)
{
   return "VGridABCD|" + VirtualGridLegCode(leg) + "|L" + (levelNum > 0 ? "+" : "") + IntegerToString(levelNum);
}

bool TryParseSignedLevelFromOrderComment(const string cmt, int &signedLevelOut)
{
   signedLevelOut = 0;
   const int p = StringFind(cmt, "|L");
   if(p < 0)
      return false;
   const int s = p + 2;
   if(s >= StringLen(cmt))
      return false;
   string levelStr = StringSubstr(cmt, s);
   const int tailSep = StringFind(levelStr, "|");
   if(tailSep >= 0)
      levelStr = StringSubstr(levelStr, 0, tailSep);
   if(StringLen(levelStr) < 1)
      return false;
   signedLevelOut = (int)StringToInteger(levelStr);
   return (signedLevelOut != 0);
}

bool TryParseLegFromOrderComment(const string cmt, ENUM_VGRID_LEG &legOut)
{
   int lvl = 0;
   const bool hasLvl = TryParseSignedLevelFromOrderComment(cmt, lvl);
   const bool below = (hasLvl && lvl < 0);

   if(StringFind(cmt, "|A|") >= 0) { legOut = below ? VGRID_LEG_BUY_BELOW : VGRID_LEG_BUY_ABOVE; return true; }
   if(StringFind(cmt, "|B|") >= 0) { legOut = below ? VGRID_LEG_BUY_BELOW_H : VGRID_LEG_BUY_ABOVE_E; return true; }
   if(StringFind(cmt, "|C|") >= 0) { legOut = below ? VGRID_LEG_SELL_BELOW : VGRID_LEG_SELL_ABOVE; return true; }
   if(StringFind(cmt, "|D|") >= 0) { legOut = below ? VGRID_LEG_SELL_BELOW_F : VGRID_LEG_SELL_ABOVE_G; return true; }
   // Legacy comment (bản cũ A/B/E/F)
   if(StringFind(cmt, "|E|") >= 0) { legOut = below ? VGRID_LEG_BUY_BELOW_H : VGRID_LEG_BUY_ABOVE_E; return true; }
   if(StringFind(cmt, "|F|") >= 0) { legOut = below ? VGRID_LEG_SELL_BELOW_F : VGRID_LEG_SELL_ABOVE_G; return true; }
   if(StringFind(cmt, "|G|") >= 0) { legOut = VGRID_LEG_SELL_ABOVE_G; return true; }
   if(StringFind(cmt, "|H|") >= 0) { legOut = VGRID_LEG_BUY_BELOW_H; return true; }
   return false;
}

bool IsVirtualGridLegBuyEntryLeg(const ENUM_VGRID_LEG leg)
{
   return (leg == VGRID_LEG_BUY_ABOVE || leg == VGRID_LEG_BUY_BELOW
        || leg == VGRID_LEG_BUY_ABOVE_E || leg == VGRID_LEG_BUY_BELOW_H);
}

bool IsVirtualGridLegSellEntryLeg(const ENUM_VGRID_LEG leg)
{
   return (leg == VGRID_LEG_SELL_ABOVE || leg == VGRID_LEG_SELL_BELOW
        || leg == VGRID_LEG_SELL_ABOVE_G || leg == VGRID_LEG_SELL_BELOW_F);
}

bool IsVirtualGridLegEnabled(const ENUM_VGRID_LEG leg)
{
   switch(leg)
   {
      case VGRID_LEG_BUY_ABOVE:
      case VGRID_LEG_BUY_BELOW:
         return EnableLegBuyA;
      case VGRID_LEG_BUY_ABOVE_E:
      case VGRID_LEG_BUY_BELOW_H:
         return EnableLegBuyB;
      case VGRID_LEG_SELL_ABOVE:
      case VGRID_LEG_SELL_BELOW:
         return EnableLegSellC;
      case VGRID_LEG_SELL_ABOVE_G:
      case VGRID_LEG_SELL_BELOW_F:
         return EnableLegSellD;
      default:
         return false;
   }
}

//+------------------------------------------------------------------+
//| Remove virtual pendings at a level for a side (buy/sell)          |
//+------------------------------------------------------------------+
void RemoveVirtualPendingsAtLevelSide(double priceLevel, bool isBuy, long whichMagic)
{
   if(!IsOurMagic(whichMagic)) return;
   double tolerance = GridPriceTolerance();
   if(GridUsesVirtualPendingMode())
   {
      for(int i = ArraySize(g_virtualPending) - 1; i >= 0; i--)
      {
         if(g_virtualPending[i].magic != whichMagic) continue;
         if(MathAbs(g_virtualPending[i].priceLevel - priceLevel) >= tolerance) continue;
         ENUM_ORDER_TYPE ot = g_virtualPending[i].orderType;
         bool entryBuy = (ot == ORDER_TYPE_BUY_STOP || ot == ORDER_TYPE_BUY_LIMIT);
         if(entryBuy == isBuy)
            VirtualPendingRemoveAt(i);
      }
      return;
   }
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderIsOurSymbolAndMagic(ticket)) continue;
      if(!OrderCommentIsGridPending(OrderGetString(ORDER_COMMENT))) continue;
      const double op = OrderGetDouble(ORDER_PRICE_OPEN);
      if(MathAbs(op - priceLevel) >= tolerance) continue;
      const ENUM_ORDER_TYPE ot = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      const bool entryBuy = (ot == ORDER_TYPE_BUY_STOP || ot == ORDER_TYPE_BUY_LIMIT);
      if(entryBuy == isBuy)
         trade.OrderDelete(ticket);
   }
}

//+------------------------------------------------------------------+
//| Find signed grid level number (+/-1..+/-Max) for a price (by tolerance) |
//+------------------------------------------------------------------+
bool FindSignedLevelNumForPrice(double price, int &signedLevelNum)
{
   signedLevelNum = 0;
   if(basePrice <= 0.0 || ArraySize(gridLevels) < 1)
      return false;
   double tol = GridPriceTolerance();
   for(int i = 0; i < ArraySize(gridLevels); i++)
   {
      if(MathAbs(gridLevels[i] - price) < tol)
      {
         signedLevelNum = GridSignedLevelNumFromIndex(i);
         return (signedLevelNum != 0);
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Modify SL/TP for a specific position ticket (hedging-safe)        |
//+------------------------------------------------------------------+
bool ModifyPositionSLTP(ulong positionTicket, double newSL, double keepTP)
{
   if(positionTicket == 0)
      return false;
   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);
   req.action   = TRADE_ACTION_SLTP;
   req.position = (ulong)positionTicket;
   req.symbol   = _Symbol;
   req.sl       = newSL;
   req.tp       = keepTP;
   bool ok = OrderSend(req, res);
   if(!ok)
      Print("VGridABCD: SLTP send fail ticket ", positionTicket, " err ", GetLastError());
   return ok;
}

//+------------------------------------------------------------------+
//| Bước giá một mức lưới (dùng gridStep; nếu 0 thì từ D pip).         |
//+------------------------------------------------------------------+
double CompoundModeGridStepPrice()
{
   if(gridStep > 0.0)
      return gridStep;
   return MathMax(pnt * 10.0 * GridDistancePips, pnt);
}

//+------------------------------------------------------------------+
//| 1 pip giá (cùng quy ước bước pip lưới: 10 × point).                 |
//+------------------------------------------------------------------+
double OnePipPrice()
{
   return pnt * 10.0;
}

//+------------------------------------------------------------------+
//| SL chung lưới: tắt khi đang 6B1 (SL chung gồng lãi riêng).         |
//+------------------------------------------------------------------+
bool GridCommonSlBlockedByCompoundMode()
{
   return g_compoundTotalProfitActive;
}

double GridCommonSlMinStopDistance()
{
   const double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   const int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const int freezeLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double minDist = (double)MathMax(stopsLevel, freezeLevel) * pt;
   if(minDist < pt * 2.0)
      minDist = pt * 2.0;
   return minDist;
}

bool GridCommonSlComputeLines(double &buyLineOut, double &sellLineOut)
{
   buyLineOut = 0.0;
   sellLineOut = 0.0;
   if(basePrice <= 0.0 || !MathIsValidNumber(basePrice))
      return false;
   const double pipDist = MathMax(0.0, GridCommonSlPipsFromBase);
   if(pipDist <= 0.0)
      return false;
   const double off = pipDist * OnePipPrice();
   buyLineOut = NormalizeDouble(basePrice - off, dgt);
   sellLineOut = NormalizeDouble(basePrice + off, dgt);
   return (buyLineOut > 0.0 && sellLineOut > 0.0);
}

//+------------------------------------------------------------------+
//| Đặt SL chung: mọi Buy → gốc−X pip; mọi Sell → gốc+X pip.           |
//+------------------------------------------------------------------+
void ProcessGridCommonStopLoss()
{
   if(!EnableGridCommonStopLoss)
      return;
   if(basePrice <= 0.0 || GridCommonSlBlockedByCompoundMode())
      return;

   double lineBuy = 0.0;
   double lineSell = 0.0;
   if(!GridCommonSlComputeLines(lineBuy, lineSell))
      return;

   g_gridCommonSlBuyLine = lineBuy;
   g_gridCommonSlSellLine = lineSell;

   const double minDist = GridCommonSlMinStopDistance();
   const double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   trade.SetExpertMagicNumber(MagicAA);

   for(int p = 0; p < PositionsTotal(); p++)
   {
      const ulong ticket = PositionGetTicket(p);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(!PositionIsOurSymbolAndMagic(ticket))
         continue;

      const ENUM_POSITION_TYPE ptp = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      const double curSL = PositionGetDouble(POSITION_SL);
      const double curTP = PositionGetDouble(POSITION_TP);
      ENUM_VGRID_LEG posLeg = VGRID_LEG_BUY_ABOVE;
      const string cmt = PositionGetString(POSITION_COMMENT);
      if(TryParseLegFromOrderComment(cmt, posLeg) && VirtualGridLegTradingStopEnabled(posLeg))
         continue;
      double newSL = 0.0;

      if(ptp == POSITION_TYPE_BUY)
      {
         newSL = lineBuy;
         if(newSL <= 0.0 || newSL >= bid - minDist)
            continue;
         if(curSL > 0.0 && MathAbs(curSL - newSL) < pt)
            continue;
      }
      else if(ptp == POSITION_TYPE_SELL)
      {
         newSL = lineSell;
         if(newSL <= 0.0 || newSL <= ask + minDist)
            continue;
         if(curSL > 0.0 && MathAbs(curSL - newSL) < pt)
            continue;
      }
      else
         continue;

      ModifyPositionSLTP(ticket, newSL, curTP);
   }
}

//+------------------------------------------------------------------+
//| Vị thế mở trong phiên lưới (cùng quy tắc đếm P/L phiên).           |
//+------------------------------------------------------------------+
bool CompoundPositionPassesSessionFilter(const ulong ticket)
{
   if(!PositionSelectByTicket(ticket))
      return false;
   if(sessionStartTime <= 0)
      return true;
   return ((datetime)PositionGetInteger(POSITION_TIME) >= sessionStartTime);
}

void CompoundRestoreTpAfterPointAReset();

void CompoundPointAClearSession()
{
   CompoundRestoreTpAfterPointAReset();
   g_compoundPointASessionLocked = false;
   g_compoundAfterClearWaitGrid = false;
   g_compoundFrozenRefPx = 0.0;
}

void CompoundResetPointAOnly()
{
   if(g_compoundPointASessionLocked)
      return;
   if(!g_compoundAfterClearWaitGrid && g_compoundFrozenRefPx <= 0.0)
      return;
   CompoundRestoreTpAfterPointAReset();
   g_compoundAfterClearWaitGrid = false;
   g_compoundFrozenRefPx = 0.0;
}

void CompoundModeClearState()
{
   g_compoundTotalProfitActive = false;
   g_compoundBuyBasketMode = false;
   g_compoundCommonSlLine = 0.0;
   g_compoundAfterClearWaitGrid = false;
   if(!g_compoundPointASessionLocked)
      g_compoundFrozenRefPx = 0.0;
   g_compoundArmed = false;
   g_compoundArmBuyBasket = false;
   g_compoundThresholdReached = false;
   g_compoundCommonSlHitPendingReset = false;
   CompoundFloatThrHudUpdate(false);
}

//+------------------------------------------------------------------+
//| true = không đặt thêm lệnh chờ (đạt ngưỡng hoặc đang gồng).      |
//+------------------------------------------------------------------+
bool CompoundBlocksNewPendingOrders()
{
   // Chỉ chặn bổ sung chờ ảo sau khi đã đặt SL chung (bước 2)
   return g_compoundTotalProfitActive;
}

//+------------------------------------------------------------------+
//| Ngưỡng gốc gồng 6B1: input 5 hoặc ngưỡng mới (3Z) khi float phiên âm. |
//+------------------------------------------------------------------+
double GetCompoundBaseTriggerUsd()
{
   if(EnableSessionFloatLossCompoundTriggerAdjust && g_sessionFloatLossCompoundTriggerActive)
      return MathMax(0.0, SessionFloatLossCompoundTriggerUSD);
   return CompoundTotalProfitTriggerUSD;
}

//+------------------------------------------------------------------+
//| Ngưỡng Σ(profit+swap) mở cho logic gồng 6b (ARM + chờ bước hủy).   |
//+------------------------------------------------------------------+
double GetCompoundFloatingTriggerThresholdUsd()
{
   return GetCompoundBaseTriggerUsd() + GetCompoundCarryContributionUsd();
}

//| Toàn bộ carry tổng cộng vào ngưỡng gồng 6B1 (1 USD lỗ đóng âm → +1 USD ngưỡng, không giới hạn). |
double GetCompoundCarryContributionUsd()
{
   if(!EnableCompoundCarry)
      return 0.0;
   return MathMax(0.0, g_balanceCompoundCarryUsd);
}

//+------------------------------------------------------------------+
//| Gán carry tổng → đóng góp ngưỡng gồng (cộng dồn). Carry phiên =   |
//| hiện tại − g_carryTotalUsdAtGridSessionStart; chỉ xét reset EA 6h. |
//+------------------------------------------------------------------+
void CompoundCarryUsdSetTotal(const double newTotalUsd)
{
   g_balanceCompoundCarryUsd = newTotalUsd;
}

//+------------------------------------------------------------------+
//| Chạm SL chung gồng lãi tổng: deal OUT âm từ SL đó không cộng carry. |
//+------------------------------------------------------------------+
bool CompoundCarrySkipsDealOutFromCompoundCommonSl(const long dealReason, const double profitSwapUsd)
{
   if(profitSwapUsd >= -1e-12)
      return false;

   // Cửa sổ reset sau chạm SL chung (broker SL trễ / EA đóng còn lại): không cộng carry.
   if(g_compoundCommonSlCarrySuppress)
      return true;

   // Đang gồng: lệnh khớp SL chung trên broker.
   if(g_compoundTotalProfitActive
      && (dealReason == DEAL_REASON_SL || dealReason == DEAL_REASON_SO))
      return true;

   return false;
}

//+------------------------------------------------------------------+
//| Đóng âm: +|lỗ| vào carry (ngưỡng gồng 6B1 = gốc + carry).         |
//+------------------------------------------------------------------+
void CompoundCarryApplyFromDealOut(const double profitSwapUsd)
{
   if(!EnableCompoundCarry)
      return;
   if(profitSwapUsd >= -1e-12)
      return;
   const double addUsd = -profitSwapUsd;
   CompoundCarryUsdSetTotal(g_balanceCompoundCarryUsd + addUsd);
   CompoundFloatThrHudUpdate(false);
}

double GetCarryInSessionUsd(void)
{
   if(sessionStartTime <= 0)
      return 0.0;
   return g_balanceCompoundCarryUsd - g_carryTotalUsdAtGridSessionStart;
}

#define COMPOUND_FLOAT_THR_HUD_PREFIX "VGridABCD_CMPFTHR_"
#define COMPOUND_FLOAT_THR_HUD_PREFIX_LEGACY "VGridABCD_CARRYHUD_"

bool CompoundFloatThrHudLabelSet(const string name, const int x, const int y, const string text,
                                   const int fontPx, const color clr, const bool bold,
                                   const ENUM_BASE_CORNER corner)
{
   if(ObjectFind(0, name) >= 0)
      ObjectDelete(0, name);
   if(!ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0))
      return false;
   ObjectSetInteger(0, name, OBJPROP_CORNER, corner);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontPx);
   ObjectSetString(0, name, OBJPROP_FONT, bold ? "Arial Bold" : "Arial");
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   return true;
}

void CompoundFloatThrHudDeleteAll()
{
   string toDel[];
   const int total = ObjectsTotal(0, -1, -1);
   for(int i = 0; i < total; i++)
   {
      const string nm = ObjectName(0, i, -1, -1);
      if(StringFind(nm, COMPOUND_FLOAT_THR_HUD_PREFIX) == 0
         || StringFind(nm, COMPOUND_FLOAT_THR_HUD_PREFIX_LEGACY) == 0)
      {
         const int n = ArraySize(toDel);
         ArrayResize(toDel, n + 1);
         toDel[n] = nm;
      }
   }
   for(int j = 0; j < ArraySize(toDel); j++)
      ObjectDelete(0, toDel[j]);
}

// HUD ngưỡng gồng lãi tổng: vẽ lại khi reset lưới/EA (isEaGridReset) hoặc khi chữ ngưỡng/phiên đổi.
void CompoundFloatThrHudUpdate(const bool isEaGridReset)
{
   static string s_snapL1 = "";
   static string s_snapL2 = "";
   static string s_snapL3 = "";
   static bool s_snapValid = false;

   const ENUM_BASE_CORNER crn = CORNER_RIGHT_UPPER;
   const int x = 14;
   const int y1 = 22;
   const int y2 = 38;
   const int y3 = 54;
   const color C_MUTED = C'140,145,158';
   const color C_BLUE = C'60,150,255';

   string line1;
   if(EnableCompoundTotalFloatingProfit && GetCompoundBaseTriggerUsd() > 0.0)
   {
      const double thrUsd = GetCompoundFloatingTriggerThresholdUsd();
      const double carryUsd = GetCompoundCarryContributionUsd();
      const double baseUsd = GetCompoundBaseTriggerUsd();
      line1 = "Ngưỡng gồng: " + DoubleToString(thrUsd, 2) + " " + AccountInfoString(ACCOUNT_CURRENCY)
            + " (gốc " + DoubleToString(baseUsd, 2);
      if(EnableCompoundCarry)
         line1 += " + carry " + DoubleToString(carryUsd, 2);
      else
         line1 += ", carry tắt";
      line1 += ")";
      if(g_sessionFloatLossCompoundTriggerActive)
         line1 += " [3Z]";
   }
   else
      line1 = "Gồng lãi tổng: tắt hoặc ngưỡng ≤ 0";

   string line2 = "Phiên lưới: ";
   if(sessionStartTime > 0)
      line2 += TimeToString(sessionStartTime, TIME_DATE | TIME_MINUTES);
   else
      line2 += "—";
   if(!g_runtimeSessionActive)
      line2 += "  |  Tạm dừng (SL gồng)";

   string line3;
   if(EnableCompoundCarry)
      line3 = "Carry: BẬT (1:1, không trần) — tổng " + DoubleToString(g_balanceCompoundCarryUsd, 2)
            + " " + AccountInfoString(ACCOUNT_CURRENCY)
            + "  |  phiên " + DoubleToString(GetCarryInSessionUsd(), 2)
            + " " + AccountInfoString(ACCOUNT_CURRENCY);
   else
      line3 = "Carry: TẮT — không cộng lỗ đóng vào ngưỡng gồng";

   if(!isEaGridReset && s_snapValid && line1 == s_snapL1 && line2 == s_snapL2 && line3 == s_snapL3)
      return;
   s_snapValid = true;
   s_snapL1 = line1;
   s_snapL2 = line2;
   s_snapL3 = line3;

   CompoundFloatThrHudLabelSet(COMPOUND_FLOAT_THR_HUD_PREFIX "L1", x, y1, line1, 9, C_BLUE, true, crn);
   CompoundFloatThrHudLabelSet(COMPOUND_FLOAT_THR_HUD_PREFIX "L2", x, y2, line2, 8, C_MUTED, false, crn);
   CompoundFloatThrHudLabelSet(COMPOUND_FLOAT_THR_HUD_PREFIX "L3", x, y3, line3, 7, C_MUTED, false, crn);
   ChartRedraw(0);
}

#define EA_RESET_COUNT_PANEL_PREFIX "VGridABCD_EARST_"

string EaResetCountPanelObjPrefix()
{
   return EA_RESET_COUNT_PANEL_PREFIX + IntegerToString(MagicAA) + "_";
}

void EaAutoResetCountPanelDeleteAll()
{
   const string pref = EaResetCountPanelObjPrefix();
   string toDel[];
   const int total = ObjectsTotal(0, -1, -1);
   for(int i = 0; i < total; i++)
   {
      const string nm = ObjectName(0, i, -1, -1);
      if(StringFind(nm, pref) == 0)
      {
         const int n = ArraySize(toDel);
         ArrayResize(toDel, n + 1);
         toDel[n] = nm;
      }
   }
   for(int j = 0; j < ArraySize(toDel); j++)
      ObjectDelete(0, toDel[j]);
}

void EaAutoResetCountPanelUpdate()
{
   if(EnableMonthlyProfitPanel)
      MonthlyProfitPanelRedrawIfNeeded(true);
}

void EaRecordAutoResetCount(const string reason)
{
   g_eaAutoResetCount++;
   Print("VGridABCD: EA reset tự động lần ", g_eaAutoResetCount,
         (StringLen(reason) > 0 ? (" — " + reason) : ""));
   EaAutoResetCountPanelUpdate();
}

double GetCompoundTriggerProgressUsd(const double totalOpenProfitSwapUsd)
{
   if(CompoundTriggerProgressMode == COMPOUND_PROGRESS_OPEN_PLUS_SESSION_CLOSED_SL_TP)
      return totalOpenProfitSwapUsd + g_compoundSessionClosedSlTpProfitSwapUsd;
   return totalOpenProfitSwapUsd;
}


//+------------------------------------------------------------------+
//| Tổng profit+swap dương của lệnh mở một phía (Buy hoặc Sell).      |
//+------------------------------------------------------------------+
double CompoundSumPositiveOpenProfitForSide(const bool buySide)
{
   double sum = 0.0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(!PositionIsOurSymbolAndMagic(ticket))
         continue;
      if(!CompoundPositionPassesSessionFilter(ticket))
         continue;
      const ENUM_POSITION_TYPE ptp = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(buySide && ptp != POSITION_TYPE_BUY)
         continue;
      if(!buySide && ptp != POSITION_TYPE_SELL)
         continue;
      const double ps = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(ps > 0.0)
         sum += ps;
   }
   return sum;
}

//+------------------------------------------------------------------+
//| Nhãn chế độ điểm A (log).                                          |
//+------------------------------------------------------------------+
string CompoundPointAModeLabel()
{
   if(CompoundPointAMode == COMPOUND_POINT_A_MODE_1)
      return "chế độ 1: Buy trên giá / Sell dưới giá";
   if(CompoundPointAMode == COMPOUND_POINT_A_MODE_2)
      return "chế độ 2: Buy dưới giá / Sell trên giá";
   return "?";
}

//+------------------------------------------------------------------+
//| Điểm A: bậc lưới gần giá nhất phía trên hoặc dưới giá hiện tại.   |
//+------------------------------------------------------------------+
bool CompoundFindPointAFromNearestGridSide(const bool buyReference, const bool wantBelowPrice,
                                           double &refPxOut)
{
   refPxOut = 0.0;
   if(basePrice <= 0.0 || ArraySize(gridLevels) < 1)
      return false;

   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double refPrice = buyReference ? bid : ask;
   const double tol = GridPriceTolerance() * 0.5;

   bool haveRef = false;
   double bestDist = 0.0;

   for(int i = 0; i < ArraySize(gridLevels); i++)
   {
      const double lvlPx = gridLevels[i];
      if(wantBelowPrice)
      {
         if(lvlPx >= refPrice - tol)
            continue;
         const double dist = refPrice - lvlPx;
         if(!haveRef || dist < bestDist - tol)
         {
            refPxOut = lvlPx;
            bestDist = dist;
            haveRef = true;
         }
      }
      else
      {
         if(lvlPx <= refPrice + tol)
            continue;
         const double dist = lvlPx - refPrice;
         if(!haveRef || dist < bestDist - tol)
         {
            refPxOut = lvlPx;
            bestDist = dist;
            haveRef = true;
         }
      }
   }
   return haveRef;
}

//+------------------------------------------------------------------+
//| Điểm A theo CompoundPointAMode (chế độ 1 hoặc 2).                 |
//+------------------------------------------------------------------+
bool CompoundFindPointAForReferenceSide(const bool buyReference, double &refPxOut)
{
   refPxOut = 0.0;
   if(CompoundPointAMode == COMPOUND_POINT_A_MODE_1)
   {
      // Chế độ 1: Buy → lưới trên giá; Sell → lưới dưới giá
      return CompoundFindPointAFromNearestGridSide(buyReference, !buyReference, refPxOut);
   }
   // Chế độ 2: Buy → lưới dưới giá; Sell → lưới trên giá
   return CompoundFindPointAFromNearestGridSide(buyReference, buyReference, refPxOut);
}

//+------------------------------------------------------------------+
//| Giá mức lưới theo bậc ký hiệu ±1, ±2, …                            |
//+------------------------------------------------------------------+
bool CompoundGetGridLevelPriceForSignedLevel(const int signedLvl, double &priceOut)
{
   priceOut = 0.0;
   if(signedLvl == 0 || ArraySize(gridLevels) < 1)
      return false;
   for(int i = 0; i < ArraySize(gridLevels); i++)
   {
      if(GridSignedLevelNumFromIndex(i) == signedLvl)
      {
         priceOut = gridLevels[i];
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Buy: Bid ≥ mức lưới ngay trên A; Sell: Ask ≤ mức lưới ngay dưới A. |
//+------------------------------------------------------------------+
bool CompoundPriceAtLeastOneGridLevelFromPointA(const bool buyReference, const double pointA)
{
   if(pointA <= 0.0 || !MathIsValidNumber(pointA))
      return false;

   const double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double tol = GridPriceTolerance() * 0.5;

   int signedLvl = 0;
   if(!FindSignedLevelNumForPrice(pointA, signedLvl))
   {
      const double step = CompoundModeGridStepPrice();
      if(step <= 0.0)
         return false;
      if(buyReference)
         return (bid - pointA >= step - pt * 0.5);
      return (pointA - ask >= step - pt * 0.5);
   }

   const int adjacentLvl = buyReference ? (signedLvl + 1) : (signedLvl - 1);
   double adjacentPx = 0.0;
   if(!CompoundGetGridLevelPriceForSignedLevel(adjacentLvl, adjacentPx))
   {
      const double step = CompoundModeGridStepPrice();
      if(step <= 0.0)
         return false;
      if(buyReference)
         return (bid - pointA >= step - pt * 0.5);
      return (pointA - ask >= step - pt * 0.5);
   }

   if(buyReference)
      return (bid >= adjacentPx - tol);
   return (ask <= adjacentPx + tol);
}

//+------------------------------------------------------------------+
//| true: điểm A đang có hiệu lực (chờ SL, đang gồng, hoặc khóa phiên). |
//+------------------------------------------------------------------+
bool CompoundPointAIsActive()
{
   return (g_compoundAfterClearWaitGrid || g_compoundTotalProfitActive || g_compoundPointASessionLocked);
}

//+------------------------------------------------------------------+
//| Xóa snapshot TP đã lưu.                                            |
//+------------------------------------------------------------------+
void CompoundTpRestoreClear()
{
   ArrayResize(g_compoundTpRestore, 0);
   g_compoundTpSnapshotTaken = false;
}

//+------------------------------------------------------------------+
//| Lưu TP lệnh phiên trước lần gỡ đầu tiên (khi khóa điểm A).         |
//+------------------------------------------------------------------+
void CompoundTpSnapshotBeforeStrip()
{
   if(g_compoundTpSnapshotTaken)
      return;

   int n = 0;

   for(int p = 0; p < PositionsTotal(); p++)
   {
      const ulong ticket = PositionGetTicket(p);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(!PositionIsOurSymbolAndMagic(ticket))
         continue;
      if(!CompoundPositionPassesSessionFilter(ticket))
         continue;
      const double tp = PositionGetDouble(POSITION_TP);
      if(tp <= 0.0)
         continue;
      ArrayResize(g_compoundTpRestore, n + 1);
      g_compoundTpRestore[n].kind = COMPOUND_TP_RESTORE_POSITION;
      g_compoundTpRestore[n].ticket = ticket;
      g_compoundTpRestore[n].magic = (long)PositionGetInteger(POSITION_MAGIC);
      g_compoundTpRestore[n].orderType = ORDER_TYPE_BUY;
      g_compoundTpRestore[n].leg = VGRID_LEG_BUY_ABOVE;
      g_compoundTpRestore[n].priceLevel = PositionGetDouble(POSITION_PRICE_OPEN);
      g_compoundTpRestore[n].tpPrice = tp;
      g_compoundTpRestore[n].slPrice = PositionGetDouble(POSITION_SL);
      n++;
   }

   for(int i = 0; i < ArraySize(g_virtualPending); i++)
   {
      if(g_virtualPending[i].tpPrice <= 0.0)
         continue;
      ArrayResize(g_compoundTpRestore, n + 1);
      g_compoundTpRestore[n].kind = COMPOUND_TP_RESTORE_VIRTUAL;
      g_compoundTpRestore[n].ticket = 0;
      g_compoundTpRestore[n].magic = g_virtualPending[i].magic;
      g_compoundTpRestore[n].orderType = g_virtualPending[i].orderType;
      g_compoundTpRestore[n].leg = g_virtualPending[i].leg;
      g_compoundTpRestore[n].priceLevel = g_virtualPending[i].priceLevel;
      g_compoundTpRestore[n].tpPrice = g_virtualPending[i].tpPrice;
      g_compoundTpRestore[n].slPrice = 0.0;
      n++;
   }

   if(GridUsesBrokerPendingMode())
   {
      for(int i = OrdersTotal() - 1; i >= 0; i--)
      {
         const ulong ticket = OrderGetTicket(i);
         if(ticket == 0 || !OrderIsOurSymbolAndMagic(ticket))
            continue;
         const double tp = OrderGetDouble(ORDER_TP);
         if(tp <= 0.0)
            continue;
         ArrayResize(g_compoundTpRestore, n + 1);
         g_compoundTpRestore[n].kind = COMPOUND_TP_RESTORE_BROKER;
         g_compoundTpRestore[n].ticket = ticket;
         g_compoundTpRestore[n].magic = (long)OrderGetInteger(ORDER_MAGIC);
         g_compoundTpRestore[n].orderType = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
         g_compoundTpRestore[n].leg = VGRID_LEG_BUY_ABOVE;
         g_compoundTpRestore[n].priceLevel = OrderGetDouble(ORDER_PRICE_OPEN);
         g_compoundTpRestore[n].tpPrice = tp;
         g_compoundTpRestore[n].slPrice = OrderGetDouble(ORDER_SL);
         n++;
      }
   }

   g_compoundTpSnapshotTaken = (n > 0);
   if(g_compoundTpSnapshotTaken)
      Print("VGridABCD: Gồng lãi — lưu ", n, " mức TP trước khi gỡ (điểm A).");
}

//+------------------------------------------------------------------+
//| Khôi phục TP đã lưu khi reset / xóa điểm A.                        |
//+------------------------------------------------------------------+
void CompoundRestoreTpAfterPointAReset()
{
   if(!g_compoundTpSnapshotTaken || ArraySize(g_compoundTpRestore) < 1)
   {
      CompoundTpRestoreClear();
      return;
   }

   trade.SetExpertMagicNumber(MagicAA);
   const double tol = GridPriceTolerance();
   int restored = 0;

   for(int i = 0; i < ArraySize(g_compoundTpRestore); i++)
   {
      const CompoundTpRestoreEntry e = g_compoundTpRestore[i];
      if(e.kind == COMPOUND_TP_RESTORE_POSITION)
      {
         if(!PositionSelectByTicket(e.ticket))
            continue;
         if(!PositionIsOurSymbolAndMagic(e.ticket))
            continue;
         const double curSL = PositionGetDouble(POSITION_SL);
         if(ModifyPositionSLTP(e.ticket, curSL, e.tpPrice))
            restored++;
      }
      else if(e.kind == COMPOUND_TP_RESTORE_VIRTUAL)
      {
         for(int v = 0; v < ArraySize(g_virtualPending); v++)
         {
            if(g_virtualPending[v].magic != e.magic)
               continue;
            if(g_virtualPending[v].orderType != e.orderType)
               continue;
            if(g_virtualPending[v].leg != e.leg)
               continue;
            if(MathAbs(g_virtualPending[v].priceLevel - e.priceLevel) >= tol)
               continue;
            g_virtualPending[v].tpPrice = e.tpPrice;
            restored++;
            break;
         }
      }
      else if(e.kind == COMPOUND_TP_RESTORE_BROKER)
      {
         if(!OrderSelect(e.ticket))
            continue;
         if(!OrderIsOurSymbolAndMagic(e.ticket))
            continue;
         const double price = OrderGetDouble(ORDER_PRICE_OPEN);
         const double sl = OrderGetDouble(ORDER_SL);
         if(trade.OrderModify(e.ticket, price, sl, e.tpPrice, ORDER_TIME_GTC, 0))
            restored++;
      }
   }

   if(restored > 0)
      Print("VGridABCD: Gồng lãi — reset điểm A → khôi phục TP ", restored, " lệnh.");

   CompoundTpRestoreClear();
}

//+------------------------------------------------------------------+
//| Gỡ TP mọi vị thế mở trong phiên lưới hiện tại.                     |
//+------------------------------------------------------------------+
void CompoundRemoveAllTpFromOpenPositions()
{
   trade.SetExpertMagicNumber(MagicAA);
   for(int p = 0; p < PositionsTotal(); p++)
   {
      const ulong ticket = PositionGetTicket(p);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(!PositionIsOurSymbolAndMagic(ticket))
         continue;
      if(!CompoundPositionPassesSessionFilter(ticket))
         continue;
      const double curSL = PositionGetDouble(POSITION_SL);
      const double curTP = PositionGetDouble(POSITION_TP);
      if(curTP > 0.0)
         ModifyPositionSLTP(ticket, curSL, 0.0);
   }
}

//+------------------------------------------------------------------+
//| Gỡ TP trên chờ ảo / broker khi điểm A đang active.                 |
//+------------------------------------------------------------------+
void CompoundStripPendingTpWhenPointAActive()
{
   for(int i = 0; i < ArraySize(g_virtualPending); i++)
   {
      if(g_virtualPending[i].tpPrice > 0.0)
         g_virtualPending[i].tpPrice = 0.0;
   }

   if(!GridUsesBrokerPendingMode())
      return;

   trade.SetExpertMagicNumber(MagicAA);
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderIsOurSymbolAndMagic(ticket))
         continue;
      if(OrderGetDouble(ORDER_TP) <= 0.0)
         continue;
      const double price = OrderGetDouble(ORDER_PRICE_OPEN);
      const double sl = OrderGetDouble(ORDER_SL);
      trade.OrderModify(ticket, price, sl, 0.0, ORDER_TIME_GTC, 0);
   }
}

//+------------------------------------------------------------------+
//| Điểm A active: mọi lệnh phiên hiện tại không có TP.               |
//+------------------------------------------------------------------+
void CompoundEnforceNoTpWhenPointAActive()
{
   if(!CompoundPointAIsActive())
      return;
   CompoundTpSnapshotBeforeStrip();
   CompoundRemoveAllTpFromOpenPositions();
   CompoundStripPendingTpWhenPointAActive();
}

//+------------------------------------------------------------------+
//| Xóa chờ ảo/broker khi đặt SL chung gồng (nếu input bật).           |
//+------------------------------------------------------------------+
void CompoundClearPendingOrdersIfEnabled()
{
   if(CompoundClearPendingOnCommonSl != COMPOUND_CLEAR_PENDING)
      return;
   VirtualPendingClear();
   if(GridUsesBrokerPendingMode())
      BrokerPendingClearAll();
}

//+------------------------------------------------------------------+
//| Xóa chờ ảo/broker (tùy input) + gỡ TP mọi vị thế đang mở.         |
//+------------------------------------------------------------------+
void CompoundClearPendingAndRemoveAllTp()
{
   CompoundClearPendingOrdersIfEnabled();
   CompoundRemoveAllTpFromOpenPositions();
}

//+------------------------------------------------------------------+
//| Đặt SL chung tại lineNorm cho mọi vị thế mở (không TP).            |
//+------------------------------------------------------------------+
void CompoundApplyCommonSlLineToAllOpenPositions(const bool buyReference, const double lineNorm, const double minDist)
{
   trade.SetExpertMagicNumber(MagicAA);
   const double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int p = 0; p < PositionsTotal(); p++)
   {
      ulong ticket = PositionGetTicket(p);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(!PositionIsOurSymbolAndMagic(ticket))
         continue;
      if(!CompoundPositionPassesSessionFilter(ticket))
         continue;

      const ENUM_POSITION_TYPE ptp = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      const double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      const double curSL = PositionGetDouble(POSITION_SL);
      double newSL = 0.0;

      if(ptp == POSITION_TYPE_BUY)
      {
         newSL = MathMax(lineNorm, openPrice + minDist);
         newSL = NormalizeDouble(newSL, dgt);
         if(newSL <= 0.0 || newSL >= bid - minDist)
            continue;
         if(newSL <= openPrice)
            continue;
         if(curSL > 0.0 && newSL <= curSL + pt)
            continue;
      }
      else if(ptp == POSITION_TYPE_SELL)
      {
         newSL = MathMin(lineNorm, openPrice - minDist);
         newSL = NormalizeDouble(newSL, dgt);
         if(newSL <= 0.0 || newSL <= ask + minDist)
            continue;
         if(newSL >= openPrice)
            continue;
         if(curSL > 0.0 && newSL >= curSL - pt)
            continue;
      }
      else
         continue;

      if(ModifyPositionSLTP(ticket, newSL, 0.0))
         Print("VGridABCD: Gồng lãi — SL chung ticket ", ticket, " SL=", DoubleToString(newSL, dgt));
   }
}

//+------------------------------------------------------------------+
//| Đạt ngưỡng: khóa điểm A một lần (cố định). Dưới ngưỡng: reset A.  |
//+------------------------------------------------------------------+
void CompoundRefreshTrackingReference(const double compoundTriggerProgressUsd)
{
   if(g_compoundTotalProfitActive)
      return;
   if(g_compoundPointASessionLocked)
      return;
   if(!EnableCompoundTotalFloatingProfit || GetCompoundBaseTriggerUsd() <= 0.0)
      return;
   if(basePrice <= 0.0)
      return;

   const double thresholdUsd = GetCompoundFloatingTriggerThresholdUsd();
   const bool thresholdOk = (compoundTriggerProgressUsd + 1e-8 >= thresholdUsd);

   if(!thresholdOk)
   {
      if(g_compoundAfterClearWaitGrid || g_compoundFrozenRefPx > 0.0)
      {
         Print("VGridABCD: Gồng lãi — tiến độ ", DoubleToString(compoundTriggerProgressUsd, 2),
               " USD < ngưỡng ", DoubleToString(thresholdUsd, 2),
               " USD → reset điểm A.");
         CompoundResetPointAOnly();
      }
      return;
   }

   // Trên ngưỡng: giữ nguyên điểm A đã khóa.
   if(g_compoundAfterClearWaitGrid && g_compoundFrozenRefPx > 0.0 && MathIsValidNumber(g_compoundFrozenRefPx))
      return;

   const double buyPosPl = CompoundSumPositiveOpenProfitForSide(true);
   const double sellPosPl = CompoundSumPositiveOpenProfitForSide(false);
   if(buyPosPl <= 0.0 && sellPosPl <= 0.0)
      return;

   bool buyReference = (buyPosPl >= sellPosPl);
   if(buyReference && buyPosPl <= 0.0)
      buyReference = false;
   if(!buyReference && sellPosPl <= 0.0)
      return;

   double pointA = 0.0;
   if(!CompoundFindPointAForReferenceSide(buyReference, pointA))
      return;

   g_compoundBuyBasketMode = buyReference;
   g_compoundFrozenRefPx = pointA;
   g_compoundAfterClearWaitGrid = true;
   g_compoundCommonSlLine = 0.0;
   CompoundEnforceNoTpWhenPointAActive();

   Print("VGridABCD: Gồng lãi — ngưỡng ", DoubleToString(thresholdUsd, 2), " USD OK",
         " | phía=", (buyReference ? "Buy" : "Sell"),
         " (P/L dương Buy=", DoubleToString(buyPosPl, 2),
         " Sell=", DoubleToString(sellPosPl, 2), " USD)",
         " | khóa điểm A=", DoubleToString(pointA, dgt),
         " [", CompoundPointAModeLabel(), "]",
         " | gỡ TP mọi lệnh phiên | chờ giá cách A ≥1 bậc lưới → SL tại A.");
}

//+------------------------------------------------------------------+
//| Bước 2: giá cách điểm A ≥1 bậc lưới → SL tại A, xóa chờ + gỡ TP. |
//| Buy: Bid ≥ mức lưới trên A; Sell: Ask ≤ mức lưới dưới A.         |
//+------------------------------------------------------------------+
void ProcessCompoundWaitingFirstGridStep()
{
   if(!g_compoundAfterClearWaitGrid)
      return;

   if(g_compoundFrozenRefPx <= 0.0 || !MathIsValidNumber(g_compoundFrozenRefPx))
   {
      CompoundResetPointAOnly();
      return;
   }

   if(!CompoundPriceAtLeastOneGridLevelFromPointA(g_compoundBuyBasketMode, g_compoundFrozenRefPx))
      return;

   const double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   const int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const int freezeLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double minDist = (double)MathMax(stopsLevel, freezeLevel) * pt;
   if(minDist < pt * 2.0)
      minDist = pt * 2.0;

   CompoundClearPendingAndRemoveAllTp();

   double slAtPointA = g_compoundFrozenRefPx;
   int lvlA = 0;
   if(FindSignedLevelNumForPrice(g_compoundFrozenRefPx, lvlA))
   {
      double gridPxA = 0.0;
      if(CompoundGetGridLevelPriceForSignedLevel(lvlA, gridPxA))
         slAtPointA = gridPxA;
   }
   g_compoundCommonSlLine = NormalizeDouble(slAtPointA, dgt);
   g_compoundFrozenRefPx = slAtPointA;
   g_compoundPointASessionLocked = true;
   CompoundApplyCommonSlLineToAllOpenPositions(g_compoundBuyBasketMode, g_compoundCommonSlLine, minDist);

   g_compoundAfterClearWaitGrid = false;
   g_compoundTotalProfitActive = true;
   CompoundFloatThrHudUpdate(false);

   Print("VGridABCD: Gồng lãi — giá cách A ≥1 bậc lưới: SL chung tại A=",
         DoubleToString(g_compoundCommonSlLine, dgt),
         " | khóa điểm A đến hết phiên",
         (CompoundClearPendingOnCommonSl == COMPOUND_CLEAR_PENDING
            ? " | xóa chờ ảo/broker + gỡ TP | không bổ sung chờ mới"
            : " | giữ nguyên chờ ảo/broker + gỡ TP | không bổ sung chờ mới"));
}

//+------------------------------------------------------------------+
//| Chạm SL chung gồng lãi (Bid/Ask vs g_compoundCommonSlLine).        |
//+------------------------------------------------------------------+
bool CompoundPriceTouchesCommonSlLine()
{
   if(g_compoundCommonSlLine <= 0.0)
      return false;

   const double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   const double touchTol = MathMax(GridPriceTolerance(), pt * 3.0);
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(g_compoundBuyBasketMode)
      return (bid <= g_compoundCommonSlLine + touchTol);
   return (ask >= g_compoundCommonSlLine - touchTol);
}

//+------------------------------------------------------------------+
//| Deal OUT SL khớp mức SL chung gồng lãi (broker).                   |
//+------------------------------------------------------------------+
bool CompoundDealOutIsCommonSlHit(const ulong deal)
{
   if(!g_compoundTotalProfitActive || g_compoundCommonSlLine <= 0.0)
      return false;
   return (HistoryDealGetInteger(deal, DEAL_REASON) == DEAL_REASON_SL);
}

//+------------------------------------------------------------------+
//| SL chung gồng lãi bị chạm → reset EA (+ carry) nếu input bật.     |
//+------------------------------------------------------------------+
void CompoundTryResetAfterCommonSlHit(const string reason)
{
   if(!CompoundResetOnCommonSlHit)
      return;
   if(!g_compoundTotalProfitActive && !g_compoundCommonSlHitPendingReset)
      return;

   g_compoundCommonSlCarrySuppress = true;
   g_compoundCommonSlHitPendingReset = false;
   Print("VGridABCD: Gồng lãi — ", reason,
         " SL chung ", DoubleToString(g_compoundCommonSlLine, dgt),
         " → reset EA + carry.");
   CompoundResetAfterCommonSlHit();
}

//+------------------------------------------------------------------+
//| Chạm SL chung: reset EA + reset carry.                              |
//+------------------------------------------------------------------+
void CompoundResetAfterCommonSlHit()
{
   g_compoundCommonSlHitPendingReset = false;
   EaRecordAutoResetCount("SL chung gồng lãi tổng");

   const double carryBeforeReset = g_balanceCompoundCarryUsd;
   g_compoundCommonSlCarrySuppress = true;
   CloseAllPositionsAndOrders();
   CompoundCarryUsdSetTotal(0.0);
   CompoundModeClearState();
   CompoundPointAClearSession();
   CompoundFloatThrHudUpdate(false);

   VirtualPendingClear();
   ArrayResize(gridLevels, 0);
   sessionStartTime = 0;
   basePrice = 0.0;
   EmaDirectionClearLock();
   StartupRsiCrossResetLatch();

   if(EnableCompoundSlPauseUntilNextServerDay)
   {
      const datetime nowSrv = TimeCurrent();
      const long nowDateKey = ServerDateKey(nowSrv);
      g_compoundSlPauseDateKey = nowDateKey;
      g_compoundSlPauseLoggedDateKey = nowDateKey;
      g_runtimeSessionActive = false;
      const string msg = "Gồng lãi chạm SL chung — reset EA + carry "
                         + DoubleToString(carryBeforeReset, 2)
                         + " → 0 | tạm dừng EA tới ngày server kế tiếp.";
      Print("VGridABCD: ", msg);
      if(EnableResetNotification)
         SendResetNotification(msg);
      return;
   }

   g_runtimeSessionActive = true;
   Print("VGridABCD: Gồng lãi — chạm SL chung — reset EA + carry ",
         DoubleToString(carryBeforeReset, 2), " → 0 | chờ đặt gốc mới.");
   if(EnableResetNotification)
      SendResetNotification("Gồng lãi: SL chung — reset EA + carry");
}

//+------------------------------------------------------------------+
//| Bước 3–4: trượt SL chung theo bậc lưới; chạm SL → reset EA+carry.  |
//+------------------------------------------------------------------+
void ProcessCompoundTotalProfitTrailing()
{
   if(!g_compoundTotalProfitActive)
      return;

   const double step = CompoundModeGridStepPrice();
   if(step <= 0.0 || g_compoundFrozenRefPx <= 0.0)
      return;

   const double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   const int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const int freezeLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double minDist = (double)MathMax(stopsLevel, freezeLevel) * pt;
   if(minDist < pt * 2.0)
      minDist = pt * 2.0;
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double pointA = g_compoundFrozenRefPx;
   const double prevCommonSlLine = g_compoundCommonSlLine;

   int openManaged = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(!PositionIsOurSymbolAndMagic(ticket))
         continue;
      if(!CompoundPositionPassesSessionFilter(ticket))
         continue;
      openManaged++;
   }
   if(openManaged == 0)
   {
      if(g_compoundCommonSlHitPendingReset)
      {
         CompoundTryResetAfterCommonSlHit("broker khớp");
         return;
      }
      CompoundModeClearState();
      Print("VGridABCD: Gồng lãi — hết vị thế mở, TẮT chế độ.");
      ManageGridOrders();
      return;
   }

   if(g_compoundBuyBasketMode)
   {
      const int k = (int)MathFloor((bid - pointA) / step + 1e-8);
      if(k >= 1)
         g_compoundCommonSlLine = NormalizeDouble(pointA + (double)(k - 1) * step, dgt);
   }
   else
   {
      const int k = (int)MathFloor((pointA - ask) / step + 1e-8);
      if(k >= 1)
         g_compoundCommonSlLine = NormalizeDouble(pointA - (double)(k - 1) * step, dgt);
   }

   if(g_compoundCommonSlLine <= 0.0)
      return;

   if(CompoundPriceTouchesCommonSlLine())
   {
      CompoundTryResetAfterCommonSlHit("giá chạm");
      return;
   }

   if(prevCommonSlLine > 0.0 && MathAbs(g_compoundCommonSlLine - prevCommonSlLine) >= step - pt * 0.5)
   {
      Print("VGridABCD: Gồng lãi — nâng SL chung lên 1 bước lưới → ",
            DoubleToString(g_compoundCommonSlLine, dgt));
   }

   CompoundApplyCommonSlLineToAllOpenPositions(g_compoundBuyBasketMode, g_compoundCommonSlLine, minDist);
}

//+------------------------------------------------------------------+
//| Chế độ chờ ảo vs lệnh chờ broker                                   |
//+------------------------------------------------------------------+
bool GridUsesVirtualPendingMode()
{
   return (GridPendingEntryMode == GRID_PENDING_MODE_VIRTUAL);
}

bool GridUsesBrokerPendingMode()
{
   return (GridPendingEntryMode == GRID_PENDING_MODE_BROKER);
}

bool OrderCommentIsGridPending(const string cmt)
{
   if(StringFind(cmt, "VGridABCD|") >= 0)
      return true;
   if(StringFind(cmt, "VDualGrid|") >= 0)
      return true;
   return false;
}

void BrokerPendingClearAll()
{
   trade.SetExpertMagicNumber(MagicAA);
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderIsOurSymbolAndMagic(ticket))
         continue;
      if(!OrderCommentIsGridPending(OrderGetString(ORDER_COMMENT)))
         continue;
      trade.OrderDelete(ticket);
   }
}

bool BrokerPendingFindAtLevel(ENUM_ORDER_TYPE orderType,
                              ENUM_VGRID_LEG leg,
                              double priceLevel,
                              ulong &ticket,
                              double &orderPrice,
                              long whichMagic)
{
   if(!IsOurMagic(whichMagic))
      return false;
   const double tolerance = GridPriceTolerance();
   ticket = 0;
   orderPrice = 0.0;
   const string legTag = "|" + VirtualGridLegCode(leg) + "|";
   for(int i = 0; i < OrdersTotal(); i++)
   {
      const ulong t = OrderGetTicket(i);
      if(t == 0 || !OrderIsOurSymbolAndMagic(t))
         continue;
      const string cmt = OrderGetString(ORDER_COMMENT);
      if(!OrderCommentIsGridPending(cmt))
         continue;
      if(StringFind(cmt, legTag) < 0)
         continue;
      const ENUM_ORDER_TYPE ot = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(ot != orderType)
         continue;
      const double op = OrderGetDouble(ORDER_PRICE_OPEN);
      if(MathAbs(op - priceLevel) >= tolerance)
         continue;
      ticket = t;
      orderPrice = op;
      return true;
   }
   return false;
}

static ENUM_GRID_PENDING_ENTRY_MODE g_gridPendingEntryModeSynced = (ENUM_GRID_PENDING_ENTRY_MODE)-1;

void GridPendingEntryModeSync()
{
   if(g_gridPendingEntryModeSynced == GridPendingEntryMode)
      return;
   if(g_gridPendingEntryModeSynced != (ENUM_GRID_PENDING_ENTRY_MODE)-1)
   {
      Print("VGridABCD: chế độ chờ → ",
            (GridUsesVirtualPendingMode() ? "CHỜ ẢO" : "CHỜ BROKER"),
            " — dọn storage chế độ cũ.");
   }
   if(GridUsesVirtualPendingMode())
      BrokerPendingClearAll();
   else
   {
      ArrayResize(g_virtualPending, 0);
      ArrayResize(g_virtualExecCooldown, 0);
   }
   g_gridPendingEntryModeSynced = GridPendingEntryMode;
}

//+------------------------------------------------------------------+
//| Virtual pending: clear all                                        |
//+------------------------------------------------------------------+
void VirtualPendingClear()
{
   ArrayResize(g_virtualPending, 0);
   ArrayResize(g_virtualExecCooldown, 0);
   if(GridUsesBrokerPendingMode())
      BrokerPendingClearAll();
}

//+------------------------------------------------------------------+
//| Same order side (buy vs sell) for virtual entry                   |
//+------------------------------------------------------------------+
bool VirtualPendingSameSide(ENUM_ORDER_TYPE a, ENUM_ORDER_TYPE b)
{
   bool ba = (a == ORDER_TYPE_BUY_LIMIT || a == ORDER_TYPE_BUY_STOP);
   bool bb = (b == ORDER_TYPE_BUY_LIMIT || b == ORDER_TYPE_BUY_STOP);
   return (ba == bb);
}

//+------------------------------------------------------------------+
//| Find virtual pending index (-1 = none)                            |
//+------------------------------------------------------------------+
int VirtualPendingFindIndex(long magic, ENUM_ORDER_TYPE orderType, ENUM_VGRID_LEG leg, double priceLevel)
{
   if(!IsOurMagic(magic)) return -1;
   double tol = gridStep * 0.5;
   if(gridStep <= 0) tol = pnt * 10.0 * GridDistancePips * 0.5;
   for(int i = 0; i < ArraySize(g_virtualPending); i++)
   {
      if(g_virtualPending[i].magic != magic) continue;
      if(!VirtualPendingSameSide(g_virtualPending[i].orderType, orderType)) continue;
      if(g_virtualPending[i].orderType != orderType) continue;
      if(g_virtualPending[i].leg != leg) continue;
      if(MathAbs(g_virtualPending[i].priceLevel - priceLevel) < tol)
         return i;
   }
   return -1;
}

//+------------------------------------------------------------------+
//| Add virtual pending if not duplicate at level                     |
//+------------------------------------------------------------------+
bool VirtualPendingAdd(long magic, ENUM_ORDER_TYPE orderType, ENUM_VGRID_LEG leg, double priceLevel, int levelNum, double tpPrice, double lot)
{
   if(!IsOurMagic(magic))
      return false;
   if(VirtualPendingFindIndex(magic, orderType, leg, priceLevel) >= 0)
      return true;
   int n = ArraySize(g_virtualPending);
   ArrayResize(g_virtualPending, n + 1);
   g_virtualPending[n].magic = magic;
   g_virtualPending[n].orderType = orderType;
   g_virtualPending[n].leg = leg;
   g_virtualPending[n].priceLevel = NormalizeDouble(priceLevel, dgt);
   g_virtualPending[n].levelNum = levelNum;
   g_virtualPending[n].tpPrice = tpPrice;
   g_virtualPending[n].lot = lot;
   return true;
}

//+------------------------------------------------------------------+
//| Remove virtual pending at index (swap with last)                  |
//+------------------------------------------------------------------+
void VirtualPendingRemoveAt(int idx)
{
   int n = ArraySize(g_virtualPending);
   if(idx < 0 || idx >= n) return;
   if(n == 1) { ArrayResize(g_virtualPending, 0); return; }
   g_virtualPending[idx] = g_virtualPending[n - 1];
   ArrayResize(g_virtualPending, n - 1);
}

//+------------------------------------------------------------------+
//| Dung sai cho cùng một ô lưới (virtual / trùng lặp)                  |
//+------------------------------------------------------------------+
double GridPriceTolerance()
{
   double t = gridStep * 0.5;
   if(gridStep <= 0.0)
      t = pnt * 10.0 * GridDistancePips * 0.5;
   return t;
}


//+------------------------------------------------------------------+
//| RSI khởi động: cắt lên X1 và/hoặc cắt xuống X2 (X=0 → bỏ qua).   |
//+------------------------------------------------------------------+
bool StartupRsiCrossUpEnabled()
{
   return (StartupRsiCrossUpLevel > 0.0);
}

bool StartupRsiCrossDownEnabled()
{
   return (StartupRsiCrossDownLevel > 0.0);
}

bool StartupRsiFilterActive()
{
   return (EnableStartupRsiCrossUpFilter
           && (StartupRsiCrossUpEnabled() || StartupRsiCrossDownEnabled()));
}

string StartupRsiConfigLabel()
{
   const bool up = StartupRsiCrossUpEnabled();
   const bool dn = StartupRsiCrossDownEnabled();
   if(up && dn)
      return "cắt lên X1 hoặc cắt xuống X2";
   if(up)
      return "cắt lên X1";
   if(dn)
      return "cắt xuống X2";
   return "tắt (X1=0 và X2=0)";
}

ENUM_TIMEFRAMES StartupRsiResolvedTimeframe()
{
   ENUM_TIMEFRAMES tf = StartupRsiTimeframe;
   if(tf == PERIOD_CURRENT)
      tf = (ENUM_TIMEFRAMES)_Period;
   return tf;
}

void StartupRsiCrossResetLatch()
{
   g_startupRsiCrossLatch = false;
   g_startupRsiLastCheckedBar1 = 0;
}

bool StartupRsiAllowsBasePlacement()
{
   if(!StartupRsiFilterActive())
      return true;
   return g_startupRsiCrossLatch;
}

void StartupRsiReleaseHandle()
{
   if(g_startupRsiHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_startupRsiHandle);
      g_startupRsiHandle = INVALID_HANDLE;
   }
}

bool StartupRsiInitHandle()
{
   StartupRsiReleaseHandle();
   if(!StartupRsiFilterActive())
      return true;
   const ENUM_TIMEFRAMES tf = StartupRsiResolvedTimeframe();
   const int period = MathMax(2, StartupRsiPeriod);
   g_startupRsiHandle = iRSI(_Symbol, tf, period, PRICE_CLOSE);
   if(g_startupRsiHandle == INVALID_HANDLE)
   {
      Print("VGridABCD: RSI khởi động — không tạo iRSI (", EnumToString(tf), ", period=", period, ").");
      return false;
   }
   return true;
}

bool StartupRsiPreCrossUpBarsMeetCondition(const int barCount, const double x1)
{
   if(barCount <= 0)
      return true;

   double rsiPre[];
   ArraySetAsSeries(rsiPre, true);
   if(CopyBuffer(g_startupRsiHandle, 0, 2, barCount, rsiPre) < barCount)
      return false;

   for(int i = 0; i < barCount; i++)
   {
      if(!MathIsValidNumber(rsiPre[i]))
         return false;
      if(rsiPre[i] >= x1 - 1e-8)
         return false;
   }
   return true;
}

bool StartupRsiPreCrossDownBarsMeetCondition(const int barCount, const double x2)
{
   if(barCount <= 0)
      return true;

   double rsiPre[];
   ArraySetAsSeries(rsiPre, true);
   if(CopyBuffer(g_startupRsiHandle, 0, 2, barCount, rsiPre) < barCount)
      return false;

   for(int i = 0; i < barCount; i++)
   {
      if(!MathIsValidNumber(rsiPre[i]))
         return false;
      if(rsiPre[i] <= x2 + 1e-8)
         return false;
   }
   return true;
}

bool StartupRsiPollCrossLatch(const bool forceRecheck)
{
   if(!StartupRsiFilterActive())
      return true;
   if(g_startupRsiCrossLatch)
      return true;
   if(g_startupRsiHandle == INVALID_HANDLE)
      return false;

   const ENUM_TIMEFRAMES tf = StartupRsiResolvedTimeframe();
   const int preUp = StartupRsiCrossUpEnabled()
      ? MathMax(0, StartupRsiPreCrossUpBarsBelowX1) : 0;
   const int preDn = StartupRsiCrossDownEnabled()
      ? MathMax(0, StartupRsiPreCrossDownBarsAboveX2) : 0;
   const int minBars = 3 + MathMax(preUp, preDn);
   if(Bars(_Symbol, tf) < minBars)
      return false;

   const datetime bar1 = iTime(_Symbol, tf, 1);
   if(bar1 <= 0)
      return false;
   if(!forceRecheck && bar1 == g_startupRsiLastCheckedBar1)
      return false;

   double rsiBuf[];
   ArraySetAsSeries(rsiBuf, true);
   if(CopyBuffer(g_startupRsiHandle, 0, 1, 2, rsiBuf) < 2)
      return false;
   if(!MathIsValidNumber(rsiBuf[0]) || !MathIsValidNumber(rsiBuf[1]))
      return false;

   bool crossUp = false;
   bool crossDown = false;

   if(StartupRsiCrossUpEnabled())
   {
      const double x1 = StartupRsiCrossUpLevel;
      crossUp = (rsiBuf[0] > x1 && rsiBuf[1] <= x1);
      if(crossUp && !StartupRsiPreCrossUpBarsMeetCondition(preUp, x1))
         crossUp = false;
      if(crossUp)
      {
         string preNote = "";
         if(preUp > 0)
            preNote = " | trước cắt: " + IntegerToString(preUp) + " nến RSI < " + DoubleToString(x1, 2);
         Print("VGridABCD: RSI khởi động — cắt lên X1 trên ", EnumToString(tf),
               " | RSI[1]=", DoubleToString(rsiBuf[0], 2),
               " RSI[2]=", DoubleToString(rsiBuf[1], 2),
               " | X1=", DoubleToString(x1, 2), preNote);
      }
   }

   if(StartupRsiCrossDownEnabled())
   {
      const double x2 = StartupRsiCrossDownLevel;
      crossDown = (rsiBuf[0] < x2 && rsiBuf[1] >= x2);
      if(crossDown && !StartupRsiPreCrossDownBarsMeetCondition(preDn, x2))
         crossDown = false;
      if(crossDown)
      {
         string preNote = "";
         if(preDn > 0)
            preNote = " | trước cắt: " + IntegerToString(preDn) + " nến RSI > " + DoubleToString(x2, 2);
         Print("VGridABCD: RSI khởi động — cắt xuống X2 trên ", EnumToString(tf),
               " | RSI[1]=", DoubleToString(rsiBuf[0], 2),
               " RSI[2]=", DoubleToString(rsiBuf[1], 2),
               " | X2=", DoubleToString(x2, 2), preNote);
      }
   }

   if(!crossUp && !crossDown)
      return false;

   g_startupRsiLastCheckedBar1 = bar1;
   g_startupRsiCrossLatch = true;
   return true;
}

//+------------------------------------------------------------------+
//| EMA lọc chiều:                                                     |
//| Close — nến đóng vs EMA(Close); khóa chiều đến reset EA.          |
//| High/Low — Close>EMA(High)=Buy; Close<EMA(Low)=Sell.              |
//|   Có gốc: khóa chiều phiên đến reset EA (Buy hoặc Sell).           |
//|   Không gốc + vùng giữa: chờ; ngoài vùng: đặt gốc ngay theo chiều.  |
//+------------------------------------------------------------------+
ENUM_TIMEFRAMES EmaDirectionResolvedTimeframe()
{
   ENUM_TIMEFRAMES tf = EmaDirectionTimeframe;
   if(tf == PERIOD_CURRENT)
      tf = (ENUM_TIMEFRAMES)_Period;
   return tf;
}

bool EmaDirectionUsesCloseStickyMode()
{
   return (EnableEmaDirectionFilter && EmaDirectionMode == EMA_DIRECTION_CLOSE);
}

bool EmaDirectionUsesHighLowMode()
{
   return (EnableEmaDirectionFilter && EmaDirectionMode == EMA_DIRECTION_HIGH_LOW);
}

void EmaDirectionClearLock()
{
   g_emaDirectionLock = 0;
   g_emaHighLowWaitLoggedBar = 0;
}

void EmaDirectionReleaseHandle()
{
   if(g_emaDirectionHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_emaDirectionHandle);
      g_emaDirectionHandle = INVALID_HANDLE;
   }
   if(g_emaDirectionHandleHigh != INVALID_HANDLE)
   {
      IndicatorRelease(g_emaDirectionHandleHigh);
      g_emaDirectionHandleHigh = INVALID_HANDLE;
   }
   if(g_emaDirectionHandleLow != INVALID_HANDLE)
   {
      IndicatorRelease(g_emaDirectionHandleLow);
      g_emaDirectionHandleLow = INVALID_HANDLE;
   }
}

bool EmaDirectionInitHandle()
{
   EmaDirectionReleaseHandle();
   if(!EnableEmaDirectionFilter)
      return true;

   const ENUM_TIMEFRAMES tf = EmaDirectionResolvedTimeframe();
   const int period = MathMax(1, EmaDirectionPeriod);

   if(EmaDirectionUsesCloseStickyMode())
   {
      g_emaDirectionHandle = iMA(_Symbol, tf, period, 0, MODE_EMA, PRICE_CLOSE);
      if(g_emaDirectionHandle == INVALID_HANDLE)
      {
         Print("VGridABCD: EMA lọc chiều — không tạo iMA Close (", EnumToString(tf), ", period=", period, ").");
         return false;
      }
      return true;
   }

   if(EmaDirectionUsesHighLowMode())
   {
      g_emaDirectionHandleHigh = iMA(_Symbol, tf, period, 0, MODE_EMA, PRICE_HIGH);
      g_emaDirectionHandleLow = iMA(_Symbol, tf, period, 0, MODE_EMA, PRICE_LOW);
      if(g_emaDirectionHandleHigh == INVALID_HANDLE || g_emaDirectionHandleLow == INVALID_HANDLE)
      {
         Print("VGridABCD: EMA lọc chiều — không tạo iMA High/Low (", EnumToString(tf), ", period=", period, ").");
         return false;
      }
      return true;
   }

   return true;
}

bool EmaDirectionReadHighLowSignal(int &signalOut)
{
   signalOut = 0;
   if(!EmaDirectionUsesHighLowMode())
      return false;
   if(g_emaDirectionHandleHigh == INVALID_HANDLE
      || g_emaDirectionHandleLow == INVALID_HANDLE)
   {
      if(!EmaDirectionInitHandle())
         return false;
   }

   const ENUM_TIMEFRAMES tf = EmaDirectionResolvedTimeframe();
   const int period = MathMax(1, EmaDirectionPeriod);
   if(Bars(_Symbol, tf) < period + 2)
      return false;
   if(BarsCalculated(g_emaDirectionHandleHigh) < period + 2
      || BarsCalculated(g_emaDirectionHandleLow) < period + 2)
      return false;

   double closeBuf[];
   double emaHighBuf[];
   double emaLowBuf[];
   ArraySetAsSeries(closeBuf, true);
   ArraySetAsSeries(emaHighBuf, true);
   ArraySetAsSeries(emaLowBuf, true);
   if(CopyClose(_Symbol, tf, 1, 1, closeBuf) < 1)
      return false;
   if(CopyBuffer(g_emaDirectionHandleHigh, 0, 1, 1, emaHighBuf) < 1)
      return false;
   if(CopyBuffer(g_emaDirectionHandleLow, 0, 1, 1, emaLowBuf) < 1)
      return false;
   if(!MathIsValidNumber(closeBuf[0])
      || !MathIsValidNumber(emaHighBuf[0])
      || !MathIsValidNumber(emaLowBuf[0]))
      return false;

   if(closeBuf[0] > emaHighBuf[0])
      signalOut = 1;
   else if(closeBuf[0] < emaLowBuf[0])
      signalOut = -1;
   else
      signalOut = 0;
   return true;
}

bool EmaDirectionTrySetLockFromClosedBar()
{
   if(!EmaDirectionUsesCloseStickyMode())
      return true;
   if(g_emaDirectionLock != 0)
      return true;
   if(g_emaDirectionHandle == INVALID_HANDLE && !EmaDirectionInitHandle())
      return false;

   const ENUM_TIMEFRAMES tf = EmaDirectionResolvedTimeframe();
   const int period = MathMax(1, EmaDirectionPeriod);
   if(Bars(_Symbol, tf) < period + 2)
      return false;
   if(BarsCalculated(g_emaDirectionHandle) < period + 2)
      return false;

   double closeBuf[];
   double emaBuf[];
   ArraySetAsSeries(closeBuf, true);
   ArraySetAsSeries(emaBuf, true);
   if(CopyClose(_Symbol, tf, 1, 1, closeBuf) < 1)
      return false;
   if(CopyBuffer(g_emaDirectionHandle, 0, 1, 1, emaBuf) < 1)
      return false;
   if(!MathIsValidNumber(closeBuf[0]) || !MathIsValidNumber(emaBuf[0]))
      return false;

   if(closeBuf[0] >= emaBuf[0])
      g_emaDirectionLock = 1;
   else
      g_emaDirectionLock = -1;

   Print("VGridABCD: EMA lọc chiều (Close) — khóa phiên ",
         (g_emaDirectionLock > 0 ? "chỉ Buy" : "chỉ Sell"),
         " | ", EnumToString(tf), " period=", period,
         " | Close[1]=", DoubleToString(closeBuf[0], dgt),
         " EMA[1]=", DoubleToString(emaBuf[0], dgt),
         " (giữ đến khi EA reset)");
   return true;
}

void EmaDirectionSnapshotHighLowAtSessionStart()
{
   if(!EmaDirectionUsesHighLowMode())
      return;

   int signal = 0;
   if(!EmaDirectionReadHighLowSignal(signal) || signal == 0)
      return;

   g_emaDirectionLock = signal;

   const ENUM_TIMEFRAMES tf = EmaDirectionResolvedTimeframe();
   const int period = MathMax(1, EmaDirectionPeriod);
   double closeBuf[];
   double emaHighBuf[];
   double emaLowBuf[];
   ArraySetAsSeries(closeBuf, true);
   ArraySetAsSeries(emaHighBuf, true);
   ArraySetAsSeries(emaLowBuf, true);
   CopyClose(_Symbol, tf, 1, 1, closeBuf);
   CopyBuffer(g_emaDirectionHandleHigh, 0, 1, 1, emaHighBuf);
   CopyBuffer(g_emaDirectionHandleLow, 0, 1, 1, emaLowBuf);

   Print("VGridABCD: EMA High/Low — đặt gốc phiên ",
         (signal > 0 ? "Buy" : "Sell"),
         " | ", EnumToString(tf), " period=", period,
         " | Close[1]=", DoubleToString(closeBuf[0], dgt),
         (signal > 0
            ? " > EMA(High)[1]=" + DoubleToString(emaHighBuf[0], dgt)
            : " < EMA(Low)[1]=" + DoubleToString(emaLowBuf[0], dgt)));
}

void EmaDirectionLogHighLowWaitIfNeeded()
{
   if(!EmaDirectionUsesHighLowMode() || basePrice > 0.0)
      return;
   if(!StartupRsiAllowsBasePlacement())
      return;

   const ENUM_TIMEFRAMES tf = EmaDirectionResolvedTimeframe();
   const datetime bar1 = iTime(_Symbol, tf, 1);
   if(bar1 <= 0 || bar1 == g_emaHighLowWaitLoggedBar)
      return;

   int signal = 0;
   if(!EmaDirectionReadHighLowSignal(signal))
      return;
   if(signal != 0)
      return;

   double closeBuf[];
   double emaHighBuf[];
   double emaLowBuf[];
   ArraySetAsSeries(closeBuf, true);
   ArraySetAsSeries(emaHighBuf, true);
   ArraySetAsSeries(emaLowBuf, true);
   CopyClose(_Symbol, tf, 1, 1, closeBuf);
   CopyBuffer(g_emaDirectionHandleHigh, 0, 1, 1, emaHighBuf);
   CopyBuffer(g_emaDirectionHandleLow, 0, 1, 1, emaLowBuf);

   g_emaHighLowWaitLoggedBar = bar1;
   Print("VGridABCD: EMA High/Low — chờ đặt gốc (Close[1] trong vùng EMA High–Low) | ",
         EnumToString(tf), " period=", EmaDirectionPeriod,
         " | Close[1]=", DoubleToString(closeBuf[0], dgt),
         " | EMA(High)[1]=", DoubleToString(emaHighBuf[0], dgt),
         " | EMA(Low)[1]=", DoubleToString(emaLowBuf[0], dgt));
}

void EmaDirectionSnapshotLockAtSessionStart()
{
   g_emaDirectionLock = 0;
   if(!EmaDirectionUsesCloseStickyMode())
      return;
   EmaDirectionTrySetLockFromClosedBar();
}

void EmaDirectionPollLockIfNeeded()
{
   if(!EmaDirectionUsesCloseStickyMode() || g_emaDirectionLock != 0)
      return;
   EmaDirectionTrySetLockFromClosedBar();
}

bool EmaDirectionAllowsBasePlacement()
{
   if(!EnableEmaDirectionFilter)
      return true;
   if(EmaDirectionUsesCloseStickyMode())
      return true;

   int signal = 0;
   if(!EmaDirectionReadHighLowSignal(signal))
      return false;
   return (signal != 0);
}

bool EmaDirectionAllowsBuyEntries()
{
   if(!EnableEmaDirectionFilter)
      return true;

   if(EmaDirectionUsesHighLowMode())
   {
      // Có gốc → chiều phiên đã khóa lúc đặt gốc; không đọc lại EMA mỗi tick.
      if(g_emaDirectionLock == 0)
         return false;
      return (g_emaDirectionLock > 0);
   }

   if(g_emaDirectionLock == 0)
      return false;
   return (g_emaDirectionLock > 0);
}

bool EmaDirectionAllowsSellEntries()
{
   if(!EnableEmaDirectionFilter)
      return true;

   if(EmaDirectionUsesHighLowMode())
   {
      if(g_emaDirectionLock == 0)
         return false;
      return (g_emaDirectionLock < 0);
   }

   if(g_emaDirectionLock == 0)
      return false;
   return (g_emaDirectionLock < 0);
}

bool EmaDirectionAllowsLeg(const ENUM_VGRID_LEG leg)
{
   if(IsVirtualGridLegBuyEntryLeg(leg))
      return EmaDirectionAllowsBuyEntries();
   if(IsVirtualGridLegSellEntryLeg(leg))
      return EmaDirectionAllowsSellEntries();
   return true;
}

void EmaDirectionPurgeBlockedSidePendings()
{
   if(!EnableEmaDirectionFilter)
      return;
   if(EmaDirectionUsesCloseStickyMode() && g_emaDirectionLock == 0)
      return;

   const bool allowBuy = EmaDirectionAllowsBuyEntries();
   const bool allowSell = EmaDirectionAllowsSellEntries();

   if(GridUsesVirtualPendingMode())
   {
      for(int i = ArraySize(g_virtualPending) - 1; i >= 0; i--)
      {
         const ENUM_VGRID_LEG leg = g_virtualPending[i].leg;
         if((!allowBuy && IsVirtualGridLegBuyEntryLeg(leg))
            || (!allowSell && IsVirtualGridLegSellEntryLeg(leg)))
            VirtualPendingRemoveAt(i);
      }
      return;
   }

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderIsOurSymbolAndMagic(ticket))
         continue;
      if(!OrderCommentIsGridPending(OrderGetString(ORDER_COMMENT)))
         continue;
      ENUM_VGRID_LEG leg = VGRID_LEG_BUY_ABOVE;
      if(!TryParseLegFromOrderComment(OrderGetString(ORDER_COMMENT), leg))
         continue;
      if((!allowBuy && IsVirtualGridLegBuyEntryLeg(leg))
         || (!allowSell && IsVirtualGridLegSellEntryLeg(leg)))
         trade.OrderDelete(ticket);
   }
}

//+------------------------------------------------------------------+
//| Đặt gốc lưới (một lần khi EA sẵn sàng chạy).                        |
//+------------------------------------------------------------------+
bool TryPlaceBaseAfterStartupFilters()
{
   if(basePrice > 0.0)
      return false;
   if(!StartupRsiAllowsBasePlacement())
      return false;
   if(!EmaDirectionAllowsBasePlacement())
      return false;

   basePrice = GridBasePriceAtPlacement();
   InitializeGridLevels();
   EmaDirectionPurgeBlockedSidePendings();
   if(EnableResetNotification)
      SendResetNotification("EA đã khởi động / đặt gốc");
   return true;
}

//+------------------------------------------------------------------+
//| Giá có trùng một mức đã đăng ký trong gridLevels                  |
//+------------------------------------------------------------------+
bool VirtualPriceMatchesRegisteredGrid(double price)
{
   double tol = GridPriceTolerance();
   for(int g = 0; g < ArraySize(gridLevels); g++)
      if(MathAbs(price - gridLevels[g]) < tol)
         return true;
   return false;
}

//+------------------------------------------------------------------+
//| Mức trên thị trường → cắt lên chạm: Buy Stop + Sell Limit.        |
//| Mức dưới thị trường → cắt xuống chạm: Buy Limit + Sell Stop.       |
//| Trong spread → chia theo mid.                                     |
//+------------------------------------------------------------------+
void GetVirtualPairForLevel(double levelPrice, double bid, double ask,
                            ENUM_ORDER_TYPE &buyType, ENUM_ORDER_TYPE &sellType)
{
   double eps = pnt * 2.0;
   if(levelPrice > ask + eps)
   {
      buyType  = ORDER_TYPE_BUY_STOP;
      sellType = ORDER_TYPE_SELL_LIMIT;
   }
   else if(levelPrice < bid - eps)
   {
      buyType  = ORDER_TYPE_BUY_LIMIT;
      sellType = ORDER_TYPE_SELL_STOP;
   }
   else
   {
      double mid = (bid + ask) * 0.5;
      if(levelPrice >= mid)
      {
         buyType  = ORDER_TYPE_BUY_STOP;
         sellType = ORDER_TYPE_SELL_LIMIT;
      }
      else
      {
         buyType  = ORDER_TYPE_BUY_LIMIT;
         sellType = ORDER_TYPE_SELL_STOP;
      }
   }
}

//+------------------------------------------------------------------+
//| Xóa chờ ảo sai loại (khi giá đổi phía so với mức)                 |
//+------------------------------------------------------------------+
void RemoveStaleVirtualTypesAtLevel(double priceLevel, ENUM_ORDER_TYPE wantBuy, ENUM_ORDER_TYPE wantSell, long whichMagic)
{
   if(!IsOurMagic(whichMagic)) return;
   double tolerance = GridPriceTolerance();
   if(GridUsesVirtualPendingMode())
   {
      for(int i = ArraySize(g_virtualPending) - 1; i >= 0; i--)
      {
         if(g_virtualPending[i].magic != whichMagic) continue;
         if(MathAbs(g_virtualPending[i].priceLevel - priceLevel) >= tolerance) continue;
         ENUM_ORDER_TYPE ot = g_virtualPending[i].orderType;
         bool isBuy = (ot == ORDER_TYPE_BUY_STOP || ot == ORDER_TYPE_BUY_LIMIT);
         if(isBuy)
         {
            if(ot != wantBuy)
               VirtualPendingRemoveAt(i);
         }
         else
         {
            if(ot != wantSell)
               VirtualPendingRemoveAt(i);
         }
      }
      return;
   }
   trade.SetExpertMagicNumber(MagicAA);
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderIsOurSymbolAndMagic(ticket)) continue;
      if(!OrderCommentIsGridPending(OrderGetString(ORDER_COMMENT))) continue;
      const double op = OrderGetDouble(ORDER_PRICE_OPEN);
      if(MathAbs(op - priceLevel) >= tolerance) continue;
      const ENUM_ORDER_TYPE ot = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      const bool isBuy = (ot == ORDER_TYPE_BUY_STOP || ot == ORDER_TYPE_BUY_LIMIT);
      if(isBuy && ot != wantBuy)
         trade.OrderDelete(ticket);
      else if(!isBuy && ot != wantSell)
         trade.OrderDelete(ticket);
   }
}

//+------------------------------------------------------------------+
//| Có vị thế mở đúng magic+symbol tại mức giá và phía Buy/Sell        |
//+------------------------------------------------------------------+
bool OurMagicPositionAtLevelSide(double priceLevel, bool isBuyOrder, long whichMagic)
{
   if(!IsOurMagic(whichMagic)) return false;
   double tolerance = GridPriceTolerance();
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != whichMagic || PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      double posPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      if(MathAbs(posPrice - priceLevel) >= tolerance) continue;
      ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if((pt == POSITION_TYPE_BUY) == isBuyOrder)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Ghi nhận chờ ảo vừa khớp market — không bổ sung lại chờ ảo cùng phía ngay. |
//+------------------------------------------------------------------+
void VirtualExecCooldownAdd(double priceLevel, bool isBuy, ENUM_VGRID_LEG leg)
{
   double p = NormalizeDouble(priceLevel, dgt);
   int n = ArraySize(g_virtualExecCooldown);
   ArrayResize(g_virtualExecCooldown, n + 1);
   g_virtualExecCooldown[n].priceLevel = p;
   g_virtualExecCooldown[n].isBuy = isBuy;
   g_virtualExecCooldown[n].leg = leg;
   g_virtualExecCooldown[n].expireUtc = TimeCurrent() + VPGRID_VIRTUAL_EXEC_COOLDOWN_SEC;
}

//+------------------------------------------------------------------+
void VirtualExecCooldownRemoveAt(int idx)
{
   int n = ArraySize(g_virtualExecCooldown);
   if(idx < 0 || idx >= n) return;
   if(n == 1) { ArrayResize(g_virtualExecCooldown, 0); return; }
   g_virtualExecCooldown[idx] = g_virtualExecCooldown[n - 1];
   ArrayResize(g_virtualExecCooldown, n - 1);
}

//+------------------------------------------------------------------+
//| true = chưa bổ sung chờ ảo (đợi vị thế hiện hoặc hết cooldown).    |
//+------------------------------------------------------------------+
bool VirtualReplenishBlockedAfterExecution(double priceLevel, ENUM_ORDER_TYPE orderType, ENUM_VGRID_LEG leg, long whichMagic)
{
   if(!IsOurMagic(whichMagic)) return false;
   bool isBuyOrder = (orderType == ORDER_TYPE_BUY_LIMIT || orderType == ORDER_TYPE_BUY_STOP);
   double tol = GridPriceTolerance();
   datetime now = TimeCurrent();
   double pl = NormalizeDouble(priceLevel, dgt);

   for(int i = ArraySize(g_virtualExecCooldown) - 1; i >= 0; i--)
   {
      if(now > g_virtualExecCooldown[i].expireUtc)
      {
         VirtualExecCooldownRemoveAt(i);
         continue;
      }
      if(MathAbs(g_virtualExecCooldown[i].priceLevel - pl) >= tol) continue;
      if(g_virtualExecCooldown[i].isBuy != isBuyOrder) continue;
      if(g_virtualExecCooldown[i].leg != leg) continue;
      if(OurMagicPositionAtLevelSide(pl, isBuyOrder, whichMagic))
      {
         VirtualExecCooldownRemoveAt(i);
         return false;
      }
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Execute virtual pendings when price touches trigger (same as broker pending) |
//+------------------------------------------------------------------+
void ProcessVirtualPendingExecutions()
{
   if(!GridUsesVirtualPendingMode())
      return;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double tol = pnt * 2.0;
   // Compare previous tick vs current (no triggers on the very first tick).
   if(lastTickBid <= 0.0 || lastTickAsk <= 0.0)
   {
      lastTickBid = bid;
      lastTickAsk = ask;
      return;
   }
   double prevBid = lastTickBid;
   double prevAsk = lastTickAsk;
   for(int i = ArraySize(g_virtualPending) - 1; i >= 0; i--)
   {
      VirtualPendingEntry e = g_virtualPending[i];
      if(!IsOurMagic(e.magic))
      {
         VirtualPendingRemoveAt(i);
         continue;
      }
      if(!IsVirtualGridLegEnabled(e.leg))
      {
         VirtualPendingRemoveAt(i);
         continue;
      }
      if(!EmaDirectionAllowsLeg(e.leg))
      {
         VirtualPendingRemoveAt(i);
         continue;
      }
      if(basePrice > 0.0 && ArraySize(gridLevels) >= MaxGridLevels + 1)
      {
         if(!VirtualPriceMatchesRegisteredGrid(e.priceLevel))
         {
            VirtualPendingRemoveAt(i);
            continue;
         }
      }
      bool trigger = false;
      // Trên thị trường: Buy Stop — Ask cắt lên; Sell Limit — Bid cắt lên (chuẩn MT5).
      if(e.orderType == ORDER_TYPE_BUY_STOP)
         trigger = (prevAsk < (e.priceLevel - tol) && ask >= (e.priceLevel - tol));
      else if(e.orderType == ORDER_TYPE_SELL_LIMIT)
         trigger = (prevBid < (e.priceLevel - tol) && bid >= (e.priceLevel - tol));
      // Dưới gốc (-1): Sell Stop — Bid cắt từ trên xuống.
      else if(e.orderType == ORDER_TYPE_SELL_STOP)
         trigger = (prevBid > (e.priceLevel + tol) && bid <= (e.priceLevel + tol));
      // Dưới gốc (-1): Buy Limit — Ask cắt từ trên xuống.
      else if(e.orderType == ORDER_TYPE_BUY_LIMIT)
         trigger = (prevAsk > (e.priceLevel + tol) && ask <= (e.priceLevel + tol));
      else
         continue;
      if(!trigger) continue;

      trade.SetExpertMagicNumber(e.magic);
      string cmt = BuildOrderCommentWithLevel(e.leg, e.levelNum);
      bool ok = false;
      double sl = 0.0; // Trading Stop sẽ tự gắn sau khi lệnh đi thuận lợi đủ X pip.
      double tp = e.tpPrice;
      if(e.orderType == ORDER_TYPE_BUY_STOP || e.orderType == ORDER_TYPE_BUY_LIMIT)
         ok = trade.Buy(e.lot, _Symbol, 0.0, sl, tp, cmt);
      else
         ok = trade.Sell(e.lot, _Symbol, 0.0, sl, tp, cmt);
      if(ok)
      {
         Print("VGridABCD -> market: ", EnumToString(e.orderType), " magic ", e.magic, " lot ", e.lot, " at level ", e.priceLevel, " (", cmt, ")");
         VirtualExecCooldownAdd(e.priceLevel, (e.orderType == ORDER_TYPE_BUY_STOP || e.orderType == ORDER_TYPE_BUY_LIMIT), e.leg);
      }
      else
         Print("VGridABCD execute fail: ", EnumToString(e.orderType), " err ", GetLastError());
      VirtualPendingRemoveAt(i);
   }
   trade.SetExpertMagicNumber(MagicAA);
   // Update last tick prices after processing triggers.
   lastTickBid = bid;
   lastTickAsk = ask;
}

//+------------------------------------------------------------------+
//| Position P/L = profit + swap (overnight fee). Commission only when position closed (in DEAL). |
//+------------------------------------------------------------------+
double GetPositionPnL(ulong ticket)
{
   if(!PositionIsOurSymbolAndMagic(ticket)) return 0.0;
   return PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
}

//+------------------------------------------------------------------+
//| Tổng float (profit+swap) vị thế mở: magic EA + symbol biểu đồ (không gộp symbol khác). |
//+------------------------------------------------------------------+
double GetOurMagicFloatingUSD()
{
   double f = 0.0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(!PositionIsOurSymbolAndMagic(ticket))
         continue;
      f += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   return f;
}

//+------------------------------------------------------------------+
//| "Vốn giao dịch" quan sát được: số dư lúc gắn EA + P/L đóng lệnh   |
//| (deal OUT) + float — không chứa hiệu ứng nạp/rút sau attach.       |
//+------------------------------------------------------------------+
double GetTradingEquityViewUSD()
{
   return attachBalance + eaCumulativeTradingPL + GetOurMagicFloatingUSD();
}

//+------------------------------------------------------------------+
//| Vốn đã đóng: chỉ balance gốc + P/L deal OUT, bỏ qua lệnh thả nổi. |
//+------------------------------------------------------------------+
double GetTradingClosedCapitalUSD()
{
   return attachBalance + eaCumulativeTradingPL;
}

//+------------------------------------------------------------------+
//| Mốc cho % P/L trong tin: TEV tại khởi động EA (đóng+treo tại thời điểm đó). |
//| Reset phiên không làm mới mốc.                                   |
//+------------------------------------------------------------------+
double GetScaleCapitalReferenceUSD()
{
   if(initialCapitalBaselineUSD > 0.0)
      return initialCapitalBaselineUSD;
   if(attachBalance > 0.0)
      return attachBalance;
   return 0.0;
}

//+------------------------------------------------------------------+
//| % thay đổi TEV so với mốc khởi động (không tính nạp/rút vào mốc).   |
//+------------------------------------------------------------------+
double GetTradingEquityViewPctVsScaleBaseline()
{
   const double r0 = GetScaleCapitalReferenceUSD();
   if(r0 <= 0.0)
      return 0.0;
   return (GetTradingEquityViewUSD() / r0 - 1.0) * 100.0;
}

//+------------------------------------------------------------------+
//| Khóa phiên sau SL gồng lãi tổng tới hết ngày server.              |
//+------------------------------------------------------------------+
long ServerDateKey(const datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return (long)dt.year * 10000L + (long)dt.mon * 100L + (long)dt.day;
}

bool IsCompoundSlPauseActiveNow(const datetime nowSrv)
{
   if(g_compoundSlPauseDateKey == 0)
      return false;
   const long nowDateKey = ServerDateKey(nowSrv);
   if(g_compoundSlPauseDateKey != nowDateKey)
   {
      g_compoundSlPauseDateKey = 0;
      g_compoundSlPauseLoggedDateKey = 0;
      return false;
   }
   return true;
}


//+------------------------------------------------------------------+
//| 10: Panel bảng lợi nhuận tháng (deal OUT, magic+symbol EA).       |
//| Tiền tố object có Magic để không trùng khi >1 EA cùng biểu đồ.     |
//+------------------------------------------------------------------+
string MpPanelObjPrefix()
{
   return "VGridABCD_MPROF_" + IntegerToString(MagicAA) + "_";
}

int MpDaysInMonth(const int year, const int mon)
{
   if(mon == 2)
      return ((((year % 4 == 0) && (year % 100 != 0)) || (year % 400 == 0)) ? 29 : 28);
   if(mon == 4 || mon == 6 || mon == 9 || mon == 11)
      return 30;
   return 31;
}

datetime MpMonthStartServer(const int year, const int mon)
{
   MqlDateTime d;
   ZeroMemory(d);
   d.year = year;
   d.mon = mon;
   d.day = 1;
   d.hour = 0;
   d.min = 0;
   d.sec = 0;
   return StructToTime(d);
}

bool MpIsSameMonth(const datetime t, const datetime monthStart)
{
   MqlDateTime a, b;
   TimeToStruct(t, a);
   TimeToStruct(monthStart, b);
   return (a.year == b.year && a.mon == b.mon);
}

void MonthlyProfitPanelDeleteAll()
{
   const string pref = MpPanelObjPrefix();
   string toDel[];
   const int total = ObjectsTotal(0, -1, -1);
   for(int i = 0; i < total; i++)
   {
      const string nm = ObjectName(0, i, -1, -1);
      if(StringFind(nm, pref) == 0)
      {
         const int n = ArraySize(toDel);
         ArrayResize(toDel, n + 1);
         toDel[n] = nm;
      }
   }
   for(int j = 0; j < ArraySize(toDel); j++)
      ObjectDelete(0, toDel[j]);
}

bool MpLabelCreate(const string name, const int x, const int y, const string text,
                   const int fontPx, const color clr, const bool bold,
                   const ENUM_BASE_CORNER corner)
{
   if(ObjectFind(0, name) >= 0)
      ObjectDelete(0, name);
   if(!ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0))
      return false;
   ObjectSetInteger(0, name, OBJPROP_CORNER, corner);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontPx);
   ObjectSetString(0, name, OBJPROP_FONT, bold ? "Arial Bold" : "Arial");
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   return true;
}

bool MpRectCreate(const string name, const int x, const int y, const int w, const int h,
                  const color bg, const color border, const ENUM_BASE_CORNER corner)
{
   if(ObjectFind(0, name) >= 0)
      ObjectDelete(0, name);
   if(!ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0))
      return false;
   ObjectSetInteger(0, name, OBJPROP_CORNER, corner);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, name, OBJPROP_COLOR, border);
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   return true;
}

bool MpButtonCreate(const string name, const int x, const int y, const int w, const int h,
                    const string caption, const ENUM_BASE_CORNER corner)
{
   if(ObjectFind(0, name) >= 0)
      ObjectDelete(0, name);
   if(!ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0))
      return false;
   ObjectSetInteger(0, name, OBJPROP_CORNER, corner);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetString(0, name, OBJPROP_TEXT, caption);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, C'45,48,58');
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, C'70,75,90');
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   return true;
}

int MpCountOpenOurPositions()
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(!PositionIsOurSymbolAndMagic(ticket))
         continue;
      n++;
   }
   return n;
}

void MonthlyProfitPanelOnInitState()
{
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now); // Dùng giờ server theo tick hiện tại của sàn
   g_mpViewMonthStart = MpMonthStartServer(now.year, now.mon);
    g_mpLastSeenServerMonthStart = g_mpViewMonthStart;
   g_mpAutoFollowCurrentMonth = true;
}

void MonthlyProfitPanelOnTradeRefresh()
{
   if(!EnableMonthlyProfitPanel)
      return;
   g_mpLastRedrawTick = 0;
   MonthlyProfitPanelRedrawIfNeeded(true);
}

void MonthlyProfitPanelRedrawIfNeeded(const bool force)
{
   if(!EnableMonthlyProfitPanel)
   {
      if(g_mpPanelWasEnabled)
      {
         MonthlyProfitPanelDeleteAll();
         g_mpPanelWasEnabled = false;
      }
      return;
   }
   g_mpPanelWasEnabled = true;
   const ulong nowMs = GetTickCount64();
   if(!force && (nowMs - g_mpLastRedrawTick) < 400)
      return;
   g_mpLastRedrawTick = nowMs;

   if(g_mpViewMonthStart <= 0)
      MonthlyProfitPanelOnInitState();

   MqlDateTime vm;
   TimeToStruct(g_mpViewMonthStart, vm);
   const int vy = vm.year;
   const int vmon = vm.mon;
   const int dim = MpDaysInMonth(vy, vmon);
   const datetime tFrom = MpMonthStartServer(vy, vmon);
   MqlDateTime endm;
   endm.year = vy;
   endm.mon = vmon;
   endm.day = dim;
   endm.hour = 23;
   endm.min = 59;
   endm.sec = 59;
   const datetime tTo = StructToTime(endm);

   static double dayPnl[32];
   static int dayDeals[32];
   ArrayInitialize(dayPnl, 0.0);
   ArrayInitialize(dayDeals, 0);

   double monthTotal = 0.0;
   int totalClosedDeals = 0;
   // Chỉ tháng đang xem (vy/vmon): sang tháng mới = tổng lại từ deal tháng đó (chưa có deal → 0).
   double monthSumUsdProfit = 0.0;   // Σ lệnh đóng lãi trong tháng (profit+swap+commission), >0
   double monthSumUsdLossAbs = 0.0; // Σ |lỗ| trong tháng (deal đóng âm)
   int tradingDays = 0;

   if(HistorySelect(tFrom, tTo))
   {
      const int nd = HistoryDealsTotal();
      for(int i = 0; i < nd; i++)
      {
         const ulong dealTicket = HistoryDealGetTicket(i);
         if(dealTicket == 0)
            continue;
         const long dType = HistoryDealGetInteger(dealTicket, DEAL_TYPE);
         if(dType != DEAL_TYPE_BUY && dType != DEAL_TYPE_SELL)
            continue;
         if(HistoryDealGetInteger(dealTicket, DEAL_ENTRY) != DEAL_ENTRY_OUT)
            continue;
         if(!IsOurMagic(HistoryDealGetInteger(dealTicket, DEAL_MAGIC)))
            continue;
         if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol)
            continue;
         const datetime dt = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
         if(dt < tFrom || dt > tTo)
            continue;

         MqlDateTime dd;
         TimeToStruct(dt, dd);
         if(dd.year != vy || dd.mon != vmon || dd.day < 1 || dd.day > 31)
            continue;

         const double fullPnL = HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
                                + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
                                + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
         const int di = dd.day;
         dayPnl[di] += fullPnL;
         dayDeals[di]++;
         monthTotal += fullPnL;
         totalClosedDeals++;
         if(fullPnL > 0.0)
            monthSumUsdProfit += fullPnL;
         else if(fullPnL < 0.0)
            monthSumUsdLossAbs += -fullPnL;
      }
   }

   for(int d = 1; d <= 31; d++)
   {
      if(dayDeals[d] > 0)
         tradingDays++;
   }

   const double avgDaily = (tradingDays > 0) ? (monthTotal / (double)tradingDays) : 0.0;
   const double usdWinLossDenom = monthSumUsdProfit + monthSumUsdLossAbs;
   double winRateUsdPct = 0.0;
   if(usdWinLossDenom > 1e-8)
      winRateUsdPct = 100.0 * monthSumUsdProfit / usdWinLossDenom;

   MqlDateTime srvNow;
   TimeToStruct(TimeCurrent(), srvNow); // Dùng giờ server theo tick hiện tại của sàn
   const datetime todayMonthStart = MpMonthStartServer(srvNow.year, srvNow.mon);
   if(g_mpLastSeenServerMonthStart <= 0)
      g_mpLastSeenServerMonthStart = todayMonthStart;
   if(todayMonthStart != g_mpLastSeenServerMonthStart)
   {
      // Sang tháng mới: ép panel về tháng hiện tại để tổng tháng bắt đầu lại từ 0.
      g_mpLastSeenServerMonthStart = todayMonthStart;
      g_mpViewMonthStart = todayMonthStart;
      g_mpAutoFollowCurrentMonth = true;
   }
   if(g_mpAutoFollowCurrentMonth && g_mpViewMonthStart != todayMonthStart)
      g_mpViewMonthStart = todayMonthStart;
   const bool isViewingCurrentMonth = (g_mpViewMonthStart == todayMonthStart);

   MonthlyProfitPanelDeleteAll();

   const ENUM_BASE_CORNER crn = CORNER_LEFT_UPPER;
   const int ox = 12;
   const int oy = 28;
   const int f0 = 9;
   const int fTitle = f0 + 2;
   const int fBig = f0 + 4;

   const color C_BG = C'14,16,20';
   const color C_CARD = C'28,31,38';
   const color C_BORDER = C'48,52,62';
   const color C_TEXT = clrWhite;
   const color C_MUTED = C'140,145,158';
   const color C_GREEN = C'0,220,130';
   const color C_RED = C'255,120,120';
   const color C_BLUE = C'60,150,255';
   const color C_ORANGE = C'255,170,60';

   const int W = 900;
   const int H = 604;
   const int pad = 10;
   int y = oy;

   MpRectCreate(MpPanelObjPrefix() + "main", ox, y, W, H, C_BG, C_BORDER, crn);
   y += pad;

   MpLabelCreate(MpPanelObjPrefix() + "hdr", ox + pad, y,
                  "BẢNG LỢI NHUẬN THÁNG (#" + IntegerToString(MagicAA) + ")", fTitle, C_TEXT, true, crn);
   y += 26;

   const int cardW = (W - pad * 5) / 4;
   const int cardH = 98;
   const int gap = pad;
   int cx = ox + pad;

   MpRectCreate(MpPanelObjPrefix() + "c1", cx, y, cardW, cardH, C_CARD, C_BORDER, crn);
   MpLabelCreate(MpPanelObjPrefix() + "c1t", cx + 8, y + 6, "TỔNG LỢI NHUẬN THÁNG", f0, C_MUTED, false, crn);
   string sTot = (monthTotal >= 0.0 ? "+" : "") + DoubleToString(monthTotal, 2) + " " + AccountInfoString(ACCOUNT_CURRENCY);
   MpLabelCreate(MpPanelObjPrefix() + "c1v", cx + 8, y + 24, sTot, fBig, (monthTotal >= 0.0 ? C_GREEN : C_RED), true, crn);
   if(isViewingCurrentMonth)
      MpLabelCreate(MpPanelObjPrefix() + "c1b", cx + cardW - 86, y + 30, "THÁNG NÀY", f0 - 1, C_GREEN, true, crn);

   cx += cardW + gap;
   MpRectCreate(MpPanelObjPrefix() + "c2", cx, y, cardW, cardH, C_CARD, C_BORDER, crn);
   MpLabelCreate(MpPanelObjPrefix() + "c2t", cx + 8, y + 6, "LỢI NHUẬN TB NGÀY", f0, C_MUTED, false, crn);
   string sAvg = (avgDaily >= 0.0 ? "+" : "") + DoubleToString(avgDaily, 2) + " " + AccountInfoString(ACCOUNT_CURRENCY);
   MpLabelCreate(MpPanelObjPrefix() + "c2v", cx + 8, y + 24, sAvg, fBig, C_TEXT, true, crn);
   MpLabelCreate(MpPanelObjPrefix() + "c2s", cx + 8, y + 74, IntegerToString(tradingDays) + " Ngày giao dịch", f0 - 1, C_MUTED, false, crn);

   cx += cardW + gap;
   MpRectCreate(MpPanelObjPrefix() + "c3", cx, y, cardW, cardH, C_CARD, C_BORDER, crn);
   MpLabelCreate(MpPanelObjPrefix() + "c3t", cx + 8, y + 4, "LÃI/LỖ USD (THEO THÁNG)", f0, C_MUTED, false, crn);
   const color c3PctClr = (totalClosedDeals == 0 ? C_TEXT : (winRateUsdPct >= 50.0 ? C_GREEN : C_RED));
   MpLabelCreate(MpPanelObjPrefix() + "c3v", cx + 8, y + 22, DoubleToString(winRateUsdPct, 1) + "%", fBig, c3PctClr, true, crn);
   const int c3sx = cx + 8;
   const int c3fSmall = f0 - 2;
   const string c3MonthOnly = "Tháng " + IntegerToString(vmon) + "/" + IntegerToString(vy);
   MpLabelCreate(MpPanelObjPrefix() + "c3sm", c3sx, y + 42, c3MonthOnly, f0 - 1, C_MUTED, false, crn);

   const string c3Cur = AccountInfoString(ACCOUNT_CURRENCY);
   if(totalClosedDeals == 0)
      MpLabelCreate(MpPanelObjPrefix() + "c3p", c3sx, y + 56, "Chưa có lệnh đóng (0)", c3fSmall, C_MUTED, false, crn);
   else if(usdWinLossDenom <= 1e-8)
      MpLabelCreate(MpPanelObjPrefix() + "c3p", c3sx, y + 56, "Hòa vốn (0 USD)", c3fSmall, C_MUTED, false, crn);
   else
   {
      const bool c3Up = (winRateUsdPct >= 50.0);
      const color c3BadgeBg = (c3Up ? C'24,92,58' : C'110,42,42');
      const color c3BadgeFg = (c3Up ? C'160,255,200' : C'255,190,190');
      const int c3bw = 52;
      const int c3bh = 16;
      const int c3bx = cx + cardW - 8 - c3bw;
      const int c3by = y + 40;
      MpRectCreate(MpPanelObjPrefix() + "c3bdg", c3bx, c3by, c3bw, c3bh, c3BadgeBg, c3BadgeBg, crn);
      MpLabelCreate(MpPanelObjPrefix() + "c3bdt", c3bx + 10, c3by + 2, (c3Up ? "Tăng" : "Giảm"), c3fSmall, c3BadgeFg, true, crn);
      MpLabelCreate(MpPanelObjPrefix() + "c3p", c3sx, y + 56, "Lãi +" + DoubleToString(monthSumUsdProfit, 2), c3fSmall, C_MUTED, false, crn);
      MpLabelCreate(MpPanelObjPrefix() + "c3l", c3sx, y + 68, "Lỗ " + DoubleToString(monthSumUsdLossAbs, 2) + " " + c3Cur, c3fSmall, C_MUTED, false, crn);
   }

   cx += cardW + gap;
   MpRectCreate(MpPanelObjPrefix() + "c4", cx, y, cardW, cardH, C_CARD, C_BORDER, crn);
   MpLabelCreate(MpPanelObjPrefix() + "c4t", cx + 8, y + 6, "LỢI NHUẬN TỪ LÚC GẮN EA", f0, C_MUTED, false, crn);
   const double attachProfitUsd = eaCumulativeTradingPL;
   string sAttach = (attachProfitUsd >= 0.0 ? "+" : "") + DoubleToString(attachProfitUsd, 2) + " " + AccountInfoString(ACCOUNT_CURRENCY);
   MpLabelCreate(MpPanelObjPrefix() + "c4v", cx + 8, y + 24, sAttach, fBig, (attachProfitUsd >= 0.0 ? C_GREEN : C_RED), true, crn);
   MpLabelCreate(MpPanelObjPrefix() + "c4s", cx + 8, y + 58, "Không reset theo tháng", f0 - 1, C_MUTED, false, crn);
   if(EnableEaAutoResetCountPanel)
      MpLabelCreate(MpPanelObjPrefix() + "c4r", cx + 8, y + 74,
                     "EA reset (tự động): " + IntegerToString(g_eaAutoResetCount) + " lần",
                     f0 - 1, C_ORANGE, true, crn);
   else
      MpLabelCreate(MpPanelObjPrefix() + "c4r", cx + 8, y + 74, " ", f0 - 1, C_MUTED, false, crn);

   y += cardH + 10;
   {
      string sCmpThr;
      if(EnableCompoundTotalFloatingProfit && GetCompoundBaseTriggerUsd() > 0.0)
         sCmpThr = "Ngưỡng gồng lãi tổng: " + DoubleToString(GetCompoundFloatingTriggerThresholdUsd(), 2)
                   + " " + AccountInfoString(ACCOUNT_CURRENCY);
      else
         sCmpThr = "Gồng lãi tổng: tắt hoặc ngưỡng ≤ 0";
      MpLabelCreate(MpPanelObjPrefix() + "cmpthr", ox + pad, y, sCmpThr, f0, C_BLUE, true, crn);
      if(EnableEaAutoResetCountPanel)
         MpLabelCreate(MpPanelObjPrefix() + "earst", ox + W - pad - 240, y,
                        "EA reset (tự động): " + IntegerToString(g_eaAutoResetCount) + " lần",
                        f0, C_ORANGE, true, crn);
   }
   y += 22;

   MpButtonCreate(MpPanelObjPrefix() + "prev", ox + pad, y, 26, 22, "<", crn);
   string monthTitle = "Tháng " + IntegerToString(vmon) + ", " + IntegerToString(vy);
   MpLabelCreate(MpPanelObjPrefix() + "month", ox + pad + 34, y + 3, monthTitle, f0, C_TEXT, true, crn);
   MpButtonCreate(MpPanelObjPrefix() + "next", ox + pad + 34 + 150, y, 26, 22, ">", crn);

   int legX = ox + W - pad - 300;
   MpLabelCreate(MpPanelObjPrefix() + "lg0", legX, y + 3, "●", f0 - 1, C_GREEN, false, crn);
   legX += 14;
   MpLabelCreate(MpPanelObjPrefix() + "lg1", legX, y + 3, "Lợi nhuận", f0 - 1, C_MUTED, false, crn);
   legX += 62;
   MpLabelCreate(MpPanelObjPrefix() + "lg2", legX, y + 3, "●", f0 - 1, C_RED, false, crn);
   legX += 14;
   MpLabelCreate(MpPanelObjPrefix() + "lg3", legX, y + 3, "Thua lỗ", f0 - 1, C_MUTED, false, crn);
   legX += 54;
   MpLabelCreate(MpPanelObjPrefix() + "lg4", legX, y + 3, "●", f0 - 1, C_BLUE, false, crn);
   legX += 14;
   MpLabelCreate(MpPanelObjPrefix() + "lg5", legX, y + 3, "Hôm nay", f0 - 1, C_MUTED, false, crn);

   y += 36;
   const string dowNames[7] = {"CHỦ NHẬT", "THỨ HAI", "THỨ BA", "THỨ TƯ", "THỨ NĂM", "THỨ SÁU", "THỨ BẢY"};
   const int cellW = (W - pad * 2) / 7;
   const int cellH = 56;
   int hx = ox + pad;
   for(int c = 0; c < 7; c++)
   {
      MpLabelCreate(MpPanelObjPrefix() + "hd" + IntegerToString(c), hx + 2, y, dowNames[c], f0 - 1, C_MUTED, false, crn);
      hx += cellW;
   }
   y += 24;

   MqlDateTime first;
   first.year = vy;
   first.mon = vmon;
   first.day = 1;
   first.hour = 12;
   first.min = 0;
   first.sec = 0;
   const datetime tFirst = StructToTime(first);
   MqlDateTime df;
   TimeToStruct(tFirst, df);
   const int lead = df.day_of_week;

   const bool monthIsFuture = (vy > srvNow.year)
                              || (vy == srvNow.year && vmon > srvNow.mon);
   const bool monthIsPast = (vy < srvNow.year)
                            || (vy == srvNow.year && vmon < srvNow.mon);

   int curDay = 1;
   for(int row = 0; row < 6; row++)
   {
      for(int col = 0; col < 7; col++)
      {
         if(row == 0 && col < lead)
            continue;
         if(curDay > dim)
            continue;

         const int cellX = ox + pad + col * cellW;
         const int cellY = y + row * cellH;

         MqlDateTime wk;
         ZeroMemory(wk);
         wk.year = vy;
         wk.mon = vmon;
         wk.day = curDay;
         wk.hour = 12;
         TimeToStruct(StructToTime(wk), wk);
         const int cellDow = wk.day_of_week;
         const bool weekend = (cellDow == 0 || cellDow == 6);

         const bool isToday = (vy == srvNow.year && vmon == srvNow.mon && curDay == srvNow.day);
         const bool cellFuture = monthIsFuture
                                 || (vy == srvNow.year && vmon == srvNow.mon && curDay > srvNow.day);
         const bool cellPast = monthIsPast
                               || (vy == srvNow.year && vmon == srvNow.mon && curDay < srvNow.day);

         if(isToday)
            MpRectCreate(MpPanelObjPrefix() + "cd" + IntegerToString(curDay), cellX + 1, cellY + 1, cellW - 2, cellH - 2,
                         C_CARD, C_BLUE, crn);
         else
            MpRectCreate(MpPanelObjPrefix() + "cd" + IntegerToString(curDay), cellX + 1, cellY + 1, cellW - 2, cellH - 2,
                         C_CARD, C_BORDER, crn);

         MpLabelCreate(MpPanelObjPrefix() + "dn" + IntegerToString(curDay), cellX + 6, cellY + 4,
                       IntegerToString(curDay), f0, C_TEXT, true, crn);

         string line2 = "";
         string line3 = "";
         color c2 = C_MUTED;

         if(dayDeals[curDay] > 0)
         {
            const double p = dayPnl[curDay];
            line2 = (p >= 0.0 ? "+" : "") + DoubleToString(p, 2);
            c2 = (p >= 0.0 ? C_GREEN : C_RED);
            line3 = IntegerToString(dayDeals[curDay]) + " LỆNH";
         }
         else if(isToday)
         {
            const int opn = MpCountOpenOurPositions();
            line2 = "ĐANG CHẠY:";
            line3 = IntegerToString(opn) + " LỆNH";
            c2 = C_BLUE;
         }
         else if(cellFuture)
         {
            line2 = "--";
            line3 = "";
         }
         else if(weekend)
         {
            line2 = "Nghi";
            line3 = "";
            c2 = C_MUTED;
         }
         else if(cellPast)
         {
            line2 = "Không có giao dịch";
            line3 = "";
         }
         else
         {
            line2 = "--";
            line3 = "";
         }

         MpLabelCreate(MpPanelObjPrefix() + "dp" + IntegerToString(curDay), cellX + 4, cellY + 20, line2, f0 - 1, c2, false, crn);
         MpLabelCreate(MpPanelObjPrefix() + "dc" + IntegerToString(curDay), cellX + 4, cellY + 34, line3, f0 - 2, C_MUTED, false, crn);

         if(isToday)
            MpLabelCreate(MpPanelObjPrefix() + "dot" + IntegerToString(curDay), cellX + cellW - 16, cellY + 4, "●", f0 - 1, C_BLUE, false, crn);

         curDay++;
      }
   }

   ChartRedraw(0);
}

void MonthlyProfitPanelShiftMonth(const int deltaMon)
{
   MqlDateTime d;
   TimeToStruct(g_mpViewMonthStart, d);
   int m = d.mon + deltaMon;
   int yr = d.year;
   while(m > 12)
   {
      m -= 12;
      yr++;
   }
   while(m < 1)
   {
      m += 12;
      yr--;
   }
   g_mpViewMonthStart = MpMonthStartServer(yr, m);
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now); // Dùng giờ server theo tick hiện tại của sàn
   const datetime todayMonthStart = MpMonthStartServer(now.year, now.mon);
   g_mpAutoFollowCurrentMonth = (g_mpViewMonthStart == todayMonthStart);
   g_mpLastRedrawTick = 0;
   MonthlyProfitPanelRedrawIfNeeded(true);
}

//+------------------------------------------------------------------+
//| Giá đặt gốc lưới: Bid hiện tại.                                    |
//+------------------------------------------------------------------+
double GridBasePriceAtPlacement()
{
   return NormalizeDouble(SymbolInfoDouble(_Symbol, SYMBOL_BID), dgt);
}

//+------------------------------------------------------------------+
//| Vẽ/cập nhật đường gốc trực tiếp trên chart.                      |
//+------------------------------------------------------------------+
void UpdateBaseLineOnChart()
{
   EaStartTimeObjectsApplyOrRemove();
   if(!EnableBaseLineAndEaStartMarker)
   {
      ObjectDelete(0, g_baseLineObjectName);
      return;
   }
   if(basePrice <= 0.0 || !MathIsValidNumber(basePrice))
   {
      ObjectDelete(0, g_baseLineObjectName);
      return;
   }

   if(ObjectFind(0, g_baseLineObjectName) < 0)
   {
      if(!ObjectCreate(0, g_baseLineObjectName, OBJ_HLINE, 0, 0, basePrice))
         return;
      ObjectSetInteger(0, g_baseLineObjectName, OBJPROP_COLOR, clrDeepSkyBlue);
      ObjectSetInteger(0, g_baseLineObjectName, OBJPROP_STYLE, STYLE_DASH);
      ObjectSetInteger(0, g_baseLineObjectName, OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, g_baseLineObjectName, OBJPROP_BACK, false);
      ObjectSetInteger(0, g_baseLineObjectName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, g_baseLineObjectName, OBJPROP_SELECTED, false);
      ObjectSetInteger(0, g_baseLineObjectName, OBJPROP_HIDDEN, true);
      ObjectSetString(0, g_baseLineObjectName, OBJPROP_TEXT, "VGridABCD Base");
   }
   ObjectSetDouble(0, g_baseLineObjectName, OBJPROP_PRICE, NormalizeDouble(basePrice, dgt));
}

//+------------------------------------------------------------------+
//| Vẽ/cập nhật đường điểm A gồng lãi tổng (nét đứt vàng).           |
//+------------------------------------------------------------------+
void UpdateCompoundPointALineOnChart()
{
   const bool show = (g_compoundFrozenRefPx > 0.0 && MathIsValidNumber(g_compoundFrozenRefPx)
                      && (g_compoundAfterClearWaitGrid || g_compoundTotalProfitActive
                          || g_compoundPointASessionLocked));
   if(!show)
   {
      ObjectDelete(0, VGRIDABCD_COMPOUND_POINT_A_LINE);
      return;
   }

   const double priceA = NormalizeDouble(g_compoundFrozenRefPx, dgt);
   if(ObjectFind(0, VGRIDABCD_COMPOUND_POINT_A_LINE) < 0)
   {
      if(!ObjectCreate(0, VGRIDABCD_COMPOUND_POINT_A_LINE, OBJ_HLINE, 0, 0, priceA))
         return;
      ObjectSetInteger(0, VGRIDABCD_COMPOUND_POINT_A_LINE, OBJPROP_COLOR, clrYellow);
      ObjectSetInteger(0, VGRIDABCD_COMPOUND_POINT_A_LINE, OBJPROP_STYLE, STYLE_DASH);
      ObjectSetInteger(0, VGRIDABCD_COMPOUND_POINT_A_LINE, OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, VGRIDABCD_COMPOUND_POINT_A_LINE, OBJPROP_BACK, false);
      ObjectSetInteger(0, VGRIDABCD_COMPOUND_POINT_A_LINE, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, VGRIDABCD_COMPOUND_POINT_A_LINE, OBJPROP_SELECTED, false);
      ObjectSetInteger(0, VGRIDABCD_COMPOUND_POINT_A_LINE, OBJPROP_HIDDEN, true);
      ObjectSetString(0, VGRIDABCD_COMPOUND_POINT_A_LINE, OBJPROP_TEXT, "VGridABCD Diem A");
   }
   ObjectSetDouble(0, VGRIDABCD_COMPOUND_POINT_A_LINE, OBJPROP_PRICE, priceA);
}

//+------------------------------------------------------------------+
//| Vạch dọc + nhãn thời gian đặt đường gốc của phiên hiện tại.        |
//+------------------------------------------------------------------+
void EaStartTimeObjectsApplyOrRemove()
{
   const datetime baseAnchorTime = (basePrice > 0.0 && sessionStartTime > 0 ? sessionStartTime : 0);
   if(!EnableBaseLineAndEaStartMarker || baseAnchorTime <= 0)
   {
      ObjectDelete(0, VGRIDABCD_EA_START_VLINE);
      ObjectDelete(0, VGRIDABCD_EA_START_TEXT);
      return;
   }

   if(ObjectFind(0, VGRIDABCD_EA_START_VLINE) < 0)
   {
      if(!ObjectCreate(0, VGRIDABCD_EA_START_VLINE, OBJ_VLINE, 0, baseAnchorTime, 0.0))
      {
         Print("VGridABCD: không tạo vạch dọc thời gian đặt gốc (OBJ_VLINE).");
         return;
      }
   }
   ObjectMove(0, VGRIDABCD_EA_START_VLINE, 0, baseAnchorTime, 0.0);
   ObjectSetInteger(0, VGRIDABCD_EA_START_VLINE, OBJPROP_COLOR, clrDodgerBlue);
   ObjectSetInteger(0, VGRIDABCD_EA_START_VLINE, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, VGRIDABCD_EA_START_VLINE, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, VGRIDABCD_EA_START_VLINE, OBJPROP_BACK, true);
   ObjectSetInteger(0, VGRIDABCD_EA_START_VLINE, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, VGRIDABCD_EA_START_VLINE, OBJPROP_SELECTED, false);
   ObjectSetInteger(0, VGRIDABCD_EA_START_VLINE, OBJPROP_HIDDEN, false);
   ObjectSetInteger(0, VGRIDABCD_EA_START_VLINE, OBJPROP_TIMEFRAMES, OBJ_ALL_PERIODS);
   ObjectSetString(0, VGRIDABCD_EA_START_VLINE, OBJPROP_TOOLTIP,
                   "VGridABCD đặt đường gốc (server): " + TimeToString(baseAnchorTime, TIME_DATE|TIME_MINUTES|TIME_SECONDS));

   double pr = ChartGetDouble(0, CHART_PRICE_MAX);
   if(!MathIsValidNumber(pr) || pr <= 0.0)
      pr = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ObjectFind(0, VGRIDABCD_EA_START_TEXT) < 0)
   {
      if(!ObjectCreate(0, VGRIDABCD_EA_START_TEXT, OBJ_TEXT, 0, baseAnchorTime, pr))
      {
         Print("VGridABCD: không tạo nhãn thời gian đặt gốc (OBJ_TEXT).");
         return;
      }
   }
   ObjectMove(0, VGRIDABCD_EA_START_TEXT, 0, baseAnchorTime, pr);
   const string txt = "BASE " + TimeToString(baseAnchorTime, TIME_DATE|TIME_MINUTES|TIME_SECONDS);
   ObjectSetString(0, VGRIDABCD_EA_START_TEXT, OBJPROP_TEXT, txt);
   ObjectSetInteger(0, VGRIDABCD_EA_START_TEXT, OBJPROP_COLOR, clrDodgerBlue);
   ObjectSetInteger(0, VGRIDABCD_EA_START_TEXT, OBJPROP_FONTSIZE, 9);
   ObjectSetString(0, VGRIDABCD_EA_START_TEXT, OBJPROP_FONT, "Arial");
   ObjectSetInteger(0, VGRIDABCD_EA_START_TEXT, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
   ObjectSetInteger(0, VGRIDABCD_EA_START_TEXT, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, VGRIDABCD_EA_START_TEXT, OBJPROP_HIDDEN, false);
   ObjectSetInteger(0, VGRIDABCD_EA_START_TEXT, OBJPROP_BACK, false);
   ObjectSetString(0, VGRIDABCD_EA_START_TEXT, OBJPROP_TOOLTIP, "Thời gian EA đặt đường gốc (TimeCurrent server)");

   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   g_isOnInitBootstrap = true;
   eaAttachTime = TimeCurrent();
   MagicAA = MagicNumber;
   trade.SetExpertMagicNumber(MagicAA);
   dgt = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   pnt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   basePrice = 0.0;
   lastTickBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   lastTickAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   eaCumulativeTradingPL = 0.0;

   // Gốc % P/L & TEV: chỉ snapshot một lần — nạp/rút sau đó không cập nhật biến này
   attachBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double tevInit = GetTradingEquityViewUSD();
   initialCapitalBaselineUSD = tevInit;
   if(initialCapitalBaselineUSD <= 0.0)
      initialCapitalBaselineUSD = attachBalance;
   sessionPeakTradingEquityView = tevInit;
   sessionMinTradingEquityView = tevInit;
   globalPeakTradingEquityView = tevInit;
   globalMinTradingEquityView = tevInit;
   sessionMaxSingleLot = 0.0;
   sessionTotalLotAtMaxLot = 0.0;
   CompoundModeClearState();
   CompoundPointAClearSession();
   g_gridCommonSlBuyLine = 0.0;
   g_gridCommonSlSellLine = 0.0;

   StartupRsiCrossResetLatch();
   StartupRsiInitHandle();
   StartupRsiPollCrossLatch(true);
   EmaDirectionClearLock();
   EmaDirectionInitHandle();

   g_runtimeSessionActive = !IsCompoundSlPauseActiveNow(TimeCurrent());
   g_gridPendingEntryModeSynced = (ENUM_GRID_PENDING_ENTRY_MODE)-1;
   GridPendingEntryModeSync();
   if(g_runtimeSessionActive)
   {
      if(!TryPlaceBaseAfterStartupFilters())
      {
         VirtualPendingClear();
         ArrayResize(gridLevels, 0);
         sessionStartTime = 0;
         basePrice = 0.0;
         EmaDirectionClearLock();
         EmaDirectionLogHighLowWaitIfNeeded();
      }
   }
   else
   {
      VirtualPendingClear();
      ArrayResize(gridLevels, 0);
      sessionStartTime = 0;
      Print("VGridABCD: tạm dừng sau SL gồng lãi tổng — chờ sang ngày server kế tiếp.");
   }
   Print("========================================");
   Print("VGridABCD đã chạy.");
   Print("Symbol: ", _Symbol, " | Base: ", basePrice, " | Grid: ", GridDistancePips, " pips | Levels: ", ArraySize(gridLevels));
   Print("Chế độ chờ: ", (GridUsesVirtualPendingMode() ? "CHỜ ẢO" : "CHỜ BROKER"),
         " | chân Buy A/B, Sell C/D (+/−) | mức=", ArraySize(gridLevels),
         " | L1 A=", VirtualGridResolvedL1(VGRID_LEG_BUY_ABOVE),
         " | B=", VirtualGridResolvedL1(VGRID_LEG_BUY_ABOVE_E),
         " | C=", VirtualGridResolvedL1(VGRID_LEG_SELL_ABOVE),
         " | D=", VirtualGridResolvedL1(VGRID_LEG_SELL_ABOVE_G));
   if(EnableStartupRsiCrossUpFilter)
      Print("RSI khởi động: BẬT | ", EnumToString(StartupRsiResolvedTimeframe()),
            " period=", StartupRsiPeriod,
            " | ", StartupRsiConfigLabel(),
            " | X1=", DoubleToString(StartupRsiCrossUpLevel, 2),
            " | X2=", DoubleToString(StartupRsiCrossDownLevel, 2),
            (g_startupRsiCrossLatch ? " | đã thỏa" : " | chờ tín hiệu"));
   if(EnableEmaDirectionFilter)
   {
      if(EmaDirectionUsesHighLowMode())
         Print("EMA lọc chiều: BẬT | High/Low | ", EnumToString(EmaDirectionResolvedTimeframe()),
               " period=", EmaDirectionPeriod,
               " | Close>EMA(High)=Buy; Close<EMA(Low)=Sell; khóa chiều lúc đặt gốc đến reset",
               (g_emaDirectionLock > 0 ? " | phiên Buy" : (g_emaDirectionLock < 0 ? " | phiên Sell" : " | chờ ngoài vùng EMA")));
      else
         Print("EMA lọc chiều: BẬT | Close | ", EnumToString(EmaDirectionResolvedTimeframe()),
               " period=", EmaDirectionPeriod,
               (g_emaDirectionLock > 0 ? " | khóa chỉ Buy" : (g_emaDirectionLock < 0 ? " | khóa chỉ Sell" : " | chờ nến đóng vs EMA")));
   }
   Print("VGridABCD: nạp/rút broker không đổi cấu hình EA — lưới/lot/mục tiêu theo input + P/L giao dịch (TEV), không theo số dư ledger.");
   Print("========================================");
   if(g_runtimeSessionActive)
      ManageGridOrders();
   UpdateBaseLineOnChart();
   MonthlyProfitPanelOnInitState();
   if(EnableMonthlyProfitPanel)
   {
      EventKillTimer();
      EventSetTimer(8);
      MonthlyProfitPanelRedrawIfNeeded(true);
   }
   else
   {
      EventKillTimer();
      MonthlyProfitPanelDeleteAll();
      g_mpPanelWasEnabled = false;
   }
   EaStartTimeObjectsApplyOrRemove();
   SendStartupTelegramScreenshot("EA vừa gắn vào biểu đồ");
   g_isOnInitBootstrap = false;
   CompoundFloatThrHudUpdate(true);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   StartupRsiReleaseHandle();
   EmaDirectionReleaseHandle();
   CompoundFloatThrHudDeleteAll();
   EaAutoResetCountPanelDeleteAll();
   MonthlyProfitPanelDeleteAll();
   ObjectDelete(0, VGRIDABCD_EA_START_VLINE);
   ObjectDelete(0, VGRIDABCD_EA_START_TEXT);
   // Gỡ object chart từ bản EA cũ (tên cố định)
   ObjectDelete(0, "VGridABCD_BaseLine");
   ObjectDelete(0, VGRIDABCD_COMPOUND_POINT_A_LINE);
   ObjectDelete(0, "VPGrid_BaseLine");
   ObjectDelete(0, "VPGrid_PoolGateAbove");
   ObjectDelete(0, "VPGrid_PoolGateBelow");
   ObjectDelete(0, "VPGrid_PoolGateZone");
   if(EnableResetNotification)
   {
      UpdateSessionStatsForNotification();
      SendResetNotification("EA đã dừng (mã lý do: " + IntegerToString(reason) + ")");
   }
   Print("VGridABCD đã dừng. Mã lý do: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   UpdateBaseLineOnChart();
   UpdateCompoundPointALineOnChart();
   MonthlyProfitPanelRedrawIfNeeded(false);

   // Tạm dừng sau SL gồng lãi tổng — chờ sang ngày server kế tiếp.
   if(!g_runtimeSessionActive)
   {
      const datetime nowSrv = TimeCurrent();
      if(IsCompoundSlPauseActiveNow(nowSrv))
      {
         const long nowDateKey = ServerDateKey(nowSrv);
         if(g_compoundSlPauseLoggedDateKey != nowDateKey)
         {
            g_compoundSlPauseLoggedDateKey = nowDateKey;
            Print("VGridABCD: đang tạm dừng sau SL chung gồng lãi tổng. Chờ sang ngày server mới để cho phép khởi động phiên mới.");
         }
         return;
      }

      g_runtimeSessionActive = true;
      StartupRsiPollCrossLatch(false);
      if(TryPlaceBaseAfterStartupFilters())
      {
         Print("VGridABCD: hết tạm dừng SL gồng — khởi động phiên mới, base=", DoubleToString(basePrice, dgt));
         if(EnableResetNotification)
            SendResetNotification("Hết tạm dừng SL gồng — EA khởi động phiên mới");
         ManageGridOrders();
      }
      else
      {
         ArrayResize(gridLevels, 0);
         sessionStartTime = 0;
         basePrice = 0.0;
         EmaDirectionClearLock();
      }
      return;
   }

   const int expectedGridLevelCount = MaxGridLevels * 2;

   if(basePrice <= 0.0)
   {
      if(StartupRsiFilterActive() && !g_startupRsiCrossLatch)
         StartupRsiPollCrossLatch(false);
      EmaDirectionLogHighLowWaitIfNeeded();
      if(!TryPlaceBaseAfterStartupFilters())
         return;
      Print("VGridABCD: đặt gốc — base=", DoubleToString(basePrice, dgt),
            (StartupRsiFilterActive() ? " (RSI " + StartupRsiConfigLabel() + ")" : ""),
            (EmaDirectionUsesHighLowMode()
               ? (g_emaDirectionLock > 0 ? " (EMA High/Low Buy)" : " (EMA High/Low Sell)")
               : ""));
      if(EnableResetNotification)
         SendResetNotification("Đủ điều kiện — bắt đầu lưới chờ ảo");
      ManageGridOrders();
      return;
   }

   // Đã có gốc, EA chưa reset: không đổi basePrice — chỉ nạp lại mức lưới nếu mảng lệch (hiếm).
   if(basePrice > 0.0 && ArraySize(gridLevels) < expectedGridLevelCount)
   {
      InitializeGridLevels();
      Print("VGridABCD: nạp lại mức lưới theo base giữ nguyên base=", DoubleToString(basePrice, dgt));
      ManageGridOrders();
      return;
   }

   ProcessVirtualPendingExecutions();

   SessionFloatLossAdjustPoll();

   if(basePrice > 0.0 && !GridCommonSlBlockedByCompoundMode())
      ProcessGridCommonStopLoss();
   ProcessVirtualGridLegTradingStops();

   double compoundOpenProfitSwapUsd = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(!PositionIsOurSymbolAndMagic(ticket))
         continue;
      if(!CompoundPositionPassesSessionFilter(ticket))
         continue;
      compoundOpenProfitSwapUsd += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }

   const double compoundTriggerProgressUsd = GetCompoundTriggerProgressUsd(compoundOpenProfitSwapUsd);

   if(EnableCompoundTotalFloatingProfit && GetCompoundBaseTriggerUsd() > 0.0)
   {
      if(g_compoundTotalProfitActive)
         ProcessCompoundTotalProfitTrailing();
      else
      {
         CompoundRefreshTrackingReference(compoundTriggerProgressUsd);
         if(g_compoundAfterClearWaitGrid)
            ProcessCompoundWaitingFirstGridStep();
      }
      if(CompoundPointAIsActive())
         CompoundEnforceNoTpWhenPointAActive();
   }

   if(EnableResetNotification)
      UpdateSessionStatsForNotification();

   ManageGridOrdersThrottled();
}

//+------------------------------------------------------------------+
//| Timer: làm mới panel lợi nhuận tháng (khi bật).                    |
//+------------------------------------------------------------------+
void OnTimer()
{
   if(EnableMonthlyProfitPanel)
      MonthlyProfitPanelRedrawIfNeeded(true);
}

//+------------------------------------------------------------------+
//| Click nút < > đổi tháng trên panel.                                |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id != CHARTEVENT_OBJECT_CLICK)
      return;
   if(!EnableMonthlyProfitPanel)
      return;
   if(sparam == MpPanelObjPrefix() + "prev")
   {
      MonthlyProfitPanelShiftMonth(-1);
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
   }
   else if(sparam == MpPanelObjPrefix() + "next")
   {
      MonthlyProfitPanelShiftMonth(1);
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
   }
}

//+------------------------------------------------------------------+
//| Throttle ManageGridOrders to reduce per-tick workload             |
//| - Virtual stop triggers still run every tick (ProcessVirtual...). |
//| - Grid maintenance: at most once/sec; + ngay khi đóng vị thế (OUT). |
//| - Không bổ sung chờ ngay sau chờ ảo -> market (cooldown + vị thế).  |
//+------------------------------------------------------------------+
void ManageGridOrdersThrottled()
{
   static datetime lastManageTime = 0;
   datetime now = TimeCurrent();
   if(lastManageTime == now)
      return;  // avoid multiple full scans in same second
   lastManageTime = now;
   ManageGridOrders();
}

//+------------------------------------------------------------------+
//| Update peak/min balance (session + global since EA attach) and max lot in session |
//+------------------------------------------------------------------+
void UpdateSessionStatsForNotification()
{
   double tev = GetTradingEquityViewUSD();
   if(tev > sessionPeakTradingEquityView) sessionPeakTradingEquityView = tev;
   if(tev < sessionMinTradingEquityView) sessionMinTradingEquityView = tev;
   if(tev > globalPeakTradingEquityView) globalPeakTradingEquityView = tev;
   if(tev < globalMinTradingEquityView) globalMinTradingEquityView = tev;
   double totalLot = 0, maxLot = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(!PositionIsOurSymbolAndMagic(ticket))
         continue;
      double vol = PositionGetDouble(POSITION_VOLUME);
      totalLot += vol;
      if(vol > maxLot) maxLot = vol;
   }
   if(maxLot > sessionMaxSingleLot)
   {
      sessionMaxSingleLot = maxLot;
      sessionTotalLotAtMaxLot = totalLot;
   }
   if(maxLot > globalMaxSingleLot)
   {
      globalMaxSingleLot = maxLot;
      globalTotalLotAtMaxLot = totalLot;
   }
}

// Telegram/WebRequest block removed to lighten code.
// If you ever need Telegram back, define VDUALGRID_ENABLE_TELEGRAM before compiling.
#ifdef VDUALGRID_ENABLE_TELEGRAM
//+------------------------------------------------------------------+
//| URL encode for Telegram text                                       |
//+------------------------------------------------------------------+
string UrlEncodeForTelegram(const string s)
{
   string result = "";
   for(int i = 0; i < StringLen(s); i++)
   {
      ushort c = StringGetCharacter(s, i);
      if(c == ' ')
         result += "+";
      else if(c == '\n')
         result += "%0A";
      else if(c == '\r')
         result += "%0D";
      else if(c == '&')
         result += "%26";
      else if(c == '=')
         result += "%3D";
      else if(c == '+')
         result += "%2B";
      else if(c == '%')
         result += "%25";
      else if(c >= 32 && c < 127)
         result += CharToString((uchar)c);
      else
      {
         // UTF-8 rồi %HH từng byte (Telegram yêu cầu; %02X từ code unit 16-bit trước đây gây HTTP 400 với tiếng Việt)
         string oneChar = StringSubstr(s, i, 1);
         uchar bytes[];
         int nb = StringToCharArray(oneChar, bytes, 0, WHOLE_ARRAY, CP_UTF8);
         if(nb <= 0)
            continue;
         int useLen = nb;
         if(useLen > 0 && bytes[useLen - 1] == 0)
            useLen--;
         for(int k = 0; k < useLen; k++)
            result += "%" + StringFormat("%02X", (uint)bytes[k]);
      }
   }
   return result;
}

//+------------------------------------------------------------------+
//| Lấy message_id từ JSON phản hồi Telegram (sendMessage/sendPhoto). |
//+------------------------------------------------------------------+
long TelegramExtractMessageIdFromJson(const string json)
{
   int p = StringFind(json, "\"message_id\"");
   if(p < 0)
      return 0;
   int c = StringFind(json, ":", p);
   if(c < 0)
      return 0;
   int i = c + 1;
   int len = StringLen(json);
   while(i < len)
   {
      ushort w = StringGetCharacter(json, i);
      if(w == ' ' || w == '\t' || w == '\n' || w == '\r')
      {
         i++;
         continue;
      }
      break;
   }
   if(i >= len)
      return 0;
   long val = 0;
   bool neg = false;
   if(StringGetCharacter(json, i) == '-')
   {
      neg = true;
      i++;
   }
   while(i < len)
   {
      ushort ch = StringGetCharacter(json, i);
      if(ch < '0' || ch > '9')
         break;
      val = val * 10 + (long)(ch - '0');
      i++;
   }
   return neg ? -val : val;
}

//+------------------------------------------------------------------+
void TelegramNotifyIdsAppend(const long mid)
{
   if(mid <= 0)
      return;
   int n = ArraySize(g_telegramNotifyMsgIds);
   if(n >= 200)
      return;
   ArrayResize(g_telegramNotifyMsgIds, n + 1);
   g_telegramNotifyMsgIds[n] = mid;
}

//+------------------------------------------------------------------+
void TelegramApiDeleteMessage(const long messageId)
{
   if(!EnableTelegram || StringLen(TelegramBotToken) < 10 || StringLen(TelegramChatID) < 5 || messageId <= 0)
      return;
   string url = "https://api.telegram.org/bot" + TelegramBotToken + "/deleteMessage";
   string body = "chat_id=" + TelegramChatID + "&message_id=" + IntegerToString(messageId);
   uchar ubody[];
   int nw = StringToCharArray(body, ubody, 0, WHOLE_ARRAY, CP_UTF8);
   if(nw <= 0)
      return;
   int blen = nw;
   if(blen > 0 && ubody[blen - 1] == 0)
      blen--;
   char post[];
   ArrayResize(post, blen);
   for(int b = 0; b < blen; b++)
      post[b] = (char)ubody[b];
   char result[];
   string resultHeaders;
   string headers = "Content-Type: application/x-www-form-urlencoded; charset=UTF-8\r\n";
   ResetLastError();
   int res = WebRequest("POST", url, headers, 5000, post, result, resultHeaders);
   if(res != 200 && res >= 0)
   {
      string resp = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
      if(StringFind(resp, "\"ok\":true") < 0)
         Print("Telegram deleteMessage id=", messageId, " HTTP ", res, " ", StringSubstr(resp, 0, 280));
   }
}

//+------------------------------------------------------------------+
//| Xóa toàn bộ tin bot đã lưu từ lần thông báo trước (deleteMessage). |
//+------------------------------------------------------------------+
void TelegramDeleteAllPreviousNotifyMessages()
{
   int n = ArraySize(g_telegramNotifyMsgIds);
   if(n <= 0)
      return;
   if(StringLen(TelegramBotToken) < 10 || StringLen(TelegramChatID) < 5)
   {
      ArrayResize(g_telegramNotifyMsgIds, 0);
      return;
   }
   for(int i = 0; i < n; i++)
   {
      long mid = g_telegramNotifyMsgIds[i];
      if(mid > 0)
         TelegramApiDeleteMessage(mid);
      Sleep(50);
   }
   ArrayResize(g_telegramNotifyMsgIds, 0);
}

//+------------------------------------------------------------------+
//| Ghép chuỗi UTF-8 / byte nhị phân vào body POST (multipart).       |
//+------------------------------------------------------------------+
void TelegramPostAppendUtf8(char &post[], int &postLen, const string s)
{
   uchar u[];
   int n = StringToCharArray(s, u, 0, WHOLE_ARRAY, CP_UTF8);
   int L = n;
   if(L > 0 && u[L - 1] == 0)
      L--;
   int old = postLen;
   ArrayResize(post, old + L);
   for(int i = 0; i < L; i++)
      post[old + i] = (char)u[i];
   postLen = old + L;
}

void TelegramPostAppendBytes(char &post[], int &postLen, const uchar &data[], const int dataLen)
{
   int old = postLen;
   ArrayResize(post, old + dataLen);
   for(int i = 0; i < dataLen; i++)
      post[old + i] = (char)data[i];
   postLen = old + dataLen;
}

//+------------------------------------------------------------------+
//| Chụp chart hiện tại (GIF) + POST Telegram sendPhoto (multipart).  |
//+------------------------------------------------------------------+
void SendTelegramChartScreenshotIfEnabled(const string caption)
{
   if(!EnableTelegram)
      return;
   if(StringLen(TelegramBotToken) < 10 || StringLen(TelegramChatID) < 5)
      return;

   int w = TelegramScreenshotWidth;
   int h = TelegramScreenshotHeight;
   if(w < 320)
      w = 320;
   if(w > 1920)
      w = 1920;
   if(h < 240)
      h = 240;
   if(h > 1080)
      h = 1080;

   const string shotName = "vdualgrid_chart_shot.gif";
   ResetLastError();
   if(!ChartScreenShot(0, shotName, w, h, ALIGN_RIGHT))
   {
      Print("VGridABCD ảnh chart: ChartScreenShot thất bại (err ", GetLastError(), ") — mở chart gắn EA hoặc thử ngoài Strategy Tester.");
      return;
   }

   int fh = FileOpen(shotName, FILE_READ | FILE_BIN);
   if(fh == INVALID_HANDLE)
   {
      Print("VGridABCD ảnh chart: không mở được ", shotName, " err ", GetLastError());
      return;
   }
   ulong sz64 = FileSize(fh);
   if(sz64 < 32 || sz64 > 10485760UL)
   {
      FileClose(fh);
      FileDelete(shotName);
      Print("VGridABCD ảnh chart: kích thước file không hợp lệ: ", sz64);
      return;
   }
   int sz = (int)sz64;
   uchar gif[];
   ArrayResize(gif, sz);
   uint nread = FileReadArray(fh, gif, 0, sz);
   FileClose(fh);
   FileDelete(shotName);
   if(nread != (uint)sz)
   {
      Print("VGridABCD ảnh chart: đọc file thiếu byte (", nread, "/", sz, ").");
      return;
   }

   string bnd = "VDG" + IntegerToString((long)TimeCurrent()) + IntegerToString(GetTickCount());
   string ctype = "multipart/form-data; boundary=" + bnd;

   char post[];
   int plen = 0;
   TelegramPostAppendUtf8(post, plen, "--" + bnd + "\r\n");
   TelegramPostAppendUtf8(post, plen, "Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n");
   TelegramPostAppendUtf8(post, plen, TelegramChatID + "\r\n");

   string cap = caption;
   if(StringLen(cap) > 1024)
      cap = StringSubstr(cap, 0, 1021) + "...";
   if(StringLen(cap) > 0)
   {
      TelegramPostAppendUtf8(post, plen, "--" + bnd + "\r\n");
      TelegramPostAppendUtf8(post, plen, "Content-Disposition: form-data; name=\"caption\"\r\n\r\n");
      TelegramPostAppendUtf8(post, plen, cap + "\r\n");
   }

   TelegramPostAppendUtf8(post, plen, "--" + bnd + "\r\n");
   TelegramPostAppendUtf8(post, plen, "Content-Disposition: form-data; name=\"photo\"; filename=\"chart.gif\"\r\n");
   TelegramPostAppendUtf8(post, plen, "Content-Type: image/gif\r\n\r\n");
   TelegramPostAppendBytes(post, plen, gif, sz);
   TelegramPostAppendUtf8(post, plen, "\r\n--" + bnd + "--\r\n");

   string url = "https://api.telegram.org/bot" + TelegramBotToken + "/sendPhoto";
   string hdr = "Content-Type: " + ctype + "\r\nContent-Length: " + IntegerToString(plen) + "\r\n";

   char result[];
   string resultHeaders;
   ResetLastError();
   int res = WebRequest("POST", url, hdr, 45000, post, result, resultHeaders);
   if(res == 200 && TelegramDeletePreviousBotMessagesOnNotify)
   {
      string okBody = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
      long mid = TelegramExtractMessageIdFromJson(okBody);
      if(mid > 0)
         TelegramNotifyIdsAppend(mid);
   }
   if(res != 200)
   {
      string resp = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
      Print("Telegram sendPhoto: HTTP ", res, " GetLastError=", GetLastError(), " | ", StringSubstr(resp, 0, 700));
   }
}



//+------------------------------------------------------------------+
//| Chọn 1 trong n chuỗi theo seed (phân tích "AI" vui, không gọi mạng). |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Cắt chuỗi cho giới hạn Telegram (caption 1024, text 4096).         |
//+------------------------------------------------------------------+
string TelegramClampLen(const string s, const int maxLen)
{
   if(maxLen < 4)
      return "";
   if(StringLen(s) <= maxLen)
      return s;
   return StringSubstr(s, 0, maxLen - 3) + "...";
}

//+------------------------------------------------------------------+
//| Gửi thông báo MT5 + Telegram khi reset / dừng EA (nội dung tiếng Việt). |
//| Telegram: (1) sendMessage tin EA. (2) Nội dung chart+phân tích local: sendPhoto (caption ngắn) + sendMessage (tách chunk nếu dài); |
//|    không ảnh: một hoặc nhiều sendMessage. |
//|    Nếu bật TelegramDeletePreviousBotMessagesOnNotify: trước khi gửi, xóa các tin bot đã gửi ở lần thông báo trước (deleteMessage). |
//+------------------------------------------------------------------+
void SendResetNotification(const string reason)
{
   if(!EnableResetNotification && !(EnableTelegram && EnableTelegramResetNotification))
      return;
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int symDigits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   // % TEV hiện tại vs mốc TEV lúc khởi động EA (một mốc; reset phiên không làm mới mốc)
   double pct = GetTradingEquityViewPctVsScaleBaseline();
   double maxLossUSD = globalPeakTradingEquityView - globalMinTradingEquityView;
   // Tin đầy đủ (Telegram + chi tiết)
   string msg = "Thông báo VGridABCD\n";
   msg += "Biểu đồ: " + _Symbol + "\n";
   msg += "Lý do: " + reason + "\n";
   msg += "Giá tại thời điểm báo: " + DoubleToString(bid, symDigits) + "\n\n";
   msg += "--- THAM CHIẾU ---\n";
   msg += "Số dư ledger khi gắn EA: " + DoubleToString(attachBalance, 2) + " USD\n";
   msg += "TEV mốc khởi động (một lần, đóng+treo tại lúc đó): " + DoubleToString(GetScaleCapitalReferenceUSD(), 2) + " USD\n";
   msg += "Nạp/rút sau đó: không đổi mốc TEV/ledger snapshot, không đổi % trong tin theo nạp/rút; EA lưới/lot/mục tiêu theo input + P/L lệnh cùng magic.\n";
   msg += "\n--- TRẠNG THÁI ---\n";
   msg += "Số dư broker hiện tại: " + DoubleToString(bal, 2) + " USD\n";
   msg += "Lãi/lỗ TEV vs mốc khởi động EA (đóng + treo magic, không nạp/rút vào mốc): " + (pct >= 0 ? "+" : "") + DoubleToString(pct, 2) + "%\n";
   msg += "Biên độ sụt giảm tối đa (theo equity EA tính từ lúc gắn): " + DoubleToString(maxLossUSD, 2) + " USD\n";
   msg += "Mức equity thấp nhất kể từ lúc gắn EA: " + DoubleToString(globalMinTradingEquityView, 2) + " USD\n";
   msg += "--- EA MIỄN PHÍ ---\n";
   msg += "EA giao dịch tự động trên MT5 miễn phí.\n";
   msg += "Đăng ký tài khoản qua liên kết: https://one.exnessonelink.com/a/iu0hffnbzb\n";
   msg += "Sau khi đăng ký, gửi ID tài khoản để nhận EA.";
   // Điện thoại (SendNotification): tối đa 255 ký tự, chỉ tiếng Việt gọn
   string rShort = reason;
   const int rMaxPhone = 70;
   if(StringLen(rShort) > rMaxPhone)
      rShort = StringSubstr(rShort, 0, rMaxPhone - 3) + "...";
   const double v0 = GetScaleCapitalReferenceUSD();
   string msgPhone = "VGridABCD • " + _Symbol + "\n";
   msgPhone += "Lý do: " + rShort + "\n";
   msgPhone += "Số vốn lúc đầu: " + DoubleToString(v0, 2) + " USD\n";
   msgPhone += "Số dư hiện tại: " + DoubleToString(bal, 2) + " USD • Lãi/lỗ: ";
   msgPhone += (pct >= 0 ? "+" : "") + DoubleToString(pct, 1) + "%";
   while(StringLen(msgPhone) > 255)
      msgPhone = StringSubstr(msgPhone, 0, 252) + "...";
   if(EnableResetNotification)
      SendNotification(msgPhone);
   if(EnableTelegram && EnableTelegramResetNotification && !g_isOnInitBootstrap)
   {
      if(TelegramDeletePreviousBotMessagesOnNotify)
         TelegramDeleteAllPreviousNotifyMessages();
      // Telegram: chỉ gửi đúng 1 tin kèm ảnh (sendPhoto + caption), không gửi text rời.
      string capShot = "VGridABCD • " + _Symbol + "\nLý do: " + rShort + "\nGiá: " + DoubleToString(bid, symDigits)
                     + "\nSố dư: " + DoubleToString(bal, 2) + " USD | P/L: "
                     + (pct >= 0 ? "+" : "") + DoubleToString(pct, 1) + "%";
      SendTelegramChartScreenshotIfEnabled(TelegramClampLen(capShot, 1024));
   }
}

void SendStartupTelegramScreenshot(const string reason)
{
   if(!EnableTelegramStartupScreenshot)
      return;
   if(!EnableTelegram || !EnableTelegramResetNotification)
      return;
   string cap = _Symbol + " • khởi động EA";
   if(StringLen(reason) > 0)
      cap += " • " + reason;
   SendTelegramChartScreenshotIfEnabled(TelegramClampLen(cap, 1024));
}

#endif // VDUALGRID_ENABLE_TELEGRAM

//+------------------------------------------------------------------+
//| Gửi thông báo MT5 khi reset / dừng EA (push).                      |
//+------------------------------------------------------------------+
#ifndef VDUALGRID_ENABLE_TELEGRAM
void SendResetNotification(const string reason)
{
   if(!EnableResetNotification)
      return;
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double pct = GetTradingEquityViewPctVsScaleBaseline();
   string rShort = reason;
   const int rMaxPhone = 70;
   if(StringLen(rShort) > rMaxPhone)
      rShort = StringSubstr(rShort, 0, rMaxPhone - 3) + "...";
   const double v0 = GetScaleCapitalReferenceUSD();
   string msgPhone = "VGridABCD • " + _Symbol + "\n";
   msgPhone += "Lý do: " + rShort + "\n";
   msgPhone += "Số vốn lúc đầu: " + DoubleToString(v0, 2) + " USD\n";
   msgPhone += "Số dư hiện tại: " + DoubleToString(bal, 2) + " USD • Lãi/lỗ: ";
   msgPhone += (pct >= 0.0 ? "+" : "") + DoubleToString(pct, 1) + "%";
   while(StringLen(msgPhone) > 255)
      msgPhone = StringSubstr(msgPhone, 0, 252) + "...";
   SendNotification(msgPhone);
}

void SendStartupTelegramScreenshot(const string reason)
{
}
#endif

//+------------------------------------------------------------------+
//| Reset “đóng sạch” EA chart này: đóng toàn bộ vị thế mở (magic+symbol), |
//| xóa lệnh chờ broker cùng magic+symbol, xóa toàn bộ chờ ảo, tắt cờ gồng lãi. |
//+------------------------------------------------------------------+
void CloseAllPositionsAndOrders()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionIsOurSymbolAndMagic(ticket)) continue;
      trade.PositionClose(ticket);
   }
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(!OrderIsOurSymbolAndMagic(ticket)) continue;
      trade.OrderDelete(ticket);
   }
   VirtualPendingClear();
   // Không gọi CompoundModeClearState ở đây — caller (vd. CompoundResetAfterCommonSlHit) xử lý sau khi deal đóng.
}

//+------------------------------------------------------------------+
//| Giữ chờ ảo / lệnh broker chỉ trên các mức đã đăng ký; xóa lạc mức. |
void CancelStopOrdersOutsideBaseZone()
{
   if(basePrice <= 0.0 || ArraySize(gridLevels) < MaxGridLevels + 1)
      return;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket <= 0 || !IsOurMagic(OrderGetInteger(ORDER_MAGIC)) || OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      if(!OrderCommentIsGridPending(OrderGetString(ORDER_COMMENT)))
         continue;
      double price = OrderGetDouble(ORDER_PRICE_OPEN);
      if(!VirtualPriceMatchesRegisteredGrid(price))
         trade.OrderDelete(ticket);
   }
   for(int j = ArraySize(g_virtualPending) - 1; j >= 0; j--)
   {
      double price = g_virtualPending[j].priceLevel;
      if(!VirtualPriceMatchesRegisteredGrid(price))
         VirtualPendingRemoveAt(j);
   }
}

//+------------------------------------------------------------------+
//| Deal OUT: cập nhật P/L tích lũy + dựng lại chờ ảo.                  |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;
   if(!HistoryDealSelect(trans.deal))
      return;
   // Chỉ lệnh Mua/Bán thật — bỏ qua nạp/rút/bonus/credit (DEAL_TYPE_BALANCE, CREDIT, …)
   const long dType = HistoryDealGetInteger(trans.deal, DEAL_TYPE);
   if(dType != DEAL_TYPE_BUY && dType != DEAL_TYPE_SELL)
      return;
   if(HistoryDealGetInteger(trans.deal, DEAL_ENTRY) != DEAL_ENTRY_OUT)
      return;
   if(!IsOurMagic(HistoryDealGetInteger(trans.deal, DEAL_MAGIC)))
      return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol)
      return;

   long dealTime = (long)HistoryDealGetInteger(trans.deal, DEAL_TIME);
   long dealReason = (long)HistoryDealGetInteger(trans.deal, DEAL_REASON);
   double dealProfitSwap = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                 + HistoryDealGetDouble(trans.deal, DEAL_SWAP);
   double fullDealPnL = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                  + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
                  + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);

   if(g_compoundTotalProfitActive && CompoundDealOutIsCommonSlHit(trans.deal))
      g_compoundCommonSlHitPendingReset = true;

   if(eaAttachTime > 0 && dealTime >= (long)eaAttachTime)
   {
      if(!CompoundCarrySkipsDealOutFromCompoundCommonSl(dealReason, dealProfitSwap))
         CompoundCarryApplyFromDealOut(dealProfitSwap);
   }
   if(sessionStartTime > 0 && dealTime >= (long)sessionStartTime)
   {
      if(dealReason == DEAL_REASON_SL || dealReason == DEAL_REASON_TP)
         g_compoundSessionClosedSlTpProfitSwapUsd += dealProfitSwap;
   }
   if(eaAttachTime > 0 && dealTime >= (long)eaAttachTime)
      eaCumulativeTradingPL += fullDealPnL;

   if(g_compoundCommonSlHitPendingReset && !OurSymbolMagicHasAnyOpenPosition())
   {
      CompoundTryResetAfterCommonSlHit("broker khớp");
      MonthlyProfitPanelOnTradeRefresh();
      return;
   }

   // Đóng vị thế: bổ sung chờ ảo (không áp khi vừa chờ ảo->market — xem VirtualExecCooldown).
   if(basePrice > 0.0 && ArraySize(gridLevels) >= MaxGridLevels + 1)
      ManageGridOrders();

   MonthlyProfitPanelOnTradeRefresh();
}

//+------------------------------------------------------------------+
//| Grid: không đặt lệnh tại gốc. ±1 cách gốc theo GridFirstLevelOffsetPips; bậc kế tiếp cách D. |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Độ lệch giá từ gốc tới bậc ký hiệu signedLevel = ±1, ±2, …         |
//+------------------------------------------------------------------+
double GridOffsetFromBaseForSignedLevel(int signedLevel)
{
   int n = MathAbs(signedLevel);
   if(n <= 0) return 0.0;
   double D = GridDistancePips * pnt * 10.0;
   double firstOffset = GridFirstLevelOffsetPips * pnt * 10.0;
   if(D <= 0.0) return 0.0;
   if(firstOffset < 0.0)
      firstOffset = 0.0;
   double off = firstOffset + ((double)n - 1.0) * D;
   return (signedLevel > 0) ? off : -off;
}

//+------------------------------------------------------------------+
//| Khoảng giá từ gốc tới bậc ±X (cùng công thức bậc ±1, bậc ±2…).   |
//+------------------------------------------------------------------+
double GridRadialDistanceFromBaseForAbsLevel(const int absLevel)
{
   if(absLevel < 1)
      return 0.0;
   int n = absLevel;
   if(n > MaxGridLevels)
      n = MaxGridLevels;
   return MathAbs(GridOffsetFromBaseForSignedLevel(n));
}

//+------------------------------------------------------------------+
//| Giá mức levelIndex (0..2*MaxGridLevels-1).                         |
//| Trên gốc: index 0..Max-1 → bậc +1..+Max. Dưới gốc: +Max.. → -1..-Max. |
//+------------------------------------------------------------------+
double GetGridLevelPrice(int levelIndex)
{
   int s;
   if(levelIndex < MaxGridLevels)
      s = levelIndex + 1;
   else
      s = -(levelIndex - MaxGridLevels + 1);
   return NormalizeDouble(basePrice + GridOffsetFromBaseForSignedLevel(s), dgt);
}

//+------------------------------------------------------------------+
//| Tier signed vs base for lot/comment: +1..+N above, -1..-N below. |
//| idx = row in gridLevels[] (0 .. 2*MaxGridLevels-1).              |
//+------------------------------------------------------------------+
int GridSignedLevelNumFromIndex(int idx)
{
   if(idx < 0 || idx >= ArraySize(gridLevels)) return 0;
   if(idx < MaxGridLevels)
      return idx + 1;
   return -(idx - MaxGridLevels + 1);
}

//+------------------------------------------------------------------+
//| Bậc dương = trên gốc; bậc âm = dưới gốc. Buy/Sell theo loại lệnh. |
//+------------------------------------------------------------------+
ENUM_VGRID_LEG VirtualGridLegFromLevelSide(const bool isBuy, const int signedLevelNum)
{
   if(signedLevelNum > 0)
      return isBuy ? VGRID_LEG_BUY_ABOVE : VGRID_LEG_SELL_ABOVE;
   if(signedLevelNum < 0)
      return isBuy ? VGRID_LEG_BUY_BELOW : VGRID_LEG_SELL_BELOW;
   return VGRID_LEG_BUY_ABOVE;
}

ENUM_VGRID_LEG VirtualGridLegFromOrder(const ENUM_ORDER_TYPE orderType, const int signedLevelNum)
{
   const bool isBuy = (orderType == ORDER_TYPE_BUY_LIMIT || orderType == ORDER_TYPE_BUY_STOP);
   return VirtualGridLegFromLevelSide(isBuy, signedLevelNum);
}

double VirtualGridResolvedL1(const ENUM_VGRID_LEG leg)
{
   switch(leg)
   {
      case VGRID_LEG_BUY_ABOVE:
      case VGRID_LEG_BUY_BELOW: return VGridL1BuyA;
      case VGRID_LEG_BUY_ABOVE_E:
      case VGRID_LEG_BUY_BELOW_H: return VGridL1BuyB;
      case VGRID_LEG_SELL_ABOVE:
      case VGRID_LEG_SELL_BELOW: return VGridL1SellC;
      case VGRID_LEG_SELL_ABOVE_G:
      case VGRID_LEG_SELL_BELOW_F: return VGridL1SellD;
   }
   return VGridL1BuyA;
}

ENUM_LOT_SCALE VirtualGridResolvedScale(const ENUM_VGRID_LEG leg)
{
   switch(leg)
   {
      case VGRID_LEG_BUY_ABOVE:
      case VGRID_LEG_BUY_BELOW: return VGridScaleBuyA;
      case VGRID_LEG_BUY_ABOVE_E:
      case VGRID_LEG_BUY_BELOW_H: return VGridScaleBuyB;
      case VGRID_LEG_SELL_ABOVE:
      case VGRID_LEG_SELL_BELOW: return VGridScaleSellC;
      case VGRID_LEG_SELL_ABOVE_G:
      case VGRID_LEG_SELL_BELOW_F: return VGridScaleSellD;
   }
   return VGridScaleBuyA;
}

double VirtualGridResolvedAddRaw(const ENUM_VGRID_LEG leg)
{
   switch(leg)
   {
      case VGRID_LEG_BUY_ABOVE:
      case VGRID_LEG_BUY_BELOW: return VGridLotAddBuyA;
      case VGRID_LEG_BUY_ABOVE_E:
      case VGRID_LEG_BUY_BELOW_H: return VGridLotAddBuyB;
      case VGRID_LEG_SELL_ABOVE:
      case VGRID_LEG_SELL_BELOW: return VGridLotAddSellC;
      case VGRID_LEG_SELL_ABOVE_G:
      case VGRID_LEG_SELL_BELOW_F: return VGridLotAddSellD;
   }
   return VGridLotAddBuyA;
}

double VirtualGridResolvedMult(const ENUM_VGRID_LEG leg)
{
   switch(leg)
   {
      case VGRID_LEG_BUY_ABOVE:
      case VGRID_LEG_BUY_BELOW: return VGridLotMultBuyA;
      case VGRID_LEG_BUY_ABOVE_E:
      case VGRID_LEG_BUY_BELOW_H: return VGridLotMultBuyB;
      case VGRID_LEG_SELL_ABOVE:
      case VGRID_LEG_SELL_BELOW: return VGridLotMultSellC;
      case VGRID_LEG_SELL_ABOVE_G:
      case VGRID_LEG_SELL_BELOW_F: return VGridLotMultSellD;
   }
   return VGridLotMultBuyA;
}

double VirtualGridResolvedMaxLot(const ENUM_VGRID_LEG leg)
{
   switch(leg)
   {
      case VGRID_LEG_BUY_ABOVE:
      case VGRID_LEG_BUY_BELOW: return VGridMaxLotBuyA;
      case VGRID_LEG_BUY_ABOVE_E:
      case VGRID_LEG_BUY_BELOW_H: return VGridMaxLotBuyB;
      case VGRID_LEG_SELL_ABOVE:
      case VGRID_LEG_SELL_BELOW: return VGridMaxLotSellC;
      case VGRID_LEG_SELL_ABOVE_G:
      case VGRID_LEG_SELL_BELOW_F: return VGridMaxLotSellD;
   }
   return VGridMaxLotBuyA;
}

bool VirtualGridResolvedTpAtNextLevel(const ENUM_VGRID_LEG leg)
{
   switch(leg)
   {
      case VGRID_LEG_BUY_ABOVE:
      case VGRID_LEG_BUY_BELOW: return VGridTpNextBuyA;
      case VGRID_LEG_BUY_ABOVE_E:
      case VGRID_LEG_BUY_BELOW_H: return VGridTpNextBuyB;
      case VGRID_LEG_SELL_ABOVE:
      case VGRID_LEG_SELL_BELOW: return VGridTpNextSellC;
      case VGRID_LEG_SELL_ABOVE_G:
      case VGRID_LEG_SELL_BELOW_F: return VGridTpNextSellD;
   }
   return VGridTpNextBuyA;
}

double VirtualGridResolvedTpPips(const ENUM_VGRID_LEG leg)
{
   switch(leg)
   {
      case VGRID_LEG_BUY_ABOVE:
      case VGRID_LEG_BUY_BELOW: return VGridTpPipsBuyA;
      case VGRID_LEG_BUY_ABOVE_E:
      case VGRID_LEG_BUY_BELOW_H: return VGridTpPipsBuyB;
      case VGRID_LEG_SELL_ABOVE:
      case VGRID_LEG_SELL_BELOW: return VGridTpPipsSellC;
      case VGRID_LEG_SELL_ABOVE_G:
      case VGRID_LEG_SELL_BELOW_F: return VGridTpPipsSellD;
   }
   return VGridTpPipsBuyA;
}

double VirtualGridResolvedTradingStopTriggerPips(const ENUM_VGRID_LEG leg)
{
   switch(leg)
   {
      case VGRID_LEG_BUY_ABOVE:
      case VGRID_LEG_BUY_BELOW: return VGridTradingStopTriggerPipsBuyA;
      case VGRID_LEG_BUY_ABOVE_E:
      case VGRID_LEG_BUY_BELOW_H: return VGridTradingStopTriggerPipsBuyB;
      case VGRID_LEG_SELL_ABOVE:
      case VGRID_LEG_SELL_BELOW: return VGridTradingStopTriggerPipsSellC;
      case VGRID_LEG_SELL_ABOVE_G:
      case VGRID_LEG_SELL_BELOW_F: return VGridTradingStopTriggerPipsSellD;
   }
   return VGridTradingStopTriggerPipsBuyA;
}

double VirtualGridResolvedTradingStopLockPips(const ENUM_VGRID_LEG leg)
{
   switch(leg)
   {
      case VGRID_LEG_BUY_ABOVE:
      case VGRID_LEG_BUY_BELOW: return VGridTradingStopLockPipsBuyA;
      case VGRID_LEG_BUY_ABOVE_E:
      case VGRID_LEG_BUY_BELOW_H: return VGridTradingStopLockPipsBuyB;
      case VGRID_LEG_SELL_ABOVE:
      case VGRID_LEG_SELL_BELOW: return VGridTradingStopLockPipsSellC;
      case VGRID_LEG_SELL_ABOVE_G:
      case VGRID_LEG_SELL_BELOW_F: return VGridTradingStopLockPipsSellD;
   }
   return VGridTradingStopLockPipsBuyA;
}

double VirtualGridResolvedTradingStopStepPips(const ENUM_VGRID_LEG leg)
{
   switch(leg)
   {
      case VGRID_LEG_BUY_ABOVE:
      case VGRID_LEG_BUY_BELOW: return VGridTradingStopStepPipsBuyA;
      case VGRID_LEG_BUY_ABOVE_E:
      case VGRID_LEG_BUY_BELOW_H: return VGridTradingStopStepPipsBuyB;
      case VGRID_LEG_SELL_ABOVE:
      case VGRID_LEG_SELL_BELOW: return VGridTradingStopStepPipsSellC;
      case VGRID_LEG_SELL_ABOVE_G:
      case VGRID_LEG_SELL_BELOW_F: return VGridTradingStopStepPipsSellD;
   }
   return VGridTradingStopStepPipsBuyA;
}

bool VirtualGridLegTradingStopEnabled(const ENUM_VGRID_LEG leg)
{
   return (VirtualGridResolvedTradingStopTriggerPips(leg) > 0.0
      && VirtualGridResolvedTradingStopLockPips(leg) > 0.0
      && VirtualGridResolvedTradingStopStepPips(leg) > 0.0);
}

//+------------------------------------------------------------------+
//| Chuẩn hóa lot theo min/max/step broker và cap chân (nếu có).      |
//+------------------------------------------------------------------+
double NormalizeVirtualGridLotForLeg(const double lotIn, const ENUM_VGRID_LEG leg)
{
   double lot = lotIn;
   const double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   const double cap = VirtualGridResolvedMaxLot(leg);
   if(cap > 0.0)
      maxLot = MathMin(maxLot, cap);
   const double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathMax(minLot, MathMin(maxLot, lot));
   if(lotStep > 0.0)
      lot = MathFloor(lot / lotStep) * lotStep;
   if(lot < minLot)
      lot = minLot;
   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| Tổng float (profit+swap) lệnh mở magic+symbol trong phiên hiện tại. |
//+------------------------------------------------------------------+
double GetSessionOpenProfitSwapUsd()
{
   if(sessionStartTime <= 0)
      return 0.0;
   double sum = 0.0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(!PositionIsOurSymbolAndMagic(ticket))
         continue;
      if(!CompoundPositionPassesSessionFilter(ticket))
         continue;
      sum += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   return sum;
}

void SessionFloatLossAdjustReset()
{
   g_sessionFloatLossAutoFirstLotActive = false;
   g_sessionFloatLossCompoundTriggerActive = false;
}

bool SessionFloatLossAutoFirstLotModeActive()
{
   if(!EnableSessionFloatLossAutoFirstLot)
      return false;
   return g_sessionFloatLossAutoFirstLotActive;
}

bool SessionFloatLossCompoundTriggerModeActive()
{
   if(!EnableSessionFloatLossCompoundTriggerAdjust)
      return false;
   return g_sessionFloatLossCompoundTriggerActive;
}

bool VirtualGridLegHasOpenPositionAtLevel(const ENUM_VGRID_LEG leg, const double priceLevel)
{
   const double tolerance = GridPriceTolerance();
   for(int i = 0; i < PositionsTotal(); i++)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(!PositionIsOurSymbolAndMagic(ticket))
         continue;
      if(!CompoundPositionPassesSessionFilter(ticket))
         continue;
      ENUM_VGRID_LEG posLeg = VGRID_LEG_BUY_ABOVE;
      if(!TryParseLegFromOrderComment(PositionGetString(POSITION_COMMENT), posLeg))
         continue;
      if(posLeg != leg)
         continue;
      if(MathAbs(PositionGetDouble(POSITION_PRICE_OPEN) - priceLevel) < tolerance)
         return true;
   }
   return false;
}

void SyncVirtualPendingLotsForSessionFloatAutoFirstLot()
{
   if(GridUsesVirtualPendingMode())
   {
      for(int i = 0; i < ArraySize(g_virtualPending); i++)
      {
         const ENUM_VGRID_LEG leg = g_virtualPending[i].leg;
         if(!IsVirtualGridLegEnabled(leg))
            continue;
         if(VirtualGridLegHasOpenPositionAtLevel(leg, g_virtualPending[i].priceLevel))
            continue;
         const int absLvl = MathMax(1, MathAbs(g_virtualPending[i].levelNum));
         g_virtualPending[i].lot = GetLotForVirtualGridLeg(leg, absLvl);
      }
      return;
   }
   trade.SetExpertMagicNumber(MagicAA);
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderIsOurSymbolAndMagic(ticket))
         continue;
      const string cmt = OrderGetString(ORDER_COMMENT);
      if(!OrderCommentIsGridPending(cmt))
         continue;
      ENUM_VGRID_LEG leg;
      if(!TryParseLegFromOrderComment(cmt, leg))
         continue;
      if(!IsVirtualGridLegEnabled(leg))
         continue;
      const double priceLevel = OrderGetDouble(ORDER_PRICE_OPEN);
      if(VirtualGridLegHasOpenPositionAtLevel(leg, priceLevel))
         continue;
      int signedLevelNum = 0;
      if(!TryParseSignedLevelFromOrderComment(cmt, signedLevelNum))
         continue;
      const int absLvl = MathMax(1, MathAbs(signedLevelNum));
      const double newLot = GetLotForVirtualGridLeg(leg, absLvl);
      const double curLot = OrderGetDouble(ORDER_VOLUME_CURRENT);
      if(MathAbs(curLot - newLot) < 1e-8)
         continue;
      const ENUM_ORDER_TYPE ot = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      trade.OrderDelete(ticket);
      PlacePendingOrder(ot, leg, priceLevel, signedLevelNum);
   }
}

void SessionFloatLossAdjustPoll()
{
   if(basePrice <= 0.0 || sessionStartTime <= 0)
      return;
   if(!EnableSessionFloatLossAutoFirstLot && !EnableSessionFloatLossCompoundTriggerAdjust)
      return;

   const double thr = MathMax(0.0, SessionFloatLossAutoFirstLotThresholdUSD);
   if(thr <= 0.0)
      return;

   const bool needAutoLot = EnableSessionFloatLossAutoFirstLot && !g_sessionFloatLossAutoFirstLotActive;
   const bool needCompound = EnableSessionFloatLossCompoundTriggerAdjust && !g_sessionFloatLossCompoundTriggerActive;
   if(!needAutoLot && !needCompound)
      return;

   const double sessionFloat = GetSessionOpenProfitSwapUsd();
   if(sessionFloat > -thr + 1e-8)
      return;

   if(needAutoLot)
   {
      g_sessionFloatLossAutoFirstLotActive = true;
      const double l1 = MathMax(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), SessionFloatLossAutoFirstLotL1);
      Print("VGridABCD: Auto lot đầu BẬT — float phiên ", DoubleToString(sessionFloat, 2),
            " USD ≤ −", DoubleToString(thr, 2),
            " → L1 chờ ảo=", DoubleToString(l1, 2),
            " (lệnh market giữ lot cũ; chỉ cập nhật chờ ảo chưa khớp)");
      SyncVirtualPendingLotsForSessionFloatAutoFirstLot();
   }

   if(needCompound)
   {
      g_sessionFloatLossCompoundTriggerActive = true;
      CompoundFloatThrHudUpdate(false);
      Print("VGridABCD: Ngưỡng gồng lãi tổng điều chỉnh — float phiên ", DoubleToString(sessionFloat, 2),
            " USD ≤ −", DoubleToString(thr, 2),
            " → gốc ", DoubleToString(SessionFloatLossCompoundTriggerUSD, 2),
            " USD (+ carry ", DoubleToString(GetCompoundCarryContributionUsd(), 2), ")");
   }
}

//+------------------------------------------------------------------+
//| Lot bậc 1 theo input chân.                                        |
//+------------------------------------------------------------------+
double GetBaseLotForVirtualGridLeg(const ENUM_VGRID_LEG leg)
{
   if(SessionFloatLossAutoFirstLotModeActive())
   {
      const double l1 = MathMax(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), SessionFloatLossAutoFirstLotL1);
      return l1;
   }
   return VirtualGridResolvedL1(leg);
}

double GetLotMultForVirtualGridLeg(const ENUM_VGRID_LEG leg)
{
   return VirtualGridResolvedMult(leg);
}

double GetLotAddForVirtualGridLeg(const ENUM_VGRID_LEG leg)
{
   return MathMax(0.0, VirtualGridResolvedAddRaw(leg));
}

ENUM_LOT_SCALE GetLotScaleForVirtualGridLeg(const ENUM_VGRID_LEG leg)
{
   return VirtualGridResolvedScale(leg);
}

double GetTakeProfitPipsForVirtualGridLeg(const ENUM_VGRID_LEG leg)
{
   return VirtualGridResolvedTpPips(leg);
}

//+------------------------------------------------------------------+
//| LOT theo chân: L1; cộng/hình học theo |bậc|.                       |
//+------------------------------------------------------------------+
double GetLotForVirtualGridLeg(const ENUM_VGRID_LEG leg, const int absLevelRaw)
{
   const int absLevel = MathMax(1, MathAbs(absLevelRaw));

   const double baseLot = GetBaseLotForVirtualGridLeg(leg);
   const ENUM_LOT_SCALE scale = GetLotScaleForVirtualGridLeg(leg);
   double lot = baseLot;
   if(absLevel <= 1 || scale == LOT_FIXED)
      lot = baseLot;
   else if(scale == LOT_ARITHMETIC)
      lot = baseLot + (double)(absLevel - 1) * GetLotAddForVirtualGridLeg(leg);
   else if(scale == LOT_GEOMETRIC)
      lot = baseLot * MathPow(GetLotMultForVirtualGridLeg(leg), absLevel - 1);

   return NormalizeVirtualGridLotForLeg(lot, leg);
}

//+------------------------------------------------------------------+
//| Lot chân Buy A theo bậc.                                          |
//+------------------------------------------------------------------+
double GetLotBuyAForLevel(const int absLevel)
{
   return GetLotForVirtualGridLeg(VGRID_LEG_BUY_ABOVE, absLevel);
}

//+------------------------------------------------------------------+
//| Lot chân Sell C theo bậc.                                          |
//+------------------------------------------------------------------+
double GetLotSellCForLevel(const int absLevel)
{
   return GetLotForVirtualGridLeg(VGRID_LEG_SELL_BELOW, absLevel);
}

//+------------------------------------------------------------------+
//| Gọi khi đặt chờ ảo: map (loại lệnh, bậc có dấu) → chân.          |
//+------------------------------------------------------------------+
double GetLotForLevel(const ENUM_ORDER_TYPE orderType, const int levelNum)
{
   if(orderType != ORDER_TYPE_BUY_LIMIT && orderType != ORDER_TYPE_SELL_LIMIT && orderType != ORDER_TYPE_BUY_STOP && orderType != ORDER_TYPE_SELL_STOP)
      return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const ENUM_VGRID_LEG leg = VirtualGridLegFromOrder(orderType, levelNum);
   return GetLotForVirtualGridLeg(leg, MathAbs(levelNum));
}

//+------------------------------------------------------------------+
//| Buy: +1→+2; -1→+1 (bậc trên gốc); -k (k≥2)→-(k-1).                |
//| Sell: +1→-1 (bậc dưới gốc); +k (k≥2)→+(k-1); -k→-(k+1).           |
//+------------------------------------------------------------------+
bool GridNeighborTakeProfitPrice(ENUM_ORDER_TYPE orderType, int signedLevelNum, double &tpOut)
{
   tpOut = 0.0;
   if(basePrice <= 0.0)
      return false;
   int n = ArraySize(gridLevels);
   if(n < 1)
      return false;
   bool isBuy = (orderType == ORDER_TYPE_BUY_STOP || orderType == ORDER_TYPE_BUY_LIMIT);

   if(isBuy)
   {
      if(signedLevelNum > 0)
      {
         if(signedLevelNum >= MaxGridLevels)
            return false;
         int idx = signedLevelNum;
         if(idx < 0 || idx >= n)
            return false;
         tpOut = NormalizeDouble(gridLevels[idx], dgt);
         return true;
      }
      if(signedLevelNum < 0)
      {
         int k = -signedLevelNum;
         if(k == 1)
         {
            if(MaxGridLevels < 1 || n < 1)
               return false;
            tpOut = NormalizeDouble(gridLevels[0], dgt);   // +1 (trên gốc), không TP tại gốc
            return true;
         }
         if(k > MaxGridLevels)
            return false;
         int idx = MaxGridLevels + k - 2;
         if(idx < MaxGridLevels || idx >= n)
            return false;
         tpOut = NormalizeDouble(gridLevels[idx], dgt);
         return true;
      }
   }
   else
   {
      if(signedLevelNum > 0)
      {
         if(signedLevelNum == 1)
         {
            if(MaxGridLevels < 1 || n <= MaxGridLevels)
               return false;
            tpOut = NormalizeDouble(gridLevels[MaxGridLevels], dgt);   // -1 (dưới gốc), không TP tại gốc
            return true;
         }
         int idx = signedLevelNum - 2;
         if(idx < 0 || idx >= MaxGridLevels)
            return false;
         tpOut = NormalizeDouble(gridLevels[idx], dgt);
         return true;
      }
      if(signedLevelNum < 0)
      {
         int k = -signedLevelNum;
         if(k >= MaxGridLevels)
            return false;
         int idx = MaxGridLevels + k;
         if(idx < 0 || idx >= n)
            return false;
         tpOut = NormalizeDouble(gridLevels[idx], dgt);
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Giá TP tuyệt đối: ưu tiên mức lưới kế, không được thì pip (nếu >0).   |
//+------------------------------------------------------------------+
double ComputeVirtualTakeProfitPrice(ENUM_ORDER_TYPE orderType, ENUM_VGRID_LEG leg, double entryPrice, int signedLevelNum)
{
   if(CompoundPointAIsActive())
      return 0.0;

   const bool isBuy = (orderType == ORDER_TYPE_BUY_STOP || orderType == ORDER_TYPE_BUY_LIMIT);

   double tpGrid = 0.0;
   if(VirtualGridResolvedTpAtNextLevel(leg))
   {
      if(GridNeighborTakeProfitPrice(orderType, signedLevelNum, tpGrid))
      {
         if(isBuy && tpGrid > entryPrice)
            return tpGrid;
         if(!isBuy && tpGrid < entryPrice)
            return tpGrid;
      }
      return 0.0;
   }
   const double tpPips = GetTakeProfitPipsForVirtualGridLeg(leg);
   if(tpPips <= 0.0)
      return 0.0;
   if(isBuy)
      return NormalizeDouble(entryPrice + tpPips * pnt * 10.0, dgt);
   return NormalizeDouble(entryPrice - tpPips * pnt * 10.0, dgt);
}

void ProcessVirtualGridLegTradingStops()
{
   if(GridCommonSlBlockedByCompoundMode())
      return;

   const double pipPx = OnePipPrice();
   if(pipPx <= 0.0)
      return;

   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   const int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const int freezeLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double minDist = (double)MathMax(stopsLevel, freezeLevel) * pt;
   if(minDist < pt * 2.0)
      minDist = pt * 2.0;

   for(int i = 0; i < PositionsTotal(); i++)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(!PositionIsOurSymbolAndMagic(ticket))
         continue;

      ENUM_VGRID_LEG leg = VGRID_LEG_BUY_ABOVE;
      const string cmt = PositionGetString(POSITION_COMMENT);
      if(!TryParseLegFromOrderComment(cmt, leg))
         continue;
      if(!VirtualGridLegTradingStopEnabled(leg))
         continue;

      const ENUM_POSITION_TYPE ptp = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      const bool isBuy = (ptp == POSITION_TYPE_BUY);
      const bool isSell = (ptp == POSITION_TYPE_SELL);
      if(!isBuy && !isSell)
         continue;
      if(isBuy && !IsVirtualGridLegBuyEntryLeg(leg))
         continue;
      if(isSell && !IsVirtualGridLegSellEntryLeg(leg))
         continue;

      const double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      const double curSL = PositionGetDouble(POSITION_SL);
      const double curTP = PositionGetDouble(POSITION_TP);

      const double triggerPips = VirtualGridResolvedTradingStopTriggerPips(leg);
      const double lockPips = VirtualGridResolvedTradingStopLockPips(leg);
      const double stepPips = VirtualGridResolvedTradingStopStepPips(leg);
      if(triggerPips <= 0.0 || lockPips <= 0.0 || stepPips <= 0.0)
         continue;

      double profitPips = 0.0;
      if(isBuy)
         profitPips = (bid - openPrice) / pipPx;
      else
         profitPips = (openPrice - ask) / pipPx;
      if(profitPips + 1e-8 < triggerPips)
         continue;

      const double extraPips = MathMax(0.0, profitPips - triggerPips);
      const int steps = (int)MathFloor((extraPips + 1e-8) / stepPips);

      double newSL = 0.0;
      if(isBuy)
      {
         newSL = openPrice + lockPips * pipPx + (double)steps * stepPips * pipPx;
         newSL = NormalizeDouble(newSL, dgt);
         if(newSL <= openPrice + pt)
            continue;
         if(newSL >= bid - minDist)
            newSL = NormalizeDouble(bid - minDist, dgt);
         if(newSL <= openPrice + pt)
            continue;
         if(curSL > 0.0 && newSL <= curSL + pt)
            continue;
      }
      else
      {
         newSL = openPrice - lockPips * pipPx - (double)steps * stepPips * pipPx;
         newSL = NormalizeDouble(newSL, dgt);
         if(newSL >= openPrice - pt)
            continue;
         if(newSL <= ask + minDist)
            newSL = NormalizeDouble(ask + minDist, dgt);
         if(newSL >= openPrice - pt)
            continue;
         if(curSL > 0.0 && newSL >= curSL - pt)
            continue;
      }

      ModifyPositionSLTP(ticket, newSL, curTP);
   }
}

//+------------------------------------------------------------------+
//| Nạp gridLevels. gridStep = D (thước dung sai / khớp mức).         |
//+------------------------------------------------------------------+
void InitializeGridLevels()
{
   CompoundPointAClearSession();
   VirtualPendingClear();
   g_compoundSessionClosedSlTpProfitSwapUsd = 0.0;
   g_compoundCommonSlCarrySuppress = false;
   // Current session = 0 and start counting from here (called when EA attached or EA auto reset)
   sessionStartTime = TimeCurrent();
   sessionStartBalance = GetTradingEquityViewUSD();
   SessionFloatLossAdjustReset();
   g_carryTotalUsdAtGridSessionStart = g_balanceCompoundCarryUsd;
   double tevSess = GetTradingEquityViewUSD();
   sessionPeakTradingEquityView = tevSess;
   sessionMinTradingEquityView = tevSess;
   // attachBalance / initialCapitalBaselineUSD NOT updated here — mốc % tin chỉ lúc OnInit
   double D = GridDistancePips * pnt * 10.0;
   gridStep = D;
   int totalLevels = MaxGridLevels * 2;

   ArrayResize(gridLevels, totalLevels);

   for(int i = 0; i < totalLevels; i++)
      gridLevels[i] = GetGridLevelPrice(i);
   Print("Initialized ", totalLevels, " levels: ±1 at ", DoubleToString(GridFirstLevelOffsetPips, 1), " pip from base; step ", GridDistancePips, " pips between levels");

   EmaDirectionSnapshotLockAtSessionStart();
   EmaDirectionSnapshotHighLowAtSessionStart();
   CompoundFloatThrHudUpdate(true);
}

//+------------------------------------------------------------------+
//| Manage grid: bậc ±1 gần gốc nhất; xa dần ±2,±3… Giá bậc: GetGridLevelPrice. |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Per level: max 1 order cho từng chân (leg). Remove duplicate virtual pendings. |
//+------------------------------------------------------------------+
void RemoveDuplicateOrdersAtLevel()
{
   double tolerance = gridStep * 0.5;
   if(gridStep <= 0) tolerance = pnt * 10.0 * GridDistancePips * 0.5;
   int nLevels = ArraySize(gridLevels);
   long magics[] = {MagicAA};
   bool enabled[] = {true};
   ENUM_VGRID_LEG legs[] = {
      VGRID_LEG_BUY_ABOVE, VGRID_LEG_BUY_BELOW,
      VGRID_LEG_BUY_ABOVE_E, VGRID_LEG_BUY_BELOW_H,
      VGRID_LEG_SELL_ABOVE, VGRID_LEG_SELL_BELOW,
      VGRID_LEG_SELL_ABOVE_G, VGRID_LEG_SELL_BELOW_F
   };
   for(int L = 0; L < nLevels; L++)
   {
      double priceLevel = gridLevels[L];
      int lvlNum = GridSignedLevelNumFromIndex(L);
      for(int m = 0; m < 1; m++)
      {
         if(!enabled[m]) continue;
         long whichMagic = magics[m];
         for(int lg = 0; lg < ArraySize(legs); lg++)
         {
            const ENUM_VGRID_LEG leg = legs[lg];
            if(!VirtualGridLegMatchesLevelSide(leg, lvlNum))
               continue;
            int positionCount = 0;
            for(int i = 0; i < PositionsTotal(); i++)
            {
               ulong ticket = PositionGetTicket(i);
               if(ticket <= 0) continue;
               if(PositionGetInteger(POSITION_MAGIC) != whichMagic || PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
               if(StringFind(PositionGetString(POSITION_COMMENT), "|" + VirtualGridLegCode(leg) + "|") < 0) continue;
               if(MathAbs(PositionGetDouble(POSITION_PRICE_OPEN) - priceLevel) < tolerance)
                  positionCount++;
            }
            int idxList[];
            ArrayResize(idxList, 0);
            if(GridUsesVirtualPendingMode())
            {
               for(int i = 0; i < ArraySize(g_virtualPending); i++)
               {
                  if(g_virtualPending[i].magic != whichMagic) continue;
                  if(g_virtualPending[i].leg != leg) continue;
                  if(MathAbs(g_virtualPending[i].priceLevel - priceLevel) >= tolerance) continue;
                  int n = ArraySize(idxList);
                  ArrayResize(idxList, n + 1);
                  idxList[n] = i;
               }
               int keep = (positionCount >= 1) ? 0 : 1;
               if(ArraySize(idxList) <= keep) continue;
               for(int a = keep; a < ArraySize(idxList) - 1; a++)
                  for(int b = a + 1; b < ArraySize(idxList); b++)
                     if(idxList[a] < idxList[b]) { int t = idxList[a]; idxList[a] = idxList[b]; idxList[b] = t; }
               for(int k = keep; k < ArraySize(idxList); k++)
                  VirtualPendingRemoveAt(idxList[k]);
            }
            else
            {
               ulong ticketList[];
               ArrayResize(ticketList, 0);
               const string legTag = "|" + VirtualGridLegCode(leg) + "|";
               for(int i = 0; i < OrdersTotal(); i++)
               {
                  const ulong ticket = OrderGetTicket(i);
                  if(ticket == 0 || !OrderIsOurSymbolAndMagic(ticket)) continue;
                  const string cmt = OrderGetString(ORDER_COMMENT);
                  if(!OrderCommentIsGridPending(cmt)) continue;
                  if(StringFind(cmt, legTag) < 0) continue;
                  if(MathAbs(OrderGetDouble(ORDER_PRICE_OPEN) - priceLevel) >= tolerance) continue;
                  int n = ArraySize(ticketList);
                  ArrayResize(ticketList, n + 1);
                  ticketList[n] = ticket;
               }
               int keep = (positionCount >= 1) ? 0 : 1;
               if(ArraySize(ticketList) <= keep) continue;
               trade.SetExpertMagicNumber(MagicAA);
               for(int k = keep; k < ArraySize(ticketList); k++)
                  trade.OrderDelete(ticketList[k]);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Mỗi bậc lưới: chờ ảo Buy A/B, Sell C/D (cả + và −).              |
//+------------------------------------------------------------------+
void ManageGridOrders()
{
   if(basePrice <= 0.0)
      return;
   if(CompoundBlocksNewPendingOrders())
      return;

   EmaDirectionPollLockIfNeeded();
   if(EmaDirectionUsesCloseStickyMode() && g_emaDirectionLock == 0)
      return;

   GridPendingEntryModeSync();
   SessionFloatLossAdjustPoll();

   CancelStopOrdersOutsideBaseZone();
   EmaDirectionPurgeBlockedSidePendings();

   if(ArraySize(gridLevels) < MaxGridLevels + 1)
      return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   int n = ArraySize(gridLevels);
   for(int L = 0; L < n; L++)
   {
      double pl = gridLevels[L];
      int lvlNum = GridSignedLevelNumFromIndex(L);
      if(lvlNum == 0)
         continue;
      ENUM_ORDER_TYPE wantBuy, wantSell;
      GetVirtualPairForLevel(pl, bid, ask, wantBuy, wantSell);
      RemoveStaleVirtualTypesAtLevel(pl, wantBuy, wantSell, MagicAA);
      if(lvlNum > 0)
      {
         EnsureOrderAtLevel(VGRID_LEG_BUY_ABOVE, wantBuy, pl, lvlNum);
         EnsureOrderAtLevel(VGRID_LEG_BUY_ABOVE_E, wantBuy, pl, lvlNum);
         EnsureOrderAtLevel(VGRID_LEG_SELL_ABOVE, wantSell, pl, lvlNum);
         EnsureOrderAtLevel(VGRID_LEG_SELL_ABOVE_G, wantSell, pl, lvlNum);
      }
      else
      {
         EnsureOrderAtLevel(VGRID_LEG_BUY_BELOW, wantBuy, pl, lvlNum);
         EnsureOrderAtLevel(VGRID_LEG_BUY_BELOW_H, wantBuy, pl, lvlNum);
         EnsureOrderAtLevel(VGRID_LEG_SELL_BELOW, wantSell, pl, lvlNum);
         EnsureOrderAtLevel(VGRID_LEG_SELL_BELOW_F, wantSell, pl, lvlNum);
      }
   }
   RemoveDuplicateOrdersAtLevel();

}

//+------------------------------------------------------------------+
//| Ensure order at level - add only when missing (no pending and no position of same type at level). |
//+------------------------------------------------------------------+
void EnsureOrderAtLevel(ENUM_VGRID_LEG leg, ENUM_ORDER_TYPE orderType, double priceLevel, int levelNum)
{
   if(!IsVirtualGridLegEnabled(leg))
      return;
   if(!EmaDirectionAllowsLeg(leg))
      return;
   ulong  ticket       = 0;
   double existingPrice = 0.0;
   if(GetPendingOrderAtLevel(orderType, leg, priceLevel, ticket, existingPrice, MagicAA))
   {
      double desiredPrice = NormalizeDouble(priceLevel, dgt);
      if(MathAbs(existingPrice - desiredPrice) > (pnt / 2.0))
         AdjustVirtualPendingToLevel(MagicAA, orderType, leg, existingPrice, priceLevel, levelNum);
      return;
   }
   if(VirtualReplenishBlockedAfterExecution(priceLevel, orderType, leg, MagicAA))
      return;
   if(!CanPlaceOrderAtLevel(orderType, leg, priceLevel, MagicAA))
      return;
   PlacePendingOrder(orderType, leg, priceLevel, levelNum);
}

//+------------------------------------------------------------------+
//| Virtual pending at level: same type + magic (no broker pendings) |
//+------------------------------------------------------------------+
bool GetPendingOrderAtLevel(ENUM_ORDER_TYPE orderType,
                            ENUM_VGRID_LEG leg,
                            double priceLevel,
                            ulong &ticket,
                            double &orderPrice,
                            long whichMagic)
{
   if(!IsOurMagic(whichMagic)) return false;
   ticket = 0;
   orderPrice = 0.0;
   if(GridUsesBrokerPendingMode())
      return BrokerPendingFindAtLevel(orderType, leg, priceLevel, ticket, orderPrice, whichMagic);
   double tolerance = GridPriceTolerance();
   for(int i = 0; i < ArraySize(g_virtualPending); i++)
   {
      if(g_virtualPending[i].magic != whichMagic) continue;
      if(g_virtualPending[i].orderType != orderType) continue;
      if(g_virtualPending[i].leg != leg) continue;
      if(MathAbs(g_virtualPending[i].priceLevel - priceLevel) < tolerance)
      {
         orderPrice = g_virtualPending[i].priceLevel;
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Adjust virtual pending price to a new grid                         |
//+------------------------------------------------------------------+
void AdjustVirtualPendingToLevel(long magic, ENUM_ORDER_TYPE orderType, ENUM_VGRID_LEG leg, double oldPrice, double priceLevel, int signedLevelNum)
{
   if(!IsOurMagic(magic)) return;
   double price = NormalizeDouble(priceLevel, dgt);
   double tp = ComputeVirtualTakeProfitPrice(orderType, leg, price, signedLevelNum);
   const int absLvl = MathMax(1, MathAbs(signedLevelNum));
   const double lot = GetLotForVirtualGridLeg(leg, absLvl);
   if(GridUsesBrokerPendingMode())
   {
      ulong ticket = 0;
      double existingPrice = 0.0;
      if(!BrokerPendingFindAtLevel(orderType, leg, oldPrice, ticket, existingPrice, magic))
         return;
      trade.SetExpertMagicNumber(magic);
      if(trade.OrderModify(ticket, price, 0.0, tp, ORDER_TIME_GTC, 0))
         Print("VGridABCD adjust broker: ", EnumToString(orderType), " magic ", magic, " at ", price,
               " lot ", DoubleToString(lot, 2), " TP ", tp);
      else
         Print("VGridABCD adjust broker fail ticket ", ticket, " err ", GetLastError());
      return;
   }
   int idx = VirtualPendingFindIndex(magic, orderType, leg, oldPrice);
   if(idx < 0) return;
   g_virtualPending[idx].priceLevel = price;
   g_virtualPending[idx].tpPrice = tp;
   g_virtualPending[idx].lot = lot;
   Print("VGridABCD adjust: ", EnumToString(orderType), " magic ", magic, " at ", price,
         " lot ", DoubleToString(g_virtualPending[idx].lot, 2), " TP ", tp);
}

//+------------------------------------------------------------------+
//| Max 1 order per side per level per magic (virtual pending or open position). |
//+------------------------------------------------------------------+
bool CanPlaceOrderAtLevel(ENUM_ORDER_TYPE orderType, ENUM_VGRID_LEG leg, double priceLevel, long whichMagic)
{
   if(!IsOurMagic(whichMagic)) return false;
   double tolerance = GridPriceTolerance();
   int countSameLevel = 0;

   if(GridUsesVirtualPendingMode())
   {
      for(int i = 0; i < ArraySize(g_virtualPending); i++)
      {
         if(g_virtualPending[i].magic != whichMagic) continue;
         if(MathAbs(g_virtualPending[i].priceLevel - priceLevel) >= tolerance) continue;
         if(g_virtualPending[i].leg == leg)
            countSameLevel++;
      }
   }
   else
   {
      const string legTag = "|" + VirtualGridLegCode(leg) + "|";
      for(int i = 0; i < OrdersTotal(); i++)
      {
         const ulong ticket = OrderGetTicket(i);
         if(ticket == 0 || !OrderIsOurSymbolAndMagic(ticket)) continue;
         const string cmt = OrderGetString(ORDER_COMMENT);
         if(!OrderCommentIsGridPending(cmt)) continue;
         if(StringFind(cmt, legTag) < 0) continue;
         if(MathAbs(OrderGetDouble(ORDER_PRICE_OPEN) - priceLevel) >= tolerance) continue;
         countSameLevel++;
      }
   }
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != whichMagic || PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      double posPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      if(MathAbs(posPrice - priceLevel) >= tolerance) continue;
      if(StringFind(PositionGetString(POSITION_COMMENT), "|" + VirtualGridLegCode(leg) + "|") >= 0)
         countSameLevel++;
   }
   return (countSameLevel < 1);   // Max 1 order (pending or position) per type per level
}

//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Place pending order with TP; lot by grid level. SL set by trailing only |
//+------------------------------------------------------------------+
void PlacePendingOrder(ENUM_ORDER_TYPE orderType, ENUM_VGRID_LEG leg, double priceLevel, int levelNum)
{
   if(!EmaDirectionAllowsLeg(leg))
      return;
   double price = NormalizeDouble(priceLevel, dgt);
   double lot   = GetLotForVirtualGridLeg(leg, MathAbs(levelNum));
   double tp = ComputeVirtualTakeProfitPrice(orderType, leg, price, levelNum);
   if(GridUsesVirtualPendingMode())
   {
      VirtualPendingAdd(MagicAA, orderType, leg, price, levelNum, tp, lot);
      Print("VGridABCD: ", EnumToString(orderType), " at ", price, " lot ", lot, " (level ", levelNum > 0 ? "+" : "", levelNum, ")");
      return;
   }
   string cmt = BuildOrderCommentWithLevel(leg, levelNum);
   trade.SetExpertMagicNumber(MagicAA);
   bool ok = false;
   const double sl = 0.0;
   switch(orderType)
   {
      case ORDER_TYPE_BUY_STOP:
         ok = trade.BuyStop(lot, price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, cmt);
         break;
      case ORDER_TYPE_BUY_LIMIT:
         ok = trade.BuyLimit(lot, price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, cmt);
         break;
      case ORDER_TYPE_SELL_STOP:
         ok = trade.SellStop(lot, price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, cmt);
         break;
      case ORDER_TYPE_SELL_LIMIT:
         ok = trade.SellLimit(lot, price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, cmt);
         break;
      default:
         return;
   }
   if(ok)
      Print("VGridABCD broker: ", EnumToString(orderType), " at ", price, " lot ", lot, " (level ", levelNum > 0 ? "+" : "", levelNum, ")");
   else
      Print("VGridABCD broker pending fail: ", EnumToString(orderType), " at ", price, " err ", GetLastError());
}

//+---------------------------------------------------------------
