enum Difficulty {
  beginner('轻松起步', '从短句开始，用熟悉的日常话题打开交流。'),
  intermediate('自然交流', '围绕日常生活展开，练习连贯地表达想法。'),
  advanced('深入表达', '探索更丰富的话题，练习细节、观点与讨论。');

  const Difficulty(this.label, this.description);
  final String label;
  final String description;
}

class AccountUser {
  const AccountUser({
    required this.id,
    required this.username,
    required this.displayName,
  });
  factory AccountUser.fromJson(Map<String, dynamic> json) => AccountUser(
    id: json['id'] as String,
    username: json['username'] as String,
    displayName: json['display_name'] as String,
  );
  final String id;
  final String username;
  final String displayName;
}

class AccountPreferences {
  const AccountPreferences({
    required this.difficulty,
    required this.speechPace,
    required this.subtitleDefault,
    required this.chineseHintsEnabled,
    required this.version,
  });
  factory AccountPreferences.fromJson(Map<String, dynamic> json) =>
      AccountPreferences(
        difficulty: json['difficulty'] == null
            ? null
            : Difficulty.values.byName(json['difficulty'] as String),
        speechPace: json['speech_pace'] as String,
        subtitleDefault: json['subtitle_default'] as bool,
        chineseHintsEnabled: json['chinese_hints_enabled'] as bool,
        version: json['version'] as int,
      );
  final Difficulty? difficulty;
  final String speechPace;
  final bool subtitleDefault;
  final bool chineseHintsEnabled;
  final int version;

  AccountPreferences copyWith({
    Difficulty? difficulty,
    String? speechPace,
    bool? subtitleDefault,
    bool? chineseHintsEnabled,
  }) => AccountPreferences(
    difficulty: difficulty ?? this.difficulty,
    speechPace: speechPace ?? this.speechPace,
    subtitleDefault: subtitleDefault ?? this.subtitleDefault,
    chineseHintsEnabled: chineseHintsEnabled ?? this.chineseHintsEnabled,
    version: version,
  );

  Map<String, dynamic> toJson() => {
    'difficulty': difficulty?.name,
    'speech_pace': speechPace,
    'subtitle_default': subtitleDefault,
    'chinese_hints_enabled': chineseHintsEnabled,
    'translation_mode': 'on_demand',
    'version': version,
  };

  bool sameValues(AccountPreferences other) =>
      difficulty == other.difficulty &&
      speechPace == other.speechPace &&
      subtitleDefault == other.subtitleDefault &&
      chineseHintsEnabled == other.chineseHintsEnabled;
}

class AccountSession {
  const AccountSession(this.user, this.preferences);
  final AccountUser user;
  final AccountPreferences preferences;
}
