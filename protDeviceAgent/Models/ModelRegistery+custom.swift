import MLXLLM
import MLXLMCommon

extension ModelRegistry {
 
    static let gemma_2_2b_it_4bit = ModelConfiguration(
        id: "mlx-community/gemma-2-2b-it-4bit",
        overrideTokenizer: "PreTrainedTokenizer",
        defaultPrompt: "Translate the following sentence from English to Italian: 'The quick brown fox jumps over the lazy dog.'"
    )
    
    func registerCustomModels() {
        register(configurations: [
            ModelRegistry.gemma_2_2b_it_4bit,
           
        ])
    }
}
