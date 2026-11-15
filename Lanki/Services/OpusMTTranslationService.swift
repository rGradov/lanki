import Foundation
import OnnxRuntimeBindings
import Tokenizers

/// On-device English ↔ Russian translation with the downloaded Opus-MT models.
final class OpusMTTranslationService: TranslationService {
    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranslationError.empty }
        guard let direction = OpusDirection.matching(from: source, to: target) else {
            throw TranslationError.api("Opus-MT supports only English and Russian.")
        }
        guard OpusMTModelStore.directionIsReady(direction) else {
            throw TranslationError.api("Download the Opus-MT model in Settings → API Keys.")
        }
        return try await OpusMTEngine.shared.translate(trimmed, direction: direction)
    }
}

/// Loads one direction at a time and runs a short greedy decode.
final class OpusMTEngine: @unchecked Sendable {
    static let shared = OpusMTEngine()

    private let queue = DispatchQueue(label: "lanki.opus-mt")
    private var env: ORTEnv?
    private var loaded: [String: LoadedDirection] = [:]

    func reset() {
        queue.sync { loaded.removeAll() }
    }

    func translate(_ text: String, direction: OpusDirection) async throws -> String {
        let loaded = try await load(direction)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try Self.generate(text, model: loaded))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func load(_ direction: OpusDirection) async throws -> LoadedDirection {
        if let cached = queue.sync(execute: { loaded[direction.folder] }) {
            return cached
        }
        let folder = OpusMTModelStore.directory(for: direction)
        let tokenizer = try await AutoTokenizer.from(modelFolder: folder)
        let config = try Self.readConfig(in: folder)
        let environment = try queue.sync { () -> ORTEnv in
            if let env { return env }
            let created = try ORTEnv(loggingLevel: .warning)
            env = created
            return created
        }
        let options = try ORTSessionOptions()
        try options.setGraphOptimizationLevel(.all)
        try options.setIntraOpNumThreads(2)
        let encoder = try ORTSession(
            env: environment,
            modelPath: folder.appendingPathComponent("encoder.onnx").path,
            sessionOptions: options
        )
        let decoder = try ORTSession(
            env: environment,
            modelPath: folder.appendingPathComponent("decoder.onnx").path,
            sessionOptions: options
        )
        let model = LoadedDirection(
            tokenizer: tokenizer,
            config: config,
            encoder: encoder,
            decoder: decoder,
            encoderInputs: try encoder.inputNames(),
            encoderOutputs: try encoder.outputNames(),
            decoderInputs: try decoder.inputNames(),
            decoderOutputs: try decoder.outputNames()
        )
        queue.sync { loaded[direction.folder] = model }
        return model
    }

    private static func readConfig(in folder: URL) throws -> OpusGenConfig {
        let data = try Data(contentsOf: folder.appendingPathComponent("config.json"))
        return try JSONDecoder().decode(OpusGenConfig.self, from: data)
    }

    private static func generate(_ text: String, model: LoadedDirection) throws -> String {
        var source = model.tokenizer.encode(text: text, addSpecialTokens: true)
        if source.count > 128 {
            source = Array(source.prefix(127))
        }
        if source.last != model.config.eosTokenId {
            source.append(model.config.eosTokenId)
        }
        guard !source.isEmpty else { throw TranslationError.empty }

        let mask = Array(repeating: Int64(1), count: source.count)
        let ids = source.map { Int64($0) }
        var retained: [NSMutableData] = []
        let encoderInputs = try tensors(
            names: model.encoderInputs,
            ids: ids,
            mask: mask,
            hidden: nil,
            retained: &retained
        )
        guard let encoderOutName = model.encoderOutputs.first else { throw TranslationError.empty }
        let encoded = try model.encoder.run(
            withInputs: encoderInputs,
            outputNames: Set([encoderOutName]),
            runOptions: nil
        )
        guard let hiddenValue = encoded[encoderOutName] else { throw TranslationError.empty }
        let hidden = try copyTensor(hiddenValue)

        var generated: [Int] = [model.config.decoderStartTokenId]
        let stepLimit = 64
        for _ in 0..<stepLimit {
            let decoderIDs = generated.map { Int64($0) }
            let decoderMask = Array(repeating: Int64(1), count: source.count)
            let decoderInputs = try tensors(
                names: model.decoderInputs,
                ids: decoderIDs,
                mask: decoderMask,
                hidden: hidden,
                retained: &retained
            )
            guard let logitsName = model.decoderOutputs.first else { throw TranslationError.empty }
            let decoded = try model.decoder.run(
                withInputs: decoderInputs,
                outputNames: Set([logitsName]),
                runOptions: nil
            )
            guard let logitsValue = decoded[logitsName] else { throw TranslationError.empty }
            let next = try argmaxLastRow(logitsValue, vocab: model.config.vocabSize, skip: model.config.padTokenId)
            if next == model.config.eosTokenId { break }
            generated.append(next)
        }

        let content = Array(generated.dropFirst())
        let text = model.tokenizer.decode(tokens: content, skipSpecialTokens: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranslationError.empty }
        return text
    }

    private static func tensors(
        names: [String],
        ids: [Int64],
        mask: [Int64],
        hidden: NSMutableData?,
        retained: inout [NSMutableData]
    ) throws -> [String: ORTValue] {
        var values: [String: ORTValue] = [:]
        for name in names {
            switch name {
            case "input_ids", "decoder_input_ids":
                values[name] = try int64Tensor(ids, retained: &retained)
            case "encoder_attention_mask":
                values[name] = try int64Tensor(mask, retained: &retained)
            case "attention_mask":
                let maskValues = hidden == nil ? mask : Array(repeating: Int64(1), count: ids.count)
                values[name] = try int64Tensor(maskValues, retained: &retained)
            case "encoder_hidden_states":
                guard let hidden else { throw TranslationError.api("Opus-MT decoder is missing the encoder state.") }
                retained.append(hidden)
                let sequence = mask.count
                let width = hidden.length / MemoryLayout<Float>.size / max(sequence, 1)
                values[name] = try ORTValue(
                    tensorData: hidden,
                    elementType: .float,
                    shape: [1, NSNumber(value: sequence), NSNumber(value: width)]
                )
            default:
                break
            }
        }
        if values["input_ids"] == nil && values["decoder_input_ids"] == nil {
            throw TranslationError.api("Opus-MT model inputs were not recognized.")
        }
        return values
    }

    private static func int64Tensor(_ values: [Int64], retained: inout [NSMutableData]) throws -> ORTValue {
        let data = NSMutableData()
        values.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            data.append(base, length: buffer.count * MemoryLayout<Int64>.size)
        }
        retained.append(data)
        return try ORTValue(
            tensorData: data,
            elementType: .int64,
            shape: [1, NSNumber(value: values.count)]
        )
    }

    private static func copyTensor(_ value: ORTValue) throws -> NSMutableData {
        let data = try value.tensorData()
        return NSMutableData(data: data as Data)
    }

    private static func argmaxLastRow(_ value: ORTValue, vocab: Int, skip: Int) throws -> Int {
        let info = try value.tensorTypeAndShapeInfo()
        guard info.elementType == .float else {
            throw TranslationError.api("Opus-MT returned an unexpected score type.")
        }
        let shape = info.shape.map(\.intValue)
        let data = try value.tensorData()
        guard shape.count >= 2 else { throw TranslationError.empty }
        let rows = shape[shape.count - 2]
        let columns = shape[shape.count - 1]
        guard rows > 0, columns > 0 else { throw TranslationError.empty }
        let scores = data.mutableBytes.bindMemory(to: Float.self, capacity: data.length / MemoryLayout<Float>.size)
        let row = (rows - 1) * columns
        var best = 0
        var bestScore = -Float.greatestFiniteMagnitude
        let limit = min(columns, max(vocab, columns))
        for index in 0..<limit {
            if index == skip { continue }
            let score = scores[row + index]
            if score > bestScore {
                bestScore = score
                best = index
            }
        }
        return best
    }
}

private struct OpusGenConfig: Decodable {
    let eosTokenId: Int
    let padTokenId: Int
    let decoderStartTokenId: Int
    let vocabSize: Int

    enum CodingKeys: String, CodingKey {
        case eosTokenId = "eos_token_id"
        case padTokenId = "pad_token_id"
        case decoderStartTokenId = "decoder_start_token_id"
        case vocabSize = "vocab_size"
    }
}

private struct LoadedDirection {
    let tokenizer: any Tokenizer
    let config: OpusGenConfig
    let encoder: ORTSession
    let decoder: ORTSession
    let encoderInputs: [String]
    let encoderOutputs: [String]
    let decoderInputs: [String]
    let decoderOutputs: [String]
}
