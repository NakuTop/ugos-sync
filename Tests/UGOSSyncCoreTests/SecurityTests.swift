import XCTest
import Security
@testable import UGOSSyncCore

final class SecurityTests: XCTestCase {
    func testRSAChallengeEncryptionRoundTrip() throws {
        let attrs: [String:Any] = [kSecAttrKeyType as String:kSecAttrKeyTypeRSA,kSecAttrKeySizeInBits as String:2048]
        var error:Unmanaged<CFError>?
        let key=try XCTUnwrap(SecKeyCreateRandomKey(attrs as CFDictionary,&error))
        let pub=try XCTUnwrap(SecKeyCopyPublicKey(key))
        let data=try XCTUnwrap(SecKeyCopyExternalRepresentation(pub,&error)) as Data
        let pem="-----BEGIN RSA PUBLIC KEY-----\n"+data.base64EncodedString()+"\n-----END RSA PUBLIC KEY-----"
        let encrypted=try RSAEncryption.encrypt("sample-password",publicKey:pem)
        let cipher=try XCTUnwrap(Data(base64Encoded:encrypted))
        let plain=try XCTUnwrap(SecKeyCreateDecryptedData(key,.rsaEncryptionPKCS1,cipher as CFData,&error)) as Data
        XCTAssertEqual(String(decoding:plain,as:UTF8.self),"sample-password")
        XCTAssertThrowsError(try RSAEncryption.encrypt("test",publicKey:"invalid"))
    }
    func testPrivateFileRejectsInsecureAndSymbolicFiles() throws {
        let temp=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temp) }
        let file=temp.appendingPathComponent("session.json")
        try PrivateFiles.write(Data("{}".utf8),to:file)
        XCTAssertEqual(try PrivateFiles.read(file),Data("{}".utf8))
        try FileManager.default.setAttributes([.posixPermissions:0o644],ofItemAtPath:file.path)
        XCTAssertThrowsError(try PrivateFiles.read(file))
        let link=temp.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:file)
        XCTAssertThrowsError(try PrivateFiles.read(link))
    }
    func testProxyUnwrapStopsAtEnginePayload() throws {
        let payload:JSON = .object(["myID":.string("test-id"),"data":.object(["unrelated":.bool(true)])])
        let encoded=String(decoding:try payload.data(),as:UTF8.self)
        XCTAssertEqual(NASClient.unwrapEngine(.object(["data":.object(["result":.string(encoded)])])),payload)
    }
}
