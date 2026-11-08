/// Who serves a model.
enum AiProvider {
  gemini('Gemini'),
  openai('OpenAI'),
  claude('Claude');

  const AiProvider(this.label);

  /// Shown beside a model in the picker.
  final String label;
}

/// The models the user picks between, by the names the app gives them. Each
/// is served by one [provider], under [defaultProviderModelId] unless
/// `dart_defines.json` names another with [environmentKey].
///
/// Listed in the order the picker shows them: the unlimited models first,
/// then the standard ones, then the frontier ones.
enum AiModelId {
  haiku(
    label: 'Haiku',
    provider: AiProvider.claude,
    tokenMultiplier: 1,
    defaultProviderModelId: 'claude-haiku-5-5',
    environmentKey: 'HAIKU_MODEL_ID',
    summary: 'Claude Haiku 5.5 · fast',
  ),
  luna(
    label: 'Luna',
    provider: AiProvider.openai,
    tokenMultiplier: 1,
    defaultProviderModelId: 'gpt-6-luna',
    environmentKey: 'LUNA_MODEL_ID',
    summary: 'GPT-6 Luna · fast',
  ),
  sonnet(
    label: 'Sonnet',
    provider: AiProvider.claude,
    tokenMultiplier: 20,
    defaultProviderModelId: 'claude-sonnet-5-5',
    environmentKey: 'SONNET_MODEL_ID',
    summary: 'Claude Sonnet 5.5 · balanced',
  ),
  sol(
    label: 'Sol',
    provider: AiProvider.openai,
    tokenMultiplier: 20,
    defaultProviderModelId: 'gpt-6.1-sol',
    environmentKey: 'SOL_MODEL_ID',
    summary: 'GPT-6.1 Sol · balanced',
  ),
  flash(
    label: 'Flash',
    provider: AiProvider.gemini,
    tokenMultiplier: 20,
    defaultProviderModelId: 'gemini-3.8-flash',
    environmentKey: 'FLASH_MODEL_ID',
    summary: 'Gemini 3.8 Flash · balanced',
  ),
  opus(
    label: 'Opus',
    provider: AiProvider.claude,
    tokenMultiplier: 40,
    defaultProviderModelId: 'claude-opus-5-5',
    environmentKey: 'OPUS_MODEL_ID',
    summary: 'Claude Opus 5.5 · frontier',
  ),
  argon(
    label: 'Argon',
    provider: AiProvider.gemini,
    tokenMultiplier: 40,
    defaultProviderModelId: 'gemini-4-argon',
    environmentKey: 'ARGON_MODEL_ID',
    summary: 'Gemini 4 Argon · frontier',
  ),
  astra(
    label: 'Astra',
    provider: AiProvider.openai,
    tokenMultiplier: 100,
    defaultProviderModelId: 'gpt-6-astra',
    environmentKey: 'ASTRA_MODEL_ID',
    summary: 'GPT-6 Astra · frontier',
  );

  const AiModelId({
    required this.label,
    required this.provider,
    required this.tokenMultiplier,
    required this.defaultProviderModelId,
    required this.environmentKey,
    required this.summary,
  });

  /// The name the user sees.
  final String label;
  final AiProvider provider;

  /// Relative token-credit consumption shown in the model picker.
  ///
  /// The least expensive models are the `x1` baseline; the other values
  /// follow the same ratio as their configured input and output rates.
  final int tokenMultiplier;

  /// The provider's own ID for this model, unless overridden.
  final String defaultProviderModelId;

  /// The `dart_defines.json` key that overrides [defaultProviderModelId].
  final String environmentKey;

  /// A few words on what it is good for, shown in the picker.
  final String summary;
}
