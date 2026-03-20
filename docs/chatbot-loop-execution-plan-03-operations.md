# Chatbot 루프 실행 계획 3

## 주제

운영 안정성, 컨텍스트 관리, 점진적 고도화

## 이 단계의 목적

1단계와 2단계가 끝나면 이 챗봇은 이미 "안전하게 멈추고", "안전하게 수정하는" 수준에 도달한다.  
세 번째 단계는 그 위에 운영 안정성과 긴 세션 품질을 올리는 단계다.

우선순위는 다음 순서다.

1. 관측 가능성
2. 컨텍스트 관리
3. provider fallback
4. 점진적 성능 개선

## 현재 문제

- 현재 챗봇은 로그는 있지만 stop reason, evidence, verification 성공률 같은 운영 지표가 구조화되어 있지 않다.
- history budget은 trimming 위주라 긴 세션에서 정보 손실이 크다. [`claude_chatbot.rb:878`](/var/www/redmine-dev/plugins/redmine_tx_mcp/lib/redmine_tx_mcp/claude_chatbot.rb#L878)
- provider 호출 실패 시 자동 fallback이 없다. [`claude_chatbot.rb:490`](/var/www/redmine-dev/plugins/redmine_tx_mcp/lib/redmine_tx_mcp/claude_chatbot.rb#L490)

## 구현 범위

### 1. 운영 지표 추가

추가할 핵심 지표:

- run 수
- stop reason 분포
- tool budget exhaustion 비율
- loop guard block 비율
- mutation verify 실패 비율
- session restore 후 follow-up 성공률
- spreadsheet workflow 사용량

구현 위치:

- `ChatbotLogger`
- 세션 summary 로그
- 필요 시 DB 또는 cache 기반 집계

### 2. Adaptive Context Compaction

도입 원칙:

- 대화를 무작정 자르지 않는다.
- evidence ledger와 plan 상태는 보존한다.
- 오래된 natural-language 메시지와 tool result만 요약/압축한다.

우선순위:

1. 오래된 tool result 요약
2. 오래된 assistant prose 요약
3. 최근 N턴과 evidence ledger는 원본 유지

실행 조건:

- message count 초과
- history chars 초과
- provider가 context overflow를 반환

결과적으로 "긴 세션"에서도 중요한 entity와 최근 수정 근거는 유지되어야 한다.

### 3. Provider Fallback

도입 목표:

- Anthropic 오류 시 OpenAI 호환 endpoint로 전환
- retryable 에러만 fallback
- write 이후 중간 fallback은 보수적으로 처리

핵심 원칙:

1. read-only 단계에서는 fallback 허용
2. write workflow 중간에는 fallback 조건을 더 엄격하게 둔다
3. verify 단계에서 provider가 바뀌어도 evidence ledger는 유지

후보 구조:

- `ChatbotLlmClient`
- `ChatbotFallbackClient`

### 4. 스트리밍 UX 개선

이 챗봇은 웹 UI에서 사용되므로, 루프가 길어질 때 사용자는 "무슨 단계인지"를 알아야 한다.

개선 목표:

- 현재 plan step 표시
- 조회 중 / 수정 중 / 검증 중 상태 분리
- 종료 사유 표시
- 보고서 생성 중 상태 표시

서버 측 이벤트 타입 예시:

- `phase`
- `verify`
- `stop_reason`
- `workspace`

### 5. 운영 릴리스 전략

이 단계는 기능 추가보다 운영 리스크 관리가 중요하다.

권장 방식:

1. feature flag 도입
2. 프로젝트 단위 enable
3. read-only 요청에 먼저 적용
4. 수정 요청은 내부 프로젝트에서 먼저 검증

## 상세 작업 순서

### 작업 1

로그와 메트릭 스키마 정리

완료 기준:

- run summary에 stop reason, iteration 수, verify status 포함
- loop guard block과 tool budget exhaustion 집계 가능

### 작업 2

adaptive compaction 추가

완료 기준:

- evidence ledger는 손실 없이 유지
- 오래된 tool result는 요약 가능
- context overflow 시 graceful retry 가능

### 작업 3

fallback client 도입

완료 기준:

- retryable error에서 대체 provider 시도
- non-retryable error는 즉시 실패
- write workflow 도중에는 보수 규칙 적용

### 작업 4

UI 스트리밍 상태 개선

완료 기준:

- 사용자가 현재 phase를 볼 수 있음
- 중단 이유가 대화창 또는 로그에 표시됨

## 테스트 계획

필수 테스트:

1. history budget 초과 시 evidence ledger 유지
2. context overflow 시 compact 후 재시도
3. retryable provider error 시 fallback 성공
4. non-retryable error 시 즉시 실패
5. write workflow 중 fallback 정책이 보수적으로 동작
6. stop reason이 SSE/UI에 노출

## 비목표

- 새로운 Redmine 도구 추가
- 프롬프트 대개편
- UI 전면 재설계

이 단계는 루프의 "운영 품질"을 높이는 단계다.

## 산출물

예상 산출물:

- 메트릭 확장
- adaptive compaction 로직
- fallback client
- 스트리밍 이벤트 확장
- 운영 feature flag

## 완료 판정

다음 조건을 만족하면 완료로 본다.

1. 긴 세션에서도 핵심 entity와 수정 근거가 유지된다.
2. retryable provider 장애가 곧바로 사용자 실패로 이어지지 않는다.
3. 운영 중 stop reason과 verify failure를 측정할 수 있다.
4. 사용자 입장에서 현재 진행 단계가 더 잘 보인다.
