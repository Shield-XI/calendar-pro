# 全天日程固定区实施计划

**Goal：** 日时间轴上下滚动或自动定位时，全天事项始终显示在日程视口顶部；全天事项较多时仍能访问全部事项。
**Architecture：** EventListView 的非 loading 内容改为固定全天区与时间轴滚动区的纵向兄弟布局。全天区自然高度、最高 88pt，超出后独立滚动；整体保持父级 200pt 高度预算，保留现有时间轴坐标及自动定位逻辑。
**Tech Stack：** Swift 6、SwiftUI、EventKit、XCTest；不新增依赖。
**执行者：** 后续 Luna 阶段。当前仅产出计划，不执行实现、审查、提交或合并，不启动子 Agent。

## 基线与授权范围

- 原工作区 `/Users/yelog/workspace/swift/calendar-pro`，目标 main，基线 `b67722acf2dc147b61a7603fbd0e656ceacaaa06`。
- plan 阶段重新确认 HEAD 与基线一致，Git status 与暂存 diff 均为空；无待复制到 worktree 的本地业务修改。
- 任务/分支待 Luna 自动命名；本阶段不创建分支、不修改 state.json 或 index。
- checkpoint.json 当前不存在，不创建它。分析依据见同目录 analysis.md；不存在需要依赖的历史 next。
- 当前计划及验证记录只写当前 `.git/opencode-tasks/ses_ec2a1aac9ffeoVh4jIg9F1KJpF/` 目录。后续若插件建立 worktree，先确认其 HEAD 与实际 diff，再按下面单元执行。

## 最终行为及不变量

1. 固定的是整个全天事项区域，不只是“All Day”标题；它位于日程标题下面、时间轴上面。
2. 时间轴滚动不改变全天区域外框位置；固定区和时间轴不重叠，卡片详情点击不受遮挡。
3. 整体日程区域最高 200pt。全天区最多 88pt，与下方间距建议 8pt；正常 200pt 视口仍给时间轴留下约 104pt。一项时按自然高度，不强占 88pt。
4. 超出全天区上限时，在全天区内部滚动可到达所有事项；滚轮位于时间轴时只滚动时间轴。
5. 无全天事项时，没有空固定区或额外间距。loading 保持原行为。
6. No Time 分组仍在主滚动内容中；空态、全天独占日期是否保留画布等其他行为均遵循现有代码。
7. 继续使用原 itemButton、24 小时 1440pt 画布、1pt/min、横向重叠 lane、双击创建坐标及分钟锚点。不添加滚动偏移状态或修改 EventKit 数据链路。
8. 今天的自动定位使用剩余时间轴视口居中；非今天的顶部定位不能被全天区挡住。分钟刷新不新增自动滚动触发。

## 修改范围

必需：
- `CalendarPro/Views/Popover/EventListView.swift`：Metrics、非 loading body、全天固定区辅助视图、dayTimelineContent。

同步修改：
- `docs/plans/2026-07-10-real-height-event-timeline-design.md`：仅更新全天固定、No Time 随时间轴滚动及整体 200pt 预算的相关设计假设，符合项目关于行为变化同步现有设计文档的约定。

仅读取/运行现有测试：`CalendarProTests/Events/CalendarItemTests.swift`、`CalendarProUITests/CalendarPopoverUITests.swift`。本计划不新增测试 fixture、不修改测试启动链路，不为布局修复扩展生产接口。

无需修改：CalendarPopoverView 的 200pt 限制、CalendarItem、EventService、时间轴模型、设置、权限、依赖、版本与发布文件。

上述两个预计修改文件完整列于同目录 change-scope.json。本计划阶段只写任务目录；设计说明的实际修改由 Luna 在实施工作区完成。若实施确需扩大文件范围，应先更新范围记录并说明原因，不能把可选测试建议视为隐含的修改授权。

## 验收与验证要求的来源

- **用户核心需求：** 向下滚动日程时间轴时，全天事项内容保持在日程可视区域顶部。通过实际滚动或可靠的界面自动化证据确认，不能仅凭标题存在或模型单测宣称满足。
- **本方案的完整性要求：** 全天内容溢出后全部可达，下方时间轴保留可操作空间，无全天时不留空区；现有点击和自动定位不因容器调整而回退。88pt 是推荐设计值，可按布局证据小幅调整并记录，不是用户指定门禁。
- **项目强制要求：** 修改后执行相关有效检查；涉及弹层交互需补手动验证说明，PR 的此类 UI 变更需截图或录屏；改变设计假设需更新对应设计文档。新增/删除源码时才重建工程。无法执行的检查如实记录原因与剩余风险。
- **本工作流验证安排：** 单元内定向检查，功能完成后全量验证，结果记录到 validation.md。命令见下文。
- **补充建议：** 下方矩阵中的广泛回归、双外观截图、精确 frame 容差和持续 UI fixture 测试用于增加信心，不是用户新增必需门禁。没有完成某一补充项不自动判定 blocked，也不应要求用户逐项人工操作。分析报告曾称整套矩阵为“必要 UI 验收”，本计划以此处来源分类为准。

## 单元一：完整实现全天固定及溢出访问

这是首个端到端可验收业务单元，不以“只移出全天区但溢出不可达”作为完成状态。

### 1. 确认相关源代码

通过 codegraph 定位 EventListView 的 Metrics、body、dayTimelineContent、auxiliarySection、itemButton 和 scrollToInitialTimelineContext。基线相关位置约为 799、828、856、1136、1151、1111 行。父级限制位于 CalendarPopoverView.eventsSection 的 `.frame(maxHeight: 200)`。

### 2. 建立固定区与滚动区的兄弟关系

保留 `if isLoading` 分支。非 loading 分支使用顶对齐 VStack；仅在 `dayTimelineLayout.allDayItems` 非空时添加全天固定区，随后保留原 ScrollViewReader 与纵向 ScrollView。

从 dayTimelineContent 删除原全天段，保留空态、No Time、画布顺序。原 `.onAppear`、两个 `.onChange` 和 proxy 继续归属下方纵向 ScrollView。不要向全天区复制 scrollTo 行为，也不要用全天高度补偿分钟坐标。

### 3. 实现自然高度和限高

在 Metrics 中定义 `allDayMaximumHeight = 88` 与固定区间距。优先用 `ViewThatFits(in: .vertical)`：首个候选为自然高度的 auxiliarySection，第二个候选为包含同一全天内容的限高纵向 ScrollView。候选必须能表达真实所需高度，不能因压缩而错误“适配”；固定区上限和较高的纵向 layoutPriority 配合父级剩余高度分配。

这只是推荐的 SwiftUI 实现路径，真正完成标准是自然高度/溢出两种行为。若实际拟合不正确，改用局部测量的 `min(contentHeight, 88)`；测量只能服务全天内容高度，避免引入主滚动偏移、重复滚动同步或持续更新循环。

全天内容在最终显示层级中只能有一份，不引入可交互的隐藏测量副本。兄弟布局无需额外不透明 overlay 背景或 zIndex 来遮挡时间轴。

### 4. 保持交互及可测性

复用 auxiliarySection 和 itemButton，不改事件详情、提醒回调和选中判断。可分别为固定区和下方主 ScrollView 增加 `calendar-popover-all-day-region` 与 `calendar-popover-day-timeline-scroll` 标识；标识只辅助界面定位，不能合并卡片辅助功能树或破坏按钮。

### 5. 同步设计并复核实际 diff

修改 `docs/plans/2026-07-10-real-height-event-timeline-design.md` 的信息结构和渲染结构，说明固定全天区、滚动 No Time 与画布、整体 200pt 预算及全天区溢出策略。不要改写其他历史条款或补做无 timed 时隐藏画布等旁支行为。

复核 `git diff --check`（预期退出 0），然后查看 `git diff -- CalendarPro/Views/Popover/EventListView.swift docs/plans/2026-07-10-real-height-event-timeline-design.md`。逐项确认全天内容没有重复渲染、触发器未增加、分钟坐标未调整、无新依赖或其他文件变更。这些命令仅检查，不 stage 或提交。

### 单元验收

- 一项全天事项自然高度显示；多项时固定区不超上限。
- 在时间轴上从上午滚到晚间再滚回，全天固定区外框 y 不变。
- 溢出全天列表能到达最后一项并点击打开详情，下面时间轴仍可滚动及双击创建。
- 自动定位、日期切换、无全天情况满足上述不变量。

## 单元二：验证并形成交付证据

### 自动检查

实施后先执行最相关范围：

```sh
xcodebuild test -project CalendarPro.xcodeproj -scheme CalendarPro -destination 'platform=macOS' -only-testing:CalendarProTests/CalendarItemTests
```

预期通过。该测试覆盖当前几何、跨日、分组、自动定位输入及创建时段；不能把它通过解释为固定区已得到 UI 验证。若失败，先区分本次变更、基线问题和环境问题，只修复任务范围内的问题。

功能齐备后执行一次完整验证：

```sh
xcodebuild test -project CalendarPro.xcodeproj -scheme CalendarPro -destination 'platform=macOS'
```

预期单元与 UI 测试通过。后续只有相关代码或环境改变才重跑，不循环重复全量。若新增或删除源码/测试文件，先按仓库约定运行 `ruby tools/generate_xcodeproj.rb`；仅修改已有文件时不运行。

### 核心 UI 证据与补充回归矩阵

优先取得一组符合用户核心需求的滚动前后证据，并提供项目要求的交互手动验证说明。下面列出建议的完整回归场景，供 Luna 按改动风险选用；不将整表逐项人工执行设为额外完成门禁。

| 场景 | 动作 | 通过条件 |
| --- | --- | --- |
| 今天，全天+timed | 打开后滚动时间轴 | 当前时刻自动定位、全天始终在顶端、时间轴确实发生移动 |
| 非今天，全天+timed | 切换日期 | 首个 timed 上下文仍可见，没有被全天区遮挡 |
| 一项全天 | 查看高度及点击 | 按内容自然高度，不强占 88pt，详情正确 |
| 多项全天 | 滚动全天区到末项并点击 | 固定外框不动，末项可达，时间轴保留空间 |
| 全天有→无→多 | 切换日期并来回滚动 | 无残留空白、重复卡片、旧滚动高度或错误选择 |
| 全天+No Time | 主滚动与提醒交互 | 仅全天固定，提醒可完成及打开详情 |
| 重叠 timed | 横向滚动、纵向滚动、双击空白 | lane 和创建时段不回退，坐标未偏移 |
| 空数据/loading | 触发相应状态 | 与原行为一致，无空全天容器 |
| 浅色/深色 | 查看固定边缘和卡片 | 无重叠透出、裁切或不可读内容 |
| 分钟刷新 | 手动滚动后等待刷新 | marker 更新，主时间轴不被重新拉回 |

项目要求涉及弹层交互的改动补手动验证说明，PR 附截图/录屏。推荐证据展示滚动前后全天区域保持同一位置且下方时间轴内容变化；多项全天末项可达的额外录屏是补充建议，不是单独的人工门禁。

现有 UI 测试只有月份导航，无需为了复用实现而新增模型测试。后续可另行补充持续 UI 自动回归，用确定性全天+timed fixture 检查固定区 frame 与下方时间轴移动。该建议不属于当前预计修改范围，不影响本次功能完成判定；若后续决定纳入，先明确文件范围及成本。不能通过写真实用户日历来构造测试数据。

### 环境受限处理

GUI、自动化授权、签名或测试宿主受限时，最多一次有针对性的修复重试；仍受限则记录命令、退出码、报错及缺失证据，交由 Luna 收尾审查决定是否补充检查。功能未实现不是阻塞；环境不可验证不能写成测试通过，也不能以无限 progress 重试替代记录限制。

### 记录及收尾

在任务目录 validation.md 追加每次实际执行的命令、退出结果、代码版本/工作区状态、环境、涉及文件和 UI 证据路径。后续 Luna 审查实际 diff 与不变量，确认无多余范围；遵循后续明确授权处理提交与合并，不将本计划视为提前授权操作共享历史。

## 完成标准与下一步

业务闭环、溢出访问、相关检查及验证记录完成后进入后续审查；环境限制和未执行的补充项明确记录，由 Luna 收尾判断，不要求全部补充场景逐项人工验收。本 plan 阶段的完成标准为实施计划与 change-scope.json 已落盘、当前工作区不变，最后写入本次 plan 回执。

下一步由 Luna 按单元一实施，先建立固定全天区与时间轴兄弟布局，再完成限高溢出和 UI 验收。无需用户再次选择方案或 resume。
