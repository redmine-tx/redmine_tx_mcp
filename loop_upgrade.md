# 에이전틱 루프 비교 리뷰: `redmine_tx_mcp` vs `karina_bot`

## 아키텍처 요약

| 항목 | redmine_tx_mcp (Ruby) | karina_bot (Python) |
|------|----------------------|---------------------|
| 언어/프레임워크 | Ruby on Rails 플러그인 | Python 스탠드얼론 |
| LLM | Claude (주) + OpenAI 호환 | Claude (주) + Gemini (폴백) |
| 루프 구조 | 중첩 loop-while | for iteration in range(hard_cap) |
| 최대 반복 | 도구 예산 기반 (기본 10, 최대 30) | 하드캡 32 + 벽시계 타임아웃 180s |
| 스트리밍 | SSE (Rails controller) | SSE (urllib) |
| 플랜 도구 | 최대 4 스텝 | 스텝 수 제한 없음 |
| 컨텍스트 관리 | 3-Layer 정적 잘라내기 | 2-Phase 적응형 compaction |

---

## 1. 루프 제어 및 종료 조건

**redmine_tx_mcp**: `resolve_response()`에서 중첩 루프 사용 — 내부 `while`이 도구 호출을 반복하고, 외부 `loop`가 가드 레일 재시도를 처리. 도구 예산 소진 시 `summarize_without_tools()`로 강제 종료.

**karina_bot**: 단일 `for` 루프에 하드캡(32) + 벽시계 타임아웃(180초) + cooperative abort 체크. 반복 경계마다 `abort_check()`와 `timeout_check()` 호출.

**차이점**: karina_bot이 **더 안전한 종료 보장**을 가짐. 하드캡 + 타임아웃 + 외부 abort의 3중 안전장치. redmine_tx_mcp는 도구 예산만으로 제어하므로 예산이 높게 설정되면 긴 실행이 가능.

---

## 2. 무한 루프 방지 (Loop Guard)

**redmine_tx_mcp**: `repeat_blocked?()` — 같은 도구+파라미터 조합의 반복 감지. 비교적 단순한 시그니처 매칭.

**karina_bot**: 전용 `loop_guard.py` 모듈 — 3가지 패턴 감지:
- **Generic repeat**: 같은 도구+파라미터 4회 초과
- **No-progress**: 같은 결과 해시 4회 초과
- **Ping-pong**: A↔B 순환 4회 초과
- **Global breaker**: 총 호출 8회 초과 시 하드 블록
- 타임스탬프 등 불안정 필드 제외 해싱

**차이점**: karina_bot이 **현저히 우수**. ping-pong 감지와 결과 기반 no-progress 감지는 redmine_tx_mcp에 없는 기능으로, 실제 프로덕션에서 자주 발생하는 루프 패턴을 잡아냄.

---

## 3. 환각 감지 및 가드 레일

**redmine_tx_mcp**: `guard_retry_instruction()` — 4가지 조건 체크:
- 플랜 미완료 감지
- 도구 없이 mutation 주장
- 쓰기 도구 없이 완료 주장
- 도구 없이 긴 사실적 답변

**karina_bot**: 유사한 환각 감지 + `tool_choice='any'` 강제 + 에러 후 성공 주장 감지.

**차이점**: 비슷한 수준이나, redmine_tx_mcp의 가드 레일이 **조건이 더 세분화**되어 있음 (4가지 vs 2가지). 반면 karina_bot은 `tool_choice` 강제를 통한 더 직접적인 교정을 수행.

---

## 4. 컨텍스트 윈도우 관리

**redmine_tx_mcp**: 3-Layer 정적 시스템:
- Layer 1: 도구 결과 4,000자 잘라내기
- Layer 3: 전체 히스토리 80,000자, 최대 60 메시지
- Layer 4: 고아 메시지 정리

**karina_bot**: 2-Phase 적응형 compaction:
- Phase 1: 에이전트 실행 전 토큰 추정 → 필요시 요약
- Phase 2: 반복 5회 이상 시 오래된 도구 결과 compaction (최근 2개 보존)
- Haiku 모델로 요약 생성
- ContextOverflowError 시 compact & retry

**차이점**: karina_bot이 **더 정교**함. 사전 토큰 추정으로 오버플로우를 예방하고, 중간 compaction으로 긴 에이전트 실행에서도 컨텍스트를 효율적으로 사용. redmine_tx_mcp는 정적 잘라내기만 하므로 정보 손실이 더 클 수 있음.

---

## 5. 도구 실행 안전성

**redmine_tx_mcp**:
- 턴당 쓰기 도구 1회 제한
- 읽기 후 쓰기 강제
- 도구 프로필 기반 선택 (7개 프로필)

**karina_bot**:
- `IntentDef` 메타데이터: `idempotent`, `side_effecting`, `retryable`, `confirm_required`
- 동적 확인 (`dynamic_confirm`)
- mutation 재시도 방지 (같은 입력으로 side-effecting 도구 재실행 차단)
- `request_toolset_expansion`으로 런타임 도구 확장

**차이점**: karina_bot이 **메타데이터 기반 세밀한 제어**를 제공. 도구별 멱등성/부작용 선언으로 재시도 정책을 도구 단위로 다르게 적용. redmine_tx_mcp의 "턴당 쓰기 1회"는 단순하지만 제약이 큼.

---

## 6. 에러 복구 및 폴백

**redmine_tx_mcp**: OpenAI 어댑터로 다른 LLM 사용 가능하나, 자동 폴백은 없음. API 에러 시 예외 발생.

**karina_bot**: `FallbackClient` — 429/529/503 시 즉시 다음 프로바이더로 전환. 최대 5 라운드 재시도. 비재시도 에러(400/401)는 즉시 실패.

**차이점**: karina_bot이 **프로덕션 안정성에서 우위**. 자동 프로바이더 전환으로 단일 장애점 제거.

---

## 7. 동시성 및 세션 관리

**redmine_tx_mcp**: `MAX_CONCURRENT_CHATS = 2`, Rails 캐시 기반 세션, DB 영속화.

**karina_bot**: 채팅별 큐 + ThreadPoolExecutor (기본 3 워커), 큐 최대 10 (오래된 메시지 드롭), cooperative abort.

**차이점**: karina_bot이 **백프레셔 메커니즘**이 있어 부하 시 graceful degradation 가능. redmine_tx_mcp는 단순 동시성 제한만 있음.

---

## 8. Extended Thinking

**redmine_tx_mcp**: 지원 없음 (일반 응답만 사용).

**karina_bot**: 상황별 thinking 예산 할당:
- 0 (비활성) → 단순 질의
- 2,000 → 낮은 신뢰도 단일 플러그인
- 3,000 → 다중 플러그인 저신뢰도
- 5,000 → 복잡한 MCP + 부작용

**차이점**: karina_bot이 **Claude의 extended thinking을 적응적으로 활용**하여 복잡한 작업에서 추론 품질을 높임.

---

## 종합 평가

| 영역 | 우위 | 설명 |
|------|------|------|
| 루프 안전성 | **karina_bot** | 3중 종료 보장 + 3가지 루프 패턴 감지 |
| 컨텍스트 관리 | **karina_bot** | 적응형 compaction vs 정적 잘라내기 |
| 에러 복구 | **karina_bot** | 자동 프로바이더 폴백 |
| 도구 안전성 | **karina_bot** | 메타데이터 기반 세밀한 제어 |
| Extended Thinking | **karina_bot** | 적응적 thinking 예산 |
| 가드 레일 세분화 | **redmine_tx_mcp** | 4가지 조건 vs 2가지 |
| 쓰기 보호 | **redmine_tx_mcp** | 턴당 1회 + 읽기 선행 강제 |
| Redmine 통합 | **redmine_tx_mcp** | 도메인 특화 도구 프로필 |

---

## redmine_tx_mcp 개선 추천 사항 (우선순위순)

### 1. Loop Guard 강화
- ping-pong, no-progress 패턴 감지 추가
- 결과 해시 기반 진행 여부 판단
- 글로벌 브레이커 (총 호출 수 제한)

### 2. 적응형 Compaction
- 정적 잘라내기 → 토큰 추정 기반 요약으로 전환
- 에이전트 실행 중 오래된 도구 결과를 Haiku로 요약
- ContextOverflowError 시 compact & retry

### 3. LLM 폴백
- API 에러(429/529/503) 시 자동 프로바이더 전환
- FallbackClient 패턴 도입

### 4. Extended Thinking
- 복잡한 요청에 thinking 예산 할당
- 상황별 적응적 예산 (0/2000/3000/5000)

### 5. 도구 메타데이터
- `idempotent`/`side_effecting`/`retryable` 속성 도입
- 도구별 재시도 정책 차등 적용
- 동적 확인(confirm) 메커니즘
