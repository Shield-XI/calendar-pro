# 未来日程版块设计

**日期：** 2026-10-16
**状态：** 已实施；单元测试与 UI 测试通过（385 + 1）
**实现记录：** [2026-10-16-upcoming-events.md](2026-10-16-upcoming-events.md)

## 目标

在菜单栏弹层的日程分节之后新增一个可折叠的「未来日程」版块，展示从当前时间起、
窗口范围内的所有日历日程（可选包含带到期时间的未完成提醒），让用户不必翻日历就
能看到接下来要发生的事。

## 信息结构

```text
月份标题
月历网格
统一日期摘要
信息条（天气 / 宜忌）
番茄钟（可选）
日程分节（现有，行为不变）
未来日程分节（新增，可折叠）
分隔线
底部操作
```

## 交互设计

- 分节默认收起，标题行只显示「未来日程」与当前窗口内的条目总数（加载中显示"加载中"）。
- 点击标题展开，内容区内部滚动，`maxHeight` 约 200 pt，不影响弹层整体紧凑布局。
- 展开后按「天」分组升序渲染：天头显示"今天 / 明天 / M月d日"（本地化模板），
  条目行复用 `EventCardView` 的卡片视觉语言，事件点击进详情、提醒点击进详情、
  提醒勾选切换完成状态。
- 底部「加载更多」按钮：初始加载窗口 30 天，每点击一次扩 30 天，直到设置的
  时间上限（30/90/180 天）；上限为 0 表示不限制，按钮常驻。
- 折叠状态只记在视图 `@State` 内：弹层每次打开回到默认收起，实现最简单，
  也避免为一次性状态引入持久化字段。

## 数据层

- `EventService.fetchUpcomingCalendarItems(now:windowEnd:enabledCalendarIDs:
  includeReminders:enabledReminderCalendarIDs:)`：
  - 事件用 `predicateForEvents(withStart: 当天零点, end: windowEnd)` 查询，
    再按 `endDate > now` 过滤，保证当天进行中事件与全天事件保留；
    开始早于今天的多天事件不纳入（避免在"未来"列表出现过去的天组）。
  - 提醒只取未完成项：复用 `fetchReminders` 的处理思路，用
    `predicateForIncompleteReminders(withDueDateStarting: nil, ending: windowEnd)`
    兜住基准到期日早于窗口的递归提醒，再在本地按窗口过滤并按
    `calendarItemIdentifier` 去重。
- 窗口起点对提醒取 `startOfDay(now)`：当天早些时候已过期但未完成的提醒保留在
  "今天"分组，与日程分节对当天的展示语义一致。

## 纯函数布局

`UpcomingSnapshot.make(items:now:calendar:)` 输入条目数组，输出按天升序的
`[UpcomingDayGroup]`（天头 + 条目）与总数，供视图直接渲染；同一天内全天条目
在前、其余按开始时间升序。与 `EventTimelineSnapshot` 的纯函数模式一致，
测试注入固定时区的 `Calendar` 即可覆盖。

## 设置项

`MenuBarPreferences` 新增（解码均带缺省回退，旧数据无损升级）：

| 字段 | 默认值 | 说明 |
| --- | --- | --- |
| `showUpcomingSection` | `true` | 是否显示未来日程分节 |
| `upcomingDayLimit` | `90` | 时间上限（天），0 表示不限制 |
| `upcomingIncludeReminders` | `false` | 是否纳入有到期时间的未完成提醒 |
| `upcomingEnabledCalendarIDs` | `[]` | 参与聚合的日历，空数组表示全选 |
| `upcomingEnabledReminderCalendarIDs` | `[]` | 参与聚合的提醒列表，空数组表示全选 |

设置页「未来日程」分组独立于「在弹层显示日程」总开关；提醒列表勾选组仅在
`upcomingIncludeReminders` 开启时显示。日历勾选沿用"空数组=全选"的归一语义。

刷新时机仿照 `loadEvents`：弹层出现、日历/提醒授权变化、设置变化、
EventKit store 变更、选中日期变化与跨天时重新拉取；用请求 ID 做竞态保护。

## 设计决策与限制

- 分节开关独立于 `showEvents`：未来日程不依赖选中日期，关闭日程分节时仍可单独使用。
- 折叠状态不持久化（见交互设计），是有意取舍而非遗漏。
- 递归提醒按"天"近似展开（复用单日判定 `isOccurrence` 逐日检查），未处理
  例外日期（excluded dates）等复杂规则；对"未来 N 天"的展示场景足够。
- 多天事件只在开始日出现在列表中，不做跨天重复展示。
- 事件窗口从当天零点起查：当天已结束的事件被过滤，但当天进行中/全天事件保留。
- 本地化 key 沿用仓库惯例（英文 key，`zh-Hans` 为源语言）；"今天/明天"使用
  独立 key（`Upcoming Today`/`Upcoming Tomorrow`），不复用菜单栏 token 的
  短文案 `Today`（zh 为"今"）。
