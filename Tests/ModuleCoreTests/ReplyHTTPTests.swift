import XCTest
@testable import ModuleApp

private final class ReplyHTTPFixture: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int,Data))?
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        do {
            guard let handler=Self.handler else { throw GoogleFailure.malformed }
            let (code,data)=try handler(request)
            let response=HTTPURLResponse(url:request.url!,statusCode:code,httpVersion:nil,headerFields:["Content-Type":"application/json"] )!
            client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self,didFailWithError:error) }
    }
    override func stopLoading() {}
}
final class ReplyHTTPTests:XCTestCase {
    func http() -> GoogleHTTP {
        let configuration=URLSessionConfiguration.ephemeral;configuration.protocolClasses=[ReplyHTTPFixture.self]
        return GoogleHTTP(configuration:configuration)
    }
    func credential(_ readonly:Bool) -> GoogleCredential {
        .init(accessToken:"authored-fixture-token",refreshToken:"authored-fixture-refresh",expiresAt:Date().addingTimeInterval(3600),scopes:Set([GoogleService.gmail.scope]+(readonly ? ["https://www.googleapis.com/auth/gmail.readonly"] : [])),email:"owner@example.test",subject:"fixture-account",client:.init(clientID:"fixture.apps.googleusercontent.com",clientSecret:nil))
    }
    func testMetadataOnlyAccountCannotFetchBody() async throws {
        var requests=0;ReplyHTTPFixture.handler={ _ in requests+=1;throw GoogleFailure.malformed }
        defer { ReplyHTTPFixture.handler=nil }
        let api=GoogleAPI(credential:credential(false),http:http(),save:{ _ in XCTFail("No credential changes") })
        do { _=try await api.replyMessage("abc123");XCTFail("Body read without separate scope") } catch { XCTAssertEqual(error as? GoogleFailure,.missingScope) }
        XCTAssertEqual(requests,0);await api.invalidate()
    }
    func testSelectedMessageUsesOnlyExactReadRequestAndNoMutation() async throws {
        var requests=0
        ReplyHTTPFixture.handler={ request in
            requests+=1;XCTAssertEqual(request.httpMethod,"GET");XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.url?.host,"gmail.googleapis.com");XCTAssertEqual(request.url?.path,"/gmail/v1/users/me/messages/abc123")
            XCTAssertEqual(URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems,[.init(name:"format",value:"full")])
            return (200,Data(#"{"id":"abc123","threadId":"def456","payload":{"mimeType":"text/plain","body":{"data":"SGVsbG8"}}}"#.utf8))
        };defer { ReplyHTTPFixture.handler=nil }
        let api=GoogleAPI(credential:credential(true),http:http(),save:{ _ in XCTFail("No credential changes") })
        let message=try await api.replyMessage("abc123")
        XCTAssertEqual(try message.payload?.plain(),"Hello");XCTAssertEqual(requests,1);await api.invalidate()
    }
    func testOversizedReplyResponseAndWrongMessageIdentityRefuse() async throws {
        for oversized in [true,false] {
            ReplyHTTPFixture.handler={ _ in (200,oversized ? Data(repeating:32,count:262_145) : Data(#"{"id":"bad123"}"#.utf8)) }
            let api=GoogleAPI(credential:credential(true),http:http(),save:{ _ in })
            do { _=try await api.replyMessage("abc123");XCTFail("Invalid response accepted") } catch {}
            await api.invalidate()
        }
        ReplyHTTPFixture.handler=nil
    }
}
