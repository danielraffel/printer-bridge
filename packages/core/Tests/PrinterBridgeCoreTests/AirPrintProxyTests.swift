import Foundation
import Testing
@testable import PrinterBridgeCore

@Test
func ippRequestParserSeparatesDocumentDataFromAttributes() throws {
    var message = Data([0x01, 0x01])
    message.append(contentsOf: [0x00, 0x02]) // Print-Job
    message.append(contentsOf: [0x00, 0x00, 0x00, 0x2A]) // request-id
    message.append(0x01) // operation-attributes-tag

    appendAttribute(tag: 0x47, name: "attributes-charset", value: "utf-8", to: &message)
    appendAttribute(tag: 0x48, name: "attributes-natural-language", value: "en", to: &message)
    appendAttribute(tag: 0x42, name: "job-name", value: "Notes Print", to: &message)
    appendAttribute(tag: 0x49, name: "document-format", value: "application/pdf", to: &message)
    message.append(0x03) // end-of-attributes-tag
    message.append(Data("PDF-DATA".utf8))

    let request = try IPPRequestParser.parse(message)

    #expect(request.operationID == .printJob)
    #expect(request.requestID == 42)
    #expect(request.firstStringValue(named: "job-name") == "Notes Print")
    #expect(request.firstStringValue(named: "document-format") == "application/pdf")
    #expect(String(data: request.documentData, encoding: .utf8) == "PDF-DATA")
}

private func appendAttribute(tag: UInt8, name: String, value: String, to data: inout Data) {
    let nameData = Data(name.utf8)
    let valueData = Data(value.utf8)
    data.append(tag)
    data.append(contentsOf: [UInt8((nameData.count >> 8) & 0xff), UInt8(nameData.count & 0xff)])
    data.append(nameData)
    data.append(contentsOf: [UInt8((valueData.count >> 8) & 0xff), UInt8(valueData.count & 0xff)])
    data.append(valueData)
}
