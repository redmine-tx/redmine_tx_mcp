# Chatbot 루프 실행 계획 1

## 주제

루프 안전장치와 종료 보장 강화

## 이 단계의 목적

이 챗봇의 1차 목적은 "긴 자율 실행"이 아니라 "Redmine 데이터를 안전하게 조회하고 수정하는 것"이다.  
따라서 첫 단계는 더 똑똑한 루프보다, 절대 오래 헤매지 않고 잘못된 write를 유발하지 않는 루프를 만드는 데 집중한다.

이 단계가 끝나면 다음이 보장되어야 한다.

1. 모든 agent run이 제한된 시간과 제한된 반복 횟수 안에서 끝난다.
2. 도구 호출이 막히거나 반복될 때 무한히 재시도하지 않는다.
3. 중단 시에도 사용자에게 현재 상태와 남은 작업을 설명할 수 있다.

## 현재 문제

- [`resolve_response`](/var/www/redmine-dev/plugins/redmine_tx_mcp/lib/redmine_tx_mcp/claude_chatbot.rb#L524) 는 중첩 루프 구조지만 hard cap, wall-clock timeout, abort가 없다.
- 반복 방지는 [`repeat_blocked?`](/var/www/redmine-dev/plugins/redmine_tx_mcp/lib/redmine_tx_mcp/claude_chatbot.rb#L1754) 기반의 호출 횟수 제한이라 no-progress와 ping-pong을 구분하지 못한다.
- 예산 소진 시 요약은 가능하지만, "왜 멈췄는지"와 "어디까지 했는지"가 구조적으로 남지 않는다.

## 구현 범위

### 1. Run Guard 도입

새 모듈 예시:

- `lib/redmine_tx_mcp/chatbot_run_guard.rb`

책임:

- `max_iterations`
- `max_elapsed_seconds`
- `abort_requested?`
- 종료 사유 코드 정리

종료 사유 예시:

- `hard_cap`
- `timeout`
- `abort`
- `tool_budget`
- `loop_guard`
- `completed`

`ClaudeChatbot`은 이 객체를 받아 루프 경계마다 검사만 하도록 단순화한다.

### 2. Progress-aware Loop Guard 도입

새 모듈 예시:

- `lib/redmine_tx_mcp/chatbot_loop_guard.rb`

최소 기능:

1. 같은 호출 반복 경고
2. 같은 결과 반복 차단
3. `A -> B -> A -> B` ping-pong 차단
4. 전체 루프 evidence 누적 차단

결과 해시 규칙:

- timestamp 계열 필드 제거
- `updated_on`, `created_on`, `request_id`, `trace_id` 등 제외
- 문자열은 앞/뒤 일부만 사용해 해시 비용 제한

중요:

- read-only 도구는 "호출 수"가 아니라 "같은 결과 반복"일 때만 강하게 막는다.
- side-effecting 도구는 현재의 보수적 정책을 유지하되 loop guard 결과도 함께 반영한다.

### 3. 종료 시 요약 응답 표준화

현재의 [`summarize_without_tools`](/var/www/redmine-dev/plugins/redmine_tx_mcp/lib/redmine_tx_mcp/claude_chatbot.rb#L1617) 는 유지하되, 종료 사유를 명시적으로 전달한다.

예시:

- 시간 제한으로 중단
- 반복 호출 감지로 중단
- 도구 호출 한도 도달

요약 프롬프트에는 아래를 포함한다.

1. 지금까지 성공한 조회/수정
2. 실패한 도구 호출
3. 아직 검증되지 않은 변경
4. 사용자가 다음 턴에 이어서 할 수 있는 행동

### 4. 취소 흐름 추가

세션 단위 abort 플래그를 추가한다.

후보 구현:

- Rails.cache 기반 `chatbot_abort:<conversation_id>`

적용 위치:

- `chat_stream`
- `resolve_response`
- 도구 호출 직전

UI 후속:

- 나중 단계에서 "실행 중 중단" 버튼 추가 가능

이번 단계에서는 서버 측 훅만 먼저 넣는다.

## 상세 작업 순서

### 작업 1

`ChatbotRunGuard` 클래스 추가

완료 기준:

- 시작 시각, iteration 수, 종료 사유를 관리한다.
- 루프 진입부에서 `continue?` 또는 `raise_stop_reason` 식으로 사용 가능하다.

### 작업 2

`resolve_response`를 단일 반복 경계 중심으로 정리

목표:

- 외부 루프의 역할과 내부 tool-use 처리 경계를 분명히 분리
- 각 반복마다 run guard 검사
- 각 반복마다 loop guard 상태 반영

### 작업 3

`ChatbotLoopGuard` 구현 및 `repeat_blocked?` 대체

목표:

- 기존 `@tool_call_history`를 완전히 없애거나, side-effecting repeat cap 용도로만 축소

### 작업 4

중단 사유와 현재 상태를 `ChatbotLogger`에 구조적으로 기록

추가 필드 예시:

- `stop_reason`
- `iteration_count`
- `elapsed_ms`
- `loop_detector`
- `remaining_tool_budget`

## 테스트 계획

대상 파일:

- `test/test_claude_chatbot.rb`
- 필요 시 `test/test_chatbot_loop_guard.rb`

필수 테스트:

1. `max_iterations` 도달 시 요약 응답으로 종료
2. wall-clock timeout 도달 시 요약 응답으로 종료
3. abort 플래그가 켜지면 다음 iteration 경계에서 종료
4. 같은 결과 반복 시 no-progress 차단
5. ping-pong 패턴 차단
6. 결과가 계속 바뀌는 read-only 반복은 허용
7. side-effecting 도구는 성공 후 동일 파라미터 재실행 차단

## 비목표

- provider fallback
- adaptive compaction
- mutation state machine
- UI 취소 버튼 완성

이 단계에서는 오직 "안전하게 멈추는 루프"를 만든다.

## 산출물

예상 산출물:

- `lib/redmine_tx_mcp/chatbot_run_guard.rb`
- `lib/redmine_tx_mcp/chatbot_loop_guard.rb`
- `claude_chatbot.rb` 리팩터링
- 루프 관련 테스트 추가

## 완료 판정

다음 조건을 만족하면 완료로 본다.

1. 모든 run이 제한 시간 또는 제한 반복 내에 종료한다.
2. 동일 결과 반복으로 인한 무한 루프가 재현되지 않는다.
3. 종료 시 사용자 메시지와 로그에 stop reason이 남는다.
4. 기존 write 보호 규칙이 유지된다.
