# Aegis 二进制加密备份设计方案

状态：已决议的设计稿，尚未实现，不代表通过安全审计。

文档修订：Draft 2，2026-11-05。磁盘格式：ABB v1（Aegis Binary Backup）。Draft 1 已被本稿完整取代，主要变化见 §0。

代码基线：51ec6a0112765e4245098e028ac9c2367561e9b5。

## 0. 相对 Draft 1 的决议

| 编号 | 决议 | 理由 |
| --- | --- | --- |
| DEC-1 | 采用“随机内容密钥 FK + 密钥槽”信封结构，取代“密码直接派生外层密钥” | 主密码与恢复密钥都能打开备份；可证明原 wrappedKey 与 VK 一致；能精确区分“密码错误”和“文件损坏” |
| DEC-2 | 默认导出模式为“保险库保护”，只放保险库槽，导出时不再输入主密码 | 保险库槽直接由已解锁的 VK 派生，强度与 iCloud 上的 VaultHeader 相同 |
| DEC-3 | “备份密码”模式默认同时附带保险库槽；用户可勾选“仅备份密码可打开” | 默认保证灾难恢复：主密码、恢复密钥、备份密码任一可用 |
| DEC-4 | 所有导出前统一进行设备所有者验证；设备未设置密码时退回为主密码验证 | 防止拿到已解锁设备的人导出含 VK 的文件，两种模式门槛一致 |
| DEC-5 | 本机已有保险库且处于锁定状态时禁止导入，必须先正常解锁 | 防止备份凭据在锁定状态下操作当前保险库 |
| DEC-6 | 删除 SHA-256 尾部、ULEB128、recordLength、headerLength、fileLength、多重版本号 | GCM 已认证全部字节；固定宽度整数没有规范编码问题；严格版本化格式不需要这些前向兼容字段 |
| DEC-7 | 增加 32 字节密钥承诺（key commitment） | AES-GCM 不承诺密钥；多槽位时防止不同凭据解出不同内容 |
| DEC-8 | 明文填充到 64 KiB 整数倍 | 文件大小不再泄露大致记录数 |
| DEC-9 | 版本图不完整时允许导出，置标志位并在两端提示 | 离线救援时不能因为历史缺失就无法备份 |
| DEC-10 | 备份密码使用 NFC 归一化；主密码保持原始 UTF-8 字节 | 备份密码是新凭据，归一化可避免跨设备输入法差异；主密码必须与现有保险库一致 |
| DEC-11 | 只使用 UTType `app.aegis.backup`，不提供旧格式导入 | 避免同一个类型标识对应两种字节格式 |
| DEC-12 | 修复 `VaultStore.restore` 保存失败后的回滚 | 防止失败恢复的插入对象被下一次保存提交 |
| DEC-13 | “修改主密码 / 重新生成恢复密钥”作为独立后续功能，不是本格式的前置条件 | DEC-3 已覆盖常见灾难恢复场景；密钥头轮换需要独立设计 CloudKit header epoch |

## 1. 需求

### 1.1 用户要求

1. 导出为自定义、紧凑的二进制文件，具有明确的魔术值和文件头。
2. 文件头可以公开版本、解密所需参数。
3. 全部业务数据及记录元信息整体加密；记录数量、条目 ID、版本关系不能从文件中读取。
4. 导出可以使用保险库自身的凭据，也可以选择独立备份密码。
5. 导入只输入一次凭据，不重复确认，不额外索要原主密码。
6. 支持完整性检测，验证成功后才能导入。
7. 格式本身不以 32 MiB 为固有限制；实现设置一致、合理的资源上限。
8. 先完成设计和审查，再实现。

### 1.2 非目标

v1 不包含：附件、增量备份、压缩（内层记录已是密文，压缩无效）、分块流式加密、纠错冗余、数字签名、原地修改备份密码、主密码轮换、VK 轮换、恢复为新保险库身份。

## 2. 当前实现约束

- 用户导出使用 ABB v1；自动填充仍在 App Group 内使用专用 JSON 快照，这是内部扩展通道，不属于用户可导入的备份格式。
- `VaultSession` 只通过 ABB v1 预览、验证和事务恢复。
- `VaultStore.restore()` 在一次 actor 调用内完成插入、保存和失败回滚；旧的导入残留问题已修复（DEC-12）。
- `VaultHeader` 不可变；保存、同步、导入都会拒绝不相同的 header。`CloudSync` 在发送本地变更前先拉取远端，`receive` 遇到不同的 header 会报 `differentVault`。
- 应用目前没有修改主密码或重新生成恢复密钥的功能。
- 记录 AAD 使用大写 `uuidString` 拼接，parents 按 `uuidString` 排序（与原始字节序一致）；二进制往返必须精确还原。
- 已注册的用户备份类型为 `app.aegis.backup`，扩展名 `aegis`。
- Swift 字符串、SwiftUI 与 Data 的内存副本无法保证立即擦除。

用户 ABB 备份与自动填充内部快照必须分离：内部快照仍可使用专用 JSON codec，但它不是用户可选择、可导入的备份格式。

## 3. 威胁模型

### 3.1 防御范围

- 备份文件被复制、丢失或上传到不可信存储后遭受离线攻击。
- 修改文件头、槽位、密文、长度、参数或 tag；截断、追加、拼接、重排槽位。
- 恶意构造的长度、数量、版本关系及高成本 KDF 参数。
- 知道备份密码的恶意文件作者构造内部结构异常的文件。
- 拿到已解锁或已解锁屏幕设备的人，借导出或导入扩大权限。
- 导入失败、取消、锁定或账号切换造成部分写入、密钥残留或错误同步。

### 3.2 不作出的保证

- 文件格式不增加密码强度；离线攻击成本取决于凭据强度与 Argon2id 参数。
- 不防御能读取进程内存的攻击者。
- 不证明备份是最新的，也不证明本机已收到云端全部数据。
- 不修复损坏文件。
- 不隐藏：文件近似大小（64 KiB 粒度）、文件名、时间戳、格式版本、槽位类型及其 KDF 参数；使用保险库槽时还公开 vaultID 和原 VaultHeader。
- 能打开文件的人就能重新生成有效文件；这不是数字签名。
- 已交出的备份无法撤销。VK 不轮换，因此任何一份备份泄露，该保险库此后的数据都可能被解密。

## 4. 密钥结构与导入导出语义

### 4.1 术语

| 名称 | 含义 | 是否在文件中 |
| --- | --- | --- |
| VK | 保险库密钥，32 字节，加密全部记录 | 仅在数据区密文内 |
| VaultHeader | vaultID、vaultSalt、KDF 参数、wrappedKey、recoveryWrappedKey | 数据区内；有保险库槽时也在公开槽位中 |
| FK | 每个文件随机生成的 32 字节内容密钥 | 只以被包裹的形式出现在槽位中 |
| payloadKey | 由 FK 派生，用于加密数据区 | 不保存 |
| commitment | 由 FK 派生的 32 字节承诺值 | 公开文件头 |
| 槽位 KEK | 包裹 FK 的密钥，由备份密码或 VK 派生 | 不保存 |

### 4.2 导出模式

| 模式 | 槽位 | 能打开文件的凭据 |
| --- | --- | --- |
| 保险库保护（默认） | 保险库槽 | 主密码、恢复密钥 |
| 备份密码（默认） | 密码槽 + 保险库槽 | 备份密码、主密码、恢复密钥 |
| 备份密码（勾选“仅备份密码可打开”） | 密码槽 | 备份密码 |

- 所有导出前执行 `LAContext.evaluatePolicy(.deviceOwnerAuthentication)`。若设备未设置密码，改为输入主密码，并用现有解锁逻辑验证（DEC-4）。
- 保险库保护模式不需要输入任何密码。
- 备份密码模式要求输入两次（确认只为防止打错，不是安全因子）。
- 勾选“仅备份密码可打开”时，界面说明：忘记该密码后，主密码和恢复密钥都无法打开此文件。
- 不持久保存备份密码，也不记住上次选择的模式。

### 4.3 导入凭据解析（只有一个输入框）

输入框提示文案按文件中的槽位决定：

- 只有保险库槽：“主密码或恢复密钥”
- 两个槽位：“备份密码、主密码或恢复密钥”
- 只有密码槽：“备份密码”

尝试顺序，任一成功即停止：

1. 文件有保险库槽，且输入去掉空白和连字符后恰好是 64 个十六进制字符：按恢复密钥解开 recoveryWrappedKey 得到 VK。
2. 文件有密码槽：对 NFC(输入) 执行 Argon2id，尝试打开密码槽。
3. 文件有保险库槽：对原始 UTF-8 输入按原 header 参数执行 Argon2id，解开 wrappedKey 得到 VK。

最坏情况执行两次 Argon2id。全部失败时提示“密码或恢复密钥不正确”。

### 4.4 导入身份规则

| 本地情况 | 行为 |
| --- | --- |
| 本机没有保险库 | 恢复 header 与记录，之后以 VK 进入已解锁状态 |
| 同一保险库，已解锁 | header 逐字节相同，且文件中的 VK 与会话 VK 常量时间比较相等，然后合并 |
| 同一保险库，已锁定 | 拒绝，提示“请先解锁保险库再导入”（DEC-5） |
| 不同保险库，或同 ID 不同 header | 拒绝，不跨库导入 |

### 4.5 恢复语义

- 恢复不修改 VaultHeader：日后锁定或重启，仍使用原主密码、原恢复密钥，或用户另行启用的本机生物识别。
- 由密码槽恢复时，预览显示：“此密码仅用于打开备份。恢复后仍使用原保险库的主密码或恢复密钥进行日常解锁。”
- 只有密码槽的文件无法证明其中的 wrappedKey 确实包裹了 VK。缓解方式：若 iCloud 已有该保险库，后续同步会对 header 逐字节比对，不一致时报不兼容，并且不覆盖云端；预览中提示此限制。“忘记主密码且丢失恢复密钥”的完整解决方案依赖后续的密钥头轮换功能（DEC-13）。
- 导入后不自动开启生物识别，不迁移设备凭据，不生成或伪造恢复密钥。

## 5. 密码学定义

| 项目 | 定义 |
| --- | --- |
| 随机数 | `SecRandomCopyBytes`（复用 `SecureRandom`） |
| 密码槽 KDF | Argon2id v1.3，输出 32 字节，v1 只接受 memory = 65536 KiB、iterations = 3、parallelism = 1；salt 16 字节 |
| 保险库槽 VK 获取 | 复用现有 VaultCrypto 解包逻辑（抽出无状态函数，不复制 AAD 字符串） |
| 保险库槽 KEK | HKDF-SHA256(ikm = VK, salt = hkdfSalt, info = "aegis.backup.v1.vault-slot", L = 32) |
| 密码槽 KEK | Argon2id 输出直接使用 |
| FK 包裹 | AES-256-GCM，随机 12 字节 nonce，16 字节 tag |
| payloadKey | HKDF-SHA256(ikm = FK, salt = 空, info = "aegis.backup.v1.payload", L = 32) |
| commitment | HKDF-SHA256(ikm = FK, salt = 空, info = "aegis.backup.v1.commit", L = 32) |
| 数据区加密 | AES-256-GCM（CryptoKit），payloadKey，文件头中的 payloadNonce，16 字节 tag |
| 压缩 | 不使用 |

规则：

- FK、各 nonce、各 salt 每次导出都重新随机生成；不复用保险库盐或记录 nonce。
- 打开槽位得到 FK 后，先常量时间比较 commitment，再打开数据区。
- 备份密码：NFC 归一化后取 UTF-8，不去空格、不改大小写、不加 NUL；导出时要求至少 12 个 Character 且不超过 4096 字节；导入时只检查 4096 字节上限，以免将来提高最小长度后拒绝合法的历史 ABB 文件。导出界面提供强度提示和随机密码生成。
- 主密码与恢复密钥：沿用现有处理方式（原始 UTF-8 字节；恢复密钥为 64 个十六进制字符）。
- 保险库槽中的 KDF 参数用 `KDFParameters.validate()` 检查范围，超出范围时在运行 Argon2 前拒绝。

## 6. 文件结构

所有多字节整数为无符号小端序，偏移相对于所在结构的起点。

    File       = FixedHeader[60] || Slot[1..2] || Ciphertext[payloadLength] || Tag[16]
    HeaderArea = FixedHeader || 全部 Slot
    文件总长度必须恰好等于 len(HeaderArea) + payloadLength + 16，不允许尾随字节

### 6.1 固定文件头（60 字节）

| 偏移 | 长度 | 类型 | 字段 | v1 规则 |
| ---: | ---: | --- | --- | --- |
| 0 | 8 | bytes | magic | `89 41 45 47 49 53 0D 0A`（0x89、“AEGIS”、CRLF） |
| 8 | 2 | UInt16 | version | 1；唯一的版本号，同时决定容器、算法与数据区格式 |
| 10 | 1 | UInt8 | slotCount | 1 或 2 |
| 11 | 1 | UInt8 | zero | 0 |
| 12 | 4 | UInt32 | payloadLength | 65536 的正整数倍，且不超过 §8.3 的上限 |
| 16 | 12 | bytes | payloadNonce | 随机 |
| 28 | 32 | bytes | commitment | 见 §5 |

### 6.2 槽位

槽位长度由类型决定。两个槽位时顺序固定为 0x01、0x02；不允许重复类型或未知类型。

**类型 0x01：密码槽（92 字节）**

| 偏移 | 长度 | 字段 |
| ---: | ---: | --- |
| 0 | 1 | type = 0x01 |
| 1 | 3 | zero |
| 4 | 4 | argonMemoryKiB |
| 8 | 4 | argonIterations |
| 12 | 4 | argonParallelism |
| 16 | 16 | salt |
| 32 | 12 | wrapNonce |
| 44 | 32 | wrappedFK（密文） |
| 76 | 16 | wrapTag |

**类型 0x02：保险库槽（244 字节）**

| 偏移 | 长度 | 字段 |
| ---: | ---: | --- |
| 0 | 1 | type = 0x02 |
| 1 | 3 | zero |
| 4 | 16 | vaultID（UUID 原始字节，RFC 4122 顺序） |
| 20 | 16 | vaultSalt |
| 36 | 4 | vaultMemoryKiB |
| 40 | 4 | vaultIterations |
| 44 | 4 | vaultParallelism |
| 48 | 60 | wrappedKey（原 combined 字节） |
| 108 | 60 | recoveryWrappedKey（原 combined 字节） |
| 168 | 16 | hkdfSalt |
| 184 | 12 | wrapNonce |
| 196 | 32 | wrappedFK（密文） |
| 228 | 16 | wrapTag |

### 6.3 认证范围

| 对象 | AAD |
| --- | --- |
| 第 i 个槽位的 FK 包裹 | FixedHeader[0..<60] ‖ UInt8(i) ‖ 该槽位从起点到 wrapNonce 之前的全部字节 |
| 数据区 | 完整 HeaderArea |

因此，修改、删除、增加或重排任何槽位，以及修改固定头的任何字节，都会导致数据区认证失败。

### 6.4 文件大小

| 模式 | HeaderArea | 最小文件（空保险库） |
| --- | ---: | ---: |
| 仅保险库槽 | 304 | 65856 |
| 仅密码槽 | 152 | 65704 |
| 两个槽位 | 396 | 65948 |

### 6.5 版本规则

- v1 只接受 version = 1；未知版本提示“需要更新 Aegis”，不尝试猜测解析。
- 所有 zero 字段必须为 0；未知槽位类型直接拒绝。
- 将来任何字段语义、算法或数据区格式的变化，都必须提升 version。
- 魔术值匹配后即锁定 ABB 解析器，任何失败都不回退到其他格式解析。

## 7. 数据区明文

### 7.1 固定前缀（212 字节）

| 偏移 | 长度 | 类型 | 字段 | 规则 |
| ---: | ---: | --- | --- | --- |
| 0 | 8 | Int64 | exportedAtMillis | 0 到 253402300799999；不参与版本新旧判断 |
| 8 | 4 | UInt32 | flags | bit 0 = 版本图不完整；其余位必须为 0 |
| 12 | 16 | UUID | vaultID | |
| 28 | 32 | bytes | vaultKey | VK；禁止进入日志、遥测、错误内容或可观察的 UI 状态 |
| 60 | 16 | bytes | vaultSalt | |
| 76 | 4 | UInt32 | vaultMemoryKiB | |
| 80 | 4 | UInt32 | vaultIterations | |
| 84 | 4 | UInt32 | vaultParallelism | |
| 88 | 60 | bytes | wrappedKey | |
| 148 | 60 | bytes | recoveryWrappedKey | |
| 208 | 4 | UInt32 | revisionCount | 可以为 0 |

VaultHeader.formatVersion 隐含为 1。若文件含有保险库槽：槽中的 header 字段必须与此处逐字节相同；保险库槽必须能用此处的 vaultKey 解出同一个 FK（即使文件是用备份密码打开的）；通过主密码或恢复密钥得到的 VK 必须与 vaultKey 常量时间比较相等。

### 7.2 记录（revisionCount 条，紧随前缀）

| 偏移 | 长度 | 类型 | 字段 |
| ---: | ---: | --- | --- |
| 0 | 16 | UUID | itemID |
| 16 | 16 | UUID | revisionID |
| 32 | 2 | UInt16 | parentCount（0 到 1000） |
| 34 | 16 × parentCount | UUID[] | parents |
| 之后 | 4 | UInt32 | sealedLength（28 到 300000） |
| 之后 | sealedLength | bytes | sealedRevision（原 EncryptedRevision.ciphertext 的 combined 字节） |

- 记录按 revisionID 原始字节严格升序排列，不允许重复，包括内容相同的重复。
- parents 严格升序、不重复、不含自身。
- EncryptedRevision.formatVersion 隐含为 1；vaultID 取自前缀。

### 7.3 填充

最后一条记录之后到 payloadLength 末尾为填充，所有字节必须为 0。导出时把明文填充到 65536 的最小正整数倍。

### 7.4 内容范围

包含：登录、银行卡、安全笔记、Markdown 备注、收藏、删除标记、历史版本、并发冲突及其关系。

不包含：未保存的表单、加密草稿、待确认的恢复密钥明文、Keychain 数据、CloudKit 账号与同步游标、设备 ID、自动填充设置、界面偏好。

## 8. 验证与资源上限

### 8.1 运行 KDF 之前

1. 在读取前检查文件大小；使用有上限的读取，读取后再次核对实际字节数。
2. 检查 magic、version、zero 字段、slotCount、槽位类型与顺序。
3. 用 checked arithmetic 核对：payloadLength 是 65536 的正整数倍、不超过上限，且文件总长度恰好吻合。
4. 密码槽参数必须属于支持集合；保险库槽参数必须通过 `KDFParameters.validate()`。

### 8.2 解密之后

1. 槽位打开后：常量时间比较 commitment，再用 payloadKey 打开数据区。
2. 解析前缀与记录：每读取一个数量或长度，都先与资源上限和剩余字节数比较，再分配内存。
3. 核对 §7.1 中槽位与数据区的一致性。
4. 用 VK 解密每条记录：按 (vaultID, itemID, revisionID, parents) 重建原 AAD；明文不超过 262144 字节；解码 VaultItem 后 item.id 必须等于 itemID。
5. 版本图：文件内存在的父节点必须属于同一条目；用有界的迭代算法检测多节点环。父节点既不在文件中、也不在本地时：flags.bit0 = 1 则接受并提示历史不完整，flags.bit0 = 0 则判为损坏。
6. 不用未经认证的父指针隐藏条目，不静默丢弃无法解密的记录。

### 8.3 资源上限（BackupLimits，导入导出共用）

| 限制 | 值 |
| --- | --- |
| payloadLength | ≤ 32 MiB（33554432） |
| revisionCount | ≤ 100000 |
| 单记录 parentCount | ≤ 1000 |
| 全文件 parents 总数 | ≤ 250000 |
| sealedLength | 28 到 300000 |
| 备份密码 UTF-8 | ≤ 4096 字节 |
| 密码槽 Argon2 | 只接受 65536 KiB / 3 / 1 |

- 导出前按相同的上限检查；超限时明确报错，不截断，也不静默漏掉历史。
- 单块 GCM 的峰值内存约为“读取的文件 + 明文 + 记录模型”加上 Argon2 的 64 MiB，最坏约 170 MB，在主 App 中可以接受；需要在最低支持设备上实测确认。
- 将来提高上限或引入分块，都需要提升 version。

## 9. 导出流程

    已解锁会话
      → 设备所有者验证（不可用时验证主密码）
      → 选择模式；备份密码模式输入两次密码
      → VaultStore 一次 actor 调用取得 header 与全部 revisions 的一致快照
      → 核对会话 VK 与快照的 vaultID 和 generation
      → 编码明文、填充，计算 flags.bit0
      → 生成 FK、commitment、payloadNonce，构造固定头
      → 生成各槽位（密码槽执行一次 Argon2id；保险库槽执行 HKDF）
      → AES-GCM 加密数据区，AAD = HeaderArea
      → 用同一个导入校验器回读验证生成的字节（复用已得到的 KEK，不重新运行 Argon2）
      → 清理密码、KEK、FK、VK、明文等可控的临时引用
      → 交给系统 fileExporter 保存

- 取得快照后发生的编辑归入下一次备份。
- 生成完成前取消或锁定：停止，不弹出保存窗口。已生成并通过验证的文件只含密文，可以继续保存。
- flags.bit0 = 1 时，在保存前提示“部分历史尚未同步到本机，此备份不完整”。
- 默认文件名为 `Aegis-YYYY-MM-DD.aegis`，不包含保险库名称或条目信息。

## 10. 导入流程与事务

    选择文件
      → 有界读取成一份不可变的字节快照
      → §8.1 检查
      → 输入一次凭据（§4.3）
      → 解密并完成 §8.2 全部验证
      → 本地身份检查（§4.4）
      → 显示恢复预览
      → 用户确认
      → VaultStore.restore：单次 actor 调用完成合并、提交或回滚
      → 若本机原本没有保险库：检查 generation 后以 VK 进入已解锁状态
      → 发布自动填充快照，按既有账号规则同步

### 10.1 文件访问

- 使用 security-scoped URL。检查、验证、确认后提交的必须是同一份字节快照，不能重新读取原路径。
- 读取、Argon2、解密都不在主线程执行。
- 选择新文件时，立即清除上一次的凭据和验证结果。

### 10.2 预览

只在认证成功后显示：导出时间、有效条目数、历史版本数、回收站条目数、冲突数、新增版本数、已存在版本数，以及历史不完整提示。由密码槽恢复时显示 §4.5 的说明。

### 10.3 存储事务

- 校验和预览阶段不写数据库，也不写同步 outbox。
- `VaultStore.restore(header:revisions:)` 在一次 actor 调用内完成：重新检查本地 header；对已存在的 revisionID 逐字节比较，不同则拒绝；插入缺失的 header 和记录（pending = true）；执行一次 `save()`；任何错误都先 `modelContext.rollback()` 再抛出。
- 合并是不可变版本的并集，因此重复导入同一文件是幂等的；本地较新的版本不会被删除。
- 预览之后本地新增的版本由 restore 的实际结果反映，返回值给出实际插入的数量。
- 提交只写入密文，不依赖会话是否已解锁。“进入已解锁状态”是独立的后一步，由现有 generation token 守护：期间发生锁定或账号变化，就保持锁定，不由异步回调自动解锁。
- 账号变化会阻止新的同步发布。

### 10.4 提交后的失败

数据库提交成功后，自动填充发布或 iCloud 同步失败，不视为导入失败，也不回滚本地恢复。分别提示“已恢复到本机”和后续服务的状态，并支持重试。

## 11. 错误分类

| 情况 | 提示 |
| --- | --- |
| magic 不匹配 | 不是受支持的 Aegis 备份 |
| 未知 version | 此备份需要更新版本的 Aegis |
| 长度、结构、zero 字段错误（KDF 之前） | 文件损坏或不完整 |
| 不支持的 KDF 参数 | 此备份的加密参数暂不受支持 |
| 所有槽位都打不开（包括固定头被修改，因为每个槽位都认证固定头） | 密码或恢复密钥不正确，或文件已被修改 |
| 槽位已打开，但 commitment 或数据区认证失败；或主密码/恢复密钥已证明正确，但保险库槽打不开 | 文件已损坏或被修改 |
| 数据区已解密，但记录或版本图验证失败 | 备份内容未通过完整性检查 |
| 本机保险库已锁定 | 请先解锁保险库再导入 |
| 不同保险库或不兼容的 header | 无法合并到当前保险库 |
| 超出资源上限 | 文件超过当前版本可处理的范围 |
| 事务保存失败 | 恢复未完成，本地数据保持原状 |
| 提交后同步失败 | 已恢复到本机，iCloud 同步尚未完成 |
| 导出时设备验证失败或取消 | 安静返回，不生成文件 |
| 用户取消 | 安静退出 |

所有文案都进入 String Catalog；产品界面不出现 AAD、nonce、KDF 等术语。

## 12. 兼容与类型注册

### 12.1 外部备份格式

- Aegis 只导出和导入 ABB v1 二进制备份。
- 非 ABB 魔术值的文件直接提示“不是受支持的 Aegis 备份”，不会尝试 JSON 兼容解析。
- ABB 魔术值匹配后即锁定 ABB 解析器，任何失败都不会回退到其他格式。

### 12.2 类型注册

- 新增导出类型 `app.aegis.backup`，扩展名 `aegis`，conforms to `public.data`。
- 只注册 `app.aegis.backup` / `aegis`；旧备份类型不再注册。
- 同步更新 `project.yml` 与 `UtilityViews.swift` 中的 UTType；分别在 macOS 和 iOS 上验证文件选择器与保存器。

### 12.3 自动填充

- 内部 `autofill.aegis` 仍使用 JSON 快照，通过专用 codec 读取；不能根据扩展名推断它是 ABB。
- 二进制备份恢复后，JSON 快照可能超过扩展的 32 MiB 限制：发布时检查大小，超限时在主 App 中明确提示自动填充不可用，并加集成测试覆盖。

## 13. 模块划分

| 模块 | 位置 | 职责 |
| --- | --- | --- |
| BackupFormat | AegisCore | 文件头、槽位、数据区的纯编解码与结构校验；无 I/O、无密钥状态 |
| BackupCryptor | AegisCore | FK、槽位、commitment、数据区加解密；复用 `SecureRandom`、`Argon2id` 和 VaultCrypto 的解包逻辑 |
| BackupLimits | AegisCore | §8.3 的上限，导入导出共用 |
| BackupValidator | AegisCore | 记录认证、版本图检查 |
| VaultStore.snapshot / restore | AegisStorage | 一致快照；单次事务的合并、提交与回滚 |
| VaultSession 导入导出 | App | 设备验证、generation、取消、进入解锁状态 |
| 导出与导入视图 | App | 模式选择、单输入框、预览与错误提示 |

不新增第三方依赖：CryptoKit 提供 AES-GCM、HKDF 和 SHA-256；LocalAuthentication 提供设备验证；Argon2 使用仓库中已有的 CArgon2。

## 14. 测试矩阵

### 14.1 字节协议

- 固定头、两种槽位的每个偏移；小端序；UUID 字节顺序。
- 三种模式的最小文件长度（§6.4）。
- 在每个结构边界截断；尾部追加字节；payloadLength 不是 65536 的倍数或超出上限。
- 非零 zero 字段或填充、未知槽位类型、重复槽位、槽位顺序错误、slotCount 为 0 或 3。
- 记录未排序或重复；parents 未排序、重复或含自身；parentCount、sealedLength、revisionCount 越界或超过剩余字节。
- 用一个独立的 Python 解析器（`Scripts/backup_format_reference.py`，PEP 723）对 Swift 生成的 golden 样本做交叉核对。`Scripts/test.sh` 自动通过 `uv` 安装 `cryptography` 与 `argon2-cffi` 并运行结构和加密检查；缺少 `uv` 时测试直接失败，不再跳过加密互操作。golden 文件由 Swift 测试在 `AEGIS_RECORD_FIXTURES=1` 下重新生成，生成后必须再次验证。

### 14.2 密码学

- 保留现有 Argon2id 已知答案测试。
- 固定测试向量：在测试中注入随机源，记录 FK、各 KEK、commitment、header、密文、tag 的完整输出。
- 修改文件头、任一槽位、密文、tag 的任意字节，都必须被拒绝。
- 把槽位移植到另一个文件、交换槽位顺序、删除一个槽位：都必须被拒绝。
- 构造“槽位能打开，但 commitment 不匹配”的样本，必须报“文件已损坏或被修改”。
- 双槽位文件：主密码、恢复密钥、备份密码三种凭据各自都能打开，并且解出的明文逐字节相同。
- “仅备份密码”文件：主密码和恢复密钥都打不开。
- 备份密码 NFC 与 NFD 输入等价；主密码保持原始字节；前后空格、中文、emoji、最长 4096 字节。
- 同一内容重复导出，FK、各 nonce、各 salt 和文件字节都不同，解密结果相同。
- 往返后记录 AAD 不变（大写 `uuidString`、parents 排序）。
- 保险库槽参数取 `validate()` 允许的上限时，测量耗时并确认可以取消。

### 14.3 记录与恢复

- 三种条目、Markdown、收藏、回收站、空保险库、并发分支与合并版本。
- 单条记录密文损坏、itemID 错误、跨条目父节点、多节点环。
- 知道密码的作者构造的结构异常文件：外层合法，内层错误。
- 两个槽位中的 header 与数据区 header 不一致，或 VK 不一致：必须被拒绝。
- 本机已锁定时导入：必须被拒绝（DEC-5）。
- 新设备恢复后锁定，再用原主密码或恢复密钥解锁成功；备份密码不能用于日常解锁。
- 重复导入同一文件是幂等的；导入较旧的备份不会覆盖本地较新的版本。
- 不同保险库、同 ID 不同 header、同 revisionID 不同内容：都被拒绝。
- flags.bit0 为 0 或 1 时，缺失父节点分别被拒绝或被接受。

### 14.4 事务、故障与性能

- P0 回归测试：让 `restore` 保存失败后再调用其他保存操作，数据库中不能出现恢复事务的对象（DEC-12）。
- 磁盘满、拒绝文件访问、文件提供方下载失败、应用被中断。
- KDF 运行期间锁定、预览期间云端更新、账号切换、提交后立即锁定。
- 在最低支持系统和低内存设备上测量峰值内存、Argon2 延迟、总耗时与取消响应。
- 自动填充 JSON 快照超过 32 MiB 的场景。
- 保存到真实文件、重启应用、从文件恢复，不能只做内存往返。
- VoiceOver、Dynamic Type、错误弹窗与中文文案。

## 15. 原审查问题的结论

| 编号 | 结论 |
| --- | --- |
| R1 | 默认模式和默认的备份密码模式都带有保险库槽，主密码与恢复密钥任一可用即可恢复。只有密码槽且主密码与恢复密钥都已丢失的情况，依赖后续的密钥头轮换功能（DEC-13）。 |
| R2 | 接受。保险库槽本身不额外暴露 VK；含密码槽的文件，其备份密码的权限等同于主密码，界面上要明确说明。VK 不轮换列为已知限制。 |
| R3 | 保险库槽在密码学上证明了 wrappedKey 与 VK 一致。只有密码槽时无法证明，依靠 iCloud header 比对加预览提示（§4.5）。 |
| R4 | 可以实现：提交是单次 actor 事务，失败即回滚；提交与“进入解锁状态”分为两步，后者由 generation 守护（§10.3）。 |
| R5 | 允许导出，设置 flags.bit0，并在两端提示（DEC-9）。 |
| R6 | 32 MiB 单块 GCM 加 64 MiB Argon2 可以接受，需要在设备上实测；v1 不分块。 |
| R7 | 用户 ABB 入口与自动填充内部 JSON 快照分离，并检查快照大小（§12）。 |
| R8 | 只有一个版本号，槽位与固定头都受数据区 AAD 覆盖，魔术值匹配后不回退到旧解析器，不存在降级路径。 |

## 16. 实施顺序与验证点

| 步骤 | 内容 | 验证点 |
| --- | --- | --- |
| P0 | 修复 `VaultStore.restore` 失败后不回滚 | 先写失败测试复现，修复后通过 |
| P1 | BackupFormat 纯编解码与 BackupLimits | §14.1 全部通过；Python 解析器交叉核对 |
| P2 | BackupCryptor 与 BackupValidator | §14.2、§14.3 中的密码学与图验证测试通过 |
| P3 | VaultStore.snapshot 与 restore 事务 | §14.4 的故障注入测试通过 |
| P4 | VaultSession、设备验证、导入导出界面 | 单输入框流程、锁定拒绝、generation 竞争测试通过 |
| P5 | ABB UTType 与自动填充内部快照 | macOS 与 iOS 上真机或模拟器手动验证文件选择器与保存器；集成测试通过 |

## 17. 后续独立设计

- 修改主密码 / 重新生成恢复密钥：CloudKit header 需要引入 epoch 并支持更新。
- VK 轮换：需要重新加密全部记录并迁移同步身份。
- 主密码的 Unicode 归一化：属于保险库层面的既有问题，需要单独做迁移设计。

## 18. 源码索引

- [数据结构与参数校验](../Packages/AegisKit/Sources/AegisCore/Models.swift)
- [密钥与记录加密](../Packages/AegisKit/Sources/AegisCore/VaultCrypto.swift)
- [存储、备份与导入](../Packages/AegisKit/Sources/AegisStorage/VaultStore.swift)
- [会话与文件恢复](../App/Services/VaultSession.swift)
- [导入导出界面](../App/Views/UtilityViews.swift)
- [自动填充读取](../AutoFill/CredentialProviderViewController.swift)
- [CloudKit 同步](../Packages/AegisKit/Sources/AegisSync/CloudSync.swift)
- [架构约定](ARCHITECTURE.md)
- [现有测试](../Packages/AegisKit/Tests/AegisCoreTests/VaultTests.swift)
- [项目与文件类型注册](../project.yml)
