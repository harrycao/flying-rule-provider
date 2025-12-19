#!/bin/bash

# flying-rule-provider processor
# 用于转换rule-set文件并推送到GitHub仓库

# Only exit on error in critical sections, not during batch processing
# We'll handle errors individually in each function

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 打印带颜色的消息
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_debug() {
    if [[ "$DEBUG_MODE" == true ]]; then
        echo -e "${YELLOW}[DEBUG]${NC} $1"
    fi
}

# 显示帮助信息
show_help() {
    cat << EOF
Usage: $0 [OPTIONS] <URL> or $0 -f <CONFIG_FILE>

Process rule-set files from URLs and push to GitHub.

SINGLE FILE MODE:
    $0 [OPTIONS] <URL>

BATCH MODE:
    $0 -f <CONFIG_FILE> [OPTIONS]

OPTIONS:
    -t, --token TOKEN        GitHub token (required)
    -r, --repo REPO          GitHub repository in format owner/repo (required)
    -b, --branch BRANCH      Target branch (default: main)
    -c, --commit-msg MSG     Commit message (default: auto-generated)
    -f, --config-file FILE   Config file with list of URLs to process
    --dry-run                Only process files without pushing to GitHub
    --debug                  Enable debug logging with hash values
    -h, --help               Show this help message

EXAMPLES:
    # Single file
    $0 -t ghp_xxx -r user/repo https://example.com/rules.yaml

    # Batch processing
    $0 -f urls.txt -t ghp_xxx -r user/repo

    # With custom branch
    $0 -f urls.txt -t ghp_xxx -r user/repo -b dev

CONFIG FILE FORMAT:
    Simple text file with one URL per line.
    Empty lines and lines starting with # are ignored.

    Example (urls.txt):
    # Social media rules
    https://cdn.jsdelivr.net/gh/blackmatrix7/ios_rule_script@master/rule/Clash/Telegram/Telegram.yaml
    https://cdn.jsdelivr.net/gh/blackmatrix7/ios_rule_script@master/rule/Clash/Twitter/Twitter.yaml

    # Ad blocking rules
    https://example.com/google-ads.yaml
    https://example.com/facebook-ads.yaml

EOF
}

# 解析命令行参数
GITHUB_TOKEN=""
REPO=""
BRANCH="main"
DEBUG_MODE=false
# 固定输出目录为 rules
OUTPUT_DIR="rules"
COMMIT_MSG=""
DRY_RUN=false
RULE_URL=""
CONFIG_FILE=""
BATCH_MODE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -t|--token)
            GITHUB_TOKEN="$2"
            shift 2
            ;;
        -r|--repo)
            REPO="$2"
            shift 2
            ;;
        -b|--branch)
            BRANCH="$2"
            shift 2
            ;;
        -c|--commit-msg)
            COMMIT_MSG="$2"
            shift 2
            ;;
        -f|--config-file)
            CONFIG_FILE="$2"
            BATCH_MODE=true
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --debug)
            DEBUG_MODE=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        -*)
            print_error "Unknown option: $1"
            show_help
            exit 1
            ;;
        *)
            if [[ "$BATCH_MODE" == true ]]; then
                print_error "URL cannot be specified when using config file mode"
                exit 1
            fi
            RULE_URL="$1"
            shift
            ;;
    esac
done

# 验证必需参数
if [[ "$BATCH_MODE" == false && -z "$RULE_URL" ]]; then
    print_error "Rule URL is required"
    show_help
    exit 1
fi

if [[ "$BATCH_MODE" == true && -z "$CONFIG_FILE" ]]; then
    print_error "Config file is required in batch mode"
    show_help
    exit 1
fi

if [[ -z "$GITHUB_TOKEN" || -z "$REPO" ]]; then
    if [[ "$DRY_RUN" != true ]]; then
        print_error "GitHub token and repository are required (unless --dry-run)"
        show_help
        exit 1
    fi
fi

# 处理单个文件的函数
process_rule_file() {
    local url="$1"
    local output_name="$2"
    local commit_msg="$3"

    # 从URL提取文件名
    local filename="$output_name"
    if [[ -z "$filename" ]]; then
        filename=$(basename "$url")
        if [[ -z "$filename" || "$filename" == *"?"* ]]; then
            filename="rules.yaml"
        fi
    fi

    # 下载rule-set文件
    print_info "Downloading rule-set from: $url"
    if ! curl -fsSL -o "rules/$filename" "$url"; then
        print_error "Failed to download rule-set file: $url"
        return 1
    fi

    # 处理文件
    print_info "Processing rule-set file: $filename"
    local file_path="rules/$filename"

    # 检测文件格式并处理
    if [[ "$filename" == *.yaml || "$filename" == *.yml ]]; then
        # 使用bash处理YAML文件
        print_info "Processing YAML file..."

        # 统计修改数量
        local modified_count=0

        # 创建临时文件
        local temp_file=$(mktemp)

        # 逐行处理文件
        while IFS= read -r line || [[ -n "$line" ]]; do
            # 匹配IP规则行: - IP-CIDR,xxx 或 - IP-CIDR6,xxx 或 - GEOIP,xxx 或 - IP-ASN,xxx
            if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+(IP-CIDR|IP-CIDR6|GEOIP|IP-ASN),.+$ ]]; then
                # 如果还没有no-resolve，则添加
                if [[ ! "$line" =~ ,no-resolve[[:space:]]*$ ]]; then
                    echo "${line},no-resolve"
                    ((modified_count++))
                else
                    echo "$line"
                fi
            else
                echo "$line"
            fi
        done < "$file_path" > "$temp_file"

        # 替换原文件
        mv "$temp_file" "$file_path"

        print_info "Added no-resolve to $modified_count IP rule(s)"
    else
        print_error "Unsupported file format: $filename"
        print_info "Supported formats: .yaml, .yml"
        return 1
    fi

    print_info "Processed file saved to: $file_path"

    # 总是进行文件比较（包括dry-run模式）
    local remote_path="rules/$filename"
    local would_upload=true

    # Only check remote file if we have GitHub credentials
    if [[ -n "$GITHUB_TOKEN" && -n "$REPO" ]]; then
        if compare_with_remote_file "$file_path" "$remote_path"; then
            would_upload=false
        fi
    fi

    # 推送到GitHub（如果不是dry-run）
    if [[ "$DRY_RUN" == false ]]; then
        if [[ "$would_upload" == true ]]; then
            # 使用自定义提交消息或默认消息
            local final_commit_msg="$commit_msg"
            if [[ -z "$final_commit_msg" ]]; then
                final_commit_msg="Update rule-set: $filename (auto-add no-resolve to IP rules)"
            fi

            # 推送文件到GitHub
            push_to_github "$file_path" "$final_commit_msg"
        else
            print_info "Skipping upload: file is unchanged"
        fi
    else
        # Dry-run mode - show what would happen
        if [[ "$would_upload" == true ]]; then
            print_info "[DRY-RUN] Would upload: $filename (file has changed)"
        else
            print_info "[DRY-RUN] Would skip: $filename (file unchanged)"
        fi
    fi

    return 0
}

# 推送文件到GitHub的函数
push_to_github() {
    local file_path="$1"
    local commit_message="$2"
    local file_name=$(basename "$file_path")

    print_info "Pushing $file_name to GitHub (rules/$file_name)..."

    # 获取当前分支的SHA
    print_info "Getting current branch information..."
    local branch_response=$(curl -s \
        -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/$REPO/branches/$BRANCH")

    # 提取SHA（无需Python）
    local base_tree=$(echo "$branch_response" | sed -n 's/.*"sha": "\([a-f0-9]\{40\}\)".*/\1/p' | head -1)

    if [[ -z "$base_tree" ]]; then
        print_error "Failed to get branch information. Please check if the branch exists."
        print_error "Response: $branch_response"
        return 1
    fi

    # 创建文件blob
    print_info "Creating file blob..."
    # 检测系统类型
    local file_b64
    if [[ "$(uname)" == "Darwin" ]]; then
        # macOS - use -i flag and remove line breaks
        file_b64=$(base64 -i "$file_path" | tr -d '\n')
    else
        # Linux
        file_b64=$(base64 -w 0 "$file_path")
    fi

    # 创建blob
    local blob_json=$(mktemp)
    cat > "$blob_json" << EOF
{
    "content": "$file_b64",
    "encoding": "base64"
}
EOF

    local blob_response=$(curl -s \
        -X POST \
        -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        -H "Content-Type: application/json" \
        -d @"$blob_json" \
        "https://api.github.com/repos/$REPO/git/blobs")

    rm -f "$blob_json"

    local blob_sha=$(echo "$blob_response" | sed -n 's/.*"sha": "\([a-f0-9]\{40\}\)".*/\1/p' | head -1)

    if [[ -z "$blob_sha" ]]; then
        print_error "Failed to create file blob"
        print_error "Response: $blob_response"
        return 1
    fi

    # 创建tree
    print_info "Creating tree..."
    # 确保文件上传到rules目录
    local file_name=$(basename "$file_path")
    local relative_path="rules/$file_name"

    local tree_json=$(mktemp)
    cat > "$tree_json" << EOF
{
    "base_tree": "$base_tree",
    "tree": [
        {
            "path": "$relative_path",
            "mode": "100644",
            "type": "blob",
            "sha": "$blob_sha"
        }
    ]
}
EOF

    local tree_response=$(curl -s \
        -X POST \
        -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        -H "Content-Type: application/json" \
        -d @"$tree_json" \
        "https://api.github.com/repos/$REPO/git/trees")

    rm -f "$tree_json"

    local tree_sha=$(echo "$tree_response" | sed -n 's/.*"sha": "\([a-f0-9]\{40\}\)".*/\1/p' | head -1)

    # 检查TREE_SHA是否有效（40个字符的十六进制）
    if [[ -z "$tree_sha" || ${#tree_sha} -ne 40 ]]; then
        print_error "Failed to create tree or invalid tree SHA"
        print_error "Response: $tree_response"
        print_error "Extracted SHA: '$tree_sha' (length: ${#tree_sha})"
        return 1
    fi

    # 创建commit
    print_info "Creating commit..."
    # 创建临时JSON文件来避免shell中的转义问题
    local json_file=$(mktemp)
    cat > "$json_file" << EOF
{
    "message": "$commit_message",
    "parents": ["$base_tree"],
    "tree": "$tree_sha"
}
EOF

    local commit_response=$(curl -s \
        -X POST \
        -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        -H "Content-Type: application/json" \
        -d @"$json_file" \
        "https://api.github.com/repos/$REPO/git/commits")

    # 清理临时文件
    rm -f "$json_file"

    local commit_sha=$(echo "$commit_response" | sed -n 's/.*"sha": "\([a-f0-9]\{40\}\)".*/\1/p' | head -1)

    if [[ -z "$commit_sha" ]]; then
        print_error "Failed to create commit"
        print_error "Response: $commit_response"
        return 1
    fi

    # 更新分支引用
    print_info "Updating branch reference..."
    local update_json=$(mktemp)
    cat > "$update_json" << EOF
{
    "sha": "$commit_sha",
    "force": false
}
EOF

    local update_response=$(curl -s \
        -X PATCH \
        -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        -H "Content-Type: application/json" \
        -d @"$update_json" \
        "https://api.github.com/repos/$REPO/git/refs/heads/$BRANCH")

    rm -f "$update_json"

    if [[ -n "$update_response" ]]; then
        print_info "Successfully pushed $file_name to GitHub!"
        print_info "Commit: $commit_sha"
    else
        print_error "Failed to push to GitHub"
        return 1
    fi

    return 0
}

# 批量处理函数
process_batch() {
    local config_file="$1"

    print_info "Processing URLs from: $config_file"

    # 检查配置文件是否存在
    if [[ ! -f "$config_file" ]]; then
        print_error "Config file not found: $config_file"
        exit 1
    fi

    # 创建rules目录
    mkdir -p "rules"
    print_info "Output directory: rules"

    # 读取所有URL（忽略空行和注释）
    local urls=()
    while IFS= read -r line; do
        # 跳过空行和注释
        [[ -z "${line// }" ]] && continue
        [[ "$line" =~ ^# ]] && continue

        # 添加URL
        urls+=("$line")
    done < "$config_file"

    local total_count=${#urls[@]}
    local success_count=0

    print_info "Found $total_count URL(s) to process"

    # 处理每个URL
    for url in "${urls[@]}"; do
        local filename=$(basename "$url")
        if [[ -z "$filename" || "$filename" == *"?"* ]]; then
            filename="rules.yaml"
        fi

        print_info ""
        print_info "=== Processing: $filename ==="
        print_debug "URL: $url"

        # Reset error handling for each file
        set +e
        if process_rule_file "$url" ""; then
            ((success_count++))
            print_debug "Successfully processed: $filename"
        else
            print_error "Failed to process: $url"
        fi
        set -e
    done

    print_info ""
    print_info "Batch processing completed: $success_count/$total_count files processed successfully"

    return 0
}

# Calculate SHA-256 hash of a file with cross-platform compatibility
calculate_file_hash() {
    local file_path="$1"
    local file_hash=""

    # Cross-platform SHA-256 calculation
    if command -v sha256sum >/dev/null 2>&1; then
        # Linux (sha256sum)
        file_hash=$(sha256sum "$file_path" | cut -d' ' -f1)
    elif command -v shasum >/dev/null 2>&1; then
        # macOS (shasum with -a 256)
        file_hash=$(shasum -a 256 "$file_path" | cut -d' ' -f1)
    elif command -v openssl >/dev/null 2>&1; then
        # Fallback to openssl
        file_hash=$(openssl dgst -sha256 "$file_path" | cut -d' ' -f2)
    else
        print_error "No SHA-256 command available"
        return 1
    fi

    echo "$file_hash"
    return 0
}

# Compare local file with remote file by downloading and hashing
compare_with_remote_file() {
    local local_file="$1"
    local remote_path="$2"  # Path in GitHub repo

    print_debug "Comparing file: $local_file with remote: $remote_path"

    # Get GitHub file info
    local api_url="https://api.github.com/repos/$REPO/contents/$remote_path"
    local response=$(curl -s \
        -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        "$api_url")

    # Check if file exists
    if echo "$response" | grep -q '"message": "Not Found"'; then
        print_info "File does not exist on GitHub, will upload"
        return 1  # Different, need upload
    fi

    # Extract and decode content
    local encoded_content=""

    # Extract content using sed with a more robust pattern
    # GitHub API returns JSON with base64 content that may be split across lines

    # First, let's debug what we received
    print_debug "GitHub API response status: $(echo "$response" | grep -o '"message":[^,]*' || echo 'OK')"
    print_debug "Response size: ${#response} characters"
    print_debug "Response preview: $(echo "$response" | head -c 200)"

    # Check if we got an error response first
    if echo "$response" | grep -q '"message"'; then
        local error_msg=$(echo "$response" | grep -o '"message":"[^"]*"' | cut -d'"' -f4)
        print_debug "GitHub API error: $error_msg"
        # Return 1 to indicate we need to upload (couldn't compare)
        return 1
    fi

    # Save response to temp file for debugging
    local debug_response_file=$(mktemp)
    echo "$response" > "$debug_response_file"
    print_debug "Full response saved to: $debug_response_file"

    # Try to extract the content field
    local temp_content=""

    # First, make sure we're dealing with a valid JSON response
    if [[ -z "$response" || "$response" == "{" ]]; then
        print_debug "Invalid or empty response"
        rm -f "$debug_response_file"
        return 1
    fi

    # Method 1: Remove all newlines first to make it a single line JSON
    local single_line_json=$(echo "$response" | tr -d '\n\r' | tr -s ' ')
    print_debug "After removing newlines: ${#single_line_json} chars"

    # Now extract using a simple pattern
    temp_content=$(echo "$single_line_json" | sed 's/.*"content": *"//' | sed 's/".*//')

    # Clean up debug file
    rm -f "$debug_response_file"

    # Debug the extracted content
    if [[ -n "$temp_content" ]]; then
        print_debug "Extracted ${#temp_content} characters of content"
        print_debug "Content starts with: ${temp_content:0:50}"
        print_debug "Content ends with: ${temp_content: -50}"
    fi

    # Process the extracted content
    if [[ -n "$temp_content" && ${#temp_content} -gt 10 && "$temp_content" != "{" ]]; then
        # Handle JSON escapes
        temp_content=$(echo "$temp_content" | sed 's/\\n/\n/g')
        temp_content=$(echo "$temp_content" | sed 's/\\"/"/g')
        temp_content=$(echo "$temp_content" | sed 's/\\\\/\\/g')

        # Remove all whitespace and newlines for clean base64
        encoded_content=$(echo "$temp_content" | tr -d ' \n\r\t')
    fi

    # Additional cleanup
    if [[ -n "$encoded_content" ]]; then
        # Collapse any remaining newlines that might be in the middle
        encoded_content=$(echo "$encoded_content" | paste -sd '' 2>/dev/null || echo "$encoded_content")
        print_debug "Encoded content length: ${#encoded_content}"
        print_debug "Encoded content (first 100 chars): ${encoded_content:0:100}"
    fi

    if [[ -z "$encoded_content" ]]; then
        print_warn "Failed to download remote content, proceeding with upload"
        return 1
    fi

    # Decode base64 content
    local temp_remote_file=$(mktemp)
    if echo "$encoded_content" | base64 -d > "$temp_remote_file" 2>&1; then
        # Calculate hashes
        local local_hash=$(calculate_file_hash "$local_file")
        local remote_hash=$(calculate_file_hash "$temp_remote_file")

        rm -f "$temp_remote_file"

        print_debug "Local hash:  $local_hash"
        print_debug "Remote hash: $remote_hash"

        if [[ "$local_hash" == "$remote_hash" ]]; then
            print_info "File unchanged (hash: $local_hash), skipping upload"
            return 0  # Same, no upload needed
        else
            return 1  # Different, need upload
        fi
    else
        # Capture the base64 decode error for debugging
        local decode_error=$(echo "$encoded_content" | base64 -d 2>&1 | head -1)
        rm -f "$temp_remote_file"
        print_debug "Base64 decode error: $decode_error"
        print_debug "Attempting to decode with: echo '$encoded_content' | base64 -d"
        print_warn "Failed to decode remote content, proceeding with upload"
        return 1
    fi
}

# 创建rules目录
mkdir -p "rules"
print_info "Output directory: rules"

# 根据模式执行处理
if [[ "$BATCH_MODE" == true ]]; then
    process_batch "$CONFIG_FILE"
else
    # 单文件模式
    process_rule_file "$RULE_URL" ""
fi

print_info "All done!"