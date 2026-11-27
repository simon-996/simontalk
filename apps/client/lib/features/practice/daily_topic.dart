import '../account/account_models.dart';

enum DailyTopic {
  weekendPlans('weekend_plans', '周末计划', '分享一个周末安排'),
  food('food', '饮食', '说说你爱吃什么'),
  hobbies('hobbies', '兴趣爱好', '聊聊最近在做的事'),
  travel('travel', '旅行', '描述一个想去的地方');

  const DailyTopic(this.id, this.title, this.goal);
  final String id;
  final String title;
  final String goal;

  static DailyTopic? fromId(String? id) {
    for (final topic in values) {
      if (topic.id == id) return topic;
    }
    return null;
  }
}

class PracticeTopicSnapshot {
  const PracticeTopicSnapshot._(this.id, this.title, this.goal);

  factory PracticeTopicSnapshot.fromJson(Map<String, dynamic> json) {
    final id = json['id'], title = json['title'], goal = json['goal'];
    if (id is! String ||
        !RegExp(r'^[a-z][a-z_0-9]{0,63}$').hasMatch(id) ||
        title is! String ||
        title.trim().isEmpty ||
        title.length > 256 ||
        goal is! String ||
        goal.trim().isEmpty ||
        goal.length > 256) {
      throw const FormatException('Invalid practice topic');
    }
    return PracticeTopicSnapshot._(id, title, goal);
  }

  final String id, title, goal;
}

class TopicSessionLaunch {
  const TopicSessionLaunch({
    required this.accountId,
    required this.topic,
    required this.difficulty,
  });

  final String accountId;
  final DailyTopic topic;
  final Difficulty difficulty;
}
