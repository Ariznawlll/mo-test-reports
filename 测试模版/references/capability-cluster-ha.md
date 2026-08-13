# 部署、集群与高可用

## cluster.supported-deployment

- **Status:** supported-with-conditions
- **User entry:** 官方 standalone/distributed/cloud deployment、配置和服务连接地址
- **Support evidence:** MatrixOne official deployment and architecture documentation
- **Scope:** 文档化 CN/TN/LogService/Proxy 拓扑、初始化、健康状态和扩展方式
- **Limitations:** 不同版本/产品形态/许可证条件必须记录；内部组件不是用户能力
- **State and invariants:** 部署可启动/关闭；服务发现一致；数据和认证入口健康；配置无 secret 泄露
- **Test routing:** launch/config UT、deployment smoke、stability/chaos；Feature BVT 使用最低正式拓扑
- **Repository evidence:** `repo:etc/launch`, `repo:docs/ai-skills/architecture.md`
- **Interactions:** required `session.connection-lifecycle`, `storage.data-durability`; high-risk bootstrap、scale、upgrade
- **Coverage gaps:** standalone 通过不能证明 distributed/Proxy 合同

## cluster.multi-cn

- **Status:** supported-with-conditions
- **User entry:** 多 CN 部署、Proxy 负载分发、CN scale/drain 和透明查询
- **Support evidence:** MatrixOne distributed deployment/multi-CN docs
- **Scope:** 正式拓扑中的节点发现、请求路由、分布式查询和支持的生命周期操作
- **Limitations:** 动态扩缩和 migration 以当前产品文档为准
- **State and invariants:** 跨 CN 结果/metadata/session 隔离正确；drain/restart 有界恢复；无重复执行或状态串线
- **Test routing:** multi-CN MOTR、distributed stability、CN kill/network chaos、cluster/proxy UT
- **Repository evidence:** `repo:docs/ai-skills/multi-cn.md`, `repo:pkg/cnservice`, `repo:pkg/clusterservice`
- **Interactions:** required `query.distributed-and-parallel-execution`, `session.connection-lifecycle`; high-risk transaction、prepared、cache invalidation
- **Coverage gaps:** 必须记录每个连接实际经过 Proxy/CN 的端口和拓扑证据

## cluster.failure-recovery

- **Status:** supported-with-conditions
- **User entry:** 官方 HA/rolling restart/主备或节点故障恢复流程
- **Support evidence:** MatrixOne HA/disaster recovery/deployment documentation and release notes
- **Scope:** 文档承诺的 CN/TN/LogService 故障和恢复边界
- **Limitations:** injection 时点、RTO/RPO 和组件冗余依产品形态；无冗余 standalone 不宣称 HA
- **State and invariants:** recovery deadline 内恢复；commit 状态确定；无丢失/重复/脑裂；服务和资源健康
- **Test routing:** chaos + stability/recovery workflow；lifecycle UT；正常 BVT 只作控制
- **Repository evidence:** `repo:pkg/common/chaos`, `repo:pkg/logservice`, `repo:pkg/tnservice`
- **Interactions:** required `storage.data-durability`, `transaction.explicit-transaction`, `observability.system-status`; high-risk network partition/commit-ack
- **Coverage gaps:** 进程 crash smoke 不能替代真实 TKE/网络分区合同
