import AsyncHTTPClient
import AWSSDKSwiftCore
import Foundation
import JWTKit
import NIO

/// struct returned when authenticating an access token
public struct AWSCognitoAccessToken: Codable {
    public let username: String
    public let subject: UUID
    public let expirationTime: Date

    private enum CodingKeys: String, CodingKey {
        case username = "username"
        case subject = "sub"
        case expirationTime = "exp"
    }
}

/// Public interface functions for authenticating with CognitoIdentityProvider access and id tokens
public extension AWSCognitoAuthenticatable {
    /// Verify id Token JWT and return contents
    ///
    /// This function verifies the id token signature, verifies it was issued by your user pool, it was generated for your application client, that it hasn't
    /// expired and that it is an id token.
    /// Then it fills out the placeholder type `Payload`with values from the id token. The list of standard list of claims found in an id token are
    /// detailed in the [OpenID spec](https://openid.net/specs/openid-connect-core-1_0.html#StandardClaims) . Your
    /// `Payload` type needs to decode using these tags, plus the AWS specific "cognito:username" tag and any custom tags you have setup
    /// for the user pool.
    /// - parameters:
    ///     - idToken: Id token, returned from login
    ///     - on: Event loop to run on
    /// - returns:
    ///     An event loop future containing the payload structure.
    func authenticate<Payload: Codable>(idToken: String, on eventLoopGroup: EventLoopGroup) -> EventLoopFuture<Payload> {
        return loadSigners(region: configuration.region, on: eventLoopGroup)
            .flatMapThrowing { signers in
                let jwtPayload = try signers.verify(idToken, as: VerifiedToken<IdTokenVerifier, Payload>.self)
                guard jwtPayload.token.audience == self.configuration.clientId else {throw AWSCognitoError.unauthorized(reason:"invalid token")}
                guard jwtPayload.token.issuer == "https://cognito-idp.\(self.configuration.region.rawValue).amazonaws.com/\(self.configuration.userPoolId)" else {
                    throw AWSCognitoError.unauthorized(reason:"invalid token")
                }
                return jwtPayload.payload
        }
    }

    /// Verify access token JWT and return contents
    ///
    /// This function verifies the access token signature, verifies it was issued by your user pool, that it hasn't expired and that it is an access token.
    /// - parameters:
    ///     - accessToken: Access token, returned from login
    ///     - on: Event loop to run on
    /// - returns:
    ///     An event loop future returning a structure with the username and UUID for the user.
    func authenticate(accessToken: String, on eventLoopGroup: EventLoopGroup) -> EventLoopFuture<AWSCognitoAccessToken> {
        return loadSigners(region: configuration.region, on: eventLoopGroup)
            .flatMapThrowing { signers in
                let jwtPayload = try signers.verify(accessToken, as: VerifiedToken<AccessTokenVerifier, AWSCognitoAccessToken>.self)
                guard jwtPayload.token.issuer == "https://cognito-idp.\(self.configuration.region.rawValue).amazonaws.com/\(self.configuration.userPoolId)" else {
                    throw AWSCognitoError.unauthorized(reason:"invalid token")
                }
                return jwtPayload.payload
        }
    }
}

extension AWSCognitoAuthenticatable {
    /// load JSON web keys and create JWT signers from them
    func loadSigners(region: Region, on eventLoopGroup: EventLoopGroup) -> EventLoopFuture<JWTSigners> {
        // check we haven't already loaded the jwt signing key set
        guard jwtSigners == nil else { return eventLoopGroup.next().makeSucceededFuture(jwtSigners!)}

        let JWTSignersURL = "https://cognito-idp.\(configuration.region.rawValue).amazonaws.com/\(configuration.userPoolId)/.well-known/jwks.json"
        let httpClient = AsyncHTTPClient.HTTPClient(eventLoopGroupProvider:.shared(eventLoopGroup))
        return httpClient
            .get(url: JWTSignersURL, deadline: .now() + TimeAmount.seconds(10))
            .always { _ in try? httpClient.syncShutdown() }
            .flatMapThrowing { response in
                let signers = JWTSigners()
                guard let body = response.body else { return JWTSigners() }
                if let data = body.getString(at: body.readerIndex, length: body.readableBytes) {
                    try signers.use(jwksJSON: data)
                }
                return signers
        }
        
    }
}