import Foundation
import Testing
@testable import ArpeggioServices

@Test func natPMPReplyRequiresMatchingContractAndAdvertisedPort() {
    let reply = Data([0, 130, 0, 0, 0, 0, 0, 1, 8, 186, 8, 186, 0, 0, 14, 16])
    #expect(PortMapper.validNATPMPReply(reply, port: 2234, deleting: false))
    for (offset, value) in [(0, UInt8(1)), (1, 129), (3, 2), (9, 1), (11, 1)] {
        var invalid = reply; invalid[offset] = value
        #expect(!PortMapper.validNATPMPReply(invalid, port: 2234, deleting: false))
    }
    #expect(!PortMapper.validNATPMPReply(reply.prefix(15), port: 2234, deleting: false))
    #expect(!PortMapper.validNATPMPReply(reply + Data([0]), port: 2234, deleting: false))
    var deletion = reply; deletion.replaceSubrange(10..<16, with: [0, 0, 0, 0, 0, 0])
    #expect(PortMapper.validNATPMPReply(deletion, port: 2234, deleting: true))
    #expect(!PortMapper.validNATPMPReply(deletion, port: 2234, deleting: false))
}

@Test func upnpDescriptionParsesServiceBlocksNamespacesAndSafeURLBase() throws {
    let location = try #require(URL(string: "http://192.168.1.1:5000/device.xml"))
    let source = "<root xmlns='urn:test'><URLBase>http://192.168.1.1:5000/base/</URLBase><serviceList><service><serviceType>unrelated</serviceType><controlURL>/wrong</controlURL></service><service><serviceType>urn:schemas-upnp-org:service:WANIPConnection:2</serviceType><controlURL>control?a=1&amp;b=2</controlURL></service></serviceList></root>"
    let device = try #require(UPnPDescription.read(Data(source.utf8), location: location))
    #expect(device.type.hasSuffix("WANIPConnection:2"))
    #expect(device.control.absoluteString == "http://192.168.1.1:5000/base/control?a=1&b=2")
    #expect(UPnPDescription.read(Data(source.replacingOccurrences(of: "http://192.168.1.1", with: "http://127.0.0.1").utf8), location: location) == nil)
    #expect(UPnPDescription.read(Data(("<!DOCTYPE root [<!ENTITY x SYSTEM 'file:///etc/passwd'>]>" + source).utf8), location: location) == nil)
    #expect(UPnPDescription.read(Data(repeating: 32, count: 256 * 1024 + 1), location: location) == nil)
}

@Test func routerURLsAndXMLValuesCannotEscapeDeviceOrigin() throws {
    for value in ["file:///tmp/router", "http://user:pass@192.168.1.1/a", "http://127.0.0.1/a", "http://192.168.1.1/a#fragment", "http://192.168.1.1:0/a"] {
        #expect(!PortMapper.isDeviceURL(try #require(URL(string: value)), host: "192.168.1.1"))
    }
    #expect(PortMapper.xmlEscape("<&\"'>") == "&lt;&amp;&quot;&apos;&gt;")
}

@Test func disabledMappingDoesNotProbeTheNetwork() async {
    let mapper = PortMapper(port: 2234)
    #expect(await mapper.map(natPMP: false, upnp: false) == .disabled)
}

@Test func soapAcknowledgmentsRequireValidXMLMatchingActionAndNoFault() {
    let service = "urn:schemas-upnp-org:service:WANIPConnection:1"
    let good = "<s:Envelope xmlns:s='http://schemas.xmlsoap.org/soap/envelope/'><s:Body><u:AddPortMappingResponse xmlns:u='\(service)'/></s:Body></s:Envelope>"
    #expect(SOAPResponse.accepts(Data(good.utf8), action: "AddPortMapping", service: service))
    #expect(!SOAPResponse.accepts(Data(good.utf8), action: "DeletePortMapping", service: service))
    #expect(!SOAPResponse.accepts(Data(good.replacingOccurrences(of: service, with: "urn:wrong").utf8), action: "AddPortMapping", service: service))
    #expect(!SOAPResponse.accepts(Data(good.dropLast().utf8), action: "AddPortMapping", service: service))
    #expect(!SOAPResponse.accepts(Data(good.replacingOccurrences(of: "</s:Body>", with: "<s:Fault/></s:Body>").utf8), action: "AddPortMapping", service: service))
}
