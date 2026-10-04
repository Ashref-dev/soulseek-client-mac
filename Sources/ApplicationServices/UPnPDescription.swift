import Foundation

final class UPnPDescription: NSObject, XMLParserDelegate {
    static let allowedTypes: Set<String> = Set(["WANIPConnection", "WANPPPConnection"].flatMap { service in
        [1, 2].map { "urn:schemas-upnp-org:service:\(service):\($0)" }
    })
    private var element = ""
    private var text = ""
    private var inService = false
    private var type = ""
    private var control = ""
    private var base = ""
    private var services: [(String, String)] = []

    static func read(_ data: Data, location: URL) -> (type: String, control: URL)? {
        guard data.count <= 256 * 1024, let host = location.host, PortMapper.isDeviceURL(location, host: host),
              let source = String(data: data, encoding: .utf8), !source.localizedCaseInsensitiveContains("<!DOCTYPE"),
              !source.localizedCaseInsensitiveContains("<!ENTITY") else { return nil }
        let delegate = UPnPDescription(); let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.shouldProcessNamespaces = true; parser.delegate = delegate
        guard parser.parse() else { return nil }
        let base: URL
        if delegate.base.isEmpty { base = location }
        else {
            guard let url = URL(string: delegate.base), PortMapper.isDeviceURL(url, host: host) else { return nil }
            base = url
        }
        for (type, path) in delegate.services where allowedTypes.contains(type) {
            if let url = URL(string: path, relativeTo: base)?.absoluteURL, PortMapper.isDeviceURL(url, host: host) { return (type, url) }
        }
        return nil
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        element = elementName; text = ""
        if elementName == "service" { inService = true; type = ""; control = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if inService, elementName == "serviceType" { type = value }
        if inService, elementName == "controlURL" { control = value }
        if elementName == "URLBase" { base = value }
        if elementName == "service" { if !control.isEmpty { services.append((type, control)) }; inService = false }
        text = ""
    }
}
