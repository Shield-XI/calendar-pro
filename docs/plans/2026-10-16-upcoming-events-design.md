# 近期日程版块设计

**日期：** 2026-10-16
**状态：** 已实施；含滚动自动加载与「近期日程」五项改造批次，单元测试
393 通过（UI 测试因环境问题按基线跳过）
**实现记录：** [2026-10-16-upcoming-events.md](2026-10-16-upcoming-events.md)

## 目标

在菜单栏弹层的日程分节之后新增一个可折叠的「近期日程」版块，以双向
时间窗口展示过去与未来的日历日程（可选包含带到期时间的未完成提醒），
上滚回看过去、下滚浏览 upcoming，不必翻日历就能掌握近期安排。

## 信息结构

```text
月份标题
月历网格
统一日期摘要
信息条（天气 / 宜忌）
番茄钟（可选）
日程分节（现有，行为不变）
近期日程分节（新增，可折叠）
分隔线
底部操作
```

## 交互设计

- 分节初始展开态读「默认展开版块」设置（默认展开），标题行只显示
  「近期日程」与当前窗口内的条目总数（加载中显示"加载中"）。
- 点击标题切换展开，内容区内部滚动，`maxHeight` 约 200 pt，不影响弹层
  整体紧凑布局。
- 展开后按「天」分组升序渲染：天头显示"昨天 / 今天 / 明天 / M月d日"
  （本地化模板），条目行复用 `EventCardView` 的卡片视觉语言，事件点击
  进详情、提醒点击进详情、提醒勾选切换完成状态。
- 双向窗口自动加载：初始窗口为 [今天零点, now + 30 天]；列表顶部对称
  哨兵向过去扩窗（每次 -30 天，无天数硬上限，探明历史起点即止），
  底部哨兵向未来扩窗（每次 +30 天），直到设置的时间上限
  （30/90/180 天）；上限为 0 表示不限制。
- 折叠状态只记在视图 `@State` 内：初始值取「默认展开版块」设置，弹层
  每次打开重新按设置取初值，会话内手动折叠即时生效不持久化。

## 数据层

- `EventService.fetchUpcomingCalendarItems(pastStart:futureEnd:
  enabledCalendarIDs:includeReminders:enabledReminderCalendarIDs:)`：
  - 事件用 `predicateForEvents(withStart: pastStart, end: futureEnd)`
    查询。该谓词是重叠语义，会返回开始早于窗口的事件，因此本地再按
    `startDate >= pastStart 且 endDate > pastStart` 过滤：开始早于过去
    端点的多天事件不纳入（只在其开始日所在的窗口内展示一次）；窗口内
    已结束的事件纳入，供上滚回看过去。过滤逻辑抽为静态纯函数
    `EventService.event(_:isWithinUpcomingWindow:enabledCalendarIDs:)`
    供单元测试覆盖边界。
  - 提醒只取未完成项：复用 `fetchReminders` 的处理思路，用
    `predicateForIncompleteReminders(withDueDateStarting: nil, ending:
    futureEnd)` 兜住基准到期日早于窗口的递归提醒，再在本地按窗口过滤
    并按 `calendarItemIdentifier` 去重。
- 提醒窗口起点取 `pastStart`（初始为今天零点）：当天早些时候已过期但
  未完成的提醒保留在"今天"分组，与日程分节对当天的展示语义一致。

## 纯函数布局

`UpcomingSnapshot.make(items:now:calendar:)` 输入条目数组，输出按天升序的
`[UpcomingDayGroup]`（天头 + 条目）与总数，供视图直接渲染；同一天内全天条目
在前、其余按开始时间升序。过去天同样分组，天头「昨天」独立文案。与
`EventTimelineSnapshot` 的纯函数模式一致，测试注入固定时区的 `Calendar`
即可覆盖。

## 设置项

`MenuBarPreferences` 新增（解码均带缺省回退，旧数据无损升级）：

| 字段 | 默认值 | 说明 |
| --- | --- | --- |
| `showUpcomingSection` | `true` | 是否显示近期日程分节 |
| `upcomingDayLimit` | `90` | 时间上限（天），0 表示不限制 |
| `upcomingIncludeReminders` | `true` | 是否纳入有到期时间的未完成提醒 |
| `upcomingDefaultExpanded` | `true` | 弹层打开时分节是否默认展开 |
| `upcomingEnabledCalendarIDs` | `[]` | 参与聚合的日历，空数组表示全选 |
| `upcomingEnabledReminderCalendarIDs` | `[]` | 参与聚合的提醒列表，空数组表示全选 |

设置项位于独立的「近期日程」设置菜单页（「日程」页之后）；提醒列表
勾选组仅在 `upcomingIncludeReminders` 开启时显示。日历勾选沿用
"空数组=全选"的归一语义。`upcomingIncludeReminders` 默认值调整为 true
时，已存 JSON 显式写入 false 的用户经 `decodeIfPresent` 保持 false，
仅缺失该 key 的历史数据与新用户走 true。

刷新时机仿照 `loadEvents`：弹层出现、日历/提醒授权变化、设置变化、
EventKit store 变更、选中日期变化与跨天时重新拉取；用请求 ID 做竞态
保护。用户已扩展的窗口端点在弹层重开时保留（`@State` 随视图实例存活），
只重取数据不重置窗口。

## 设计决策与限制

- 分节开关独立于 `showEvents`：近期日程不依赖选中日期，关闭日程分节时
  仍可单独使用。
- 折叠状态不持久化（见交互设计），是有意取舍而非遗漏。
- 递归提醒按"天"近似展开（复用单日判定 `isOccurrence` 逐日检查），未处理
  例外日期（excluded dates）等复杂规则；对"近期 N 天"的展示场景足够。
- 多天事件只在其开始日（不早于窗口过去端点）出现在列表中，不做跨天
  重复展示；开始早于过去端点的多天事件整体不纳入。
- 双向窗口防重：每次扩窗全量重查当前窗口，两端加载标记一起置位、
  哨兵被进度行替换（视图层防重），加载中忽略新的扩窗触发（状态层
  防重）；过去端无天数硬上限，以「扩窗带不回任何条目」视为已探明
  历史起点（`isUpcomingPastExhausted`），数据源/设置变化与跨天时复位；
  过期结果由既有请求 ID 守卫丢弃。
- 已知取舍：顶部哨兵位于列表首元素，展开且未探明历史起点时通常可见，
  打开即自动向过去补窗（内容不足一屏时连续加载）；历史极长的用户首次
  展开会连续扩窗直到探明起点，之后会话内不再重复；向过去插入内容时
  视口随滚动偏移保持在内容顶部，如需「今日居中」的稳定视口可后续引入
  `defaultScrollAnchor`（macOS 14+）再评估。
- 本地化 key 沿用仓库惯例（英文 key，`zh-Hans` 为源语言）；"昨天/今天/
  明天"使用独立 key（`Recent Yesterday`/`Recent Today`/
  `Recent Tomorrow`），不复用菜单栏 token 的短文案 `Today`（zh 为"今"）。
