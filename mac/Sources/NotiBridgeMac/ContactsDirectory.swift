import Contacts
import Foundation
import NotiBridgeCore

/// Mac 通讯录：来电显示名字、拨号时搜索联系人。只在本机读取，不上传。
@MainActor
final class ContactsDirectory: ObservableObject {
    @Published private(set) var index = ContactIndex()
    @Published private(set) var status: CNAuthorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
    private let store = CNContactStore()
    private var observer: NSObjectProtocol?

    var authorized: Bool { status == .authorized }

    init() {
        observer = NotificationCenter.default.addObserver(forName: .CNContactStoreDidChange, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.reload() }
        }
        if authorized { reload() }
    }

    /// 申请权限（在使用通话功能时调用）
    func requestAccess() {
        guard status == .notDetermined else { reload(); return }
        store.requestAccess(for: .contacts) { _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.status = CNContactStore.authorizationStatus(for: .contacts)
                    self.reload()
                }
            }
        }
    }

    func reload() {
        status = CNContactStore.authorizationStatus(for: .contacts)
        guard authorized else { return }
        let store = self.store
        DispatchQueue.global(qos: .utility).async {
            var entries: [ContactEntry] = []
            let req = CNContactFetchRequest(keysToFetch: [CNContactPhoneNumbersKey as CNKeyDescriptor,
                                                          CNContactFormatter.descriptorForRequiredKeys(for: .fullName)])
            try? store.enumerateContacts(with: req) { c, _ in
                let name = CNContactFormatter.string(from: c, style: .fullName) ?? ""
                for p in c.phoneNumbers { entries.append(ContactEntry(name: name, number: p.value.stringValue)) }
            }
            let idx = ContactIndex(entries)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.index = idx } }
        }
    }

    func name(forNumber n: String) -> String? { index.name(forNumber: n) }
    func search(_ q: String) -> [ContactEntry] { index.search(q) }
}
