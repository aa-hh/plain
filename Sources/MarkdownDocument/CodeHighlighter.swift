import Foundation
import JavaScriptCore
import PlainVendor

/// Runs Prism 1.30.0 in one `JSContext`, created on first use. Language files load on demand, after the languages
/// they `require` or list as `optional` in `components.json`. Results are cached for the 512 most recent
/// (language, code) pairs. Safe to call from any thread; calls run one at a time.
final class CodeHighlighter: @unchecked Sendable {
    static let shared = CodeHighlighter()

    private let lock = NSLock()
    private var context: JSContext?
    /// Language id or alias to language id.
    private var ids: [String: String] = [:]
    private var dependencies: [String: [String]] = [:]
    /// Language ids in the order their files were evaluated.
    private(set) var loadedLanguages: [String] = []
    private var cache: [String: [CodeToken]] = [:]
    private var cacheOrder: [String] = []
    private let cacheLimit = 512

    /// Leaf tokens with UTF-16 ranges relative to `code`, or nil when Prism has no such language.
    func tokens(for code: String, language: String) -> [CodeToken]? {
        lock.lock()
        defer { lock.unlock() }
        let context = context ?? makeContext()
        guard let id = ids[language.lowercased()] else { return nil }
        let key = id + "\u{0}" + code
        if let cached = cache[key] {
            cacheOrder.removeAll { $0 == key }
            cacheOrder.append(key)
            return cached
        }
        load(id, in: context)
        guard let flat = context.objectForKeyedSubscript("__plainTokens")?.call(withArguments: [code, id])?.toArray() else { return nil }
        var tokens: [CodeToken] = []
        tokens.reserveCapacity(flat.count / 3)
        var index = 0
        while index + 2 < flat.count {
            if let start = flat[index] as? NSNumber, let length = flat[index + 1] as? NSNumber, let type = flat[index + 2] as? String {
                tokens.append(CodeToken(range: NSRange(location: start.intValue, length: length.intValue), type: type))
            }
            index += 3
        }
        cache[key] = tokens
        cacheOrder.append(key)
        if cacheOrder.count > cacheLimit { cache[cacheOrder.removeFirst()] = nil }
        return tokens
    }

    /// Ids of loaded languages, in load order.
    func loadedLanguageIDs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return loadedLanguages
    }

    private func makeContext() -> JSContext {
        let context = JSContext()!
        if let core = try? String(contentsOf: VendorFiles.prismFolder.appendingPathComponent("prism-core.min.js"), encoding: .utf8) {
            context.evaluateScript(core)
        }
        context.evaluateScript("""
        function __plainTokens(code, lang) {
          var out = [], pos = 0;
          function walk(node, type) {
            if (typeof node === 'string') {
              if (type && node.length) out.push(pos, node.length, type);
              pos += node.length;
            } else if (Array.isArray(node)) {
              for (var i = 0; i < node.length; i++) walk(node[i], type);
            } else {
              walk(node.content, node.type);
            }
          }
          walk(Prism.tokenize(code, Prism.languages[lang]), null);
          return out;
        }
        """)
        if let data = try? Data(contentsOf: VendorFiles.prismComponentsJSON),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let languages = json["languages"] as? [String: Any] {
            func list(_ value: Any?) -> [String] {
                if let single = value as? String { return [single] }
                return value as? [String] ?? []
            }
            for (id, value) in languages where id != "meta" {
                guard let entry = value as? [String: Any] else { continue }
                ids[id] = id
                for alias in list(entry["alias"]) { ids[alias] = id }
                dependencies[id] = list(entry["require"]) + list(entry["optional"])
            }
        }
        self.context = context
        return context
    }

    private var attempted: Set<String> = []

    private func load(_ id: String, in context: JSContext) {
        guard attempted.insert(id).inserted else { return }
        for dependency in dependencies[id] ?? [] { load(dependency, in: context) }
        let url = VendorFiles.prismFolder.appendingPathComponent("prism-\(id).min.js")
        if let script = try? String(contentsOf: url, encoding: .utf8) { context.evaluateScript(script) }
        loadedLanguages.append(id)
    }
}
