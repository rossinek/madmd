import Foundation

struct MarkdownFile {
    let url: URL
    var text: String
    var diskData: Data
    let encoding: String.Encoding
    let bom: Data

    static func read(_ url: URL) throws -> MarkdownFile {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let encoding: String.Encoding
        let bom: Data
        let body: Data
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            encoding = .utf8; bom = Data([0xEF, 0xBB, 0xBF]); body = data.dropFirst(3)
        } else if data.starts(with: [0xFF, 0xFE]) {
            encoding = .utf16LittleEndian; bom = Data([0xFF, 0xFE]); body = data.dropFirst(2)
        } else if data.starts(with: [0xFE, 0xFF]) {
            encoding = .utf16BigEndian; bom = Data([0xFE, 0xFF]); body = data.dropFirst(2)
        } else {
            encoding = .utf8; bom = Data(); body = data
        }
        guard let text = String(data: body, encoding: encoding) else {
            throw NSError(domain: "madmd", code: 1, userInfo: [NSLocalizedDescriptionKey: "The file is not valid UTF-8 or UTF-16 text."])
        }
        return MarkdownFile(url: url, text: text, diskData: data, encoding: encoding, bom: bom)
    }

    func data(for text: String) throws -> Data {
        guard let body = text.data(using: encoding) else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
        return bom + body
    }
}
