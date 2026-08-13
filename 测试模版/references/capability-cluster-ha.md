# 部署、集群与高可用

## cluster.supported-deployment

- **支持状态:** supported-with-conditions
- **用户入口:** 官方 standalone/distributed/cloud deployment、配置和服务连接地址
- **支持证据:** MatrixOne 官方部署和架构文档
- **支持范围:** 文档化 CN/TN/LogService/Proxy 拓扑、初始化、健康状态和扩展方式
- **限制条件:** 不同版本/产品形态/许可证条件必须记录；内部组件不是用户能力
- **状态与不变量:** 部署可启动/关闭；服务发现一致；数据和认证入口健康；配置无 secret 泄露
- **测试分层:** launch/config UT、deployment smoke、stability/chaos；Feature BVT 使用最低正式拓扑
- **仓库证据:** `repo:etc/launch`, `repo:docs/ai-skills/architecture.md`
- **关联能力:** 必需 `session.connection-lifecycle`, `storage.data-durability`; 高风险 bootstrap、scale、upgrade
- **覆盖缺口:** standalone 通过不能证明 distributed/Proxy 合同

## cluster.multi-cn

- **支持状态:** supported-with-conditions
- **用户入口:** 多 CN 部署、Proxy 负载分发、CN scale/drain 和透明查询
- **支持证据:** MatrixOne 分布式部署和多 CN 文档
- **支持范围:** 正式拓扑中的节点发现、请求路由、分布式查询和支持的生命周期操作
- **限制条件:** 动态扩缩和 migration 以当前产品文档为准
- **状态与不变量:** 跨 CN 结果/metadata/session 隔离正确；drain/restart 有界恢复；无重复执行或状态串线
- **测试分层:** multi-CN MOTR、distributed stability、CN kill/network chaos、cluster/proxy UT
- **仓库证据:** `repo:docs/ai-skills/multi-cn.md`, `repo:pkg/cnservice`, `repo:pkg/clusterservice`
- **关联能力:** 必需 `query.distributed-and-parallel-execution`, `session.connection-lifecycle`; 高风险 transaction、prepared、cache invalidation
- **覆盖缺口:** 必须记录每个连接实际经过 Proxy/CN 的端口和拓扑证据

## cluster.failure-recovery

- **支持状态:** supported-with-conditions
- **用户入口:** 官方 HA/rolling restart/主备或节点故障恢复流程
- **支持证据:** MatrixOne HA/disaster recovery/deployment documentation and release notes
- **支持范围:** 文档承诺的 CN/TN/LogService 故障和恢复边界
- **限制条件:** injection 时点、RTO/RPO 和组件冗余依产品形态；无冗余 standalone 不宣称 HA
- **状态与不变量:** recovery deadline 内恢复；commit 状态确定；无丢失/重复/脑裂；服务和资源健康
- **测试分层:** chaos + stability/recovery workflow；lifecycle UT；正常 BVT 只作控制
- **仓库证据:** `repo:pkg/common/chaos`, `repo:pkg/logservice`, `repo:pkg/tnservice`
- **关联能力:** 必需 `storage.data-durability`, `transaction.explicit-transaction`, `observability.system-status`; 高风险 network partition/commit-ack
- **覆盖缺口:** 进程 crash smoke 不能替代真实 TKE/网络分区合同
