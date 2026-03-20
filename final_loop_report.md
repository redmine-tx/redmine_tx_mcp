# 최종 루프 비교 보고서

## 목적

`~/Repos/karina_bot`의 에이전틱 루프와 현재 Redmine 챗봇 루프의 품질을 비교한다.

이 문서는 [`loop_upgrade.md`](/var/www/redmine-dev/plugins/redmine_tx_mcp/loop_upgrade.md)를 참고했지만, 최종 평가는 직접 확인한 코드와 실제 테스트 실행 결과를 기준으로 정리했다.

## 검토 범위

- `karina_bot`
  - [`/home/dev/Repos/karina_bot/core/llm_client.py`](/home/dev/Repos/karina_bot/core/llm_client.py)
  - [`/home/dev/Repos/karina_bot/core/loop_guard.py`](/home/dev/Repos/karina_bot/core/loop_guard.py)
  - [`/home/dev/Repos/karina_bot/core/retry_policy.py`](/home/dev/Repos/karina_bot/core/retry_policy.py)
  - [`/home/dev/Repos/karina_bot/core/session.py`](/home/dev/Repos/karina_bot/core/session.py)
  - [`/home/dev/Repos/karina_bot/tests/test_agent_loop.py`](/home/dev/Repos/karina_bot/tests/test_agent_loop.py)
  - [`/home/dev/Repos/karina_bot/tests/test_iteration_cap.py`](/home/dev/Repos/karina_bot/tests/test_iteration_cap.py)
  - [`/home/dev/Repos/karina_bot/tests/test_session.py`](/home/dev/Repos/karina_bot/tests/test_session.py)
- 현재 챗봇
  - [`/var/www/redmine-dev/plugins/redmine_tx_mcp/lib/redmine_tx_mcp/claude_chatbot.rb`](/var/www/redmine-dev/plugins/redmine_tx_mcp/lib/redmine_tx_mcp/claude_chatbot.rb)
  - [`/var/www/redmine-dev/plugins/redmine_tx_mcp/test/test_claude_chatbot.rb`](/var/www/redmine-dev/plugins/redmine_tx_mcp/test/test_claude_chatbot.rb)

## 요약 결론

에이전틱 루프 자체의 품질은 `karina_bot`이 더 높다.

핵심 이유는 다음과 같다.

1. 종료 보장이 더 강하다.
2. 루프 감지가 결과 기반이며 progress-aware하다.
3. 재시도 정책이 도구 메타데이터 기반으로 더 정교하다.
4. 컨텍스트 오버플로우와 프로바이더 장애에 대한 복구 전략이 있다.
5. 세션, abort, 루프 가드에 대한 테스트 밀도가 더 높고 실제로 실행 검증도 가능했다.

반면 현재 챗봇은 다음 영역에서 강점이 있다.

1. Redmine 도메인에 맞춘 쓰기 보호 규칙이 직접적이다.
2. 웹 대화 세션의 export/restore 흐름이 잘 정리되어 있다.
3. 읽기 후 쓰기 강제, 한 응답당 쓰기 1회 제한 같은 운영 안전장치가 명확하다.

즉, 일반적인 에이전틱 루프 엔진 품질은 `karina_bot` 우위이고, Redmine 업무 제약에 맞춘 도메인 가드는 현재 챗봇이 더 실무 지향적이다.

## 상세 비교

### 1. 루프 제어와 종료 보장

현재 챗봇은 [`claude_chatbot.rb:524`](/var/www/redmine-dev/plugins/redmine_tx_mcp/lib/redmine_tx_mcp/claude_chatbot.rb#L524) 에서 `loop do`와 내부 `while`로 응답을 계속 해석한다. 종료 조건은 주로 도구 호출 예산 소진과 `guard_retry_instruction`의 재시도 종료에 의존한다. [`claude_chatbot.rb:527`](/var/www/redmine-dev/plugins/redmine_tx_mcp/lib/redmine_tx_mcp/claude_chatbot.rb#L527) [`claude_chatbot.rb:561`](/var/www/redmine-dev/plugins/redmine_tx_mcp/lib/redmine_tx_mcp/claude_chatbot.rb#L561)

이 구조는 동작은 하지만 루프 중심부에 wall-clock timeout이나 cooperative abort가 없다. HTTP 레벨 read timeout은 존재하지만, 그것은 API 호출 단위 보호일 뿐 전체 agent run 종료 보장은 아니다. [`claude_chatbot.rb:494`](/var/www/redmine-dev/plugins/redmine_tx_mcp/lib/redmine_tx_mcp/claude_chatbot.rb#L494)

반면 `karina_bot`은 메인 루프를 명시적 iteration 루프로 두고, 매 반복 경계마다 abort와 timeout을 먼저 검사한다. [`llm_client.py:633`](/home/dev/Repos/karina_bot/core/llm_client.py#L633) [`llm_client.py:635`](/home/dev/Repos/karina_bot/core/llm_client.py#L635) [`llm_client.py:640`](/home/dev/Repos/karina_bot/core/llm_client.py#L640) 여기에 세션 차원의 abort 플래그도 분리되어 있다. [`session.py:127`](/home/dev/Repos/karina_bot/core/session.py#L127)

판정: 이 축은 `karina_bot`이 명확히 우수하다.

### 2. 무한 루프 방지

현재 챗봇의 반복 방지는 `repeat_limit_for_tool`, `tool_call_signature`, `repeat_blocked?` 중심이다. [`claude_chatbot.rb:1736`](/var/www/redmine-dev/plugins/redmine_tx_mcp/lib/redmine_tx_mcp/claude_chatbot.rb#L1736) [`claude_chatbot.rb:1747`](/var/www/redmine-dev/plugins/redmine_tx_mcp/lib/redmine_tx_mcp/claude_chatbot.rb#L1747) [`claude_chatbot.rb:1754`](/var/www/redmine-dev/plugins/redmine_tx_mcp/lib/redmine_tx_mcp/claude_chatbot.rb#L1754) 즉, 기본적으로 "같은 도구 + 같은 파라미터를 몇 번 호출했는가"를 본다.

이 방식의 한계는 두 가지다.

1. 결과가 계속 달라지는 정상적인 read-only 반복도 호출 횟수만으로 차단할 수 있다.
2. `A -> B -> A -> B` 같은 ping-pong이나 "파라미터는 같지만 결과가 계속 같은 no-progress"를 구분하지 못한다.

`karina_bot`은 이 부분이 훨씬 강하다. 결과 해시를 만들 때 timestamp류의 불안정 필드를 제거하고, 결과 기반 no-progress, alternating ping-pong, global breaker를 모두 감지한다. [`loop_guard.py:110`](/home/dev/Repos/karina_bot/core/loop_guard.py#L110) [`loop_guard.py:176`](/home/dev/Repos/karina_bot/core/loop_guard.py#L176) [`loop_guard.py:298`](/home/dev/Repos/karina_bot/core/loop_guard.py#L298) [`loop_guard.py:315`](/home/dev/Repos/karina_bot/core/loop_guard.py#L315) [`loop_guard.py:202`](/home/dev/Repos/karina_bot/core/loop_guard.py#L202)

또 이 동작은 테스트로 고정돼 있다.

- no-progress 차단: [`test_agent_loop.py:194`](/home/dev/Repos/karina_bot/tests/test_agent_loop.py#L194)
- progressing read-only 허용: [`test_agent_loop.py:236`](/home/dev/Repos/karina_bot/tests/test_agent_loop.py#L236)
- global evidence 누적 성질: [`test_agent_loop.py:151`](/home/dev/Repos/karina_bot/tests/test_agent_loop.py#L151)

판정: 루프 감지 품질은 `karina_bot`이 한 단계가 아니라 여러 단계 위다.

### 3. 환각 및 잘못된 완료 주장 가드

현재 챗봇의 `guard_retry_instruction`은 꽤 좋다. 계획 미완료, capability refusal, 쓰기 없이 완료 주장, 사실 조회를 도구 없이 답한 경우를 각각 다른 문구로 재시도시킨다. [`claude_chatbot.rb:1802`](/var/www/redmine-dev/plugins/redmine_tx_mcp/lib/redmine_tx_mcp/claude_chatbot.rb#L1802) [`claude_chatbot.rb:1813`](/var/www/redmine-dev/plugins/redmine_tx_mcp/lib/redmine_tx_mcp/claude_chatbot.rb#L1813) [`claude_chatbot.rb:1837`](/var/www/redmine-dev/plugins/redmine_tx_mcp/lib/redmine_tx_mcp/claude_chatbot.rb#L1837) [`claude_chatbot.rb:1850`](/var/www/redmine-dev/plugins/redmine_tx_mcp/lib/redmine_tx_mcp/claude_chatbot.rb#L1850)

이 부분은 단순 규칙 기반으로는 상당히 실용적이다. 관련 테스트도 있다. [`test_claude_chatbot.rb:378`](/var/www/redmine-dev/plugins/redmine_tx_mcp/test/test_claude_chatbot.rb#L378) [`test_claude_chatbot.rb:398`](/var/www/redmine-dev/plugins/redmine_tx_mcp/test/test_claude_chatbot.rb#L398) [`test_claude_chatbot.rb:419`](/var/www/redmine-dev/plugins/redmine_tx_mcp/test/test_claude_chatbot.rb#L419)

`karina_bot`은 이 영역에서 tool 미호출 hallucination과 도구 에러 후 성공 주장 교정을 직접 loop 안에 넣고, 필요 시 `tool_choice='any'`로 강제한다. [`llm_client.py:721`](/home/dev/Repos/karina_bot/core/llm_client.py#L721) [`llm_client.py:737`](/home/dev/Repos/karina_bot/core/llm_client.py#L737) 이 흐름 역시 테스트가 있다. [`test_agent_loop.py:26`](/home/dev/Repos/karina_bot/tests/test_agent_loop.py#L26) [`test_agent_loop.py:68`](/home/dev/Repos/karina_bot/tests/test_agent_loop.py#L68)

판정: 이 축은 큰 차이보다는 성향 차이다.

- 현재 챗봇: 도메인 규칙이 더 직접적
- `karina_bot`: 루프 엔진 수준에서의 교정이 더 일관적

### 4. 도구 실행 안전성

현재 챗봇은 읽기와 쓰기가 섞이면 쓰기를 미루고, 한 응답 안에서 쓰기 도구를 하나만 실행한다. [`claude_chatbot.rb:574`](/var/www/redmine-dev/plugins/redmine_tx_mcp/lib/redmine_tx_mcp/claude_chatbot.rb#L574) [`claude_chatbot.rb:618`](/var/www/redmine-dev/plugins/redmine_tx_mcp/lib/redmine_tx_mcp/claude_chatbot.rb#L618) [`claude_chatbot.rb:629`](/var/www/redmine-dev/plugins/redmine_tx_mcp/lib/redmine_tx_mcp/claude_chatbot.rb#L629) 이 정책은 Redmine 수정 작업에 매우 적합하다. 테스트도 있다. [`test_claude_chatbot.rb:275`](/var/www/redmine-dev/plugins/redmine_tx_mcp/test/test_claude_chatbot.rb#L275) [`test_claude_chatbot.rb:312`](/var/www/redmine-dev/plugins/redmine_tx_mcp/test/test_claude_chatbot.rb#L312) [`test_claude_chatbot.rb:348`](/var/www/redmine-dev/plugins/redmine_tx_mcp/test/test_claude_chatbot.rb#L348)

반면 현재 챗봇의 repeat 정책은 여전히 규칙이 단순하다. side-effecting이면 성공 1회 후 차단, read-only면 3회, 그 외 2회다. [`claude_chatbot.rb:1736`](/var/www/redmine-dev/plugins/redmine_tx_mcp/lib/redmine_tx_mcp/claude_chatbot.rb#L1736) 이 정책은 운영상 보수적이지만, 도구 성질을 메타데이터로 세밀하게 구분하지는 못한다.

`karina_bot`은 retry 정책을 `idempotent`, `side_effecting`, `confirm_required`, `retryable` 메타데이터로 분리한다. [`retry_policy.py:16`](/home/dev/Repos/karina_bot/core/retry_policy.py#L16) [`retry_policy.py:48`](/home/dev/Repos/karina_bot/core/retry_policy.py#L48) 그리고 read/write 혼합 defer도 메타데이터 기반으로 처리한다. [`llm_client.py:801`](/home/dev/Repos/karina_bot/core/llm_client.py#L801) [`llm_client.py:927`](/home/dev/Repos/karina_bot/core/llm_client.py#L927)

판정:

- Redmine 업무 안전 규칙은 현재 챗봇이 더 직관적이다.
- 범용적인 agent tool policy 설계는 `karina_bot`이 더 낫다.

### 5. 컨텍스트 관리

현재 챗봇은 개별 tool result truncation과 전체 history budget trimming을 한다. [`claude_chatbot.rb:824`](/var/www/redmine-dev/plugins/redmine_tx_mcp/lib/redmine_tx_mcp/claude_chatbot.rb#L824) [`claude_chatbot.rb:878`](/var/www/redmine-dev/plugins/redmine_tx_mcp/lib/redmine_tx_mcp/claude_chatbot.rb#L878) 이 방식은 단순하고 유지보수하기 쉽지만, 오래된 맥락을 요약해 보존하기보다는 잘라낸다.

`karina_bot`은 iteration 내 총 결과량을 제한하고, context overflow 발생 시 compact 후 재시도하며, 반복이 길어지면 오래된 tool result를 다시 compact한다. [`llm_client.py:1042`](/home/dev/Repos/karina_bot/core/llm_client.py#L1042) [`llm_client.py:667`](/home/dev/Repos/karina_bot/core/llm_client.py#L667) [`llm_client.py:1086`](/home/dev/Repos/karina_bot/core/llm_client.py#L1086) 이에 대한 테스트도 있다. [`test_iteration_cap.py:10`](/home/dev/Repos/karina_bot/tests/test_iteration_cap.py#L10) [`test_iteration_cap.py:69`](/home/dev/Repos/karina_bot/tests/test_iteration_cap.py#L69) [`test_iteration_cap.py:106`](/home/dev/Repos/karina_bot/tests/test_iteration_cap.py#L106)

판정: 컨텍스트 관리도 `karina_bot` 우위다.

### 6. 프로바이더 장애 복구

현재 챗봇은 Anthropic/OpenAI adapter를 지원하지만, 한 provider 호출 실패 시 자동 fallback이 없다. [`claude_chatbot.rb:490`](/var/www/redmine-dev/plugins/redmine_tx_mcp/lib/redmine_tx_mcp/claude_chatbot.rb#L490) [`claude_chatbot.rb:515`](/var/www/redmine-dev/plugins/redmine_tx_mcp/lib/redmine_tx_mcp/claude_chatbot.rb#L515)

`karina_bot`은 `FallbackClient`로 retryable API 에러를 round-robin 전환한다. [`llm_client.py:1169`](/home/dev/Repos/karina_bot/core/llm_client.py#L1169) [`llm_client.py:1223`](/home/dev/Repos/karina_bot/core/llm_client.py#L1223)

판정: 운영 안정성은 `karina_bot` 우위다.

### 7. 세션/상태 관리

현재 챗봇은 웹 대화 맥락에 맞는 export/restore를 제공하고, structured tool history와 pending plan context를 복원한다. [`claude_chatbot.rb:297`](/var/www/redmine-dev/plugins/redmine_tx_mcp/lib/redmine_tx_mcp/claude_chatbot.rb#L297) [`claude_chatbot.rb:305`](/var/www/redmine-dev/plugins/redmine_tx_mcp/lib/redmine_tx_mcp/claude_chatbot.rb#L305) 관련 테스트도 적절하다. [`test_claude_chatbot.rb:151`](/var/www/redmine-dev/plugins/redmine_tx_mcp/test/test_claude_chatbot.rb#L151) [`test_claude_chatbot.rb:176`](/var/www/redmine-dev/plugins/redmine_tx_mcp/test/test_claude_chatbot.rb#L176)

`karina_bot`은 run lifecycle, abort, background task 기록, 상태 표시가 더 커널화되어 있다. [`session.py:59`](/home/dev/Repos/karina_bot/core/session.py#L59) [`session.py:100`](/home/dev/Repos/karina_bot/core/session.py#L100) [`session.py:111`](/home/dev/Repos/karina_bot/core/session.py#L111) [`session.py:146`](/home/dev/Repos/karina_bot/core/session.py#L146) 세션 단위 검증도 많다. [`test_session.py:14`](/home/dev/Repos/karina_bot/tests/test_session.py#L14) [`test_session.py:122`](/home/dev/Repos/karina_bot/tests/test_session.py#L122) [`test_session.py:230`](/home/dev/Repos/karina_bot/tests/test_session.py#L230)

판정:

- 웹 챗 UX용 session snapshot은 현재 챗봇 강점
- 루프 실행 커널로서의 세션 모델은 `karina_bot` 강점

## 테스트 및 검증 상태

직접 실행한 결과는 다음과 같다.

### `karina_bot`

- `PYTHONPATH=tests:. python3 -m unittest tests.test_agent_loop tests.test_iteration_cap`
  - 결과: `Ran 63 tests ... OK`
- `PYTHONPATH=tests:. python3 -m unittest tests.test_session`
  - 결과: `Ran 69 tests ... OK`

즉, 루프 핵심, iteration cap, 세션/abort 흐름은 현재 환경에서 직접 실행 검증됐다.

### 현재 챗봇

- [`test/test_claude_chatbot.rb`](/var/www/redmine-dev/plugins/redmine_tx_mcp/test/test_claude_chatbot.rb) 는 존재하고, loop budget, write defer, session restore, guard retry 등을 테스트한다. [`test_claude_chatbot.rb:205`](/var/www/redmine-dev/plugins/redmine_tx_mcp/test/test_claude_chatbot.rb#L205) [`test_claude_chatbot.rb:225`](/var/www/redmine-dev/plugins/redmine_tx_mcp/test/test_claude_chatbot.rb#L225) [`test_claude_chatbot.rb:275`](/var/www/redmine-dev/plugins/redmine_tx_mcp/test/test_claude_chatbot.rb#L275)
- 다만 이 환경에서는 Tidewave railtie가 non-reloading 환경을 거부해 테스트를 끝까지 실행하지 못했다.

따라서 현재 챗봇 쪽 평가는 코드 검토와 테스트 코드 존재를 근거로 했고, 동일 수준의 실행 검증까지는 완료하지 못했다.

## 최종 판정

### 종합 우위

`karina_bot`

### 이유

1. 루프 종료 보장이 더 명시적이다.
2. 반복 감지가 결과 기반이며 실제 무한 루프 패턴을 더 잘 잡는다.
3. 메타데이터 기반 retry 정책이 더 설계적으로 일관된다.
4. context overflow와 provider failure에 대한 회복성이 더 높다.
5. 핵심 루프 관련 테스트를 현재 환경에서 직접 실행해 확인할 수 있었다.

### 현재 챗봇이 더 좋은 점

1. Redmine 수정 작업에 맞춘 쓰기 보호 규칙이 더 직접적이다.
2. 읽기 후 쓰기, 쓰기 1회 제한은 업무 시스템에 매우 실용적이다.
3. 세션 export/restore는 웹 UI 대화 경험에 적합하다.

## 현재 챗봇 개선 우선순위

### 1순위

`resolve_response` 루프에 hard cap, wall-clock timeout, cooperative abort를 추가한다.

근거:

- 현재는 도구 예산 중심 종료다. [`claude_chatbot.rb:527`](/var/www/redmine-dev/plugins/redmine_tx_mcp/lib/redmine_tx_mcp/claude_chatbot.rb#L527)
- `karina_bot`은 이 부분이 이미 엔진 수준에서 정리되어 있다. [`llm_client.py:633`](/home/dev/Repos/karina_bot/core/llm_client.py#L633)

### 2순위

`repeat_blocked?`를 결과 기반 `LoopGuard` 모듈로 교체한다.

최소 요구사항:

- no-progress detection
- ping-pong detection
- global breaker
- unstable field 제거 후 결과 해시

### 3순위

도구 메타데이터 기반 retry policy를 도입한다.

최소 요구사항:

- `idempotent`
- `side_effecting`
- `retryable`
- `confirm_required`

### 4순위

context overflow 대응과 adaptive compaction을 도입한다.

현재 구조는 trimming 위주라 장기 루프에서 정보 손실이 크다. [`claude_chatbot.rb:878`](/var/www/redmine-dev/plugins/redmine_tx_mcp/lib/redmine_tx_mcp/claude_chatbot.rb#L878)

### 5순위

provider fallback을 추가한다.

Anthropic/OpenAI adapter를 이미 갖고 있으므로, 장애 복구용 래퍼를 올리는 비용 대비 효과가 크다.

## 결론 한 줄

현재 챗봇은 Redmine 작업 규칙을 잘 반영한 실무형 루프이고, `karina_bot`은 그보다 더 성숙한 범용 에이전틱 루프 엔진이다. 현재 챗봇이 `karina_bot` 수준으로 올라가려면 종료 보장, progress-aware loop guard, retry stratification, adaptive compaction을 먼저 가져와야 한다.
