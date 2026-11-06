/// 一家 AI 提供商的模型单价（用户自填，每百万 token）。
///
/// 价格由用户在提供商设置里照着厂商价目表填：各家价目随时在变、同一端点下不同
/// 模型价格也不同，内置一份价目表必然过期，算出来的「费用」反而误导。缓存读 /
/// 写单价没填时按输入单价算（宁可高估，不少算）。
library;

class AiModelPricing {
  const AiModelPricing({
    this.inputPerMillion,
    this.outputPerMillion,
    this.cacheReadPerMillion,
    this.cacheWritePerMillion,
    String currency = kAiDefaultPricingCurrency,
  }) : _currencyInput = currency;

  factory AiModelPricing.fromJson(Map<String, Object?> json) => AiModelPricing(
    inputPerMillion: _price(json['input']),
    outputPerMillion: _price(json['output']),
    cacheReadPerMillion: _price(json['cacheRead']),
    cacheWritePerMillion: _price(json['cacheWrite']),
    currency: _currency(json['currency']),
  );

  final double? inputPerMillion;
  final double? outputPerMillion;
  final double? cacheReadPerMillion;
  final double? cacheWritePerMillion;

  final String _currencyInput;

  /// ISO 4217 币种代码（USD / CNY …，已转大写），只用于显示；认不出时为 USD。
  String get currency => _currency(_currencyInput);

  /// 输入与输出单价都填了才算得出费用；只填一半时不显示费用（少算比不算更误导）。
  bool get isSet => inputPerMillion != null && outputPerMillion != null;

  /// 按本单价算一次请求的费用；单价没填齐时为 null。
  double? costOf({
    int inputTokens = 0,
    int outputTokens = 0,
    int cacheReadTokens = 0,
    int cacheWriteTokens = 0,
  }) {
    final double? input = inputPerMillion;
    final double? output = outputPerMillion;
    if (input == null || output == null) return null;
    return (inputTokens * input +
            outputTokens * output +
            cacheReadTokens * (cacheReadPerMillion ?? input) +
            cacheWriteTokens * (cacheWritePerMillion ?? input)) /
        1000000;
  }

  AiModelPricing copyWith({
    double? Function()? inputPerMillion,
    double? Function()? outputPerMillion,
    double? Function()? cacheReadPerMillion,
    double? Function()? cacheWritePerMillion,
    String? currency,
  }) => AiModelPricing(
    inputPerMillion: inputPerMillion == null
        ? this.inputPerMillion
        : inputPerMillion(),
    outputPerMillion: outputPerMillion == null
        ? this.outputPerMillion
        : outputPerMillion(),
    cacheReadPerMillion: cacheReadPerMillion == null
        ? this.cacheReadPerMillion
        : cacheReadPerMillion(),
    cacheWritePerMillion: cacheWritePerMillion == null
        ? this.cacheWritePerMillion
        : cacheWritePerMillion(),
    currency: currency == null ? this.currency : _currency(currency),
  );

  /// 一项都没填时为空表（调用方据此不落盘）。
  Map<String, Object?> toJson() => <String, Object?>{
    if (inputPerMillion != null) 'input': inputPerMillion,
    if (outputPerMillion != null) 'output': outputPerMillion,
    if (cacheReadPerMillion != null) 'cacheRead': cacheReadPerMillion,
    if (cacheWritePerMillion != null) 'cacheWrite': cacheWritePerMillion,
    if (currency != kAiDefaultPricingCurrency) 'currency': currency,
  };

  bool get isEmpty =>
      inputPerMillion == null &&
      outputPerMillion == null &&
      cacheReadPerMillion == null &&
      cacheWritePerMillion == null &&
      currency == kAiDefaultPricingCurrency;
}

const String kAiDefaultPricingCurrency = 'USD';

/// 用户输入的单价：空 / 非数字 / 负数 = 没填。
double? parseAiPrice(String raw) {
  final double? value = double.tryParse(raw.trim());
  return value == null || value.isNaN || value.isInfinite || value < 0
      ? null
      : value;
}

double? _price(Object? raw) {
  if (raw is! num) return null;
  final double value = raw.toDouble();
  return value.isNaN || value.isInfinite || value < 0 ? null : value;
}

String _currency(Object? raw) {
  final String code = '${raw ?? ''}'.trim().toUpperCase();
  return RegExp(r'^[A-Z]{3}$').hasMatch(code)
      ? code
      : kAiDefaultPricingCurrency;
}
