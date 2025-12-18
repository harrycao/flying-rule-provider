# flying-rule-provider

一个用于处理和推送规则集文件的工具，能够自动为IP相关规则添加no-resolve标记，并通过GitHub API推送到指定仓库。

## 功能特点

- 下载并处理来自指定URL的YAML格式rule-set文件
- 自动为IP相关规则（IP-CIDR、IP-CIDR6、GEOIP、IP-ASN）添加`no-resolve`标记
- **纯Bash实现，无任何外部依赖**（包括Python）
- 通过GitHub API直接推送到仓库，无需本地Git配置
- 支持Dry-run模式，仅处理文件不推送
- 彩色输出，清晰的执行日志

## 使用方法

### 单文件处理

```bash
./process-rules.sh -t <GITHUB_TOKEN> -r <OWNER/REPO> <RULE_URL>
```

### 批量处理

```bash
./process-rules.sh -f <CONFIG_FILE> -t <GITHUB_TOKEN> -r <OWNER/REPO>
```

批量处理允许一次性处理多个规则文件，通过配置文件指定待处理的文件列表。

### 完整参数

```bash
./process-rules.sh [OPTIONS] <URL>    # 单文件模式
./process-rules.sh -f <CONFIG_FILE> [OPTIONS]  # 批量模式

OPTIONS:
    -t, --token TOKEN        GitHub token (必需)
    -r, --repo REPO          GitHub仓库，格式为 owner/repo (必需)
    -b, --branch BRANCH      目标分支 (默认: main)
    -c, --commit-msg MSG     提交消息 (默认: 自动生成)
    -f, --config-file FILE   批量处理配置文件
    --dry-run                仅处理文件，不推送到GitHub
    -h, --help               显示帮助信息
```

### 示例

1. **处理规则并推送到主分支**：
```bash
./process-rules.sh \
  --token ghp_xxxxxxxxxxxxxxxxxxxx \
  --repo username/rules-repo \
  https://example.com/rules.yaml
```

2. **推送到指定分支**：
```bash
./process-rules.sh \
  -t ghp_xxx \
  -r username/rules-repo \
  -b development \
  https://example.com/rules.yaml
```

3. **Dry-run模式（仅本地处理）**：
```bash
./process-rules.sh \
  --dry-run \
  https://example.com/rules.yaml
```

4. **自定义提交消息**：
```bash
./process-rules.sh \
  -t ghp_xxx \
  -r username/rules-repo \
  -c "Update ad rules with no-resolve" \
  https://example.com/ad-rules.yaml
```

5. **批量处理示例**：
```bash
./process-rules.sh \
  -f batch-config.yaml \
  -t ghp_xxx \
  -r username/rules-repo
```

6. **批量处理（Dry-run模式）**：
```bash
./process-rules.sh \
  -f batch-config.yaml \
  --dry-run
```

7. **实际使用示例（Telegram规则集）**：
```bash
./process-rules.sh \
  --dry-run \
  https://cdn.jsdelivr.net/gh/blackmatrix7/ios_rule_script@master/rule/Clash/Telegram/Telegram.yaml
```

## GitHub Token 配置

1. 访问 [GitHub Settings > Developer settings > Personal access tokens](https://github.com/settings/tokens)
2. 点击 "Generate new token (classic)"
3. 选择以下权限：
   - `repo` - 完整的仓库访问权限
   - `workflow` - 如果需要更新GitHub Actions文件
4. 复制生成的token

## 批量处理配置文件

批量处理使用简单的文本文件，每行一个URL。空行和以`#`开头的行会被忽略。

示例文件 `urls.txt`：
```
# 社交媒体规则
https://cdn.jsdelivr.net/gh/blackmatrix7/ios_rule_script@master/rule/Clash/Telegram/Telegram.yaml
https://cdn.jsdelivr.net/gh/blackmatrix7/ios_rule_script@master/rule/Clash/Twitter/Twitter.yaml

# 视频服务规则
https://cdn.jsdelivr.net/gh/blackmatrix7/ios_rule_script@master/rule/Clash/YouTube/YouTube.yaml
https://cdn.jsdelivr.net/gh/blackmatrix7/ios_rule_script@master/rule/Clash/Netflix/Netflix.yaml
```

### 配置文件特点

- 纯文本格式，易于编辑
- 支持注释（`#` 开头的行）
- 忽略空行
- 每行一个URL
- 输出文件名自动从URL提取，处理后保持原名
- IP相关规则会自动添加 `no-resolve` 标记

参考文件：`urls.txt`

## 支持的文件格式

仅支持YAML/YML格式的规则文件，如Clash规则集格式：

```yaml
# NAME: Telegram
# AUTHOR: blackmatrix7
payload:
  - DOMAIN-SUFFIX,telegram.org
  - IP-CIDR,91.108.0.0/16         # 将自动添加 no-resolve
  - IP-CIDR6,2001:67c:4e8::/48    # 将自动添加 no-resolve
  - GEOIP,CN                       # 将自动添加 no-resolve
  - IP-ASN,12345                   # 将自动添加 no-resolve
```

## 自动处理规则

脚本会自动识别以下类型的规则并添加`no-resolve`标记：
- `IP-CIDR` - IPv4 CIDR规则
- `IP-CIDR6` - IPv6 CIDR规则
- `GEOIP` - 地理位置IP规则
- `IP-ASN` - 自治系统号码规则

## 注意事项

1. 确保GitHub Token有足够的权限
2. 目标分支必须存在于仓库中
3. 处理后的文件保存在 `rules/` 目录，会覆盖原文件
4. Dry-run模式适合测试脚本功能
5. 脚本仅处理YAML/YML格式文件
6. 处理后的文件保持原名，直接修改原文件内容

## 测试

使用 `--dry-run` 参数进行测试，不会实际推送到GitHub：

```bash
# 单文件测试
./process-rules.sh --dry-run https://cdn.jsdelivr.net/gh/blackmatrix7/ios_rule_script@master/rule/Clash/Telegram/Telegram.yaml

# 批量处理测试
./process-rules.sh -f urls.txt --dry-run
```

测试时会显示处理过程，文件会保存在本地的 `rules/` 目录中。

## 错误处理

脚本包含完整的错误处理机制：
- 网络请求失败
- 文件格式不支持
- GitHub API错误
- 权限不足

## 安全性

- 不会在日志中显示完整的GitHub Token
- 使用set -e确保遇到错误立即退出
- 所有文件操作都在指定目录内进行