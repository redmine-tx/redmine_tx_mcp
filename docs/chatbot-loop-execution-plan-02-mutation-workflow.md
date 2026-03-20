# Chatbot 루프 실행 계획 2

## 주제

Redmine 수정 워크플로와 세션 증거 관리 강화

## 이 단계의 목적

이 챗봇의 핵심 가치는 Redmine 업무를 "안전하게" 보조하는 것이다.  
따라서 두 번째 단계는 루프 자체보다, 조회 결과를 근거로 수정하고, 수정 후 검증하고, 그 근거를 세션에 남기는 흐름을 확립하는 데 집중한다.

이 단계가 끝나면 다음이 가능해야 한다.

1. 수정 요청이 항상 `read -> decide -> write -> verify -> report` 순서를 따른다.
2. 검증되지 않은 변경은 완료로 보고하지 않는다.
3. 후속 질문에서 "방금 찾은 이슈", "아까 올린 파일", "계속 진행"을 안정적으로 해석한다.

## 현재 문제

- 쓰기 보호는 좋지만, 수정 워크플로가 명시적 상태 머신은 아니다.
- [`guard_retry_instruction`](/var/www/redmine-dev/plugins/redmine_tx_mcp/lib/redmine_tx_mcp/claude_chatbot.rb#L1802) 는 완료 주장 재시도를 막지만, write 후 read-back 검증을 구조적으로 강제하지는 않는다.
- 세션에는 대화와 plan 상태는 남지만, "이번 턴의 근거 데이터"가 구조화되어 있지 않다. [`claude_chatbot.rb:297`](/var/www/redmine-dev/plugins/redmine_tx_mcp/lib/redmine_tx_mcp/claude_chatbot.rb#L297)

## 구현 범위

### 1. Mutation Workflow State 도입

새 모듈 예시:

- `lib/redmine_tx_mcp/chatbot_mutation_workflow.rb`

상태 예시:

- `intent_detected`
- `target_resolved`
- `change_resolved`
- `write_executed`
- `verify_succeeded`
- `failed`

대상 요청:

- issue update
- bulk update
- relation create/delete
- version/project/user 수정 계열
- spreadsheet 기반 일괄 수정

핵심 규칙:

1. 수정 전 target entity가 식별되어야 한다.
2. 변경 필드가 확정되어야 한다.
3. write 성공 응답만으로 완료 판정하지 않는다.
4. 관련 read 도구로 read-back 검증해야 한다.

### 2. Tool Metadata 도입

현재의 이름 패턴 기반 판정을 메타데이터 기반으로 바꾼다.

추가 속성 예시:

- `read_only`
- `side_effecting`
- `idempotent`
- `confirm_required`
- `verify_with`
- `entity_type`

예시:

- `issue_update`
  - `side_effecting: true`
  - `verify_with: ["issue_get"]`
- `insert_bulk_update`
  - `side_effecting: true`
  - `verify_with: ["issue_list", "issue_get"]`
- `spreadsheet_export_report`
  - `side_effecting: true`
  - `verify_with: []`

### 3. Evidence Ledger 도입

새 세션 상태 예시:

- `resolved_entities`
- `last_read_evidence`
- `last_write_attempt`
- `last_verification`
- `active_workspace_file`

구현 위치 후보:

- `export_agent_state`
- `restore_agent_state`

[`plan_state`](/var/www/redmine-dev/plugins/redmine_tx_mcp/lib/redmine_tx_mcp/claude_chatbot.rb#L301) 와 별개로, 근거와 대상 엔티티를 저장한다.

저장 예시:

```json
{
  "resolved_entities": {
    "issue_ids": [123, 124],
    "version_ids": [9],
    "file_names": ["report.xlsx"]
  },
  "last_write_attempt": {
    "tool": "issue_update",
    "inputs": {"id": 123, "status_id": 5}
  },
  "last_verification": {
    "tool": "issue_get",
    "status": "passed"
  }
}
```

### 4. 후속 요청 해석 규칙 강화

대상 표현:

- "계속 진행해줘"
- "아까 그 이슈"
- "방금 올린 파일 기준으로"
- "찾은 것들 다 바꿔줘"

해석 순서:

1. pending mutation workflow 확인
2. evidence ledger의 최신 entity 확인
3. workspace file 확인
4. 없으면 명시적 재질문

이 단계의 목표는 애매한 follow-up을 대화 히스토리 전체가 아니라 구조화된 상태로 푸는 것이다.

## 상세 작업 순서

### 작업 1

도구 메타데이터 저장 구조 정의

완료 기준:

- 각 tool definition에 접근 가능한 metadata registry가 생긴다.
- 기존 `read_only_tool?`, `side_effecting_tool?`는 registry를 우선 사용한다.

### 작업 2

Mutation workflow 구현

완료 기준:

- write 계열 요청마다 현재 단계가 상태로 추적된다.
- write 성공 후 verify 미완료면 답변을 완료로 확정하지 않는다.

### 작업 3

Evidence ledger를 session state에 통합

완료 기준:

- `export_session_state`, `restore_session_state`로 복원 가능
- ambiguous follow-up에서 ledger를 우선 사용

### 작업 4

Spreadsheet 기반 수정 흐름을 workflow에 포함

핵심:

- 어떤 파일을 읽었는지
- 어떤 시트를 썼는지
- 어떤 행을 기준으로 변경했는지
- 보고서를 생성했는지

이 정보를 evidence로 남긴다.

## 테스트 계획

필수 테스트:

1. `issue_update` 후 `issue_get` 검증이 없으면 완료 보고 차단
2. write 성공 응답이 있어도 read-back mismatch면 실패 보고
3. bulk update 후 표본 또는 목록 검증 수행
4. 세션 restore 후 "계속 진행"이 pending mutation을 이어감
5. "아까 그 이슈"가 최근 evidence의 issue id를 참조
6. spreadsheet 기반 요청에서 최근 업로드 파일이 유지됨

추천 테스트 파일:

- `test/test_claude_chatbot.rb`
- `test/test_chatbot_mutation_workflow.rb`

## 비목표

- provider fallback
- extended thinking 최적화
- 대규모 context compaction

이 단계는 "정확한 변경과 검증"에 집중한다.

## 산출물

예상 산출물:

- `lib/redmine_tx_mcp/chatbot_mutation_workflow.rb`
- tool metadata registry
- `claude_chatbot.rb` 세션 상태 확장
- follow-up 해석 테스트

## 완료 판정

다음 조건을 만족하면 완료로 본다.

1. 수정형 요청은 verify 없는 완료 응답을 만들지 않는다.
2. 후속 요청이 최근 entity와 파일 맥락을 안정적으로 이어받는다.
3. 세션 복원 후에도 pending plan과 pending mutation이 모두 유지된다.
4. 로그와 상태에서 "무엇을 바꾸려 했고, 무엇으로 검증했는지"를 추적할 수 있다.
