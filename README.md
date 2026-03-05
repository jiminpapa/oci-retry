# OCI A1 Free Tier - GitHub Actions 자동 재시도

PC를 켜지 않고 GitHub Actions에서 5분마다 OCI A1 무료 인스턴스 생성을 시도합니다.
4개 리전(오사카/서울/춘천/도쿄) × 각 리전 AD를 자동 순회합니다.

## 설정 방법

### 1. GitHub 저장소 생성
```bash
cd ~/oci-github-retry
git init
git add -A
git commit -m "init"
```
GitHub에서 **Private** 저장소 생성 후:
```bash
git remote add origin https://github.com/YOUR_USERNAME/oci-retry.git
git push -u origin master
```

### 2. Secrets 등록
GitHub 저장소 → Settings → Secrets and variables → Actions → New repository secret

| Secret 이름 | 값 | 어디서 가져오나 |
|---|---|---|
| `OCI_TENANCY_ID` | `ocid1.tenancy.oc1..aaaa...` | `~/.oci/config`의 tenancy |
| `OCI_USER_ID` | `ocid1.user.oc1..aaaa...` | `~/.oci/config`의 user |
| `OCI_FINGERPRINT` | `d6:3c:4d:38:...` | `~/.oci/config`의 fingerprint |
| `OCI_API_KEY` | PEM 파일 내용 전체 | `cat ~/.oci/oci_api_key.pem` |
| `OCI_SSH_PUB_KEY` | `ssh-rsa AAAA...` | `cat ~/.ssh/oci_rsa.pub` |

### 3. (선택) 알림 설정

#### 텔레그램
1. @BotFather에게 `/newbot` → 봇 토큰 받기
2. 봇에게 아무 메시지 보내기
3. `https://api.telegram.org/bot<TOKEN>/getUpdates`에서 chat_id 확인
4. Secrets에 추가:
   - `TELEGRAM_BOT_TOKEN`: 봇 토큰
   - `TELEGRAM_CHAT_ID`: 채팅 ID

#### 디스코드
1. 서버 설정 → 연동 → 웹후크 → 새 웹후크 → URL 복사
2. Secrets에 추가:
   - `DISCORD_WEBHOOK_URL`: 웹후크 URL

### 4. 실행 확인
- Actions 탭에서 워크플로우 확인
- "Run workflow" 버튼으로 수동 실행 테스트
- 성공 시 텔레그램/디스코드로 알림

## 동작 방식

```
5분마다 실행
  → 오사카 → VCN/서브넷 자동 생성(최초 1회) → AD별 인스턴스 시도
  → 서울   → VCN/서브넷 자동 생성(최초 1회) → AD별 인스턴스 시도
  → 춘천   → VCN/서브넷 자동 생성(최초 1회) → AD별 인스턴스 시도
  → 도쿄   → VCN/서브넷 자동 생성(최초 1회) → AD별 인스턴스 시도
  → 전부 실패 → 5분 후 재시도
```

## 성공 후
1. 알림에서 리전/IP 확인
2. GitHub Actions → Settings → Actions → General → "Disable Actions" (비용 절약)
3. SSH 접속:
```bash
ssh -i ~/.ssh/oci_rsa ubuntu@[공개IP]
```

## 비용
- GitHub Actions 무료: 2,000분/월
- 5분마다 실행 × 4분 = 하루 ~1,152분
- **약 2일 연속 가동 가능** (넉넉하게는 주말 포함 돌릴 수 있음)
- 성공 후 즉시 Actions 비활성화하면 문제 없음

## 중단하기
- GitHub 저장소 → Actions → 해당 워크플로우 → "Disable workflow"
