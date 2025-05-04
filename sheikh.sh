#!/data/data/com.termux/files/usr/bin/bash

# Sheikh Agent v3.0 - Full Production Version
# Author: Likhon Dev (based on original concept)
# GitHub: https://github.com/likhonsdev/Prompt-Engineering
# License: MIT

# Configuration
MODEL="gemini-1.5-flash"
PROMPT_URL="https://raw.githubusercontent.com/likhonsdev/Prompt-Engineering/main/sheikh-agent/prompt.md"
LOCAL_PROMPT="prompt.md"
OUTPUT_DIR="generated_app"
MAX_RETRIES=5
TIMEOUT=45
API_KEY_FILE="$HOME/.sheikh_api_key"
CACHE_DIR="$HOME/.sheikh_cache"
LOG_FILE="$CACHE_DIR/agent.log"

# System Prompt (Critical for AI behavior)
SYSTEM_PROMPT="You are Sheikh Agent, an advanced AI application generator. Follow these rules:
1. STRICTLY adhere to MDX syntax in responses
2. Generate COMPLETE, PRODUCTION-READY code
3. Include ALL necessary files (configs, tests, etc.)
4. Use modern best practices
5. Validate all code before inclusion
6. Maintain consistent style throughout"

# Colors and formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# Initialize system
init_system() {
  [ ! -d "$CACHE_DIR" ] && mkdir -p "$CACHE_DIR"
  exec > >(tee -a "$LOG_FILE") 2>&1
  trap cleanup EXIT
}

# Cleanup function
cleanup() {
  if [ $? -ne 0 ]; then
    log "ERROR" "Script failed - check $LOG_FILE"
  fi
}

# Enhanced logging
log() {
  local level=$1
  local message=$2
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  
  case $level in
    "SUCCESS") color=$GREEN ;;
    "ERROR") color=$RED ;;
    "WARNING") color=$YELLOW ;;
    "INFO") color=$BLUE ;;
    *) color=$RESET ;;
  esac

  echo -e "${color}[${timestamp}] [${level}]${RESET} ${message}"
  echo "[${timestamp}] [${level}] ${message}" >> "$LOG_FILE"
}

# Check prerequisites
check_dependencies() {
  local missing=()
  for cmd in curl jq awk sed git; do
    if ! command -v "$cmd" &> /dev/null; then
      missing+=("$cmd")
    fi
  done

  if [ ${#missing[@]} -gt 0 ]; then
    log "ERROR" "Missing dependencies: ${missing[*]}"
    log "INFO" "Install with: pkg install ${missing[*]}"
    return 1
  fi
}

# Secure API key handling
setup_api_key() {
  if [ -f "$API_KEY_FILE" ]; then
    API_KEY=$(cat "$API_KEY_FILE")
  else
    read -sp "Enter your Gemini API key: " API_KEY
    echo
    echo "$API_KEY" > "$API_KEY_FILE"
    chmod 600 "$API_KEY_FILE"
    log "SUCCESS" "API key securely stored"
  fi
}

# Fetch or update prompt
get_prompt() {
  local cache_age=86400 # 24 hours
  
  if [ -f "$LOCAL_PROMPT" ]; then
    local local_mtime=$(stat -c %Y "$LOCAL_PROMPT" 2>/dev/null || stat -f %m "$LOCAL_PROMPT")
    local current_time=$(date +%s)
    
    if (( current_time - local_mtime < cache_age )); then
      log "INFO" "Using cached prompt"
      return 0
    fi
  fi

  log "INFO" "Fetching latest prompt from GitHub..."
  if curl -sL "$PROMPT_URL" -o "$LOCAL_PROMPT"; then
    log "SUCCESS" "Prompt updated successfully"
  else
    [ -f "$LOCAL_PROMPT" ] || {
      log "ERROR" "Failed to fetch prompt and no local copy exists"
      return 1
    }
    log "WARNING" "Using cached prompt (network failed)"
  fi
}

# Process MDX content
preprocess_mdx() {
  local content="$1"
  
  # Remove Thinking blocks but preserve their decisions
  content=$(echo "$content" | sed '/<Thinking>/,/<\/Thinking>/d')
  
  # Remove other MDX components
  for component in LinearProcessFlow Quiz Checklist VerificationSteps; do
    content=$(echo "$content" | sed "/<$component\/\?>/d")
  done
  
  # Clean math blocks
  content=$(echo "$content" | sed 's/\$\$.*\$\$//g')
  
  echo "$content"
}

# Call Gemini API with retries
call_gemini() {
  local prompt_content=$(cat "$LOCAL_PROMPT")
  local full_prompt=$(echo -e "$SYSTEM_PROMPT\n\n$prompt_content")
  local attempt=1
  local response

  while [ $attempt -le $MAX_RETRIES ]; do
    log "INFO" "API Attempt $attempt/$MAX_RETRIES"
    
    response=$(curl -sS -X POST \
      -m "$TIMEOUT" \
      "https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent?key=${API_KEY}" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg prompt "$full_prompt" '{
        contents: [{
          parts: [{
            text: $prompt
          }]
        }],
        generationConfig: {
          temperature: 0.2,
          topP: 0.95,
          maxOutputTokens: 8000
        }
      }')") || {
      log "WARNING" "API connection failed (attempt $attempt)"
      sleep $((attempt * 2))
      attempt=$((attempt + 1))
      continue
    }

    local error=$(echo "$response" | jq -r '.error.message // empty')
    [ -n "$error" ] && {
      log "WARNING" "API error: $error"
      attempt=$((attempt + 1))
      sleep 3
      continue
    }

    local content=$(echo "$response" | jq -r '.candidates[0].content.parts[0].text // empty')
    [ -z "$content" ] && {
      log "WARNING" "Empty API response"
      attempt=$((attempt + 1))
      continue
    }

    echo "$content"
    return 0
  done

  log "ERROR" "API failed after $MAX_RETRIES attempts"
  return 1
}

# Generate files from code blocks
generate_files() {
  local content="$1"
  content=$(preprocess_mdx "$content")
  
  log "INFO" "Generating files in $OUTPUT_DIR/"
  rm -rf "$OUTPUT_DIR"
  mkdir -p "$OUTPUT_DIR"

  echo "$content" | awk -v outdir="$OUTPUT_DIR" '
    BEGIN { 
      FS="\n"
      RS="```"
      count=0
    }
    NR % 2 == 0 {
      gsub(/^[ \t\n]+/, "", $0)
      gsub(/[ \t\n]+$/, "", $0)
      
      if (match($1, /([a-zA-Z0-9]+)([ \t]+(file|filename)=["'\'']?([^"'\''\s]+)/, m)) {
        lang = m[1]
        filename = m[4]
      } else if (match($1, /^([a-zA-Z0-9]+)/, m)) {
        lang = m[1]
        filename = "file_" count "." lang
      } else {
        next
      }
      
      # Create directory structure
      cmd = "mkdir -p \"" outdir "/" dirname(filename) "\""
      system(cmd)
      
      # Write file content
      outfile = outdir "/" filename
      for (i=2; i<=NF; i++) {
        print $i > outfile
      }
      close(outfile)
      
      printf "  \033[32m✓\033[0m %s\n", filename
      count++
    }
    
    function dirname(path) {
      if (sub(/\/[^\/]*$/, "", path)) {
        return path
      }
      return "."
    }
  '

  [ $(find "$OUTPUT_DIR" -type f | wc -l) -eq 0 ] && {
    log "ERROR" "No files generated - invalid response format"
    return 1
  }
  
  log "SUCCESS" "Generated $(find "$OUTPUT_DIR" -type f | wc -l) files"
}

# Post-generation validation
validate_output() {
  log "INFO" "Validating generated application..."
  
  local errors=0
  
  # Check for critical files
  for file in "package.json" "src/app/layout.tsx"; do
    if [ ! -f "$OUTPUT_DIR/$file" ]; then
      log "ERROR" "Missing critical file: $file"
      errors=$((errors + 1))
    fi
  done
  
  # Check TypeScript files for compilation
  if find "$OUTPUT_DIR" -name "*.ts" | grep -q .; then
    if ! command -v tsc &> /dev/null; then
      log "WARNING" "TypeScript not installed - skipping compilation check"
    else
      if ! tsc -p "$OUTPUT_DIR" --noEmit &>> "$LOG_FILE"; then
        log "ERROR" "TypeScript compilation failed"
        errors=$((errors + 1))
      fi
    fi
  fi
  
  [ $errors -eq 0 ] && log "SUCCESS" "Validation passed" || {
    log "ERROR" "Found $errors critical issues"
    return 1
  }
}

# Main execution flow
main() {
  init_system
  log "INFO" "Starting Sheikh Agent v3.0"
  
  check_dependencies || exit 1
  setup_api_key || exit 1
  get_prompt || exit 1
  
  log "INFO" "Generating application with $MODEL..."
  local generated_content=$(call_gemini) || exit 1
  
  generate_files "$generated_content" || exit 1
  validate_output || exit 1
  
  log "SUCCESS" "Application generated in $OUTPUT_DIR/"
  log "INFO" "Next steps:"
  echo -e "  ${BOLD}cd $OUTPUT_DIR${RESET}"
  echo -e "  ${BOLD}npm install${RESET} (if package.json exists)"
  echo -e "  ${BOLD}npm run dev${RESET} to start development"
}

main "$@"
