# 历史页面点击时的身份和记录校验

2026-10-23，持续开发授权下核对跨入口衔接。历史View按构建时的metadata显示按钮，但Screen的onOpen/onText/onReview/onDelete/onSource/onTarget没有一致的点击时校验；owner变化后旧onSource可拼出`/history/null`，刷新或翻页后旧回调也可能继续跳旧记录。关联列表和复盘已有点击时守卫，沿用同一原则修补历史页，不改变服务端授权或数据格式。

推荐在Screen回调入口读取当前账号和原controller的当前内容；相较仅依赖View禁用，它覆盖重建前/旧回调；相较新建全局导航框架，局部守卫足以解决本单元问题。需要signedIn、非account busy、当前账号等于controller owner、controller非busy且未失效。列表还要求ID仍在当前页；详情要求当前item对应当前URL，文字/复盘要求仍sealed，目标/来源要求仍为rehearsal且有source，关联要求ordinary。所有URL使用当前已验证metadata，不将null插入路径。

先以真实Router/provider及HTTP替身复现owner变化、读取中、翻页离开原行和metadata变为unsealed后的旧回调。正常文字/复盘/删除/关联入口保留，补正常子来源/目标导航。无新界面、无后端/schema/依赖/数据库写入；浏览器工具条件未变时如实保留实际验收待补，不虚构媒体/改善评价。
