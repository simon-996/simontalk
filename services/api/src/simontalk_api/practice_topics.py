"""Curated daily topics and the topic snapshot stored with an ordinary practice."""

from dataclasses import asdict, dataclass
from types import MappingProxyType
from typing import Literal

from simontalk_api.errors import APIError

TopicId = Literal["weekend_plans", "food", "hobbies", "travel"]


@dataclass(frozen=True, slots=True)
class PracticeTopic:
    id: str
    title: str
    goal: str
    prompt: str

    def snapshot(self):
        return asdict(self)


DAILY_TOPICS = MappingProxyType(
    {
        topic.id: topic
        for topic in (
            PracticeTopic(
                "weekend_plans",
                "周末计划",
                "分享一个周末安排",
                "Talk about weekend plans. Ask about one thing the learner plans to do.",
            ),
            PracticeTopic(
                "food",
                "饮食",
                "说说你爱吃什么",
                "Talk about food. Ask which dish the learner likes and why.",
            ),
            PracticeTopic(
                "hobbies",
                "兴趣爱好",
                "聊聊最近在做的事",
                "Talk about hobbies. Ask about one activity the learner has enjoyed recently.",
            ),
            PracticeTopic(
                "travel",
                "旅行",
                "描述一个想去的地方",
                "Talk about travel. Ask about one place the learner would like to visit.",
            ),
        )
    }
)


def practice_topic(practice):
    configuration = practice.configuration
    if isinstance(configuration, dict):
        if practice.mode == "free_chat" and "topic" not in configuration:
            return None
        snapshot = configuration.get("topic")
        if (
            practice.mode == "daily_topic"
            and practice.kind == "ordinary"
            and type(snapshot) is dict
            and set(snapshot) == {"id", "title", "goal", "prompt"}
            and all(
                type(value) is str and value.strip() and len(value) <= 256
                for value in snapshot.values()
            )
        ):
            return PracticeTopic(**snapshot)
    raise APIError(409, "practice_configuration_changed", "练习话题配置已更改。")
