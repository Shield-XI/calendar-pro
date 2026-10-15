# 全天日程单行常驻栏 Implementation Plan

**执行者：** Luna。按下列端到端单元连续实施、验证及审查，不启动子 Agent，不要求用户 resume。本阶段只制定计划，不实施或提交。
**Goal：** 全天区域无论事件数量多少，默认只占一行，同时可访问全部事件并打开正确详情。
**Architecture：** 保留 EventListView 中固定全天区与主滚动区的兄弟关系，将全天区域替换为“全天标签 + 首条紧凑事件按钮 + 隐藏项菜单”。沿用现有事件分组、详情回调和时间轴，不增加布局测量或持久化状态。
**Tech Stack：** Swift 6、SwiftUI、EventKit、XCTest；不增加依赖。

## 基线与约束

- 原工作区 `/Users/yelog/workspace/swift/calendar-pro`；目标 main；起点及 plan 时 HEAD 均为 `0d8b23f72403f152941b30ac8b134de76109f125`。
- plan 阶段 `git status --short`、工作区 diff stat、暂存 diff stat 为空。不依赖未提交文件；无需清理、stash 或复制本地行为。
- `checkpoint.json` 尚不存在；不创建。插件 state.json 只读，本轮 activeReceipt 为 plan、token `03498101-1924-4e49-8100-8e64217c5786`。
- 所有本阶段产物只写当前 `.git/opencode-tasks/ses_ec287bb3fffepstKKQjF8h3dIb/`。技能默认的 docs/plans 输出位置、worktree 创建、提交与执行方式选择由用户阶段约束覆盖，不在此阶段执行。
- 完整设计依据见同目录 analysis.md，后续不必反复通读：关键决策是**整个区域仅一行**，其余项目使用明确的 +N 入口；不采用多行堆叠、水平滚动或向下展开。
- 本轮没有获得可读取的 Image 1；设计来自代码和需求，未做截图对照。尚未实施、编译或 UI 验证。

## 修改范围

必需修改：

1. `CalendarPro/Views/Popover/EventListView.swift`：Metrics、pinnedAllDaySection、全天专用私有渲染辅助方法；删除旧全天高度上限、ViewThatFits 与嵌套竖向滚动。
2. `CalendarPro/Resources/Localizable.xcstrings`：补溢出按钮帮助/辅助功能字符串，复用可用的全天、取消等既有语义文本。
3. `docs/plans/2026-07-10-real-height-event-timeline-design.md`：更新信息结构与渲染结构中的“最多 88pt / 区域内滚动”假设，说明单行及隐藏事件菜单。

仅读取/运行现有测试：`CalendarProTests/Events/CalendarItemTests.swift`、`CalendarProUITests/CalendarPopoverUITests.swift`。

不改 CalendarItem、EventService、通用 EventCardView、父级 200pt 上限、提醒分组、时间轴坐标、设置或发布文件。不增加源文件，因此不重建工程；若后续实际需要新增/删除源文件，按仓库约定执行 `ruby tools/generate_xcodeproj.rb` 并记录新增范围和理由。不要为了布局验证扩充生产启动模式。

## 单元一：实现单行预览、完整溢出访问和详情闭环

这是第一个可验收业务单元；不能以“只完成首项样式、其余项不可达”作为中间交付。

### 1. 核对实际上下文

在实施工作区先核对 HEAD 和实际 diff。通过 codegraph 获取 `EventListView pinnedAllDaySection allDaySectionHeader allDayItemsMaximumHeight itemButton`，确认当前基线结构仍一致。

相关位置：EventListView Metrics 约 799 行，body 约 829 行，pinnedAllDaySection 约 866 行，itemButton 约 1198 行。父级 `CalendarPopoverView.eventsSection` 约 209–222 行将 EventListView 限为最高 200pt。

### 2. 定义单行指标并移除旧限高逻辑

- 将 `allDayMaximumHeight = 88` 替换为 `allDayRowHeight = 28`，可另定义 `allDayCornerRadius = 4` 和小间距，遵循现有 Metrics 风格。
- 删除 `allDayItemsMaximumHeight` 及 `88 - 31` 计算。
- 全天横栏 28pt，顶部 4pt，沿用主滚动区上方 8pt 间隔，总预算目标 40pt。实际主区域满额为 200pt 时应剩约 160pt。
- 保留 body 中非空全天判断、固定区 layoutPriority(1)、主滚动区 layoutPriority(-1)、ScrollViewReader 和全部现有滚动触发器。

### 3. 用单行结构替换 pinnedAllDaySection

在该 computed property 中只取一次 `dayTimelineLayout.allDayItems`，以 first 与 dropFirst 分别产生预览和隐藏项。

布局顺序：

1. 全天标签：现有 `L("All Day")`，11pt medium/semibold、secondary、宽度 `Metrics.timeLaneWidth`（46pt）、trailing 对齐；单行，长翻译可适度缩小并保留完整辅助功能文本。
2. 外部 HStack spacing 复用 `Metrics.contentSpacing`（8pt），确保右侧内容从主时间轴内容轨同一 x 开始。
3. 右侧 HStack：首项按钮可伸展、隐藏项菜单保持自身宽度，两者约 6pt 间距。标题不得挤掉 +N。
4. 固定内部高度 28pt，外加 top 4pt。保留区域 accessibilityIdentifier `calendar-popover-all-day-region`。无数据时不渲染该区域或额外间隔。

不引入 ViewThatFits、全天内部 ScrollView、GeometryReader、overlay 固定方案或隐藏测量副本。

### 4. 实现紧凑事件按钮

优先在现有文件内添加私有方法或私有 View，不给通用 EventCardView 增加新模式。

- 事件通过 `if case .event(let event)` 安全解包；不要 force cast。
- 使用原生 Button，action 为 `onSelectEvent(event)`；selection 比较 `selectedEventIdentifier == event.selectionIdentifier`。
- label 为 3pt 色轨 + 单行标题；系统 12pt medium，`.lineLimit(1)`，尾部省略，左右约 6–8pt 内边距，圆角约 4pt，浅日历色底。颜色使用现有语义底色及 item.color；深浅外观遵循现有卡片色彩规律。
- 去除重复“All Day”、地点、来源、会议元数据和圆点，不给标题加缩放以塞入内容。
- 选中态使用更明显的日历色填充/边框；取消态标题删除线且弱化，保留点击详情。焦点与 hover 不覆盖系统键盘反馈；不增加装饰动画。
- 整个 28pt 高度可点击。色轨对辅助功能隐藏；Button help/label 提供完整标题、全天、来源和取消语义；避免多次朗读同一个标题。
- 可加稳定事件标识 `calendar-popover-all-day-event-<selectionIdentifier>`；不改变 CalendarItem.id 的全局实现。

### 5. 完成隐藏项 Menu 与本地化

- 只有 remaining 非空时显示 Menu，入口文字为 `+\(remaining.count)`，不是总数。
- 每个剩余事件一个原生可执行 Button，action 同样调用 onSelectEvent。用事件标识保持稳定身份，不用标题作 id。
- 菜单项使用完整标题，并显示日历来源以区分同名事件；优先原生 Text/Label。选中项可以原生 checkmark 表示；取消项保留可理解的取消语义，不依赖菜单内自定义文本样式一定被 AppKit 保留。
- Menu 的 help/accessibilityLabel 用本地化格式“另外 %d 个全天日程”（英文建议 `%d more all-day events`），采用项目既有 L/LF 格式；检查 Localizable.xcstrings 的语言集合并补齐一致的翻译。需要复数时按现有 string catalog 结构处理。
- 保留系统菜单滚动、键盘导航、Esc 关闭和自动定位；不要改为独立浮窗、popover 或自绘菜单。可选菜单样式 API 先查当前文档，不凭猜测引入版本不兼容修饰符。
- 标识 `calendar-popover-all-day-overflow`。入口不是 hover 才出现；有足够文字宽度显示 +N，采用系统原生 Menu 箭头行为，避免重复手工箭头。
- 预览始终使用输入顺序首项；菜单选择其他事件后不重新排序预览。数量变化重新从当前 items 派生，不持久化旧列表。

### 6. 同步文档并检查范围

更新真实高度时间线设计文档第 54 行附近的信息结构、第 126 行附近的渲染结构，描述单行全天固定栏、首项预览及 +N 菜单，其余时间轴行为不变。

执行：

```sh
git diff --check
git diff --stat
git diff -- CalendarPro/Views/Popover/EventListView.swift CalendarPro/Resources/Localizable.xcstrings docs/plans/2026-07-10-real-height-event-timeline-design.md
```

预期 diff check 退出 0；实际 diff 仅涵盖上述范围。确认无双份事件、无 88pt 遗留全天限高、无分钟坐标补偿、无新的自动定位触发、无新依赖。

### 单元验收

- 1、3、20 条全天事项时区域都保持一行，时间轴始终拥有剩余可操作空间。
- 首项直接打开正确详情；所有隐藏项包括末项均可通过菜单打开；+N 等于隐藏项数量。
- 在下方时间轴滚动时全天区域位置不变；主滚动、双击创建与事件点击没有被固定区遮挡。
- 无全天项不留空栏；全天 1→多→0、日期切换和同步更新不残留旧内容。

## 单元二：验证并形成可审查交付

### 要求来源与门禁边界

- **用户需求：** 全天显示节省空间，数量增加时仍能看到并操作下方日程；所选方案需要保证单行显示、隐藏事件可达及详情正确。这些是业务结果要求，不意味着用户必须逐项亲自验收。
- **项目强制要求（AGENTS.md）：** 修改后运行相关有效检查；弹层变更补手动验证说明；PR 附截图或录屏；设计假设变化同步相关设计文档。说明中区分已验证和待验证，不能以说明代替通过结果。
- **本工作流要求：** 单元内定向测试，功能齐备后全量验证，并把实际结果写入 validation.md；环境受限检查最多一次针对性修复重试，再由 Luna 收尾审查处理证据缺口。
- **补充验证建议：** 0/1/3/20 数据组合的临时宿主、精确 frame 测量、双语言双外观全矩阵、VoiceOver 操作录像等用于提高信心。具体宿主和人工操作方式不是新增强制门禁；环境受限时不得因此要求用户反复操作或阻止流程进入收尾审查。28/40/160pt 属于设计目标，不能当成用户指定的硬阈值。

### 定向测试

```sh
xcodebuild test -project CalendarPro.xcodeproj -scheme CalendarPro -destination 'platform=macOS' -only-testing:CalendarProTests/CalendarItemTests
```

预期通过。覆盖分组、真实时间轴几何、跨日、自动定位输入与创建时段；不能证明 SwiftUI 单行布局已通过。

### UI 证据

核心验证是实际一行恒高、隐藏末项可达并打开正确事件、主时间轴仍可滚动。现有 CalendarPopoverUITests 仅验证月份导航，且 `CALENDAR_PRO_UI_TEST_MODE=popover-window` 没有全天 fixture，不能用旧 UI 测试代替核心证据。

建议使用可用预览或临时 NSHostingView 验证宿主注入内存 EKEvent/EKCalendar，构造 0/1/3/20 个全天+timed 项，所有临时脚本放当前任务目录。这是可选证据路径，不要求必须创建该宿主；选择现有工具能可靠执行的最小验证方式即可。不创建真实用户日历事件、不引入生产测试数据或长期测试启动链路。若仅能进行静态渲染，可验证高度、裁切、颜色，但必须单独说明尚未验证菜单 action/焦点/系统弹层。

| 场景 | 观察结果 |
| --- | --- |
| 多条全天+timed，滚动前后 | 全天区域 frame 保持不变，下方内容确实滚动；单行连同间隔目标约≤40pt |
| 单项及多项溢出 | 无溢出时首项填满；有溢出时 +N 可见、末项可到达、详情匹配 |
| 超长标题、同名不同日历、取消/选中 | 不换行、不挤掉入口；完整文案和来源可获知；状态语义保留 |
| 无全天、loading、1→多→0、日期切换 | 没有多余间距或旧事件 |
| 深浅外观、中英文、键盘/VoiceOver | 文案不截掉入口、颜色可读、控件可激活、菜单可关闭 |
| 今天/非今天、分钟刷新、重叠 lane、无时间提醒 | 原自动定位和手动滚动不回退，提醒完成与打开仍有效 |

前两行及空数据转换属于直接功能验收，其余作为相关风险回归按实际验证能力补充。28/40/160pt 为设计目标，可据字体和实测小幅调整并记录理由；不能退回随事件数量增长的固定区。

项目要求弹层变更提供手动验证说明，PR 附截图或录屏。记录已执行动作、实际结果和未完成项，不要求用户代为完成实现。没有 UI 权限时不声称已验证。

### 功能齐备后全量检查

```sh
xcodebuild test -project CalendarPro.xcodeproj -scheme CalendarPro -destination 'platform=macOS'
```

预期单元与 UI 测试通过。只执行一次，除非后续相关代码或环境发生变化。现有测试不能覆盖新菜单全部交互，应保留对应证据限制。

GUI、测试宿主、权限、签名等环境问题最多一次针对性修复重试；仍受限则记录退出码、错误及缺少的 UI 证据，交 Luna 收尾审查判断是否补充检查。普通代码错误自行修复，不把未实现功能标记 blocked，也不无限 progress 重试同一检查。

将每条实际验证命令、退出结果、相关文件、代码版本与工作区状态、环境和证据路径追加到任务目录 validation.md。最终复核实际 diff、业务闭环与限制。提交、分支命名和合并按后续阶段明确授权执行，本计划本身不执行这些操作。

## 下一步

Luna 在实际实施工作区核对 HEAD/diff，完成单元一整条全天栏及溢出详情访问，再进入单元二验证和审查。建议任务主题 `compact-all-day-events`，命名由插件/Luna 后续处理。本 plan 阶段以本计划、change-scope.json 与指定 completed 回执落盘结束。
