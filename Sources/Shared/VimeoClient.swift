//
//  VimeoClient.swift
//  VimeoNetworkingExample-iOS
//
//  Created by Huebner, Rob on 3/21/16.
//  Copyright © 2016 Vimeo. All rights reserved.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

import Foundation

/// `VimeoClient` handles a rich assortment of functionality focused around interacting with the Vimeo API.  A client object tracks an authenticated account, handles the low-level execution of requests through a session manager with caching functionality, presents a high-level `Request` and `Response` interface, and notifies of globally relevant events and errors through `Notification`s
/// To start using a client, first instantiate an `AuthenticationController` to load a stored account or authenticate a new one.  Next, create `Request` instances and pass them into the `request` function, which returns `Response`s on success.
final public class VimeoClient {
    // MARK: -
    
    /// `RequestToken` stores a reference to an in-flight request
    public struct RequestToken {

        /// The path of the request
        public let path: String?
        
        /// The data task of the request
        public let task: Task?

        /// Resumes the request token task
        public func resume() {
            self.task?.resume()
        }

        /// Cancels the request token task
        public func cancel() {
            self.task?.cancel()
        }
    }
    
    /// Dictionary containing URL parameters for a request
    public typealias RequestParametersDictionary = [String: Any]
    
    /// Array containing URL parameters for a request
    public typealias RequestParametersArray = [Any]
    
    /// Dictionary containing a JSON response
    public typealias ResponseDictionary = [String: Any]
    
    /// Domain for errors generated by `VimeoClient`
    public static let ErrorDomain = "VimeoClientErrorDomain"
    
    // MARK: -
    
    /// Session manager handles the http session data tasks and request/response serialization
    private var sessionManager: SessionManaging? = nil
    
    /// response cache handles all memory and disk caching of response dictionaries
    private let responseCache = ResponseCache()

    private var reachabilityManager: ReachabilityManaging?

    /// Create a new client
    ///
    /// - Parameters:
    ///   - appConfiguration: Your application's configuration
    ///   - configureSessionManagerBlock: a block to configure the session manager
    convenience public init(
        appConfiguration: AppConfiguration,
        reachabilityManager: ReachabilityManaging? = nil,
        configureSessionManagerBlock: ConfigureSessionManagerBlock? = nil
    ) {
        let reachabilityManager = reachabilityManager ?? VimeoReachabilityProvider.reachabilityManager
        let sessionManager = VimeoSessionManager.defaultSessionManager(
            appConfiguration: appConfiguration,
            configureSessionManagerBlock: configureSessionManagerBlock
        )
        self.init(
            appConfiguration: appConfiguration,
            reachabilityManager: reachabilityManager,
            sessionManager: sessionManager
        )
    }
    
    public init(
        appConfiguration: AppConfiguration? = nil,
        reachabilityManager: ReachabilityManaging? = nil,
        sessionManager: SessionManaging? = nil
    ) {
        let reachabilityManager = reachabilityManager ?? VimeoReachabilityProvider.reachabilityManager
        self.reachabilityManager = reachabilityManager
        if let appConfiguration = appConfiguration,
            let sessionManager = sessionManager {
            self.configuration = appConfiguration
            self.sessionManager = sessionManager
        }
    }
    
    // MARK: - Configuration
    
    /// The client's configuration
    public fileprivate(set) var configuration: AppConfiguration? = nil
    
    // MARK: - Authentication
    
    /// Stores the current account, if one exists
    public internal(set) var currentAccount: VIMAccount? {
        didSet {
            if let authenticatedAccount = self.currentAccount {
                self.sessionManager?.clientDidAuthenticate(with: authenticatedAccount)
            }
            else {
                self.sessionManager?.clientDidClearAccount()
            }
            
            self.notifyObserversAccountChanged(forAccount: self.currentAccount, previousAccount: oldValue)
        }
    }
    
    internal func notifyObserversAccountChanged(forAccount account: VIMAccount?, previousAccount: VIMAccount?) {
        NetworkingNotification.authenticatedAccountDidChange.post(object: account,
                                                        userInfo: [UserInfoKey.previousAccount.rawValue as String : previousAccount ?? NSNull()])
    }
}

// MARK: - Client configuration utility

extension VimeoClient {

    /// Configures a client instance and its associated session manager with the given configuration,
    /// reachability manager and an optional configuration block.
    /// - Parameter client: the `VimeoClient` instance to be configured
    /// - Parameter appConfiguration: the `AppConfiguration` object to be used by the client and associated session manager
    /// - Parameter reachabilityManager: the `ReachabilityManaging` instance to be used by the client and associated
    /// session to determine network reachability status. If none is provided the default reachability manager is used
    /// - Parameter configureSessionManagerBlock: An optional configuration block for the client's session manager
    ///
    /// Note that calling this method invalidates the `VimeoClient`'s existing session manager and creates
    /// a new instance with the given configuration.
    public static func configure(
        _ client: VimeoClient,
        appConfiguration: AppConfiguration,
        reachabilityManager: ReachabilityManaging? = nil,
        configureSessionManagerBlock: ConfigureSessionManagerBlock? = nil
    ) {
        let reachabilityManager = reachabilityManager ?? VimeoReachabilityProvider.reachabilityManager
        client.configuration = appConfiguration
        let defaultSessionManager = VimeoSessionManager.defaultSessionManager(
            appConfiguration: appConfiguration,
            configureSessionManagerBlock: configureSessionManagerBlock
        )
        client.sessionManager?.invalidate(cancelingPendingTasks: false)
        client.sessionManager = defaultSessionManager
        client.reachabilityManager = reachabilityManager
    }
}

// MARK: - Request
extension VimeoClient {
    /// Executes a `Request`
    ///
    /// - Parameters:
    ///   - request: `Request` object containing all the required URL and policy information
    ///   - startImmediately: a boolean indicating whether or not the request should resume immediately
    ///   - completionQueue: dispatch queue on which to execute the completion closure
    ///   - completion: a closure executed one or more times, containing a `Result`
    ///
    /// - Returns: a `RequestToken` for the in-flight request
    public func request<ModelType>(
        _ request: Request<ModelType>,
        startImmediately: Bool = true,
        completionQueue: DispatchQueue = .main,
        completion: @escaping ResultCompletion<Response<ModelType>, NSError>.T
    ) -> RequestToken {
        if request.useCache {
            return self.cachedResponse(
                for: request,
                completionQueue: completionQueue,
                then: completion
            )
        } else {
            let requestToken = self.create(
                request,
                completionQueue: completionQueue,
                then: completion
            )
            if startImmediately { requestToken.resume() }
            return requestToken
        }
    }

    /// Executes a `Request` encapsulated into an `EndpointType` and bound to a `Decodable` response.
    ///
    /// - Parameters:
    ///   - endpoint: `EndpointType` object containing the information required to build a request
    ///   - startImmediately: a boolean indicating whether or not the request should resume immediately
    ///   - completionQueue: dispatch queue on which to execute the callback closure
    ///   - callback: a closure executed once the request completes, containing a `Result` type
    ///   for the specified decodable.
    ///
    /// - Returns: a `RequestToken` for the in-flight request
    public func request<Model: Decodable>(
        _ endpoint: EndpointType,
        startImmediately: Bool = true,
        completionQueue: DispatchQueue = .main,
        then callback: @escaping (Result<Model, Error>) -> Void
    ) -> RequestToken {
        let task = self.sessionManager?.request(
            endpoint,
            parameters: nil,
            then: { (sessionManagingResult: SessionManagingResult<Model>) in
                completionQueue.async {
                    callback(sessionManagingResult.result)
                }
            }
        )
        if startImmediately { task?.resume() }
        return RequestToken(path: endpoint.path, task: task)
    }

    /// Removes any cached responses for a given `Request`
    /// - Parameters:
    ///   - key: the cache key for which to remove all cached responses
    public func removeCachedResponse(forKey key: String) {
        self.responseCache.removeResponse(forKey: key)
    }
    
    /// Clears a client's cache of all stored responses
    public func removeAllCachedResponses() {
        self.responseCache.clear()
    }
}

extension VimeoClient {

    // MARK: - Private network request handling

    private func create<ModelType>(
        _ request: Request<ModelType>,
        completionQueue: DispatchQueue,
        then callback: @escaping ResultCompletion<Response<ModelType>, NSError>.T
    ) -> RequestToken {
        let task = self.sessionManager?.request(
            request,
            parameters: request.parameters,
            then: { (sessionManagingResult: SessionManagingResult<JSON>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    switch sessionManagingResult.result {
                    case .success(let JSON):
                        self.handleTaskSuccess(
                            for: request,
                            urlRequest: sessionManagingResult.request,
                            responseObject: JSON,
                            completionQueue: completionQueue,
                            completion: callback
                        )
                    case .failure(let error):
                        self.handleTaskFailure(
                            for: request,
                            urlRequest: sessionManagingResult.request,
                            error: error as NSError,
                            completionQueue: completionQueue,
                            completion: callback
                        )
                    }
                }
            }
        )

        guard let requestTask = task else {
            let description = "Session manager did not return a task"
            assertionFailure(description)

            let error = NSError(
                domain: type(of: self).ErrorDomain,
                code: LocalErrorCode.requestMalformed.rawValue,
                userInfo: [NSLocalizedDescriptionKey: description]
            )
            self.handleTaskFailure(
                for: request,
                urlRequest: nil,
                error: error,
                completionQueue: completionQueue,
                completion: callback
            )
            return RequestToken(path: request.path, task: nil)
        }

        return RequestToken(path: request.path, task: requestTask)
    }

    // MARK: - Private cache response handling

    private func cachedResponse<ModelType>(
        for request: Request<ModelType>,
        completionQueue: DispatchQueue,
        then callback: @escaping ResultCompletion<Response<ModelType>, NSError>.T
    ) -> RequestToken {
        self.responseCache.response(forRequest: request) { result in
            switch result {
            case .success(let responseDictionary):
                if let responseDictionary = responseDictionary {
                    self.handleTaskSuccess(
                        for: request,
                        urlRequest: nil,
                        responseObject: responseDictionary,
                        isCachedResponse: true,
                        completionQueue: completionQueue,
                        completion: callback
                    )
                } else {
                    let error = NSError(
                        domain: type(of: self).ErrorDomain,
                        code: LocalErrorCode.cachedResponseNotFound.rawValue,
                        userInfo: [NSLocalizedDescriptionKey: "Cached response not found"]
                    )
                    self.handleError(error, request: request)

                    completionQueue.async {
                        callback(.failure(error))
                    }
                }

            case .failure(let error):
                self.handleError(error, request: request)

                completionQueue.async {
                    callback(.failure(error))
                }
            }
        }
        return RequestToken(path: request.path, task: nil)
    }

    // MARK: - Private task completion handlers
    
    private func handleTaskSuccess<ModelType>(
        for request: Request<ModelType>,
        urlRequest: URLRequest?,
        responseObject: Any,
        isCachedResponse: Bool = false,
        completionQueue: DispatchQueue,
        completion: @escaping ResultCompletion<Response<ModelType>, NSError>.T
    ) {
        guard
            let responseDictionary = responseObject as? ResponseDictionary,
            responseDictionary.isEmpty == false else {

            if ModelType.self == VIMNullResponse.self {
                let nullResponseObject = VIMNullResponse()
                
                // Swift complains that this cast always fails, but it doesn't seem to ever actually fail, and it's required to call completion with this response [RH] (4/12/2016)
                // It's also worth noting that (as of writing) there's no way to direct the compiler to ignore specific instances of warnings in Swift :S [RH] (4/13/16)
                let response = Response(model: nullResponseObject, json: [:]) as! Response<ModelType>

                completionQueue.async {
                    completion(.success(response as Response<ModelType>))
                }
            } else {
                let description = "VimeoClient requestSuccess returned invalid/absent dictionary"
                assertionFailure(description)
                let error = NSError(
                    domain: type(of: self).ErrorDomain,
                    code: LocalErrorCode.invalidResponseDictionary.rawValue,
                    userInfo: [NSLocalizedDescriptionKey: description]
                )
                self.handleTaskFailure(
                    for: request,
                    urlRequest: urlRequest,
                    error: error,
                    completionQueue: completionQueue,
                    completion: completion
                )
            }
            
            return
        }
        
        do {
            let modelObject: ModelType = try VIMObjectMapper.mapObject(responseDictionary: responseDictionary, modelKeyPath: request.modelKeyPath)
            
            var response: Response<ModelType>
            
            if let pagingDictionary = responseDictionary[.pagingKey] as? ResponseDictionary {
                let totalCount = responseDictionary[.totalKey] as? Int ?? 0
                let currentPage = responseDictionary[.pageKey] as? Int ?? 0
                let itemsPerPage = responseDictionary[.perPageKey] as? Int ?? 0
                
                var nextPageRequest: Request<ModelType>? = nil
                var previousPageRequest: Request<ModelType>? = nil
                var firstPageRequest: Request<ModelType>? = nil
                var lastPageRequest: Request<ModelType>? = nil
                
                if let nextPageLink = pagingDictionary[.nextKey] as? String {
                    nextPageRequest = request.associatedPageRequest(withNewPath: nextPageLink)
                }
                
                if let previousPageLink = pagingDictionary[.previousKey] as? String {
                    previousPageRequest = request.associatedPageRequest(withNewPath: previousPageLink)
                }
                
                if let firstPageLink = pagingDictionary[.firstKey] as? String {
                    firstPageRequest = request.associatedPageRequest(withNewPath: firstPageLink)
                }
                
                if let lastPageLink = pagingDictionary[.lastKey] as? String {
                    lastPageRequest = request.associatedPageRequest(withNewPath: lastPageLink)
                }
                
                response = Response<ModelType>(model: modelObject,
                                               json: responseDictionary,
                                               isCachedResponse: isCachedResponse,
                                               totalCount: totalCount,
                                               page: currentPage,
                                               itemsPerPage: itemsPerPage,
                                               nextPageRequest: nextPageRequest,
                                               previousPageRequest: previousPageRequest,
                                               firstPageRequest: firstPageRequest,
                                               lastPageRequest: lastPageRequest)
            }
            else {
                response = Response<ModelType>(model: modelObject, json: responseDictionary, isCachedResponse: isCachedResponse)
            }
            
            // To avoid a poisoned cache, explicitly wait until model object parsing is successful to store responseDictionary [RH]
            if request.cacheResponse {
                self.responseCache.setResponse(responseDictionary: responseDictionary, forRequest: request)
            }
            
            completionQueue.async {
                completion(.success(response))
            }
        }
        catch let error {
            self.responseCache.removeResponse(forKey: request.cacheKey)
            
            self.handleTaskFailure(
                for: request,
                urlRequest: urlRequest,
                error: error as NSError,
                completionQueue: completionQueue,
                completion: completion
            )
        }
    }
    
    private func handleTaskFailure<ModelType>(
        for request: Request<ModelType>,
        urlRequest: URLRequest?,
        error: NSError,
        completionQueue: DispatchQueue,
        completion: @escaping ResultCompletion<Response<ModelType>, NSError>.T
    ) {
        guard error.code != NSURLErrorCancelled else {
            // TODO: This error never gets propagated up the chain because we don't call the completion closure here.
            // We need to investigate whether adding the callback here will cause any unforeseen side effects on calling
            // sites before fixing it. [RDPA 10/16/2019]
            return
        }

        self.handleError(error, request: request, urlRequest: urlRequest)
        
        if case .multipleAttempts(let attemptCount, let initialDelay) = request.retryPolicy, attemptCount > 1 {
            var retryRequest = request
            
            retryRequest.retryPolicy = .multipleAttempts(attemptCount: attemptCount - 1, initialDelay: initialDelay * 2)
            
            DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + Double(Int64(initialDelay * Double(NSEC_PER_SEC))) / Double(NSEC_PER_SEC)) {
                let _ = self.request(retryRequest, completionQueue: completionQueue, completion: completion)
            }
        }
        
        completionQueue.async {
            completion(.failure(error))
        }
    }
    
    // MARK: - Private error handling
    
    private func handleError<ModelType>(
        _ error: NSError,
        request: Request<ModelType>,
        urlRequest: URLRequest? = nil
    ) {
        if error.isServiceUnavailableError {
            NetworkingNotification.clientDidReceiveServiceUnavailableError.post(object: nil)
        } else if error.isInvalidTokenError {
            NetworkingNotification.clientDidReceiveInvalidTokenError.post(object: self.token(from: urlRequest))
        }
    }
    
    private func token(from urlRequest: URLRequest?) -> String? {
        guard let bearerHeader = urlRequest?.allHTTPHeaderFields?[.authorizationHeader],
            let range = bearerHeader.range(of: String.bearerQuery) else {
            return nil
        }
        var str = bearerHeader
        str.removeSubrange(range)
        return str
    }
}

private extension String {
    // Auth Header constants
    static let bearerQuery = "Bearer "
    static let authorizationHeader = "Authorization"

    // Response Key constants
    static let pagingKey = "paging"
    static let totalKey = "total"
    static let pageKey = "page"
    static let perPageKey = "per_page"
    static let nextKey = "next"
    static let previousKey = "previous"
    static let firstKey = "first"
    static let lastKey = "last"
}
