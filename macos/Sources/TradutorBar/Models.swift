import Foundation

// Só os campos que o menu usa: o resto do contrato pode mudar sem quebrar a decodificação.

struct EngineStatus: Decodable, Equatable, Sendable {
    struct Jobs: Decodable, Equatable, Sendable {
        let current: Job?
        let queued: [Job]
        /// Opcional para o app continuar funcionando com um motor mais antigo, que não manda o histórico.
        let recent: [Job]?
    }

    struct Cookies: Decodable, Equatable, Sendable {
        let present: Bool
        var browser: String? = nil
        /// nil = o motor ainda não tentou ler os cookies do navegador nesta execução.
        var browserOk: Bool? = nil
    }

    let version: String
    let jobs: Jobs
    let cacheBytes: Int64
    let settings: EngineSettings
    let voices: [String: String]
    var cookies: Cookies? = nil
}

struct Job: Decodable, Equatable, Sendable, Identifiable {
    let id: String
    let videoId: String
    let stageLabel: String?
    let progress: Double?
    let title: String?
    var status: String? = nil
    var error: String? = nil
    var report: JobReport? = nil
    var finishedAt: Double? = nil
}

struct JobReport: Decodable, Equatable, Sendable {
    var tempoTotalS: Double? = nil
    var traducao: String? = nil
    var aviso: String? = nil
}

struct EngineSettings: Decodable, Equatable, Sendable {
    var voice: String
    var translator: String
    var ollamaFallback: Bool
    var ollamaAssist: Bool
    var useCookies: Bool
    var cacheLimitGb: Double? = nil
    var cookiesFromBrowser: String? = nil
    var voiceOffsetDb: Double? = nil
    var uiAccent: String? = nil
}

struct Health: Decodable, Sendable {
    let ok: Bool
}

struct CacheCleared: Decodable, Sendable {
    let freedBytes: Int64
}

struct JobCancelled: Decodable, Sendable {
    let cancelled: Bool
}

struct VoiceOption: Identifiable, Equatable {
    let id: String
    let name: String
}
