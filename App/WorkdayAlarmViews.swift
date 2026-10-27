import SwiftUI

private enum AlarmText {
    static func day(_ date: Date, includeYear: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.calendar = WorkdayClock.calendar
        formatter.timeZone = WorkdayClock.calendar.timeZone
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = includeYear ? "yyyy 年 M 月 d 日 EEEE" : "M 月 d 日 EEEE"
        return formatter.string(from: date)
    }
    static func time(_ date: Date) -> String {
        let parts = WorkdayClock.calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour!, parts.minute!)
    }
    static let weekdays = [(2, "一"), (3, "二"), (4, "三"), (5, "四"), (6, "五"), (7, "六"), (1, "日")]
}

struct WorkdayAlarmHome: View {
    let isActive: Bool
    @ObservedObject private var model = WorkdayAlarmService.shared
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .largeTitle) private var heroFontSize: CGFloat = 58
    @State private var editing: WorkdayAlarmRule?
    @State private var deleting: WorkdayAlarmRule?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    hero
                    if let error = model.error {
                        alarmNotice(error, symbol: "exclamationmark.triangle", color: .orange)
                        HStack {
                            Button("重新检查") { Task { await model.refresh(requestPermission: true) } }
                                .disabled(model.busy)
                            if model.authorization == .denied {
                                Spacer()
                                Link("前往系统设置", destination: URL(string: UIApplication.openSettingsURLString)!)
                            }
                        }.font(.subheadline.weight(.semibold))
                    }
                    if let missing = model.report?.missingYears, !missing.isEmpty {
                        alarmNotice("缺少 \(missing.sorted().map(String.init).joined(separator: "、")) 年安排。该年度的法定工作日闹钟暂不排程，请在「年度安排」中更新。",
                                    symbol: "calendar.badge.exclamationmark", color: .orange)
                    }
                    if model.rules.isEmpty {
                        VStack(spacing: 14) {
                            Image(systemName: "sunrise").font(.system(size: 38)).foregroundStyle(.orange)
                            Text("工作日准时醒，休息日安心睡").font(.headline)
                            Text("自动跳过法定休息日，记住周末补班。\n也可以为某一天单独调整。")
                                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button("创建第一个闹钟") { editing = WorkdayAlarmRule() }
                                .buttonStyle(.borderedProminent).controlSize(.large)
                                .disabled(!model.loaded || model.busy)
                                .accessibilityIdentifier("alarm.create.first")
                        }.frame(maxWidth: .infinity).padding(.vertical, 28)
                    } else {
                        HStack {
                            Text("我的闹钟").font(.headline)
                            Spacer()
                            if model.busy { ProgressView().accessibilityLabel("正在核对系统闹钟") }
                        }
                        ForEach(model.rules) { rule in alarmCard(rule) }
                        if model.rules.count >= 8 {
                            Text("最多保留 8 个闹钟，可编辑或删除现有闹钟。").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    NavigationLink {
                        WorkdayCalendarDataView(model: model)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "calendar.badge.clock").font(.title2).foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("年度安排").font(.headline).foregroundStyle(.primary)
                                Text(model.years.keys.sorted().map(String.init).joined(separator: " · ") + " 年 · 内置与下载更新")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }.padding(18).background(.background, in: RoundedRectangle(cornerRadius: 20))
                    }.buttonStyle(.plain).accessibilityIdentifier("alarm.calendar")
                    VStack(alignment: .leading, spacing: 8) {
                        Label("北京时间 · 离线可用", systemImage: "globe.asia.australia")
                            .font(.subheadline.weight(.medium))
                        Text("响铃由系统闹钟执行。静音与专注模式下可提醒；所有时间固定为北京时间，出国旅行时也不会改为当地时间。")
                        Text("请勿隐藏卷轴或为它单独设置 Face ID／密码锁；Apple 提示此类 App 的闹钟可能无法响铃。")
                        Text("最多预排未来 90 天内最近的 64 次；打开卷轴或关闭闹钟时补齐。若长期不使用，请在已排程日期结束前打开检查。后台刷新不保证执行。")
                    }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 2)
                }.padding(20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("调休闹钟")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editing = WorkdayAlarmRule() } label: { Image(systemName: "plus") }
                        .accessibilityLabel("添加闹钟").accessibilityIdentifier("alarm.create")
                        .disabled(!model.loaded || model.busy || model.rules.count >= 8)
                }
            }
            .sheet(item: $editing) { WorkdayAlarmEditor(model: model, rule: $0) }
            .confirmationDialog("删除这个闹钟？", isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                if let rule = deleting {
                    Button("删除 \(rule.timeText) 闹钟", role: .destructive) {
                        Task { await model.delete(rule) }; deleting = nil
                    }
                }
            }
            .task(id: isActive) { if isActive { await model.enter() } }
            .onChange(of: scenePhase) { _, phase in
                if isActive && phase == .active { Task { await model.enter() } }
            }
            .tint(.orange)
        }
    }
    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("下一次响铃", systemImage: "bell.badge").font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            if let next = model.next {
                Text(AlarmText.time(next.date))
                    .font(.system(size: heroFontSize, weight: .light, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.65)
                    .accessibilityIdentifier("alarm.next.time")
                Text("\(AlarmText.day(next.date)) · \(next.label)").font(.headline)
                Label(next.reason, systemImage: "checkmark.circle.fill").font(.subheadline).foregroundStyle(.orange)
            } else {
                Text(model.rules.contains(where: \.enabled) ? "等待安排" : "留一个好早晨")
                    .font(.largeTitle.weight(.semibold))
                Text(model.rules.contains(where: \.enabled) ? "还没有确认成功的系统闹钟，请查看下方提示。" : "按工作日设一次，把调休交给卷轴。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if let report = model.report, let last = report.confirmed.last {
                Divider()
                Text("已确认 \(report.confirmed.count) 次 · 最远 \(AlarmText.day(last.date))")
                    .font(.caption).foregroundStyle(.secondary)
                if report.unconfirmedCount > 0 {
                    Text("还有 \(report.unconfirmedCount) 次未确认排程").font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(24)
        .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 28))
        .accessibilityElement(children: .contain)
    }
    private func alarmCard(_ rule: WorkdayAlarmRule) -> some View {
        let confirmed = model.report?.confirmed.filter { $0.ruleID == rule.id } ?? []
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Button { editing = rule } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(rule.timeText).font(.system(size: 40, weight: .light, design: .rounded)).monospacedDigit()
                        Text("\(rule.label.isEmpty ? "起床" : rule.label) · \(rule.mode.title)").font(.subheadline)
                            .foregroundStyle(.secondary)
                    }.foregroundStyle(rule.enabled ? .primary : .secondary)
                }.buttonStyle(.plain).accessibilityLabel("编辑 \(rule.timeText) \(rule.label)")
                Spacer(minLength: 16)
                Toggle("启用 \(rule.timeText) 闹钟", isOn: Binding(
                    get: { rule.enabled }, set: { enabled in Task { await model.toggle(rule, enabled: enabled) } }))
                    .labelsHidden().disabled(model.busy)
                    .accessibilityIdentifier("alarm.toggle.\(rule.id.uuidString)")
            }
            if rule.enabled {
                if let first = confirmed.first {
                    Text("\(AlarmText.day(first.date)) · \(first.reason)").font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("尚无已确认排程", systemImage: "clock.badge.exclamationmark")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            HStack {
                NavigationLink("未来安排") { WorkdayAlarmPreview(model: model, ruleID: rule.id) }
                Spacer()
                Button("删除", role: .destructive) { deleting = rule }
                    .disabled(model.busy)
            }.font(.caption.weight(.semibold))
        }.padding(20).background(.background, in: RoundedRectangle(cornerRadius: 22))
    }
    private func alarmNotice(_ text: String, symbol: String, color: Color) -> some View {
        Label { Text(text).font(.subheadline) } icon: { Image(systemName: symbol) }
            .foregroundStyle(color).padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            .accessibilityIdentifier("alarm.notice")
    }
}

private struct WorkdayAlarmEditor: View {
    @ObservedObject var model: WorkdayAlarmService
    @Environment(\.dismiss) private var dismiss
    @State var rule: WorkdayAlarmRule
    @State private var saving = false
    private var time: Binding<Date> {
        Binding(get: { WorkdayClock.parse("2026-01-01", hour: rule.hour, minute: rule.minute)! }, set: {
            let parts = WorkdayClock.calendar.dateComponents([.hour, .minute], from: $0)
            rule.hour = parts.hour!; rule.minute = parts.minute!
        })
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("响铃时间", selection: time, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel).labelsHidden()
                        .environment(\.timeZone, WorkdayClock.calendar.timeZone)
                        .environment(\.locale, Locale(identifier: "zh_CN"))
                        .accessibilityIdentifier("alarm.editor.time")
                } footer: { Text("北京时间（UTC+8）。跨时区旅行仍按此时间响铃。") }
                Section("重复方式") {
                    Picker("重复", selection: $rule.mode) {
                        ForEach(WorkdayAlarmRule.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.menu)
                    if rule.mode == .weekly {
                        ForEach(AlarmText.weekdays, id: \.0) { day, title in
                            Toggle("星期\(title)", isOn: Binding(get: { rule.weekdays.contains(day) }, set: {
                                if $0 { rule.weekdays.insert(day) } else { rule.weekdays.remove(day) }
                            }))
                        }
                    }
                    if rule.mode == .workdays {
                        Label("法定休息日不响，周末补班照常响", systemImage: "calendar.badge.checkmark")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Section {
                    TextField("名称，例如：起床、出门", text: $rule.label)
                        .onChange(of: rule.label) { _, value in if value.count > 30 { rule.label = String(value.prefix(30)) } }
                    Toggle("启用闹钟", isOn: $rule.enabled)
                }
                Section {
                    ForEach(0..<7, id: \.self) { offset in
                        let date = WorkdayClock.day(offset, after: Date())
                        AlarmDayRow(date: date, decision: WorkdayPlanner.decision(day: date, rule: rule, datasets: model.datasets))
                    }
                } header: { Text("接下来 7 天 · 规则预览") } footer: {
                    Text("这是规则预览，实际排程以首页确认为准。保存后可在「未来安排」中调整单日例外。")
                }
                if let error = model.error { Section { Text(error).foregroundStyle(.orange).font(.subheadline) } }
            }
            .navigationTitle(model.rules.contains(where: { $0.id == rule.id }) ? "编辑闹钟" : "添加闹钟")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        saving = true
                        Task { let saved = await model.save(rule); saving = false; if saved { dismiss() } }
                    }.disabled(saving || model.busy || (rule.mode == .weekly && rule.weekdays.isEmpty))
                    .accessibilityIdentifier("alarm.editor.save")
                }
            }.interactiveDismissDisabled(saving).tint(.orange)
        }
    }
}

private struct AlarmDayRow: View {
    let date: Date
    let decision: WorkdayDecision
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: decision.shouldRing == true ? "bell.fill" : decision.shouldRing == false ? "moon.zzz" : "questionmark.circle")
                .foregroundStyle(decision.shouldRing == true ? .orange : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(AlarmText.day(date)).foregroundStyle(.primary)
                Text(decision.reason).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(decision.shouldRing == true ? "响铃" : decision.shouldRing == false ? "休息" : "待更新")
                .font(.caption.weight(.medium)).foregroundStyle(decision.shouldRing == true ? .orange : .secondary)
        }.accessibilityElement(children: .combine)
    }
}

private struct WorkdayAlarmPreview: View {
    @ObservedObject var model: WorkdayAlarmService
    let ruleID: UUID
    @State private var selectedDay: String?
    private var rule: WorkdayAlarmRule? { model.rules.first { $0.id == ruleID } }
    var body: some View {
        List {
            if let rule {
                Section {
                    Text("\(rule.timeText) · \(rule.mode.title)").font(.title2.weight(.semibold))
                    Text(rule.enabled ? "轻点日期，为那一天单独调整。以下为规则预览，已交给系统的次数以首页为准。" : "这个闹钟已关闭。以下是开启后的规则预览。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section("未来 30 天 · 北京时间") {
                    ForEach(0..<30, id: \.self) { offset in
                        let date = WorkdayClock.day(offset, after: Date())
                        Button { selectedDay = WorkdayClock.key(date) } label: {
                            AlarmDayRow(date: date, decision: WorkdayPlanner.decision(day: date, rule: rule, datasets: model.datasets))
                        }.disabled(model.busy)
                    }
                }
                if !rule.exceptions.isEmpty {
                    Section("个人例外") {
                        ForEach(rule.exceptions.keys.sorted(), id: \.self) { day in
                            HStack {
                                Text(day)
                                Spacer()
                                Text(rule.exceptions[day] == true ? "响铃" : "不响").foregroundStyle(.secondary)
                                Button("恢复") { adjust(day, to: nil) }.font(.caption)
                                    .disabled(model.busy)
                            }
                        }
                    }
                }
                if let error = model.error { Section { Text(error).foregroundStyle(.orange) } }
            }
        }.navigationTitle("未来安排").navigationBarTitleDisplayMode(.inline)
            .confirmationDialog(selectedDay ?? "调整这一天", isPresented: Binding(
                get: { selectedDay != nil }, set: { if !$0 { selectedDay = nil } }), titleVisibility: .visible) {
                if let day = selectedDay {
                    Button("这一天响铃") { adjust(day, to: true) }
                    Button("这一天不响") { adjust(day, to: false) }
                    Button("遵循默认规则") { adjust(day, to: nil) }
                }
            }
    }
    private func adjust(_ day: String, to value: Bool?) {
        guard var rule else { return }
        rule.exceptions[day] = value
        selectedDay = nil
        Task { _ = await model.save(rule) }
    }
}

private struct WorkdayCalendarDataView: View {
    @ObservedObject var model: WorkdayAlarmService
    var body: some View {
        List {
            Section {
                Label("年度安排保存在这台 iPhone", systemImage: "iphone")
                    .font(.headline)
                Text("断网也能判断调休并执行已排程闹钟。更新只下载公开日历，不上传你的闹钟或截图。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section("已具备的年度") {
                ForEach(model.years.keys.sorted().reversed(), id: \.self) { year in
                    if let record = model.years[year] {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("\(String(year)) 年").font(.title2.weight(.semibold))
                                Spacer()
                                Text("\(record.downloaded ? "已下载" : "App 内置") · v\(record.dataset.revision)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text("\(record.dataset.overrides.filter { $0.kind == .rest }.count) 个休息日 · \(record.dataset.overrides.filter { $0.kind == .work }.count) 个补班日")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Link(destination: record.dataset.source.url) {
                                Label("查看国务院安排原文", systemImage: "arrow.up.right.square")
                            }.font(.subheadline)
                            Text("公告日期 \(record.dataset.source.publishedAt)").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 6)
                    }
                }
            }
            Section {
                Toggle("自动检查年度更新", isOn: Binding(
                    get: { model.automaticUpdates }, set: { model.setAutomaticUpdates($0) }))
                    .disabled(model.busy || model.updating)
                Button { Task { await model.updateCalendar() } } label: {
                    HStack {
                        Text(model.updating ? "正在检查…" : "检查更新")
                        Spacer()
                        if model.updating { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }
                }.disabled(model.busy || model.updating).accessibilityIdentifier("alarm.calendar.update")
                if let date = model.checkedAt {
                    Text("最近成功检查：\(AlarmText.day(date, includeYear: true)) \(AlarmText.time(date))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let message = model.updateMessage { Text(message).font(.subheadline).accessibilityIdentifier("alarm.calendar.result") }
            } footer: {
                Text("自动检查仅在进入调休闹钟后进行，每天最多一次成功检查。版本更新也可携带新年度；未获得的新年度会显示待更新。")
            }
            Section("下载入口") {
                Link("查看公开年度文件索引", destination: WorkdayHolidayStore.endpoint)
                Text("GitHub Pages 提供静态文件。下载失败时保留已有安排；修订发布后，需要成功检查更新才能应用。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("年度安排").navigationBarTitleDisplayMode(.inline).tint(.orange)
    }
}
