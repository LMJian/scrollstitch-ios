import SwiftUI

struct ProductInformationView: View {
    private let information: ProductInformation? = Bundle.main.url(forResource: "ProductInfo", withExtension: "json")
        .flatMap { try? Data(contentsOf: $0) }.flatMap { try? ProductInformation.decode($0) }
    static var versionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
        return "\(version)（\(build)）"
    }
    var body: some View {
        List {
            if let information {
                ForEach(Array(information.sections.enumerated()), id: \.offset) { _, section in
                    Section(section.title) { Text(section.body).fixedSize(horizontal: false, vertical: true) }
                }
                if information.supportLink != nil || information.privacyLink != nil || information.supportEmailLink != nil {
                    Section("了解更多") {
                        if let url = information.supportLink { Link("联系与支持", destination: url) }
                        if let url = information.privacyLink { Link("在线隐私政策", destination: url) }
                        if let url = information.supportEmailLink { Link("邮件联系开发者", destination: url) }
                    }
                }
                Section {
                    LabeledContent("说明版本", value: information.policyVersion)
                    LabeledContent("更新日期", value: information.effectiveDate)
                }
            } else {
                Section("在本机处理") { Text("卷轴在本机处理图片。保存和分享由你主动选择。") }
                Section { Text("完整隐私说明暂时无法读取，请更新应用后查看。当前作品仍保留在本机。") }
            }
            Section { LabeledContent("卷轴版本", value: Self.versionLabel) }
        }.navigationTitle("隐私与数据").navigationBarTitleDisplayMode(.inline)
    }
}
