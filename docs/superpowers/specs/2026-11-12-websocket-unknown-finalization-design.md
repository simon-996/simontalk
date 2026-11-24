# WebSocket 启动失败与失联持久收尾候选

在服务器已经提交单次 claim 后，一旦连接/配置失败、客户端断开、账号撤销、租约到期或任务取消，即使当前登录已失效也必须能记录“远端未知”。提供仅接收服务端持有的 `WebSocketClaim` 和有限原因枚举的同步事务函数；不开放路由、不接受客户端传入的凭据、状态或供应商原文，不将本地 socket 关闭当作可信终止。

先重新计算并核对 claim 的域隔离指纹，按 user → 未删除 practice → connection 行加锁，复验用户/练习、client instance、epoch、已持久化指纹与状态。仅仍对应该次、termination 为 unknown 的 negotiating/configuring/ready/closing/unknown 可以收尾；过期 claim、不同连接、已关闭/已证明终止或删除不得覆盖。将 connection 置 unknown，practice 非结束/完成时置 interrupted，补全 signalling_finished_at 和已存在的 blocked、零尝试终止检查。重复/并发同 claim 必须幂等，不能重置第一次原因或时间。数据库提交失败由调用方获知；进程崩溃前未执行函数仍由租约扫描保持保守未知。实际主管仍需有界关闭本地 socket、取消在途工作，并隔离未知计费。

不提供成功回写：在配置门、真实上游连接和持久 claim 之间建立不可混淆的同一连接绑定之前，单独的布尔成功不能证明供应商事件来自该次尝试。成功结果留待完整主管实现和真实实测。
