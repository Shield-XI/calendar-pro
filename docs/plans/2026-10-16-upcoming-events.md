# 未来日程版块实现记录

**日期：** 2026-10-16
**设计文档：** [2026-10-16-upcoming-events-design.md](2026-10-16-upcoming-events-design.md)

## 改动清单

### 新增

- `CalendarPro/Views/Popover/UpcomingEventsSection.swift`：
  `UpcomingSnapshot` 纯函数（按天分组升序 + 天头文案）与
  `UpcomingEventsSection` 可折叠分节视图（标题行 + 计数、内部滚动内容区、
  加载更多按钮、条目复用 `EventCardView`）。
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

## 未确定项 / 后续可迭代

- 「加载更多」扩窗后不做已加载数据的增量合并，每次全量重查（窗口内数据量小，可接受）。
- 递归提醒按天近似展开（见设计文档限制），如需精确支持例外日期需引入
  EventKit 逐展开查询或本地完整递归求解。
