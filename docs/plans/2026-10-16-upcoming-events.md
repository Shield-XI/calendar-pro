# 近期日程版块实现记录

**日期：** 2026-10-16
**设计文档：** [2026-10-16-upcoming-events-design.md](2026-10-16-upcoming-events-design.md)

## 改动清单

### 新增

- `CalendarPro/Views/Popover/UpcomingEventsSection.swift`：
  `UpcomingSnapshot` 纯函数（按天分组升序 + 天头文案）与
  `UpcomingEventsSection` 可折叠分节视图（标题行 + 计数、内部滚动内容区、
  滚动到底自动加载、条目复用 `EventCardView`）。
- `CalendarProTests/Popover/UpcomingSnapshotTests.swift`：跨天分组升序、
  同一天全天在前/按时间排序、空输入、无开始日期条目忽略，以及
  `EventService.reminder(isDueWithin:)` 的窗口过滤与每日/每周递归近似展开用例。
- `docs/plans/2026-10-16-upcoming-events-design.md`、本实现记录。

### 修改

- `CalendarPro/Settings/MenuBarPreferences.swift`：新增 5 个字段
  （`showUpcomingSection` / `upcomingDayLimit` / `upcomingIncludeReminders` /
  `upcomingEnabledCalendarIDs` / `upcomingEnabledReminderCalendarIDs`），
  CodingKeys、解码缺省回退与编码同步补齐，默认构造与 preview 同步。
- `CalendarPro/Settings/SettingsStore.swift`：新增
  `setShowUpcomingSection` / `setUpcomingDayLimit` /
  `setUpcomingIncludeReminders` / `setUpcomingCalendarEnabled` /
  `setUpcomingReminderCalendarEnabled`，日历勾选沿用"空数组=全选"归一逻辑。
- `CalendarPro/Features/Events/EventService.swift`：新增
  `fetchUpcomingCalendarItems` 与私有 `fetchUpcomingReminders`；
  静态 `reminder(_:isDueWithin:windowEnd:calendar:)` 复用单日递归判定
  `isOccurrence` 做按天近似展开。
- `CalendarPro/Views/Popover/CalendarPopoverView.swift`：新增 5 个入参与
  `onLoadMoreUpcoming` 回调，在 `eventsSection` 之后插入新分节；
  现有日程分节行为不变。
- `CalendarPro/Views/RootPopoverView.swift`：新增
  `upcomingItems` / `isLoadingUpcoming` / `upcomingWindowDays` /
  `upcomingRequestID` 状态与 `loadUpcoming` / `handleLoadMoreUpcoming` /
  `clearLoadedUpcoming`；onAppear、授权变化、设置变化、store 变更、
  选中日期变化、跨天均触发重取；提醒完成切换后同步刷新。
- `CalendarPro/Views/Settings/EventsSettingsView.swift`：新增「未来日程」
  分组（开关、时间上限 Picker、包含提醒 Toggle、日历勾选组、
  提醒列表勾选组）及对应 Binding。
- `CalendarPro/Resources/Localizable.xcstrings`：新增 13 个 key 的
  en 与 zh-Hans 文案（`Upcoming Events`、`Show Upcoming Section` 等）。
- `CalendarProTests/Settings/SettingsStoreTests.swift`：新增未来日程设置
  持久化往返与"重新勾选恢复空数组=全选"两个用例。
- `CalendarProTests/Settings/MenuBarPreferencesTests.swift`：新增默认值与
  旧数据解码回退两个用例。
- `CalendarProTests/MenuBar/ClockRenderServiceTests.swift`：4 处
  `MenuBarPreferences` 成员逐一构造补齐新字段（成员逐一初始化器变更的连带修复）。
- `CalendarPro.xcodeproj`：`ruby tools/generate_xcodeproj.rb` 重建，纳入新文件。

## 验证

```bash
ruby tools/generate_xcodeproj.rb
xcodebuild build -project CalendarPro.xcodeproj -scheme CalendarPro \
  -destination 'platform=macOS' -derivedDataPath .dd
# BUILD SUCCEEDED

xcodebuild test -project CalendarPro.xcodeproj -scheme CalendarPro \
  -destination 'platform=macOS' -derivedDataPath .dd
# CalendarProTests.xctest: Executed 385 tests, with 0 failures (0 unexpected)
# CalendarProUITests.xctest: 1 test passed
# TEST SUCCEEDED
```

备注：首次完整运行时 UI 用例 `testPopoverRendersMonthNavigation` 在应用启动
`runningForeground` 等待处超时（尚未触及弹层断言），单独重跑与随后完整重跑均
通过，判定为启动激活时序抖动，与本功能无关。

## 验收修复记录（2026-10-16）

验收审查确认两项问题，本节记录修复：

- pbxproj 版本号回退：重建工程时 `tools/generate_xcodeproj.rb` 写死
  `MARKETING_VERSION = 1.0.0` / `CURRENT_PROJECT_VERSION = 1`，覆盖了上游
  直接维护的 0.2.6/9。修复为直接编辑 `project.pbxproj` 四处恢复
  0.2.6/9（未再跑 regen，未改动上游脚本；注意后续再重建工程需先修正脚本
  版本号来源，此处不代改）。
- 多天事件产生过去天组：EventKit 窗口谓词为重叠语义，原过滤只查
  `endDate > now`，开始早于今天未结束的多天事件会进入列表并按其 startDate
  分出过去天组。修复为按设计语义补 `startDate >= 窗口起点`，逻辑抽为静态
  纯函数 `EventService.event(_:isWithinUpcomingWindow:now:enabledCalendarIDs:)`
  （未挂载日历的事件仅在“全部日历”语义下纳入，避免夹具强解包），
  并补 3 条单测覆盖“昨天开始今天未结束”“昨天开始明天结束”排除与
  “今天开始进行中”保留。
- 顺带（低severity）：`UpcomingEventsSection` 的快照改为 body 内单次求值，
  标题计数与展开内容共用同一份分组结果，避免重复排序分组。

验证：`xcodebuild build` 热身后单测
`Executed 388 tests, with 0 failures (0 unexpected)`（含 3 条新边界用例）。
UI 用例因本机 Runner 冷启动被杀（testmanagerd 提前终止，属既有环境问题，
与本次改动无关，UI 测试代码未变动）未能运行，如实记录。

## 滚动自动加载改造（2026-10-16）

分页触发从「点击底部加载更多按钮」改为「滚动到底自动加载」，窗口渐进扩展
逻辑（首窗 30 天，每次 +30 天至上限 30/90/180/全部）不变：

- `UpcomingEventsSection`：列表容器由 `VStack` 改为 `LazyVStack`（普通
  VStack 一次性物化全部子视图，末尾哨兵的 onAppear 会在展开瞬间立即触发）；
  移除「加载更多」按钮，改为末尾 1pt `Color.clear` 哨兵挂 `onAppear` 触发
  扩窗回调。加载中哨兵被进度指示替换、达上限时 `hasMore` 为 false，两种
  情况哨兵都不在视图层级内防重复触发；一次加载结束后哨兵重新插入并再次
  触发 onAppear，内容不足一屏时连续加载至占满视口或达上限。
- `RootPopoverView.handleLoadMoreUpcoming`：新增 `isLoadingUpcoming`
  在-flight 守卫（既有 `upcomingRequestID` 竞态守卫不变）。
- `Localizable.xcstrings`：删除不再被引用的 `Load More` key（en 与 zh-Hans）。

验证：`xcodebuild build` 热身后
`xcodebuild test ... -skip-testing:CalendarProUITests`，单测
`Executed 388 tests, with 0 failures (0 unexpected)`，TEST SUCCEEDED；
UI 测试因本机 Runner 环境问题按基线跳过（与本次改动无关，UI 测试代码未
变动），触发链路以人工滚动验证为准。

## 近期日程五项改造（2026-10-16 第二批）

在滚动自动加载（f445374）基础上完成五项变更，逐项独立提交：

### 1. 更名「未来日程」→「近期日程」（commit 4d34c20）

- `Localizable.xcstrings`：版块相关 10 个含 Upcoming 的用户可见 key 全部
  更名（`Upcoming Events`→`Recent Events` 等），en/zh-Hans 取值同步，
  「未来日程」措辞统一改为「近期日程」；菜单栏「即将到来」指示器
  （`UpcomingEventMonitor` 的 `Upcoming` key）属独立功能不更名。
- 代码标识符（`UpcomingEventsSection`、`upcomingDayLimit` 等）与 JSON
  存储字段名不动，避免破坏已存用户设置解码。

### 2. 带时间提醒默认包含（commit 81a4ab0）

- `upcomingIncludeReminders` 默认值 false→true（默认构造、preview、解码
  回退三处）。解码兼容：已存 JSON 显式 false 经 `decodeIfPresent` 保持
  false，仅缺失 key 的历史数据与新用户走 true。
- 勾选路径核验（读码结论，无 bug）：`fetchUpcomingCalendarItems` 的
  includeReminders 分支 → `fetchUpcomingReminders`（未完成过滤、
  `predicateForIncompleteReminders` 起始 nil 兜递归基准、本地窗口过滤、
  按 `calendarItemIdentifier` 去重）→ 设置页开关经
  `setUpcomingIncludeReminders` → `loadUpcoming` 生效，提醒列表勾选组
  仅在开关开启时显示。

### 3. 设置拆页（commit f174d60）

- 新增 `UpcomingEventsSettingsView.swift` 原样迁移近期日程设置组；
  `EventsSettingsView` 移除该组（保留菜单栏指示器设置，属菜单栏功能）；
  `SettingsSidebarItem` 新增 upcoming 项（日程之后，clock 图标）。
- 新增 `Configure Recent Events` / `Recent Events Detail Description`
  两个 key；`ruby tools/generate_xcodeproj.rb` 重建工程。
- regen 副作用核对：脚本写死的 MARKETING_VERSION/CURRENT_PROJECT_VERSION
  覆盖为 1.0.0/1，已直接改回 0.2.6/9；Package.resolved 本次为被删除
  （非上批的 Sparkle 升版），已按原样恢复，Sparkle 保持 2.9.1 未漂移；
  scheme 差异仅为 regen 目标 UUID 轮换，与既往 regen 提交一致。

### 4. 默认展开可配置（commit 035aa41）

- 新增 `upcomingDefaultExpanded`（默认 true），解码回退/编码/CodingKeys
  同步；属性带默认值，既有成员逐一构造调用点零改动。
- `UpcomingEventsSection` 显式 init 以 `State(initialValue:)` 取设置值，
  弹层重开按设置取初态，会话内手动折叠不持久化；「近期日程」设置页
  新增「默认展开版块」开关。

### 5. 双向窗口 + 打开刷新（commit 35f7bd2）

- 窗口模型 [今天, 今天+N] → [pastStart, futureEnd]：初始 pastStart=
  今天零点；`RootPopoverView` 以 `upcomingPastDays/upcomingFutureDays`
  两个 `@State` 记端点，弹层重开保留已扩展端点、只重取数据。
- `EventService.fetchUpcomingCalendarItems` 入参改 pastStart/futureEnd；
  静态过滤 `event(isWithinUpcomingWindow:)` 去掉 `endDate > now` 守卫
  （改 `endDate > windowStart` 挡异常时长），窗口内已结束事件纳入以
  支持回看过去；开始早于过去端点的多天事件仍整体排除。该调整超出委派
  书「不改函数本身」的字面要求：若保留 `endDate > now`，已结束的过去
  事件永远被过滤，「上滚查看过去日程」不成立（初始 pastStart=今天零点
  也将失去意义），故做最小语义适配并在函数头注明。
- 顶部对称 1pt 哨兵向过去扩窗（每次 -30 天，无天数硬上限），底部哨兵
  向未来扩窗与设置上限不变；两端各自 isLoading/达界防重：过去端以
  「扩窗带不回条目即视为历史起点」置 `isUpcomingPastExhausted`（数据源/
  设置变化与跨天复位），未来端沿用 dayLimit hasMore；加载中哨兵被进度
  行替换 + in-flight 忽略触发，全量重查天然串行化，请求 ID 竞态守卫不变。
- `UpcomingSnapshot` 过去天同样分组，新增「昨天」天头（`Recent Yesterday`）。
- 打开刷新核验（读码结论）：`PopoverController` 一次性创建并复用
  contentViewController，弹层每次 show 时内容视图重新挂载触发
  `RootPopoverView.onAppear → loadUpcoming()` 重取，属既有链路未改；
  已扩展端点因 `@State` 存活而保留。属静态核验，未做真机弹层时序验证。

### 新增测试

- `MenuBarPreferencesTests`：显式 false 解码保留 1 条；默认值/旧数据
  回退断言补 `upcomingIncludeReminders=true`、`upcomingDefaultExpanded`。
- `SettingsStoreTests`：持久化往返补包含提醒翻转与默认展开字段。
- `UpcomingSnapshotTests`：过去天组与未来天组升序共存、昨天天头文案、
  多天事件在开始日所在组单次展示 3 条；窗口过滤新增「过去端点扩展后
  已结束事件纳入」，原 3 条改签名后断言不变。

## 近期日程五项改造验证

```bash
xcodebuild build -project CalendarPro.xcodeproj -scheme CalendarPro \
  -destination 'platform=macOS' -derivedDataPath .dd
# BUILD SUCCEEDED（每批次提交前均单独通过）

xcodebuild test -project CalendarPro.xcodeproj -scheme CalendarPro \
  -destination 'platform=macOS' -derivedDataPath .dd \
  -skip-testing:CalendarProUITests
# Executed 393 tests, with 0 failures (0 unexpected)（基线 388 + 新增 5）
```

UI 测试因本机 Runner 环境问题按基线跳过（与本次改动无关，UI 测试代码
未变动）；弹层滚动加载链路以人工验证为准。

## 未确定项 / 后续可迭代

- 扩窗后不做已加载数据的增量合并，每次全量重查（窗口内数据量小，可接受）。
- 递归提醒按天近似展开（见设计文档限制），如需精确支持例外日期需引入
  EventKit 逐展开查询或本地完整递归求解。
