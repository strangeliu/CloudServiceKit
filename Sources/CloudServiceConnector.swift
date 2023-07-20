//
//  CloudServiceConnector.swift
//  CloudServiceKit
//
//  Created by alexiscn on 2021/8/26.
//

import Foundation
import OAuthSwift
import CryptoKit
import AuthenticationServices
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import class AppKit.NSViewController
#endif

#if canImport(UIKit)
public typealias PlatformController = UIViewController
#elseif canImport(AppKit)
public typealias PlatformController = NSViewController
#endif

public protocol CloudServiceOAuth {
    
    var authorizeUrl: String { get }
    
    var accessTokenUrl: String { get }

}

class CancelHanlder: @unchecked Sendable {
    
    var handler: (() -> Void)?
    
    init() {
        
    }
}

/// The base connector provided by CloudService.
/// CloudServiceKit provides a default connector for each cloud service, such as `DropboxConnector`.
/// You can implement your own connector if you want customizations.
public class CloudServiceConnector: CloudServiceOAuth {
    
    /// subclass must provide authorizeUrl
    public var authorizeUrl: String { return "" }
    
    /// subclass must provide accessTokenUrl
    public var accessTokenUrl: String { return "" }
    
    /// subclass can provide more custom parameters
    public var authorizeParameters: OAuthSwift.Parameters { return [:] }
    
    public var tokenParameters: OAuthSwift.Parameters { return [:] }
    
    public var scope: String = ""
    
    public var responseType: String
    
#if !os(tvOS)
    public weak var presentationContextProvider: ASWebAuthenticationPresentationContextProviding?
#endif
    
    /// The appId or appKey of your service.
    let appId: String
    
    /// The app scret of your service.
    let appSecret: String
    
    /// The redirectUrl.
    let callbackUrl: String
    
    public let state: String
    
    var oauth: OAuth2Swift?
    
    
    /// Create cloud service connector
    /// - Parameters:
    ///   - appId: The appId.
    ///   - appSecret: The app secret.
    ///   - callbackUrl: The redirect url
    ///   - responseType: The response type.  The default value is `code`.
    ///   - scope: The scope your app use for the service.
    ///   - state: The state information. The default value is empty.
    public init(appId: String, appSecret: String, callbackUrl: String, responseType: String = "code", scope: String = "", state: String = "") {
        self.appId = appId
        self.appSecret = appSecret
        self.callbackUrl = callbackUrl
        self.responseType = responseType
        self.scope = scope
        self.state = state
    }
    
    func generateCodeVerifier(length: Int) -> String {
        var data = Data(count: length)
        let result = data.withUnsafeMutableBytes { mutableBytes in
            SecRandomCopyBytes(kSecRandomDefault, length, mutableBytes.baseAddress!)
        }

        if result == errSecSuccess {
            return data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        } else {
            return ""
        }
    }
    
    func generateCodeChallenge(from codeVerifier: String) -> String {
        let codeVerifierData = Data(codeVerifier.utf8)
        let codeVerifierHash = SHA256.hash(data: codeVerifierData)
        let codeChallenge = Data(codeVerifierHash).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return codeChallenge
    }
    
    @discardableResult
    public func connect(completion: @escaping (Result<OAuthSwift.TokenSuccess, Error>) -> Void) -> OAuthSwiftRequestHandle? {
        let oauth = OAuth2Swift(consumerKey: appId, consumerSecret: appSecret, authorizeUrl: authorizeUrl, accessTokenUrl: accessTokenUrl, responseType: responseType, contentType: nil)
#if os(iOS)
        oauth.authorizeURLHandler = WebAuthenticationURLHandler(callbackUrlScheme: callbackUrl, presentationContextProvider: presentationContextProvider, prefersEphemeralWebBrowserSession: false)
#endif
        oauth.allowMissingStateCheck = true
        self.oauth = oauth
        let codeVerifier = generateCodeVerifier(length: 64)
        let challenge = generateCodeChallenge(from: codeVerifier)
        return oauth.authorize(withCallbackURL: URL(string: callbackUrl)!, scope: scope, state: state, codeChallenge: challenge, codeVerifier: codeVerifier, parameters: authorizeParameters) { result in
            switch result {
            case .success(let token):
                completion(.success(token))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    
    @MainActor
    public func connect() async throws -> OAuthSwift.TokenSuccess {
        let cancelHandler = CancelHanlder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let handler = self.connect { result in
                    continuation.resume(with: result)
                }
                cancelHandler.handler = {
                    handler?.cancel()
                }
            }
        } onCancel: {
            cancelHandler.handler?()
        }
    }
    
    public func renewToken(with refreshToken: String, completion: @escaping (Result<OAuthSwift.TokenSuccess, Error>) -> Void) {
        let oauth = OAuth2Swift(consumerKey: appId, consumerSecret: appSecret, authorizeUrl: authorizeUrl, accessTokenUrl: accessTokenUrl, responseType: responseType, contentType: nil)
        oauth.allowMissingStateCheck = true
        oauth.renewAccessToken(withRefreshToken: refreshToken, parameters: tokenParameters) { result in
            switch result {
            case .success(let token):
                completion(.success(token))
            case .failure(let error):
                completion(.failure(error))
            }
        }
        self.oauth = oauth
    }
}

// MARK: - CloudServiceProviderDelegate
extension CloudServiceConnector: CloudServiceProviderDelegate {
    
    public func renewAccessToken(withRefreshToken refreshToken: String, completion: @escaping (Result<URLCredential, Error>) -> Void) {
        renewToken(with: refreshToken) { result in
            switch result {
            case .success(let token):
                let credential = URLCredential(user: "user", password: token.credential.oauthToken, persistence: .permanent)
                completion(.success(credential))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    
}

// MARK: - BaiduPanConnector
public class BaiduPanConnector: CloudServiceConnector {
    
    /// The OAuth2 url, which is `https://openapi.baidu.com/oauth/2.0/authorize`.
    public override var authorizeUrl: String {
#if canImport(UIKit)
        if UIScreen.main.traitCollection.userInterfaceIdiom == .pad {
            return "https://openapi.baidu.com/oauth/2.0/authorize?display=pad&force_login=1"
        } else {
            return "https://openapi.baidu.com/oauth/2.0/authorize?display=mobile&force_login=1"
        }
#else
        return "https://openapi.baidu.com/oauth/2.0/authorize?display=pc&force_login=1"
#endif
    }
    
    /// The access token url, which is `https://openapi.baidu.com/oauth/2.0/token`.
    public override var accessTokenUrl: String {
        return "https://openapi.baidu.com/oauth/2.0/token"
    }
    
    /// The scope to access baidu pan service. The default and only value is `basic,netdisk`.
    public override var scope: String {
        get { return "basic,netdisk" }
        set {  }
    }
}

// MARK: - BoxConnector
public class BoxConnector: CloudServiceConnector {
    
    public override var authorizeUrl: String {
        return "https://account.box.com/api/oauth2/authorize"
    }
    
    public override var accessTokenUrl: String {
        return "https://api.box.com/oauth2/token"
    }
    
    private var defaultScope = "root_readwrite"
    public override var scope: String {
        get { return defaultScope }
        set { defaultScope = newValue }
    }
}

// MARK: - DropboxConnector
public class DropboxConnector: CloudServiceConnector {
    
    public override var authorizeUrl: String {
        return "https://www.dropbox.com/oauth2/authorize?token_access_type=offline"
    }
    
    public override var accessTokenUrl: String {
        return "https://api.dropbox.com/oauth2/token"
    }
}

// MARK: - GoogleDriveConnector
public class GoogleDriveConnector: CloudServiceConnector {
    
    public override var authorizeUrl: String {
        return "https://accounts.google.com/o/oauth2/auth"
    }
    
    public override var accessTokenUrl: String {
        return "https://accounts.google.com/o/oauth2/token"
    }
    
    private var defaultScope = "https://www.googleapis.com/auth/drive https://www.googleapis.com/auth/userinfo.profile"
    public override var scope: String {
        get { return defaultScope }
        set { defaultScope = newValue }
    }
}


// MARK: - OneDriveConnector
public class OneDriveConnector: CloudServiceConnector {

    public override var authorizeUrl: String {
        return "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
    }

    public override var accessTokenUrl: String {
        return "https://login.microsoftonline.com/common/oauth2/v2.0/token"
    }

    private var defaultScope = "offline_access User.Read Files.ReadWrite.All"
    /// The scope to access OneDrive service. The default value is `offline_access User.Read Files.ReadWrite.All`.
    public override var scope: String {
        get { return defaultScope }
        set { defaultScope = newValue }
    }
}

// MARK: - PCloudConnector
public class PCloudConnector: CloudServiceConnector {
    
    public override var authorizeUrl: String {
        return "https://my.pcloud.com/oauth2/authorize"
    }
    
    public override var accessTokenUrl: String {
        return "https://api.pcloud.com/oauth2_token"
    }
    
    public override func renewToken(with refreshToken: String, completion: @escaping (Result<OAuthSwift.TokenSuccess, Error>) -> Void) {
        // pCloud OAuth does not respond with a refresh token, so renewToken is unsupported.
        completion(.failure(CloudServiceError.unsupported))
    }
}

extension CloudServiceConnector {
    
    public func renewToken(with refreshToken: String) async throws -> OAuthSwift.TokenSuccess {
        try await withCheckedThrowingContinuation { continuation in
            renewToken(with: refreshToken) { result in
                continuation.resume(with: result)
            }
        }
    }
}
