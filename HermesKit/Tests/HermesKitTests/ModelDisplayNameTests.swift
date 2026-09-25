import Testing
@testable import HermesKit

/// Mirrors the desktop's `model-status-label.test.ts` so both apps name a model the same way.
struct ModelDisplayNameTests {
  @Test func anthropicIdsDropProviderPrefixDatePinAndDotTheVersion() {
    #expect(ModelDisplayName.label("claude/claude-opus-5-5") == "Opus 5.5")
    #expect(ModelDisplayName.label("claude-opus-4-5-20251101") == "Opus 4.5")
    #expect(ModelDisplayName.label("anthropic/claude-haiku-4-5-20251001") == "Haiku 4.5")
    #expect(ModelDisplayName.label("claude-fable-5-1") == "Fable 5.1")
  }

  @Test func contextWindowSuffixBecomesATagNotBrackets() {
    #expect(ModelDisplayName.parts("claude-sonnet-5[1m]") == .init(name: "Sonnet 5", tag: "1M"))
    #expect(!ModelDisplayName.label("claude-opus-5[1m]").contains("["))
  }

  @Test func localGGUFIdsGetACleanNameAndQuantTag() {
    #expect(ModelDisplayName.parts("Qwen3.6-27B-UD-Q4_K_XL") == .init(name: "Qwen3.6 27B", tag: "Q4"))
    #expect(ModelDisplayName.parts("Qwen3-4B-Instruct-2507-UD-Q8_K_XL") == .init(name: "Qwen3 4B", tag: "Q8"))
    #expect(ModelDisplayName.parts("some-model-Q6_K") == .init(name: "Some Model", tag: "Q6"))
  }

  @Test func variantSuffixesAreTagsSoDistinctIdsDontCollapse() {
    #expect(ModelDisplayName.parts("anthropic/claude-opus-4.8-fast") == .init(name: "Opus 4.8", tag: "Fast"))
    #expect(ModelDisplayName.label("anthropic/claude-opus-4.8-fast") == "Opus 4.8 · Fast")
  }

  @Test func otherFamilies() {
    #expect(ModelDisplayName.label("openai/gpt-5.5") == "GPT-5.5")
    #expect(ModelDisplayName.label("gemini-3-pro") == "Gemini 3 pro")
    #expect(ModelDisplayName.label("ollama-cloud/glm-5.3-flash") == "Glm 5.3 Flash")
    #expect(ModelDisplayName.label("kimi-k3") == "Kimi K3")
    // Byte-identical to the desktop even where its heuristic is clumsy (checked against
    // `modelDisplayParts` under tsx): parity beats a mobile-only "improvement".
    #expect(ModelDisplayName.label("bedrock/us.anthropic.claude-opus-4-6-v1") == "Us.Anthropic.Claude Opus 4 6 V1")
    #expect(ModelDisplayName.label("") == "No model")
  }

  @Test func pickerSearchMatchesTheFriendlyLabelToo() throws {
    let options = ModelOptions(providers: [
      .init(name: "OmniRoute", slug: "omni", models: ["claude/claude-opus-5-5", "codex/gpt-6-sol"],
            authenticated: true),
    ])
    let hits = options.filteredProviders(matching: "opus 5.5")
    #expect(hits.first?.models == ["claude/claude-opus-5-5"])
    // Raw-id search still works.
    #expect(options.filteredProviders(matching: "gpt-6-sol").first?.models == ["codex/gpt-6-sol"])
  }
}
