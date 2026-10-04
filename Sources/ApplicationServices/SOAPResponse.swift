import Foundation

final class SOAPResponse: NSObject, XMLParserDelegate {
    private let action: String
    private let service: String
    private var found = false
    private var fault = false
    private var stack: [(String, String?)] = []
    private var text = ""
    private var errorCode: Int?
    private init(action: String, service: String) { self.action = action; self.service = service }
    static func accepts(_ data: Data, action: String, service: String) -> Bool {
        guard let delegate = parse(data, action: action, service: service) else { return false }
        return delegate.found && !delegate.fault
    }
    static func faultCode(_ data: Data) -> Int? { parse(data, action: "", service: "")?.errorCode }
    private static func parse(_ data: Data, action: String, service: String) -> SOAPResponse? {
        guard data.count <= 64 * 1024, let text = String(data: data, encoding: .utf8),
              !text.localizedCaseInsensitiveContains("<!DOCTYPE"), !text.localizedCaseInsensitiveContains("<!ENTITY") else { return nil }
        let parser = XMLParser(data: data); let delegate = SOAPResponse(action: action, service: service)
        parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        return parser.parse() ? delegate : nil
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        let soap = "http://schemas.xmlsoap.org/soap/envelope/"
        let inBody = stack.count == 2 && stack[0].0 == "Envelope" && stack[0].1 == soap && stack[1].0 == "Body" && stack[1].1 == soap
        if elementName == "Fault", inBody, namespaceURI == soap { fault = true }
        if elementName == action + "Response", namespaceURI == service, inBody { found = true }
        stack.append((elementName, namespaceURI)); text = ""
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if fault, elementName == "errorCode" { errorCode = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if !stack.isEmpty { stack.removeLast() }; text = ""
    }
}
