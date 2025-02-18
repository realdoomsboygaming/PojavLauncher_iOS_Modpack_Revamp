import Foundation

class CurseForgeAPI {

    private let apiKey: String

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    // Helper method to perform GET request
    private func performGETRequest(url: URL, completion: @escaping (Data?, Error?) -> Void) {
        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            if let error = error {
                completion(nil, error)
                return
            }
            completion(data, nil)
        }
        task.resume()
    }

    // Helper method to perform POST request
    private func performPOSTRequest(url: URL, parameters: [String: Any], completion: @escaping (Data?, Error?) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: parameters, options: [])
        } catch {
            completion(nil, error)
            return
        }
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(nil, error)
                return
            }
            completion(data, nil)
        }
        task.resume()
    }

    // Fetch mod details
    func getModDetails(modId: Int, completion: @escaping (ModDetails?, Error?) -> Void) {
        let urlString = "https://api.curseforge.com/v1/mods/\(modId)"
        guard let url = URL(string: urlString) else {
            completion(nil, NSError(domain: "Invalid URL", code: 400, userInfo: nil))
            return
        }
        
        performGETRequest(url: url) { data, error in
            if let error = error {
                completion(nil, error)
                return
            }
            
            guard let data = data else {
                completion(nil, NSError(domain: "No Data", code: 404, userInfo: nil))
                return
            }
            
            do {
                let decoder = JSONDecoder()
                let modDetails = try decoder.decode(ModDetails.self, from: data)
                completion(modDetails, nil)
            } catch {
                completion(nil, error)
            }
        }
    }

    // Search for mods with filters
    func searchModsWithFilters(filters: [String: Any], completion: @escaping ([Mod]?, Error?) -> Void) {
        let urlString = "https://api.curseforge.com/v1/mods/search"
        guard let url = URL(string: urlString) else {
            completion(nil, NSError(domain: "Invalid URL", code: 400, userInfo: nil))
            return
        }
        
        performPOSTRequest(url: url, parameters: filters) { data, error in
            if let error = error {
                completion(nil, error)
                return
            }
            
            guard let data = data else {
                completion(nil, NSError(domain: "No Data", code: 404, userInfo: nil))
                return
            }
            
            do {
                let decoder = JSONDecoder()
                let response = try decoder.decode(ModSearchResponse.self, from: data)
                completion(response.mods, nil)
            } catch {
                completion(nil, error)
            }
        }
    }

    // Install modpack
    func installModpack(modpackId: Int, completion: @escaping (Bool, Error?) -> Void) {
        let urlString = "https://api.curseforge.com/v1/modpacks/\(modpackId)/install"
        guard let url = URL(string: urlString) else {
            completion(false, NSError(domain: "Invalid URL", code: 400, userInfo: nil))
            return
        }
        
        let parameters: [String: Any] = ["modpackId": modpackId]
        
        performPOSTRequest(url: url, parameters: parameters) { data, error in
            if let error = error {
                completion(false, error)
                return
            }
            
            guard let data = data else {
                completion(false, NSError(domain: "No Data", code: 404, userInfo: nil))
                return
            }
            
            // Handle the response, e.g., check if the installation was successful
            do {
                let decoder = JSONDecoder()
                let response = try decoder.decode(InstallResponse.self, from: data)
                completion(response.success, nil)
            } catch {
                completion(false, error)
            }
        }
    }
}

// Model for the mod details response
struct ModDetails: Codable {
    let id: Int
    let name: String
    let description: String
}

// Model for the mod search response
struct ModSearchResponse: Codable {
    let mods: [Mod]
}

// Model for individual mod details in search results
struct Mod: Codable {
    let id: Int
    let name: String
    let slug: String
    let downloads: Int
}

// Model for the install response
struct InstallResponse: Codable {
    let success: Bool
}

// Example usage of CurseForgeAPI to fetch mod details
let curseForgeAPI = CurseForgeAPI(apiKey: "YOUR_API_KEY_HERE")

// Fetch mod details
curseForgeAPI.getModDetails(modId: 1234) { modDetails, error in
    if let error = error {
        print("Error fetching mod details: \(error)")
    } else if let modDetails = modDetails {
        print("Mod Name: \(modDetails.name), Description: \(modDetails.description)")
    }
}

// Example usage of searching for mods with filters
let filters: [String: Any] = ["category": "Adventure", "gameVersion": "1.16.5"]
curseForgeAPI.searchModsWithFilters(filters: filters) { mods, error in
    if let error = error {
        print("Error searching for mods: \(error)")
    } else if let mods = mods {
        for mod in mods {
            print("Mod Name: \(mod.name), Downloads: \(mod.downloads)")
        }
    }
}

// Example usage of installing a modpack
curseForgeAPI.installModpack(modpackId: 5678) { success, error in
    if let error = error {
        print("Error installing modpack: \(error)")
    } else if success {
        print("Modpack installed successfully!")
    }
}
