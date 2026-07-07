/// Network-serializable plugin sync entry
class PluginSyncEntry {
  final String id;
  final String name;
  final String minVersion;
  final bool mandatory;
  final String source; // "bundled" | "external"
  final bool enabled;
  final String? bundledData;

  const PluginSyncEntry({
    required this.id,
    required this.name,
    this.minVersion = '',
    this.mandatory = false,
    this.source = 'external',
    this.enabled = false,
    this.bundledData,
  });

  factory PluginSyncEntry.fromJson(Map<String, dynamic> json) {
    return PluginSyncEntry(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      minVersion: json['min_version'] as String? ?? '',
      mandatory: json['mandatory'] as bool? ?? false,
      source: json['source'] as String? ?? 'external',
      enabled: json['enabled'] as bool? ?? false,
      bundledData: json['bundled_data'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'min_version': minVersion,
    'mandatory': mandatory,
    'source': source,
    'enabled': enabled,
    if (bundledData != null) 'bundled_data': bundledData,
  };
}

/// Client's plugin ack reply
class PluginAckMessage {
  final String clientId;
  final bool ready;
  final List<String> missingPlugins;

  const PluginAckMessage({
    required this.clientId,
    required this.ready,
    this.missingPlugins = const [],
  });

  Map<String, dynamic> toJson() => {
    'type': 'plugin_ack',
    'client_id': clientId,
    'ready': ready,
    'missing_plugins': missingPlugins,
  };

  factory PluginAckMessage.fromJson(Map<String, dynamic> json) {
    return PluginAckMessage(
      clientId: json['client_id'] as String? ?? '',
      ready: json['ready'] as bool? ?? false,
      missingPlugins: (json['missing_plugins'] as List<dynamic>?)
          ?.map((e) => e as String).toList() ?? [],
    );
  }
}
