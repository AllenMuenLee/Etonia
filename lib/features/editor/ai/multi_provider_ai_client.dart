import 'package:http/http.dart' as http;

import 'ai_client.dart';
import 'ai_config.dart';
import 'claude_ai_client.dart';
import 'gemini_ai_client.dart';
import 'openai_ai_client.dart';

/// Makes the client that answers for [model], under its provider's own
/// [providerModelId].
typedef AiProviderClientFactory =
    AiClient Function(AiModelId model, String providerModelId);

/// Answers each request with the model it names: Luna, Sol, and Argon on
/// Gemini, Haiku, Sonnet, and Opus on Claude, and Astra on OpenAI. Every
/// one returns the same version-2 JSON, so chat and Notation behave alike
/// whichever is picked.
///
/// A client per model is made on first use and kept, sharing one
/// [http.Client], and all of them are closed by [close].
class MultiProviderAiClient implements AiModelRouter {
  MultiProviderAiClient({
    required this.config,
    this.notationConfig = const AiNotationConfig(),
    this.defaultModel = AiModelId.sol,
    http.Client? httpClient,
    Map<AiProvider, AiProviderClientFactory>? factories,
  }) : _httpClient = httpClient,
       _ownsHttpClient = httpClient == null,
       _factories = factories ?? const <AiProvider, AiProviderClientFactory>{};

  final AiApiConfig config;
  final AiNotationConfig notationConfig;

  @override
  final AiModelId defaultModel;

  final bool _ownsHttpClient;
  http.Client? _httpClient;
  final Map<AiProvider, AiProviderClientFactory> _factories;
  final Map<AiModelId, AiClient> _clients = <AiModelId, AiClient>{};
  bool _closed = false;

  @override
  List<AiModelId> get models => AiModelId.values;

  @override
  bool isModelConfigured(AiModelId model) => config.hasKeyFor(model.provider);

  @override
  bool get isConfigured => models.any(isModelConfigured);

  @override
  bool get routes => false;

  @override
  String get modelLabel => defaultModel.label;

  /// The client [model] is sent to, made on first use.
  AiClient clientFor(AiModelId model) {
    return _clients.putIfAbsent(model, () {
      final String id = config.providerModelId(model);
      final AiProviderClientFactory? factory = _factories[model.provider];
      if (factory != null) {
        return factory(model, id);
      }
      final http.Client client = _httpClient ??= http.Client();
      return switch (model.provider) {
        AiProvider.gemini => GeminiAiClient(
          config: config.withGeminiModel(id),
          httpClient: client,
          notationConfig: notationConfig,
        ),
        AiProvider.claude => ClaudeAiClient(
          config: config,
          model: id,
          httpClient: client,
          notationConfig: notationConfig,
        ),
        AiProvider.openai => OpenAiClient(
          config: config,
          model: id,
          httpClient: client,
          notationConfig: notationConfig,
        ),
      };
    });
  }

  @override
  Future<AiResult> send(
    AiRequest request, {
    AiPartialCallback? onPartial,
    AiNotationPartialCallback? onNotation,
  }) {
    final AiModelId model = request.model ?? defaultModel;
    if (_closed) {
      return Future<AiResult>.value(
        const AiError(AiFailure(AiFailureKind.network)),
      );
    }
    if (!isModelConfigured(model)) {
      return Future<AiResult>.value(
        const AiError(AiFailure(AiFailureKind.notConfigured)),
      );
    }
    return clientFor(
      model,
    ).send(request, onPartial: onPartial, onNotation: onNotation);
  }

  @override
  void close() {
    _closed = true;
    for (final AiClient client in _clients.values) {
      client.close();
    }
    _clients.clear();
    if (_ownsHttpClient) {
      _httpClient?.close();
    }
    _httpClient = null;
  }
}
