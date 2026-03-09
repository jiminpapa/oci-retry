#!/bin/bash
# OCI A1 Free Tier - Multi-Region Auto Retry Script
# GitHub Actions에서 실행 (5분마다 cron)

set -uo pipefail

# ===== 설정 =====
TENANCY_ID="ocid1.tenancy.oc1..aaaaaaaaxpz2u4vggintwglqy3gwznqkvwqfczcsx6bbckxn7cwfiwnnijqq"
INSTANCE_NAME="vm-a1-free"
OCPU=1
RAM_GB=6
SHAPE="VM.Standard.A1.Flex"

# 시도할 리전 목록 (가까운 순)
REGIONS=("ap-osaka-1") 

# ===== 함수 =====

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

# 텔레그램 알림 (선택사항)
notify() {
  local msg="$1"
  if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d chat_id="${TELEGRAM_CHAT_ID}" \
      -d text="${msg}" \
      -d parse_mode="Markdown" > /dev/null 2>&1 || true
  fi
  if [[ -n "${DISCORD_WEBHOOK_URL:-}" ]]; then
    curl -s -X POST "${DISCORD_WEBHOOK_URL}" \
      -H "Content-Type: application/json" \
      -d "{\"content\": \"${msg}\"}" > /dev/null 2>&1 || true
  fi
}

# 리전 구독 확인
check_region_subscription() {
  local region="$1"
  local result
  result=$(oci iam region-subscription list \
    --tenancy-id "$TENANCY_ID" \
    --query "data[?\"region-name\"=='$region'].\"region-name\"" \
    --raw-output 2>&1) || true

  if [[ "$result" == *"$region"* ]]; then
    return 0
  else
    log "[$region] 리전 미구독 - 스킵"
    return 1
  fi
}

# 리전에 VCN/서브넷이 있는지 확인, 없으면 자동 생성
# 반환값: stdout에 subnet_id만 출력 (log는 stderr로)
ensure_network() {
  local region="$1"
  log "[$region] 네트워크 확인 중..."

  # 기존 VCN 검색
  local vcn_id
  vcn_id=$(oci network vcn list \
    --compartment-id "$TENANCY_ID" \
    --region "$region" \
    --display-name "vcn-a1-free" \
    --lifecycle-state AVAILABLE \
    --query 'data[0].id' --raw-output 2>&1) || true

  if [[ "$vcn_id" == *"Error"* || "$vcn_id" == *"error"* || "$vcn_id" == *"Exception"* ]]; then
    log "[$region] VCN 조회 실패: $(echo "$vcn_id" | head -3)"
    return 1
  fi

  if [[ -z "$vcn_id" || "$vcn_id" == "null" || "$vcn_id" == "None" ]]; then
    log "[$region] VCN 생성 중..."
    local create_result
    create_result=$(oci network vcn create \
      --compartment-id "$TENANCY_ID" \
      --region "$region" \
      --display-name "vcn-a1-free" \
      --cidr-blocks '["10.0.0.0/16"]' \
      --dns-label "vcna1free" \
      --wait-for-state AVAILABLE \
      --query 'data.id' --raw-output 2>&1) || true

    if [[ -z "$create_result" || "$create_result" == "null" || "$create_result" == *"Error"* || "$create_result" == *"error"* ]]; then
      log "[$region] VCN 생성 실패: $(echo "$create_result" | head -5)"
      return 1
    fi
    vcn_id="$create_result"
    log "[$region] VCN 생성 완료: $vcn_id"

    # 인터넷 게이트웨이 생성
    local igw_id
    igw_id=$(oci network internet-gateway create \
      --compartment-id "$TENANCY_ID" \
      --region "$region" \
      --vcn-id "$vcn_id" \
      --display-name "igw-a1-free" \
      --is-enabled true \
      --wait-for-state AVAILABLE \
      --query 'data.id' --raw-output 2>&1) || true

    if [[ -z "$igw_id" || "$igw_id" == "null" || "$igw_id" == *"Error"* ]]; then
      log "[$region] IGW 생성 실패: $(echo "$igw_id" | head -3)"
      return 1
    fi
    log "[$region] IGW 생성 완료: $igw_id"

    # 라우트 테이블
    local rt_id
    rt_id=$(oci network route-table list \
      --compartment-id "$TENANCY_ID" \
      --region "$region" \
      --vcn-id "$vcn_id" \
      --query 'data[0].id' --raw-output 2>&1) || true

    oci network route-table update \
      --rt-id "$rt_id" \
      --region "$region" \
      --route-rules "[{\"destination\":\"0.0.0.0/0\",\"destinationType\":\"CIDR_BLOCK\",\"networkEntityId\":\"$igw_id\"}]" \
      --force > /dev/null 2>&1 || true
    log "[$region] 라우트 테이블 업데이트 완료"

    # 보안 목록
    local sl_id
    sl_id=$(oci network security-list list \
      --compartment-id "$TENANCY_ID" \
      --region "$region" \
      --vcn-id "$vcn_id" \
      --query 'data[0].id' --raw-output 2>&1) || true

    oci network security-list update \
      --security-list-id "$sl_id" \
      --region "$region" \
      --ingress-security-rules '[
        {"protocol":"6","source":"0.0.0.0/0","tcpOptions":{"destinationPortRange":{"min":22,"max":22}}},
        {"protocol":"6","source":"0.0.0.0/0","tcpOptions":{"destinationPortRange":{"min":80,"max":80}}},
        {"protocol":"6","source":"0.0.0.0/0","tcpOptions":{"destinationPortRange":{"min":443,"max":443}}},
        {"protocol":"1","source":"0.0.0.0/0","icmpOptions":{"type":3,"code":4}},
        {"protocol":"1","source":"10.0.0.0/16","icmpOptions":{"type":3}}
      ]' \
      --egress-security-rules '[{"protocol":"all","destination":"0.0.0.0/0"}]' \
      --force > /dev/null 2>&1 || true
    log "[$region] 보안 목록 업데이트 완료"
  else
    log "[$region] 기존 VCN 사용: $vcn_id"
  fi

  # 서브넷 확인/생성
  local subnet_id
  subnet_id=$(oci network subnet list \
    --compartment-id "$TENANCY_ID" \
    --region "$region" \
    --vcn-id "$vcn_id" \
    --display-name "subnet-a1-free" \
    --lifecycle-state AVAILABLE \
    --query 'data[0].id' --raw-output 2>&1) || true

  if [[ -z "$subnet_id" || "$subnet_id" == "null" || "$subnet_id" == "None" || "$subnet_id" == *"Error"* ]]; then
    log "[$region] 서브넷 생성 중..."

    subnet_id=$(oci network subnet create \
      --compartment-id "$TENANCY_ID" \
      --region "$region" \
      --vcn-id "$vcn_id" \
      --display-name "subnet-a1-free" \
      --cidr-block "10.0.0.0/24" \
      --dns-label "subneta1" \
      --wait-for-state AVAILABLE \
      --query 'data.id' --raw-output 2>&1) || true

    if [[ -z "$subnet_id" || "$subnet_id" == "null" || "$subnet_id" == *"Error"* ]]; then
      log "[$region] 서브넷 생성 실패: $(echo "$subnet_id" | head -3)"
      return 1
    fi
    log "[$region] 서브넷 생성 완료: $subnet_id"
  else
    log "[$region] 기존 서브넷 사용: $subnet_id"
  fi

  # stdout에 subnet_id만 출력
  echo "$subnet_id"
}

# 리전에서 최신 Ubuntu 이미지 OCID 가져오기
get_image_id() {
  local region="$1"
  oci compute image list \
    --compartment-id "$TENANCY_ID" \
    --region "$region" \
    --operating-system "Canonical Ubuntu" \
    --operating-system-version "22.04" \
    --shape "$SHAPE" \
    --sort-by TIMECREATED \
    --sort-order DESC \
    --query 'data[0].id' --raw-output 2>/dev/null || echo ""
}

# 리전의 AD 목록 가져오기
get_availability_domains() {
  local region="$1"
  oci iam availability-domain list \
    --compartment-id "$TENANCY_ID" \
    --region "$region" \
    --query 'data[*].name' --raw-output 2>/dev/null | tr -d '[]" ' | tr ',' '\n'
}

# 인스턴스 생성 시도
try_launch() {
  local region="$1"
  local subnet_id="$2"
  local image_id="$3"
  local ad="$4"

  log "[$region] 인스턴스 생성 시도 (AD: $ad)..."

  # SSH 공개키를 임시 파일로 저장
  local ssh_key_file
  ssh_key_file=$(mktemp)
  echo "$SSH_PUB_KEY" > "$ssh_key_file"

  local result
  result=$(oci compute instance launch \
    --compartment-id "$TENANCY_ID" \
    --region "$region" \
    --availability-domain "$ad" \
    --subnet-id "$subnet_id" \
    --image-id "$image_id" \
    --shape "$SHAPE" \
    --shape-config "{\"ocpus\":$OCPU,\"memoryInGBs\":$RAM_GB}" \
    --display-name "$INSTANCE_NAME" \
    --assign-public-ip true \
    --ssh-authorized-keys-file "$ssh_key_file" \
    2>&1) || true
  rm -f "$ssh_key_file"

  if echo "$result" | grep -q '"lifecycle-state"'; then
    local instance_id
    instance_id=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('data',{}).get('id',''))" 2>/dev/null || echo "확인필요")
    log "SUCCESS! [$region] 인스턴스 생성 성공!"
    log "인스턴스 ID: $instance_id"
    notify "🎉 *OCI A1 인스턴스 생성 성공!*\n리전: \`$region\`\nAD: \`$ad\`\nID: \`$instance_id\`"
    return 0
  fi

  if echo "$result" | grep -q "LimitExceeded"; then
    log "[$region] LimitExceeded - 이미 인스턴스 존재 또는 한도 초과"
    return 2
  fi

  if echo "$result" | grep -q "Out of host capacity"; then
    log "[$region/$ad] 용량 부족 - 다음 시도..."
    return 1
  fi

  log "[$region] 기타 오류:"
  echo "$result" | head -20 >&2
  return 1
}

# ===== 메인 =====

  log "=== OCI A1 Multi-Region Auto Retry ==="
  log "리전: ${REGIONS[*]}"
  log "스펙: ${OCPU} OCPU / ${RAM_GB}GB RAM"

  SSH_PUB_KEY="${OCI_SSH_PUB_KEY:-}"
  if [[ -z "$SSH_PUB_KEY" ]]; then
    log "ERROR: OCI_SSH_PUB_KEY 환경변수가 없습니다"
    exit 1
  fi

  # 구독된 리전만 필터링
  SUBSCRIBED_REGIONS=()
  for region in "${REGIONS[@]}"; do
    if check_region_subscription "$region"; then
      SUBSCRIBED_REGIONS+=("$region")
    fi
  done

  if [[ ${#SUBSCRIBED_REGIONS[@]} -eq 0 ]]; then
    log "ERROR: 구독된 리전이 없습니다"
    exit 1
  fi
  log "구독된 리전: ${SUBSCRIBED_REGIONS[*]}"

  # 네트워크/이미지는 처음 1번만 준비
  declare -A REGION_SUBNET
  declare -A REGION_IMAGE
  declare -A REGION_ADS

  for region in "${SUBSCRIBED_REGIONS[@]}"; do
    subnet_id=$(ensure_network "$region") || { log "[$region] 네트워크 준비 실패, 스킵"; continue; }
    if [[ "$subnet_id" != ocid1.subnet.* ]]; then
      log "[$region] 유효하지 않은 서브넷 ID: $subnet_id"
      continue
    fi
    image_id=$(get_image_id "$region")
    if [[ -z "$image_id" || "$image_id" == "null" ]]; then
      log "[$region] Ubuntu 이미지 없음, 스킵"
      continue
    fi
    REGION_SUBNET[$region]="$subnet_id"
    REGION_IMAGE[$region]="$image_id"
    REGION_ADS[$region]=$(get_availability_domains "$region")
    log "[$region] 준비 완료 - 이미지: $image_id"
  done

  # 최대 270초(4분 30초) 동안 15초 간격으로 반복 시도
  START_TIME=$(date +%s)
  MAX_DURATION=270
  ATTEMPT=0

  while true; do
    ELAPSED=$(( $(date +%s) - START_TIME ))
    if [[ $ELAPSED -ge $MAX_DURATION ]]; then
      log "시간 초과 - 다음 실행에서 재시도"
      break
    fi

    ATTEMPT=$((ATTEMPT + 1))
    log "===== 시도 #$ATTEMPT (경과: ${ELAPSED}초) ====="

    for region in "${!REGION_SUBNET[@]}"; do
      while IFS= read -r ad; do
        [[ -z "$ad" ]] && continue
        result_code=0
        try_launch "$region" "${REGION_SUBNET[$region]}" "${REGION_IMAGE[$region]}" "$ad" || result_code=$?
        case $result_code in
          0) notify "✅ 스크립트 종료 - 인스턴스 생성 성공"; exit 0 ;;
          2) notify "⚠️ LimitExceeded - 이미 인스턴스 존재"; exit 0 ;;
          *) continue ;;
        esac
      done <<< "${REGION_ADS[$region]}"
    done

    log "15초 후 재시도..."
    sleep 15
  done

  log "모든 시도 완료 - 다음 실행에서 재시도"
