# AcceleratedRecoiling

Minecraft 服务端实体碰撞优化模组。原生内核在 `native/`，用 Zig 编写、由 Gradle 交叉编译进 jar。构建与提权见上级目录的 `AGENTS.md`。

## 改内核前先看

- `cd native && zig build test` 会编两个测试二进制：一个钉 baseline，一个按本机 CPU。**两个都必须绿**——只跑 baseline 不会执行到 v3/v4 的 object。
- 量化预筛在 `queryBatch` 内逐 section 判定（`count >= 1024`）。Java 侧 `RealtimeNative.quantizeSection` 的阈值必须与之保持一致，否则 native 会越界读 SoA 数据。
- `v4` 档从未在任何 AVX-512 真机上执行过，改动 `kernel.zig` 时不要假定它已被验证。
